#!/usr/bin/env python3
"""Compile the actual lease only; use isolated paths and dedicated child processes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--scratch', required=True, type=Path)
args = parser.parse_args()
scratch = args.scratch.resolve()
if scratch.exists():
    raise SystemExit('Use a new, absent scratch directory.')
scratch.mkdir(parents=True, mode=0o700)
test = Path(__file__).resolve().parent
root = test.parents[2]
source = root / 'SystemAudioProcessor/Sources/SystemAudioProcessor/CaptureSessionLease.swift'
localization = root / 'SystemAudioProcessor/Sources/SystemAudioProcessor/AppLocalization.swift'
binary = scratch / 'LeaseChecks'
commands = []
checks = []
children = []

def save():
    (scratch / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    (scratch / 'results.json').write_text(json.dumps(checks, indent=2) + '\n')

def check(condition, label, **details):
    checks.append({'check': label, 'passed': bool(condition), **details})
    save()
    if not condition:
        raise AssertionError(label)

def run(argv, name, expected=0):
    start = time.monotonic()
    result = subprocess.run([str(x) for x in argv], text=True, capture_output=True, timeout=30)
    elapsed = time.monotonic() - start
    (scratch / (name + '.txt')).write_text(result.stdout + result.stderr)
    commands.append({'argv': [str(x) for x in argv], 'log': name + '.txt', 'exit_code': result.returncode,
                     'expected_exit': expected, 'elapsed_seconds': elapsed})
    save()
    check(result.returncode == expected, name + ' exit', elapsed_seconds=elapsed)
    return result, elapsed

def receive(child):
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    ready = selector.select(timeout=5)
    selector.close()
    if not ready:
        raise AssertionError('dedicated holder did not respond')
    line = child.stdout.readline().rstrip('\n')
    with (scratch / ('holder-' + str(child.pid) + '.txt')).open('a') as log:
        log.write(line + '\n')
    return line

def holder(directory):
    argv = [str(binary), 'holder', str(directory)]
    child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, bufsize=1)
    children.append(child)
    commands.append({'argv': argv, 'pid': child.pid, 'log': 'holder-' + str(child.pid) + '.txt'})
    save()
    check(receive(child).startswith('HELD pid='), 'holder acquired', pid=child.pid)
    return child

def send(child, text, marker):
    child.stdin.write(text + '\n'); child.stdin.flush()
    check(receive(child) == marker, 'holder ' + text, pid=child.pid)

def finish(child, expected):
    code = child.wait(timeout=5)
    check(code == expected, 'holder terminal exit', pid=child.pid, exit_code=code)
    for command in commands:
        if command.get('pid') == child.pid:
            command['exit_code'] = code
    save()

try:
    run(['swiftc', '-swift-version', '6', '-g', '-O', source, localization, test / 'main.swift', '-o', binary], 'build')
    (scratch / 'source-hashes.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in [source, localization, test / 'main.swift', Path(__file__).resolve()]}, indent=2) + '\n')
    (scratch / 'binary.sha256').write_text(hashlib.sha256(binary.read_bytes()).hexdigest() + '\n')
    directory = scratch / 'shared'
    run([binary, 'same-pid', directory], 'same-pid')
    path = directory / 'capture.lock'
    inode = path.stat().st_ino
    check(stat.S_IMODE(directory.stat().st_mode) == 0o700, 'directory mode0700')
    check(stat.S_IMODE(path.stat().st_mode) == 0o600 and stat.S_ISREG(path.stat().st_mode), 'regular file mode0600')
    process = holder(directory)
    _, elapsed = run([binary, 'probe', directory], 'contention', 23)
    check(elapsed < 2, 'contention nonblocking', elapsed_seconds=elapsed)
    send(process, 'release', 'RELEASED')
    run([binary, 'probe', directory], 'normal-release')
    check(process.poll() is None, 'reacquired while original process alive')
    send(process, 'quit', 'EXITING'); finish(process, 0)
    process = holder(directory)
    send(process, 'deinit', 'DEINITIALIZED')
    run([binary, 'probe', directory], 'default-deinit-release')
    send(process, 'quit', 'EXITING'); finish(process, 0)
    process = holder(directory)
    send(process, 'crash', 'CRASHING'); finish(process, -signal.SIGKILL)
    run([binary, 'probe', directory], 'crash-release')
    result, _ = run([binary, 'exec', directory], 'cloexec')
    pids = [line.split('pid=')[1] for line in result.stdout.splitlines() if 'pid=' in line]
    check(len(pids) == 2 and pids[0] == pids[1], 'same PID reacquires after exec without deinit', pids=pids)
    process = holder(directory)
    send(process, 'abandon', 'ABANDONED')
    run([binary, 'probe', directory], 'abandon-survives-release-and-deinit', 23)
    send(process, 'quit', 'EXITING'); finish(process, 0)
    run([binary, 'probe', directory], 'abandon-process-exit-release')
    check(path.stat().st_ino == inode, 'persistent inode never unlinked', inode=inode)
    # Permission/type failures must fail closed and must not modify the target.
    unsafe_directory = scratch / 'wide-directory'; unsafe_directory.mkdir(mode=0o755)
    unsafe_directory.chmod(0o755)
    run([binary, 'probe', unsafe_directory], 'reject-wide-directory', 24)
    link_directory = scratch / 'directory-link'; link_directory.symlink_to(directory, target_is_directory=True)
    run([binary, 'probe', link_directory], 'reject-directory-symlink', 24)
    for case in ['wide-file', 'symlink', 'fifo', 'hardlink']:
        case_directory = scratch / case; case_directory.mkdir(mode=0o700)
        lock = case_directory / 'capture.lock'
        if case == 'wide-file':
            lock.touch(mode=0o644); lock.chmod(0o644)
        elif case == 'symlink':
            lock.symlink_to(path)
        elif case == 'fifo':
            os.mkfifo(lock, 0o600)
        else:
            sacrificial = case_directory / 'other'; sacrificial.touch(mode=0o600); os.link(sacrificial, lock)
        run([binary, 'probe', case_directory], 'reject-' + case, 24)
    check(path.stat().st_ino == inode and path.read_bytes() == b'', 'rejection preserved original lock inode and contents')
    print('CaptureSessionLeaseChecks: ' + str(len(checks)) + ' checks passed; actual isolated processes/flock, no audio APIs or GUI')
finally:
    # Only processes created by this harness are eligible for cleanup. The
    # running LowEnd app/debug processes are never inspected or controlled.
    for child in children:
        if child.poll() is None:
            child.kill(); child.wait(timeout=5)
    save()
