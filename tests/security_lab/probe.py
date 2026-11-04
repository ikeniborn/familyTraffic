"""Real socket clients and a TLS target for the disposable security lab."""
import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import socket
import ssl
import struct

CA = "/lab/certs/fullchain.pem"
USER = "fixture-user"
PASSWORD = "fixture-password"


def exact(stream, length):
    result = b""
    while len(result) < length:
        chunk = stream.recv(length - len(result))
        if not chunk:
            raise RuntimeError("unexpected EOF")
        result += chunk
    return result


def proxy_socket(port, password=PASSWORD, user=USER, host="node", tls=False):
    stream = socket.create_connection((host, port), timeout=3)
    if tls:
        stream = ssl.create_default_context(cafile=CA).wrap_socket(stream, server_hostname="proxy.lab")
    if port in (8118, 8119):
        auth = base64.b64encode(f"{user}:{password}".encode()).decode()
        stream.sendall(f"CONNECT target:443 HTTP/1.1\r\nHost: target:443\r\nProxy-Authorization: Basic {auth}\r\n\r\n".encode())
        response = b""
        while b"\r\n\r\n" not in response:
            response += exact(stream, 1)
        return stream, int(response.split()[1])
    stream.sendall(b"\x05\x01\x00" if port in (1082, 1083) else b"\x05\x01\x02")
    choice = exact(stream, 2)
    if choice == b"\x05\x02":
        username, secret = user.encode(), password.encode()
        stream.sendall(b"\x01" + bytes([len(username)]) + username + bytes([len(secret)]) + secret)
        if exact(stream, 2)[1] != 0:
            return stream, 407
    elif choice != b"\x05\x00":
        raise RuntimeError("SOCKS method rejected")
    stream.sendall(b"\x05\x01\x00\x03\x06target" + struct.pack("!H", 443))
    result = exact(stream, 4)
    if result[1] != 0:
        raise RuntimeError("SOCKS destination rejected")
    exact(stream, 4 if result[3] == 1 else 16 if result[3] == 4 else exact(stream, 1)[0])
    exact(stream, 2)
    return stream, 200


def fetch(port, password=PASSWORD, user=USER):
    stream, status = proxy_socket(port, password, user, host="127.0.0.1" if port in (1082, 1083) else "node", tls=port in (1080, 8118))
    if status != 200:
        stream.close()
        return status
    # MemoryBIO supports verified HTTPS inside an already TLS-wrapped proxy socket.
    incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
    session = ssl.create_default_context(cafile=CA).wrap_bio(incoming, outgoing, server_hostname="target.lab")
    def pump():
        data = outgoing.read()
        if data:
            stream.sendall(data)
        data = stream.recv(65536)
        if not data:
            raise RuntimeError("HTTPS tunnel closed")
        incoming.write(data)
    while True:
        try:
            session.do_handshake()
            break
        except ssl.SSLWantReadError:
            pump()
    data = outgoing.read()
    if data:
        stream.sendall(data)
    session.write(b"GET /controlled HTTP/1.1\r\nHost: target.lab\r\nConnection: close\r\n\r\n")
    stream.sendall(outgoing.read())
    response = b""
    while b"\r\n\r\n" not in response:
        try:
            response += session.read(65536)
        except ssl.SSLWantReadError:
            pump()
    stream.close()
    return int(response.split()[1])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("target", "fetch", "connect", "raw"))
    parser.add_argument("--port", type=int)
    parser.add_argument("--password", default=PASSWORD)
    parser.add_argument("--user", default=USER)
    parser.add_argument("--payload", default="")
    args = parser.parse_args()
    if args.mode == "target":
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"controlled TLS target\n")
            def log_message(self, *_):
                pass
        server = ThreadingHTTPServer(("0.0.0.0", 443), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(CA, "/lab/certs/privkey.pem")
        server.socket = context.wrap_socket(server.socket, server_side=True)
        server.serve_forever()
    elif args.mode == "fetch":
        print(json.dumps({"status": fetch(args.port, args.password, args.user)}))
    else:
        with socket.create_connection(("node", args.port), timeout=2) as stream:
            if args.mode == "raw":
                stream.sendall(bytes.fromhex(args.payload))
                try:
                    stream.recv(4096)
                except (ConnectionResetError, TimeoutError):
                    pass
        print(json.dumps({"connected": True}))


if __name__ == "__main__":
    main()
