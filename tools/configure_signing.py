#!/usr/bin/env python3
"""Configure this checkout for one Apple Developer team before signing."""
import argparse
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('team_id', help='Your ten-character Apple Developer team ID')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Z0-9]{10}', args.team_id) or args.team_id == 'YOURTEAMID':
        parser.error('Provide your ten-character Apple Developer team ID')
    root = Path(__file__).resolve().parents[1]
    roots = [root / 'third_party/Shizuku', root / 'tools/manager']
    changed = []
    for base in roots:
        for path in base.rglob('*'):
            if any(p in path.relative_to(root).parts for p in ['.git', '.build', 'build', 'SourcePackages']):
                continue
            if not path.is_file() or path.suffix not in {'.swift', '.entitlements', '.plist'}:
                continue
            source = path.read_text()
            if 'YOURTEAMID' not in source:
                continue
            path.write_text(source.replace('YOURTEAMID', args.team_id))
            changed.append(str(path.relative_to(root)))
    if not changed:
        parser.error('No signing placeholders found; use an unconfigured checkout to change teams')
    print(f'Configured {len(changed)} files. Pass DEVELOPMENT_TEAM to xcodebuild and SHIZUKU_TEAM_ID to distribution scripts.')


if __name__ == '__main__':
    main()
