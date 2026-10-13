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
}
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

URL_RULES = [
    (re.compile(r"^https://(disk|docs)\.yandex\.(ru|com)/\S+$"), "yandex"),
    (re.compile(r"^https://cloud\.mail\.ru/\S+$"), "mailru"),
]

HELP_USER = (
    "Пришли ссылку на <b>публичный</b> документ (доступ по ссылке):\n"
    "• Yandex Docs: <code>https://disk.yandex.ru/i/...</code> (старый редактор)\n"
    + ("• Yandex Docs (новый редактор): <code>https://docs.yandex.ru/edit/d/...</code>\n" if VYANDEX_MODE == "auto" else "")
    + "• Mail.ru: <code>https://cloud.mail.ru/public/...</code>\n\n"
    "В ответ придёт конфиг для OpenFlux.\n"
    "/myconfig — прислать мой конфиг ещё раз\n"
    "/client — скачать клиент"
)
HELP_ADMIN = (
    "<b>Админ</b>\n"
    "/users — пользователи\n"
    "/channels — каналы\n"
    "/status — состояние сервера\n"
    "/give &lt;tg_id&gt; &lt;url&gt; [secret|nosecret] [vyandex] — выдать канал\n"
    "/revoke &lt;channel_id&gt; — остановить канал\n"
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
    return clean_link(url) if transport == "vyandex" else url


def detect_transport(url):
    if VYANDEX_MODE == "auto" and VYANDEX_URL_RE.match(url):
        return "vyandex"
    for rx, t in URL_RULES:
        if rx.match(url):
            return t
    return None


async def url_alive(url):
    try:
        timeout = aiohttp.ClientTimeout(total=15)
        async with aiohttp.ClientSession(timeout=timeout) as s:
            async with s.get(url, allow_redirects=True) as r:
                return r.status < 400
    except Exception:
        return False


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


def config_message(ch, head):
    text = f"{head}\n\n<code>{esc(build_config(ch))}</code>"
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
    """Конфиг текстом + QR. Сначала QR, чтобы текст с кнопками оказался последним сообщением."""
    if QR_ENABLED:
        try:
            await bot.send_photo(
                ch["tg_id"],
                BufferedInputFile(qr_png(build_config(ch)), filename=f"openflux-{ch['id']}.png"),
                caption="📷 QR для импорта в клиент",
            )
        except Exception as e:
            log.warning("QR for channel %s failed: %s", ch["id"], e)
    await notify_user(bot, ch["tg_id"], config_message(ch, head) + tail, kb)


def find_secret(logs):
    found = SECRET_RE.findall(logs or "")
    if not found:
        return None
    last = found[-1]
    return last if isinstance(last, str) else next((g for g in last if g), None)


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
    fmt = {"url": ch["url"], "secret": secret or ""}
    args = [t.format(**fmt) for t in toks]
    env = {}
    if secret and SECRET_METHOD == "generate" and "{secret}" not in tpl:
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


CAPTCHA_MARKERS = ("captcha required", "captcha")


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


async def stop_channel(ch):
    await asyncio.to_thread(_remove_container, ch["container"])
    set_channel(ch["id"], "stopped")


# ---------- жизненный цикл канала ----------
async def provision(bot: Bot, ch_id):
    try:
        ch = q1("SELECT * FROM channels WHERE id=?", ch_id)
        olds = q("SELECT * FROM channels WHERE tg_id=? AND status='running' AND id<>?", ch["tg_id"], ch_id)
        running = q1("SELECT COUNT(*) AS n FROM channels WHERE status='running'")["n"]
        if running - len(olds) >= MAX_CHANNELS:
            set_channel(ch_id, "failed")
            await notify_user(bot, ch["tg_id"], "Сейчас нет свободных слотов, попробуй позже.")
            await notify_admins(bot, f"⚠️ Лимит каналов ({MAX_CHANNELS}) исчерпан, заявка #{ch_id} не запущена.")
            return

        use_secret = wants_secret(ch)
        secret = secrets.token_urlsafe(24) if use_secret and SECRET_METHOD == "generate" else None
        name = await asyncio.to_thread(_run_container, ch, secret)
        ex("UPDATE channels SET container=? WHERE id=?", name, ch_id)
        await asyncio.sleep(STARTUP_WAIT)
        status, logs, started_at = await asyncio.to_thread(_container_state, name)

        if status == "running" and use_secret and SECRET_METHOD == "log":
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


async def watchdog(bot: Bot):
    alerted = {"disk": False, "mem": False}
    captcha_alerted = set()  # id каналов, по которым уже предупредили
    while True:
        await asyncio.sleep(60)
        try:
            for ch in q("SELECT * FROM channels WHERE status='running'"):
                status, logs, started_at = await asyncio.to_thread(_container_state, ch["container"], 300)
                if status != "running":
                    set_channel(ch["id"], "failed")
                    await notify_user(bot, ch["tg_id"], "⚠️ Твой канал перестал работать. Пришли ссылку на документ заново.")
                    await notify_admins(bot, f"⚠️ Канал #{ch['id']} ({ch['tg_id']}) упал: {status}\n<pre>{esc(logs[-1500:])}</pre>")
                    continue

                recent = (await asyncio.to_thread(_recent_logs, ch["container"])).lower()
                has_captcha = any(mk in recent for mk in CAPTCHA_MARKERS)
                if has_captcha and ch["id"] not in captcha_alerted:
                    captcha_alerted.add(ch["id"])
                    await notify_admins(
                        bot,
                        f"🧩 Канал #{ch['id']} ({ch['tg_id']}, {ch['transport']}): Яндекс требует капчу для IP узла.\n"
                        "Пока она не пройдена, канал не передаёт трафик.",
                    )
                    await notify_user(
                        bot, ch["tg_id"],
                        "🧩 Яндекс попросил капчу для твоего канала, пока он может не работать. "
                        "Админ в курсе.",
                    )
                elif not has_captcha and ch["id"] in captcha_alerted:
                    captcha_alerted.discard(ch["id"])
                    await notify_admins(bot, f"✅ Канал #{ch['id']}: капча больше не встречается в логах")
                if started_at and started_at != ch["started_at"]:
                    # контейнер перезапускался (краш, ребут, обновление OpenFlux)
                    from_log = wants_secret(ch) and SECRET_METHOD == "log"
                    new_secret = find_secret(logs) if from_log else ch["secret"]
                    if from_log and not new_secret:
                        continue  # секрет ещё не напечатан — проверим через минуту
                    ex("UPDATE channels SET secret=?, started_at=? WHERE id=?", new_secret, started_at, ch["id"])
                    if new_secret != ch["secret"]:
                        ch = q1("SELECT * FROM channels WHERE id=?", ch["id"])
                        await send_config(bot, ch, "🔄 Канал перезапустился и сменил секрет. Новый конфиг:")
                        await notify_admins(bot, f"🔄 Канал #{ch['id']}: секрет обновлён и отправлен пользователю")

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
    if not await url_alive(url):
        await m.answer("Документ недоступен. Проверь, что он открыт по ссылке.")
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
    await m.answer(f"Запущено: {total}/{MAX_CHANNELS}\n\n" + ("\n".join(lines) or "Нет активных"))


GIVE_USAGE = "Формат: /give &lt;tg_id&gt; &lt;url&gt; [secret|nosecret] [vyandex]"


def parse_give(args):
    """/give <tg_id> <url> [secret|nosecret] [vyandex] → ((tg_id, url, use_secret, transport), None) или (None, ошибка)."""
    parts = (args or "").split()
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
    await stop_channel(ch)
    await notify_user(bot, ch["tg_id"], "Твой канал остановлен администратором.")
    await m.answer(f"Канал #{ch['id']} остановлен.")


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
