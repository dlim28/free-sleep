"""TCP/UDP echo servers and clients used by the firewall network-namespace tests.

Usage:
  network_probe.py serve-tcp|serve-udp ADDRESS PORT
  network_probe.py tcp|udp ADDRESS PORT          (exit 0 when the echo round-trip works)
  network_probe.py hold-tcp ADDRESS PORT READY_FILE RESULT_FILE GO_FILE...
      Open a connection and exchange once, then create READY_FILE. For each GO_FILE, wait
      until it exists, exchange again, and append 'exchanged' or 'blocked' to RESULT_FILE.
"""

from pathlib import Path
import socket
import sys
import threading
import time


TIMEOUT_SECONDS = 1.5


def echo_connection(connection):
    with connection:
        while True:
            data = connection.recv(1024)
            if not data:
                return
            connection.sendall(data)


def serve_tcp(address, port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((address, port))
    server.listen()
    while True:
        connection, _ = server.accept()
        threading.Thread(target=echo_connection, args=(connection,), daemon=True).start()


def serve_udp(address, port):
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind((address, port))
    while True:
        data, peer = server.recvfrom(1024)
        server.sendto(data, peer)


def exchange_tcp(address, port):
    try:
        with socket.create_connection((address, port), timeout=TIMEOUT_SECONDS) as connection:
            connection.sendall(b'ping')
            return connection.recv(4) == b'ping'
    except OSError:
        return False


def exchange_udp(address, port):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(TIMEOUT_SECONDS)
        try:
            client.sendto(b'ping', (address, port))
            data, _ = client.recvfrom(4)
            return data == b'ping'
        except OSError:
            return False


def hold_tcp(address, port, ready_file, result_file, *go_files):
    connection = socket.create_connection((address, port), timeout=TIMEOUT_SECONDS)
    connection.sendall(b'ping')
    if connection.recv(4) != b'ping':
        raise RuntimeError('initial exchange failed')
    Path(ready_file).touch()
    for go_file in go_files:
        while not Path(go_file).exists():
            time.sleep(0.05)
        try:
            connection.sendall(b'pong')
            result = 'exchanged' if connection.recv(4) == b'pong' else 'blocked'
        except OSError:
            result = 'blocked'
        with open(result_file, 'a') as results:
            results.write(result + '\n')


def main():
    operation, address, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
    if operation == 'serve-tcp':
        serve_tcp(address, port)
    elif operation == 'serve-udp':
        serve_udp(address, port)
    elif operation == 'tcp':
        sys.exit(0 if exchange_tcp(address, port) else 1)
    elif operation == 'udp':
        sys.exit(0 if exchange_udp(address, port) else 1)
    elif operation == 'hold-tcp':
        hold_tcp(address, port, *sys.argv[4:])
    else:
        sys.exit(f'unknown operation {operation}')


if __name__ == '__main__':
    main()
