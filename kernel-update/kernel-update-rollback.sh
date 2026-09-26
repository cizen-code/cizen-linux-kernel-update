#!/usr/bin/env bash
# ============================================================
# kernel-update-rollback.sh — vuelve al kernel Cizen ANTERIOR
#
# kernel-update.sh guarda dos cosas en $ROLLBACK_DIR antes de instalar un kernel
# nuevo, y esta es la diferencia entre las dos:
#
#   *.pkg.tar.zst   el PAQUETE del kernel anterior. Es el rollback de verdad:
#                   `pacman -U` lo reinstala con sus módulos, su vmlinuz y sus
#                   hooks, y la base de datos de pacman vuelve a decir la verdad.
#   *.tar.xz        los FICHEROS del kernel que se estaba ejecutando (módulos +
#                   vmlinuz + UKI). Solo sirve si no hay paquete, y tiene un
#                   precio: pacman sigue diciendo que está instalado el kernel
#                   nuevo, así que la siguiente actualización ya no sabe cuál era
#                   el anterior. Por eso es el plan B, no el plan A.
#
# Importante: bore y bmq se llaman igual (`7.2.7-cizen-v3`, solo cambia el
# pkgrel), así que el rollback NO se elige por la release sino por el manifiesto
# $ROLLBACK_DIR/rollback.info (pkgbase + pkgver + scheduler). Un rollback que
# reinstala "el kernel anterior" tiene que ser el de verdad, sea el scheduler
# que sea.
#
# Uso:
#   krollback --list             # qué kernel anterior hay (con su scheduler)
#   krollback -y                 # restaurarlo sin preguntar
#   krollback                    # restaurarlo con confirmación (TTY)
#
# Variables de entorno (override):
#   CIZEN_ROLLBACK_DIR  directorio de rollback (default /var/lib/kernel-update/rollback)
# ============================================================

set -uo pipefail
export LC_ALL=C

ROLLBACK_DIR="${CIZEN_ROLLBACK_DIR:-/var/lib/kernel-update/rollback}"
MANIFEST="$ROLLBACK_DIR/rollback.info"
# No hay comando `krollback` en el PATH: los mensajes usan la ruta real.
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
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

mf() {  # mf clave -> valor del manifiesto (vacío si no está)
  local key="$1" line
  [ -f "$MANIFEST" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done < <(sudo cat -- "$MANIFEST" 2>/dev/null || cat -- "$MANIFEST" 2>/dev/null)
  return 0
}

confirm() {  # confirm "pregunta"
  if [ "$ASSUME_YES" = true ]; then return 0; fi
  if ! [ -t 0 ] && ! [ -t 1 ]; then
    fatal "No hay terminal interactiva y no se pasó -y/--yes; aborto."
  fi
  local answer
  read -r -p "  $1 [S/n] " answer < /dev/tty || answer="n"
  case "${answer:-s}" in
    s|S|si|SI|sí|Sí|y|Y|yes|YES) : ;;
    *) err "Rollback cancelado."; exit 1 ;;
  esac
}

list_archives() {
  sudo -v 2>/dev/null || sudo -n true 2>/dev/null || { sudo -v || fatal "Se necesita sudo para leer $ROLLBACK_DIR."; }

  local pkgbase pkgver release sched pkgfile archive archive_rel ts pkgpath
  pkgbase="$(mf pkgbase)"; pkgver="$(mf pkgver)"; release="$(mf release)"
  sched="$(mf sched)"; pkgfile="$(mf pkgfile)"; archive="$(mf archive)"
  archive_rel="$(mf archive_rel)"; ts="$(mf ts)"
  [ -n "$pkgfile" ] && pkgpath="$ROLLBACK_DIR/$pkgfile"

  echo
  if [ -z "$pkgfile" ] && [ -z "$archive" ]; then
    warn "No hay nada que restaurar en $ROLLBACK_DIR."
    echo
    info "Se guarda automáticamente en cada instalación de kernel-update.sh"
    info "(paquete del kernel anterior + archive de ficheros)."
    return 1
  fi

  echo "${C}Kernel anterior disponible para rollback:${N}"
  if [ -n "$pkgver" ]; then
    printf '  %spaquete%s  %s-%s' "$G" "$N" "${pkgbase:-linux-cizen-v3}" "$pkgver"
    [ -n "$sched" ] && printf '  (scheduler: %s)' "$sched"
    [ -n "$release" ] && printf '  release %s' "$release"
    echo
    if [ -n "$pkgpath" ] && sudo test -s "$pkgpath" 2>/dev/null; then
      printf '  %sfichero%s  %s (%s)\n' "$G" "$N" "$pkgpath" "$(sudo du -h -- "$pkgpath" 2>/dev/null | cut -f1)"
    else
      printf '  %sfichero%s  %sNO ESTÁ (%s)\n' "$Y" "$N" "$N" "${pkgpath:-desconocido}"
    fi
    [ -n "$ts" ] && printf '  %sguardado%s  %s\n' "$G" "$N" "$ts"
  fi
  if [ -n "$archive" ] && sudo test -s "$ROLLBACK_DIR/$archive" 2>/dev/null; then
    echo
    printf '  %splan B%s    %s (ficheros%s)\n' "$Y" "$N" "$archive" \
      "$([ -n "$archive_rel" ] && printf ' de %s' "$archive_rel")"
    info "Solo se usa si no hay paquete. Reinstala ficheros, pero pacman sigue"
    info "diciendo que está el kernel nuevo: úsalo solo como último recurso."
  fi
  echo
  if [ -n "$pkgver" ] && [ -n "$pkgpath" ] && sudo test -s "$pkgpath" 2>/dev/null; then
    ok "Listo. Para volver atrás:  sudo $SELF"
  else
    warn "No hay paquete utilizable: solo queda el archive de ficheros."
  fi
  return 0
}

restore_from_archive() {  # plan B: extraer ficheros
  local archive archive_rel
  archive="$(mf archive)"
  archive_rel="$(mf archive_rel)"
  [ -n "$archive" ] || fatal "No hay archive de rollback en $ROLLBACK_DIR."
  sudo test -s "$ROLLBACK_DIR/$archive" 2>/dev/null || fatal "El archive $archive no está o está vacío."

  echo
  echo "${C}Se restaurarán los ficheros de${N} ${archive_rel:-el kernel anterior}"
  echo "${C}Archive:${N} $ROLLBACK_DIR/$archive"
  echo
  warn "Esto NO es un downgrade de paquete: pacman seguirá diciendo que el"
  warn "kernel instalado es el nuevo, y la siguiente actualización volverá a"
  warn "perder el anterior. Es el plan B de krollback, no el normal."
  echo
  confirm "¿Extraer los ficheros y regenerar el arranque?"

  ok "Extrayendo módulos + vmlinuz + UKI ..."
  sudo tar --xz -xf "$ROLLBACK_DIR/$archive" -C / || \
    fatal "La extracción falló. NO reinicies todavía; diagnostica el archive."
  ok "Ficheros restaurados."
  info "Para que la UKI apunte al kernel restaurado:  sudo cizen-uki-sync"
  info "y luego  sudo reboot."
}

restore_package() {  # plan A: reinstalar el paquete
  local pkgbase pkgver release sched pkgfile ts pkgpath
  pkgbase="$(mf pkgbase)"; pkgver="$(mf pkgver)"; release="$(mf release)"
  sched="$(mf sched)"; pkgfile="$(mf pkgfile)"; ts="$(mf ts)"
  [ -n "$pkgfile" ] || { restore_from_archive; return $?; }
  pkgpath="$ROLLBACK_DIR/$pkgfile"
  sudo test -s "$pkgpath" 2>/dev/null || {
    warn "El paquete de rollback ($pkgfile) no está en $ROLLBACK_DIR."
    restore_from_archive
    return $?
  }

  local installed
  installed="$(pacman -Q "${pkgbase:-linux-cizen-v3}" 2>/dev/null | awk '{print $2}' | head -n1)"

  echo
  echo "${C}Se reinstalará el kernel anterior:${N} ${pkgbase:-linux-cizen-v3}-$pkgver${sched:+ ($sched)}"
  echo "${C}Paquete:${N} $pkgpath"
  [ -n "$release" ] && echo "${C}Release :${N} $release"
  [ -n "$ts" ] && echo "${C}Guardado:${N} $ts"
  echo
  if [ -n "$installed" ] && [ "$installed" != "$pkgver" ]; then
    info "Ahora mismo está instalado: $pkgbase-$installed"
  fi
  warn "pacman lo reinstala tal cual (módulos + vmlinuz + hooks) y regenera"
  warn "la UKI. El scheduler vuelve al que tenía ese paquete."
  echo
  confirm "¿Reinstalar ${pkgbase:-linux-cizen-v3}-$pkgver y regenerar el UKI?"

  ok "Reinstalando el paquete anterior ..."
  if ! sudo pacman -U "$pkgpath" --noconfirm; then
    err "pacman -U falló. NO reinicies: el sistema puede haber quedado a medias."
    err "Diagnostica con:  sudo pacman -U '$pkgpath'   (sin --noconfirm)"
    exit 1
  fi
  ok "Paquete reinstalado: ${pkgbase:-linux-cizen-v3}-$pkgver${sched:+ [$sched]}"

  # El UKI en el ESP sigue apuntando al kernel que se acaba de sustituir: sin
  # regenerarlo, reiniciar volvería a arrancar el kernel nuevo.
  if command -v cizen-uki-sync >/dev/null 2>&1; then
    ok "Regenerando el UKI para que apunte al kernel restaurado ..."
    if sudo cizen-uki-sync; then
      ok "UKI regenerada."
    else
      warn "cizen-uki-sync falló. El UKI puede seguir apuntando al kernel nuevo."
      warn "Repásalo con:  sudo cizen-uki-sync"
    fi
  else
    warn "cizen-uki-sync no está en PATH: el UKI puede seguir apuntando al"
    warn "kernel nuevo. Regenera la UKI antes de reiniciar."
  fi

  echo
  ok "Rollback preparado: el paquete instalado vuelve a ser $pkgbase-$pkgver"
  info "Para volver al kernel más reciente, compílalo de nuevo con kernel-update.sh."
  info "Comprueba que el verificador lo ve tras el reboot:"
  info "  /usr/local/bin/kernel-update/kernel-update-verify.sh"
  ok "Cuando estés listo:  sudo reboot"
  echo
}

case "$DO_LIST" in
  true) list_archives; exit 0 ;;
esac

sudo -v || fatal "Se necesita sudo para restaurar."
restore_package
exit 0
