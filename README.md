# Xray Gateway

Docker-based Xray transparent gateway with an integrated Web UI.

> **ALPHA / NOT PRODUCTION READY.** The Docker image and host TPROXY rules have not yet completed end-to-end validation against a real LAN and Remnawave subscription. Test on an isolated host before routing production traffic.

## Architecture

One container runs Xray Core, the Python gateway, Web UI, isolated node checker and hourly subscription updater. Docker uses `network_mode: host`. Persistent state is mounted from `./data` to `/etc/xray-gateway`.

The host-side network helper creates a dedicated nftables table (`inet xray_gateway`), one IPv4 policy-routing rule and a local route in table 100. It does not flush or rewrite the host's existing firewall. It intercepts TCP and UDP arriving on the selected LAN interface, excluding RFC1918, link-local, multicast, loopback, reserved and the configured LAN subnet. IPv6 interception is not implemented.

## Requirements

- Debian 12/13, IPv4 LAN.
- Docker Engine and Docker Compose v2.
- Root access.
- A dedicated LAN ingress interface (often a Linux bridge such as `br0`).

## Install

First install and start the container:

```bash
git clone https://github.com/VaZeR-nhk/xray-gateway.git
cd xray-gateway
bash install.sh
```

The installer asks for the Remnawave HTTPS subscription URL and Web UI credentials. Secrets, HAPP HWID, downloaded subscription and active profile state are stored under `./data`, not in Git.

After confirming that the container and Xray are running, install host TPROXY rules:

```bash
bash host-network.sh install
```

The helper asks for the LAN ingress interface and LAN CIDR (for example `br0` and `192.168.12.0/24`). You can also pass them as arguments:

```bash
bash host-network.sh install br0 192.168.12.0/24
```

It installs a dedicated systemd oneshot unit for persistence across reboot. The helper stores the previous `rp_filter` values and restores them on removal. Review the interface carefully: traffic is intercepted only when it enters through that interface.

Open `http://SERVER-IP:8080` from a trusted management network. The built-in Web UI uses HTTP Basic Authentication; do not expose port 8080 directly to the public Internet. Put it behind a trusted reverse proxy with TLS if remote access is required.

## Operations

```bash
bash update.sh
docker compose logs -f
docker compose ps
```

Remove only the host TPROXY integration:

```bash
bash host-network.sh uninstall
```

Remove the container while preserving `./data`:

```bash
bash uninstall.sh
```

## Current behavior

- Subscription is downloaded with a persistent HAPP HWID.
- Original profile list is retained; no actual node is removed or filtered from the subscription.
- Profile selection is manual. The API verifies the selected index after applying it.
- Xray config is validated before it is applied; failed restarts trigger rollback where a previous config exists.
- Node checks run separate temporary Xray processes through local SOCKS listeners. They do not restart or alter the main Xray process, active profile or subscription JSON.
- The Web UI and Xray run in the same container under Supervisor.
- Subscription update runs hourly.

## Important limitations

- TPROXY setup currently handles IPv4 only. IPv6 traffic is not intercepted and must be handled separately or disabled/routed outside this gateway.
- The node check uses `http://www.gstatic.com/generate_204`; a node can be usable while this particular test endpoint is blocked.
- No automatic failover or profile switching is performed.
- No production end-to-end validation has yet been completed. Do not direct an entire production LAN through this build until the checklist below passes.

## Pre-production checklist

1. Back up the existing native gateway, including its original HWID, settings, subscription, active profile, config and Web UI credentials.
2. Build the image and verify container health and Xray status.
3. Confirm that the panel lists all subscription profiles and that manual profile selection changes the active configuration.
4. Run all node checks and compare their results with independent connectivity tests.
5. Apply host TPROXY on a test LAN client first.
6. Verify LAN-to-LAN, router management, DNS, IPv4, UDP and direct/private destinations.
7. Reboot and confirm the systemd TPROXY unit restores the rules.
8. Run the uninstall command and confirm that only project-owned rules are removed.

Do not migrate or stop an existing native production gateway using this repository yet. A dedicated data/HWID migration and rollback procedure still needs to be completed and tested.
