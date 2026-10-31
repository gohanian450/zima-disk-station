#!/usr/bin/env bash
# =====================================================================
#   ZIMA DISK STATION — vérification
#   Contrôle que c'est bien la dernière version qui s'affiche au démarrage.
#     sudo ./verifier.sh
# =====================================================================
cd "$(dirname "$0")"
V=$'\e[32m'; R=$'\e[31m'; J=$'\e[33m'; G=$'\e[1m'; N=$'\e[0m'
ok=0; ko=0
bon()  { echo "  ${V}✅${N} $1"; ok=$((ok+1)); }
mauv() { echo "  ${R}❌${N} $1"; [[ -n "${2:-}" ]] && echo "     ${J}→ $2${N}"; ko=$((ko+1)); }

echo
echo "${G}ZIMA DISK STATION — vérification${N}"
echo

# 1. Version du dépôt
git config --global --add safe.directory "$(pwd)" 2>/dev/null || true
if git rev-parse HEAD >/dev/null 2>&1; then
  local_v=$(git rev-parse --short HEAD)
  if timeout 15 git fetch --quiet origin 2>/dev/null; then
    distant=$(git rev-parse --short origin/main)
    if [[ "$local_v" == "$distant" ]]; then bon "Dépôt à jour avec GitHub (version $local_v)"
    else mauv "Dépôt en retard : $local_v au lieu de $distant" "sudo ./mettre-a-jour.sh"; fi
  else
    echo "  ${J}⚠️${N}  GitHub injoignable — version locale : $local_v"
  fi
else
  mauv "Ce dossier n'est pas le dépôt GitHub" "refais le git clone"
fi

# 2. Fichiers installés = fichiers du dépôt
DEST=""
for d in /opt/disques /DATA/disques; do [[ -f "$d/ecran-disques.py" ]] && DEST=$d && break; done
if [[ -z "$DEST" ]]; then
  mauv "Station pas encore installée" "sudo ./installer.sh"
else
  for f in ecran-disques.py effacer-disques.sh; do
    if cmp -s "$f" "$DEST/$f"; then bon "$f installé = version du dépôt"
    else mauv "$f installé est différent du dépôt" "sudo ./installer.sh"; fi
  done
  if [[ -e "$DEST/ecran-disques.sh" ]]; then
    mauv "Un ancien ecran-disques.sh traîne dans $DEST" "sudo rm $DEST/ecran-disques.sh"
  else
    bon "Aucun ancien fichier d'écran dans $DEST"
  fi
fi

# 3. Démarrage automatique
if systemctl cat disques-ecran.service >/dev/null 2>&1; then
  exe=$(systemctl cat disques-ecran.service | grep -m1 '^ExecStart=' | cut -d= -f2-)
  if [[ "$exe" == *ecran-disques.py* ]]; then bon "Le service lance la nouvelle interface (ecran-disques.py)"
  else mauv "Le service lance une ancienne version : $exe" "sudo ./installer.sh"; fi
  [[ "$(systemctl is-enabled disques-ecran.service 2>/dev/null)" == "enabled" ]] \
    && bon "Démarre tout seul à chaque allumage" \
    || mauv "Ne démarre pas tout seul" "sudo systemctl enable disques-ecran"
  if systemctl is-active --quiet disques-ecran.service; then bon "En marche en ce moment"
  else mauv "Arrêté en ce moment" "sudo systemctl restart disques-ecran"; fi
elif command -v docker >/dev/null 2>&1 && docker inspect zima-disk-station >/dev/null 2>&1; then
  bon "Mode conteneur Docker installé"
else
  mauv "Aucun service d'écran installé" "sudo ./installer.sh"
fi
if command -v docker >/dev/null 2>&1 && systemctl cat disques-ecran.service >/dev/null 2>&1 \
   && timeout 10 docker inspect zima-disk-station >/dev/null 2>&1; then
  mauv "Un ancien conteneur zima-disk-station tourne en plus du service" "sudo docker rm -f zima-disk-station"
fi

# 4. Rien d'autre ne prend l'écran
autre=""
for dm in lightdm gdm gdm3 sddm lxdm xdm; do
  [[ "$(systemctl is-enabled "$dm.service" 2>/dev/null)" == "enabled" ]] && autre+="$dm "
done
[[ -z "$autre" ]] && bon "Aucun bureau graphique ne recouvre l'écran" \
                  || mauv "Bureau graphique actif : $autre" "sudo ./installer.sh"
[[ "$(systemctl is-enabled getty@tty1.service 2>/dev/null)" == "enabled" ]] \
  && mauv "La console texte tty1 est encore active" "sudo ./installer.sh" \
  || bon "Console texte tty1 désactivée"

# 5. Matériel et outils
[[ -e /dev/fb0 ]] && bon "Écran HDMI détecté (/dev/fb0)" \
                  || mauv "Aucun écran détecté" "branche l'écran HDMI, allume-le, puis sudo reboot"
python3 -c "import PIL" 2>/dev/null && bon "Python + Pillow présents" \
                  || mauv "Pillow manquant" "sudo apt-get install -y -t bullseye python3-pil"
command -v smartctl >/dev/null 2>&1 && bon "smartctl présent (santé des disques)" \
                  || mauv "smartctl manquant" "sudo apt-get install -y -t bullseye smartmontools"

echo
if (( ko == 0 )); then
  echo "${V}${G}Tout est bon ($ok/$ok).${N} Au prochain démarrage, la nouvelle Zima Disk Station s'affichera."
else
  echo "${R}${G}$ko point(s) à corriger${N} — suis les flèches ${J}→${N} ci-dessus."
fi
echo
