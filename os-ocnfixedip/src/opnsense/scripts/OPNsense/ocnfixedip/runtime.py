#!/usr/local/bin/python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (C) 2026 OCN Fixed IP (IPoE) Plugin Contributors
"""Serialization, locking and bounded prefix updates for the shell entry points."""
import contextlib
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


def atomic_write(path, content):
    path = Path(path)
    fd, name = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextlib.contextmanager
def locked(path, timeout=30):
    # Never unlink lock files: waiting processes must lock the same inode.
    with open(path, 'a') as stream:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError('Another operation is still running')
                time.sleep(0.1)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def format_json(template, values):
    # Existing shell payloads consist only of quoted string placeholders.
    parts = template.split('"%s"')
    if len(parts) != len(values) + 1:
        raise ValueError('Invalid JSON template')
    output = parts[0]
    for value, part in zip(values, parts[1:]):
        output += json.dumps(value, ensure_ascii=True) + part
    return json.dumps(json.loads(output), separators=(',', ':'))


def select_ipv6(lines, excluded=()):
    candidates = []
    for line in lines.splitlines():
        fields = line.split()
        if len(fields) < 2 or fields[0] != 'inet6':
            continue
        if any(flag in fields for flag in ('tentative', 'duplicated', 'deprecated', 'temporary', 'detached')):
            continue
        try:
            address = ipaddress.IPv6Address(fields[1].split('%')[0])
        except ValueError:
            continue
        if str(address) not in excluded and address.is_global and address in ipaddress.IPv6Network('2000::/3'):
            candidates.append(address)
    prefixes = {ipaddress.IPv6Network(str(addr) + '/56', strict=False) for addr in candidates}
    if len(prefixes) != 1:
        raise ValueError('WAN requires one unambiguous stable global /56 prefix')
    return str(candidates[0])


def update_url(url, hostname):
    parsed = urlsplit(url)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ValueError('Update URL must be HTTP(S) without embedded credentials or fragment')
    # Hostname is an OCN token, not a general-purpose URL or HTML fragment.
    if hostname and not re.fullmatch(r'[A-Za-z0-9._-]+', hostname):
        raise ValueError('Invalid prefix update hostname')
    query = parse_qsl(parsed.query, keep_blank_values=True)
    tokens = [value for key, value in query if key == 'hostname']
    if len(tokens) > 1 or any(not re.fullmatch(r'[A-Za-z0-9._-]+', token) for token in tokens):
        raise ValueError('Invalid hostname in update URL')
    if hostname and not tokens:
        query.append(('hostname', hostname))
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode(query), ''))


def quote_netrc(value):
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError('Control characters are not allowed in credentials')
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def prefix_update(values, state):
    user, password, hostname, url = values
    code, rc = 'curl-error', 1
    try:
        with locked(str(state) + '.lock'):
            try:
                url = update_url(url, hostname)
                if not user:
                    raise ValueError('Authentication user is required')
                login, secret = quote_netrc(user), quote_netrc(password)
                # mkstemp creates mode 0600; finally also runs on handled signals.
                with tempfile.TemporaryDirectory(prefix='ocnfixedip-auth-') as directory:
                    netrc = Path(directory) / 'netrc'
                    fd = os.open(netrc, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    with os.fdopen(fd, 'w') as stream:
                        stream.write('default\nlogin ' + login + '\npassword ' + secret + '\n')
                    result = subprocess.run(
                        ['curl', '--disable', '-6', '-sS', '--fail', '--proto', '=http,https',
                         '--connect-timeout', '2', '--max-time', '10', '--max-filesize', '4096',
                         '--netrc-file', str(netrc), url],
                        capture_output=True, text=True, timeout=12,
                    )
                    rc = result.returncode
                    tokens = result.stdout.split()
                    token = tokens[0] if tokens else 'empty-response'
                    code = token if token in ('good', 'nochg', 'nohost', 'badauth', 'notfqdn', 'abuse', '911') else 'invalid-response'
                    if rc:
                        code = 'curl-error'
            except (OSError, ValueError, subprocess.TimeoutExpired):
                # Never log credentials, URLs, curl stderr or untrusted response bodies.
                code, rc = 'update-error', 1
            atomic_write(state, f'{int(time.time())} {rc} {code}\n')
    except TimeoutError:
        code, rc = 'update-busy', 1
    return {'status': 'ok' if rc == 0 and code in ('good', 'nochg') else 'ng', 'result': code}


def main(args):
    mode = args[0]
    if mode == 'json':
        print(format_json(args[1], args[2:]))
    elif mode == 'select-ipv6':
        print(select_ipv6(sys.stdin.read(), args[1:]))
    elif mode in ('validate-update', 'update'):
        values = sys.stdin.read().split('\0')
        if len(values) != 4:
            raise ValueError('Invalid update input')
        if mode == 'validate-update':
            update_url(values[3], values[2])
            quote_netrc(values[0]); quote_netrc(values[1])
            if not values[0]:
                raise ValueError('Authentication user is required')
        else:
            print(json.dumps(prefix_update(values, args[1])))
    elif mode == 'lock':
        with locked(args[1]):
            return subprocess.call(args[2:])
    elif mode == 'cached-status':
        cache = Path(args[1])
        with locked(str(cache) + '.lock'):
            if cache.exists() and 0 <= time.time() - cache.stat().st_mtime < 5:
                print(cache.read_text(), end='')
                return 0
            output = subprocess.check_output(args[2:], text=True, timeout=45)
            json.loads(output)
            atomic_write(cache, output)
            print(output, end='')
    return 0


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        sys.exit(main(sys.argv[1:]))
    except (ValueError, OSError, TimeoutError, subprocess.SubprocessError):
        stream = sys.stderr if len(sys.argv) > 1 and sys.argv[1] in ('select-ipv6', 'validate-update') else sys.stdout
        print(json.dumps({'result': 'failed', 'message': 'Backend operation failed; check the system log'}), file=stream)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
