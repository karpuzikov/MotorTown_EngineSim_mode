"""Read-only Windows DLL dependency audit for UE4SS error 0x7e.

Requires the Visual Studio dumpbin.exe already present on the build machine.
Never loads game DLLs or changes the installed mod.
"""

import argparse
from datetime import datetime
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


IMPORT_NAME = re.compile(r'^\s*([\w.+-]+\.dll)\s*$', re.IGNORECASE)
VIRTUAL_IMPORT = ('api-ms-win-', 'ext-ms-win-')


def find_dumpbin():
    found = shutil.which('dumpbin.exe') or shutil.which('dumpbin')
    if found:
        return Path(found)
    programs = os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')
    vswhere = Path(programs) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    if not vswhere.is_file():
        return None
    result = subprocess.run(
        [str(vswhere), '-latest', '-products', '*', '-property', 'installationPath'],
        capture_output=True, text=True, timeout=15)
    if result.returncode != 0 or not result.stdout.strip():
        return None
    tools_root = Path(result.stdout.strip()) / 'VC/Tools/MSVC'
    if not tools_root.is_dir():
        return None
    for version in sorted(tools_root.iterdir(), reverse=True):
        candidate = version / 'bin/Hostx64/x64/dumpbin.exe'
        if candidate.is_file():
            return candidate
    return None


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest().upper()


def imports(dumpbin, dll):
    result = subprocess.run(
        [str(dumpbin), '/dependents', str(dll)],
        capture_output=True, text=True, errors='replace', timeout=30)
    if result.returncode != 0:
        return None, (result.stdout + result.stderr).strip()[-1000:]
    names = []
    for line in result.stdout.splitlines():
        match = IMPORT_NAME.match(line)
        if match and match.group(1).lower() not in {n.lower() for n in names}:
            names.append(match.group(1))
    return names, None


def audit(game, work, dumpbin):
    mod = game / 'ue4ss/Mods/MotorTownEngineSim/dlls'
    installed = mod / 'main.dll'
    staged = work / 'build/UE4SS/dev-stage/ue4ss/Mods/MotorTownEngineSim/dlls/main.dll'
    lines = [
        'Motor Town native DLL loader audit (read only)',
        f'Game: {game}',
        f'Installed: {installed}',
        f'Staged: {staged}',
        f'Dumpbin: {dumpbin}',
    ]
    if not installed.is_file():
        lines.append('MISSING installed main.dll')
        return lines
    installed_hash = sha256(installed)
    lines.append(f'Installed main.dll SHA256: {installed_hash}')
    if staged.is_file():
        staged_hash = sha256(staged)
        lines.append(f'Staged main.dll SHA256: {staged_hash}')
        lines.append(('MATCH' if installed_hash == staged_hash else 'MISMATCH') +
                     ' installed main.dll == staged main.dll')
    else:
        lines.append('MISSING staged main.dll')

    runtime_dlls = sorted(mod.glob('*.dll'), key=lambda p: p.name.lower())
    lines.append(f'Installed mod DLLs: {len(runtime_dlls)}')
    for path in runtime_dlls:
        lines.append(f'  {path.name}: {path.stat().st_size} bytes')

    if dumpbin is None:
        lines.append('ERROR: Visual Studio dumpbin.exe not found; import audit unavailable.')
        return lines

    roots = [mod, game / 'ue4ss', game]
    windows = os.environ.get('WINDIR')
    if windows:
        roots.append(Path(windows) / 'System32')
    checked = set()
    pending = [installed]
    missing = set()
    while pending and len(checked) < 150:
        dll = pending.pop(0)
        key = str(dll).lower()
        if key in checked:
            continue
        checked.add(key)
        names, error = imports(dumpbin, dll)
        if error is not None:
            lines.append(f'ERROR inspecting {dll.name}: {error}')
            continue
        lines.append(f'Imports of {dll.name}: {len(names)}')
        for name in names:
            if name.lower().startswith(VIRTUAL_IMPORT):
                continue
            resolved = next((root / name for root in roots if (root / name).is_file()), None)
            if resolved is None:
                missing_key = (dll.name.lower(), name.lower())
                if missing_key not in missing:
                    missing.add(missing_key)
                    lines.append(f'MISSING {name} (imported by {dll.name})')
            else:
                lines.append(f'  {name} -> {resolved}')
                # UE4SS.dll is already loaded by the game; inspect only the
                # new mod and its bundled dependencies, not UE4SS internals.
                if resolved.parent == mod:
                    pending.append(resolved)
    lines.append(f'Unresolved import entries: {len(missing)}')
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-win64', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--dumpbin', type=Path, help='Override VS dumpbin for testing')
    args = parser.parse_args()
    report = audit(args.game_win64, args.work, args.dumpbin or find_dumpbin())
    target = args.work / 'logs' / ('NativeLoad_' + datetime.now().strftime('%Y-%m-%d-%H-%M-%S-%f') + '.txt')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text('\n'.join(report) + '\n', encoding='utf-8')
    print('\n'.join(report))
    print(f'\nReport saved: {target}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
