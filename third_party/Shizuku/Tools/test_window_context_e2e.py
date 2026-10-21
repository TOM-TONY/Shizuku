#!/usr/bin/env python3
"""Run synthetic window capture, real anonymous XPC, native generation and storage checks.

Never registers an IME, contacts the installed service, or requests OS permissions.
Permission and lock transitions are injected into a dedicated process's OS adapter.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import struct
import subprocess
import tempfile


def scan(root):
    reference = re.compile(r'画面限定参照|琥珀の灯台')
    values = [(index + 37) / 128 for index in range(32)]
    vector = struct.pack('<32f', *values)
    vector_json = json.dumps(values, separators=(',', ':'))
    files = []
    sqlite_rows = 0
    positive = False
    for path in sorted(root.rglob('*')):
        assert not path.is_symlink(), 'Unexpected link in isolated storage'
        if not path.is_file():
            continue
        data = path.read_bytes()
        assert vector not in data, 'Reference vector persisted'
        for encoding in ['utf-8', 'utf-16-le', 'utf-16-be']:
            text = data.decode(encoding, errors='ignore')
            assert not reference.search(text), 'Reference marker persisted'
            assert vector_json not in re.sub(r'\s+', '', text), 'Reference vector serialized'
            positive |= '本人が確定する検査用の文章です。' in text
        assert path.suffix.lower() not in ['.png', '.jpg', '.jpeg', '.pdf', '.heic', '.tiff'], 'Image persisted'
        if data.startswith(b'SQLite format 3\0'):
            connection = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)
            try:
                tables = [row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")]
                for table in tables:
                    quoted = '"' + table.replace('"', '""') + '"'
                    for row in connection.execute('SELECT * FROM ' + quoted):
                        sqlite_rows += 1
                        for value in row:
                            assert not reference.search(str(value)), 'Reference in SQLite cell'
                            if isinstance(value, bytes):
                                assert vector not in value, 'Reference vector in SQLite cell'
            finally:
                connection.close()
        files.append({'path': str(path.relative_to(root)), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
    assert positive, 'Missing learning positive control'
    return {'files': files, 'sqliteRowsInspected': sqlite_rows, 'referenceMarkersFound': 0,
            'referenceVectorCanariesFound': 0, 'learningPositiveControl': positive}


def verify_scanner(parent):
    values = [(index + 37) / 128 for index in range(32)]
    controls = ['画面限定参照の一部'.encode(), '琥珀の灯台'.encode('utf-16-le'),
                struct.pack('<32f', *values), json.dumps(values).encode()]
    for control in controls:
        with tempfile.TemporaryDirectory(prefix='audit-control-', dir=parent) as directory:
            root = Path(directory)
            (root / 'positive.txt').write_text('本人が確定する検査用の文章です。')
            (root / 'leak.bin').write_bytes(control)
            try:
                scan(root)
            except AssertionError as error:
                assert 'Reference' in str(error), 'Scanner failed for an unrelated reason'
            else:
                raise AssertionError('Scanner missed a deliberate reference leak')
    return len(controls)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--resources', required=True, type=Path)
    parser.add_argument('--completion-model', required=True, type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    controls = verify_scanner(out)
    runtime = out / 'runtime'
    runtime.mkdir()
    (runtime / '.synthetic-window-test').touch()
    (runtime / 'home').mkdir()
    (runtime / 'tmp').mkdir()
    resources = out / 'resources'
    resources.mkdir()
    conversion = args.resources.resolve() / 'zenz-ane/zenz-v2.5-medium-ane.mlmodelc'
    assert conversion.is_dir() and args.completion_model.is_dir(), 'Existing local models required'
    (resources / conversion.name).symlink_to(conversion, target_is_directory=True)
    environment = dict(os.environ, LLM_IME_WINDOW_TEST_ROOT=str(runtime),
                       LLM_IME_PERSONAL_DIR=str(runtime / 'personal'),
                       LLM_IME_WINDOW_TEST_RESOURCES=str(resources),
                       LLM_IME_WINDOW_TEST_COMPLETION=str(args.completion_model.resolve()),
                       CFFIXED_USER_HOME=str(runtime / 'home'), TMPDIR=str(runtime / 'tmp') + '/',
                       XDG_CACHE_HOME=str(runtime / 'home/Library/Caches'))
    start = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    with (runtime / 'stdout.log').open('w') as stdout, (runtime / 'stderr.log').open('w') as stderr:
        process = subprocess.Popen([str(args.server.resolve()), '--window-context-e2e-self-test'],
                                   env=environment, stdout=stdout, stderr=stderr)
        try:
            code = process.wait(timeout=360)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise
    # Only this synthetic process's unified logs are queried.
    with (runtime / 'unified-log.json').open('w') as log:
        logged = subprocess.run(['/usr/bin/log', 'show', '--info', '--debug', '--style', 'json', '--start', start,
                                 '--predicate', f'processIdentifier == {process.pid}'],
                                stdout=log, stderr=subprocess.PIPE, text=True, timeout=45)
    (out / 'process.json').write_text(json.dumps({'pid': process.pid, 'exitCode': code,
                                                'unifiedLogExitCode': logged.returncode,
                                                'systemPermissionsChanged': False,
                                                'isolatedTemporaryDirectory': True}, indent=2) + '\n')
    if code:
        # Diagnostics contain stage labels and numeric metadata; no fixture body is echoed.
        print((runtime / 'stdout.log').read_text())
        raise SystemExit(code)
    assert logged.returncode == 0, 'Unified log inspection unavailable'
    audit = scan(runtime)
    audit['leakDetectionControlsPassed'] = controls
    (out / 'storage-audit.json').write_text(json.dumps(audit, indent=2) + '\n')
    print((runtime / 'stdout.log').read_text())
    print((runtime / 'result.json').read_text())
    print(json.dumps({'postExitStorageAudit': 'PASS', 'files': len(audit['files']),
                      'sqliteRowsInspected': audit['sqliteRowsInspected']}))


if __name__ == '__main__':
    main()
