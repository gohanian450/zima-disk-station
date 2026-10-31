#!/usr/bin/env bash
# =====================================================================
#  effacer-disques.sh — ZimaBoard (v3, avec progression sur l'écran)
#  Efface et reformate TOUS les disques SATA, USB (docks) et NVMe.
#  Le disque système (eMMC / disque qui porte le système) n'est JAMAIS touché.
#  Tous les disques sont traités EN MÊME TEMPS ; la progression s'affiche
#  sur l'écran HDMI (ecran-disques.sh).
#
#  Utilisation :
#    sudo ./effacer-disques.sh --liste          -> montre ce qui serait effacé (rien n'est touché)
#    sudo ./effacer-disques.sh                  -> effacement rapide + ext4
#    sudo MODE=complet ./effacer-disques.sh     -> réécrit tout le disque avec des zéros (long,
#                                                  % réel octet par octet, données irrécupérables)
#    sudo FS=exfat ./effacer-disques.sh         -> formate en exFAT (Windows/Mac)
#    sudo FS=ntfs  ./effacer-disques.sh         -> formate en NTFS
# =====================================================================
set -uo pipefail

FS="${FS:-ext4}"
MODE="${MODE:-rapide}"
STATUS_DIR=/run/effacement
DRY_RUN=0
[[ "${1:-}" == "--liste" ]] && DRY_RUN=1

[[ $EUID -eq 0 ]] || { echo "❌ Lance ce script avec sudo."; exit 1; }
[[ "$FS"   =~ ^(ext4|exfat|ntfs)$ ]]    || { echo "❌ FS doit être ext4, exfat ou ntfs."; exit 1; }
[[ "$MODE" =~ ^(rapide|complet)$ ]]     || { echo "❌ MODE doit être rapide ou complet."; exit 1; }

est_systeme() {
  local d="$1"
  [[ "$d" == /dev/mmcblk* ]] && return 0
  lsblk -nro MOUNTPOINT "$d" 2>/dev/null | grep -qE '^(/|/boot.*|/usr|/var|/DATA)$' && return 0
  return 1
}

# --- Disque qui contient Docker (applis CasaOS / ZimaOS) -----------------
DOCKER_DIR=""; DISQUE_DOCKER=""
if command -v docker >/dev/null 2>&1; then
  DOCKER_DIR=$(timeout 10 docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)
fi
[[ -z "$DOCKER_DIR" && -f /etc/docker/daemon.json ]] && \
  DOCKER_DIR=$(grep -oE '"data-root"[^"]*"[^"]+"' /etc/docker/daemon.json | sed -E 's/.*"([^"]+)"$/\1/' || true)
if [[ -n "$DOCKER_DIR" ]]; then
  src=$(findmnt -no SOURCE --target "$DOCKER_DIR" 2>/dev/null || true)
  pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)
  [[ -n "$pk" ]] && DISQUE_DOCKER="/dev/$pk"
fi

est_docker() {  # disque qui contient les données Docker (applis CasaOS), même si Docker est arrêté
  local d="$1" mp
  [[ -n "$DISQUE_DOCKER" && "$d" == "$DISQUE_DOCKER" ]] && return 0
  for mp in $(lsblk -nro MOUNTPOINT "$d" 2>/dev/null); do
    [[ -d "$mp/docker-data" || -d "$mp/docker" ]] && return 0
  done
  return 1
}

# --- Disques cibles ------------------------------------------------------
CIBLES=()
while read -r nom type tran; do
  [[ "$type" == "disk" ]] || continue
  [[ "${tran:-}" =~ ^(sata|usb|nvme)$ ]] || continue
  if est_systeme "$nom"; then echo "🛡️  Protégé (système) : $nom"; continue; fi
  if est_docker "$nom"; then
    if [[ "${FORCER:-0}" != "1" ]]; then
      echo "🛡️  Protégé : $nom contient Docker et tes applis CasaOS"
      echo "    -> pour l'effacer quand même : arrête Docker, puis sudo FORCER=1 $0"
      continue
    fi
    if systemctl is-active --quiet docker.service 2>/dev/null || pgrep -x dockerd >/dev/null 2>&1; then
      echo "⛔ $nom contient Docker et Docker tourne encore : effacement refusé."
      echo "    -> arrête-le d'abord : sudo systemctl stop docker.socket docker containerd"
      continue
    fi
    echo "⚠️  $nom contient les données Docker : il SERA effacé (FORCER=1)."
  fi
  CIBLES+=("$nom")
done < <(lsblk -dnpo NAME,TYPE,TRAN)

[[ ${#CIBLES[@]} -gt 0 ]] || { echo "Aucun disque SATA/USB à effacer."; exit 0; }

echo
echo "=============== DISQUES QUI SERONT EFFACÉS ==============="
for d in "${CIBLES[@]}"; do
  lsblk -dno NAME,SIZE,TRAN,MODEL -p "$d"
  m=$(lsblk -lno MOUNTPOINT "$d" | grep -v '^$' | tr '\n' ' ')
  [[ -n "$m" ]] && echo "    ⚠️  actuellement utilisé dans : $m"
done
echo "==========================================================="
echo "Mode : $MODE    Système de fichiers : $FS"
echo
[[ $DRY_RUN -eq 1 ]] && { echo "Mode --liste : rien n'a été modifié."; exit 0; }

echo "⚠️  TOUTES les données de ces disques seront DÉTRUITES définitivement."
read -rp "Tape EFFACER (en majuscules) pour continuer : " rep
[[ "$rep" == "EFFACER" ]] || { echo "Annulé."; exit 1; }

mkdir -p "$STATUS_DIR"
rm -f "$STATUS_DIR"/*

duree() {  # secondes -> "1h12" / "4 min"
  local s=$1
  (( s >= 3600 )) && { printf '%dh%02d' $((s/3600)) $(( (s%3600)/60 )); return; }
  printf '%d min' $(( (s+59)/60 ))
}

# --- Travail sur UN disque (lancé en parallèle) -------------------------
travail() {
  local d=$1 label=$2 nom st taille part
  nom=$(basename "$d"); st="$STATUS_DIR/$nom"
  taille=$(blockdev --getsize64 "$d")
  etat() { echo "$1|$2|${3:-}" > "$st"; }   # pourcent | message | octets restants

  etat 2 "Démontage des partitions" "$taille"
  for p in $(lsblk -lnpo NAME "$d" | tail -n +2); do
    swapoff "$p" 2>/dev/null || true
    umount -l "$p" 2>/dev/null || true
  done

  etat 5 "Suppression des signatures" "$taille"
  wipefs -af "$d" >/dev/null 2>&1

  if [[ "$MODE" == "complet" ]]; then
    # Réécriture complète : progression réelle lue dans /proc
    dd if=/dev/zero of="$d" bs=4M oflag=direct status=none 2>/dev/null &
    local pid=$! pos=0 avant=0 t0 t1 vitesse eta
    t0=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
      sleep 3
      pos=$(awk '/^pos:/{print $2}' "/proc/$pid/fdinfo/1" 2>/dev/null || echo "$pos")
      t1=$(date +%s)
      vitesse=$(( (pos - avant) / 3 )); avant=$pos
      if (( vitesse > 0 )); then
        eta=$(duree $(( (taille - pos) / vitesse )))
        etat $(( 5 + pos * 85 / taille )) "Écriture de zéros · $(( vitesse / 1000000 )) Mo/s · ${eta} restantes" $(( taille - pos ))
      fi
    done
    wait "$pid" 2>/dev/null || true      # dd finit toujours par « disque plein » : normal
  else
    etat 30 "Effacement TRIM (SSD)" "$(( taille * 70 / 100 ))"
    if ! blkdiscard "$d" 2>/dev/null; then
      etat 40 "TRIM non supporté · effacement des tables" "$(( taille * 60 / 100 ))"
    fi
    etat 60 "Mise à zéro du début du disque" "$(( taille * 40 / 100 ))"
    dd if=/dev/zero of="$d" bs=1M count=16 conv=fsync status=none 2>/dev/null
  fi

  etat 92 "Création de la table de partitions GPT" "$(( taille * 8 / 100 ))"
  if [[ "$FS" == "ext4" ]]; then
    printf 'label: gpt\n,,L\n' | sfdisk -q "$d" >/dev/null 2>&1
  else
    printf 'label: gpt\n,,EBD0A0A2-B9E5-4433-87C0-68B6B72699C7\n' | sfdisk -q "$d" >/dev/null 2>&1
  fi
  blockdev --rereadpt "$d" 2>/dev/null || true
  udevadm settle 2>/dev/null || sleep 2

  part=$(lsblk -lnpo NAME "$d" | sed -n 2p)
  [[ -n "$part" ]] || { etat 0 "ERREUR : partition introuvable"; return 1; }

  etat 96 "Formatage en $FS" "$(( taille * 4 / 100 ))"
  case "$FS" in
    ext4)  mkfs.ext4 -F -q -L "$label" "$part" ;;
    exfat) mkfs.exfat -n "$label" "$part" >/dev/null ;;
    ntfs)  mkfs.ntfs -f -Q -L "$label" "$part" >/dev/null ;;
  esac || { etat 0 "ERREUR pendant le formatage $FS"; return 1; }

  etat 100 "Terminé · $FS « $label »" 0
}

# --- Lancer tous les disques en parallèle --------------------------------
n=1
for d in "${CIBLES[@]}"; do
  travail "$d" "DISQUE$n" &
  echo "▶ $d → DISQUE$n (suivi sur l'écran HDMI)"
  n=$((n+1))
done

echo "En cours… regarde l'écran du ZimaBoard pour la progression."
wait
echo
echo "🎉 Terminé."
for f in "$STATUS_DIR"/*; do echo "  $(basename "$f") : $(cut -d'|' -f2 "$f")"; done
