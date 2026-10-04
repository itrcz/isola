#!/usr/bin/env python3
"""Destructive only to newly-created temporary fixture images, never a user's VM."""
import hashlib, json, pathlib, plistlib, struct, subprocess, tempfile, uuid, zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
SMOKE = ROOT / '.build/disk-expansion-smoke'
def run(*args):
    return subprocess.run([str(a) for a in args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

def attach(image, mount=False):
    flags = [] if mount else ['-nomount']
    result = plistlib.loads(run('hdiutil', 'attach', *flags, '-noautofsck', '-imagekey', 'diskimage-class=CRawDiskImage', image, '-plist'))
    entities = result['system-entities']
    device = next(e['dev-entry'] for e in entities if e['dev-entry'].removeprefix('/dev/disk').isdigit())
    return device, entities

def digest(path):
    with open(path, 'rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

with tempfile.TemporaryDirectory(prefix='IsolaDiskExpansionTest-', dir=ROOT/'.build') as directory:
    folder = pathlib.Path(directory)
    image = folder / 'Disk.img'
    with open(image, 'wb') as f: f.truncate(1024**3)
    suffix = uuid.uuid4().hex[:8]
    names = ['IsolaSystem'+suffix, 'IsolaRecovery'+suffix]
    device, _ = attach(image)
    try:
        run('diskutil', 'partitionDisk', device, 'GPT', 'APFS', names[0], '400m', 'APFS', names[1], 'R')
        for name in names:
            (pathlib.Path('/Volumes')/name/'preserve.txt').write_text(name)
    finally:
        run('hdiutil', 'detach', device)
    # Give the second real APFS partition the standard Apple recovery GPT type.
    with open(image, 'r+b') as f:
        f.seek(512); h = bytearray(f.read(512)); backup = struct.unpack_from('<Q',h,32)[0]
        f.seek(1024); entries = bytearray(f.read(16384))
        entries[128:144] = uuid.UUID('52637672-7900-11aa-aa11-00306543ecac').bytes_le
        for lba in [1, backup]:
            f.seek(lba*512); header=bytearray(f.read(512)); entry_lba=struct.unpack_from('<Q',header,72)[0]
            f.seek(entry_lba*512); f.write(entries)
            struct.pack_into('<I',header,88,zlib.crc32(entries)); struct.pack_into('<I',header,16,0)
            struct.pack_into('<I',header,16,zlib.crc32(header[:struct.unpack_from('<I',header,12)[0]]))
            f.seek(lba*512); f.write(header)
    original_hash = digest(image)
    # Move is smaller than Recovery: tests overlapping source/destination regions.
    print(run(SMOKE, folder, 1200*1024**2).decode())
    backups=list(folder.glob('Before expansion */Disk.img'))
    assert len(backups)==1 and digest(backups[0]) == original_hash, 'original backup changed'
    device, entities = attach(image, mount=True)
    try:
        mountpoints = [pathlib.Path(e['mount-point']) for e in entities if 'mount-point' in e]
        assert sorted((p/'preserve.txt').read_text() for p in mountpoints) == sorted(names)
    finally:
        run('hdiutil','detach',device)
    # Further growth works on an already relocated image.
    print(run(SMOKE, folder, 2*1024**3).decode())
    # Failure after relocation but before attach must keep the original byte-for-byte.
    unchanged = digest(image)
    run(SMOKE, folder, 3*1024**3, '--fail')
    assert digest(image) == unchanged
    # Corrupt primary GPT: fail closed without changing this copy.
    with open(image,'r+b') as f: f.seek(512+16); f.write(b'FAIL')
    before = digest(image)
    failed=subprocess.run([str(SMOKE), str(folder), str(3*1024**3)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert failed.returncode != 0 and digest(image) == before
    print('PASS: APFS grow, overlapping Recovery relocation, backup hash, both files preserved, repeated growth, corrupt GPT refusal')
