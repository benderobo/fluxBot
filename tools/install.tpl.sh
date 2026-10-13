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
__BOT_PY__
OFEOF_BOTPY

  cat > "$BOT_DIR/requirements.txt" <<'OFEOF_REQ'
__REQUIREMENTS__
OFEOF_REQ

  cat > "$BOT_DIR/Dockerfile" <<'OFEOF_BOTDF'
__BOT_DOCKERFILE__
OFEOF_BOTDF

  cat > "$BOT_DIR/docker-compose.yml" <<'OFEOF_COMPOSE'
__BOT_COMPOSE__
OFEOF_COMPOSE

  cat > "$EXIT_DIR/Dockerfile" <<'OFEOF_EXITDF'
__EXIT_DOCKERFILE__
OFEOF_EXITDF

  cat > "$EXIT_DIR/entrypoint.sh" <<'OFEOF_ENTRY'
__ENTRYPOINT__
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
