#!/usr/bin/env python3
"""Exercise the real settings client, codec and queue at a test-only XPC proxy boundary.

Uses existing Release package objects. Default mode does not connect to launchd,
register an IME, read personal records, or write preferences.
The explicit --test-server-shutdown mode uses real XPC
only after verifying personal-e2e; the caller must restore its test Server.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--derived-data', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--test-server-shutdown', action='store_true', help="Test real XPC shutdown; requires personal-e2e and completion off. Restoring the Server is the caller's responsibility.")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    dd, out = (args.derived_data.resolve(), args.out.resolve())
    out.mkdir(parents=True, exist_ok=True)
    relative = 'Shizuku/InputController/ConverterServerClient.swift'
    source = (repo / relative).read_text()
    source = source.replace('@objc private protocol ConverterServerXPCProtocol', '@objc protocol ConverterServerXPCProtocol', 1)
    for name in ['remoteObjectProxy', 'longRequestProxy']:
        marker = '    private func ' + name + '(completion: @escaping (ConverterServerXPCProtocol?) -> Void) {'
        begin = source.index(marker) + len(marker)
        end = source.index('\n    private func ', begin)
        source = source[:begin] + '\n        completion(SettingsReconnectProxy())\n    }\n' + source[end:]
    marker = '    private func ensureConnection() -> NSXPCConnection {'
    source = source.replace(marker, marker + '\n        preconditionFailure("Real XPC is forbidden in this test")', 1)
    copied = out / 'ConverterServerClient.swift'
    copied.write_text(source)
    products = dd / 'Build/Products/Release'
    objects = dd / 'Build/Intermediates.noindex/Shizuku.build/Release/Shizuku.build/Objects-normal/arm64'
    package_objects = [p for p in (objects / 'Shizuku.LinkFileList').read_text().splitlines() if '/Products/Release/' in p]
    assert package_objects, 'Build Release before running this test'
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    flags = ['-target', 'arm64-apple-macos15.0', '-sdk', sdk, '-cxx-interoperability-mode=default', '-I', str(products), '-F', str(products / 'PackageFrameworks'), '-F', str(products)]
    includes = [dd / 'SourcePackages/checkouts/swift-numerics/Sources/_NumericsShims/include', dd / 'SourcePackages/checkouts/SwiftyMarisa/Sources/marisa-trie/include']
    for directory in includes:
        flags += ['-Xcc', f'-I{directory}']
    for path in [includes[0] / 'module.modulemap', dd / 'Build/Intermediates.noindex/GeneratedModuleMaps/marisa-trie.modulemap']:
        flags += ['-Xcc', f'-fmodule-map-file={path}']
    executable = out / 'settings-reconnect-tests'
    sources = [str(repo / 'Tools/ConverterShutdownTests.swift')] if args.test_server_shutdown else [str(copied), str(repo / 'Shizuku/InputController/InputTrace.swift'), str(repo / 'Tools/ConverterSettingsReconnectTests.swift')]
    command = ['xcrun', 'swiftc', '-module-name', 'SettingsReconnectTests', '-swift-version', '5', '-O', '-whole-module-optimization', '-parse-as-library', '-profile-generate'] + flags + sources + package_objects + ['-lc++', '-Xlinker', '-no_warn_duplicate_libraries', '-o', str(executable)]
    (out / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    with (out / 'build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=log, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(executable)], check=True)
    env = dict(os.environ, LLVM_PROFILE_FILE=str(out / '%p.profraw'))
    with (out / 'stdout.log').open('w') as stdout, (out / 'run.log').open('w') as stderr:
        subprocess.run([str(executable), str(out / 'result.json')], env=env, stdout=stdout, stderr=stderr, check=True, timeout=15)
    print((out / 'result.json').read_text())
if __name__ == '__main__':
    main()
