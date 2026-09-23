#!/usr/bin/env bash
# ============================================================
# kernel-update-rollback.sh — restaura el kernel Cizen PREVIO
# Guardado por kernel-update.sh antes de cada instalación en
# $ROLLBACK_DIR (/var/lib/kernel-update/rollback por defecto).
#
# El archive contiene los módulos (/usr/lib/modules/<release>),
# /boot/vmlinuz-linux-cizen-v3 y la/las UKI del ESP
# (boot/EFI/Linux/arch-linux-cizen-v3.efi y sus variantes +N de boot counting).
# krollback los restaura y deja la máquina lista para `sudo reboot` con el
# kernel anterior.
#
# Uso:
#   krollback --list             # listar el archive disponible
#   krollback -y                 # restaurar sin confirmar
#   krollback                    # restaurar con confirmación (TTY)
#
# Variables de entorno (override):
#   CIZEN_ROLLBACK_DIR  directorio de archives (default /var/lib/kernel-update/rollback)
#
# NOTA: la base de datos de pacman seguirá reflejando el paquete MÁS RECIENTE
# aunque el kernel que se arranca sea el archivado. Es un rollback a nivel de
# boot (kernel+UKI+initramfs), no un downgrade del paquete.
# ============================================================

set -uo pipefail
export LC_ALL=C

ROLLBACK_DIR="${CIZEN_ROLLBACK_DIR:-/var/lib/kernel-update/rollback}"
DO_LIST=false
DO_RESTORE=false
ASSUME_YES=false

for a in "$@"; do
  case "$a" in
    --list|-l) DO_LIST=true ;;
    --yes|-y|--force|-f) ASSUME_YES=true; DO_RESTORE=true ;;
    *) DO_RESTORE=true ;;
  esac
done
[ "$DO_LIST" = false ] && [ "$DO_RESTORE" = false ] && DO_RESTORE=true

# Colores (solo TTY)
if [ -t 1 ]; then
  G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; C=$'\033[0;36m'; N=$'\033[0m'
else
  G=""; Y=""; C=""; R=""; N=""
fi
ok(){  printf '%s  %s %s\n' "$G" "✓" "$*"; }
warn(){ printf '%s  %s %s\n' "$Y" "⚠" "$*"; }
err(){ printf '%s  %s %s\n' "$R" "✗" "$*" >&2; }
info(){ printf '%s  %s %s\n' "$C" "•" "$*"; }
fatal(){ err "$*"; exit 1; }

list_archives() {
  if ! sudo -n true 2>/dev/null; then
    sudo -v || fatal "Se necesita sudo para leer $ROLLBACK_DIR."
  fi
  if [ ! -d "$ROLLBACK_DIR" ] || [ "$(sudo ls -A -- "$ROLLBACK_DIR" 2>/dev/null | wc -l)" -eq 0 ]; then
    warn "No hay archives de rollback en $ROLLBACK_DIR."
    echo
    info "Se generan automáticamente en cada instalación de kernel-update.sh"
    info "(rollback dual: kernel actual + previo)."
    return 1
  fi
  echo
  echo "${C}Archives de rollback disponibles:${N}"
  sudo ls -la -- "$ROLLBACK_DIR" 2>/dev/null | grep -E '\.tar\.xz$|total|^d' || true
  return 0
}

pick_newest() {
  sudo ls -1 -- "$ROLLBACK_DIR"/*.tar.xz 2>/dev/null | sort -V | tail -n1
}

restore() {
  local archive="" rel
  archive="$(pick_newest)"
  if [ -z "$archive" ]; then
    fatal "No hay archive de rollback que restaurar en $ROLLBACK_DIR."
  fi
  rel="$(basename -- "$archive" .tar.xz)"

  echo
  echo "${C}Se restaurará el kernel:${N} $rel"
  echo "${C}Archivo:${N} $archive"
  echo
  warn "La base de datos de pacman SEGUIRÁ reflejando el paquete más reciente"
  warn "(rollback a nivel de boot, no downgrade de paquete)."
  warn "Comprueba que no haya nada importante en /usr/lib/modules/$rel antes de seguir."
  echo

  if [ "$ASSUME_YES" = false ]; then
    if ! [ -t 0 ] && ! [ -t 1 ]; then
      fatal "No hay terminal interactiva y no se pasó -y/--yes; aborto."
    fi
    local answer
    read -r -p "  ¿Restaurar el kernel $rel y regenerar el arranque? [S/n] " answer < /dev/tty || answer="n"
    case "${answer:-s}" in
      s|S|si|SI|sí|Sí|y|Y|yes|YES) : ;;
      *) err "Restauración cancelada."; exit 1 ;;
    esac
  fi

  ok "Extrayendo módulos + vmlinuz + UKI de $rel ..."
  if ! sudo tar --xz -xf "$archive" -C /; then
    fatal "La extracción falló. NO reinicies todavía; diagnostica el archive."
  fi

  echo
  ok "Kernel $rel restaurado (módulos + vmlinuz + UKI)."
  info "La UKI archivada es la que se estaba arrancando; se mantiene tal cual."
  info "Si cambiaste /etc/kernel/cmdline desde que se archivó, regenera con:"
  info "  sudo cizen-uki-sync"
  echo
  ok "Cuando estés listo:  sudo reboot"
  echo
  info "Para volver al kernel reciente: compílalo de nuevo con kbuild/kupdate."
}

case "$DO_LIST" in
  true) list_archives; exit 0 ;;
esac

sudo -v || fatal "Se necesita sudo para restaurar."
list_archives >/dev/null 2>&1 || true
restore
exit 0