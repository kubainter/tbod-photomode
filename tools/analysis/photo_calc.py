import os, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'capstone', 'lib'))
from capstone import Cs, CS_ARCH_X86, CS_MODE_64, CS_AC_READ, CS_AC_WRITE
from capstone.x86 import X86_OP_MEM, X86_OP_REG, X86_REG_RCX, X86_REG_RDX, X86_REG_RSI, X86_REG_RDI, X86_REG_R8

EXE = r'G:\Steam\steamapps\common\The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\Dawnwalker.exe'
PREF = 0x140000000
VT_RVA = 0x8115F08          # APhotoCameraActor CDO vtable (patch3 jmap 0x7ff618c25f08 - base 0x7ff610b10000)
GAP_LO, GAP_HI = 0x380, 0xC10   # unreflected region of APhotoCameraActor

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

# read vtable slots until non-code pointer
slots = []
k = 0
while True:
    r = u64(VT_RVA + 8 * k) - PREF
    if not is_exec(r):
        break
    slots.append(r)
    k += 1
print('PhotoCameraActor vtable exec slots: %d' % len(slots))

def scan_fn(start_rva, max_ins=400):
    """Return (gap_reads, out_writes, n_ins). gap_reads: list of (disp, ins_str);
       out_writes: writes to mem disp 0x20..0x80 on non-rcx base."""
    gap, outw, n = [], [], 0
    p = off(start_rva)
    end = min(p + 0x4000, T_END)
    seen_ret = False
    while p < end and n < max_ins:
        gen = md.disasm(data[p:p + 16], rva_of(p), 1)
        ins = next(gen, None)
        if ins is None:
            break
        n += 1
        try:
            ops = ins.operands
        except Exception:
            ops = []
        for op in ops:
            if op.type != X86_OP_MEM:
                continue
            base = op.mem.base
            disp = op.mem.disp
            acc = ''
            if op.access & CS_AC_READ: acc += 'R'
            if op.access & CS_AC_WRITE: acc += 'W'
            if GAP_LO <= disp <= GAP_HI:
                gap.append((disp, '%s %s' % (ins.mnemonic, ins.op_str), acc, ins.address))
            if base != X86_REG_RCX and 0x20 <= disp <= 0x80:
                outw.append((disp, '%s %s' % (ins.mnemonic, ins.op_str), acc, ins.address))
        p += ins.size
        if ins.mnemonic == 'ret':
            seen_ret = True
            break
    return gap, outw, n, seen_ret

best = []
for idx, r in enumerate(slots):
    try:
        gap, outw, n, ret = scan_fn(r)
    except Exception:
        continue
    # score: functions reading gap AND writing out-struct = strong CalcCamera/POV candidates
    score = len(gap) * 2 + len(outw)
    if gap or outw:
        best.append((score, idx, r, gap, outw, n, ret))

best.sort(key=lambda t: -t[0])
print('\nTop candidate slots (gap reads / out writes):')
for score, idx, r, gap, outw, n, ret in best[:8]:
    print('\nslot %d fn 0x%X ins=%d ret=%s score=%d' % (idx, r, n, ret, score))
    for disp, s, acc, a in gap[:12]:
        print('   GAP   0x%X %s [%s]' % (a, s, acc))
    for disp, s, acc, a in outw[:12]:
        print('   OUTw  0x%X %s [%s] disp=0x%X' % (a, s, acc, disp))
