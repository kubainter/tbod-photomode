import os, re, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'capstone', 'lib'))
from capstone import Cs, CS_ARCH_X86, CS_MODE_64, CS_AC_READ, CS_AC_WRITE
from capstone.x86 import X86_OP_MEM

GAME = r'G:\Steam\steamapps\common\The Blood of Dawnwalker\Dawnwalker\Binaries\Win64'
EXE = os.path.join(GAME, 'Dawnwalker.exe')
JMAP = os.path.join(GAME, 'ue4ss', 'Dawnwalker-5.5.4-265636+dw1-pc-265636-shipping-patch3-all-97b7e501c.jmap')
PREF = 0x140000000
DUMP_BASE = 0x7ff610b10000
DISP = 0x9B4

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

jm = open(JMAP, 'rb').read()

def cdo_vt(key):
    m = re.search(rb'\n"' + re.escape(key) + rb'": \{[^}]*?"vtable": "0x([0-9a-fA-F]+)"', jm)
    if not m:
        raise SystemExit('CDO not found: ' + key.decode())
    return int(m.group(1), 16) - DUMP_BASE

def class_vt(cls):
    m = re.search(rb'"vtable": "0x([0-9a-fA-F]+)",\s*"object_flags": [^\n]*\n\s*"outer": [^\n]*\n\s*"class": "' + re.escape(cls) + rb'"', jm)
    if not m:
        raise SystemExit('no instance of class: ' + cls.decode())
    return int(m.group(1), 16) - DUMP_BASE

cam_vt = class_vt(b'/Script/Engine.CameraComponent')
reb_vt = class_vt(b'/Script/RebelCamera.RebelCameraComponent')
cam = vt_slots(cam_vt)
reb = vt_slots(reb_vt)
print('CameraComponent vt slots=%d  RebelCameraComponent vt slots=%d' % (len(cam), len(reb)))

overrides = [(k, reb[k]) for k in range(min(len(cam), len(reb))) if reb[k] != cam[k]]
print('overridden slots in RebelCameraComponent: %d' % len(overrides))

md = Cs(CS_ARCH_X86, CS_MODE_64)
md.detail = True
md.skipdata = True

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

def disasm_fn(s):
    out, p = [], s
    while p < T_END and p - s < 0x4000:
        if data[p] == 0xCC and out:
            break
        gen = md.disasm(data[p:p + 16], rva_of(p), 1)
        ins = next(gen, None)
        if ins is None:
            break
        tgt = None
        if ins.mnemonic in ('call', 'jmp') and ins.op_str.startswith('0x'):
            try:
                tgt = int(ins.op_str, 16)
            except ValueError:
                tgt = None
        out.append((ins.address, ins.size, acc_9b4(ins), tgt))
        p += ins.size
    return out

def fn_start(o):
    p = o
    lim = max(T_RAW + 1, o - 0x4000)
    while p > lim and data[p - 1] != 0xCC:
        p -= 1
    return p if data[p - 1] == 0xCC else None

starts = set()
p = T_RAW
while True:
    i = data.find(b'\xB4\x09\x00\x00', p, T_END)
    if i < 0:
        break
    p = i + 1
    s = fn_start(i)
    if s is not None:
        starts.add(rva_of(s))
hot = {}
for r in starts:
    body = disasm_fn(off(r))
    if any(acc for _, _, acc, _ in body):
        hot[r] = sum(sz for _, sz, _, _ in body)
print('functions touching +0x9B4: %d' % len(hot))

print('\n--- overridden slots: direct +0x9B4 access or calls into +0x9B4 functions ---')
for k, r in overrides:
    body = disasm_fn(off(r))
    direct = [(a, acc) for a, _, acc, _ in body if acc]
    calls = sorted({t for _, _, _, t in body if t is not None})
    hot_calls = [t for t in calls if t in hot]
    size = sum(sz for _, sz, _, _ in body)
    if direct or hot_calls:
        print('slot %3d  fn 0x%X size=%d  9B4-direct=%s  calls->9B4fns=[%s]  calls=%d' % (
            k, r, size, ','.join('0x%X:%s' % (a, '/'.join(x)) for a, x in direct) or '-',
            ', '.join('0x%X' % t for t in hot_calls) or '-', len(calls)))

print('\n--- every +0x9B4 function: callers (direct call/jmp) ---')
callers = {r: [] for r in hot}
p = T_RAW
while True:
    i = data.find(b'\xE8', p, T_END - 5)
    if i < 0:
        break
    p = i + 1
    tgt = rva_of(i) + 5 + struct.unpack_from('<i', data, i + 1)[0]
    if tgt in callers and len(callers[tgt]) < 8:
        callers[tgt].append(rva_of(i))
for r in sorted(hot):
    print('0x%X size=%-6d callers=[%s]' % (r, hot[r], ', '.join('0x%X' % c for c in callers[r])))
