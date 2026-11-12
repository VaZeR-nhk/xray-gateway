# Xray Gateway

Docker-based transparent Xray gateway with an integrated Web UI.

> Early development: do not deploy on a production router yet. Host TPROXY rules and profile activation are being ported and validated.

## Target architecture

- One container: Xray Core, Python gateway, Web UI, node checker and update scheduler.
- Docker host networking for transparent proxying.
- Persistent `/etc/xray-gateway` data directory for subscription, HWID, active profile and credentials.
- No subscription node filtering or automatic profile switching.

## Status

The original Debian implementation is being migrated. The Docker runtime and host firewall installer are not yet production-ready.
