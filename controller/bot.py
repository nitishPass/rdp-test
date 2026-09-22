import asyncio
import base64
import html
import logging
import os
import re
from dataclasses import dataclass, field
from typing import Any

import requests
import yaml
from nacl import public
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ChatAction
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

logging.basicConfig(
    format="%(asctime)s | %(levelname)s | %(message)s",
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
)
log = logging.getLogger("rdp-controller")

GITHUB_API = "https://api.github.com"
TG_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
TG_ADMIN_ID = int(os.environ["TELEGRAM_ADMIN_ID"])
TG_CHAT_ID = int(os.environ["TELEGRAM_CHAT_ID"])
GH_TOKEN = os.environ["GITHUB_TOKEN"]
GH_REPO = os.environ["GITHUB_REPO"]  # owner/repo
GH_WORKFLOW = os.getenv("GITHUB_WORKFLOW", "rdp.yml")
GH_REF = os.getenv("GITHUB_REF", "main")

SESSION: dict[int, "Session"] = {}


@dataclass
class Session:
    mode: str = ""
    inputs: dict[str, str] = field(default_factory=dict)
    pending_input: str | None = None
    custom_username: str | None = None


def gh_headers():
    return {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {GH_TOKEN}",
        "X-GitHub-Api-Version": "2026-03-10",
    }


def gh(method: str, path: str, **kwargs):
    r = requests.request(
        method,
        f"{GITHUB_API}{path}",
        headers=gh_headers(),
        timeout=30,
        **kwargs,
    )
    if not r.ok:
        raise RuntimeError(f"GitHub API {r.status_code}: {r.text[:500]}")
    return r


def workflow_yaml() -> dict[str, Any]:
    r = gh(
        "GET",
        f"/repos/{GH_REPO}/contents/.github/workflows/{GH_WORKFLOW}",
        params={"ref": GH_REF},
    )
    data = r.json()
    raw = base64.b64decode(data["content"]).decode("utf-8")
    parsed = yaml.safe_load(raw) or {}
    # PyYAML 1.1 may parse YAML key 'on' as True.
    trigger = parsed.get("on")
    if trigger is None:
        trigger = parsed.get(True, {})
    if trigger is None:
        trigger = {}
    inputs = trigger.get("workflow_dispatch", {}).get("inputs", {})
    return {"raw": raw, "inputs": inputs or {}}


def workflow_inputs() -> dict[str, dict[str, Any]]:
    return workflow_yaml()["inputs"]


def repo_secret_public_key():
    return gh(
        "GET", f"/repos/{GH_REPO}/actions/secrets/public-key"
    ).json()


def put_repo_secret(name: str, value: str):
    key_data = repo_secret_public_key()
    key = public.PublicKey(
        key_data["key"].encode("utf-8"),
        public.Encoding.Base64Encoder(),
    )
    encrypted = public.SealedBox(key).encrypt(value.encode("utf-8"))
    encrypted_b64 = base64.b64encode(encrypted).decode("ascii")

    gh(
        "PUT",
        f"/repos/{GH_REPO}/actions/secrets/{name}",
        json={"encrypted_value": encrypted_b64, "key_id": key_data["key_id"]},
    )


def dispatch_workflow(inputs: dict[str, str]):
    payload = {"ref": GH_REF, "inputs": inputs}
    r = gh(
        "POST",
        f"/repos/{GH_REPO}/actions/workflows/{GH_WORKFLOW}/dispatches",
        json=payload,
    )
    return r.json() if r.content else {}


def list_runs(limit=10):
    r = gh(
        "GET",
        f"/repos/{GH_REPO}/actions/runs",
        params={"workflow_id": GH_WORKFLOW, "per_page": limit},
    )
    return r.json().get("workflow_runs", [])


def active_runs():
    return [
        x for x in list_runs(30)
        if x.get("status") in {"queued", "in_progress", "waiting", "requested", "pending"}
    ]


def cancel_run(run_id: int):
    gh("POST", f"/repos/{GH_REPO}/actions/runs/{run_id}/cancel")


def run_url(run):
    return run.get("html_url", "")


def esc(v) -> str:
    return html.escape(str(v))


def allowed(update: Update) -> bool:
    user = update.effective_user
    chat = update.effective_chat
    return bool(
        user
        and chat
        and user.id == TG_ADMIN_ID
        and chat.id == TG_CHAT_ID
    )


async def deny_or_ignore(update: Update):
    if update.callback_query:
        await update.callback_query.answer("Not authorized.", show_alert=True)
    elif update.effective_message:
        await update.effective_message.reply_text("Not authorized.")


def main_menu():
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("▶️ Start", callback_data="menu:start"),
            InlineKeyboardButton("📊 Status", callback_data="menu:status"),
        ],
        [
            InlineKeyboardButton("📋 Runs", callback_data="menu:runs"),
            InlineKeyboardButton("🛑 Stop", callback_data="menu:stop"),
        ],
        [
            InlineKeyboardButton("⚙️ Workflow Inputs", callback_data="menu:inputs"),
            InlineKeyboardButton("🔄 Refresh", callback_data="menu:home"),
        ],
    ])


async def send_home(message):
    runs = active_runs()
    state = "🟢 RUNNING" if runs else "⚫ STOPPED"
    text = (
        "<b>🖥 RDP WORKFLOW CONTROLLER</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"Workflow: <code>{esc(GH_WORKFLOW)}</code>\n"
        f"Runner state: <b>{state}</b>\n"
        f"Active runs: <b>{len(runs)}</b>\n\n"
        "The controller stays online independently of the Windows runner."
    )
    await message.reply_text(text, parse_mode="HTML", reply_markup=main_menu())


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny_or_ignore(update)
    SESSION[update.effective_user.id] = Session()
    await send_home(update.effective_message)


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny_or_ignore(update)
    await show_status(update.effective_message)


async def cmd_runs(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny_or_ignore(update)
    await show_runs(update.effective_message)


async def show_status(message):
    try:
        runs = active_runs()
        if not runs:
            text = "<b>📊 STATUS</b>\n━━━━━━━━━━━━━━━━━━━━\n⚫ No active workflow run."
        else:
            lines = [
                "<b>📊 ACTIVE RUNS</b>",
                "━━━━━━━━━━━━━━━━━━━━",
            ]
            for r in runs[:5]:
                lines.append(
                    f"#{r['run_number']} • <b>{esc(r['status'])}</b> • "
                    f"{esc(r.get('run_started_at') or r.get('created_at') or '-')}\n"
                    f"<a href=\"{esc(run_url(r))}\">Open run</a>"
                )
            text = "\n".join(lines)
        await message.reply_text(
            text,
            parse_mode="HTML",
            disable_web_page_preview=True,
            reply_markup=main_menu(),
        )
    except Exception as e:
        log.exception("status")
        await message.reply_text(f"❌ Status error: <code>{esc(e)}</code>", parse_mode="HTML")


async def show_runs(message):
    try:
        runs = list_runs(10)
        if not runs:
            text = "<b>📋 RECENT RUNS</b>\n━━━━━━━━━━━━━━━━━━━━\nNo runs found."
        else:
            lines = ["<b>📋 RECENT RUNS</b>", "━━━━━━━━━━━━━━━━━━━━"]
            for r in runs:
                lines.append(
                    f"#{r['run_number']} • {esc(r['status'])}/{esc(r['conclusion'] or '-')}\n"
                    f"<a href=\"{esc(run_url(r))}\">Open</a>"
                )
            text = "\n".join(lines)
        await message.reply_text(text, parse_mode="HTML", disable_web_page_preview=True, reply_markup=main_menu())
    except Exception as e:
        await message.reply_text(f"❌ Runs error: <code>{esc(e)}</code>", parse_mode="HTML")


async def start_flow(message, user_id: int):
    s = SESSION.setdefault(user_id, Session())
    s.mode = "credentials"
    s.inputs = {}
    s.pending_input = None

    await message.reply_text(
        "<b>🚀 START RDP WORKFLOW</b>\n\n"
        "RDP credentials:\n"
        "• <b>Keep Default</b> = use the username/password already stored in your existing CloudVault secrets.json.\n"
        "• <b>Custom</b> = save a new username/password as encrypted GitHub Actions repository secrets and use them for this run.\n\n"
        "The password is never sent as a workflow_dispatch input.",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup([
            [
                InlineKeyboardButton("🔒 Keep Default", callback_data="cred:default"),
                InlineKeyboardButton("✏️ Custom", callback_data="cred:custom"),
            ],
            [InlineKeyboardButton("❌ Cancel", callback_data="menu:home")],
        ]),
    )


async def show_next_input(message, user_id: int):
    s = SESSION[user_id]
    inputs = workflow_inputs()

    # rdp_credential_mode is handled by the dedicated credential screen.
    keys = [k for k in inputs.keys() if k != "rdp_credential_mode"]

    # Skip values already collected.
    remaining = [k for k in keys if k not in s.inputs]

    if not remaining:
        return await confirm_start(message, user_id)

    key = remaining[0]
    spec = inputs[key] or {}
    name = spec.get("description") or key
    typ = spec.get("type", "string")
    default = spec.get("default")
    choices = spec.get("options") or spec.get("choices") or []

    s.pending_input = key

    # Safe defaults: automatically take a workflow default for non-required fields
    # only after showing it to the user.
    if typ == "boolean":
        default_text = "true" if default is True else "false" if default is False else "not set"
        await message.reply_text(
            f"<b>⚙️ {esc(key)}</b>\n{esc(name)}\n\nDefault: <code>{default_text}</code>",
            parse_mode="HTML",
            reply_markup=InlineKeyboardMarkup([
                [
                    InlineKeyboardButton("✅ True", callback_data=f"input:{key}:true"),
                    InlineKeyboardButton("❌ False", callback_data=f"input:{key}:false"),
                ],
                [InlineKeyboardButton("↩️ Use default", callback_data=f"input:{key}:__default__")],
                [InlineKeyboardButton("🛑 Cancel", callback_data="menu:home")],
            ]),
        )
        return

    if typ == "choice" or choices:
        rows = []
        for choice in choices[:20]:
            rows.append([InlineKeyboardButton(str(choice), callback_data=f"input:{key}:{choice}")])
        if default is not None:
            rows.append([InlineKeyboardButton(f"↩️ Default: {default}", callback_data=f"input:{key}:__default__")])
        rows.append([InlineKeyboardButton("🛑 Cancel", callback_data="menu:home")])
        await message.reply_text(
            f"<b>⚙️ {esc(key)}</b>\n{esc(name)}",
            parse_mode="HTML",
            reply_markup=InlineKeyboardMarkup(rows),
        )
        return

    default_text = "not set" if default is None else str(default)
    await message.reply_text(
        f"<b>⚙️ {esc(key)}</b>\n{esc(name)}\n\n"
        f"Default: <code>{esc(default_text)}</code>\n\n"
        "Send the value, or /skip to use the workflow default.",
        parse_mode="HTML",
    )


async def confirm_start(message, user_id: int):
    s = SESSION[user_id]
    lines = ["<b>🚀 READY TO START</b>", "━━━━━━━━━━━━━━━━━━━━"]
    lines.append(f"RDP credentials: <b>{esc(s.mode)}</b>")
    for k, v in s.inputs.items():
        shown = "••••••" if "password" in k.lower() or "token" in k.lower() else v
        lines.append(f"{esc(k)} = <code>{esc(shown)}</code>")

    await message.reply_text(
        "\n".join(lines),
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("▶️ START WORKFLOW", callback_data="start:confirm")],
            [InlineKeyboardButton("✏️ Edit", callback_data="start:edit"),
             InlineKeyboardButton("❌ Cancel", callback_data="menu:home")],
        ]),
    )


async def handle_custom_username(message, user_id):
    s = SESSION[user_id]
    value = message.text.strip()
    if not value or len(value) > 100:
        return await message.reply_text("Invalid username. Send a shorter username.")
    s.custom_username = value
    s.pending_input = "__custom_password__"
    await message.reply_text("🔐 Send the custom RDP password.\nIt will be encrypted before being stored in GitHub Actions Secrets.")


async def handle_custom_password(message, user_id):
    s = SESSION[user_id]
    value = message.text
    if not value or len(value) > 256:
        return await message.reply_text("Invalid password length.")
    try:
        put_repo_secret("RDP_CUSTOM_USERNAME", s.custom_username or "")
        put_repo_secret("RDP_CUSTOM_PASSWORD", value)
        s.mode = "custom"
        s.pending_input = None
        await message.reply_text(
            "✅ Custom RDP credentials saved as encrypted GitHub repository secrets.\n\n"
            "Continuing with workflow parameters…"
        )
        await show_next_input(message, user_id)
    except Exception as e:
        log.exception("custom credentials")
        await message.reply_text(f"❌ Could not save custom credentials: <code>{esc(e)}</code>", parse_mode="HTML")


async def on_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return
    uid = update.effective_user.id
    s = SESSION.get(uid)
    if not s:
        return await send_home(update.effective_message)
    if s.pending_input == "__custom_username__":
        return await handle_custom_username(update.effective_message, uid)
    if s.pending_input == "__custom_password__":
        return await handle_custom_password(update.effective_message, uid)

    if s.pending_input:
        key = s.pending_input
        s.inputs[key] = update.effective_message.text.strip()
        s.pending_input = None
        return await show_next_input(update.effective_message, uid)


async def callbacks(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    if not allowed(update):
        return await q.answer("Not authorized.", show_alert=True)
    await q.answer()
    uid = update.effective_user.id
    data = q.data

    if data == "menu:home":
        SESSION[uid] = Session()
        return await send_home(q.message)

    if data == "menu:start":
        return await start_flow(q.message, uid)

    if data == "menu:status":
        return await show_status(q.message)

    if data == "menu:runs":
        return await show_runs(q.message)

    if data == "menu:stop":
        runs = active_runs()
        if not runs:
            return await q.message.reply_text("⚫ No active workflow run.", reply_markup=main_menu())
        rows = []
        for r in runs[:10]:
            rows.append([
                InlineKeyboardButton(
                    f"🛑 Stop #{r['run_number']}",
                    callback_data=f"stop:{r['id']}",
                )
            ])
        rows.append([InlineKeyboardButton("↩️ Back", callback_data="menu:home")])
        return await q.message.reply_text(
            "<b>🛑 ACTIVE RUNS</b>\nSelect a run to cancel.",
            parse_mode="HTML",
            reply_markup=InlineKeyboardMarkup(rows),
        )

    if data == "menu:inputs":
        try:
            inputs = workflow_inputs()
            lines = ["<b>⚙️ CURRENT WORKFLOW INPUTS</b>", "━━━━━━━━━━━━━━━━━━━━"]
            for k, v in inputs.items():
                typ = v.get("type", "string")
                default = v.get("default", "—")
                choices = v.get("options") or []
                lines.append(f"<b>{esc(k)}</b> • {esc(typ)} • default=<code>{esc(default)}</code>")
                if choices:
                    lines.append(f"choices: {esc(', '.join(map(str, choices)))}")
            await q.message.reply_text("\n".join(lines), parse_mode="HTML", reply_markup=main_menu())
        except Exception as e:
            await q.message.reply_text(f"❌ Could not read workflow inputs: <code>{esc(e)}</code>", parse_mode="HTML")
        return

    if data == "cred:default":
        s = SESSION.setdefault(uid, Session())
        s.mode = "default"
        s.inputs["rdp_credential_mode"] = "default"
        s.pending_input = None
        return await show_next_input(q.message, uid)

    if data == "cred:custom":
        s = SESSION.setdefault(uid, Session())
        s.mode = "custom"
        s.inputs["rdp_credential_mode"] = "custom"
        s.pending_input = "__custom_username__"
        return await q.message.reply_text(
            "👤 Send the custom RDP username."
        )

    if data.startswith("input:"):
        _, key, value = data.split(":", 2)
        s = SESSION[uid]
        spec = workflow_inputs().get(key, {})
        if value == "__default__":
            default = spec.get("default")
            if default is None:
                s.inputs[key] = ""
            elif isinstance(default, bool):
                s.inputs[key] = "true" if default else "false"
            else:
                s.inputs[key] = str(default)
        else:
            s.inputs[key] = value
        s.pending_input = None
        return await show_next_input(q.message, uid)

    if data == "start:edit":
        s = SESSION[uid]
        s.inputs = {"rdp_credential_mode": s.mode}
        s.pending_input = None
        return await show_next_input(q.message, uid)

    if data == "start:confirm":
        s = SESSION[uid]
        try:
            await q.message.reply_chat_action(ChatAction.TYPING)
            # Don't allow accidental relay mode from this controller unless explicitly chosen.
            inputs = dict(s.inputs)
            result = dispatch_workflow(inputs)
            await q.message.reply_text(
                "🚀 <b>Workflow dispatched.</b>\n\n"
                f"Workflow: <code>{esc(GH_WORKFLOW)}</code>\n"
                f"Credential mode: <b>{esc(s.mode)}</b>\n\n"
                "Use /status or /runs to monitor it.",
                parse_mode="HTML",
                reply_markup=main_menu(),
            )
            SESSION.pop(uid, None)
        except Exception as e:
            log.exception("dispatch")
            await q.message.reply_text(
                f"❌ Dispatch failed:\n<code>{esc(e)}</code>",
                parse_mode="HTML",
                reply_markup=main_menu(),
            )
        return

    if data.startswith("stop:"):
        run_id = int(data.split(":", 1)[1])
        try:
            cancel_run(run_id)
            await q.message.reply_text(
                f"🛑 Cancellation requested for run <code>{run_id}</code>.",
                parse_mode="HTML",
                reply_markup=main_menu(),
            )
        except Exception as e:
            await q.message.reply_text(f"❌ Stop failed: <code>{esc(e)}</code>", parse_mode="HTML")


async def cmd_skip(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return
    uid = update.effective_user.id
    s = SESSION.get(uid)
    if not s or not s.pending_input:
        return await update.effective_message.reply_text("Nothing to skip.")
    key = s.pending_input
    spec = workflow_inputs().get(key, {})
    default = spec.get("default")
    s.inputs[key] = "" if default is None else ("true" if default is True else "false" if default is False else str(default))
    s.pending_input = None
    await show_next_input(update.effective_message, uid)


def main():
    app = Application.builder().token(TG_TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("runs", cmd_runs))
    app.add_handler(CommandHandler("skip", cmd_skip))
    app.add_handler(CallbackQueryHandler(callbacks))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))
    log.info("24/7 Telegram controller starting for %s / %s", GH_REPO, GH_WORKFLOW)
    app.run_polling(drop_pending_updates=True, allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
