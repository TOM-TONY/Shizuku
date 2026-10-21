#!/usr/bin/env python3
"""Standalone AppKit/IMK client regression, using an existing Release build.

Copies app sources into --out, replaces only IMK's private client-proxy boundary and
ConverterServer transport, and links the existing Release package objects. The real
Apple IMK base initializer runs with a nil private proxy; client() returns the mock.
No IMKServer is created, no IME is registered, and real XPC is disabled. Preferences
are overridden in memory by the Swift harness. No test host or installed app runs.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--source-packages', type=Path, help='Existing cloned SourcePackages directory when separate from derived data')
    parser.add_argument('--menu-validation-only', action='store_true', help='Run menu purity tests without activating a controller, displaying windows, or processing keys')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    dd, out = (args.derived_data.resolve(), args.out.resolve())
    src = out / 'sources'
    src.mkdir(parents=True, exist_ok=True)
    objects = dd / 'Build/Intermediates.noindex/Shizuku.build/Release/Shizuku.build/Objects-normal/arm64'
    products = dd / 'Build/Products/Release'
    paths = []
    source_paths = (objects / 'Shizuku.SwiftFileList').read_text().splitlines()
    trace_source = repo / 'Shizuku/InputController/InputTrace.swift'
    if str(trace_source) not in source_paths:
        source_paths.append(str(trace_source))
    for line in source_paths:
        path = Path(line)
        text = path.read_text()
        if path.name == 'AppDelegate.swift':
            assert '@main\n' in text
            text = text.replace('@main\n', '', 1)
        if path.name == 'ShizukuInputController.swift':
            assert 'super.init(server: server, delegate: delegate, client: inputClient)' in text
            text = text.replace('    let converterServerClient = ConverterServerClient()', '    static var initializationTestClient: InitializationClient?\n    override func client() -> (any IMKTextInput & NSObjectProtocol)! { Self.initializationTestClient }\n    func initializationTestExpirePlacedUndo() { self.placedAssistance?.time = .distantPast }\n    func initializationTestIdleCompletion(_ text: String, left: String) {\n        self.inputState = .none\n        self.ghostClientBundleID = "dev.tomonari.imk-initialization-test"\n        let idle = IdleCompletion(text: text, leftContext: left, caretX: 200,\n            lineRect: NSRect(x: 200, y: 200, width: 1, height: 18), fontSize: 15, lineStartX: 200, rightEdge: nil)\n        self.idleCompletion = idle\n        self.completionPopupWindow.show(text: text, lineRect: idle.lineRect)\n    }\n    let converterServerClient = ConverterServerClient()', 1)
            text = text.replace('super.init(server: server, delegate: delegate, client: inputClient)', 'super.init(server: server, delegate: delegate, client: nil)', 1)
        if path.name == 'ConverterServerClient.swift':
            assert 'synchronousRemoteObjectProxy' not in text, 'Synchronous XPC must not be introduced'
            text = text.replace('    nonisolated init() {}', '    static var initializationTestTransport: ((ConverterServerCommand, @escaping (ConverterServerResponse?) -> Void) -> Void)?\n    nonisolated init() {}', 1)
            for name in ['remoteObjectProxy', 'longRequestProxy']:
                marker = '    private func ' + name + '(completion: @escaping (ConverterServerXPCProtocol?) -> Void) {'
                begin = text.index(marker) + len(marker)
                end = text.index('\n    private func ', begin)
                text = text[:begin] + '\n        completion(InitializationXPCProxy())\n    }\n' + text[end:]
            marker = '    private func ensureConnection() -> NSXPCConnection {'
            text = text.replace(marker, marker + '\n        preconditionFailure("Real XPC is forbidden in this test")', 1)
            text = text.replace('@objc private protocol ConverterServerXPCProtocol', '@objc protocol ConverterServerXPCProtocol', 1)
            text += '\n@MainActor final class InitializationXPCProxy: NSObject, ConverterServerXPCProtocol {\n    static var malformedResponse = false\n    func openSession(with reply: @escaping @Sendable (String) -> Void) { preconditionFailure("Unexpected proxy API") }\n    func closeSession(_ sessionID: String, with reply: @escaping @Sendable (Bool) -> Void) { preconditionFailure("Unexpected proxy API") }\n    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void) { preconditionFailure("Unexpected proxy API") }\n    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void) {\n        let command = try! ConverterServerCodec.decodeCommand(from: data)\n        guard let transport = ConverterServerClient.initializationTestTransport else { preconditionFailure("Missing test transport") }\n        transport(command) { response in\n            if Self.malformedResponse { reply(Data([255]), nil); return }\n            reply(response.flatMap { try? ConverterServerCodec.encode($0) }, nil)\n        }\n    }\n}\n'
        target = src / path.name
        target.write_text(text)
        paths.append(str(target))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    flags = ['-target', 'arm64-apple-macos15.0', '-sdk', sdk, '-cxx-interoperability-mode=default', '-I', str(products), '-F', str(products / 'PackageFrameworks'), '-F', str(products)]
    packages = args.source_packages.resolve() if args.source_packages else dd / 'SourcePackages'
    includes = [packages / 'checkouts/swift-numerics/Sources/_NumericsShims/include', packages / 'checkouts/SwiftyMarisa/Sources/marisa-trie/include']
    maps = [includes[0] / 'module.modulemap', dd / 'Build/Intermediates.noindex/GeneratedModuleMaps/marisa-trie.modulemap']
    cc = []
    for directory in includes:
        cc += ['-Xcc', f'-I{directory}']
    for path in maps:
        cc += ['-Xcc', f'-fmodule-map-file={path}']
    package_objects = [p for p in (objects / 'Shizuku.LinkFileList').read_text().splitlines() if '/Products/Release/' in p]
    assert package_objects, 'Build Release first; no package objects found'
    compile_args = ['xcrun', 'swiftc', '-module-name', 'Shizuku', '-swift-version', '5', '-O', '-whole-module-optimization'] + flags + cc
    if args.menu_validation_only:
        compile_args += ['-D', 'MENU_VALIDATION_ONLY']
    test_sources = [str(repo / 'Tools/ClientInitializationTests.swift')]
    if args.menu_validation_only:
        test_sources.append(str(repo / 'Tools/ClientMenuValidationTests.swift'))
    compile_args += paths + test_sources + ['-parse-as-library', '-emit-object', '-o', str(out / 'harness.o')]
    executable = out / 'client-initialization-tests'
    link_args = ['xcrun', 'swiftc'] + flags + cc + ['-profile-generate', '-Xlinker', '-no_warn_duplicate_libraries', str(out / 'harness.o')] + package_objects + ['-lc++', '-o', str(executable)]
    (out / 'commands.json').write_text(json.dumps([compile_args, link_args], indent=2) + '\n')
    with (out / 'build.log').open('w') as log:
        subprocess.run(compile_args, stdout=log, stderr=log, check=True)
        subprocess.run(link_args, stdout=log, stderr=log, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(executable)], check=True)
    env = dict(os.environ, LLVM_PROFILE_FILE=str(out / '%p.profraw'))
    with (out / 'stdout.log').open('w') as stdout, (out / 'run.log').open('w') as stderr:
        subprocess.run([str(executable), str(out / 'result.json')], env=env, stdout=stdout, stderr=stderr, check=True, timeout=60)
    result = json.loads((out / 'result.json').read_text())
    if not args.menu_validation_only:
        from check_input_trace import inspect_rows
        predicate = f"""subsystem == "dev.tomonari.inputmethod.Shizuku" AND category == "input" AND processIdentifier == {result['processID']}"""
        for attempt in range(3):
            with (out / 'log-show.stderr').open('w') as errors:
                captured = subprocess.run(['/usr/bin/log', 'show', '--last', '5m', '--predicate', predicate, '--style', 'json'], stdout=subprocess.PIPE, stderr=errors, check=True, text=True)
            try:
                checks = inspect_rows(json.loads(captured.stdout))
                break
            except AssertionError:
                if attempt == 2:
                    raise
                time.sleep(0.5)
        (out / 'log-assertions.json').write_text(json.dumps(checks, indent=2) + '\n')
        result['logAssertionsPassed'] = True
    print(json.dumps({'revision': 'working-tree', **result}, sort_keys=True))
if __name__ == '__main__':
    main()
