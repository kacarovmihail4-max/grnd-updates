#!/usr/bin/env python3
"""LuaJIT 2.1 bytecode-dump (BCDUMP_VERSION 2) structural editor.

Scope: stripped dumps as produced by MoonLoader's 32-bit LuaJIT
(``1B 4C 4A 02 02`` magic, no BCDUMP_F_FR2).

The dump is a flat stream of self-delimiting prototype chunks, each prefixed
by a ULEB128 length, followed by a single zero terminator. Every chunk has a
fixed header (flags, numparams, framesize, sizeuv + ULEB sizekgc/sizekn/sizebc),
then (sizebc-1) instruction words, sizeuv upvalue refs, the GC constants
(kgc), then number constants (kn).

Runtime kgc slots are k[-1] (last entry in dump order) .. k[-sizekgc]
(first entry). Bytecode KGC operands address k[-1-n], so a string constant
PREPENDED to the kgc section lands at k[-(sizekgc+1)] and does not shift any
existing operand. That is the only mutation this tool performs.

Reference: LuaJIT src/lj_bcread.c, src/lj_bcwrite.c, src/lj_bcdump.h.
"""

BCDUMP_HEAD1 = 0x1B
BCDUMP_F_STRIP = 0x02
BCDUMP_KGC_CHILD, BCDUMP_KGC_TAB, BCDUMP_KGC_I64, BCDUMP_KGC_U64, \
    BCDUMP_KGC_COMPLEX, BCDUMP_KGC_STR = range(6)


def uleb_read(buf, pos):
    v = 0
    sh = 0
    while True:
        b = buf[pos]
        pos += 1
        v |= (b & 0x7F) << sh
        if not (b & 0x80):
            return v, pos
        sh += 7


def uleb_write(v):
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def parse_dump(data):
    """Return (version, flags, chunks); chunks=(len_pos, body_pos, len, body)."""
    assert data[0] == BCDUMP_HEAD1 and data[1:3] == b'LJ', 'bad magic'
    version, flags = data[3], data[4]
    assert version == 2, f'unsupported BCDUMP_VERSION {version}'
    pos = 5
    if not (flags & BCDUMP_F_STRIP):
        nlen, pos = uleb_read(data, pos)
        pos += nlen
    chunks = []
    while True:
        assert pos < len(data), 'missing EOF terminator'
        if data[pos] == 0:
            pos += 1
            break
        len_pos = pos
        clen, body_pos = uleb_read(data, pos)
        body = data[body_pos:body_pos + clen]
        assert len(body) == clen, 'truncated chunk'
        chunks.append((len_pos, body_pos, clen, body))
        pos = body_pos + clen
    assert pos == len(data), f'trailing bytes after terminator: {len(data)-pos}'
    return version, flags, chunks


def parse_chunk_header(body):
    flags, numparams, framesize, sizeuv = body[0:4]
    p = 4
    sizekgc, p = uleb_read(body, p)
    sizekn, p = uleb_read(body, p)
    sizebc, p = uleb_read(body, p)
    return {'flags': flags, 'numparams': numparams, 'framesize': framesize,
            'sizeuv': sizeuv, 'sizekgc': sizekgc, 'sizekn': sizekn,
            'sizebc': sizebc + 1, 'hdr_end': p}


def kgc_start_offset(body, h):
    # bc[0] (FUNCV/FUNCF) is synthesized by the reader; only sizebc-1 words
    # are stored, followed by sizeuv 16-bit upvalue refs.
    return h['hdr_end'] + (h['sizebc'] - 1) * 4 + h['sizeuv'] * 2


def insert_root_string_constant(data, marker):
    """Prepend a string GC constant to the ROOT proto (the last chunk).

    Returns (new_bytes, info_dict). The root is chosen so only one chunk
    length prefix has to be rewritten; child chunks stay byte-identical.
    """
    version, flags, chunks = parse_dump(data)
    assert flags & BCDUMP_F_STRIP, 'only stripped dumps supported'
    idx = len(chunks) - 1
    len_pos, body_pos, clen, body = chunks[idx]
    h = parse_chunk_header(body)
    ins_at = kgc_start_offset(body, h)
    tag = body[ins_at]
    assert tag in (BCDUMP_KGC_CHILD, BCDUMP_KGC_TAB, BCDUMP_KGC_I64,
                   BCDUMP_KGC_U64, BCDUMP_KGC_COMPLEX) or tag >= BCDUMP_KGC_STR, \
        f'bad kgc tag {tag} at insertion point'

    marker_b = marker.encode('utf-8')
    enc = uleb_write(BCDUMP_KGC_STR + len(marker_b)) + marker_b
    old_kgc = uleb_write(h['sizekgc'])
    new_kgc = uleb_write(h['sizekgc'] + 1)
    assert body[4:4 + len(old_kgc)] == old_kgc

    new_body = (body[:ins_at] + enc + body[ins_at:])
    new_body = new_body[:4] + new_kgc + new_body[4 + len(old_kgc):]

    out = bytearray()
    out += data[:len_pos]
    out += uleb_write(len(new_body))
    out += new_body
    out += data[body_pos + clen:]
    info = {'chunk': idx, 'sizekgc': (h['sizekgc'], h['sizekgc'] + 1),
            'inserted_bytes': len(enc), 'delta': len(out) - len(data),
            'version': version, 'flags': flags}
    return bytes(out), info


if __name__ == '__main__':
    import sys
    _, flags, chunks = parse_dump(open(sys.argv[1], 'rb').read())
    print(f'flags=0x{flags:02x} chunks={len(chunks)}')
    root = parse_chunk_header(chunks[-1][3])
    print('root proto:', {k: root[k] for k in
          ('flags', 'sizekgc', 'sizekn', 'sizebc', 'sizeuv')})
