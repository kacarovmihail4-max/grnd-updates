#!/usr/bin/env python3
"""Build the published 1.21 update package.

What it does, and why:

* The updater's ``detectVersion`` first tries the SOURCE pattern
  ``GRND_SCRIPT_VERSION%s*=%s*"([%d%.]+)"`` on the downloaded file. The shipped
  artifact is stripped LuaJIT bytecode, where that text never appears
  contiguously, so the check falls through to an X.Y.Z gmatch whose minimum
  hit is ``0.0.0`` -- every downloaded bytecode was rejected.
* The Lua source (and therefore GRND_SCRIPT_VERSION, which stays exactly
  ``1.21``) is not available in this update-channel repository, so the script
  cannot be recompiled. Instead we add one *unreferenced* string constant to
  the root prototype that makes the authoritative source-pattern branch
  succeed. No instruction, operand or existing constant changes (verified by
  bytecode disassembly diff); every child prototype stays byte-identical.
* ``update.txt`` is the transitional X.Y.Z manifest required by the 1.20
  client (it parses only ``%d+.%d+.%d+``). The 1.21 updater accepts both
  forms.
"""
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ljbc  # noqa: E402

SCRIPT_VERSION = "1.21"          # GRND_SCRIPT_VERSION -- never changed
MANIFEST_VERSION = "1.21.0"      # X.Y.Z label of the same release
MARKER = f'GRND_SCRIPT_VERSION="{MANIFEST_VERSION}"'


def main(inp, out_luac, out_manifest):
    data = open(inp, 'rb').read()
    assert data[:4] == b'\x1bLJ\x02' and data[4] == 0x02, \
        'input must be stripped non-FR2 LuaJIT 2.1 bytecode'
    # The real script version constant is present as a kgc string:
    # tag = BCDUMP_KGC_STR(5) + len("1.21")(4) = 0x09, then the raw bytes.
    assert b'\x09' + SCRIPT_VERSION.encode() in data, \
        f'GRND_SCRIPT_VERSION constant {SCRIPT_VERSION} not found'
    assert MARKER.encode() not in data, 'marker already present (idempotency guard)'

    patched, info = ljbc.insert_root_string_constant(data, MARKER)

    # Re-parse the result and prove every child chunk is untouched.
    _, _, old = ljbc.parse_dump(data)
    _, _, new = ljbc.parse_dump(patched)
    assert len(old) == len(new)
    for i in range(len(old) - 1):
        assert old[i][3] == new[i][3], f'child prototype {i} changed'
    assert patched[:4] == b'\x1bLJ\x02' and patched[4] == 0x02
    assert b'\x09' + SCRIPT_VERSION.encode() in patched, \
        'original version constant must survive'
    assert MARKER.encode() in patched

    open(out_luac, 'wb').write(patched)
    with open(out_manifest, 'w', newline='\n') as f:
        f.write(MANIFEST_VERSION + '\n')

    print(f'wrote {out_luac}: {len(data)} -> {len(patched)} bytes '
          f'(root kgc {info["sizekgc"][0]} -> {info["sizekgc"][1]}, '
          f'delta {info["delta"]})')
    print(f'wrote {out_manifest}: {MANIFEST_VERSION}')
    print('sha256 luac    :', hashlib.sha256(patched).hexdigest())
    print('sha256 manifest:',
          hashlib.sha256((MANIFEST_VERSION + '\n').encode()).hexdigest())


if __name__ == '__main__':
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    inp = sys.argv[1] if len(sys.argv) > 1 else os.path.join(base, 'grnd_adm_tools.luac')
    out_luac = sys.argv[2] if len(sys.argv) > 2 else os.path.join(base, 'grnd_adm_tools.luac')
    out_manifest = sys.argv[3] if len(sys.argv) > 3 else os.path.join(base, 'update.txt')
    main(inp, out_luac, out_manifest)
