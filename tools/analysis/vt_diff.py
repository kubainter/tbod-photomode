import os, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'capstone', 'lib'))

EXE = r'G:\Steam\steamapps\common\The Blood of Dawnwalker\Dawnwalker\Binaries\Win64\Dawnwalker.exe'
PREF = 0x140000000
BASE = 0x7ff610b10000

VT = {
    'PhotoCameraActor': 0x7ff618c25f08 - BASE,
    'DefaultPawn':      0x7ff61852c608 - BASE,
    'Pawn':             0x7ff61830c3e8 - BASE,
    'Actor':            0x7ff6182f3ce8 - BASE,
    'CameraActor':      0x7ff618366e88 - BASE,
}

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

def is_exec(rva):
    return any(va <= rva < va + span and ex for va, span, _, ex, _ in secs)

def u64(rva):
    return struct.unpack_from('<Q', data, off(rva))[0]

def vt_slots(vt, n=900):
    out = []
    for k in range(n):
        r = u64(vt + 8 * k) - PREF
        if not is_exec(r):
            break
        out.append(r)
    return out

tables = {name: vt_slots(rva) for name, rva in VT.items()}
for name, t in tables.items():
    print(name, len(t), 'slots')

pa, dp = tables['PhotoCameraActor'], tables['DefaultPawn']
print('\nDiff slots PhotoCameraActor vs DefaultPawn:')
for i, (a, b) in enumerate(zip(pa, dp)):
    if a != b:
        # also show if equal to Pawn/Actor slot (inherited unchanged vs grandparent)
        tag = ''
        if i < len(tables['Pawn']) and tables['Pawn'][i] == a:
            tag = ' (== Pawn)'
        if i < len(tables['Actor']) and tables['Actor'][i] == a:
            tag += ' (== Actor)'
        if i < len(tables['CameraActor']) and tables['CameraActor'][i] == a:
            tag += ' (== CameraActor)'
        print('  slot %3d  PA=0x%08X  DP=0x%08X%s' % (i, a, b, tag))
