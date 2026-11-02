import os, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'capstone', 'lib'))
from capstone import Cs, CS_ARCH_X86, CS_MODE_64, CS_AC_READ, CS_AC_WRITE
from capstone.x86 import X86_OP_MEM, X86_REG_RSP

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
print('slots: %d' % len(slots))

def scan(start_rva, max_ins=500):
    p = off(start_rva)
    end = min(p + 0x6000, T_END)
    writes = {}      # base_reg -> set of disps written
    gap_acc = []     # accesses to gap offsets on rcx-relative regs (any base)
    n = 0
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
            base, disp = op.mem.base, op.mem.disp
            if op.access & CS_AC_WRITE and base != X86_REG_RSP and 0 <= disp < 0x100:
                writes.setdefault(base, set()).add((disp, ins.mnemonic))
            if GAP_LO <= disp <= GAP_HI:
                gap_acc.append((ins.address, ins.mnemonic, ins.op_str,
                                'W' if op.access & CS_AC_WRITE else 'R'))
        p += ins.size
        if ins.mnemonic == 'ret':
            break
    return writes, gap_acc, n

from capstone.x86_const import X86_REG_RAX as _RAX
import capstone.x86_const as XC
regname = {}
for nm in dir(XC):
    if nm.startswith('X86_REG_'):
        regname[getattr(XC, nm)] = nm[8:]

for idx, r in enumerate(slots):
    try:
        writes, gap, n = scan(r)
    except Exception:
        continue
    hit = False
    for base, ds in writes.items():
        disps = {d for d, _ in ds}
        has_loc = any(d in disps for d in (0x0, 0x8, 0x10))
        has_rot = any(d in disps for d in (0x18, 0x20, 0x28))
        has_fov = 0x30 in disps or 0x34 in disps
        if has_loc and has_rot and has_fov:
            hit = True
            print('\n=== slot %d fn 0x%X base=%s writes=%s' % (idx, r, regname.get(base, hex(base)), sorted(disps)))
    if hit:
        # dump the whole function for manual review
        p = off(r)
        cnt = 0
        while cnt < 500:
            gen = md.disasm(data[p:p + 16], rva_of(p), 1)
            ins = next(gen, None)
            if ins is None:
                break
            print('   0x%X  %s %s' % (ins.address, ins.mnemonic, ins.op_str))
            cnt += 1
            p += ins.size
            if ins.mnemonic == 'ret':
                break
        if gap:
            print('   -- gap accesses:')
            for a, mn, ops, acc in gap:
                print('   0x%X %s %s [%s]' % (a, mn, ops, acc))
