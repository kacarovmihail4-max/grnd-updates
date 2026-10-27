#!/bin/sh
# Полная локальная проверка релиза 1.21:
#   1) берём ИСХОДНЫЙ байткод 1.21 из ветки main (до версионной инъекции);
#   2) собираем кандидат во временном каталоге через tools/make_release.py;
#   3) структурные инварианты байткода (Python);
#   4) кросс-поколенческий приёмочный тест апдейтера (LuaJIT).
# LuaJIT задаётся переменной LJ (по умолчанию luajit из PATH).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

if [ -n "${1:-}" ]; then
  cp "$1" "$STAGE/orig.luac"
elif git -C "$ROOT" cat-file -e main:grnd_adm_tools.luac 2>/dev/null; then
  git -C "$ROOT" show main:grnd_adm_tools.luac > "$STAGE/orig.luac"
else
  cp "$ROOT/grnd_adm_tools.luac" "$STAGE/orig.luac"
fi

python3 "$ROOT/tools/make_release.py" \
  "$STAGE/orig.luac" "$STAGE/grnd_adm_tools.luac" "$STAGE/update.txt"

python3 "$ROOT/tests/test_bytecode_structure.py" \
  "$STAGE/orig.luac" "$STAGE/grnd_adm_tools.luac" "$STAGE/update.txt"

LJ=${LJ:-luajit}
"$LJ" "$ROOT/tests/grnd_update_acceptance_test.lua" \
  "$STAGE/orig.luac" "$STAGE/grnd_adm_tools.luac"
