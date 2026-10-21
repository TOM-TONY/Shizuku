#!/usr/bin/env python3
"""Assert the metadata-only native fixture's saved unified log (never read personal stores)."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re


def inspect_rows(rows):
    messages = [row.get('eventMessage', '') for row in rows]
    assert messages, 'No input trace records were persisted'
    assert not any(word in message for word in ['TRACE_PRIVATE_SENTINEL', 'きょう', '今日', 'Ruri v3 30M', '貼り付け😀'] for message in messages), 'Fixture text leaked into logs'
    functional = [message for message in messages if ' c=18446744073709551615 ' not in message]
    assert len(messages) - len(functional) == 14 * 1020, 'Benchmark log records were dropped'
    stages, reasons = Counter(), Counter()
    parsed = []
    for message in functional:
        values = dict(re.findall(r'(stage|c|r|key|modifiers|state|length|effects|reason|n)=([^ ]+)', message))
        assert set(values) == {'stage', 'c', 'r', 'key', 'modifiers', 'state', 'length', 'effects', 'reason', 'n'}
        for key in ['c', 'r', 'key', 'modifiers', 'length', 'effects', 'n']:
            int(values[key])
        assert re.fullmatch(r'[A-Za-z_]+', values['stage'] + values['state'] + values['reason'])
        stages[values['stage']] += 1
        reasons[values['reason']] += 1
        parsed.append(values)
    for stage in ['init_begin', 'init', 'activate', 'activate_return', 'deactivate', 'deactivate_return', 'handle', 'handle_return', 'queued', 'send', 'response', 'marked_call', 'marked_return', 'insert_call', 'insert_return', 'commitComposition', 'exception']:
        assert stages[stage], f'Missing {stage}'
    for reason in ['no_event', 'no_client', 'not_key_down', 'router_application', 'stale_activation', 'timeout', 'decode_error', 'retry', 'objc_uncaught']:
        assert reasons[reason], f'Missing guard/error reason {reason}'
    main_stages = {'queued', 'send', 'response', 'marked_call', 'marked_return', 'insert_call', 'insert_return'}
    first_key = [row['stage'] for row in parsed if row['c'] == '1' and row['r'] == '1' and row['stage'] in main_stages]
    assert first_key == ['queued', 'send', 'response', 'marked_call', 'marked_return']
    commit = [row for row in parsed if row['c'] == '1' and row['r'] == '2' and row['stage'] in main_stages]
    assert [row['stage'] for row in commit] == ['queued', 'send', 'response', 'insert_call', 'insert_return']
    assert next(row for row in commit if row['stage'] == 'response')['effects'] == '1'
    assert next(row for row in commit if row['stage'] == 'insert_call')['length'] == '2'
    return {'records': len(messages), 'functionalRecords': len(functional), 'noText': True, 'allBenchmarkLogsPersisted': True, 'stages': dict(stages),
            'reasons': dict(reasons), 'firstKeyStages': first_key, 'commitStages': [row['stage'] for row in commit]}


def inspect(path):
    return inspect_rows(json.loads(path.read_text()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.log)
    args.out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
