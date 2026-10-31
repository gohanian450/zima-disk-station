#!/usr/bin/env bash
# =====================================================================
#  ZIMA DISK STATION — effacer-disques.sh
#  Efface et reformate les disques SATA, USB (docks) et NVMe.
#  Jamais touchés : la mémoire interne (eMMC), le disque système,
#  et le disque qui contient Docker (sauf FORCER=1, Docker arrêté).
#  La progression s'affiche sur l'écran HDMI.
#
#  Utilisation :
#    sudo ./effacer-disques.sh --liste          -> montre ce qui serait effacé (rien n'est touché)
#    sudo ./effacer-disques.sh                  -> efface tous les disques autorisés (demande EFFACER)
#                                                  par défaut : réécriture complète, chaque bloc mis à zéro
#    sudo MODE=rapide ./effacer-disques.sh      -> effacement rapide (TRIM, quelques secondes)
#    sudo FS=exfat ./effacer-disques.sh         -> formate en exFAT (Windows/Mac) — aussi : ntfs
#
#  Utilisé par la station automatique :
#    effacer-disques.sh --candidats             -> liste les disques autorisés (un par ligne)
#    effacer-disques.sh --protege               -> liste « disque|raison » des disques protégés
#    effacer-disques.sh --auto /dev/sdX         -> efface ce disque sans rien demander
# =====================================================================
set -uo pipefail

# réglages par défaut : /etc/zima-disk-station.conf (sinon : réécriture complète, ext4)
CONF=/etc/zima-disk-station.conf
CONF_MODE=""; CONF_FS=""
if [[ -f "$CONF" ]]; then
  CONF_MODE=$(sed -n 's/^MODE=//p' "$CONF" | tail -n1 | tr -d ' "')
  CONF_FS=$(sed -n 's/^FS=//p' "$CONF" | tail -n1 | tr -d ' "')
fi
FS="${FS:-${CONF_FS:-ext4}}"
MODE="${MODE:-${CONF_MODE:-complet}}"
STATUS_DIR=/run/effacement
ETIQUETTE="ZDS-EFFACE"        # nom donné aux disques effacés (permet de les reconnaître)
ACTION="effacer"; CIBLE_AUTO=""
case "${1:-}" in
  --liste)     ACTION="liste" ;;
  --candidats) ACTION="candidats" ;;
  --protege)   ACTION="protege" ;;
  --auto)      ACTION="auto"; CIBLE_AUTO="${2:-}" ;;
esac
# le mode automatique n'efface jamais le disque Docker, même avec FORCER=1
[[ "$ACTION" =~ ^(candidats|protege|auto)$ ]] && FORCER=0

[[ $EUID -eq 0 ]] || { echo "❌ Lance ce script avec sudo."; exit 1; }
[[ "$FS"   =~ ^(ext4|exfat|ntfs)$ ]] || { echo "❌ FS doit être ext4, exfat ou ntfs."; exit 1; }
[[ "$MODE" =~ ^(rapide|complet)$ ]]  || { echo "❌ MODE doit être rapide ou complet."; exit 1; }

dire() { [[ "$ACTION" =~ ^(candidats|protege|auto)$ ]] || echo "$@"; }

# --- Protections ---------------------------------------------------------
est_systeme() {
  local d="$1"
  [[ "$d" == /dev/mmcblk* ]] && return 0
  lsblk -nro MOUNTPOINT "$d" 2>/dev/null | grep -qE '^(/|/boot.*|/usr|/var|/DATA)$' && return 0
  return 1
}

DOCKER_DIR=""; DISQUE_DOCKER=""; DOCKER_ACTIF=0
if command -v docker >/dev/null 2>&1; then
  DOCKER_DIR=$(timeout 10 docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)
  [[ -n "$DOCKER_DIR" ]] && DOCKER_ACTIF=1
fi
if [[ -z "$DOCKER_DIR" && -f /etc/docker/daemon.json ]]; then
  DOCKER_DIR=$(grep -oE '"data-root"[^"]*"[^"]+"' /etc/docker/daemon.json | sed -E 's/.*"([^"]+)"$/\1/' || true)
fi
if [[ -n "$DOCKER_DIR" ]]; then
  src=$(findmnt -no SOURCE --target "$DOCKER_DIR" 2>/dev/null || true)
  pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)
  [[ -n "$pk" ]] && DISQUE_DOCKER="/dev/$pk"
fi

est_docker() {  # disque qui contient les données Docker (applis CasaOS)
  local d="$1" mp
  [[ -n "$DISQUE_DOCKER" && "$d" == "$DISQUE_DOCKER" ]] && return 0
  # Docker tourne et utilise un autre disque : un vieux dossier docker-data ne protège plus rien
  (( DOCKER_ACTIF )) && return 1
  # Docker arrêté : on reste prudent et on protège tout disque qui contient des données Docker
  for mp in $(lsblk -nro MOUNTPOINT "$d" 2>/dev/null); do
    [[ -d "$mp/docker-data" || -d "$mp/docker" ]] && return 0
  done
  return 1
}

# --- Disques autorisés ---------------------------------------------------
CIBLES=(); PROTEGES=()
while read -r nom type tran; do
  [[ "$type" == "disk" ]] || continue
  [[ "${tran:-}" =~ ^(sata|usb|nvme)$ ]] || continue
  if est_systeme "$nom"; then
    dire "🛡️  Protégé (système) : $nom"; PROTEGES+=("$nom|système"); continue
  fi
  if est_docker "$nom"; then
    if [[ "${FORCER:-0}" != "1" ]]; then
      dire "🛡️  Protégé : $nom contient Docker et tes applis CasaOS"
      dire "    -> pour l'effacer quand même : arrête Docker, puis sudo FORCER=1 $0"
      PROTEGES+=("$nom|Docker"); continue
    fi
    if systemctl is-active --quiet docker.service 2>/dev/null || pgrep -x dockerd >/dev/null 2>&1; then
      dire "⛔ $nom contient Docker et Docker tourne encore : effacement refusé."
      dire "    -> arrête-le d'abord : sudo systemctl stop docker.socket docker containerd"
      PROTEGES+=("$nom|Docker"); continue
    fi
    dire "⚠️  $nom contient les données Docker : il SERA effacé (FORCER=1)."
  fi
  CIBLES+=("$nom")
done < <(lsblk -dnpo NAME,TYPE,TRAN)

case "$ACTION" in
  candidats) printf '%s\n' "${CIBLES[@]+"${CIBLES[@]}"}"; exit 0 ;;
  protege)   printf '%s\n' "${PROTEGES[@]+"${PROTEGES[@]}"}"; exit 0 ;;
  auto)
    trouve=0
    for d in "${CIBLES[@]+"${CIBLES[@]}"}"; do [[ "$d" == "$CIBLE_AUTO" ]] && trouve=1; done
    (( trouve )) || { echo "Refusé : $CIBLE_AUTO n'est pas un disque autorisé." >&2; exit 2; }
    CIBLES=("$CIBLE_AUTO") ;;
esac

[[ ${#CIBLES[@]} -gt 0 ]] || { echo "Aucun disque SATA/USB à effacer."; exit 0; }

if [[ "$ACTION" != "auto" ]]; then
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
  [[ "$ACTION" == "liste" ]] && { echo "Mode --liste : rien n'a été modifié."; exit 0; }

  echo "⚠️  TOUTES les données de ces disques seront DÉTRUITES définitivement."
  read -rp "Tape EFFACER (en majuscules) pour continuer : " rep
  [[ "$rep" == "EFFACER" ]] || { echo "Annulé."; exit 1; }
fi

mkdir -p "$STATUS_DIR"
for d in "${CIBLES[@]}"; do rm -f "$STATUS_DIR/${d##*/}"; done

duree() {
  local s=$1
  (( s >= 3600 )) && { printf '%dh%02d' $((s/3600)) $(( (s%3600)/60 )); return; }
  printf '%d min' $(( (s+59)/60 ))
}

# --- Effacement d'UN disque ---------------------------------------------
travail() {
  local d=$1 nom st taille part
  nom=$(basename "$d"); st="$STATUS_DIR/$nom"
  taille=$(blockdev --getsize64 "$d")
  etat() { echo "$1|$2|${3:-}|${4:-}" > "$st"; }   # pourcent | message | octets restants | heure de fin (epoch)
  local verifie=""

  etat 2 "Démontage des partitions" "$taille"
  for p in $(lsblk -lnpo NAME "$d" | tail -n +2); do
    swapoff "$p" 2>/dev/null || true
    umount -l "$p" 2>/dev/null || true
  done

  etat 5 "Suppression des signatures" "$taille"
  wipefs -af "$d" >/dev/null 2>&1

  if [[ "$MODE" == "complet" ]]; then
    dd if=/dev/zero of="$d" bs=64M oflag=direct status=none 2>/dev/null &
    local pid=$! pos=0 avant=0 vitesse eta
    while kill -0 "$pid" 2>/dev/null; do
      sleep 3
      pos=$(awk '/^pos:/{print $2}' "/proc/$pid/fdinfo/1" 2>/dev/null || echo "$pos")
      vitesse=$(( (pos - avant) / 3 )); avant=$pos
      if (( vitesse > 0 )); then
        local reste_s=$(( (taille - pos) / vitesse ))
        eta=$(duree "$reste_s")
        etat $(( 5 + pos * 83 / taille )) "Écriture de zéros · $(( vitesse / 1000000 )) Mo/s · ${eta} restantes" \
             $(( taille - pos )) $(( $(date +%s) + reste_s + 60 ))
      fi
    done
    wait "$pid" 2>/dev/null || true      # dd finit toujours par « disque plein » : normal

    # Vérification : relit le début, la fin et 64 endroits au hasard ; tout doit être à zéro
    local mio=$(( taille / 1048576 )) n=0 total=66 off mauvais=0
    for off in 0 $(( mio > 1 ? mio - 1 : 0 )) $(for _ in $(seq 64); do echo $(( (RANDOM * 32768 + RANDOM) % (mio > 0 ? mio : 1) )); done); do
      n=$((n + 1))
      etat $(( 88 + n * 3 / total )) "Vérification · échantillon $n / $total" "$(( taille * 8 / 100 ))"
      if [[ $(dd if="$d" bs=1M skip="$off" count=1 iflag=direct status=none 2>/dev/null | tr -d '\0' | head -c1 | wc -c) -ne 0 ]]; then
        mauvais=$((mauvais + 1))
      fi
    done
    if (( mauvais > 0 )); then
      etat 0 "ERREUR : vérification échouée · $mauvais zone(s) non effacée(s)"
      return 1
    fi
    verifie=" · vérifié"

    etat 91 "Réécriture vérifiée · nettoyage TRIM" "$(( taille * 9 / 100 ))"
    blkdiscard "$d" 2>/dev/null || true  # SSD : libère les cellules (sans effet sur un HDD)
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
    ext4)  mkfs.ext4 -F -q -L "$ETIQUETTE" "$part" ;;
    exfat) mkfs.exfat -n "$ETIQUETTE" "$part" >/dev/null ;;
    ntfs)  mkfs.ntfs -f -Q -L "$ETIQUETTE" "$part" >/dev/null ;;
  esac || { etat 0 "ERREUR pendant le formatage $FS"; return 1; }

  etat 100 "Terminé · $FS « $ETIQUETTE »$verifie" 0
}

for d in "${CIBLES[@]}"; do
  travail "$d" &
  dire "▶ $d (suivi sur l'écran HDMI)"
done
dire "En cours… regarde l'écran du ZimaBoard pour la progression."
wait
if [[ "$ACTION" != "auto" ]]; then
  echo
  echo "🎉 Terminé."
  for d in "${CIBLES[@]}"; do echo "  ${d##*/} : $(cut -d'|' -f2 "$STATUS_DIR/${d##*/}" 2>/dev/null)"; done
fi
