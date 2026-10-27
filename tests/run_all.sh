#!/bin/sh
# Полная локальная проверка релиза 1.21:
#   1) берём ИСХОДНЫЙ байткод 1.21 из доконверсионного коммита
#      (по умолчанию 131629b — состояние main до версионной инъекции;
#      можно переопределить ORIG_REF или передать путь к файлу аргументом);
#   2) собираем кандидат во временном каталоге через tools/make_release.py;
#   3) структурные инварианты байткода (Python);
#   4) кросс-поколенческий приёмочный тест апдейтера (LuaJIT, переменная LJ).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ORIG_REF=${ORIG_REF:-131629b}

if [ -n "${1:-}" ]; then
  cp "$1" "$STAGE/orig.luac"
elif git -C "$ROOT" cat-file -e "$ORIG_REF:grnd_adm_tools.luac" 2>/dev/null; then
  git -C "$ROOT" show "$ORIG_REF:grnd_adm_tools.luac" > "$STAGE/orig.luac"
else
  echo "нет исходного байткода в $ORIG_REF; передайте путь аргументом" >&2
  exit 2
fi

python3 "$ROOT/tools/make_release.py" \
  "$STAGE/orig.luac" "$STAGE/grnd_adm_tools.luac" "$STAGE/update.txt"

python3 "$ROOT/tests/test_bytecode_structure.py" \
  "$STAGE/orig.luac" "$STAGE/grnd_adm_tools.luac" "$STAGE/update.txt"

LJ=${LJ:-luajit}
"$LJ" "$ROOT/tests/grnd_update_acceptance_test.lua" \
  "$STAGE/orig.luac" "$STAGE/grnd_adm_tools.luac"
