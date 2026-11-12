#!/bin/sh
set -eu
while :; do
  sleep 3600
  /usr/local/bin/xray-gateway update || true
done
