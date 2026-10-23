#!/usr/bin/env python3
"""Explicit harmless window only; no permission changes, installation, or release."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--executable', required=True)
parser.add_argument('--window-id', type=int, required=True)
parser.add_argument('--expected-title', required=True)
parser.add_argument('--evidence-dir', type=Path, required=True)
args = parser.parse_args()
args.evidence_dir.mkdir(parents=True, exist_ok=False)

def call(name, arguments=None):
    message = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
               'params': {'name': name, 'arguments': arguments or {}}}
    process = subprocess.run([args.executable, '--mcp'], input=json.dumps(message) + '\n',
                             text=True, capture_output=True, timeout=60, check=True)
    response = json.loads(process.stdout)['result']
    text = response['content'][0]['text']
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        value = text
    return {'isError': response.get('isError', False), 'value': value}

def success(name, arguments=None):
    response = call(name, arguments)
    assert not response['isError'], response
    return response['value']

def save(name, value):
    (args.evidence_dir / name).write_text(json.dumps(value, ensure_ascii=False, indent=2))

targets = success('list_recording_targets')
assert any(w['id'] == args.window_id and w['title'] == args.expected_title
           for w in targets['windows']), 'Target changed; refusing to record a different window'
before = success('get_project_state')
checks = {}
for label, arguments in [
    ('unknown_window', {'target': 'window', 'window_id': 4294967295}),
    ('negative_window', {'target': 'window', 'window_id': -1}),
    ('boolean_id', {'target': 'window', 'window_id': True}),
    ('invalid_fps', {'target': 'window', 'window_id': args.window_id, 'fps': 29}),
    ('invalid_boolean', {'target': 'window', 'window_id': args.window_id, 'camera': 1}),
    ('missing_display', {'target': 'area'}),
    ('outside_area', {'target': 'area', 'display_id': targets['displays'][0]['id'],
                      'x': -1, 'y': 0, 'width': 100, 'height': 100}),
]:
    checks[label] = call('start_recording', arguments)['isError']
    assert checks[label], label
started = success('start_recording', {'target': 'window', 'window_id': args.window_id})
sid = started['session_id']
save('started.json', started)
try:
    checks['duplicate_start'] = call('start_recording', {'target': 'window', 'window_id': args.window_id})['isError']
    checks['wrong_stop'] = call('stop_recording', {'session_id': 'wrong-session'})['isError']
    checks['missing_stop_id'] = call('stop_recording')['isError']
    checks['unknown_status'] = call('get_recording_status', {'session_id': 'wrong-session'})['isError']
    time.sleep(10)
    during = success('get_recording_status', {'session_id': sid})
    assert during['state'] == 'recording' and during['elapsed_seconds'] >= 9
    save('during.json', during)
    time.sleep(max(0, 24 - during['elapsed_seconds']))
finally:
    stopped = call('stop_recording', {'session_id': sid})
    save('stopped.json', stopped)
assert not stopped['isError'] and stopped['value']['state'] == 'completed', stopped
checks['idempotent_stop'] = call('stop_recording', {'session_id': sid}) == stopped
checks['project_preserved'] = before == success('get_project_state')
assert all(checks.values()), checks
screen = next(f for f in stopped['value']['result']['files'] if f['kind'] == 'screen')
probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', screen['path']]))
assert not any(s['codec_type'] == 'audio' for s in probe['streams']), 'Silent defaults failed'
assert 20 <= float(probe['format']['duration']) <= 30
checksum = args.evidence_dir / 'frames.md5'
subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', screen['path'], '-map', '0:v:0',
                '-fps_mode', 'passthrough', '-enc_time_base', 'demux', '-f', 'framemd5', str(checksum)], check=True)
frames = [line for line in checksum.read_text().splitlines() if not line.startswith('#')]
unique = len({line.split(',')[-1].strip() for line in frames})
assert unique > 30, 'No sufficient motion; use an animated harmless window'
save('checks.json', checks)
save('media.json', {'probe': probe, 'decoded_frames': len(frames), 'unique_frames': unique})
print(json.dumps({'checks': checks, 'screen': screen, 'decoded_frames': len(frames), 'unique_frames': unique}, ensure_ascii=False))
