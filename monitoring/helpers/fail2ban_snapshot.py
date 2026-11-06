#!/usr/bin/python3
"""Publish a fixed, read-only Fail2ban status snapshot without exposing its socket."""
import ipaddress
import json
import os
import pathlib
import re
import subprocess
import tempfile
import time

DESTINATION = pathlib.Path('/var/lib/familytraffic-fail2ban/status.json')
JAILS = ('sshd', 'familytraffic-proxy-auth')
AUTH_LOG = pathlib.Path('/opt/familytraffic/logs/xray/auth.log')

def collect(run=subprocess.run):
    result = {'timestamp': time.time(), 'jails': {}}
    for jail in JAILS:
        response = run(['/usr/bin/fail2ban-client', 'status', jail], capture_output=True, text=True, timeout=5, check=False)
        if response.returncode:
            raise RuntimeError('Fail2ban status failed')
        count = re.search(r'Currently banned:\s*(\d+)', response.stdout)
        values = re.search(r'Banned IP list:\s*([^\n]*)', response.stdout)
        if count is None or values is None:
            raise RuntimeError('Invalid Fail2ban status')
        ips = [str(ipaddress.ip_address(value)) for value in values[1].split()]
        result['jails'][jail] = {'count': int(count[1]), 'ips': ips[:1000], 'overflow': max(0, len(ips) - 1000)}
    return result

def read_auth(previous, path=AUTH_LOG, start_at_end=True):
    counts = dict(previous.get('auth', {'http': 0, 'socks': 0}))
    cursor = dict(previous.get('_auth_cursor', {'id': '', 'offset': 0}))
    gap = previous.get('auth_gaps', 0)
    def consume(candidate, offset):
        nonlocal counts
        with candidate.open('rb') as stream:
            stream.seek(offset)
            while True:
                start = stream.tell()
                line = stream.readline(16385)
                if not line:
                    return stream.tell()
                if not line.endswith(b'\n'):
                    if len(line) >= 16385:
                        raise RuntimeError('Oversized auth record')
                    return start
                match = re.search(rb'\bFT_AUTH_FAILURE protocol=(http|socks)\b', line)
                if match:
                    key = match[1].decode('ascii')
                    counts[key] = counts.get(key, 0) + 1
    try:
        marker_path = path.parent / 'traffic-rotation-generation'
        marker = marker_path.read_text().strip() if marker_path.exists() else ''
        if previous.get('_auth_cursor', {}).get('id') and marker != previous.get('_auth_rotation', ''):
            gap += 1
        stat = path.stat()
        identity = f'{stat.st_dev}:{stat.st_ino}'
        if not cursor['id'] and start_at_end:
            cursor = {'id': identity, 'offset': stat.st_size}
        if cursor['id'] and cursor['id'] != identity:
            old = next((p for p in path.parent.iterdir() if p.is_file() and f'{p.stat().st_dev}:{p.stat().st_ino}' == cursor['id']), None)
            if old is None:
                gap += 1
            else:
                consume(old, cursor['offset'])
            cursor = {'id': identity, 'offset': 0}
        if stat.st_size < cursor['offset']:
            gap += 1
            cursor['offset'] = 0
        cursor = {'id': identity, 'offset': consume(path, cursor['offset'])}
        return {'auth': counts, '_auth_cursor': cursor, 'auth_gaps': gap, 'auth_up': True, '_auth_rotation': marker}
    except (OSError, RuntimeError):
        return {'auth': previous.get('auth', {'http': 0, 'socks': 0}), '_auth_cursor': previous.get('_auth_cursor', {'id': '', 'offset': 0}), 'auth_gaps': previous.get('auth_gaps', 0), 'auth_up': False, '_auth_rotation': previous.get('_auth_rotation', '')}

def publish(destination=DESTINATION, run=subprocess.run):
    data = collect(run)
    destination = pathlib.Path(destination)
    try:
        previous = json.loads(destination.read_text())
    except FileNotFoundError:
        previous = {}
    except (ValueError, OSError) as error:
        raise RuntimeError('Invalid prior snapshot; refusing counter reset') from error
    data.update(read_auth(previous))
    destination.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=destination.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o640)
            json.dump(data, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, destination)
        directory = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)

if __name__ == '__main__':
    publish()
