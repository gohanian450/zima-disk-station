#!/usr/bin/env bash
# =====================================================================
#   ZIMA DISK STATION — installateur
#
#     sudo ./installer.sh                 -> installe et affiche l'écran
#     sudo ./installer.sh --desinstaller  -> retire tout
#
#   Garde tous les fichiers du dossier ensemble :
#     installer.sh  ecran-disques.py  effacer-disques.sh  Dockerfile  polices/
# =====================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "❌ Lance avec sudo."; exit 1; }

SERVICE=/etc/systemd/system/disques-ecran.service
CONTENEUR=zima-disk-station

retirer() {
  systemctl disable --now disques-ecran.service 2>/dev/null || true
  rm -f "$SERVICE"
  systemctl daemon-reload 2>/dev/null || true
  if command -v docker >/dev/null 2>&1; then
    docker rm -f "$CONTENEUR" >/dev/null 2>&1 || true
  fi
}

if [[ "${1:-}" == "--desinstaller" ]]; then
  retirer
  rm -rf /opt/disques /DATA/disques
  systemctl enable --now getty@tty1.service 2>/dev/null || true
  echo "✅ ZIMA DISK STATION désinstallé."
  exit 0
fi

ICI=$(cd "$(dirname "$0")" && pwd)
for f in ecran-disques.py effacer-disques.sh polices; do
  [[ -e "$ICI/$f" ]] || { echo "❌ Il manque « $f » à côté de installer.sh."; exit 1; }
done
[[ -e /dev/fb0 ]] || echo "⚠️  /dev/fb0 introuvable : branche l'écran HDMI et redémarre si l'image n'apparaît pas."

# ---------------------------------------------------------------- 1. copie des fichiers
DEST=/opt/disques
if ! mkdir -p "$DEST" 2>/dev/null || ! touch "$DEST/.test" 2>/dev/null; then
  DEST=/DATA/disques          # ZimaOS : le système est en lecture seule
  mkdir -p "$DEST"
fi
rm -f "$DEST/.test"
cp -r "$ICI/ecran-disques.py" "$ICI/effacer-disques.sh" "$ICI/polices" "$DEST/"
[[ -f "$ICI/Dockerfile" ]] && cp "$ICI/Dockerfile" "$DEST/"
chmod +x "$DEST/effacer-disques.sh" "$DEST/ecran-disques.py"
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

# l'écran ne doit plus être recouvert par la console texte
systemctl disable --now getty@tty1.service 2>/dev/null || true
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
    -e ZDS_CHEMIN="$DEST" \
    "$CONTENEUR" >/dev/null
  MODE="conteneur Docker"

else
  echo "❌ Ni Python (avec Pillow) ni Docker trouvés : impossible d'afficher l'écran."
  exit 1
fi

echo
echo "✅ ZIMA DISK STATION est affiché sur l'écran HDMI ($MODE) et redémarrera tout seul."
echo
echo "   Effacer les disques ........ sudo $DEST/effacer-disques.sh"
echo "   Vérifier sans rien effacer . sudo $DEST/effacer-disques.sh --liste"
echo "   Effacement complet (lent) .. sudo MODE=complet $DEST/effacer-disques.sh"
echo "   Désinstaller ............... sudo ./installer.sh --desinstaller"
