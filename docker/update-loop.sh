#!/bin/sh
set -eu
while :; do
  sleep 3600
  /usr/local/sbin/xray-gateway update || true
done
