#!/usr/bin/env python3
import base64
import importlib.machinery
import importlib.util
import io
import unittest
from email.message import Message
from unittest.mock import patch
from urllib.error import HTTPError

loader=importlib.machinery.SourceFileLoader("xray_gateway", "gateway/xray-gateway")
spec=importlib.util.spec_from_loader(loader.name, loader)
gateway=importlib.util.module_from_spec(spec)
loader.exec_module(gateway)


class HeaderResponse:
    def __init__(self, headers, body=b"[]"):
        self.headers=headers
        self.body=body
    def __enter__(self):
        return self
    def __exit__(self, *args):
        return False
    def read(self):
        return self.body


class HwidHeaderTests(unittest.TestCase):
    def headers(self, **values):
        result=Message()
        for key,value in values.items():
            result[key.replace("_","-")]=value
        return result

    def test_max_devices_header(self):
        with self.assertRaisesRegex(RuntimeError, "достигнут лимит устройств"):
            gateway.check_subscription_headers(self.headers(x_hwid_max_devices_reached="true"))

    def test_legacy_limit_header(self):
        with self.assertRaisesRegex(RuntimeError, "достигнут лимит устройств"):
            gateway.check_subscription_headers(self.headers(x_hwid_limit=" TRUE "))

    def test_announce_base64_is_decoded(self):
        announce=base64.b64encode("Удалите старое устройство".encode()).decode()
        with self.assertRaisesRegex(RuntimeError, "Удалите старое устройство"):
            gateway.check_subscription_headers(self.headers(
                x_hwid_max_devices_reached="true", announce="base64:"+announce))

    def test_unsupported_hwid(self):
        with self.assertRaisesRegex(RuntimeError, "x-hwid-not-supported"):
            gateway.check_subscription_headers(self.headers(x_hwid_not_supported="true"))

    def test_active_alone_is_informational(self):
        gateway.check_subscription_headers(self.headers(x_hwid_active="true"))

    def test_http_200_is_checked_before_body(self):
        headers=self.headers(x_hwid_max_devices_reached="true")
        response=HeaderResponse(headers)
        with patch.object(gateway.urllib.request, "urlopen", return_value=response):
            with self.assertRaisesRegex(RuntimeError, "достигнут лимит устройств"):
                gateway.download({"SUBSCRIPTION_URL":"https://example.invalid/sub", "HWID":"11111111-1111-4111-8111-111111111111"})
        self.assertEqual(response.body,b"[]")

    def test_http_error_headers_are_checked(self):
        headers=self.headers(x_hwid_limit="true")
        error=HTTPError("https://example.invalid/json", 403, "Forbidden", headers, io.BytesIO(b""))
        with patch.object(gateway.urllib.request, "urlopen", side_effect=error):
            with self.assertRaisesRegex(RuntimeError, "достигнут лимит устройств"):
                gateway.download({"SUBSCRIPTION_URL":"https://example.invalid/sub", "HWID":"11111111-1111-4111-8111-111111111111"})


if __name__=="__main__":
    unittest.main(verbosity=2)
