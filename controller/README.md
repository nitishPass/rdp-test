# 24/7 Telegram → GitHub Actions Controller

This controller is intentionally separate from the Windows GitHub Actions runner.

## What it does

- Keeps the Telegram bot alive even when the Windows RDP workflow is stopped.
- Starts the `rdp.yml` workflow from Telegram.
- Stops/cancels active workflow runs from Telegram.
- Shows active/recent workflow runs.
- Reads `.github/workflows/rdp.yml` and discovers `workflow_dispatch` inputs dynamically.
- Handles the RDP credential choice first:
  - **Keep Default** → existing `System/secrets.json` credentials.
  - **Custom** → stores the supplied username/password as encrypted GitHub Actions repository secrets, then uses them.
- Never sends the custom RDP password as a `workflow_dispatch` input.

## Telegram commands

- `/start`
- `/status`
- `/runs`
- `/skip`

The inline menu provides Start, Status, Runs, Stop, and Workflow Inputs.

## Important credential design

GitHub workflow-dispatch inputs are not a safe place for a password. The controller therefore uses:

- `RDP_CREDENTIAL_MODE=default` → Bootstrap uses the current CloudVault credentials.
- `RDP_CREDENTIAL_MODE=custom` → Bootstrap uses:
  - `RDP_CUSTOM_USERNAME`
  - `RDP_CUSTOM_PASSWORD`

The two custom values are stored through GitHub's repository-secret API, encrypted with the repository public key using libsodium/PyNaCl.

## Requirements

- A small always-on Linux VPS, Raspberry Pi, or other always-on Linux host.
- Python 3.11+.
- A Telegram bot token.
- Your Telegram numeric user ID and chat ID.
- A GitHub fine-grained token with:
  - Actions: Read and write
  - Secrets: Read and write
  - Contents: Read
  - Metadata: Read
- Repository access sufficient for the selected permissions.

## Install

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip

mkdir -p ~/rdp-controller
cd ~/rdp-controller

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

cp .env.example .env
nano .env
```

Fill:

```text
TELEGRAM_BOT_TOKEN=...
TELEGRAM_ADMIN_ID=...
TELEGRAM_CHAT_ID=...

GITHUB_TOKEN=...
GITHUB_REPO=OWNER/REPOSITORY
GITHUB_WORKFLOW=rdp.yml
GITHUB_REF=main
```

Test:

```bash
set -a
source .env
set +a
python bot.py
```

Open Telegram and send `/start`.

## Keep it alive with systemd

Create:

```bash
sudo nano /etc/systemd/system/rdp-telegram-controller.service
```

Use:

```ini
[Unit]
Description=RDP Telegram GitHub Actions Controller
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=YOUR_LINUX_USER
WorkingDirectory=/home/YOUR_LINUX_USER/rdp-controller
EnvironmentFile=/home/YOUR_LINUX_USER/rdp-controller/.env
ExecStart=/home/YOUR_LINUX_USER/rdp-controller/.venv/bin/python /home/YOUR_LINUX_USER/rdp-controller/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now rdp-telegram-controller
sudo systemctl status rdp-telegram-controller
```

Logs:

```bash
journalctl -u rdp-telegram-controller -f
```

## First-run workflow

1. Send `/start`.
2. Press **▶️ Start**.
3. Choose:
   - **🔒 Keep Default**, or
   - **✏️ Custom**.
4. If Custom:
   - send username;
   - send password;
   - the controller encrypts and writes the two GitHub repository secrets.
5. The controller reads the workflow's current `workflow_dispatch` inputs.
6. It asks for each input.
7. Confirm **START WORKFLOW**.
8. The controller calls GitHub's workflow-dispatch API.
9. Use **Status/Runs/Stop** without opening GitHub.

## Adding a new workflow parameter

For example:

```yaml
on:
  workflow_dispatch:
    inputs:
      enable_ollama:
        description: Enable Ollama
        required: true
        type: boolean
        default: true
```

No controller code change is needed.

The controller reads the workflow file from GitHub and automatically displays the new parameter.

GitHub allows up to 25 top-level `workflow_dispatch` inputs. Keep passwords/tokens out of those inputs. Use repository secrets for sensitive values.

## Security notes

- Do not commit `.env`.
- Restrict the Telegram bot to your numeric admin ID and chat ID.
- Use a dedicated fine-grained GitHub token rather than a broad classic PAT where possible.
- The custom RDP password is stored as a GitHub Actions secret, not as a workflow input.
- The controller does not print the password.
- Do not put the bot token or GitHub token into source code.

## Existing runner-side BotService

`core/BotService.ps1` is intentionally left in place. It continues to handle runner-local features such as downloads, `/backup`, `/relay`, and runner shutdown.

The new controller is the permanent control plane. This prevents the Telegram bot from disappearing when the Windows runner stops.
