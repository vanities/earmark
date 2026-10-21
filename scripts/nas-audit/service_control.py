"""Own a loopback fixture SMB process and accept file-based stop/start requests from tests."""
import argparse
import json
import signal
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, default=Path('/tmp/mango-earmark-smb-fixtures'))
parser.add_argument('--read-delay', type=float, default=0.03)
args = parser.parse_args()
root = args.root.resolve()
root.mkdir(exist_ok=True)
marker = root / '.simulator-smb-audit'
if any(root.iterdir()) and not marker.exists():
    parser.error('Use an empty directory or an existing generated fixture root')
try:
    with socket.create_connection(('127.0.0.1', 1445), timeout=0.2):
        parser.error('Port 1445 already has a listener; refusing to control another service')
except OSError:
    pass
marker.write_text('Generated SMB simulator fixtures only.\n')
control = root / '.service-control'
control.mkdir(exist_ok=True)
for name in ['request.json', 'response.json', 'session.json']:
    (control / name).unlink(missing_ok=True)
nonce = str(uuid.uuid4())
child = None
generation = 0

def write_json(name, value):
    temporary = control / (name + '.new')
    temporary.write_text(json.dumps(value))
    temporary.replace(control / name)

def stop():
    global child
    if child is not None:
        if child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=5)
        child = None

def start():
    global child, generation
    if child is not None and child.poll() is None:
        return
    command = [sys.executable, str(Path(__file__).with_name('smb_fixture.py')),
               '--root', str(root), '--read-delay', str(args.read_delay)]
    if generation > 0:
        command.append('--reuse-fixtures')
    child = subprocess.Popen(command,
                             stdout=output, stderr=subprocess.STDOUT)
    for _ in range(100):
        if child.poll() is not None:
            raise RuntimeError('Owned SMB fixture process exited during startup; inspect server-output.log')
        try:
            with socket.create_connection(('127.0.0.1', 1445), timeout=0.1):
                generation += 1
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError('Owned SMB fixture process did not listen on port 1445')

def interrupted(_signal, _frame):
    raise KeyboardInterrupt

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
with (control / 'server-output.log').open('a') as output:
    try:
        start()
        write_json('session.json', {'nonce': nonce, 'generation': generation})
        print(f'Controlled SMB fixture ready: {control}', flush=True)
        last_request = None
        while True:
            try:
                request = json.loads((control / 'request.json').read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                time.sleep(0.01)
                continue
            if request.get('nonce') != nonce or request.get('id') == last_request:
                time.sleep(0.01)
                continue
            last_request = request['id']
            action = request.get('action')
            if action == 'stop':
                stop()
            elif action == 'start':
                start()
            else:
                raise RuntimeError(f'Unknown fixture control action: {action}')
            write_json('response.json', {'id': last_request, 'nonce': nonce, 'running': child is not None,
                                         'generation': generation})
    except KeyboardInterrupt:
        pass
    finally:
        stop()
        (control / 'session.json').unlink(missing_ok=True)
