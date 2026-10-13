#!/usr/bin/env python3
"""Собирает install.sh из tools/install.tpl.sh и исходников bot/ и exit/.
Запуск из корня репо: python3 tools/build.py  (с --check — только проверить, что install.sh актуален)"""
import pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PARTS = {
    "__BOT_PY__": "bot/bot.py",
    "__REQUIREMENTS__": "bot/requirements.txt",
    "__BOT_DOCKERFILE__": "bot/Dockerfile",
    "__BOT_COMPOSE__": "bot/docker-compose.yml",
    "__EXIT_DOCKERFILE__": "exit/Dockerfile",
    "__ENTRYPOINT__": "exit/entrypoint.sh",
}

out = (ROOT / "tools/install.tpl.sh").read_text()
for ph, path in PARTS.items():
    body = (ROOT / path).read_text().rstrip("\n")
    if "OFEOF_" in body:
        sys.exit(f"{path}: содержит маркер OFEOF_, сломает heredoc")
    if ph not in out:
        sys.exit(f"нет плейсхолдера {ph} в шаблоне")
    out = out.replace(ph, body)

target = ROOT / "install.sh"
if "--check" in sys.argv:
    if not target.exists() or target.read_text() != out:
        sys.exit("install.sh устарел: запусти python3 tools/build.py")
    print("install.sh актуален")
else:
    target.write_text(out)
    target.chmod(0o755)
    print("install.sh собран")
