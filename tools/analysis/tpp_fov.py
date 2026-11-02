import os, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'capstone', 'lib'))
from capstone import Cs, CS_ARCH_X86, CS_MODE_64, CS_AC_READ, CS_AC_WRITE
from capstone.x86 import X86_OP_MEM

EXE = r'G:\Steam\steamapps\common\The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\Dawnwalker.exe'
PREF = 0x140000000
DISP = 0x9B4
TPP_VT = 0x780C4C0

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

TEXT = [s for s in secs if s[4] == '.text'][0]
T_RAW, T_VA, T_SPAN = TEXT[2], TEXT[0], TEXT[1]
T_END = T_RAW + T_SPAN

def u64(rva):
    return struct.unpack_from('<Q', data, off(rva))[0]

def vt_slots(vt, n=400):
    out = []
    for k in range(n):
        r = u64(vt + 8 * k) - PREF
        if not is_exec(r):
            break
        out.append(r)
    return out

tpp = vt_slots(TPP_VT)
slot_of = {r: k for k, r in enumerate(tpp)}
print('TPP vtable exec slots: %d | slot 89 -> 0x%X' % (len(tpp), tpp[89]))

cands = []
p = T_RAW
while True:
    i = data.find(b'\xB4\x09\x00\x00', p, T_END)
    if i < 0:
        break
    cands.append(i)
    p = i + 1

def fn_start(o):
    p = o
    lim = max(T_RAW + 1, o - 0x4000)
    while p > lim and data[p - 1] != 0xCC:
        p -= 1
    return p if data[p - 1] == 0xCC else None

md = Cs(CS_ARCH_X86, CS_MODE_64)
md.detail = True
md.skipdata = True

def disasm_fn(s):
    out, p = [], s
    while p < T_END and p - s < 0x4000:
        if data[p] == 0xCC and out:
            break
        gen = md.disasm(data[p:p + 16], rva_of(p), 1)
        ins = next(gen, None)
        if ins is None:
            break
        out.append((ins.address, ins.mnemonic, ins.op_str, ins.size, acc_9b4(ins)))
        p += ins.size
    return out

def acc_9b4(ins):
    res = []
    try:
        ops = ins.operands
    except Exception:
        return res
    for op in ops:
        if op.type == X86_OP_MEM and op.mem.disp == DISP and op.mem.index == 0:
            a = ('R' if op.access & CS_AC_READ else '') + ('W' if op.access & CS_AC_WRITE else '')
            res.append(a or '?')
    return res

starts = set()
nopad = 0
for o in cands:
    s = fn_start(o)
    if s is None:
        nopad += 1
    else:
        starts.add(s)
print('disp32 0x9B4 candidates: %d | distinct function starts: %d | no CC padding found: %d' % (len(cands), len(starts), nopad))

results = []
for s in sorted(starts):
    ins_list = disasm_fn(s)
    hits = [(a, mn, ops, acc) for a, mn, ops, _, acc in ins_list if acc]
    if hits:
        results.append((rva_of(s), sum(sz for _, _, _, sz, _ in ins_list), hits))

want = {r for r, _, _ in results}
callers = {r: [] for r in want}
p = T_RAW
while True:
    i = data.find(b'\xE8', p, T_END - 5)
    if i < 0:
        break
    p = i + 1
    tgt = rva_of(i) + 5 + struct.unpack_from('<i', data, i + 1)[0]
    if tgt in callers and len(callers[tgt]) < 6:
        callers[tgt].append(rva_of(i))

print('functions touching +0x9B4: %d' % len(results))
for r, size, hits in results:
    slot = slot_of.get(r)
    print('\nfn 0x%X size=%d tppSlot=%s callers=[%s]' % (r, size, slot if slot is not None else '-', ', '.join('0x%X' % c for c in callers[r])))
    for a, mn, ops, acc in hits:
        print('   0x%X  %s %s  -> %s' % (a, mn, ops, '/'.join(acc)))
