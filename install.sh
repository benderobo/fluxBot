#!/usr/bin/env bash
# OpenFlux Bot — установщик и менеджер
# Запуск: bash <(curl -Ls https://raw.githubusercontent.com/benderobo/fluxBot/main/install.sh)
# После установки: ofbot

VERSION="1.6.1"
SCRIPT_URL="${OFBOT_SCRIPT_URL:-https://raw.githubusercontent.com/benderobo/fluxBot/main/install.sh}"
BASE=/opt/openflux-bot
BOT_DIR=$BASE/bot
EXIT_DIR=$BASE/exit
BIN_NAME=universal-bypass-tool
OF_REPO="${OFBOT_OF_REPO:-p1neappleXpress/OpenFlux}"
IMAGE=openflux-exit:local
CMD_PATH=/usr/local/bin/ofbot

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
info() { echo -e "${C}[i]${N} $*"; }
ok()   { echo -e "${G}[✓]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[✗]${N} $*" >&2; }
ask()  { local v; read -rp "$(echo -e "${Y}[?]${N} $1${2:+ [$2]}: ")" v; echo "${v:-$2}"; }
confirm() { [[ "$(ask "$1 (y/N)" n)" =~ ^[yYдД] ]]; }
pause(){ read -rp "Enter — продолжить..." _; }

need_root() { [ "$(id -u)" -eq 0 ] || { err "Запусти от root"; exit 1; }; }
installed() { [ -f "$BOT_DIR/docker-compose.yml" ]; }
cpu_arch()  { case "$(uname -m)" in x86_64) echo amd64;; aarch64|arm64) echo arm64;; *) echo unknown;; esac; }

env_get() { [ -f "$BOT_DIR/.env" ] && grep -E "^$1=" "$BOT_DIR/.env" | head -1 | cut -d= -f2-; }
env_or()  { local v; v=$(env_get "$1"); echo "${v:-$2}"; }

# ---------------- проверки и зависимости ----------------
check_os() {
  . /etc/os-release 2>/dev/null
  case "$ID" in ubuntu|debian) ;; *) warn "Проверено на Ubuntu/Debian, у тебя: ${ID:-unknown}";; esac
  [ "$(cpu_arch)" = unknown ] && { err "Неподдерживаемая архитектура $(uname -m)"; exit 1; }
}

check_disk() {
  local free; free=$(df -Pm / | awk 'NR==2{print $4}')
  if [ "$free" -lt 3072 ]; then
    warn "На / свободно ${free} МБ, рекомендуется минимум 3 ГБ"
    confirm "Продолжить всё равно?" || exit 1
  fi
}

install_deps() {
  info "Устанавливаю пакеты..."
  apt-get update -qq && apt-get install -y -qq curl jq ca-certificates tar git >/dev/null \
    || { err "apt-get не отработал"; exit 1; }
  if ! command -v docker >/dev/null 2>&1; then
    info "Устанавливаю Docker..."
    curl -fsSL https://get.docker.com | sh >/dev/null || { err "Docker не установился"; exit 1; }
  fi
  docker compose version >/dev/null 2>&1 || { err "Нет плагина docker compose"; exit 1; }
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"
}

harden_logs() {
  mkdir -p /etc/docker
  if [ ! -f /etc/docker/daemon.json ]; then
    echo '{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }' > /etc/docker/daemon.json
    if [ -n "$(docker ps -q)" ] && ! confirm "Нужен рестарт Docker (запущенные контейнеры перезапустятся). Сейчас?"; then
      warn "Ротация логов применится после рестарта Docker"
    else
      systemctl restart docker && ok "Ротация docker-логов включена"
    fi
  else
    warn "/etc/docker/daemon.json уже существует — проверь ротацию логов вручную"
  fi
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=150M\n' > /etc/systemd/journald.conf.d/size.conf
  systemctl restart systemd-journald && ok "journald ограничен 150M"
}

# ---------------- файлы ----------------
write_files() {
  mkdir -p "$BOT_DIR/data" "$EXIT_DIR"

  cat > "$BOT_DIR/bot.py" <<'OFEOF_BOTPY'
import asyncio
import base64
import html
import io
import json
import logging
import os
import re
import secrets
import shlex
import shutil
import sqlite3
import time
import urllib.parse
import zlib

import aiohttp
import docker
import qrcode
from aiogram import Bot, Dispatcher, F, Router
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.filters import Command, CommandObject, CommandStart
from aiogram.types import BufferedInputFile, CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("of-bot")

# ---------- настройки ----------
BOT_TOKEN = os.environ["BOT_TOKEN"]
ADMIN_IDS = {int(x) for x in os.environ["ADMIN_IDS"].split(",") if x.strip()}
DB_PATH = os.getenv("DB_PATH", "/data/bot.db")
OF_IMAGE = os.getenv("OF_IMAGE", "openflux-exit:local")
MAX_CHANNELS = int(os.getenv("MAX_CHANNELS", "4"))
CHANNEL_MEM = os.getenv("CHANNEL_MEM", "200m")
CHANNEL_CPUS = float(os.getenv("CHANNEL_CPUS", "0.4"))
STARTUP_WAIT = int(os.getenv("STARTUP_WAIT", "10"))
DISK_ALERT_PCT = int(os.getenv("DISK_ALERT_PCT", "85"))
MEM_ALERT_PCT = int(os.getenv("MEM_ALERT_PCT", "90"))
ARGS_TEMPLATES = {
    "yandex": os.getenv("ARGS_YANDEX", "--role=exit --transport=yandex --url {url}"),
    "mailru": os.getenv("ARGS_MAILRU", "--role=exit --transport=mailru --url {url}"),
    "vyandex": os.getenv("ARGS_VYANDEX", "--role=exit --transport=vyandex --url {url}"),
    "boards": os.getenv("ARGS_BOARDS", "--role=exit --transport=boards --url {url}"),
    # прямой TCP: узел слушает порт, который бот публикует наружу (см. PUBLIC_HOST)
    "direct": os.getenv("ARGS_DIRECT", "--role=exit --negotiate --transports=direct:50 --direct-listen=0.0.0.0:{port}"),
    # Cups.online: узел сам создаёт комнаты при старте (без --url) и печатает их список для клиента
    "cups": os.getenv("ARGS_CUPS", "--role=exit --transport=cupsonline"),
}
# Прямое TCP-подключение к серверу (без документа). Включается, только если задан PUBLIC_HOST — публичный адрес сервера.
# Адрес узла в этом режиме виден, поэтому он не маскируется; ключ шифрования обязателен.
PUBLIC_HOST = (os.getenv("PUBLIC_HOST") or "").strip()
DIRECT_PORT_MIN = int(os.getenv("DIRECT_PORT_MIN") or "20000")
DIRECT_PORT_MAX = int(os.getenv("DIRECT_PORT_MAX") or "20999")
DIRECT_CONTEXT = "http://#"  # контекст ключа узла без --url (проверено официальным --make-link и узлом)
DIRECT_PRIORITY = 50  # как directPriority в OpenFlux
# Cups.online: канал без документа, комнаты создаёт сам узел. Контекст ключа у такого узла — "http://#"
# (список комнат в контекст не входит, см. transport/kdfcontext.go в OpenFlux).
CUPS_ENABLED = (os.getenv("CUPS_ENABLED") or "1") == "1"
CUPS_TIMEOUT = int(os.getenv("CUPS_TIMEOUT") or "90")  # сколько ждать список комнат в логе узла
# каналы без ссылки на документ: ключ обязателен и передаётся через OF_SECRET, а не из лога
NO_DOC_TRANSPORTS = ("direct", "cups")
# Секрет канала
# SECRET_CHOICE: ask — пользователь выбирает кнопкой; always — всегда с секретом; never — всегда без
# SECRET_METHOD: как получить секрет для каналов «с секретом»:
#   generate — бот генерирует секрет, канал получает его через --encryption-key-file (по умолчанию)
#   log      — устаревший режим: вытащить секрет из лога exit-node регэкспом
# SECRET_DEFAULT: что выдаёт /give без явного аргумента (secret | nosecret)
_legacy_mode = (os.getenv("SECRET_MODE") or "").lower()  # совместимость с v1.2
SECRET_METHOD = (os.getenv("SECRET_METHOD") or (_legacy_mode if _legacy_mode in ("log", "generate") else "generate")).lower()
SECRET_CHOICE = (os.getenv("SECRET_CHOICE") or ("never" if _legacy_mode == "none" else "ask")).lower()
SECRET_DEFAULT = (os.getenv("SECRET_DEFAULT") or "secret").lower() == "secret"
# пусто = секрет уходит в контейнер через env OF_SECRET, entrypoint пишет его в файл
# и добавляет --encryption-key-file; задай флаг вручную, только если нужен другой способ
SECRET_ARG = os.getenv("SECRET_ARG") or ""
SECRET_TIMEOUT = int(os.getenv("SECRET_TIMEOUT") or "60")
try:
    SECRET_RE = re.compile(
        os.getenv("SECRET_REGEX")
        or r"(?i)\b(?:secret|key|psk|password|token)\b\s*[:=]\s*([A-Za-z0-9+/=_-]{8,})"
    )
except re.error as e:
    raise SystemExit(f"Плохой SECRET_REGEX: {e}")

CONFIG_TEMPLATE = os.getenv("CONFIG_TEMPLATE") or "openflux://?transport={transport}&url={url_enc}&name={name}"
# шаблон для каналов с секретом; пусто = CONFIG_TEMPLATE + секрет отдельной строкой
CONFIG_TEMPLATE_SECRET = os.getenv("CONFIG_TEMPLATE_SECRET") or ""
# Формат конфига:
#   openflux-v1 — родной формат клиентов: openflux://v1/<base64url(raw-deflate(JSON))>
#   template    — строка по CONFIG_TEMPLATE / CONFIG_TEMPLATE_SECRET
CONFIG_FORMAT = (os.getenv("CONFIG_FORMAT") or "openflux-v1").lower()
CONFIG_NAME = os.getenv("CONFIG_NAME") or "OpenFlux {id}"  # имя профиля в клиенте: {id}, {tg_id}, {transport}
TRANSPORT_TYPES = {
    "yandex": os.getenv("TYPE_YANDEX") or "yandex",
    "mailru": os.getenv("TYPE_MAILRU") or "mailru",
    "vyandex": os.getenv("TYPE_VYANDEX") or "vyandex",
    "boards": os.getenv("TYPE_BOARDS") or "boards",
    "cups": os.getenv("TYPE_CUPS") or "cupsonline",
}

# отправлять конфиг ещё и QR-кодом (iOS-клиент импортирует профили через QR)
QR_ENABLED = (os.getenv("QR_ENABLED") or "1") == "1"

# Клиенты OpenFlux. Формат CLIENT_LINKS: "Название|url;Название|url"
AUTHOR_URL = "https://github.com/p1neappleXpress"
DEFAULT_CLIENT_LINKS = (
    "🍏 iPhone / iPad (TestFlight)|https://testflight.apple.com/join/BwnAcdus;"
    "📱 Android|https://github.com/p1neappleXpress/OpenFluxAndroid/releases;"
    "💻 Windows / Linux|https://github.com/p1neappleXpress/OpenFlux/releases"
)


def parse_links(raw):
    out = []
    for item in (raw or "").split(";"):
        if "|" in item:
            label, url = (x.strip() for x in item.split("|", 1))
            if label and url.startswith("https://"):
                out.append((label, url))
    return out


CLIENT_LINKS = parse_links(os.getenv("CLIENT_LINKS")) or parse_links(DEFAULT_CLIENT_LINKS)
CREDITS = (
    f'🍍 OpenFlux — проект <a href="{AUTHOR_URL}">p1neappleXpress</a>. '
    "Респект автору — заглянь на GitHub и поставь ⭐"
)
CLIENT_TEXT = (
    "<b>📲 Клиент OpenFlux</b>\n"
    "Скачай приложение под свою платформу, затем импортируй конфиг, который пришлёт бот.\n"
    "На iPhone сначала поставь TestFlight из App Store, потом открой ссылку iOS-клиента.\n\n"
    + CREDITS
    + '\niOS-клиент — <a href="https://github.com/saharev1">@saharev1</a> 🙏'
)

# Yandex Volga (транспорт vyandex): ссылка вида https://docs.yandex.ru/edit/d/<id>.
# Шаблон взят из провижининга OpenFlux; такие же ссылки обычный транспорт yandex
# тоже может получить, поэтому автоопределение выключено по умолчанию:
#   off  — vyandex выдаётся только админом: /give <tg_id> <url> vyandex
#   auto — ссылки /edit/d/ от пользователей сразу уходят в vyandex
VYANDEX_URL_RE = re.compile(
    r"^https://(?:docs|disk)\.yandex\.(?:ru|com|by|kz|uz)/edit/d/[A-Za-z0-9_-]{16,200}/?(?:[?#]\S*)?$"
)
VYANDEX_MODE = (os.getenv("VYANDEX_MODE") or "off").lower()

def direct_enabled():
    return bool(PUBLIC_HOST) and CONFIG_FORMAT == "openflux-v1"


def cups_enabled():
    return CUPS_ENABLED


# Yandex Boards: транспорт берёт из ссылки только параметр hash (так же делает extractBoardsHash в OpenFlux)
URL_RULES = [
    (re.compile(r"^https://boards\.yandex\.ru/[^\s#]*[?&]hash=[^&\s#]{6,}[^\s#]*(?:#\S*)?$"), "boards"),
    (re.compile(r"^https://(disk|docs)\.yandex\.(ru|com)/\S+$"), "yandex"),
    (re.compile(r"^https://cloud\.mail\.ru/\S+$"), "mailru"),
]

HELP_USER = (
    "Пришли ссылку на <b>публичный</b> документ (доступ по ссылке):\n"
    "• Yandex Docs: <code>https://disk.yandex.ru/i/...</code> (старый редактор)\n"
    + ("• Yandex Docs (новый редактор): <code>https://docs.yandex.ru/edit/d/...</code>\n" if VYANDEX_MODE == "auto" else "")
    + "• Yandex Boards: <code>https://boards.yandex.ru/guest/?hash=...</code>\n"
    + "• Mail.ru: <code>https://cloud.mail.ru/public/...</code>\n\n"
    "В ответ придёт конфиг для OpenFlux.\n"
    "/myconfig — прислать мой конфиг ещё раз\n"
    "/client — скачать клиент\n"
    "/delete — удалить мой канал"
    + ("\n/direct — канал без документа: прямое TCP-подключение (адрес сервера виден)" if direct_enabled() else "")
    + ("\n/cups — канал без документа: комнаты Cups.online" if cups_enabled() else "")
)
HELP_ADMIN = (
    "<b>Админ</b>\n"
    "/users — пользователи\n"
    "/channels — каналы\n"
    "/status — состояние сервера\n"
    "/give &lt;tg_id&gt; &lt;url|direct|cups&gt; [secret|nosecret] [vyandex] — выдать канал\n"
    "/delete [channel_id] — удалить канал (с подтверждением; без номера — свои)\n"
    "/revoke &lt;channel_id&gt; — остановить канал сразу, без подтверждения\n"
    "/ban &lt;tg_id&gt; · /unban &lt;tg_id&gt;\n"
    "/decode &lt;openflux://v1/...&gt; — показать JSON профиля"
)

dk = docker.from_env()
router = Router()


# ---------- БД ----------
def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    with db() as c:
        c.executescript(
            """
            CREATE TABLE IF NOT EXISTS users(
              tg_id INTEGER PRIMARY KEY, username TEXT, name TEXT,
              status TEXT NOT NULL DEFAULT 'new', created INTEGER);
            CREATE TABLE IF NOT EXISTS channels(
              id INTEGER PRIMARY KEY AUTOINCREMENT, tg_id INTEGER NOT NULL,
              transport TEXT NOT NULL, url TEXT NOT NULL, container TEXT,
              status TEXT NOT NULL, created INTEGER);
            """
        )
        cols = {r[1] for r in c.execute("PRAGMA table_info(channels)")}
        if "secret" not in cols:
            c.execute("ALTER TABLE channels ADD COLUMN secret TEXT")
        if "started_at" not in cols:
            c.execute("ALTER TABLE channels ADD COLUMN started_at TEXT")
        if "use_secret" not in cols:
            c.execute("ALTER TABLE channels ADD COLUMN use_secret INTEGER")
        if "port" not in cols:
            c.execute("ALTER TABLE channels ADD COLUMN port INTEGER")


def q(sql, *args):
    with db() as c:
        return c.execute(sql, args).fetchall()


def q1(sql, *args):
    rows = q(sql, *args)
    return rows[0] if rows else None


def ex(sql, *args):
    with db() as c:
        return c.execute(sql, args).lastrowid


def set_channel(ch_id, status):
    ex("UPDATE channels SET status=? WHERE id=?", status, ch_id)


# ---------- утилиты ----------
def is_admin(uid):
    return uid in ADMIN_IDS


def esc(s):
    return html.escape(str(s if s is not None else ""))


def clean_link(url):
    """Без query, fragment и хвостового слеша — так ссылку нормализует и OpenFlux."""
    return re.split(r"[?#]", url, maxsplit=1)[0].rstrip("/")


def canonical_url(url, transport):
    # ссылка попадает и в --url узла, и в context профиля: обе стороны берут одну строку
    if transport == "vyandex":
        return clean_link(url)
    if transport == "boards":
        return url.split("#", 1)[0]  # query нужен (там hash), фрагмент — нет
    return url


def detect_transport(url):
    if VYANDEX_MODE == "auto" and VYANDEX_URL_RE.match(url):
        return "vyandex"
    for rx, t in URL_RULES:
        if rx.match(url):
            return t
    return None


# Сервисы документов (в первую очередь Mail.ru) режут запросы без браузерных заголовков,
# поэтому проверка ссылки представляется браузером, как это делает и сам OpenFlux.
URL_CHECK_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
    "Accept-Language": "ru-RU,ru;q=0.9,en;q=0.8",
}
# Mail.ru отдаёт заголовки длиннее лимита aiohttp по умолчанию (8190 байт): один только
# content-security-policy-report-only занимает около 9 КБ. Без этого aiohttp падает с
# ClientResponseError, хотя документ открывается.
URL_CHECK_LIMITS = {"max_line_size": 65536, "max_field_size": 65536}


async def url_check(url):
    """→ (ok, reason). reason: "HTTP 403" или имя ошибки сети; пусто, если всё хорошо."""
    try:
        timeout = aiohttp.ClientTimeout(total=15)
        async with aiohttp.ClientSession(timeout=timeout, headers=URL_CHECK_HEADERS, **URL_CHECK_LIMITS) as s:
            async with s.get(url, allow_redirects=True) as r:
                if r.status < 400:
                    return True, ""
                log.warning("url check %s -> HTTP %s", url, r.status)
                return False, f"HTTP {r.status}"
    except Exception as e:
        log.warning("url check %s failed: %s: %s", url, type(e).__name__, e)
        return False, type(e).__name__


def url_check_message(reason):
    """Понятное пользователю объяснение, почему проверка ссылки не прошла."""
    if reason in ("HTTP 404", "HTTP 410"):
        return "Документ не найден. Проверь ссылку и что файл не удалён."
    if reason.startswith("HTTP "):
        return (
            f"Сервис ответил <code>{esc(reason)}</code>. Либо документ закрыт для доступа по ссылке, "
            "либо сервис не пускает сервер бота. Проверь доступ «по ссылке» и повтори; "
            "если так и остаётся — админ увидит причину в логах бота."
        )
    if reason == "ClientResponseError":
        return (
            "Сервис ответил так, что бот не смог разобрать ответ (например, слишком длинные заголовки). "
            "Админ увидит подробности в логах бота."
        )
    return (
        f"Сервер бота не смог подключиться к сервису (<code>{esc(reason)}</code>). "
        "Возможно, он недоступен с адреса сервера. Админ увидит подробности в логах бота."
    )


# Для этих сервисов проверка ссылки не подтверждена на практике: ответ 4xx/5xx (кроме 404/410) не блокирует
# выдачу канала, а только пишется в лог. Недоступный документ всё равно виден по логам узла.
SOFT_CHECK_TRANSPORTS = {"boards"}


def check_blocks(transport, ok, reason):
    """Нужно ли отказать пользователю по результату проверки ссылки."""
    if ok:
        return False
    if transport in SOFT_CHECK_TRANSPORTS and reason.startswith("HTTP ") and reason not in ("HTTP 404", "HTTP 410"):
        log.warning("link check for %s answered %s, continuing anyway", transport, reason)
        return False
    return True


async def url_alive(url):
    return (await url_check(url))[0]


def wants_secret(ch):
    if ch["use_secret"] is None:  # каналы до v1.3
        return bool(ch["secret"])
    return bool(ch["use_secret"])


def template_for(ch):
    if wants_secret(ch) and CONFIG_TEMPLATE_SECRET:
        return CONFIG_TEMPLATE_SECRET
    return CONFIG_TEMPLATE


def encode_openflux_v1(obj):
    raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)  # raw deflate, без заголовка zlib
    data = comp.compress(raw) + comp.flush()
    return "openflux://v1/" + base64.urlsafe_b64encode(data).decode().rstrip("=")


def decode_openflux_v1(link):
    payload = link.strip().split("openflux://v1/", 1)[1]
    data = base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4))
    return json.loads(zlib.decompress(data, -15))


def secret_embedded(ch):
    if CONFIG_FORMAT == "openflux-v1":
        return True  # секрет зашит в ссылку (поле secret + context)
    return "{secret" in template_for(ch)


def build_config(ch):
    if CONFIG_FORMAT == "openflux-v1":
        name = CONFIG_NAME.format(id=ch["id"], tg_id=ch["tg_id"], transport=ch["transport"])
        obj = {"name": name}
        if ch["transport"] == "direct":
            # сессия с проверкой участников: ключ обязателен, context — по умолчанию узла без --url
            obj.update(negotiate=True, secret=ch["secret"], context=DIRECT_CONTEXT)
            obj["transports"] = [{"type": "direct", "dial": ch["url"], "priority": DIRECT_PRIORITY}]
            return encode_openflux_v1(obj)
        if ch["transport"] == "cups":
            # комнаты создал узел; ключ выводится из секрета и контекста "http://#" (не из списка комнат)
            obj.update(secret=ch["secret"], context=DIRECT_CONTEXT)
            obj["transports"] = [{"type": TRANSPORT_TYPES["cups"], "url": ch["url"]}]
            return encode_openflux_v1(obj)
        if wants_secret(ch) and ch["secret"]:
            # AES-256-GCM: ключ выводится из секрета и ссылки на документ (context),
            # поэтому context обязан совпадать с --url канала до символа
            obj["secret"] = ch["secret"]
            obj["context"] = ch["url"]
        obj["transports"] = [{"type": TRANSPORT_TYPES.get(ch["transport"], ch["transport"]), "url": ch["url"]}]
        return encode_openflux_v1(obj)
    return build_template_config(ch)


def build_template_config(ch):
    secret = (ch["secret"] or "") if wants_secret(ch) else ""
    return template_for(ch).format(
        transport=ch["transport"],
        url=ch["url"],
        url_enc=urllib.parse.quote(ch["url"], safe=""),
        name=f"of-{ch['tg_id']}-{ch['id']}",
        secret=secret,
        secret_enc=urllib.parse.quote(secret, safe=""),
    )


def config_link_message(ch):
    """Ссылка/конфиг одним отдельным сообщением — ничего лишнего, чтобы её было удобно копировать и пересылать."""
    return f"<code>{esc(build_config(ch))}</code>"


def config_head(ch, head):
    text = head
    # секрет всегда виден отдельно, даже если шаблон его не содержит
    if wants_secret(ch) and ch["secret"] and not secret_embedded(ch):
        text += f"\n\n🔑 Секрет: <code>{esc(ch['secret'])}</code>"
    return text


def qr_png(data):
    img = qrcode.make(data, box_size=8, border=2)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


async def send_config(bot: Bot, ch, head, tail="", kb=None):
    """QR, пояснение, ссылка ОТДЕЛЬНЫМ сообщением, затем хвост с кнопками (кнопки остаются последними)."""
    if QR_ENABLED:
        try:
            await bot.send_photo(
                ch["tg_id"],
                BufferedInputFile(qr_png(build_config(ch)), filename=f"openflux-{ch['id']}.png"),
                caption="📷 QR для импорта в клиент",
            )
        except Exception as e:
            log.warning("QR for channel %s failed: %s", ch["id"], e)
    await notify_user(bot, ch["tg_id"], config_head(ch, head))
    tail = tail.strip()
    await notify_user(bot, ch["tg_id"], config_link_message(ch), None if tail else kb)
    if tail:
        await notify_user(bot, ch["tg_id"], tail, kb)


def find_secret(logs):
    found = SECRET_RE.findall(logs or "")
    if not found:
        return None
    last = found[-1]
    return last if isinstance(last, str) else next((g for g in last if g), None)


# узел Cups.online при старте создаёт комнаты и печатает их одной строкой base64url(JSON-список uuid)
CUPS_ROOMS_RE = re.compile(r"=== COPY THIS TO CLIENT ===\s*\r?\n\s*([A-Za-z0-9_-]{8,4096})\s*\r?\n\s*=+")


def find_cups_rooms(logs):
    """Последний напечатанный узлом список комнат или None. Проверяет, что внутри JSON-список uuid."""
    for packed in reversed(CUPS_ROOMS_RE.findall(logs or "")):
        try:
            ids = json.loads(base64.urlsafe_b64decode(packed + "=" * (-len(packed) % 4)))
        except Exception:
            continue
        if isinstance(ids, list) and ids and all(isinstance(i, str) and re.fullmatch(r"[0-9a-fA-F-]{36}", i) for i in ids):
            return packed
    return None


def upsert_user(m: Message):
    u = m.from_user
    ex(
        "INSERT INTO users(tg_id, username, name, created) VALUES(?,?,?,?) "
        "ON CONFLICT(tg_id) DO UPDATE SET username=excluded.username, name=excluded.name",
        u.id, u.username, u.full_name, int(time.time()),
    )
    return q1("SELECT * FROM users WHERE tg_id=?", u.id)


async def notify_admins(bot: Bot, text, kb=None):
    for a in ADMIN_IDS:
        try:
            await bot.send_message(a, text, reply_markup=kb)
        except Exception as e:
            log.warning("notify admin %s failed: %s", a, e)


def kb_clients():
    rows = [[InlineKeyboardButton(text=label, url=url)] for label, url in CLIENT_LINKS]
    rows.append([InlineKeyboardButton(text="⭐ p1neappleXpress на GitHub", url=AUTHOR_URL)])
    return InlineKeyboardMarkup(inline_keyboard=rows)


async def notify_user(bot: Bot, tg_id, text, kb=None):
    try:
        await bot.send_message(tg_id, text, reply_markup=kb)
    except Exception as e:
        log.warning("notify user %s failed: %s", tg_id, e)


# ---------- docker ----------
def strip_secret_tokens(toks):
    """Убрать из аргументов флаг секрета вместе со значением (для каналов без секрета)."""
    out = []
    for t in toks:
        if "{secret}" in t:
            if t == "{secret}" and out and out[-1].startswith("-"):
                out.pop()
            continue
        out.append(t)
    return out


def _run_container(ch, secret=None):
    name = f"of-u{ch['tg_id']}-c{ch['id']}"
    tpl = ARGS_TEMPLATES[ch["transport"]]
    toks = shlex.split(tpl)
    if not secret:
        toks = strip_secret_tokens(toks)
    fmt = {"url": ch["url"], "secret": secret or "", "port": ch["port"]}
    args = [t.format(**fmt) for t in toks]
    env = {}
    direct = ch["transport"] == "direct"
    if secret and (SECRET_METHOD == "generate" or ch["transport"] in NO_DOC_TRANSPORTS) and "{secret}" not in tpl:
        if SECRET_ARG:
            args += [t.format(**fmt) for t in shlex.split(SECRET_ARG)]
        else:
            env["OF_SECRET"] = secret  # entrypoint → файл → --encryption-key-file
    dk.containers.run(
        OF_IMAGE,
        command=args,
        environment=env,
        name=name,
        detach=True,
        cap_add=["NET_ADMIN", "NET_RAW"],
        mem_limit=CHANNEL_MEM,
        nano_cpus=int(CHANNEL_CPUS * 1e9),
        restart_policy={"Name": "unless-stopped"},
        log_config=docker.types.LogConfig(
            type="json-file", config={"max-size": "10m", "max-file": "2"}
        ),
        labels={"openflux.bot": "1", "openflux.channel": str(ch["id"])},
        ports={f"{ch['port']}/tcp": ch["port"]} if direct else None,
    )
    return name


def _container_state(name, tail=15):
    if not name:
        return "missing", "", None
    try:
        c = dk.containers.get(name)
        c.reload()
        return c.status, c.logs(tail=tail).decode(errors="replace"), c.attrs["State"].get("StartedAt")
    except docker.errors.NotFound:
        return "missing", "", None


async def wait_secret(name):
    deadline = time.monotonic() + SECRET_TIMEOUT
    while time.monotonic() < deadline:
        status, logs, _ = await asyncio.to_thread(_container_state, name, 300)
        secret = find_secret(logs)
        if secret:
            return secret, logs
        if status != "running":
            return None, logs
        await asyncio.sleep(3)
    return None, logs


async def wait_cups_rooms(name):
    deadline = time.monotonic() + CUPS_TIMEOUT
    logs = ""
    while time.monotonic() < deadline:
        status, logs, _ = await asyncio.to_thread(_container_state, name, 300)
        rooms = find_cups_rooms(logs)
        if rooms:
            return rooms, logs
        if status != "running":
            return None, logs
        await asyncio.sleep(3)
    return None, logs


# Настоящие признаки капчи/входа Яндекса — тексты ошибок OpenFlux ("yandex docs: captcha required",
# "captcha solve: ...", "yandex docs: login required"). Само слово «captcha» признаком НЕ является: оно есть в общей
# подсказке ядра "no carrier is connected on this side (document unreachable, captcha, or network)", которая
# выводится при любой потере связи с документом, в том числе у Mail.ru, где капчи нет.
CAPTCHA_MARKERS = ("captcha required", "captcha solve:", "login required")
YANDEX_TRANSPORTS = {"yandex", "vyandex", "boards"}
# Признаки того, что узел не подключён к документу (строки уровня Info, видны без отладки)
NO_CARRIER_MARKERS = ("no carrier is connected", "cannot open the document")
CARRIER_ALERT_TICKS = 2  # столько проверок подряд (по минуте), прежде чем предупреждать админа
CARRIER_CLEAR_TICKS = 2


def has_captcha(transport, logs):
    return transport in YANDEX_TRANSPORTS and any(mk in (logs or "").lower() for mk in CAPTCHA_MARKERS)


def carrier_down(logs):
    return any(mk in (logs or "").lower() for mk in NO_CARRIER_MARKERS)


def carrier_detail(logs):
    """Последняя строка лога про отсутствие связи с документом — для сообщения админу."""
    lines = [ln for ln in (logs or "").splitlines() if any(mk in ln.lower() for mk in NO_CARRIER_MARKERS)]
    return lines[-1].strip()[-300:] if lines else ""


class CarrierTracker:
    """Отличает «связи с документом нет уже несколько минут» от разовой строки в логе (дребезга):
    update() → "alert" после ALERT подряд плохих проверок, "clear" после CLEAR подряд хороших, иначе None."""

    def __init__(self, alert_ticks=CARRIER_ALERT_TICKS, clear_ticks=CARRIER_CLEAR_TICKS):
        self.alert_ticks, self.clear_ticks = alert_ticks, clear_ticks
        self.bad, self.good, self.alerted = {}, {}, set()

    def update(self, ch_id, down):
        if down:
            self.good.pop(ch_id, None)
            self.bad[ch_id] = self.bad.get(ch_id, 0) + 1
            if self.bad[ch_id] >= self.alert_ticks and ch_id not in self.alerted:
                self.alerted.add(ch_id)
                return "alert"
        else:
            self.bad.pop(ch_id, None)
            if ch_id in self.alerted:
                self.good[ch_id] = self.good.get(ch_id, 0) + 1
                if self.good[ch_id] >= self.clear_ticks:
                    self.alerted.discard(ch_id)
                    self.good.pop(ch_id, None)
                    return "clear"
        return None

    def forget(self, ch_id):
        self.bad.pop(ch_id, None)
        self.good.pop(ch_id, None)
        self.alerted.discard(ch_id)


def _recent_logs(name, seconds=180):
    try:
        c = dk.containers.get(name)
        return c.logs(since=int(time.time()) - seconds).decode(errors="replace")
    except docker.errors.NotFound:
        return ""


def _remove_container(name):
    if not name:
        return
    try:
        dk.containers.get(name).remove(force=True)
    except docker.errors.NotFound:
        pass


def allocate_port(ch_id):
    """Свободный порт из диапазона для прямого канала; сохраняет его и адрес host:port в записи. None, если порты кончились."""
    used = {r["port"] for r in q("SELECT port FROM channels WHERE port IS NOT NULL AND status IN ('running','pending')")}
    for p in range(DIRECT_PORT_MIN, DIRECT_PORT_MAX + 1):
        if p not in used:
            ex("UPDATE channels SET port=?, url=? WHERE id=?", p, f"{PUBLIC_HOST}:{p}", ch_id)
            return p
    return None


async def stop_channel(ch):
    await asyncio.to_thread(_remove_container, ch["container"])
    set_channel(ch["id"], "stopped")


async def delete_channel(ch):
    """Удалить канал: запущенный останавливается, ожидающий заявку — снимается. → итоговый статус."""
    if ch["status"] == "pending":
        # контейнер мог уже создаться (канал стартует), поэтому убираем и его
        await asyncio.to_thread(_remove_container, ch["container"])
        set_channel(ch["id"], "cancelled")
        ex("UPDATE users SET status='new' WHERE tg_id=? AND status='pending'", ch["tg_id"])
        return "cancelled"
    await stop_channel(ch)
    return "stopped"


# ---------- жизненный цикл канала ----------
async def provision(bot: Bot, ch_id):
    try:
        ch = q1("SELECT * FROM channels WHERE id=?", ch_id)
        if not ch or ch["status"] != "pending":
            return  # заявку успели удалить или отклонить
        olds = q("SELECT * FROM channels WHERE tg_id=? AND status='running' AND id<>?", ch["tg_id"], ch_id)
        running = q1("SELECT COUNT(*) AS n FROM channels WHERE status='running'")["n"]
        if running - len(olds) >= MAX_CHANNELS:
            set_channel(ch_id, "failed")
            await notify_user(bot, ch["tg_id"], "Сейчас нет свободных слотов, попробуй позже.")
            await notify_admins(bot, f"⚠️ Лимит каналов ({MAX_CHANNELS}) исчерпан, заявка #{ch_id} не запущена.")
            return

        if ch["transport"] == "direct":
            if not PUBLIC_HOST or allocate_port(ch_id) is None:
                set_channel(ch_id, "failed")
                await notify_user(bot, ch["tg_id"], "Сейчас нельзя выдать прямой канал, попробуй позже.")
                await notify_admins(bot, f"⚠️ Прямой канал #{ch_id}: нет PUBLIC_HOST или свободных портов {DIRECT_PORT_MIN}-{DIRECT_PORT_MAX}.")
                return
            ch = q1("SELECT * FROM channels WHERE id=?", ch_id)
        use_secret = wants_secret(ch)
        secret = secrets.token_urlsafe(24) if use_secret and (SECRET_METHOD == "generate" or ch["transport"] in NO_DOC_TRANSPORTS) else None
        name = await asyncio.to_thread(_run_container, ch, secret)
        ex("UPDATE channels SET container=? WHERE id=?", name, ch_id)
        await asyncio.sleep(STARTUP_WAIT)
        status, logs, started_at = await asyncio.to_thread(_container_state, name)

        cur = q1("SELECT status FROM channels WHERE id=?", ch_id)
        if not cur or cur["status"] != "pending":  # канал удалили, пока он запускался
            await asyncio.to_thread(_remove_container, name)
            return

        if status == "running" and ch["transport"] == "cups":
            rooms, logs = await wait_cups_rooms(name)
            if not rooms:
                await asyncio.to_thread(_remove_container, name)
                set_channel(ch_id, "failed")
                await notify_user(bot, ch["tg_id"], "Не удалось создать комнаты Cups.online. Админ уже разбирается.")
                await notify_admins(
                    bot,
                    f"❌ Канал #{ch_id} (cups): список комнат не появился в логе за {CUPS_TIMEOUT}с "
                    "(проверь, что сервер открывает interview.cups.online). Хвост лога:\n"
                    f"<pre>{esc(logs[-1500:])}</pre>",
                )
                return
            ex("UPDATE channels SET url=? WHERE id=?", rooms, ch_id)
            ch = q1("SELECT * FROM channels WHERE id=?", ch_id)
        if status == "running" and use_secret and SECRET_METHOD == "log" and ch["transport"] not in NO_DOC_TRANSPORTS:
            secret, logs = await wait_secret(name)
            if not secret:
                await asyncio.to_thread(_remove_container, name)
                set_channel(ch_id, "failed")
                await notify_user(bot, ch["tg_id"], "Канал запустился, но не удалось получить секрет. Админ уже разбирается.")
                await notify_admins(
                    bot,
                    f"🔑 Канал #{ch_id}: секрет не найден в логах за {SECRET_TIMEOUT}с.\n"
                    "Проверь SECRET_REGEX (или переключи SECRET_METHOD=generate) в .env. Хвост лога:\n"
                    f"<pre>{esc(logs[-1500:])}</pre>",
                )
                return

        if status != "running":
            await asyncio.to_thread(_remove_container, name)
            set_channel(ch_id, "failed")
            await notify_user(bot, ch["tg_id"], "Канал не поднялся. Проверь, что документ публичный, и пришли ссылку ещё раз.")
            await notify_admins(bot, f"❌ Канал #{ch_id} ({ch['tg_id']}) упал на старте, status={status}\n<pre>{esc(logs[-1500:])}</pre>")
            return

        ex("UPDATE channels SET status='running', secret=?, started_at=? WHERE id=?", secret, started_at, ch_id)
        for o in olds:  # старый канал гасим только после успешного старта нового
            await stop_channel(o)

        ch = q1("SELECT * FROM channels WHERE id=?", ch_id)
        await send_config(
            bot, ch, "✅ Канал готов. Импортируй в OpenFlux:",
            "\n\nНет клиента? Скачай по кнопкам ниже.\n\n" + CREDITS,
            kb_clients(),
        )
        await notify_admins(bot, f"✅ Канал #{ch_id} для <code>{ch['tg_id']}</code> запущен ({ch['transport']}, {lock_icon(ch)})")
    except Exception as e:
        log.exception("provision %s", ch_id)
        set_channel(ch_id, "failed")
        await notify_admins(bot, f"❌ Канал #{ch_id}: ошибка\n<pre>{esc(e)}</pre>")


async def ban_user(bot: Bot, tg_id):
    ex("UPDATE users SET status='banned' WHERE tg_id=?", tg_id)
    for ch in q("SELECT * FROM channels WHERE tg_id=? AND status IN ('running','pending')", tg_id):
        await stop_channel(ch)


def host_stats():
    du = shutil.disk_usage(os.path.dirname(DB_PATH) or "/")
    mem = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":", 1)
            mem[k] = int(v.split()[0])
    mem_pct = 100 - mem["MemAvailable"] * 100 // mem["MemTotal"]
    disk_pct = du.used * 100 // du.total
    with open("/proc/loadavg") as f:
        load = f.read().split()[0]
    return {
        "disk_pct": disk_pct, "disk_free_gb": round(du.free / 2**30, 1),
        "mem_pct": mem_pct, "mem_total_mb": mem["MemTotal"] // 1024, "load": load,
    }


async def check_channel_logs(bot, ch, recent, last_minute, captcha_alerted, carrier):
    """Разбирает логи работающего канала: настоящая капча Яндекса и потеря связи с документом."""
    captcha = has_captcha(ch["transport"], recent)
    if captcha and ch["id"] not in captcha_alerted:
        captcha_alerted.add(ch["id"])
        await notify_admins(
            bot,
            f"🧩 Канал #{ch['id']} ({ch['tg_id']}, {ch['transport']}): Яндекс требует капчу или вход для IP узла.\n"
            "Пока это не пройдено, канал не передаёт трафик.",
        )
        await notify_user(
            bot, ch["tg_id"],
            "🧩 Яндекс попросил капчу для твоего канала, пока он может не работать. Админ в курсе.",
        )
    elif not captcha and ch["id"] in captcha_alerted:
        captcha_alerted.discard(ch["id"])
        await notify_admins(bot, f"✅ Канал #{ch['id']}: признаков капчи в логах больше нет")

    # связь с документом: предупреждаем только админа и только если это длится, а не одна строка в логе.
    # Если уже есть настоящая капча — отдельное сообщение не нужно, причина понятна.
    down = (not captcha) and carrier_down(last_minute)
    event = carrier.update(ch["id"], down)
    if event == "alert":
        detail = carrier_detail(last_minute)
        await notify_admins(
            bot,
            f"🔌 Канал #{ch['id']} ({ch['tg_id']}, {ch['transport']}) не подключён к документу уже несколько минут.\n"
            "Проверьте, что ссылка открыта, документ не удалён и на нём нет второго узла (один документ — одно устройство). "
            "Подробности — в логах контейнера."
            + (f"\n<pre>{esc(detail)}</pre>" if detail else ""),
        )
    elif event == "clear":
        await notify_admins(bot, f"✅ Канал #{ch['id']}: связь с документом восстановилась")


async def refresh_after_restart(bot: Bot, ch, logs, started_at):
    """Контейнер перезапускался (краш, ребут, обновление OpenFlux): подхватить новый секрет или новые комнаты Cups.online."""
    if ch["transport"] == "cups":
        # без --url узел при каждом старте создаёт новые комнаты, старая строка в профиле перестаёт работать
        rooms = find_cups_rooms(logs)
        if not rooms:
            return  # список ещё не напечатан — проверим через минуту
        ex("UPDATE channels SET url=?, started_at=? WHERE id=?", rooms, started_at, ch["id"])
        if rooms != ch["url"]:
            ch = q1("SELECT * FROM channels WHERE id=?", ch["id"])
            await send_config(bot, ch, "🔄 Канал перезапустился и создал новые комнаты Cups.online. Старый профиль больше не работает, импортируй новый:")
            await notify_admins(bot, f"🔄 Канал #{ch['id']} (cups): комнаты обновлены и отправлены пользователю")
        return
    from_log = wants_secret(ch) and SECRET_METHOD == "log"
    new_secret = find_secret(logs) if from_log else ch["secret"]
    if from_log and not new_secret:
        return  # секрет ещё не напечатан — проверим через минуту
    ex("UPDATE channels SET secret=?, started_at=? WHERE id=?", new_secret, started_at, ch["id"])
    if new_secret != ch["secret"]:
        ch = q1("SELECT * FROM channels WHERE id=?", ch["id"])
        await send_config(bot, ch, "🔄 Канал перезапустился и сменил секрет. Новый конфиг:")
        await notify_admins(bot, f"🔄 Канал #{ch['id']}: секрет обновлён и отправлен пользователю")


async def watchdog(bot: Bot):
    alerted = {"disk": False, "mem": False}
    captcha_alerted = set()  # id каналов, по которым уже предупредили
    carrier = CarrierTracker()
    while True:
        await asyncio.sleep(60)
        try:
            running = q("SELECT * FROM channels WHERE status='running'")
            for gone in {i for i in (*carrier.bad, *carrier.good, *carrier.alerted, *captcha_alerted)} - {r["id"] for r in running}:
                carrier.forget(gone)  # канал остановили или удалили — не копим состояние
                captcha_alerted.discard(gone)
            for ch in running:
                status, logs, started_at = await asyncio.to_thread(_container_state, ch["container"], 300)
                if status != "running":
                    set_channel(ch["id"], "failed")
                    await notify_user(bot, ch["tg_id"], "⚠️ Твой канал перестал работать. Пришли ссылку на документ заново.")
                    await notify_admins(bot, f"⚠️ Канал #{ch['id']} ({ch['tg_id']}) упал: {status}\n<pre>{esc(logs[-1500:])}</pre>")
                    continue

                recent = await asyncio.to_thread(_recent_logs, ch["container"])
                last_minute = await asyncio.to_thread(_recent_logs, ch["container"], 60)
                await check_channel_logs(bot, ch, recent, last_minute, captcha_alerted, carrier)
                if started_at and started_at != ch["started_at"]:
                    await refresh_after_restart(bot, ch, logs, started_at)

            st = host_stats()
            for key, pct, limit in (("disk", st["disk_pct"], DISK_ALERT_PCT), ("mem", st["mem_pct"], MEM_ALERT_PCT)):
                if pct >= limit and not alerted[key]:
                    alerted[key] = True
                    await notify_admins(bot, f"🔥 {key}: {pct}% (порог {limit}%)")
                elif pct < limit - 5 and alerted[key]:
                    alerted[key] = False
                    await notify_admins(bot, f"✅ {key} в норме: {pct}%")
        except Exception:
            log.exception("watchdog")


# ---------- пользователь ----------
def kb_secret(ch_id):
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="🔑 С секретом", callback_data=f"sec:{ch_id}:1"),
        InlineKeyboardButton(text="🔓 Без секрета", callback_data=f"sec:{ch_id}:0"),
    ]])


def lock_icon(ch):
    return "🔑" if wants_secret(ch) else "🔓"


async def submit_channel(bot: Bot, ch_id):
    """Канал с выбранным режимом: одобренным — сразу запуск, остальным — на ревью."""
    ch = q1("SELECT * FROM channels WHERE id=?", ch_id)
    u = q1("SELECT * FROM users WHERE tg_id=?", ch["tg_id"])
    if u["status"] == "approved":
        await notify_user(bot, ch["tg_id"], "Запускаю канал, это ~15 секунд…")
        asyncio.create_task(provision(bot, ch_id))
        return
    ex("UPDATE users SET status='pending' WHERE tg_id=?", u["tg_id"])
    await notify_user(bot, ch["tg_id"], "Заявка отправлена админу. Конфиг придёт после одобрения.")
    await notify_admins(
        bot,
        f"🆕 Заявка #{ch_id}\nОт: {esc(u['name'])} @{esc(u['username'])} (<code>{u['tg_id']}</code>)\n"
        f"Транспорт: {ch['transport']} · {lock_icon(ch)} {'с секретом' if wants_secret(ch) else 'без секрета'}\n{esc(ch['url'])}",
        kb_review(ch_id, u["tg_id"]),
    )


def kb_review(ch_id, tg_id):
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Одобрить", callback_data=f"ap:{ch_id}"),
        InlineKeyboardButton(text="❌ Отклонить", callback_data=f"rj:{ch_id}"),
        InlineKeyboardButton(text="⛔ Бан", callback_data=f"ban:{tg_id}"),
    ]])


@router.message(CommandStart())
async def cmd_start(m: Message):
    u = upsert_user(m)
    if u["status"] == "banned":
        return
    text = HELP_USER
    if u["status"] != "approved":
        text += "\n\nПервую заявку проверит админ."
    if is_admin(m.from_user.id):
        text += "\n\n" + HELP_ADMIN
    await m.answer(text)
    await m.answer(CLIENT_TEXT, reply_markup=kb_clients())


@router.message(Command("myconfig"))
async def cmd_myconfig(m: Message, bot: Bot):
    u = upsert_user(m)
    if u["status"] == "banned":
        return
    ch = q1("SELECT * FROM channels WHERE tg_id=? AND status='running' ORDER BY id DESC LIMIT 1", u["tg_id"])
    if not ch:
        await m.answer("Активного канала нет. Пришли ссылку на документ.")
        return
    await send_config(bot, ch, "Твой текущий конфиг:")


@router.message(Command("client"))
async def cmd_client(m: Message):
    upsert_user(m)
    await m.answer(CLIENT_TEXT, reply_markup=kb_clients())


@router.message(F.text.regexp(r"^https://"))
async def on_link(m: Message, bot: Bot):
    u = upsert_user(m)
    if u["status"] == "banned":
        return
    url = m.text.strip().split()[0]
    transport = detect_transport(url)
    if not transport:
        await m.answer("Не узнаю ссылку.\n\n" + HELP_USER)
        return
    url = canonical_url(url, transport)
    # незавершённый выбор секрета заменяется новой ссылкой
    ex("UPDATE channels SET status='cancelled' WHERE tg_id=? AND status='choosing'", u["tg_id"])
    if q1("SELECT id FROM channels WHERE tg_id=? AND status='pending'", u["tg_id"]):
        await m.answer("У тебя уже есть заявка на рассмотрении.")
        return
    await m.answer("Проверяю ссылку…")
    ok, reason = await url_check(url)
    if check_blocks(transport, ok, reason):
        await m.answer(url_check_message(reason))
        return

    if SECRET_CHOICE == "ask":
        ch_id = ex(
            "INSERT INTO channels(tg_id, transport, url, status, created) VALUES(?,?,?,'choosing',?)",
            u["tg_id"], transport, url, int(time.time()),
        )
        await m.answer(
            "Как настроить канал?\n\n"
            "🔑 <b>С секретом</b> — подключиться можно только зная секрет. Надёжнее.\n"
            "🔓 <b>Без секрета</b> — хватает ссылки на документ. Проще, но кто знает ссылку — тот подключится.",
            reply_markup=kb_secret(ch_id),
        )
        return

    ch_id = ex(
        "INSERT INTO channels(tg_id, transport, url, status, created, use_secret) VALUES(?,?,?,'pending',?,?)",
        u["tg_id"], transport, url, int(time.time()), 1 if SECRET_CHOICE == "always" else 0,
    )
    await submit_channel(bot, ch_id)


@router.callback_query(F.data.startswith("sec:"))
async def cb_secret(c: CallbackQuery, bot: Bot):
    _, ch_id, val = c.data.split(":")
    ch = q1("SELECT * FROM channels WHERE id=?", int(ch_id))
    if not ch or ch["tg_id"] != c.from_user.id or ch["status"] != "choosing":
        await c.answer("Уже неактуально")
        return
    if q1("SELECT id FROM channels WHERE tg_id=? AND status='pending'", ch["tg_id"]):
        await c.answer("Уже есть заявка на рассмотрении", show_alert=True)
        return
    ex("UPDATE channels SET use_secret=?, status='pending' WHERE id=?", int(val), ch["id"])
    await c.message.edit_text("Выбрано: " + ("🔑 с секретом" if val == "1" else "🔓 без секрета"))
    await c.answer()
    await submit_channel(bot, ch["id"])


# ---------- кнопки админа ----------
@router.callback_query(F.data.startswith("ap:"))
async def cb_approve(c: CallbackQuery, bot: Bot):
    if not is_admin(c.from_user.id):
        await c.answer()
        return
    ch = q1("SELECT * FROM channels WHERE id=?", int(c.data[3:]))
    if not ch or ch["status"] != "pending":
        await c.answer("Уже обработано")
        return
    ex("UPDATE users SET status='approved' WHERE tg_id=?", ch["tg_id"])
    await c.message.edit_text(c.message.html_text + "\n\n✅ Одобрено")
    await c.answer()
    await notify_user(bot, ch["tg_id"], "Заявка одобрена, запускаю канал…")
    asyncio.create_task(provision(bot, ch["id"]))


@router.callback_query(F.data.startswith("rj:"))
async def cb_reject(c: CallbackQuery, bot: Bot):
    if not is_admin(c.from_user.id):
        await c.answer()
        return
    ch = q1("SELECT * FROM channels WHERE id=?", int(c.data[3:]))
    if not ch or ch["status"] != "pending":
        await c.answer("Уже обработано")
        return
    set_channel(ch["id"], "rejected")
    ex("UPDATE users SET status='new' WHERE tg_id=? AND status='pending'", ch["tg_id"])
    await c.message.edit_text(c.message.html_text + "\n\n❌ Отклонено")
    await c.answer()
    await notify_user(bot, ch["tg_id"], "Заявка отклонена.")


@router.callback_query(F.data.startswith("ban:"))
async def cb_ban(c: CallbackQuery, bot: Bot):
    if not is_admin(c.from_user.id):
        await c.answer()
        return
    await ban_user(bot, int(c.data[4:]))
    await c.message.edit_text(c.message.html_text + "\n\n⛔ Забанен")
    await c.answer()


# ---------- команды админа ----------
@router.message(Command("status"))
async def cmd_status(m: Message):
    if not is_admin(m.from_user.id):
        return
    st = host_stats()
    running = q1("SELECT COUNT(*) AS n FROM channels WHERE status='running'")["n"]
    await m.answer(
        f"Каналы: {running}/{MAX_CHANNELS}\n"
        f"Диск: {st['disk_pct']}% (свободно {st['disk_free_gb']} ГБ)\n"
        f"RAM: {st['mem_pct']}% из {st['mem_total_mb']} МБ\n"
        f"Load: {st['load']}"
    )


@router.message(Command("decode"))
async def cmd_decode(m: Message, command: CommandObject):
    if not is_admin(m.from_user.id):
        return
    link = (command.args or "").strip()
    if not link.startswith("openflux://v1/"):
        await m.answer("Формат: /decode openflux://v1/...")
        return
    try:
        obj = decode_openflux_v1(link)
    except Exception as e:
        await m.answer(f"Не удалось разобрать: {esc(e)}")
        return
    await m.answer(f"<pre>{esc(json.dumps(obj, ensure_ascii=False, indent=2))}</pre>")


@router.message(Command("users"))
async def cmd_users(m: Message):
    if not is_admin(m.from_user.id):
        return
    rows = q(
        "SELECT u.*, (SELECT COUNT(*) FROM channels c WHERE c.tg_id=u.tg_id AND c.status='running') AS active "
        "FROM users u ORDER BY created DESC LIMIT 40"
    )
    lines = [
        f"<code>{r['tg_id']}</code> {esc(r['name'])} @{esc(r['username'])} — {r['status']}, каналов: {r['active']}"
        for r in rows
    ]
    await m.answer("\n".join(lines) or "Пусто")


@router.message(Command("channels"))
async def cmd_channels(m: Message):
    if not is_admin(m.from_user.id):
        return
    rows = q("SELECT * FROM channels WHERE status IN ('running','pending') ORDER BY id DESC LIMIT 40")
    lines = [
        f"#{r['id']} <code>{r['tg_id']}</code> {r['transport']} — {r['status']} {esc(r['container'])}"
        + " " + lock_icon(r)
        for r in rows
    ]
    total = q1("SELECT COUNT(*) AS n FROM channels WHERE status='running'")["n"]
    await m.answer(
        f"Запущено: {total}/{MAX_CHANNELS}\n\n" + ("\n".join(lines) or "Нет активных"),
        reply_markup=kb_delete_list(rows[:20]) if rows else None,
    )


GIVE_USAGE = "Формат: /give &lt;tg_id&gt; &lt;url|direct|cups&gt; [secret|nosecret] [vyandex]"


def parse_give(args):
    """/give <tg_id> <url> [secret|nosecret] [vyandex] → ((tg_id, url, use_secret, transport), None) или (None, ошибка)."""
    parts = (args or "").split()
    if len(parts) >= 2 and parts[0].isdigit() and parts[1].lower() in NO_DOC_TRANSPORTS:
        # канал без ссылки (direct, cups): ключ обязателен (nosecret недопустим)
        if any(f != "secret" for f in parts[2:]) or len(parts) > 3:
            return None, GIVE_USAGE
        kind = parts[1].lower()
        return (int(parts[0]), kind, True, kind), None
    flags = parts[2:]
    allowed = {"secret", "nosecret", "vyandex"}
    if (
        len(parts) < 2 or not parts[0].isdigit()
        or any(f not in allowed for f in flags) or len(set(flags)) != len(flags)
        or {"secret", "nosecret"} <= set(flags)
    ):
        return None, GIVE_USAGE
    url = parts[1]
    if {"secret", "nosecret"} & set(flags):
        use_secret = "secret" in flags
    else:
        use_secret = SECRET_DEFAULT
    if "vyandex" in flags:
        if not VYANDEX_URL_RE.match(url):
            return None, "Для vyandex нужна ссылка вида https://docs.yandex.ru/edit/d/…"
        transport = "vyandex"
    else:
        transport = detect_transport(url)
        if not transport:
            return None, "Не узнаю ссылку."
    return (int(parts[0]), canonical_url(url, transport), use_secret, transport), None


@router.message(Command("give"))
async def cmd_give(m: Message, command: CommandObject, bot: Bot):
    if not is_admin(m.from_user.id):
        return
    parsed, error = parse_give(command.args)
    if error:
        await m.answer(error)
        return
    tg_id, url, use_secret, transport = parsed
    if transport == "direct" and not direct_enabled():
        await m.answer("Прямой канал выключен: задай PUBLIC_HOST в .env и перезапусти бота.")
        return
    if transport == "cups" and not cups_enabled():
        await m.answer("Канал Cups.online выключен: CUPS_ENABLED=0 в .env.")
        return
    if not q1("SELECT tg_id FROM users WHERE tg_id=?", tg_id):
        await m.answer("Пользователь должен сначала написать боту /start.")
        return
    ex("UPDATE users SET status='approved' WHERE tg_id=?", tg_id)
    ch_id = ex(
        "INSERT INTO channels(tg_id, transport, url, status, created, use_secret) VALUES(?,?,?,'pending',?,?)",
        tg_id, transport, url, int(time.time()), int(use_secret),
    )
    await m.answer(f"Запускаю канал #{ch_id} {'🔑' if use_secret else '🔓'} ({transport})…")
    asyncio.create_task(provision(bot, ch_id))


@router.message(Command("revoke"))
async def cmd_revoke(m: Message, command: CommandObject, bot: Bot):
    if not is_admin(m.from_user.id):
        return
    arg = (command.args or "").strip()
    ch = q1("SELECT * FROM channels WHERE id=?", int(arg)) if arg.isdigit() else None
    if not ch:
        await m.answer("Канал не найден.")
        return
    await delete_channel(ch)
    await notify_user(bot, ch["tg_id"], "Твой канал остановлен администратором.")
    await m.answer(f"Канал #{ch['id']} остановлен.")


# ---------- прямой TCP ----------
@router.message(Command("direct"))
async def cmd_direct(m: Message, bot: Bot):
    u = upsert_user(m)
    if u["status"] == "banned":
        return
    if not direct_enabled():
        await m.answer("Прямое подключение на этом сервере не включено.")
        return
    ex("UPDATE channels SET status='cancelled' WHERE tg_id=? AND status='choosing'", u["tg_id"])
    if q1("SELECT id FROM channels WHERE tg_id=? AND status='pending'", u["tg_id"]):
        await m.answer("У тебя уже есть заявка на рассмотрении.")
        return
    await m.answer(
        "⚠️ Прямой канал не маскируется под документ: адрес сервера виден, и его могут заблокировать. "
        "Трафик зашифрован ключом, который придёт в профиле."
    )
    ch_id = ex(
        "INSERT INTO channels(tg_id, transport, url, status, created, use_secret) VALUES(?,?,?,'pending',?,1)",
        u["tg_id"], "direct", "direct", int(time.time()),
    )
    await submit_channel(bot, ch_id)


@router.message(Command("cups"))
async def cmd_cups(m: Message, bot: Bot):
    u = upsert_user(m)
    if u["status"] == "banned":
        return
    if not cups_enabled():
        await m.answer("Канал Cups.online на этом сервере не включён.")
        return
    ex("UPDATE channels SET status='cancelled' WHERE tg_id=? AND status='choosing'", u["tg_id"])
    if q1("SELECT id FROM channels WHERE tg_id=? AND status='pending'", u["tg_id"]):
        await m.answer("У тебя уже есть заявка на рассмотрении.")
        return
    await m.answer(
        "ℹ️ Канал через комнаты Cups.online: документ не нужен, комнаты создаёт сервер. "
        "Если канал перезапустится, комнаты станут новыми, и профиль придётся импортировать заново — бот пришлёт его сам. "
        "Трафик зашифрован ключом из профиля."
    )
    ch_id = ex(
        "INSERT INTO channels(tg_id, transport, url, status, created, use_secret) VALUES(?,?,?,'pending',?,1)",
        u["tg_id"], "cups", "cups", int(time.time()),
    )
    await submit_channel(bot, ch_id)


# ---------- удаление каналов ----------
DELETABLE = ("running", "pending")


def channel_title(ch):
    return f"#{ch['id']} · {ch['transport']} {lock_icon(ch)}"


def can_delete(user_id, ch):
    return bool(ch) and ch["status"] in DELETABLE and (is_admin(user_id) or ch["tg_id"] == user_id)


def kb_delete_list(channels):
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=f"🗑 {channel_title(ch)}", callback_data=f"del:{ch['id']}")] for ch in channels
    ])


def kb_delete_confirm(ch_id):
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Да, удалить", callback_data=f"delok:{ch_id}"),
        InlineKeyboardButton(text="↩️ Отмена", callback_data="delno"),
    ]])


def delete_prompt(ch):
    if ch["status"] == "pending":
        return f"Отозвать заявку на канал {channel_title(ch)}?"
    return (
        f"Удалить канал {channel_title(ch)}?\n"
        "Он перестанет работать, а профиль в клиенте станет недействительным. Отменить это нельзя."
    )


def channel_from_callback(data, prefix):
    raw = data[len(prefix):]
    return q1("SELECT * FROM channels WHERE id=?", int(raw)) if raw.isdigit() else None


@router.message(Command("delete"))
async def cmd_delete(m: Message, command: CommandObject):
    u = upsert_user(m)
    if u["status"] == "banned":
        return
    arg = (command.args or "").strip()
    if arg:
        if not is_admin(m.from_user.id):
            await m.answer("Номер канала указывает только админ. Пришли просто /delete.")
            return
        ch = q1("SELECT * FROM channels WHERE id=?", int(arg)) if arg.isdigit() else None
        if not can_delete(m.from_user.id, ch):
            await m.answer("Активный канал с таким номером не найден.")
            return
        await m.answer(delete_prompt(ch), reply_markup=kb_delete_confirm(ch["id"]))
        return
    channels = q("SELECT * FROM channels WHERE tg_id=? AND status IN ('running','pending') ORDER BY id DESC", m.from_user.id)
    if not channels:
        await m.answer("У тебя нет активных каналов.")
    elif len(channels) == 1:
        await m.answer(delete_prompt(channels[0]), reply_markup=kb_delete_confirm(channels[0]["id"]))
    else:
        await m.answer("Какой канал удалить?", reply_markup=kb_delete_list(channels))


@router.callback_query(F.data.startswith("del:"))
async def cb_delete(c: CallbackQuery):
    ch = channel_from_callback(c.data, "del:")
    if not ch or ch["status"] not in DELETABLE:
        await c.answer("Уже неактуально")
        return
    if not can_delete(c.from_user.id, ch):
        await c.answer("Это не твой канал", show_alert=True)
        return
    await c.message.answer(delete_prompt(ch), reply_markup=kb_delete_confirm(ch["id"]))
    await c.answer()


@router.callback_query(F.data.startswith("delok:"))
async def cb_delete_ok(c: CallbackQuery, bot: Bot):
    ch = channel_from_callback(c.data, "delok:")
    if not ch or ch["status"] not in DELETABLE:
        await c.answer("Уже неактуально")
        return
    if not can_delete(c.from_user.id, ch):
        await c.answer("Это не твой канал", show_alert=True)
        return
    await delete_channel(ch)
    await c.message.edit_text(f"🗑 Канал {channel_title(ch)} удалён. Чтобы получить новый, пришли ссылку на документ.")
    await c.answer()
    if ch["tg_id"] == c.from_user.id:
        if not is_admin(c.from_user.id):
            await notify_admins(bot, f"🗑 Пользователь <code>{ch['tg_id']}</code> удалил канал #{ch['id']} ({ch['transport']})")
    else:
        await notify_user(bot, ch["tg_id"], f"Твой канал #{ch['id']} удалён администратором.")


@router.callback_query(F.data == "delno")
async def cb_delete_no(c: CallbackQuery):
    await c.message.edit_text("Отменено.")
    await c.answer()


@router.message(Command("ban"))
async def cmd_ban(m: Message, command: CommandObject, bot: Bot):
    if not is_admin(m.from_user.id):
        return
    arg = (command.args or "").strip()
    if not arg.isdigit():
        await m.answer("Формат: /ban &lt;tg_id&gt;")
        return
    await ban_user(bot, int(arg))
    await m.answer("Забанен, каналы остановлены.")


@router.message(Command("unban"))
async def cmd_unban(m: Message, command: CommandObject):
    if not is_admin(m.from_user.id):
        return
    arg = (command.args or "").strip()
    if not arg.isdigit():
        await m.answer("Формат: /unban &lt;tg_id&gt;")
        return
    ex("UPDATE users SET status='new' WHERE tg_id=?", int(arg))
    await m.answer("Разбанен (снова нужен апрув).")


@router.message()
async def fallback(m: Message):
    upsert_user(m)
    await m.answer(HELP_USER)


async def main():
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    init_db()
    bot = Bot(BOT_TOKEN, default=DefaultBotProperties(parse_mode=ParseMode.HTML, link_preview_is_disabled=True))
    dp = Dispatcher()
    dp.include_router(router)
    asyncio.create_task(watchdog(bot))
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
OFEOF_BOTPY

  cat > "$BOT_DIR/requirements.txt" <<'OFEOF_REQ'
aiogram>=3.13,<4
aiohttp>=3.9
docker>=7.1
qrcode[pil]>=7.4
OFEOF_REQ

  cat > "$BOT_DIR/Dockerfile" <<'OFEOF_BOTDF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY bot.py .
CMD ["python", "-u", "bot.py"]
OFEOF_BOTDF

  cat > "$BOT_DIR/docker-compose.yml" <<'OFEOF_COMPOSE'
services:
  of-bot:
    build: .
    container_name: of-bot
    restart: unless-stopped
    env_file: .env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "2" }
OFEOF_COMPOSE

  cat > "$EXIT_DIR/Dockerfile" <<'OFEOF_EXITDF'
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends iptables ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY universal-bypass-tool /app/universal-bypass-tool
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/universal-bypass-tool /app/entrypoint.sh
ENTRYPOINT ["/app/entrypoint.sh"]
OFEOF_EXITDF

  cat > "$EXIT_DIR/entrypoint.sh" <<'OFEOF_ENTRY'
#!/bin/sh
set -e
# RST-drop только внутри netns контейнера
iptables -C OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null \
  || iptables -A OUTPUT -p tcp --tcp-flags RST RST -j DROP

# аргументы от бота (CMD) имеют приоритет над OPENFLUX_ARGS из compose
if [ "$#" -eq 0 ] && [ -n "$OPENFLUX_ARGS" ]; then
  # shellcheck disable=SC2086
  set -- $OPENFLUX_ARGS
fi

# секрет канала: бот передаёт его в env, в аргументы он не попадает
if [ -n "$OF_SECRET" ]; then
  umask 077
  printf '%s' "$OF_SECRET" > /run/openflux.key
  unset OF_SECRET
  set -- "$@" --encryption-key-file /run/openflux.key
fi

exec /app/universal-bypass-tool "$@"
OFEOF_ENTRY
  chmod +x "$EXIT_DIR/entrypoint.sh"
  ok "Файлы записаны в $BASE"
}

# ---------------- бинарник OpenFlux ----------------
# Сверка SHA-256 скачанного релиза. Ожидаемый хеш берём из OFBOT_OF_SHA256 (пин),
# иначе из файла .sha256 / checksums среди ассетов релиза. Нет хеша — только с подтверждением.
# $1 — скачанный файл, $2 — имя ассета, $3 — JSON релиза
verify_asset() {
  local file=$1 name=$2 rel=$3 exp="" sumurl sumf n got
  if [ -n "${OFBOT_OF_SHA256:-}" ]; then
    exp=${OFBOT_OF_SHA256,,}
  else
    sumurl=$(jq -r --arg n "$name" '.assets[]?.browser_download_url
        | select(endswith($n + ".sha256") or test("(?i)(sha256sums?|checksums?)(\\.txt)?$"))' <<<"$rel" | head -n1)
    if [ -n "$sumurl" ]; then
      sumf=$(mktemp)
      if curl -fsSL "$sumurl" -o "$sumf" 2>/dev/null; then
        exp=$(grep -F "$name" "$sumf" | grep -oiE '\b[0-9a-f]{64}\b' | head -n1)
        if [ -z "$exp" ]; then  # файл с единственным хешем без имени
          n=$(grep -oiE '\b[0-9a-f]{64}\b' "$sumf" | wc -l)
          [ "$n" -eq 1 ] && exp=$(grep -oiE '\b[0-9a-f]{64}\b' "$sumf")
        fi
        exp=${exp,,}
      fi
      rm -f "$sumf"
    fi
  fi
  got=$(sha256sum "$file" | cut -d' ' -f1)
  if [ -z "$exp" ]; then
    warn "У релиза нет файла SHA-256 для $name — целостность не проверить (sha256: $got)"
    confirm "Установить без проверки?" || return 1
    return 0
  fi
  if [ "$got" != "$exp" ]; then
    err "SHA-256 не совпал для $name: ожидался $exp, получен $got"
    return 1
  fi
  ok "SHA-256 совпал: $got"
}

fetch_release() {
  local a url tmp f rel
  a=$(cpu_arch)
  info "Ищу релиз $OF_REPO для linux-$a..."
  rel=$(curl -fsSL "https://api.github.com/repos/$OF_REPO/releases/latest" 2>/dev/null)
  url=$(jq -r --arg a "$a" '.assets[]?.browser_download_url
        | select(test("linux"; "i") and test($a))
        | select(test("\\.(sha256|sig|txt|md)$") | not)' <<<"$rel" 2>/dev/null | head -n1)
  [ -z "$url" ] && return 1
  tmp=$(mktemp -d)
  curl -fL --progress-bar "$url" -o "$tmp/asset" || { rm -rf "$tmp"; return 1; }
  verify_asset "$tmp/asset" "$(basename "$url")" "$rel" || { rm -rf "$tmp"; return 1; }
  case "$url" in
    *.tar.gz|*.tgz) tar xzf "$tmp/asset" -C "$tmp" ;;
    *.zip) command -v unzip >/dev/null || apt-get install -y -qq unzip >/dev/null; unzip -q "$tmp/asset" -d "$tmp" ;;
    *) mv "$tmp/asset" "$tmp/$BIN_NAME" ;;
  esac
  f=$(find "$tmp" -type f -name "${BIN_NAME}*" ! -name '*.sha256' | head -n1)
  [ -z "$f" ] && f="$tmp/$BIN_NAME"
  [ -f "$f" ] || { rm -rf "$tmp"; return 1; }
  install -m 755 "$f" "$EXIT_DIR/$BIN_NAME" && rm -rf "$tmp"
  ok "Бинарник из релиза: $(basename "$url")"
}

build_from_source() {
  info "Собираю $OF_REPO из исходников (golang в docker, займёт пару минут)..."
  local cgo
  for cgo in 0 1; do
    if docker run --rm -e GOTOOLCHAIN=auto -e CGO_ENABLED=$cgo -v "$EXIT_DIR":/out golang:1 sh -c \
      "git clone -q --depth 1 https://github.com/$OF_REPO /src && cd /src && go build -o /out/$BIN_NAME ." ; then
      [ "$cgo" = 1 ] && warn "Собрано с CGO — возможна несовместимость glibc с рантайм-образом"
      docker image rm golang:1 >/dev/null 2>&1
      ok "Собрано из исходников"
      return 0
    fi
  done
  docker image rm golang:1 >/dev/null 2>&1
  return 1
}

fetch_binary() {
  fetch_release && return 0
  warn "Готовый релиз недоступен или не прошёл проверку"
  local p; p=$(ask "Путь к готовому бинарнику (пусто — собрать из исходников)" "")
  if [ -n "$p" ]; then
    [ -f "$p" ] || { err "Файл $p не найден"; return 1; }
    install -m 755 "$p" "$EXIT_DIR/$BIN_NAME" && ok "Бинарник скопирован из $p" && return 0
  fi
  build_from_source || { err "Не удалось получить бинарник OpenFlux"; return 1; }
}

build_exit_image() {
  info "Собираю образ канала $IMAGE..."
  docker build -q -t "$IMAGE" "$EXIT_DIR" >/dev/null && ok "Образ $IMAGE готов" || { err "Сборка образа не удалась"; return 1; }
}

# ---------------- настройка ----------------
configure() {
  local token bot_name admins ram def maxch
  while :; do
    token=$(ask "BOT_TOKEN (от @BotFather)" "$(env_get BOT_TOKEN)")
    bot_name=$(curl -fsS "https://api.telegram.org/bot${token}/getMe" 2>/dev/null | jq -r '.result.username // empty')
    [ -n "$bot_name" ] && { ok "Бот: @$bot_name"; break; }
    err "Токен не принят Telegram, попробуй ещё раз"
  done
  while :; do
    admins=$(ask "ADMIN_IDS — tg id админов через запятую (узнать: @userinfobot)" "$(env_get ADMIN_IDS)")
    [[ "$admins" =~ ^[0-9]+(,[0-9]+)*$ ]] && break
    err "Нужны числовые id через запятую"
  done
  ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  def=$(( (ram - 512) / 150 )); [ "$def" -lt 1 ] && def=1
  maxch=$(ask "MAX_CHANNELS (RAM ${ram} МБ → рекомендую $def)" "$(env_or MAX_CHANNELS "$def")")

  {
    echo "BOT_TOKEN=$token"
    echo "ADMIN_IDS=$admins"
    echo "OF_IMAGE=$IMAGE"
    echo "MAX_CHANNELS=$maxch"
    echo "CHANNEL_MEM=$(env_or CHANNEL_MEM 128m)"
    echo "CHANNEL_CPUS=$(env_or CHANNEL_CPUS 0.3)"
    echo "STARTUP_WAIT=$(env_or STARTUP_WAIT 10)"
    echo "DISK_ALERT_PCT=$(env_or DISK_ALERT_PCT 85)"
    echo "MEM_ALERT_PCT=$(env_or MEM_ALERT_PCT 90)"
    echo "ARGS_YANDEX=$(env_or ARGS_YANDEX '--role=exit --transport=yandex --url {url}')"
    echo "ARGS_MAILRU=$(env_or ARGS_MAILRU '--role=exit --transport=mailru --url {url}')"
    echo "ARGS_VYANDEX=$(env_or ARGS_VYANDEX '--role=exit --transport=vyandex --url {url}')"
    echo "ARGS_BOARDS=$(env_or ARGS_BOARDS '--role=exit --transport=boards --url {url}')"
    echo "CLIENT_LINKS=$(env_get CLIENT_LINKS)"
    local legacy; legacy=$(env_get SECRET_MODE)
    echo "SECRET_CHOICE=$(env_or SECRET_CHOICE "$([ "$legacy" = none ] && echo never || echo ask)")"
    echo "SECRET_METHOD=generate"
    echo "SECRET_DEFAULT=$(env_or SECRET_DEFAULT secret)"
    local sarg; sarg=$(env_get SECRET_ARG); [ "$sarg" = '--secret {secret}' ] && sarg=""
    echo "SECRET_ARG=$sarg"
    echo "SECRET_REGEX=$(env_get SECRET_REGEX)"
    echo "SECRET_TIMEOUT=$(env_or SECRET_TIMEOUT 60)"
    echo "CONFIG_TEMPLATE_SECRET=$(env_get CONFIG_TEMPLATE_SECRET)"
    echo "QR_ENABLED=$(env_or QR_ENABLED 1)"
    echo "CONFIG_FORMAT=$(env_or CONFIG_FORMAT openflux-v1)"
    echo "CONFIG_NAME=$(env_or CONFIG_NAME 'OpenFlux {id}')"
    echo "TYPE_YANDEX=$(env_or TYPE_YANDEX yandex)"
    echo "TYPE_MAILRU=$(env_or TYPE_MAILRU mailru)"
    echo "TYPE_VYANDEX=$(env_or TYPE_VYANDEX vyandex)"
    echo "TYPE_BOARDS=$(env_or TYPE_BOARDS boards)"
    echo "VYANDEX_MODE=$(env_or VYANDEX_MODE off)"
    echo "PUBLIC_HOST=$(env_get PUBLIC_HOST)"
    echo "DIRECT_PORT_MIN=$(env_or DIRECT_PORT_MIN 20000)"
    echo "DIRECT_PORT_MAX=$(env_or DIRECT_PORT_MAX 20999)"
    echo "ARGS_DIRECT=$(env_or ARGS_DIRECT '--role=exit --negotiate --transports=direct:50 --direct-listen=0.0.0.0:{port}')"
    echo "CUPS_ENABLED=$(env_or CUPS_ENABLED 1)"
    echo "CUPS_TIMEOUT=$(env_or CUPS_TIMEOUT 90)"
    echo "TYPE_CUPS=$(env_or TYPE_CUPS cupsonline)"
    echo "ARGS_CUPS=$(env_or ARGS_CUPS '--role=exit --transport=cupsonline')"
    echo "CONFIG_TEMPLATE=$(env_or CONFIG_TEMPLATE 'openflux://?transport={transport}&url={url_enc}&name={name}')"
  } > "$BOT_DIR/.env.new" && mv "$BOT_DIR/.env.new" "$BOT_DIR/.env"
  chmod 600 "$BOT_DIR/.env"
  ok "Настройки сохранены в $BOT_DIR/.env"
}

bot_up()      { (cd "$BOT_DIR" && docker compose up -d --build) && ok "Бот запущен"; docker image prune -f >/dev/null 2>&1; }
bot_stop()    { (cd "$BOT_DIR" && docker compose stop) && ok "Бот остановлен"; }
bot_restart() { (cd "$BOT_DIR" && docker compose up -d --force-recreate) && ok "Бот перезапущен (.env перечитан)"; }
bot_logs()    { trap 'true' INT; (cd "$BOT_DIR" && docker compose logs -f --tail 100); trap - INT; }

install_cmd() {
  if [ -f "$0" ] && [ "$(readlink -f "$0")" != "$CMD_PATH" ]; then
    install -m 755 "$0" "$CMD_PATH"
  elif [ -n "$SCRIPT_URL" ]; then
    curl -fsSL "$SCRIPT_URL" -o "$CMD_PATH" && chmod +x "$CMD_PATH"
  fi
  [ -x "$CMD_PATH" ] && ok "Быстрый запуск: ${B}ofbot${N}" \
    || warn "Команда ofbot не создана: скачай скрипт файлом (curl -o install.sh ...) или задай OFBOT_SCRIPT_URL"
}

# ---------------- каналы ----------------
recreate_channels() {
  local ids id j name mem cpu cmd lab envs extra
  ids=$(docker ps -aq --filter label=openflux.bot=1)
  [ -z "$ids" ] && { info "Каналов нет"; return 0; }
  info "Пересоздаю каналы на новом образе (бот на паузе)..."
  (cd "$BOT_DIR" && docker compose stop >/dev/null 2>&1)
  for id in $ids; do
    j=$(docker inspect "$id")
    name=$(jq -r '.[0].Name | ltrimstr("/")' <<<"$j")
    mem=$(jq -r '.[0].HostConfig.Memory // 0' <<<"$j")
    cpu=$(jq -r '.[0].HostConfig.NanoCpus // 0' <<<"$j")
    mapfile -t cmd < <(jq -r '.[0].Config.Cmd[]?' <<<"$j")
    mapfile -t lab < <(jq -r '.[0].Config.Labels // {} | to_entries[] | "--label=\(.key)=\(.value)"' <<<"$j")
    mapfile -t envs < <(jq -r '.[0].Config.Env[]? | select(startswith("OF_SECRET=")) | "--env=\(.)"' <<<"$j")
    # опубликованные порты (прямые каналы) нужно сохранить при пересоздании
    mapfile -t pubs < <(jq -r '.[0].HostConfig.PortBindings // {} | to_entries[] | .key as $k | .value[]? | "--publish=\(.HostPort):\($k)"' <<<"$j")
    extra=()
    [ "$mem" -gt 0 ] && extra+=(--memory "$mem")
    [ "$cpu" -gt 0 ] && extra+=(--cpus "$(awk -v n="$cpu" 'BEGIN{printf "%.2f", n/1e9}')")
    docker rm -f "$id" >/dev/null
    if docker run -d --name "$name" --cap-add NET_ADMIN --cap-add NET_RAW --restart unless-stopped \
        --log-opt max-size=10m --log-opt max-file=2 "${extra[@]}" "${lab[@]}" "${envs[@]}" "${pubs[@]}" "$IMAGE" "${cmd[@]}" >/dev/null; then
      ok "$name"
    else
      err "$name не поднялся — бот пометит его упавшим"
    fi
  done
  (cd "$BOT_DIR" && docker compose start >/dev/null 2>&1) && ok "Бот снова запущен"
}

show_status() {
  echo -e "\n${B}Сервер${N}"
  df -h / | awk 'NR==2{print "  Диск: "$3" / "$2" ("$5")"}'
  free -m | awk '/Mem:/{print "  RAM:  "$3" / "$2" МБ"}'
  echo "  Load: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo -e "\n${B}Бот${N}"
  docker ps -a --filter name=^of-bot$ --format '  {{.Names}}: {{.Status}}'
  echo -e "\n${B}Каналы${N} (лимит $(env_get MAX_CHANNELS))"
  local n; n=$(docker ps -q --filter label=openflux.bot=1 | wc -l)
  echo "  Запущено: $n"
  [ "$n" -gt 0 ] && docker stats --no-stream --filter label=openflux.bot=1 \
    --format '  {{.Name}}\tCPU {{.CPUPerc}}\tRAM {{.MemUsage}}\tNET {{.NetIO}}'
  echo
}

# ---------------- бэкап / удаление ----------------
do_backup() {
  local f="/root/ofbot-backup-$(date +%F_%H%M).tar.gz"
  tar czf "$f" -C "$BOT_DIR" data .env && ok "Бэкап: $f"
}

do_restore() {
  local f; f=$(ask "Путь к бэкапу (.tar.gz)" "$(ls -1t /root/ofbot-backup-*.tar.gz 2>/dev/null | head -1)")
  [ -f "$f" ] || { err "Файл не найден"; return 1; }
  bot_stop; tar xzf "$f" -C "$BOT_DIR" && ok "Восстановлено из $f"; bot_up
}

do_uninstall() {
  confirm "Удалить бота, все каналы и файлы?" || return
  confirm "Сделать бэкап перед удалением?" && do_backup
  docker ps -aq --filter label=openflux.bot=1 | xargs -r docker rm -f >/dev/null
  (cd "$BOT_DIR" 2>/dev/null && docker compose down --rmi local >/dev/null 2>&1)
  docker image rm "$IMAGE" >/dev/null 2>&1
  rm -rf "$BASE" "$CMD_PATH"
  ok "Удалено. Настройки Docker/journald оставлены."
  exit 0
}

# ---------------- сценарии ----------------
do_install() {
  if installed; then
    warn "Уже установлено в $BASE"
    confirm "Переустановить (данные и .env сохранятся)?" || return
  fi
  check_os; check_disk; install_deps; harden_logs
  write_files
  fetch_binary || return 1
  build_exit_image || return 1
  configure
  bot_up
  install_cmd
  echo
  ok "${B}Готово.${N} Напиши своему боту /start — придёт меню админа."
  warn "Не забудь подставить реальный CONFIG_TEMPLATE и флаги Mail.ru в $BOT_DIR/.env"
}

update_bot()  { write_files && bot_up; }
update_of()   { fetch_binary && build_exit_image && recreate_channels; }
update_self() {
  [ -z "$SCRIPT_URL" ] && { warn "OFBOT_SCRIPT_URL не задан — самообновление недоступно"; return; }
  curl -fsSL "$SCRIPT_URL" -o "$CMD_PATH.new" && bash -n "$CMD_PATH.new" \
    && mv "$CMD_PATH.new" "$CMD_PATH" && chmod +x "$CMD_PATH" && ok "Скрипт обновлён" && exec "$CMD_PATH"
  err "Не удалось обновить скрипт"; rm -f "$CMD_PATH.new"
}

edit_env() { ${EDITOR:-nano} "$BOT_DIR/.env" && chmod 600 "$BOT_DIR/.env" && bot_up; }

# ---------------- меню ----------------
header() {
  clear
  echo -e "${B}${C}OPENFLUX BOT${N}  v$VERSION"
  if installed; then
    local st="${R}остановлен${N}"
    [ -n "$(docker ps -q --filter name=^of-bot$)" ] && st="${G}работает${N}"
    echo -e " Бот: $st   Каналов: $(docker ps -q --filter label=openflux.bot=1 | wc -l)/$(env_get MAX_CHANNELS)"
  else
    echo -e " ${Y}Не установлен${N}"
  fi
  echo
}

menu_manage() {
  while :; do
    header
    echo "1. Статус сервера и каналов"
    echo "2. Логи бота"
    echo "3. Перезапустить бота"
    echo "4. Остановить бота"
    echo "5. Запустить бота"
    echo "6. Изменить настройки (.env)"
    echo "7. Перенастроить (токен, админы, лимит)"
    echo "8. Пересоздать все каналы"
    echo
    echo "0. Назад"
    case "$(ask "Выбери действие (0-8)")" in
      1) show_status; pause ;;
      2) bot_logs ;;
      3) bot_restart; pause ;;
      4) bot_stop; pause ;;
      5) bot_up; pause ;;
      6) edit_env; pause ;;
      7) configure && bot_up; pause ;;
      8) recreate_channels; pause ;;
      0) return ;;
    esac
  done
}

menu_update() {
  while :; do
    header
    echo "1. Обновить бота (код из этой версии скрипта)"
    echo "2. Обновить OpenFlux (бинарник + пересоздать каналы)"
    echo "3. Обновить сам скрипт"
    echo
    echo "0. Назад"
    case "$(ask "Выбери действие (0-3)")" in
      1) update_bot; pause ;;
      2) update_of; pause ;;
      3) update_self; pause ;;
      0) return ;;
    esac
  done
}

menu_main() {
  while :; do
    header
    echo "1. Установка"
    if installed; then
      echo "2. Управление"
      echo "3. Обновление"
      echo "4. Бэкап"
      echo "5. Восстановить из бэкапа"
      echo "6. Удалить"
    fi
    echo
    echo "0. Выход"
    echo -e " Быстрый запуск: ${B}ofbot${N}"
    echo
    case "$(ask "Выбери действие")" in
      1) do_install; pause ;;
      2) installed && menu_manage ;;
      3) installed && menu_update ;;
      4) installed && { do_backup; pause; } ;;
      5) installed && { do_restore; pause; } ;;
      6) installed && do_uninstall ;;
      0) exit 0 ;;
    esac
  done
}

# ---------------- CLI ----------------
need_root
case "${1:-}" in
  install)   do_install ;;
  status)    show_status ;;
  logs)      bot_logs ;;
  restart)   bot_restart ;;
  backup)    do_backup ;;
  update-of) update_of ;;
  update-bot) update_bot ;;
  "")        menu_main ;;
  *)         echo "Использование: ofbot [install|status|logs|restart|backup|update-of|update-bot]"; exit 1 ;;
esac
