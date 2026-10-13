<h1 align="center">⚡ fluxBot</h1>

<p align="center">
  Telegram bot that hands out <a href="https://github.com/p1neappleXpress/OpenFlux">OpenFlux</a> channels — with admin approval and a one-command installer
</p>

<p align="center">
  🇷🇺 <a href="./README.md">Русский</a> | 🇬🇧 <strong>English</strong>
</p>

<p align="center">
  <a href="https://github.com/benderobo/fluxBot/actions/workflows/check.yml"><img src="https://github.com/benderobo/fluxBot/actions/workflows/check.yml/badge.svg" alt="check" /></a>
  <img src="https://img.shields.io/badge/python-3.12-blue" alt="python" />
  <img src="https://img.shields.io/badge/aiogram-3.x-2ca5e0" alt="aiogram" />
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license" />
</p>

---

> [!CAUTION]
> **EDUCATIONAL PROJECT FOR LEARNING NETWORK TUNNELS, DOCKER AND THE TELEGRAM BOT API. RUN IT ON YOUR OWN SERVERS AT YOUR OWN RISK. THE AUTHOR IS NOT RESPONSIBLE FOR HOW YOU USE IT.**

---

## Overview

A user sends the bot a link to **their own** public document, an admin approves the request, and the bot spins up a dedicated exit node and replies with a ready-to-import profile — an `openflux://v1/...` link plus a QR code.

```
User ──document link──▶ fluxBot ──approval──▶ admin
                           │
                           ├─ docker run ▶ channel (exit node) ◀──▶ Yandex / Mail.ru
                           │
User ◀── openflux://v1 + QR┘
```

Every channel is a separate container with its own network namespace, RAM/CPU limits and log rotation. The `RST DROP` rule OpenFlux needs stays inside the container and doesn't affect other services on the host.

> [!IMPORTANT]
> Debian / Ubuntu, amd64 / arm64, root. A dedicated server for exit nodes is recommended.

### Features

- 📝 Requests with one-tap admin approval; trusted users get channels instantly
- 🔑 Channels with a secret (AES-256-GCM) or without — user's choice
- 📲 Native `openflux://v1` profiles plus QR for one-tap import
- 🐳 One container per channel, resource limits, `RST DROP` scoped to its netns
- 🐕 Watchdog: crashed channels, secret changes, Yandex captcha, disk and RAM
- 🔄 OpenFlux updates without dropping channels or losing secrets
- 💾 Backup and restore from the menu

## Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/benderobo/fluxBot/main/install.sh)
```

Pick **"1. Установка"**, enter the bot token from [@BotFather](https://t.me/BotFather), your Telegram ID from [@userinfobot](https://t.me/userinfobot) and the channel limit. Then send `/start` to your bot. Menu afterwards: `ofbot`.

| Channels | vCPU | RAM | Disk |
|---|---|---|---|
| up to 5 | 1 | 1 GB | 10 GB |
| 10–15 | 2 | 2–4 GB | 20 GB |
| 30 | 4 | 4–6 GB | 40 GB |

> [!TIP]
> For 30+ channels prefer 2–3 servers with 10–15 channels each: dozens of processes behind one IP quickly trigger Yandex captchas.

## Bot commands

**User:** `/start`, `/myconfig`, `/client`, `/direct` (a channel without a document: plain TCP to the server; only when the admin set `PUBLIC_HOST`), `/delete` (delete your own channel or withdraw your request, with a confirmation button), or just send a document link.

**Admin:** `/users`, `/channels`, `/status`, `/give <tg_id> <url|direct> [secret|nosecret] [vyandex]`, `/delete [id]` (delete a channel after a button confirmation; the owner is notified), `/revoke <id>` (stop immediately), `/ban` · `/unban <tg_id>`, `/decode <openflux://v1/...>`.

**Supported links:** Yandex Docs (`https://disk.yandex.ru/i/…`), Yandex Boards (`https://boards.yandex.ru/guest/?hash=…`), Mail.ru (`https://cloud.mail.ru/public/…`). Yandex Volga (`vyandex`) is handed out by the admin: `/give <tg_id> <url> vyandex`.

## Clients

| Platform | Client |
|---|---|
| 🍏 iPhone / iPad | [TestFlight](https://testflight.apple.com/join/BwnAcdus) |
| 📱 Android | [OpenFluxAndroid](https://github.com/p1neappleXpress/OpenFluxAndroid/releases) |
| 💻 Windows / Linux | [OpenFlux](https://github.com/p1neappleXpress/OpenFlux/releases) |

## Configuration

`/opt/openflux-bot/bot/.env`, apply with `ofbot restart`. All options are documented in [`bot/.env.example`](./bot/.env.example). Yandex Volga (`vyandex`, links like `https://docs.yandex.ru/edit/d/…`) is handed out with `/give <tg_id> <url> vyandex`; set `VYANDEX_MODE=auto` to route such links from users to it automatically.

## Encryption

For 🔑 channels the bot generates a secret and passes it via an environment variable. The entrypoint writes it to a `600` file, unsets the variable and starts the node with `--encryption-key-file`, so the secret never shows up in the process arguments. The AES-256-GCM key is derived from the secret **and the document URL** (`context`), so the two must match exactly — the bot takes both from the same database row.

## Security

> [!IMPORTANT]
> The bot has access to `docker.sock`, which is root-equivalent. Treat the bot token like a root password.

Use SSH keys only, install `fail2ban`, expose nothing but SSH on the exit server.

## Development

Edit `bot/` or `exit/` → run `python3 tools/build.py` → commit together with `install.sh`. CI fails if the installer is out of date.

## Credits

- 🍍 **[p1neappleXpress](https://github.com/p1neappleXpress)** — author of OpenFlux. Give the [project](https://github.com/p1neappleXpress/OpenFlux) a ⭐
- 🍏 **[@saharev1](https://github.com/saharev1)** — OpenFlux iOS client
- 💡 **[eGamesAPI](https://github.com/eGamesAPI/remnawave-reverse-proxy)** — inspiration for the menu-driven installer

## License

fluxBot is [MIT](./LICENSE). OpenFlux is GPL-3.0 and is not included here — the installer downloads the official release.
