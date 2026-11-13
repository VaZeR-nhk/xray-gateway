#!/usr/bin/env python3
import json
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gateway.routing_view import build_routing_view, load_routing_view


class RoutingViewTests(unittest.TestCase):
    def test_exposes_routes_without_outbound_credentials(self):
        config = {
            "routing": {
                "domainStrategy": "IPIfNonMatch",
                "rules": [
                    {"type": "field", "domain": ["domain:example.org"], "outboundTag": "proxy"},
                    {"type": "field", "ip": ["geoip:private"], "balancerTag": "AUTO"},
                ],
                "balancers": [
                    {"tag": "AUTO", "selector": ["proxy"], "fallbackTag": "proxy",
                     "strategy": {"type": "leastLoad", "settings": {"maxRTT": "1s"}}}
                ],
            },
            "dns": {"queryStrategy": "UseIP", "servers": ["1.1.1.1"]},
            "outbounds": [
                {"tag": "proxy", "protocol": "vless",
                 "settings": {"vnext": [{"address": "node.example.org", "port": 443,
                                         "users": [{"id": "private-uuid", "encryption": "none"}]}]}},
                {"tag": "direct", "protocol": "freedom"},
            ],
            "inbounds": [{"tag": "socks-in", "protocol": "socks", "listen": "127.0.0.1", "port": 10808}],
        }
        result = build_routing_view(config)
        encoded = json.dumps(result)
        self.assertTrue(result["read_only"])
        self.assertEqual(result["routing"]["rules"][1]["balancerTag"], "AUTO")
        self.assertEqual(result["routing"]["balancers"][0]["fallbackTag"], "proxy")
        self.assertEqual(result["outbounds"][0]["endpoints"][0]["address"], "node.example.org")
        self.assertNotIn("private-uuid", encoded)
        self.assertNotIn('"users"', encoded)
        self.assertNotIn('"settings"', encoded)
        self.assertEqual(result["inbounds"][0]["tag"], "socks-in")

    def test_rejects_non_object_config(self):
        with self.assertRaises(ValueError):
            build_routing_view([])

    def test_reads_active_config_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({"routing": {"rules": []}, "outbounds": []}), encoding="utf-8")
            self.assertTrue(load_routing_view(path)["read_only"])


if __name__ == "__main__":
    unittest.main()
