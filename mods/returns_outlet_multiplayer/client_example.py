#!/usr/bin/env python3
"""Small smoke-test client for Returns Outlet Multiplayer."""
from __future__ import annotations

import argparse
import socket
import sys

from protocol import decode_message, encode_message


def send(sock: socket.socket, kind: str, **payload) -> None:
    sock.sendall(encode_message(kind, **payload))


def recv(sock: socket.socket):
    return decode_message(sock.makefile("rb").readline())


def main() -> None:
    parser = argparse.ArgumentParser(description="Connect one buyer to a multiplayer mod server.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--name", default="Demo Buyer")
    args = parser.parse_args()

    with socket.create_connection((args.host, args.port), timeout=5) as sock:
        send(sock, "join", name=args.name)
        print(recv(sock))
        send(sock, "ready", ready=True)
        send(sock, "move", x=4.0, y=2.0, rotation=90.0)
        send(sock, "claim_pallet", pallet_id="PALLET-001")
        send(sock, "chat", text="Found a promising electronics pallet!")
    return None


if __name__ == "__main__":
    sys.exit(main())
