"""Refuse to build the native DLL against an unknown or incomplete UE4SS tree.

The verified Motor Town installation reports UE4SS f885e8d2. The private
UEPseudo Unreal headers cannot be supplied by a generated game SDK dump.
"""

import argparse
from pathlib import Path
import subprocess
import sys


MOTORTOWN_UE4SS_COMMIT = 'f885e8d2d4dd25258082538f1a9fd56a1c3b1bf1'
PRIVATE_UNREAL_PATH = 'deps/first/Unreal'


def _git(source, *args):
    try:
        result = subprocess.run(
            ['git', '-C', str(source), *args], text=True, capture_output=True,
            check=False, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValueError(f'Cannot inspect UE4SS source checkout: {error}') from error
    if result.returncode:
        raise ValueError(f'Cannot inspect UE4SS source checkout: {result.stderr.strip()}')
    return result.stdout


def verify_checkout(source, expected_commit=MOTORTOWN_UE4SS_COMMIT):
    """Validate pinned UE4SS source revision and every nested submodule."""
    source = Path(source).resolve()
    if not (source / 'CMakeLists.txt').is_file() or not (
        source / 'UE4SS/include/Mod/CppUserModBase.hpp'
    ).is_file():
        raise ValueError('UE4SS source is missing its root build or native mod headers')

    root = Path(_git(source, 'rev-parse', '--show-toplevel').strip()).resolve()
    if root != source:
        raise ValueError('UE4SS source must be the root of its own Git checkout')
    commit = _git(source, 'rev-parse', 'HEAD').strip()
    if commit.lower() != expected_commit.lower():
        raise ValueError(f'UE4SS revision mismatch: installed version needs '
                         f'{expected_commit}; provided source is {commit}')

    # Leading status character is significant; '-' means a submodule was not
    # initialized, '+' means it does not match the pinned superproject tree.
    status = _git(source, 'submodule', 'status', '--recursive')
    seen_private_unreal = False
    for entry in status.splitlines():
        if not entry or len(entry[1:].split()) < 2:
            raise ValueError(f'Invalid UE4SS submodule status: {entry!r}')
        indicator = entry[0]
        submodule_path = entry[1:].split()[1]
        if submodule_path == PRIVATE_UNREAL_PATH:
            seen_private_unreal = True
        if indicator != ' ':
            raise ValueError(f'UE4SS submodule is missing or changed: {submodule_path}. '
                             'Initialize matching recursive submodules with Epic-linked access.')
    if not seen_private_unreal:
        raise ValueError(f'UE4SS private submodule {PRIVATE_UNREAL_PATH} is not configured')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', help='Path to the full RE-UE4SS Git checkout')
    args = parser.parse_args(argv)
    try:
        verify_checkout(args.source)
    except ValueError as error:
        print(f'Native UE4SS preflight failed: {error}', file=sys.stderr)
        return 1
    print(f'UE4SS checkout verified at {MOTORTOWN_UE4SS_COMMIT}; all submodules initialized')
    return 0


if __name__ == '__main__':
    sys.exit(main())
