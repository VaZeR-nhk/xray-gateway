#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "gateway" / "xray-gateway"
loader = importlib.machinery.SourceFileLoader("xray_gateway_entrypoint", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
gateway = importlib.util.module_from_spec(spec)
loader.exec_module(gateway)


class TproxyConfigTests(unittest.TestCase):
    def setUp(self):
        self.profile = {
            "inbounds": [
                {"tag": "socks", "protocol": "socks", "port": 10808},
                {"tag": "tproxy-in", "protocol": "dokodemo-door", "port": 9999},
            ],
            "routing": {
                "rules": [
                    {"type": "field", "domain": ["domain:local.example"], "outboundTag": "direct"},
                    {"type": "field", "network": "tcp,udp", "balancerTag": "AUTO"},
                ],
                "balancers": [{"tag": "AUTO", "selector": ["proxy"], "strategy": {"type": "leastLoad"}}],
            },
            "outbounds": [{"tag": "proxy", "protocol": "vless"}, {"tag": "direct", "protocol": "freedom"}],
        }

    def build(self, enabled=True, port="12345"):
        cfg = {
            "ENABLE_TPROXY": "true" if enabled else "false",
            "TPROXY_PORT": port,
            "GATEWAY_IP": "192.168.12.39",
        }
        return json.loads(gateway.build(self.profile, cfg))

    def test_enabled_adds_tcp_udp_transparent_inbound(self):
        result = self.build(port="23456")
        inbound = next(x for x in result["inbounds"] if x["tag"] == "tproxy-in")
        self.assertEqual(inbound["protocol"], "tunnel")
        self.assertEqual(inbound["listen"], "0.0.0.0")
        self.assertEqual(inbound["port"], 23456)
        self.assertEqual(inbound["settings"], {"allowedNetwork": "tcp,udp", "followRedirect": True})
        self.assertEqual(inbound["streamSettings"]["sockopt"]["tproxy"], "tproxy")
        self.assertNotIn("sniffing", inbound)

    def test_existing_routing_and_outbounds_are_preserved(self):
        result = self.build()
        self.assertEqual(result["routing"], self.profile["routing"])
        self.assertEqual(result["outbounds"], self.profile["outbounds"])
        self.assertEqual(result["inbounds"][0], self.profile["inbounds"][0])
        self.assertEqual(sum(x.get("tag") == "tproxy-in" for x in result["inbounds"]), 1)
        self.assertEqual(self.profile["inbounds"][1]["port"], 9999)

    def test_disabled_removes_stale_tproxy_inbound(self):
        result = self.build(enabled=False)
        self.assertEqual([x["tag"] for x in result["inbounds"]], ["socks"])

    def test_accepts_decimal_port_with_leading_zeroes(self):
        result = self.build(port="012345")
        inbound = next(x for x in result["inbounds"] if x["tag"] == "tproxy-in")
        self.assertEqual(inbound["port"], 12345)

    def test_rejects_invalid_tproxy_ports(self):
        for value in ("0", "65536", "-1", "12abc", "", "1.5"):
            with self.subTest(port=value):
                with self.assertRaises(ValueError):
                    self.build(port=value)


if __name__ == "__main__":
    unittest.main()
