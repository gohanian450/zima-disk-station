#!/usr/bin/env bash
# =====================================================================
#   ZIMA DISK STATION — installateur
#
#     sudo ./installer.sh                 -> installe et affiche l'écran
#     sudo ./installer.sh --desinstaller  -> retire tout
#
#   Installe deux services qui démarrent tout seuls :
#     • disques-ecran : le tableau de bord sur l'écran HDMI
#     • disques-auto  : l'effacement automatique des disques branchés
#   Réglages : /etc/zima-disk-station.conf
# =====================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "❌ Lance avec sudo."; exit 1; }

SERVICE=/etc/systemd/system/disques-ecran.service
SERVICE_AUTO=/etc/systemd/system/disques-auto.service
CONF=/etc/zima-disk-station.conf
CONTENEUR=zima-disk-station

retirer() {
  systemctl disable --now disques-ecran.service disques-auto.service 2>/dev/null || true
  rm -f "$SERVICE" "$SERVICE_AUTO"
  systemctl daemon-reload 2>/dev/null || true
  if command -v docker >/dev/null 2>&1; then
    docker rm -f "$CONTENEUR" >/dev/null 2>&1 || true
  fi
}

if [[ "${1:-}" == "--desinstaller" ]]; then
  retirer
  for f in /opt/disques/.bureau-desactive /DATA/disques/.bureau-desactive; do
    [[ -f "$f" ]] || continue
    while read -r dm; do
      if [[ "$dm" == "graphical" ]]; then systemctl set-default graphical.target >/dev/null 2>&1 || true
      else systemctl enable "$dm.service" >/dev/null 2>&1 || true; fi
    done < "$f"
    echo "ℹ️  Bureau graphique réactivé (actif au prochain démarrage)."
  done
  rm -rf /opt/disques /DATA/disques
  rm -f "$CONF"
  systemctl enable --now getty@tty1.service 2>/dev/null || true
  echo "✅ ZIMA DISK STATION désinstallé."
  exit 0
fi

ICI=$(cd "$(dirname "$0")" && pwd)
for f in ecran-disques.py effacer-disques.sh auto-effacement.sh polices; do
  [[ -e "$ICI/$f" ]] || { echo "❌ Il manque « $f » à côté de installer.sh."; exit 1; }
done
[[ -e /dev/fb0 ]] || echo "ℹ️  Aucun écran détecté pour l'instant : branche l'écran HDMI, il s'affichera au prochain démarrage."

# ---------------------------------------------------------------- 1. copie des fichiers
DEST=/opt/disques
if ! mkdir -p "$DEST" 2>/dev/null || ! touch "$DEST/.test" 2>/dev/null; then
  DEST=/DATA/disques          # ZimaOS : le système est en lecture seule
  mkdir -p "$DEST"
fi
rm -f "$DEST/.test"
cp -r "$ICI/ecran-disques.py" "$ICI/effacer-disques.sh" "$ICI/auto-effacement.sh" "$ICI/polices" "$DEST/"
[[ -f "$ICI/Dockerfile" ]] && cp "$ICI/Dockerfile" "$DEST/"
chmod +x "$DEST/effacer-disques.sh" "$DEST/ecran-disques.py" "$DEST/auto-effacement.sh"
if [[ ! -f "$CONF" ]]; then
  cat > "$CONF" <<'REGLAGES'
# ZIMA DISK STATION — réglages
# AUTO=1 : tout disque SATA / USB branché est effacé après le compte à rebours
# AUTO=0 : rien n'est effacé tant qu'on ne lance pas effacer-disques.sh
AUTO=1
# secondes de compte à rebours avant l'effacement automatique (minimum 10)
DELAI=30
# complet = chaque bloc du disque réécrit avec des zéros (long) · rapide = TRIM (secondes)
MODE=complet
# ext4 · exfat (Windows / Mac) · ntfs
FS=ext4
REGLAGES
  echo "✅ Réglages créés : $CONF (effacement automatique ACTIVÉ)"
fi
mkdir -p /run/effacement
echo "✅ Fichiers copiés dans $DEST"

retirer   # repart propre si une ancienne version tourne

# ---------------------------------------------------------------- 2. choisir le mode
python_ok() { command -v python3 >/dev/null 2>&1 && python3 -c "import PIL" 2>/dev/null; }

if ! python_ok && command -v apt-get >/dev/null 2>&1; then
  echo "Installation de Python, Pillow et smartmontools…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true
  apt-get install -y -qq python3 python3-pil smartmontools >/dev/null
fi

# l'écran ne doit plus être recouvert par la console texte ni par un bureau graphique
systemctl disable --now getty@tty1.service 2>/dev/null || true
for dm in lightdm gdm gdm3 sddm lxdm xdm; do
  if systemctl is-enabled "$dm.service" >/dev/null 2>&1; then
    systemctl disable --now "$dm.service" >/dev/null 2>&1 || true
    echo "$dm" >> "$DEST/.bureau-desactive"
    echo "ℹ️  Bureau graphique ($dm) désactivé pour laisser l'écran à la station."
  fi
done
if [[ "$(systemctl get-default 2>/dev/null)" == "graphical.target" ]]; then
  systemctl set-default multi-user.target >/dev/null 2>&1 || true
  echo "graphical" >> "$DEST/.bureau-desactive"
fi
setterm --blank 0 --powerdown 0 --cursor off </dev/tty1 >/dev/tty1 2>/dev/null || true

if python_ok; then
  # ------------------------------------------------ mode natif (Debian / CasaOS)
  command -v smartctl >/dev/null 2>&1 || echo "⚠️  smartctl absent : la santé affichera « SMART absent »."
  cat > "$SERVICE" <<EOF
[Unit]
Description=ZIMA DISK STATION - tableau de bord des disques sur l'ecran HDMI
After=multi-user.target
Conflicts=getty@tty1.service

[Service]
Type=simple
Environment=PYTHONUNBUFFERED=1
ExecStartPre=-/bin/chvt 1
ExecStartPre=/bin/mkdir -p /run/effacement
ExecStart=/usr/bin/env python3 $DEST/ecran-disques.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now disques-ecran.service
  MODE="service système"

elif command -v docker >/dev/null 2>&1; then
  # ------------------------------------------------ mode Docker (ZimaOS)
  echo "Python absent : construction du conteneur (quelques minutes la première fois)…"
  docker build -q -t "$CONTENEUR" "$DEST" >/dev/null
  docker run -d --name "$CONTENEUR" --restart unless-stopped \
    --privileged --network host --pid host \
    -v /dev:/dev -v /run/udev:/run/udev:ro -v /run/effacement:/run/effacement \
    -v "$CONF":"$CONF":ro \
    -e ZDS_CHEMIN="$DEST" \
    "$CONTENEUR" >/dev/null
  MODE="conteneur Docker"

else
  echo "❌ Ni Python (avec Pillow) ni Docker trouvés : impossible d'afficher l'écran."
  exit 1
fi

# ---------------------------------------------------------------- 3. effacement automatique
cat > "$SERVICE_AUTO" <<SERVICEAUTO
[Unit]
Description=ZIMA DISK STATION - effacement automatique des disques branches
After=multi-user.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/effacement
ExecStart=$DEST/auto-effacement.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEAUTO
systemctl daemon-reload
systemctl enable --now disques-auto.service

echo
echo "✅ ZIMA DISK STATION est affiché sur l'écran HDMI ($MODE) et redémarrera tout seul."
"$DEST/auto-effacement.sh" --etat | sed 's/^/   /'
echo "   Activer / désactiver ....... sudo $DEST/auto-effacement.sh --activer   (ou --desactiver)"
echo
echo "   Effacer les disques ........ sudo $DEST/effacer-disques.sh"
echo "   Vérifier sans rien effacer . sudo $DEST/effacer-disques.sh --liste"
echo "   Effacement rapide (TRIM) .. sudo MODE=rapide $DEST/effacer-disques.sh"
echo "   Désinstaller ............... sudo ./installer.sh --desinstaller"
