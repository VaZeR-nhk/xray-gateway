#!/bin/bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
git pull --ff-only
docker compose up -d --build
