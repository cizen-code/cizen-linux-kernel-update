#!/usr/bin/env bash
# ============================================================
# kernel-update-manager.sh — Gestor de kernels instalados Cizen.
#
# Orquesta los distintos binarios de la suite (kernel-update.sh,
# cizen-uki-sync, kernel-update-rollback.sh) para gestionar MÁS DE UN
# kernel instalado a la vez: listar, resumir, seleccionar de arranque,
# respaldar y retirar releases concretos.
#
# Uso:
#   kernel-update-manager.sh list | ls
#   kernel-update-manager.sh info [release]
#   kernel-update-manager.sh flip <release>     # arrancar con ese kernel
#   kernel-update-manager.sh backup [release]   # respaldar módulos + UKI
#   kernel-update-manager.sh remove  <release>  # retirar un release instalado
#   kernel-update-manager.sh guide              # consejos (sched-ext, UKI)
#   kernel-update-manager.sh help
#
# En v27.30.0 se integra también como opción del menú interactivo.
# ============================================================
set -uo pipefail

SUITE="/usr/local/bin/kernel-update"
UKI_SUFFIX="cizen-v3"   # coincide con CIZEN_UKI_SUFFIX de cizen-uki-sync
BACKUP_DIR="/var/backups/cizen-kernels"
ESP="/boot/EFI"

r=""
g=""
y=""
n=""
[ -t 1 ] && { r=$'\033[0;31m'; g=$'\033[0;32m'; y=$'\033[1;33m'; n=$'\033[0m'; }

usage() {
  sed -n 's/^#   \(kernel-update-manager.sh\)/\1/p; s/^#   \(kernel-update.sh\|cizen-uki-sync\|kernel-update-rollback.sh\)/  \1/p' "$0"
  echo
}

fatal() { printf '  %b%s%b\n' "$r" "$*" "$n" >&2; exit 1; }
info()  { printf '  %b%s%b\n' "$y" "$*" "$n"; }
ok()    { printf '  %b%s%b\n' "$g" "$*" "$n"; }

# Lista de releases instalados en /usr/lib/modules (orden semántico nuevo->viejo).
installed_releases() {
  local d rel
  for d in /usr/lib/modules/*; do
    [ -d "$d" ] || continue
    rel="${d#/usr/lib/modules/}"
    printf '%s\n' "$rel"
  done | sort -Vr 2>/dev/null
}

# Etiqueta y pkgbase de un release.
release_label() { # $1 = release
  local pb
  pb="$(cat "/usr/lib/modules/$1/pkgbase" 2>/dev/null || echo "-")"
  printf '%s\n' "$pb"
}

# UKI(s) activo(s) para el release Cizen (por sufijo en /usr/lib/modules/*suffix/vmlinuz).
cizen_release() {
  local d rel
  for d in /usr/lib/modules/*"$UKI_SUFFIX"; do
    [ -d "$d" ] || continue
    rel="${d#/usr/lib/modules/}"
    if [ -f "$d/vmlinuz" ]; then printf '%s\n' "$rel"; fi
  done
}

release_by_arg() { # $1 = release pedido
  local d rel want="$1"
  for d in /usr/lib/modules/*; do
    [ -d "$d" ] || continue
    rel="${d#/usr/lib/modules/}"
    if [ "$rel" = "$want" ] || [ "${rel%%-cizen*}" = "$want" ] || \
       { [[ "$want" =~ ^[0-9]+(\.[0-9]+)*$ ]] && [ "${rel%%-*}" = "$want" ]; }; then
      printf '%s\n' "$rel"
      return 0
    fi
  done
  return 1
}

cmd_list() {
  local RUNNING="$(uname -r)"
  local rel pb tag
  rule="$(printf '%*s' 46 '' | tr ' ' '-')"
  printf '  %s\n' "$rule"
  printf '  %-34s %s\n' "Release instalado" "pkgbase"
  printf '  %s\n' "$rule"
  for rel in $(installed_releases); do
    pb="$(release_label "$rel")"
    tag=""
    [ "$rel" = "$RUNNING" ] && tag="  ← en ejecución"
    case "$pb" in
      *cizen*) printf '  %b%-34s%b %s%b\n' "$g" "$rel" "$n" "$pb" "$tag" ;;
      *)       printf '  %-34s %s%b\n' "$rel" "$pb" "$tag" ;;
    esac
  done
  printf '  %s\n' "$rule"
  info "Releases Cizen candidates a gestionar:"
  for rel in $(cizen_release); do printf '    - %s\n' "$rel"; done
}

cmd_info() {
  local rel="${1:-$(uname -r)}"
  [ -d "/usr/lib/modules/$rel" ] || fatal "No existe /usr/lib/modules/$rel"
  local RUNNING="$rel = $(uname -r)"
  [ "$rel" = "$(uname -r)" ] && RUNNING="sí"
  printf '  Release     : %s\n' "$rel"
  printf '  En ejecución: %s\n' "$RUNNING"
  printf '  pkgbase     : %s\n' "$(release_label "$rel")"
  printf '  vmlinuz     : %s\n' "$([ -f "/usr/lib/modules/$rel/vmlinuz" ] && echo sí || echo no)"
  printf '  Módulos     : %s\n' "$(find "/usr/lib/modules/$rel/kernel" -type f 2>/dev/null | wc -l) archivos"
  if [ -f "/usr/lib/modules/$rel/pkgbase" ] && grep -q "cizen" "/usr/lib/modules/$rel/pkgbase"; then
    printf '  UKI en ESP  :\n'
    find "$ESP" -type f -name '*.efi' 2>/dev/null | while read -r f; do
      printf '    - %s\n' "${f#$ESP/}"
    done
  fi
}

cmd_flip() {
  [ $# -gt 0 ] || fatal "flip requiere un release (kernel-update-manager.sh flip 7.2.6-cizen-v3)"
  local rel entry
  rel="$(release_by_arg "${1%*.efi}")" || fatal "Release '$1' no está instalado."
  entry="$(basename "$(find "$ESP" -type f -name '*.efi' 2>/dev/null | head -n1)" .efi)"
  [ -n "$entry" ] || fatal "No se encontró ninguna UKI en $ESP."
  info "Fijando arranque en modo oneshot a '$entry' (release $rel)..."
  sudo bootctl set-oneshot "$entry" || fatal "bootctl set-oneshot falló."
  ok "Al reiniciar se arrancará $rel. (bootctl unset-oneshot para cancelar.)"
}

cmd_backup() {
  local rel="${1:-$(uname -r)}"
  [ -d "/usr/lib/modules/$rel" ] || fatal "No existe /usr/lib/modules/$rel"
  local dst="$BACKUP_DIR/$rel-$(date +%Y%m%d-%H%M%S)"
  sudo mkdir -p "$dst"
  sudo rsync -a --delete "/usr/lib/modules/$rel/" "$dst/modules/" 2>/dev/null \
    || sudo cp -a "/usr/lib/modules/$rel" "$dst/modules" || fatal "No se pudo respaldar los módulos."
  local uki
  uki="$(find "$ESP" -type f -name '*.efi' 2>/dev/null | head -n1)"
  [ -n "$uki" ] && sudo cp -f "$uki" "$dst/$(basename "$uki")" 2>/dev/null
  ok "Kernel $rel respaldado en $dst"
}

cmd_remove() {
  [ $# -gt 0 ] || fatal "remove requiere un release (kernel-update-manager.sh remove 7.2.6-cizen-v3)"
  local rel
  rel="$(release_by_arg "$1")" || fatal "Release '$1' no está instalado."
  [ "$rel" = "$(uname -r)" ] && fatal "No se puede retirar el kernel EN EJECUCIÓN ($rel)."
  # Deja el UKI del resto de releases intacto: solo se elimina el árbol de
  # módulos y su /boot/vmlinuz si existe.
  info "Retirando release $rel..."
  sudo rm -rf -- "/usr/lib/modules/$rel" || fatal "rm falló."
  rm -f -- "/boot/vmlinuz-$rel" 2>/dev/null || true
  ok "Release $rel retirado. Recuerda regenerar el UKI si era el único (suite kernel-update)."
}

cmd_scx_guide() {
  printf '  sched-ext (SCX): schedulers en usuariospace (CONFIG_SCHED_CLASS_EXT).\n'
  printf '  El motor puede habilitarlo sin parches (símbolo mainline desde 6.6).\n'
  printf '  Para usarlo tras compilar: pacman -S scx-scheds; sudo scx_rusty.\n'
  printf '  /usr/lib/modules/$(uname -r): %s ext? %s\n' \
    '' "$([ -d "/sys/kernel/scx_scheduler" ] && echo 'sí (activo ahora)' || echo 'verifica tras arrancar')"
}

cmd="${1:-help}"
case "$cmd" in
  list|ls)                    cmd_list ;;
  info)                       cmd_info "${2:-$(uname -r)}" ;;
  flip)                       cmd_flip "${2:-}" ;;
  backup)                     cmd_backup "${2:-}" ;;
  remove|rm|uninstall|del)    cmd_remove "${2:-}" ;;
  scx)                        cmd_scx_guide ;;
  guide|help|--help|-h)       usage ;;
  *) fatal "Acción desconocida: $cmd (usa 'help' para la sintaxis)." ;;
esac