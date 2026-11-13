#!/bin/bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
read -r -p "Остановить и удалить контейнер? Каталог state и файл .env останутся. [y/N] " answer
[[ "$answer" == [yY] ]] || exit 0
docker compose down
echo "Контейнер удалён; ./state и .env сохранены."
