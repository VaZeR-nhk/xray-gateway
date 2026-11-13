#!/usr/bin/env python3
"""Read-only, allowlisted view of the active Xray routing configuration."""
import json
from pathlib import Path

CONFIG = Path("/var/lib/xray-gateway/config.json")
RULE_FIELDS = (
    "type", "inboundTag", "domain", "ip", "port", "source", "sourcePort",
    "network", "protocol", "user", "attrs", "process", "packageName",
    "wifiSSID", "wifiBSSID", "domainMatcher", "outboundTag", "balancerTag",
)
DNS_SERVER_FIELDS = ("address", "port", "domains", "expectIPs", "skipFallback", "queryStrategy")


def _value(value, limit=200):
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, str):
        return value[:2048]
    if isinstance(value, list):
        return [_value(item, limit) for item in value[:limit]]
    if isinstance(value, dict):
        return {str(key)[:80]: _value(item, limit) for key, item in list(value.items())[:limit]}
    return str(value)[:2048]


def _selected(source, fields):
    if not isinstance(source, dict):
        return {}
    return {key: _value(source[key]) for key in fields if key in source}


def _outbound(item):
    if not isinstance(item, dict):
        return None
    result = {
        "tag": _value(item.get("tag", "")),
        "protocol": _value(item.get("protocol", "unknown")),
    }
    settings = item.get("settings") if isinstance(item.get("settings"), dict) else {}
    endpoints = []
    for group in ("vnext", "servers"):
        entries = settings.get(group, [])
        if isinstance(entries, list):
            for entry in entries[:100]:
                if isinstance(entry, dict) and entry.get("address"):
                    endpoint = {"address": _value(entry["address"])}
                    if "port" in entry:
                        endpoint["port"] = _value(entry["port"])
                    endpoints.append(endpoint)
    if settings.get("address"):
        endpoint = {"address": _value(settings["address"])}
        if "port" in settings:
            endpoint["port"] = _value(settings["port"])
        endpoints.append(endpoint)
    if endpoints:
        result["endpoints"] = endpoints
    proxy = item.get("proxySettings")
    if isinstance(proxy, dict) and proxy.get("tag"):
        result["proxy_via"] = _value(proxy["tag"])
    stream = item.get("streamSettings")
    if isinstance(stream, dict):
        transport = {}
        for key in ("network", "security"):
            if key in stream:
                transport[key] = _value(stream[key])
        if transport:
            result["transport"] = transport
    return result


def build_routing_view(config):
    if not isinstance(config, dict):
        raise ValueError("Активная конфигурация Xray должна быть JSON-объектом")
    routing = config.get("routing") if isinstance(config.get("routing"), dict) else {}
    rules = routing.get("rules", [])
    balancers = routing.get("balancers", [])
    dns = config.get("dns") if isinstance(config.get("dns"), dict) else {}
    outbounds = config.get("outbounds", [])
    inbounds = config.get("inbounds", [])

    safe_rules = []
    if isinstance(rules, list):
        for index, rule in enumerate(rules[:500]):
            if isinstance(rule, dict):
                safe_rules.append({"index": index + 1, **_selected(rule, RULE_FIELDS)})

    safe_balancers = []
    if isinstance(balancers, list):
        for item in balancers[:100]:
            if not isinstance(item, dict):
                continue
            entry = _selected(item, ("tag", "selector", "fallbackTag", "strategy"))
            safe_balancers.append(entry)

    safe_dns = {}
    for key in ("queryStrategy", "disableCache", "disableFallback", "disableFallbackIfMatch", "tag"):
        if key in dns:
            safe_dns[key] = _value(dns[key])
    servers = dns.get("servers", [])
    safe_dns["servers"] = []
    if isinstance(servers, list):
        for server in servers[:100]:
            if isinstance(server, str):
                safe_dns["servers"].append(server[:2048])
            elif isinstance(server, dict):
                safe_dns["servers"].append(_selected(server, DNS_SERVER_FIELDS))

    safe_outbounds = [item for item in (_outbound(x) for x in outbounds[:200] if isinstance(outbounds, list)) if item]
    safe_inbounds = []
    if isinstance(inbounds, list):
        for item in inbounds[:200]:
            if isinstance(item, dict):
                safe_inbounds.append(_selected(item, ("tag", "protocol", "listen", "port")))

    return {
        "read_only": True,
        "source": "active_config",
        "routing": {
            "domainStrategy": _value(routing.get("domainStrategy")),
            "domainMatcher": _value(routing.get("domainMatcher")),
            "rules": safe_rules,
            "balancers": safe_balancers,
        },
        "dns": safe_dns,
        "outbounds": safe_outbounds,
        "inbounds": safe_inbounds,
    }


def load_routing_view(path=CONFIG):
    try:
        config = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise RuntimeError("Активная конфигурация Xray ещё не создана") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError("Не удалось прочитать активную конфигурацию Xray: " + str(exc)) from exc
    return build_routing_view(config)
