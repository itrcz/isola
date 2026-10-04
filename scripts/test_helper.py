#!/usr/bin/env python3
"""Exercise the built helper's real UNIX datagram interface and parent-lifetime pipe."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import sys

if len(sys.argv) != 2:
    raise SystemExit('Usage: python3 scripts/test_helper.py /path/to/isola-network')
helper = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='isola-test-', dir='/tmp') as directory:
    gw = directory + '/gw.sock'
    peer = directory + '/vm.sock'
    stats = directory + '/stats.json'
    process = subprocess.Popen([str(helper), '--socket', gw, '--peer', peer, '--stats', stats], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        process.stdin.write(json.dumps({'Host': '127.0.0.1', 'Port': 1, 'Username': 'test', 'Password': 'test'}).encode() + b'\n')
        process.stdin.flush()
        deadline = time.monotonic() + 5
        while not os.path.exists(gw):
            assert process.poll() is None, 'helper exited during startup'
            assert time.monotonic() < deadline, 'helper startup timeout'
            time.sleep(.02)
        assert os.stat(gw).st_mode & 0o777 == 0o600
        client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        client.settimeout(2)
        client.bind(peer)
        client.connect(gw)
        mac = bytes.fromhex('024953000002')
        arp = struct.pack('!HHBBH', 1, 0x800, 6, 4, 1) + mac + bytes([10,77,0,2]) + bytes(6) + bytes([10,77,0,1])
        client.send(bytes.fromhex('ffffffffffff') + mac + bytes.fromhex('0806') + arp)
        response = client.recv(1600)
        assert response[12:14] == bytes.fromhex('0806')
        assert response[20:22] == bytes.fromhex('0002'), 'no ARP reply through UNIX socket'
        assert response[28:32] == bytes([10,77,0,1])
        # A guest may transmit while it stops reading (full RX ring). Ensure
        # reverse-direction congestion never wedges the gateway's receive loop.
        frame = bytes.fromhex('ffffffffffff') + mac + bytes.fromhex('0806') + arp
        for _ in range(4000):
            client.send(frame)
        deadline = time.monotonic() + 5
        while True:
            try:
                counters = json.loads(Path(stats).read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                counters = {}
            if counters.get('frames', 0) >= 4001:
                break
            assert time.monotonic() < deadline, 'receive loop wedged by blocked guest RX'
            time.sleep(.05)
        assert counters['send_queue_dropped'] > 0, 'stress did not fill output queue'
        client.settimeout(.5)
        drain_deadline = time.monotonic() + 5
        while time.monotonic() < drain_deadline:
            try:
                client.recv(1600)
            except socket.timeout:
                break
        client.settimeout(2)
        client.send(frame)
        assert client.recv(1600)[20:22] == bytes.fromhex('0002'), 'gateway did not recover after congestion'
        process.stdin.close()
        assert process.wait(timeout=3) == 0, 'helper survived loss of parent pipe'
        client.close()
        print('PASS: UNIX Ethernet round trip, socket permissions, blocked guest RX stress (4000 frames), exit on parent EOF')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
