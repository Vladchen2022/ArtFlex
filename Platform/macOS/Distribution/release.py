#!/usr/bin/env python3
"""Local, traceable builds and reversible installs; no network service or dependency."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
DIST = Path(__file__).resolve().parent
MANIFEST = 'BuildManifest.json'

def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()

def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()

def tree_digest(path):
    h = hashlib.sha256()
    for file in sorted(p for p in path.rglob('*') if p.is_file()):
        h.update(str(file.relative_to(path)).encode()); h.update(digest(file).encode())
    return h.hexdigest()

def source_files():
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
    return sorted(p for p in paths if p and '__pycache__' not in p and not p.endswith('.pyc') and (p.startswith(('Core/', 'Rendering/', 'Infrastructure/', 'Platform/')) or p in ('Package.swift', 'Package.resolved')) and (ROOT / p).is_file())

def source_digest():
    h = hashlib.sha256()
    for p in source_files(): h.update(p.encode()); h.update(digest(ROOT / p).encode())
    return h.hexdigest()

def binary_uuid(path):
    return run('dwarfdump', '--uuid', str(path)).splitlines()[0].split()[1]

def verify_products(products):
    data = json.loads((products / MANIFEST).read_text())
    assert data['sourceFingerprint'] == source_digest(), 'Source changed since build; rebuild first'
    assert data['executableSHA256'] == digest(products / 'ArtFlex'), 'Build executable changed'
    assert data['resourcesSHA256'] == tree_digest(products / 'ArtFlex_ArtFlex.bundle'), 'Build resources changed'
    assert data['binaryUUID'] == binary_uuid(products / 'ArtFlex'), 'Build UUID mismatch'
    return data

def verify_app(app):
    data = json.loads((app / 'Contents/Resources' / MANIFEST).read_text())
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert data['buildVersion'] == info['CFBundleVersion'], 'Bundle/manifest version mismatch'
    assert data['binaryUUID'] == binary_uuid(app / 'Contents/MacOS/ArtFlex'), 'Installed UUID mismatch'
    assert data['resourcesSHA256'] == tree_digest(app / 'Contents/Resources/ArtFlex_ArtFlex.bundle'), 'Installed resource mismatch'
    assert (app / 'Contents/Resources' / info['CFBundleIconFile']).is_file(), 'Missing icon'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    return data

def install(source, target, legacy_verified=False):
    source, target = source.resolve(), target.absolute()
    assert source != target and target.suffix == '.app', 'Choose a different .app destination'
    def verify(path):
        if legacy_verified:
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(path)], check=True)
            assert tree_digest(path) == legacy_verified, 'Rollback backup differs from recorded bytes'
        else: verify_app(path)
    verify(source)
    # Refuse replacing running builds, even if launched by another bundle alias.
    assert subprocess.run(['pgrep', '-x', 'ArtFlex'], stdout=subprocess.DEVNULL).returncode != 0, 'Quit ArtFlex before installation'
    target.parent.mkdir(parents=True, exist_ok=True)
    backup_root = ROOT / '.build/install-backups'
    backup_root.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    backup = backup_root / (stamp + '-' + target.name)
    staging = Path(tempfile.mkdtemp(prefix='.artflex-install-', dir=target.parent)) / target.name
    moved = False
    try:
        subprocess.run(['ditto', str(source), str(staging)], check=True)
        verify(staging)
        if target.exists():
            subprocess.run(['ditto', str(target), str(backup)], check=True)
            # Verify backup byte identity before touching the old installation.
            backup_hash = tree_digest(backup)
            assert tree_digest(target) == backup_hash, 'Backup differs from installed application'
            backup.with_suffix('.json').write_text(json.dumps({'backup': str(backup), 'target': str(target), 'sha256': backup_hash}, indent=2))
            old = staging.parent / 'previous.app'
            os.rename(target, old)
            moved = True
        os.rename(staging, target)
        verify(target)
        print(json.dumps({'installed': str(target), 'backup': str(backup) if moved else None}, ensure_ascii=False))
    except BaseException:
        if moved:
            if target.exists(): shutil.rmtree(target)
            os.rename(staging.parent / 'previous.app', target)
        raise
    finally:
        shutil.rmtree(staging.parent)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    b = sub.add_parser('build'); b.add_argument('--configuration', choices=['debug', 'release'], default='release')
    v = sub.add_parser('verify-products'); v.add_argument('path', type=Path)
    v = sub.add_parser('verify-app'); v.add_argument('path', type=Path)
    i = sub.add_parser('install'); i.add_argument('source', type=Path); i.add_argument('--target', type=Path, default=Path('/Applications/ArtFlex.app'))
    rb = sub.add_parser('rollback'); rb.add_argument('record', type=Path)
    args = parser.parse_args()
    if args.command == 'build':
        before = source_digest()
        subprocess.run(['swift', 'build', '-c', args.configuration], cwd=ROOT, check=True)
        assert before == source_digest(), 'Source changed during build; no manifest created'
        products = Path(run('swift', 'build', '-c', args.configuration, '--show-bin-path'))
        info = plistlib.loads((DIST / 'Info.plist').read_bytes())
        paths = source_files()
        dirty = bool(run('git', 'status', '--porcelain', '--', *paths))
        data = dict(schema=1, gitCommit=run('git', 'rev-parse', 'HEAD'), sourceDirty=dirty,
                    sourceFingerprint=before, buildVersion=info['CFBundleVersion'], configuration=args.configuration,
                    builtAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), binaryUUID=binary_uuid(products / 'ArtFlex'),
                    executableSHA256=digest(products / 'ArtFlex'), resourcesSHA256=tree_digest(products / 'ArtFlex_ArtFlex.bundle'))
        (products / MANIFEST).write_text(json.dumps(data, indent=2) + '\n')
        print(products / MANIFEST)
    elif args.command == 'verify-products': print(json.dumps(verify_products(args.path)))
    elif args.command == 'verify-app': print(json.dumps(verify_app(args.path)))
    elif args.command == 'install': install(args.source, args.target)

    elif args.command == 'rollback':
        record = json.loads(args.record.read_text())
        backup = Path(record['backup'])
        assert backup.parent == ROOT / '.build/install-backups', 'Not an ArtFlex install backup'
        assert tree_digest(backup) == record['sha256'], 'Backup changed'
        install(backup, Path(record['target']), legacy_verified=record['sha256'])
