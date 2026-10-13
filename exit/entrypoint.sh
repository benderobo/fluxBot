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
