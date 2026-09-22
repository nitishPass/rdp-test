# Telegram 24/7 Controller — Setup Guide

## What changed

The Windows runner no longer needs to be the only place where the Telegram control bot lives.

The new `controller/` process runs continuously on an always-on Linux host and talks to the GitHub Actions API.

Flow:

Telegram → 24/7 controller → GitHub API → rdp.yml → Windows runner

The existing `core/BotService.ps1` remains runner-side.

## Files changed

### Added
- `controller/bot.py`
- `controller/requirements.txt`
- `controller/.env.example`
- `controller/.gitignore`
- `controller/README.md`

### Modified
- `.github/workflows/rdp.yml`
- `core/Bootstrap.ps1`

### Not removed
- `core/BotService.ps1`
- `core/JobManager.ps1`
- `core/RelayManager.ps1`

## GitHub token permissions

Create a fine-grained token for this repository.

Minimum practical permissions for this controller:
- Actions: Read and write
- Contents: Read
- Metadata: Read
- Secrets: Read and write

The controller needs Actions write to dispatch/cancel workflows and Secrets write to save custom RDP credentials securely.

## Existing default RDP credentials

No migration is required for your existing credentials.

When Telegram chooses:

`🔒 Keep Default`

the Windows runner continues using:

`System/secrets.json`

from your existing CloudVault restore.

## Custom RDP credentials

When Telegram chooses:

`✏️ Custom`

the controller asks for username and password.

It encrypts each value with the repository's GitHub Actions public key and stores:
- `RDP_CUSTOM_USERNAME`
- `RDP_CUSTOM_PASSWORD`

The password is never placed in the workflow-dispatch JSON.

## 24/7 host

A small Linux VPS is recommended.

Install:

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip
mkdir -p ~/rdp-controller
cd ~/rdp-controller
python3 -m venv .venv
source .venv/bin/activate
```

Copy `controller/` contents to this directory and run:

```bash
pip install -r requirements.txt
cp .env.example .env
nano .env
python bot.py
```

For permanent service, follow `controller/README.md` for the systemd unit.

## Telegram IDs

The bot intentionally accepts commands only when both:
- `TELEGRAM_ADMIN_ID` matches the sender ID
- `TELEGRAM_CHAT_ID` matches the chat ID

Do not use the bot's username as an authorization mechanism.

## Dynamic workflow inputs

The controller fetches `.github/workflows/rdp.yml` and reads the `workflow_dispatch.inputs` block.

If you add a new non-secret input later, the controller automatically shows it.

Example:

```yaml
enable_ollama:
  description: Enable Ollama
  required: true
  type: boolean
  default: true
```

No Python change is needed.

Do not add passwords, API keys, bot tokens, or other secrets as workflow inputs. Use GitHub repository secrets instead.

## Test sequence

1. Start the controller on the VPS.
2. Send `/start`.
3. Press `▶️ Start`.
4. Select `🔒 Keep Default`.
5. Leave `is_relay` at its default.
6. Confirm.
7. Verify the workflow starts.
8. Use `/status`.
9. Use `/runs`.
10. Stop the run from the Telegram `🛑 Stop` menu.

Then test `✏️ Custom` separately.
