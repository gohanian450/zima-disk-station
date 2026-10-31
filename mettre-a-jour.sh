#!/usr/bin/env bash
# =====================================================================
#   ZIMA DISK STATION — mise à jour
#   Récupère la dernière version sur GitHub et réinstalle.
#     sudo ./mettre-a-jour.sh
# =====================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "❌ Lance avec sudo."; exit 1; }
cd "$(dirname "$0")"

echo "Recherche de la dernière version…"
git config --global --add safe.directory "$(pwd)" 2>/dev/null || true
avant=$(git rev-parse --short HEAD)
git fetch --quiet origin
git reset --quiet --hard origin/main
apres=$(git rev-parse --short HEAD)

if [[ "$avant" == "$apres" ]]; then
  echo "✅ Déjà à jour ($apres)."
else
  echo "✅ Mise à jour : $avant → $apres"
  git log --oneline "$avant..$apres" | sed 's/^/   • /'
fi
chmod +x ./*.sh ./*.py
./installer.sh

# contrôle final
./verifier.sh
