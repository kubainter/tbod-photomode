import os, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'capstone', 'lib'))
from capstone import Cs, CS_ARCH_X86, CS_MODE_64, CS_AC_READ, CS_AC_WRITE
from capstone.x86 import X86_OP_MEM

EXE = r'G:\Steam\steamapps\common\The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\Dawnwalker.exe'
PREF = 0x140000000
VT_RVA = 0x8115F08
GAP_LO, GAP_HI = 0x380, 0xC10

data = open(EXE, 'rb').read()
pe = struct.unpack_from('<I', data, 0x3C)[0]
nsec = struct.unpack_from('<H', data, pe + 6)[0]
optsz = struct.unpack_from('<H', data, pe + 20)[0]
secs = []
for i in range(nsec):
    o = pe + 24 + optsz + 40 * i
    vsz, va, rsz, rptr = struct.unpack_from('<IIII', data, o + 8)
    ch = struct.unpack_from('<I', data, o + 36)[0]
    secs.append((va, max(vsz, rsz), rptr, bool(ch & 0x20000000), data[o:o + 8].rstrip(b'\0').decode(errors='replace')))

def off(rva):
    for va, span, raw, _, _ in secs:
        if va <= rva < va + span:
            return raw + rva - va
    raise ValueError(hex(rva))

def rva_of(o):
    for va, span, raw, _, _ in secs:
        if raw <= o < raw + span:
            return o - raw + va
    raise ValueError(hex(o))

def is_exec(rva):
    return any(va <= rva < va + span and ex for va, span, _, ex, _ in secs)

def u64(rva):
    return struct.unpack_from('<Q', data, off(rva))[0]

TEXT = [s for s in secs if s[4] == '.text'][0]
T_RAW, T_SPAN = TEXT[2], TEXT[1]
T_END = T_RAW + T_SPAN

md = Cs(CS_ARCH_X86, CS_MODE_64)
md.detail = True
md.skipdata = True

slots = []
k = 0
while True:
    r = u64(VT_RVA + 8 * k) - PREF
    if not is_exec(r):
        break
    slots.append(r)
    k += 1

for idx, r in enumerate(slots):
    try:
        p = off(r)
    except Exception:
        continue
    gap_hits = []
    n = 0
    q = p
    while q < min(p + 0x6000, T_END) and n < 600:
        gen = md.disasm(data[q:q + 16], rva_of(q), 1)
        ins = next(gen, None)
        if ins is None:
            break
        n += 1
        try:
            ops = ins.operands
        except Exception:
            ops = []
        for op in ops:
            if op.type == X86_OP_MEM and GAP_LO <= op.mem.disp <= GAP_HI:
                acc = ('R' if op.access & CS_AC_READ else '') + ('W' if op.access & CS_AC_WRITE else '')
                gap_hits.append((ins.address, ins.mnemonic, ins.op_str, acc, op.mem.disp))
        q += ins.size
        if ins.mnemonic == 'ret':
            break
    if gap_hits:
        uniq = {}
        for a, mn, ops, acc, d in gap_hits:
            uniq.setdefault(d, []).append((a, mn, ops, acc))
        print('slot %3d fn 0x%X  gap offsets: %s' % (idx, r, ', '.join('0x%X' % d for d in sorted(uniq))))
        for d in sorted(uniq):
            for a, mn, ops, acc in uniq[d][:3]:
                print('        0x%X  %s %s [%s] ->0x%X' % (a, mn, ops, acc, d))
