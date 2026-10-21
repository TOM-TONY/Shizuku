#!/usr/bin/env python3
"""Keep build outputs and local models out of this checkout's Git index."""
from pathlib import Path
import subprocess


def main():
    root = Path(__file__).resolve().parents[1]
    git_root = Path(subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--show-toplevel'], text=True).strip())
    if git_root.resolve() != root:
        raise SystemExit('Run this only from the Shizuku repository checkout')
    path = Path(subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--path-format=absolute', '--git-path', 'info/exclude'], text=True).strip())
    rules = ['**/.build/', '**/build/', '**/SourcePackages/', '**/xcuserdata/', '**/__pycache__/',
             'models/', '.venv/', '.local/', '.DS_Store', '*.log', '*.profraw', '*.profdata']
    existing = path.read_text() if path.exists() else ''
    additions = [rule for rule in rules if rule not in existing.splitlines()]
    if additions:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('a') as stream:
            stream.write(('\n' if existing and not existing.endswith('\n') else '') + '\n'.join(additions) + '\n')
    print('Local build and model exclusions are configured.')


if __name__ == '__main__':
    main()
