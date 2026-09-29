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
# ESP: la misma detección que cizen-uki-sync (findmnt -o FSTYPE), NO un
# '[ -d $r/EFI/Linux ]'. En este host /boot es la ESP y va 0700 root: la prueba
# de directorio exige +x sobre el punto de montaje, así que sin sudo daba
#_permission denied_ y caía al fallback. Con el layout estándar de Arch (ESP en
# /efi, /boot un directorio normal) ese fallback es /boot/EFI, que no existe:
# cizen_ukis() salía vacía y flip moría y backup NO respaldaba la UKI.
ESP=""
# Privilegios SOLO si hacen falta, y en este orden: primero sin sudo (por si el
# fichero ya es legible), luego `sudo -n` (credenciales cacheadas o allowlist,
# sin preguntar) y por último `sudo`, que sí puede pedir contraseña.
#
# Antes el gestor usaba `sudo -n test -r` / `sudo -n test -d`. Eso no puede
# funcionar NUNCA: `test` es un BUILTIN de bash, sudo no ejecuta builtins, así
# que salía con código 127 y con `-n` no hay a quién preguntar. Como esa era la
# comprobación de legibilidad de _uki_release(), la función devolvía 1 sin
# haber mirado la UKI nunca, y el gestor no encontraba ninguna release: 'flip'
# moría y 'backup' no respaldaba nada. Y aunque esa línea se hubiera resuelto,
# el `objdump` de las dos líneas siguientes corre sin privilegios y el ESP es
# vfat con dmask=0077, así que tampoco podía leer la cabecera.
_priv() {
  "$@" 2>/dev/null && return 0
  sudo -n "$@" 2>/dev/null && return 0
  sudo "$@"
}
_find_esp_root() {
  local r fstype
  for r in /boot /efi /boot/efi; do
    [ -d "$r" ] || continue
    fstype="$(findmnt -n -M "$r" -o FSTYPE 2>/dev/null || true)"
    if [[ "$fstype" =~ ^(vfat|msdos|fuseblk)$ ]]; then
      printf '%s\n' "$r"
      return 0
    fi
  done
  # Sin findmnt útil: se prueba con _priv, que sí puede atravesar el 0700.
  # /usr/bin/test es el binario de coreutils (el builtin no lo puede ejecutar
  # sudo), y sudo -n funciona porque va en el allowlist.
  for r in /boot /efi /boot/efi; do
    [ -n "$r" ] || continue
    if _priv /usr/bin/test -d "$r/EFI"; then
      printf '%s\n' "$r"
      return 0
    fi
  done
  return 1
}
ESP="$( _find_esp_root)" || ESP=""
if [ -z "$ESP" ]; then
  ESP="/boot/EFI"   # mejor un valor conocido que una lista vacía que rompe find
fi
export ESP

# UKI(s) Cizen del ESP (patrón por sufijo; excluye *.efi.bak), más reciente
# primero. Solo se pueden arrancar los *.efi a secas, que es lo que filtra esto.
# find va con sudo por lo mismo: el ESP suele ser root 0700.
cizen_ukis() {
  _priv /usr/bin/find "$ESP" -type f -name "*${UKI_SUFFIX}*" -name '*.efi' -printf '%T@ %p\n' \
    | sort -k1,1nr | awk '{ $1=""; sub(/^ /,""); print }'
}

# Release exacto que lleva dentro una UKI, leído de su sección .uname.
# Imprescindible porque el NOMBRE del UKI es por pkgbase
# (arch-linux-cizen-v3.efi), no por release: con dos releases Cizen instalados
# hay una sola UKI y su nombre no dice cuál es. Sin esto, 'flip <release
# antiguo>' fixaba el arranque sobre la UKI (la única) y anunciaba un release
# que no se iba a arrancar. Vacío = no se pudo leer (sin objdump, sin sudo, o
# UKI sin .uname) y hay que decirlo en vez de suponer.
_uki_release() {
  local f="$1" hdr sz off
  command -v objdump >/dev/null 2>&1 || return 1
  [ -r "$f" ] || _priv /usr/bin/test -r "$f" || return 1
  # objdump TIENE que ir con privilegios cuando el ESP no es legible: es la
  # cabecera de la UKI, no un fichero de texto. Se lee una sola vez y de ahí se
  # sacan tamaño (columna 3) y offset en fichero (columna 6: la VMA de la
  # columna 4 NO sirve, son direcciones de memoria, no del fichero).
  hdr="$(_priv /usr/bin/objdump -h -- "$f")" || return 1
  sz="$(awk '$2 == ".uname" { print $3; exit }' <<<"$hdr")"
  off="$(awk '$2 == ".uname" { print $6; exit }' <<<"$hdr")"
  [ -n "$sz" ] && [ -n "$off" ] || return 1
  _priv /usr/bin/dd if="$f" bs=1 skip=$((16#$off)) count=$((16#$sz)) 2>/dev/null
}

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

release_by_arg() { # $1 = release pedido → release instalado, o error
  local d rel want="$1" c m
  local exact="" cizen="" other="" ek="" ck="" ok_=""
  # admitting un release: exacto, 'X.Y.Z-cizen*', o prefijo de versión si lo
  # pedido es una versión desnuda ('6.18.54' → '6.18.54-1.1-lts').
  #
  # Entre los que admiten, el ORDEN DE PREFERENCIA es: exacto > Cizen > otro.
  # Antes el bucle se daba por satisfecho con la PRIMERA coincidencia del glob
  # /usr/lib/modules/*, que viene ordenado: con '7.2.8' pedido, ganaba
  # '7.2.8-arch1-1' (a < c) y 'remove 7.2.8' acababa borrando el árbol de
  # módulos del kernel de la distribución en vez del Cizen.
  for d in /usr/lib/modules/*; do
    [ -d "$d" ] || continue
    rel="${d#/usr/lib/modules/}"
    if   [ "$rel" = "$want" ];            then m=exact
    elif [ "${rel%%-cizen*}" = "$want" ]; then m=cizen
    elif [[ "$want" =~ ^[0-9]+(\.[0-9]+)*$ ]] && [ "${rel%%-*}" = "$want" ]; then m=other
    else continue
    fi
    c="$(release_label "$rel")"
    # Dentro de una categoría gana el release más largo (más específico:
    # '7.2.8-cizen-v3' gana a un '7.2.8-arch1-1' de la misma categoría).
    case "$m" in
      exact) [ -z "$exact" ] || [ "${#rel}" -gt "${#ek}" ] && { exact="$rel"; ek="$rel"; } ;;
      cizen) [ -z "$cizen" ] || [ "${#rel}" -gt "${#ck}" ] && { cizen="$rel"; ck="$rel"; } ;;
      *)     [ -z "$other" ] || [ "${#rel}" -gt "${#ok_}" ] && { other="$rel"; ok_="$rel"; } ;;
    esac
  done
  if   [ -n "$exact" ]; then printf '%s\n' "$exact"; return 0
  elif [ -n "$cizen" ]; then printf '%s\n' "$cizen"; return 0
  elif [ -n "$other" ];  then printf '%s\n' "$other";  return 0
  fi
  return 1
}

cmd_list() {
  local RUNNING="$(uname -r)"
  local rel pb tag
  local rule; rule="$(printf '%*s' 46 '' | tr ' ' '-')"
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
  local RUNNING="no"
  [ "$rel" = "$(uname -r)" ] && RUNNING="sí"
  printf '  Release     : %s\n' "$rel"
  printf '  En ejecución: %s\n' "$RUNNING"
  printf '  pkgbase     : %s\n' "$(release_label "$rel")"
  printf '  vmlinuz     : %s\n' "$([ -f "/usr/lib/modules/$rel/vmlinuz" ] && echo sí || echo no)"
  printf '  Módulos     : %s\n' "$(find "/usr/lib/modules/$rel/kernel" -type f 2>/dev/null | wc -l) archivos"
  if [ -f "/usr/lib/modules/$rel/pkgbase" ] && grep -q "cizen" "/usr/lib/modules/$rel/pkgbase"; then
    printf '  UKI en ESP  :\n'
    # Solo las UKIs de Cizen: un 'find -name *.efi' a pelo también saca
    # EFI/systemd/systemd-bootx64.efi y el fallback, que son el BOOTLOADER, no
    # UKIs, y presentarlos aquí como "UKI en ESP" miente. Se reaprovecha
    # cizen_ukis(), que ya filtra por sufijo y lleva _priv (el ESP es vfat 0700,
    # así que sin sudo no se ve ninguna). De cada una se lee su .uname, que es
    # lo que dice qué kernel arranca de verdad.
    local _any=0 _u _r
    while read -r _u; do
      [ -n "$_u" ] || continue
      _r="$(_uki_release "$_u")"
      [ -n "$_r" ] || _r="(ilegible)"
      _any=1
      printf '    - %s  [.uname=%s]\n' "${_u#$ESP/}" "$_r"
    done < <(cizen_ukis)
    [ "$_any" = 1 ] || printf '    (ninguna)\n'
  fi
}

cmd_flip() {
  [ $# -gt 0 ] || fatal "flip requiere un release (kernel-update-manager.sh flip 7.2.6-cizen-v3)"
  local rel pb uki entry want urel found="" unknown=""
  rel="$(release_by_arg "${1%*.efi}")" || fatal "Release '$1' no está instalado."

  # La UKI NO se llama por release: es arch-<pkgbase>[+N].efi, así que con dos
  # releases Cizen instalados hay una sola UKI y su nombre no la distingue. Se
  # busca la que LITERALMENTE lleva dentro el release pedido (sección .uname) en
  # vez de dar por buena 'la Cizen más reciente': esa es la que se va a
  # arrancar, y puede no ser la que el usuario pidió.
  while IFS= read -r uki; do
    [ -n "$uki" ] || continue
    urel="$(_uki_release "$uki" 2>/dev/null | tr -d '\000\n\r')"
    if [ "$urel" = "$rel" ]; then found="$uki"; break; fi
    [ -n "$urel" ] || unknown="$uki"
  done < <(cizen_ukis)

  if [ -z "$found" ]; then
    if [ -n "$unknown" ]; then
      fatal "No se pudo leer la versión interna de la UKI (sin objdump o sin sudo); no se toca el arranque. Revísalo a mano: objdump -h '$unknown'"
    fi
    pb="$(release_label "$rel")"
    fatal "No hay ninguna UKI en el ESP que contenga el kernel $rel.
  La suite mantiene UNA UKI por pkgbase (${pb:-cizen}), no una por release, y
  la que hay ahora contiene otra versión. Para volver a este kernel usa:
    sudo kernel-update-rollback.sh --list   (archive del kernel anterior)
    sudo kernel-update-rollback.sh"
  fi

  entry="${found%.efi}"
  info "Fijando arranque en modo oneshot a '$entry' (contiene $rel)..."
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
  # La UKI tiene que ser LA de este release, no 'la más reciente': respaldar los
  # módulos de 7.2.7 con la UKI de 7.2.8 produce un directorio que restaura un
  # kernel que no es el que dice respaldar. Y si no hay UKI de este release se
  # AVISA: antes el '[ -n "$uki" ] &&' se comía el fallo en silencio y el 'ok'
  # siguiente declaraba el respaldo completo sin el único fichero del que
  # depende el arranque.
  local uki urel want found="" unknown=""
  while IFS= read -r uki; do
    [ -n "$uki" ] || continue
    urel="$(_uki_release "$uki" 2>/dev/null | tr -d '\000\n\r')"
    if [ "$urel" = "$rel" ]; then found="$uki"; break; fi
    [ -n "$urel" ] || unknown="$uki"
  done < <(cizen_ukis)

  if [ -n "$found" ]; then
    sudo cp -f "$found" "$dst/$(basename "$found")" || fatal "No se pudo copiar la UKI a $dst."
    ok "Kernel $rel respaldado en $dst (módulos + UKI)."
  elif [ -n "$unknown" ]; then
    ok "Kernel $rel respaldado en $dst (solo módulos)."
    warn "No se pudo leer la versión interna de ninguna UKI; el UKI NO se ha respaldado."
    warn "  Backupeala a mano:  sudo cp '$unknown' $dst/"
  else
    ok "Kernel $rel respaldado en $dst (solo módulos)."
    warn "No hay UKI en el ESP que contenga $rel; este respaldo NO sirve para arrancar."
  fi
}

cmd_remove() {
  [ $# -gt 0 ] || fatal "remove requiere un release (kernel-update-manager.sh remove 7.2.6-cizen-v3)"
  local rel
  rel="$(release_by_arg "$1")" || fatal "Release '$1' no está instalado."
  [ "$rel" = "$(uname -r)" ] && fatal "No se puede retirar el kernel EN EJECUCIÓN ($rel)."
  # Retirar el kernel de la distribución deja el sistema sin un kernel de
  # reserva y rompe el bootloader si es el único LoaderEntrySigned. Sólo se
  # acepta si el pkgbase lo dice claramente Cizen.
  case "$(release_label "$rel")" in
    *cizen*) ;;
    *) fatal "El release $rel es de la distribución (pkgbase '$(release_label "$rel")'), no de la suite Cizen.
  Retirarlo deja el sistema sin kernel de reserva. Si es lo que quieres, borra
  antes su entrada de /boot/loader/entries y su UKI del ESP." ;;
  esac
  # Deja el UKI del resto de releases intacto: solo se elimina el árbol de
  # módulos y su /boot/vmlinuz si existe.
  info "Retirando release $rel..."
  sudo rm -rf -- "/usr/lib/modules/$rel" || fatal "rm falló."
  # Con sudo: sin él el rm de /boot (0700 root) fallaba siempre y el '|| true'
  # lo silenciaba, dejando /boot/vmlinuz-<rel> huérfano mientras el 'ok' de
  # abajo declaraba el release retirado.
  if [ -e "/boot/vmlinuz-$rel" ]; then
    sudo rm -f -- "/boot/vmlinuz-$rel" || fatal "No se pudo borrar /boot/vmlinuz-$rel."
  fi
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