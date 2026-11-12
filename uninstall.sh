#!/bin/bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
read -r -p "Остановить и удалить контейнер? Каталог data останется. [y/N] " answer
[[ "$answer" == [yY] ]] || exit 0
docker compose down
echo "Контейнер удалён; ./data сохранён."
