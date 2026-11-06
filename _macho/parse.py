import struct, sys

path = sys.argv[1]
data = open(path, 'rb').read()

magic = struct.unpack('<I', data[:4])[0]
if magic != 0xfeedfacf:
    print('not mach-o64 le: %08x' % magic); sys.exit(1)

cputype, cpusub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack('<iiIIIII', data[4:32])
print('cputype=%d ncmds=%d sizeofcmds=%d' % (cputype, ncmds, sizeofcmds))

off = 32
LC_NAMES = {0xc: 'LC_LOAD_DYLIB', 0x8000001c: 'LC_LOAD_WEAK_DYLIB', 0x19: 'LC_SEGMENT_64',
            0x1d: 'LC_CODE_SIGNATURE', 0x1c: 'LC_RPATH', 0xe: 'LC_LOAD_DYLINKER',
            0x80000022: 'LC_DYLD_CHAINED_FIXUPS', 0x80000033: 'LC_DYLD_INFO_ONLY',
            0x32: 'LC_BUILD_VERSION', 0x26: 'LC_FUNCTION_STARTS', 0x29: 'LC_DATA_IN_CODE',
            0x1b: 'LC_UUID', 0x80000028: 'LC_MAIN', 0x2b: 'LC_SOURCE_VERSION',
            0x24e: 'LC_ENCRYPTION_INFO_64', 0x1e: 'LC_SEGMENT_SPLIT_INFO'}

dylibs = []
for i in range(ncmds):
    if off + 8 > len(data): break
    cmd, cmdsize = struct.unpack('<II', data[off:off+8])
    name = LC_NAMES.get(cmd, 'cmd_0x%x' % cmd)
    if cmd in (0xc, 0x8000001c, 0x1c):
        str_off = struct.unpack('<I', data[off+8:off+12])[0]
        s = data[off+str_off:off+cmdsize].split(b'\0')[0].decode('utf-8', 'replace')
        dylibs.append((name, s))
    off += cmdsize

print('--- load paths ---')
for n, s in dylibs:
    print('%-20s %s' % (n, s))
