# Xray Gateway

Docker-based Xray transparent gateway with an integrated Web UI.

> **ALPHA / NOT PRODUCTION READY.** The current commit ports the core subscription and profile control flow. Host-side TPROXY policy routing and nftables setup are not implemented yet. Do not direct production LAN traffic through this build.

## Architecture

One container runs Xray Core, the Python gateway, Web UI and an hourly subscription updater. Docker uses `network_mode: host` and the required network capabilities. Persistent state is mounted from `./data` to `/etc/xray-gateway`.

## Install

On Debian 12/13 with Docker Engine and Compose v2:

```bash
git clone https://github.com/VaZeR-nhk/xray-gateway.git
cd xray-gateway
./install.sh
```

The installer asks for the Remnawave HTTPS subscription URL and Web UI credentials. Secrets, HAPP HWID, downloaded subscription and active profile state are stored under `./data`, not in Git.

Open `http://SERVER-IP:8080`.

## Operations

```bash
./update.sh
docker compose logs -f
docker compose ps
./uninstall.sh
```

Uninstall preserves `./data`.

## Current behavior

- Subscription is downloaded with a persistent HAPP HWID.
- Original profile list is retained; no actual node is removed or filtered from the subscription.
- Profile selection is manual. The API checks that the selected index is reflected in gateway state before reporting success.
- Xray config is validated before it is applied; failed restarts trigger rollback where a previous config exists.
- The Web UI and Xray run in the same container under Supervisor.

## Not implemented yet

- Host nftables TPROXY rules, policy routing and a reversible host firewall installer.
- Port of the original isolated all-node checker.
- End-to-end tests against the live Remnawave subscription and actual LAN traffic.

Do not enable transparent forwarding until those pieces have been tested on the target host.
