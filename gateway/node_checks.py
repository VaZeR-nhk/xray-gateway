#!/usr/bin/python3
"""Isolated subscription-node checks. Never touches the active gateway config or service."""
import copy
import ipaddress
import json
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

SUBSCRIPTION = Path("/var/lib/xray-gateway/subscription.json")
XRAY = "/usr/local/bin/xray"
CURL = shutil.which("curl")
_lock = threading.Lock()
_state = {"running": False, "started_at": None, "finished_at": None,
          "total": 0, "completed": 0, "results": [], "error": None}


def get_checks():
    with _lock:
        return copy.deepcopy(_state)


def _targets():
    profiles = json.loads(SUBSCRIPTION.read_text())
    targets = []
    for pi, profile in enumerate(profiles):
        profile_name = profile.get("remarks") or f"Профиль {pi + 1}"
        for outbound in profile.get("outbounds", []):
            protocol = outbound.get("protocol")
            if protocol not in ("vless", "hysteria", "hysteria2"):
                continue
            settings = outbound.get("settings", {})
            if protocol == "vless":
                for server in settings.get("vnext", []):
                    item = copy.deepcopy(outbound)
                    item["settings"]["vnext"] = [copy.deepcopy(server)]
                    targets.append({"profile": profile_name, "profile_index": pi,
                        "tag": outbound.get("tag", protocol), "protocol": protocol,
                        "address": server.get("address", "?"), "port": server.get("port", 0),
                        "outbound": item})
            else:
                targets.append({"profile": profile_name, "profile_index": pi,
                    "tag": outbound.get("tag", protocol), "protocol": protocol,
                    "address": settings.get("address", "?"), "port": settings.get("port", 0),
                    "outbound": copy.deepcopy(outbound)})
    return targets


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _direct_ip():
    r = subprocess.run([CURL, "--noproxy", "*", "--connect-timeout", "5",
        "--max-time", "10", "--fail", "--silent", "--show-error",
        "https://api.ipify.org?format=text"], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12)
    if r.returncode:
        raise RuntimeError("Не удалось определить внешний IP сервера: " + r.stderr.strip()[:200])
    value = r.stdout.strip()
    ipaddress.ip_address(value)
    return value


def _run_one(target, direct_ip):
    result = {k: target[k] for k in ("profile", "profile_index", "tag", "protocol", "address", "port")}
    result.update(status="FAIL", latency_ms=None, http_code=None, error=None)
    if not CURL:
        result["error"] = "curl не установлен"
        return result

    port = _free_port()
    config = {"log": {"loglevel": "warning"},
        "inbounds": [{"listen": "127.0.0.1", "port": port, "protocol": "socks",
            "settings": {"auth": "noauth", "udp": False}, "tag": "node-check-in"}],
        "outbounds": [target["outbound"]]}
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix="xray-node-check-") as tmp:
            config_path = Path(tmp) / "config.json"
            log_path = Path(tmp) / "xray.log"
            config_path.write_text(json.dumps(config, ensure_ascii=False))
            config_path.chmod(0o600)
            test = subprocess.run([XRAY, "run", "-test", "-config", str(config_path)],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
            if test.returncode:
                result["error"] = "Ошибка проверки конфигурации Xray: " + test.stdout[-250:]
                return result
            with log_path.open("w") as log:
                process = subprocess.Popen([XRAY, "run", "-config", str(config_path)],
                    stdout=log, stderr=subprocess.STDOUT)
                ready = False
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        break
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                            ready = True
                            break
                    except OSError:
                        time.sleep(0.1)
                if not ready:
                    log.flush()
                    result["error"] = "Локальный SOCKS не запустился: " + log_path.read_text(errors="replace")[-250:]
                    return result
                started = time.monotonic()
                try:
                    r = subprocess.run([CURL, "--socks5-hostname", f"127.0.0.1:{port}",
                        "--connect-timeout", "5", "--max-time", "12", "--silent", "--show-error",
                        "--fail", "--write-out", "|%{http_code}|%{time_starttransfer}",
                        "https://api.ipify.org?format=text"], text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=14)
                    fields = r.stdout.strip().split("|")
                    proxy_ip = fields[0].strip() if len(fields) >= 3 else ""
                    code = fields[1].strip() if len(fields) >= 3 else ""
                    result["http_code"] = code or None
                    if len(fields) >= 3:
                        try:
                            result["latency_ms"] = round(float(fields[2].strip()) * 1000)
                        except ValueError:
                            pass
                    try:
                        ipaddress.ip_address(proxy_ip)
                        valid_ip = True
                    except ValueError:
                        valid_ip = False
                    if r.returncode == 0 and code == "200" and valid_ip:
                        if proxy_ip != direct_ip:
                            result["status"] = "OK"
                        else:
                            result["error"] = "IP выхода совпадает с IP сервера — прокси не подтверждён"
                    else:
                        result["error"] = f"curl exit={r.returncode}, HTTP={code or 'нет ответа'}" + (("; " + r.stderr.strip()[:200]) if r.stderr.strip() else "")
                except subprocess.TimeoutExpired:
                    result["latency_ms"] = round((time.monotonic() - started) * 1000)
                    result["error"] = "Тайм-аут HTTP-проверки"
    except subprocess.TimeoutExpired:
        result["error"] = "Тайм-аут запуска или проверки конфигурации Xray"
    except Exception as e:
        result["error"] = f"{type(e).__name__}: {str(e)[:250]}"
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    return result


def _worker(targets):
    try:
        direct_ip = _direct_ip()
        with ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(_run_one, target, direct_ip) for target in targets]
            for future in as_completed(futures):
                try:
                    item = future.result()
                except Exception as e:
                    item = {"profile": "—", "profile_index": -1, "tag": "—",
                        "protocol": "—", "address": "—", "port": 0, "status": "FAIL",
                        "latency_ms": None, "http_code": None, "error": str(e)[:250]}
                with _lock:
                    _state["results"].append(item)
                    _state["completed"] += 1
    except Exception as e:
        with _lock:
            _state["error"] = str(e)
    finally:
        with _lock:
            _state["running"] = False
            _state["finished_at"] = time.strftime("%Y-%m-%d %H:%M:%S")


def start_checks():
    with _lock:
        if _state["running"]:
            return copy.deepcopy(_state)
        _state.update(running=True, started_at=time.strftime("%Y-%m-%d %H:%M:%S"),
            finished_at=None, total=0, completed=0, results=[], error=None)
    try:
        targets = _targets()
        with _lock:
            _state["total"] = len(targets)
        if not targets:
            with _lock:
                _state["running"] = False
                _state["error"] = "В подписке не найдены поддерживаемые VLESS/Hysteria outbounds"
            return get_checks()
        if not CURL:
            raise RuntimeError("curl не установлен")
        threading.Thread(target=_worker, args=(targets,), daemon=True,
            name="xray-node-checks").start()
    except Exception as e:
        with _lock:
            _state["running"] = False
            _state["error"] = str(e)
    return get_checks()
