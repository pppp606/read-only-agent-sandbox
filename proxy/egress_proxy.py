#!/usr/bin/env python3
"""Minimal allowlisted CONNECT proxy for local experiments; NOT production hardened."""
import os
import select
import socket
import socketserver
import ipaddress
from urllib.parse import urlsplit

ALLOWED = set(os.environ.get("ALLOWED_HOSTS", "api.anthropic.com").split(","))
PORT = int(os.environ.get("PORT", "3128"))

class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(10)
        try:
            line = self.rfile.readline(8192).decode("ascii", "replace").strip()
            parts = line.split()
            if len(parts) != 3 or parts[0] != "CONNECT":
                return self.reply(405)
            target = parts[1]
            parsed = urlsplit("//" + target)
            host, port = parsed.hostname, parsed.port
            if not host or port != 443 or host not in ALLOWED:
                return self.reply(403)
            while True:
                header = self.rfile.readline(8192)
                if not header or header in (b"\r\n", b"\n"):
                    break
            addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
            # Avoid connecting to loopback/private/metadata destinations after DNS resolution.
            for family, typ, proto, _, addr in addresses:
                ip = ipaddress.ip_address(addr[0])
                if not ip.is_global:
                    continue
                upstream = socket.socket(family, typ, proto)
                upstream.settimeout(10)
                try:
                    upstream.connect(addr)
                    self.connection.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                    self.connection.settimeout(None)
                    upstream.settimeout(None)
                    self.tunnel(upstream)
                    return
                finally:
                    upstream.close()
            self.reply(502)
        except (OSError, ValueError, UnicodeError):
            try:
                self.reply(502)
            except OSError:
                pass

    def reply(self, status):
        reason = {403:"Forbidden",405:"Method Not Allowed",502:"Bad Gateway"}[status]
        self.connection.sendall(f"HTTP/1.1 {status} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())

    def tunnel(self, upstream):
        peers = [self.connection, upstream]
        while True:
            ready, _, _ = select.select(peers, [], [], 60)
            if not ready:
                return
            for src in ready:
                data = src.recv(65536)
                if not data:
                    return
                (upstream if src is self.connection else self.connection).sendall(data)

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

if __name__ == "__main__":
    with Server(("0.0.0.0", PORT), Handler) as server:
        print(f"CONNECT proxy listening on {PORT}; allowed hosts: {sorted(ALLOWED)}", flush=True)
        server.serve_forever()
