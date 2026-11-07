"""Phones through a tunnel (pqv/wallet.py): ngrok forwards to the loopback listener, so a request is treated as
remote (pairing code required) when it carries forwarding headers or a non-local Host; and the wallet finds its
tunnel's public URL through ngrok's local agent API."""
import json
import threading
import unittest
from email.message import Message
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest import mock

from pqv import wallet as w


def request(headers, lan=False):
    h = object.__new__(w.H)
    h.headers = Message()
    for k, v in headers.items():
        h.headers[k] = v
    h.server = type("S", (), {"lan": True})() if lan else object()
    return h


class Remote(unittest.TestCase):
    def test_loopback_browser_is_local(self):
        for host in ("127.0.0.1:8201", "localhost:8201", "[::1]:8201", "LOCALHOST"):
            self.assertFalse(request({"Host": host})._remote, host)

    def test_tunnel_host_is_remote(self):
        self.assertTrue(request({"Host": "abcd-1234.ngrok-free.app"})._remote)
        self.assertTrue(request({"Host": "127.0.0.1.evil.example:8201"})._remote)  # DNS-rebinding style names too
        self.assertTrue(request({})._remote)  # no Host header at all: not a local browser

    def test_forwarding_headers_are_remote_even_with_a_local_host(self):
        for k in ("X-Forwarded-For", "X-Forwarded-Host", "Forwarded", "X-Real-IP"):
            self.assertTrue(request({"Host": "127.0.0.1:8201", k: "203.0.113.7"})._remote, k)

    def test_lan_listener_is_remote(self):
        self.assertTrue(request({"Host": "127.0.0.1:9201"}, lan=True)._remote)


class TunnelDiscovery(unittest.TestCase):
    def setUp(self):
        body = json.dumps({"tunnels": [
            {"public_url": "http://alice.example", "config": {"addr": "http://localhost:8201"}},       # http: skipped
            {"public_url": "https://alice.ngrok-free.app/", "config": {"addr": "http://localhost:8201"}},
            {"public_url": "https://other.ngrok-free.app", "config": {"addr": "localhost:18201"}},     # another port
        ]}).encode()

        class Api(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.srv = HTTPServer(("127.0.0.1", 0), Api)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.api = f"http://127.0.0.1:{self.srv.server_port}/api/tunnels"

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def test_finds_the_https_tunnel_to_this_port(self):
        with mock.patch.object(w, "NGROK_APIS", ["http://127.0.0.1:1/api/tunnels", self.api]), mock.patch.object(w, "PORT", 8201):
            self.assertEqual(w.tunnel_url(), "https://alice.ngrok-free.app")
        with mock.patch.object(w, "NGROK_APIS", [self.api]), mock.patch.object(w, "PORT", 8202):
            self.assertIsNone(w.tunnel_url())

    def test_no_agent_running(self):
        with mock.patch.object(w, "NGROK_APIS", ["http://127.0.0.1:1/api/tunnels"]), mock.patch.object(w, "PORT", 8201):
            self.assertIsNone(w.tunnel_url())


if __name__ == "__main__":
    unittest.main()
