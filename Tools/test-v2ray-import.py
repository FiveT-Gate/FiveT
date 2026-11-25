"""Check the Mac link importer with synthetic share links; no DNS or VPN traffic."""

import json
import os
import subprocess
import sys
import unittest
from urllib.parse import urlencode

APP = sys.argv.pop(1)


class ImportTest(unittest.TestCase):
    def import_link(self, **query):
        link = (
            "vless://11111111-2222-4333-8444-555555555555@192.0.2.10:443?"
            + urlencode(dict(security="tls", sni="example.com", **query))
            + "#sample"
        )
        env = dict(os.environ, FIVET_SHOW_OUTBOUND="1")
        env.pop("FIVET_LAUNCH_CONFIG", None)
        result = subprocess.check_output([APP, "--check-v2ray", link], text=True, env=env, timeout=15)
        summary, outbound = result.splitlines()
        self.assertIn("OK name=sample", summary)
        return json.loads(outbound)["streamSettings"]

    def test_unpinned_link_uses_normal_tls_verification(self):
        self.assertEqual(self.import_link(type="tcp")["tlsSettings"], {"serverName": "example.com"})

    def test_xhttp_link_preserves_certificate_pins_and_names(self):
        pins = "ab" * 32 + "," + ":".join(["CD"] * 32)
        names = "example.com,www.example.net"
        stream = self.import_link(type="xhttp", mode="packet-up", pcs=pins, vcn=names)
        self.assertEqual(stream["xhttpSettings"]["mode"], "packet-up")
        self.assertEqual(stream["tlsSettings"], {
            "serverName": "example.com",
            "pinnedPeerCertSha256": pins,
            "verifyPeerCertByName": names,
        })


if __name__ == "__main__":
    unittest.main()
