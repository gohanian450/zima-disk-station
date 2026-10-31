#!/usr/bin/env bash
# =====================================================================
#  ZIMA DISK STATION — effacement automatique
#  Tout disque SATA / USB / NVMe branché est effacé après un compte à
#  rebours affiché à l'écran. Débrancher le disque pendant le compte à
#  rebours annule l'effacement.
#
#  Jamais effacés automatiquement : mémoire interne, disque système,
#  disque qui contient Docker, et disques déjà effacés par la station.
#
#    sudo ./auto-effacement.sh --activer     -> active l'effacement automatique
#    sudo ./auto-effacement.sh --desactiver  -> le désactive
#    sudo ./auto-effacement.sh --etat        -> affiche le réglage actuel
#  Réglages : /etc/zima-disk-station.conf
# =====================================================================
set -uo pipefail
CONF=/etc/zima-disk-station.conf
ICI=$(cd "$(dirname "$0")" && pwd)
STATUS_DIR=/run/effacement
ETIQUETTE="ZDS-EFFACE"

lire_conf() {
  AUTO=0; DELAI=30; MODE=complet; FS=ext4
  # shellcheck disable=SC1090
  [[ -f "$CONF" ]] && . "$CONF"
  [[ "$DELAI" =~ ^[0-9]+$ ]] || DELAI=30
  (( DELAI < 10 )) && DELAI=10      # toujours au moins 10 s pour pouvoir annuler
}

regler() {
  [[ $EUID -eq 0 ]] || { echo "❌ Lance avec sudo."; exit 1; }
  [[ -f "$CONF" ]] || printf 'AUTO=0\nDELAI=30\nMODE=complet\nFS=ext4\n' > "$CONF"
  if grep -q '^AUTO=' "$CONF"; then sed -i "s/^AUTO=.*/AUTO=$1/" "$CONF"; else echo "AUTO=$1" >> "$CONF"; fi
}

case "${1:-}" in
  --activer|on)     regler 1; echo "✅ Effacement automatique ACTIVÉ : tout disque branché sera effacé après le compte à rebours."; exit 0 ;;
  --desactiver|off) regler 0; echo "✅ Effacement automatique DÉSACTIVÉ : les disques restent « En attente »."; exit 0 ;;
  --etat)           lire_conf; (( AUTO == 1 )) && echo "Effacement automatique : ACTIVÉ (délai ${DELAI} s, mode $MODE, $FS)" \
                                                || echo "Effacement automatique : désactivé"; exit 0 ;;
esac

[[ $EUID -eq 0 ]] || { echo "❌ Lance avec sudo."; exit 1; }
mkdir -p "$STATUS_DIR"

identite() { lsblk -dno SERIAL,SIZE,MODEL "$1" 2>/dev/null | tr -s ' '; }
deja_efface() { lsblk -lno LABEL "$1" 2>/dev/null | grep -qx "$ETIQUETTE"; }
statut() { echo "$2|$3|${4:-}" > "$STATUS_DIR/${1##*/}"; }

rebours_puis_effacer() {
  local d=$1 id=$2 s
  lire_conf
  for ((s = DELAI; s > 0; s--)); do
    # disque débranché ou remplacé, ou mode auto coupé : on annule
    if [[ ! -b "$d" || "$(identite "$d")" != "$id" ]]; then rm -f "$STATUS_DIR/${d##*/}"; return 0; fi
    lire_conf
    if (( AUTO != 1 )); then rm -f "$STATUS_DIR/${d##*/}"; return 0; fi
    # un effacement manuel a été lancé entre-temps sur ce disque : on le laisse faire
    if (( s < DELAI )) && [[ -f "$STATUS_DIR/${d##*/}" ]] \
       && ! grep -q '|Effacement automatique dans' "$STATUS_DIR/${d##*/}"; then return 0; fi
    statut "$d" $(( (DELAI - s) * 100 / DELAI )) "Effacement automatique dans $s s · débranche le disque pour annuler"
    sleep 1
  done
  deja_efface "$d" && { statut "$d" 100 "Déjà effacé · « $ETIQUETTE »" 0; return 0; }
  echo "Effacement automatique de $d ($id)"
  if ! MODE="$MODE" FS="$FS" "$ICI/effacer-disques.sh" --auto "$d"; then
    statut "$d" 0 "ERREUR : effacement automatique refusé ou échoué"
  fi
}

declare -A VU PID
echo "Service d'effacement automatique démarré."
while true; do
  lire_conf

  # disques débranchés ou remplacés : on les oublie
  for d in "${!VU[@]}"; do
    if [[ ! -b "$d" || "$(identite "$d")" != "${VU[$d]}" ]]; then
      unset "VU[$d]" "PID[$d]"
      rm -f "$STATUS_DIR/${d##*/}"
    fi
  done

  # disques protégés : affichés comme tels à l'écran
  while IFS='|' read -r d raison; do
    [[ -n "$d" ]] || continue
    if [[ "$raison" == "Docker" ]]; then statut "$d" 0 "PROTÉGÉ · contient Docker et les applis CasaOS"
    else statut "$d" 0 "PROTÉGÉ · disque du système"; fi
    VU[$d]=$(identite "$d")
  done < <("$ICI/effacer-disques.sh" --protege 2>/dev/null)

  if (( AUTO == 1 )); then
    while read -r d; do
      [[ -n "$d" ]] || continue
      id=$(identite "$d")
      [[ "${VU[$d]:-}" == "$id" ]] && continue                       # déjà pris en charge
      [[ -n "${PID[$d]:-}" ]] && kill -0 "${PID[$d]}" 2>/dev/null && continue   # en cours
      VU[$d]=$id
      if deja_efface "$d"; then
        statut "$d" 100 "Déjà effacé · « $ETIQUETTE »" 0
        continue
      fi
      rebours_puis_effacer "$d" "$id" &
      PID[$d]=$!
    done < <("$ICI/effacer-disques.sh" --candidats 2>/dev/null)
  else
    # mode auto coupé : on oublie les disques non protégés et sans travail en cours
    for d in "${!VU[@]}"; do
      if [[ -z "${PID[$d]:-}" ]] || ! kill -0 "${PID[$d]}" 2>/dev/null; then
        grep -q '^0|PROTÉGÉ' "$STATUS_DIR/${d##*/}" 2>/dev/null && continue
        unset "VU[$d]" "PID[$d]"
      fi
    done
  fi
  sleep 3
done
