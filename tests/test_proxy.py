"""Local deterministic tests; no external network required."""
import http.client
import os
import subprocess
import sys
import time
import unittest

class ProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.proc = subprocess.Popen([sys.executable, "proxy/egress_proxy.py"], env={**os.environ,"PORT":"43128"}, stdout=subprocess.DEVNULL)
        for _ in range(50):
            try:
                c = http.client.HTTPConnection("127.0.0.1",43128,timeout=1)
                c.connect()
                c.close()
                break
            except OSError:
                time.sleep(.05)
        else:
            raise RuntimeError("proxy did not start")

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=5)

    def request(self, method, target):
        c = http.client.HTTPConnection("127.0.0.1",43128,timeout=3)
        c.request(method,target)
        r = c.getresponse()
        status = r.status
        r.read()
        c.close()
        return status

    def test_unapproved_domain(self):
        self.assertEqual(self.request("CONNECT","example.com:443"),403)

    def test_unapproved_port(self):
        self.assertEqual(self.request("CONNECT","api.anthropic.com:80"),403)

    def test_ip_literal(self):
        self.assertEqual(self.request("CONNECT","1.1.1.1:443"),403)

    def test_plain_http(self):
        self.assertEqual(self.request("GET","http://example.com/"),405)

if __name__ == "__main__":
    unittest.main()
