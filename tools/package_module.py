#!/usr/bin/env python3
"""Package one module ZIP, preserving source comments and the compiled observer."""
from pathlib import Path
import argparse, hashlib, json, subprocess, zipfile
ROOT = Path(__file__).resolve().parents[1]
FILES = ('module.prop', 'customize.sh', 'CoreGate.sh', 'service.sh', 'migrate-config.sh', 'uninstall.sh', 'action.sh', 'sepolicy.rule', 'config.example.json', 'packages.txt', 'capture.txt', 'update.json', 'LICENSE', 'FREEZE-UPSTREAM.txt')
LIBS = 'config hardware freeze cores frequency probe runtime thermal lifecycle commands'.split()
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, default=ROOT)
    ap.add_argument('--output', type=Path, default=ROOT / 'out')
    ap.add_argument('--binary', type=Path)
    args = ap.parse_args()
    files = {name: (args.source / name).read_bytes() for name in FILES}
    files.update({'lib/' + name + '.sh': (args.source / 'lib' / (name + '.sh')).read_bytes() for name in LIBS})
    for name, data in files.items():
        if name.endswith('.sh'):
            subprocess.run(['sh', '-n'], input=data, check=True, capture_output=True)
    prop = dict(line.split('=', 1) for line in files['module.prop'].decode().splitlines() if '=' in line and not line.startswith('#'))
    version = 'v' + prop['version'].removeprefix('v')
    update = json.loads(files['update.json'])
    assert update['version'] == version and update['versionCode'] == int(prop['versionCode'])
    json.loads(files['config.example.json'])
    binary = (args.binary or args.source / 'bin/coregated').read_bytes()
    if len(binary) < 20 or binary[:6] != b'\x7fELF\x02\x01' or int.from_bytes(binary[18:20], 'little') != 183:
        raise SystemExit('Expected compiled AArch64 ELF64 coregated')
    files['bin/coregated'] = binary
    args.output.mkdir(parents=True, exist_ok=True)
    target = args.output / ('CoreGate-' + version + '.zip')
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (0o100755 if name.endswith('.sh') or name.startswith('bin/') else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
    with zipfile.ZipFile(target) as archive:
        assert archive.testzip() is None
        assert {'CoreGate.sh', 'service.sh', 'customize.sh', 'lib/commands.sh', 'lib/lifecycle.sh'} <= set(archive.namelist()), 'Missing runtime entry or libraries'
        assert all(archive.read(name) == data for name, data in files.items())
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    target.with_suffix('.sha256').write_text(digest + '  ' + target.name + '\n')
    print(target, target.stat().st_size, 'bytes; syntax, versions, ELF and ZIP verification: PASS')
if __name__ == '__main__':
    main()
