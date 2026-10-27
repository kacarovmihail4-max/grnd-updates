#!/usr/bin/env python3
"""Структурные инварианта LuaJIT-дампа до/после версионной инъекции.

Запуск: python3 tests/test_bytecode_structure.py <orig.luac> <fixed.luac> <manifest>
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import ljbc  # noqa: E402

MARKER = b'GRND_SCRIPT_VERSION="1.21.0"'
failures = 0


def check(name, cond, detail=''):
    global failures
    print(('  PASS  ' if cond else '  FAIL  ') + name + (f'  [{detail}]' if detail else ''))
    if not cond:
        failures += 1


def main():
    orig_path, fixed_path, manifest_path = sys.argv[1:4]
    orig = open(orig_path, 'rb').read()
    fixed = open(fixed_path, 'rb').read()
    manifest = open(manifest_path, 'rb').read()

    print('== Заголовок и формат (LuaJIT/MoonLoader, x86, stripped) ==')
    for tag, data in (('orig', orig), ('fixed', fixed)):
        check(f'{tag}: магия 1B 4C 4A, BCDUMP v2, flags=0x02 (strip, без FR2)',
              data[:5] == b'\x1bLJ\x02\x02', data[:5].hex())

    vo, fo, co = ljbc.parse_dump(orig)
    vf, ff, cf = ljbc.parse_dump(fixed)
    check('число прототипов не изменилось', len(co) == len(cf),
          f'{len(co)} -> {len(cf)}')

    print('== Дочерние прототипы байт-в-байт не тронуты ==')
    changed = [i for i in range(len(co) - 1) if co[i][3] != cf[i][3]]
    check('изменён только корневой прототип', changed == [], str(changed))

    ho, hn = ljbc.parse_chunk_header(co[-1][3]), ljbc.parse_chunk_header(cf[-1][3])
    check('sizekgc корня вырос ровно на 1',
          hn['sizekgc'] == ho['sizekgc'] + 1,
          f"{ho['sizekgc']} -> {hn['sizekgc']}")
    for key in ('flags', 'numparams', 'framesize', 'sizeuv', 'sizekn', 'sizebc'):
        check(f'поле {key} корня не изменилось', ho[key] == hn[key],
              f"{ho[key]} -> {hn[key]}")

    print('== Тело прототипа: байткод/uv/прочие константы идентичны ==')
    o0 = ljbc.kgc_start_offset(co[-1][3], ho)
    n0 = ljbc.kgc_start_offset(cf[-1][3], hn)
    w_old = len(ljbc.uleb_write(ho['sizekgc']))
    w_new = len(ljbc.uleb_write(hn['sizekgc']))
    # префикс без ULEB-значования sizekgc (оно намеренно увеличено на 1)
    pre_old = co[-1][3][:4] + co[-1][3][4 + w_old:o0]
    pre_new = cf[-1][3][:4] + cf[-1][3][4 + w_new:n0]
    check('префикс до kgc совпадает (кроме значения sizekgc)', pre_old == pre_new)
    delta = len(cf[-1][3]) - len(co[-1][3])
    inserted = cf[-1][3][n0:n0 + delta]
    check('вставлен только тег строки + маркер', inserted[1:] == MARKER,
          inserted.hex())
    check('тег = BCDUMP_KGC_STR(5) + длина маркера',
          inserted[0] == 5 + len(MARKER))
    check('хвост kgc/kn совпадает', cf[-1][3][n0 + delta:] == co[-1][3][o0:])

    print('== Версия исходника ==')
    check('константа GRND_SCRIPT_VERSION "1.21" присутствует в обоих файлах',
          b'\x091.21' in orig and b'\x091.21' in fixed)
    check('маркер 1.21.0 присутствует только в fixed',
          MARKER not in orig and MARKER in fixed)

    print('== Манифест ==')
    check('update.txt = строка "1.21.0" с LF', manifest == b'1.21.0\n',
          repr(manifest))

    print()
    if failures:
        print(f'ИТОГ: {failures} провалено')
        sys.exit(1)
    print('ИТОГ: все структурные проверки пройдены')


if __name__ == '__main__':
    main()
