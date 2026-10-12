<h1 align="center">⚡ fluxBot</h1>

<p align="center">
  Telegram-бот для раздачи каналов <a href="https://github.com/p1neappleXpress/OpenFlux">OpenFlux</a> с админкой, апрувом и установщиком в одну команду
</p>

<p align="center">
  🇷🇺 <strong>Русский</strong> | 🇬🇧 <a href="./README-EN.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/benderobo/fluxBot/actions/workflows/check.yml"><img src="https://github.com/benderobo/fluxBot/actions/workflows/check.yml/badge.svg" alt="check" /></a>
  <img src="https://img.shields.io/badge/python-3.12-blue" alt="python" />
  <img src="https://img.shields.io/badge/aiogram-3.x-2ca5e0" alt="aiogram" />
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license" />
</p>

---

> [!CAUTION]
> **ПРОЕКТ СОЗДАН В ОБРАЗОВАТЕЛЬНЫХ ЦЕЛЯХ — ДЛЯ ИЗУЧЕНИЯ СЕТЕВЫХ ТУННЕЛЕЙ, DOCKER И TELEGRAM BOT API. ИСПОЛЬЗУЙТЕ НА СВОИХ СЕРВЕРАХ И НА СВОЙ СТРАХ И РИСК. АВТОР НЕ НЕСЁТ ОТВЕТСТВЕННОСТИ ЗА ВАШЕ ИСПОЛЬЗОВАНИЕ.**

---

## Обзор

fluxBot превращает VPS в сервис выдачи каналов OpenFlux. Пользователь присылает боту ссылку на **свой** публичный документ, админ одобряет заявку, бот поднимает для него отдельный exit-node и присылает готовый профиль — ссылкой `openflux://v1/...` и QR-кодом.

```
Пользователь ──ссылка на документ──▶ fluxBot ──апрув──▶ админ
                                        │
                                        ├─ docker run ▶ канал (exit-node) ◀──▶ Яндекс / Mail.ru
                                        │
Пользователь ◀── openflux://v1 + QR ────┘
```

Каждый канал — отдельный контейнер со своим network namespace, лимитами RAM/CPU и ротацией логов. Правило `RST DROP`, которое нужно OpenFlux, живёт только внутри контейнера и не ломает остальные сервисы на сервере.

> [!IMPORTANT]
> Поддерживаются Debian и Ubuntu, amd64 и arm64. Запуск от root. Рекомендуется отдельный чистый сервер под exit-ноды — не тот, где стоит ваша основная VPN-нода.

### Возможности

| | |
|---|---|
| 📝 **Заявки** | Пользователь присылает ссылку, админ одобряет кнопкой. Доверенным — каналы сразу |
| 🔑 **Шифрование** | Каналы с секретом (AES-256-GCM) и без — пользователь выбирает сам |
| 📲 **Профили** | Родной формат `openflux://v1` + QR — импорт в клиент в одно касание |
| 🐳 **Изоляция** | Контейнер на канал, лимиты ресурсов, `RST DROP` только внутри netns |
| 🐕 **Watchdog** | Падение канала, смена секрета, капча Яндекса, диск и RAM сервера |
| 🔄 **Обновления** | OpenFlux обновляется без разрыва каналов и потери секретов |
| 💾 **Бэкапы** | Бэкап и восстановление базы и настроек из меню |

---

## Подготовка

1. **Сервер** — VPS на Debian/Ubuntu. Ориентир по ресурсам:

   | Каналов | vCPU | RAM | Диск |
   |---|---|---|---|
   | до 5 | 1 | 1 ГБ | 10 ГБ |
   | 10–15 | 2 | 2–4 ГБ | 20 ГБ |
   | 30 | 4 | 4–6 ГБ | 40 ГБ |

   > [!TIP]
   > Для 30+ каналов лучше 2–3 сервера по 10–15 каналов, чем один большой: десятки процессов с одного IP Яндекс быстро встречает капчей.

2. **Бот** — создайте у [@BotFather](https://t.me/BotFather) и сохраните токен.
3. **Ваш Telegram ID** — узнайте у [@userinfobot](https://t.me/userinfobot).

---

## Установка

```bash
bash <(curl -Ls https://raw.githubusercontent.com/benderobo/fluxBot/main/install.sh)
```

1. Выберите **«1. Установка»**
2. Введите токен бота — скрипт сразу проверит его в Telegram
3. Введите ID админов через запятую
4. Подтвердите лимит каналов — скрипт предложит значение по объёму RAM
5. Напишите боту `/start` — придёт меню админа

Установщик сам поставит Docker, включит ротацию логов Docker и journald, скачает OpenFlux (релиз → локальный бинарник → сборка из исходников) и соберёт образ канала.

> [!NOTE]
> Быстрый запуск меню после установки: `ofbot`

---

## Меню `ofbot`

```
OPENFLUX BOT  v1.6.1
 Бот: работает   Каналов: 3/12

1. Установка
2. Управление      статус, логи, рестарт, правка .env, пересоздание каналов
3. Обновление      бот / OpenFlux / сам скрипт
4. Бэкап
5. Восстановить из бэкапа
6. Удалить
```

Команды без меню: `ofbot status | logs | restart | backup | update-of | update-bot`

---

## Использование

### Пользователь

1. Создаёт **публичный** документ:
   - **Yandex Docs** — в старом редакторе, «Поделиться → доступ по ссылке», ссылка вида `https://disk.yandex.ru/i/...`
   - **Mail.ru** — публичная ссылка `https://cloud.mail.ru/public/...`
2. Присылает ссылку боту и выбирает: 🔑 **с секретом** или 🔓 **без секрета**
3. Получает профиль ссылкой и QR-кодом, импортирует в клиент

| Команда | Описание |
|---|---|
| `/start` | Справка и кнопки клиентов |
| `/myconfig` | Прислать текущий профиль ещё раз |
| `/client` | Ссылки на клиенты OpenFlux |

### Админ

| Команда | Описание |
|---|---|
| `/users` | Список пользователей и их статусы |
| `/channels` | Активные каналы и занятые слоты |
| `/status` | Диск, RAM, нагрузка сервера |
| `/give <tg_id> <url> [secret\|nosecret]` | Выдать канал вручную |
| `/revoke <id>` | Остановить канал |
| `/ban <tg_id>` · `/unban <tg_id>` | Бан с остановкой всех каналов |
| `/decode <openflux://v1/...>` | Показать JSON любого профиля |

---

## Клиенты

| Платформа | Клиент |
|---|---|
| 🍏 iPhone / iPad | [TestFlight](https://testflight.apple.com/join/BwnAcdus) — сначала поставьте TestFlight из App Store |
| 📱 Android | [OpenFluxAndroid](https://github.com/p1neappleXpress/OpenFluxAndroid/releases) |
| 💻 Windows / Linux | [OpenFlux](https://github.com/p1neappleXpress/OpenFlux/releases) |

Список кнопок в боте меняется через `CLIENT_LINKS` в `.env`.

---

## Настройки

Файл `/opt/openflux-bot/bot/.env`. После правки: `ofbot restart`.

| Параметр | По умолчанию | Описание |
|---|---|---|
| `BOT_TOKEN` | — | Токен бота |
| `ADMIN_IDS` | — | ID админов через запятую |
| `MAX_CHANNELS` | по RAM | Максимум одновременных каналов |
| `CHANNEL_MEM` / `CHANNEL_CPUS` | `128m` / `0.3` | Лимиты на один канал |
| `SECRET_CHOICE` | `ask` | `ask` — выбор кнопкой, `always` / `never` — без выбора |
| `SECRET_DEFAULT` | `secret` | Режим для `/give` без аргумента |
| `CONFIG_FORMAT` | `openflux-v1` | Формат профиля: `openflux-v1` или `template` |
| `CONFIG_NAME` | `OpenFlux {id}` | Имя профиля в клиенте |
| `QR_ENABLED` | `1` | Слать профиль ещё и QR-кодом |
| `CLIENT_LINKS` | p1neappleXpress | Кнопки клиентов: `Название\|url;Название\|url` |
| `DISK_ALERT_PCT` / `MEM_ALERT_PCT` | `85` / `90` | Пороги алертов админу |

Полный список с комментариями — в [`bot/.env.example`](./bot/.env.example).

---

## Как устроено шифрование

Для каналов 🔑 бот генерирует секрет и передаёт его в контейнер через переменную окружения. Entrypoint записывает его в файл с правами `600`, удаляет из окружения и запускает узел с `--encryption-key-file`. В аргументах процесса секрет не виден.

Ключ AES-256-GCM выводится из секрета **и ссылки на документ** (`context`), поэтому ссылка в профиле и `--url` узла обязаны совпадать до символа. Бот берёт обе из одной записи в базе — расхождения исключены.

---

## Капча Яндекса

Узел ходит в документы со своего IP, и при большом числе каналов Яндекс начинает требовать капчу. Бот замечает её в логах канала и сразу пишет админу и владельцу канала.

Пройти капчу можно через **«Прямой канал для капчи»** в клиенте — из сети без ограничений (домашний Wi-Fi), чтобы проверка шла с IP узла.

> [!WARNING]
> Автоматическая настройка прямого канала в fluxBot пока в разработке.

---

## Обновление

| Что | Как |
|---|---|
| Код бота | `ofbot` → «Обновление» → «Обновить бота» |
| OpenFlux | `ofbot` → «Обновление» → «Обновить OpenFlux» — каналы пересоздаются с сохранением секретов |
| Скрипт | `ofbot` → «Обновление» → «Обновить сам скрипт» |
| Всё сразу | Повторный запуск установщика → «Установка» → `y` (база и `.env` сохраняются) |

---

## Безопасность

> [!IMPORTANT]
> Бот работает с `docker.sock` — это эквивалент root на сервере. Храните токен бота как root-пароль.

- `.env` создаётся с правами `600`, база и бэкапы не покидают сервер
- Закройте вход по паролю в SSH, оставьте только ключи, поставьте `fail2ban`
- Наружу на exit-сервере не нужно открывать ничего, кроме SSH

---

## Частые проблемы

<details>
<summary><b>Канал не поднимается после апрува</b></summary>

Бот пришлёт админу хвост лога. Чаще всего документ не публичный или открыт в новом редакторе Яндекса — нужен старый.
</details>

<details>
<summary><b>Клиент не подключается к каналу 🔑</b></summary>

Проверьте, что ссылка в профиле совпадает с документом до символа — лишний пробел или буква в конце ломают вывод ключа. Пересоздайте профиль через `/myconfig`.
</details>

<details>
<summary><b>Первое подключение висит</b></summary>

Это нормально: первые соединения через документ могут устанавливаться до ~5 минут.
</details>

<details>
<summary><b>Закончилось место на диске</b></summary>

`ofbot status` покажет занятость. Логи каналов и Docker ограничены установщиком, journald — 150 МБ. Если место всё равно уходит: `docker system df` и `journalctl --vacuum-size=100M`.
</details>

---

## Разработка

```
bot/            бот: aiogram 3, SQLite, Docker SDK
exit/           образ канала: OpenFlux exit-node + entrypoint
tools/          шаблон и сборщик install.sh
install.sh      генерируется — руками не править
```

Изменили `bot/` или `exit/` → `python3 tools/build.py` → коммит вместе с `install.sh`. CI проверяет, что установщик собран из актуальных исходников.

---

## Благодарности

- 🍍 **[p1neappleXpress](https://github.com/p1neappleXpress)** — автор OpenFlux. Поставьте ⭐ [проекту](https://github.com/p1neappleXpress/OpenFlux)
- 🍏 **[@saharev1](https://github.com/saharev1)** — iOS-клиент OpenFlux
- 💡 **[eGamesAPI](https://github.com/eGamesAPI/remnawave-reverse-proxy)** — за пример удобного установщика с меню

## Лицензия

Код fluxBot — [MIT](./LICENSE). OpenFlux распространяется под GPL-3.0 и в репозиторий не входит: установщик скачивает официальный релиз.


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

**User:** `/start`, `/myconfig`, `/client`, or just send a document link.

**Admin:** `/users`, `/channels`, `/status`, `/give <tg_id> <url> [secret|nosecret]`, `/revoke <id>`, `/ban` · `/unban <tg_id>`, `/decode <openflux://v1/...>`.

## Clients

| Platform | Client |
|---|---|
| 🍏 iPhone / iPad | [TestFlight](https://testflight.apple.com/join/BwnAcdus) |
| 📱 Android | [OpenFluxAndroid](https://github.com/p1neappleXpress/OpenFluxAndroid/releases) |
| 💻 Windows / Linux | [OpenFlux](https://github.com/p1neappleXpress/OpenFlux/releases) |

## Configuration

`/opt/openflux-bot/bot/.env`, apply with `ofbot restart`. All options are documented in [`bot/.env.example`](./bot/.env.example).

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
