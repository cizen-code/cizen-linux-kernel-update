#!/usr/bin/env bash
# ============================================================
# pgo-collect.sh — Recoge un perfil AutoFDO del kernel Cizen en
# ejecución y lo convierte para usarlo como CIZEN_PGO_PROFILE.
#
# Pipeline (docs.kernel.org/dev-tools/autofdo.html):
#   1. captura perf:      perf record -F 999 -a -g (radiografía de TODO el
#                         sistema durante N segundos de tu carga real).
#   2. conversión:         llvm-profgen --binary vmlinux --perfdata perf.data
#      → fichero .afdo legible por clang (-fprofile-sample-use), no por gcc.
#   3. rebuild:            CIZEN_PGO_PROFILE=<fichero> kernel-update.sh <build>
#      El motor (v27.31.45) fuerza CONFIG_AUTOFDO_CLANG y entrega el perfil
#      al make como CLANG_AUTOFDO_PROFILE. Requiere la familia clang (el
#      default actual es Thin-LTO → clang ya).
#
# Notas:
#   - Capturar con la carga REPRESENTATIVA (Arranca apps, compila, navega,
#     juega…): el perfil solo optimiza lo que ve el muestreador. 10-15 min es
#     una buena medida.
#   - El fichero sale en $HOME/kernel-pgo/<kver>.afdo. Puede reutilizarse en
#     rebuilds (consérvalo junto a los perf.data).
#
# Uso:
#   sudo kernel-update/pgo-collect.sh [--duration N] [--vmlinux RUTA] [--out FICH]
#
#   --duration N   segundos de muestreo (default 600)
#   --vmlinux RUTA vmlinux del kernel Cizen que quieres perfil-optimizar.
#                  Si se omite se busca, en orden: /lib/modules/<uname -r>/build/vmlinux,
#                  $CIZEN_VMLINUX_STORE/<uname -r>/vmlinux y .../vmlinux.unstripped.
#                  El kernel-update.sh actual guarda una copia persistente del vmlinux
#                  de cada build en ese store (default /var/cache/cizen-kernel/vmlinux),
#                  porque el árbol de compilación vive en un tmpfs que se desmonta.
#   --out FICH     fichero .afdo de salida (default $HOME/kernel-pgo/<kver>.afdo)
#
# Variables de entorno:
#   CIZEN_PGO_DURATION  igual que --duration
#   CIZEN_PGO_VMLINUX   igual que --vmlinux
#   CIZEN_PGO_OUT       igual que --out
#   CIZEN_VMLINUX_STORE store de vmlinux persistentes que deja kernel-update.sh
#                       (default /var/cache/cizen-kernel/vmlinux)

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

# ── Colores ─────────────────────────────────────────────────
if [ -t 1 ]; then
  R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'; C=$'\033[0;36m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; C=""; N=""
fi

log(){  printf '%s[%s]%s %s\n' "$B" "$(date +%H:%M:%S)" "$N" "$*"; }
ok(){   printf '%s  ✓%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s  ⚠%s %s\n' "$Y" "$N" "$*"; }
err(){  printf '%s  ✗%s %s\n' "$R" "$N" "$*" >&2; }
info(){ printf '%s  •%s %s\n' "$C" "$N" "$*"; }
fatal(){ err "$*"; exit 1; }

# Privilegios: `perf record -a` necesita root (o perf_event_paranoid bajo).
# Si el usuario lanza el script sin sudo, se re-ejecuta con sudo.
SUDO=()
if [ "$(id -u)" != 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
    log "Elevando a root: ${SUDO[*]} $0 $*"
    exec "${SUDO[@]}" "$0" "$@"
  else
    fatal "Se necesita root: ejecuta  sudo $0 $*  (perf record -a exige privilegios)."
  fi
fi

DURATION="${CIZEN_PGO_DURATION:-600}"
VMLINUX="${CIZEN_PGO_VMLINUX:-}"
OUT="${CIZEN_PGO_OUT:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --duration) DURATION="${2:-}"; [ -n "$DURATION" ] || fatal "--duration requiere segundos"; shift 2 ;;
    --vmlinux)  VMLINUX="${2:-}"; [ -n "$VMLINUX" ] || fatal "--vmlinux requiere una ruta"; shift 2 ;;
    --out)      OUT="${2:-}"; [ -n "$OUT" ] || fatal "--out requiere una ruta"; shift 2 ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0 ;;
    *) fatal "Argumento desconocido: $1 (usa --help)" ;;
  esac
done

command -v perf >/dev/null 2>&1 || fatal "No está 'perf' (sudo pacman -S perf) — herramienta de muestreo."

KVER="$(uname -r)"

# Búsqueda del vmlinux (ver pgo-collect: el kernel se compila en un tmpfs que se
# desmonta al terminar el pipeline, así que el vmlinux SOLO existe como copia
# persistente en $VMLINUX_STORE; el enlace /lib/modules/<kver>/build no se crea).
VMLINUX_STORE="${CIZEN_VMLINUX_STORE:-/var/cache/cizen-kernel/vmlinux}"
if [ -z "$VMLINUX" ]; then
  for cand in "/lib/modules/$KVER/build/vmlinux" \
              "$VMLINUX_STORE/$KVER/vmlinux" \
              "$VMLINUX_STORE/$KVER/vmlinux.unstripped"; do
    if [ -f "$cand" ]; then VMLINUX="$cand"; break; fi
  done
fi
if [ -z "$VMLINUX" ]; then
  fatal "No encuentro el vmlinux de '$KVER'.
  El kernel se compila en un tmpfs que se desmonta tras el build, así que no queda
  vmlinux en disco salvo en la copia persistente que crea kernel-update.sh.
  Qué hacer:
    - ¿Ya hiciste un build con este motor? Reconstruye una vez (el archivado ocurre
      al final del pipeline) y vuelve a intentar:
          sudo /usr/local/bin/kernel-update/kernel-update.sh build
    - ¿El build fue anterior a este cambio? Pasa la ruta a mano si aún conservas el
      árbol de compilación (con CIZEN_KEEP_TMPFS=1 no se desmonta):
          sudo $0 --duration $DURATION --vmlinux /ruta/al/vmlinux
    - La búsqueda por defecto es: /lib/modules/$KVER/build/vmlinux y
      $VMLINUX_STORE/$KVER/vmlinux (configurable con CIZEN_VMLINUX_STORE)."
fi
[ -f "$VMLINUX" ] || fatal "vmlinux no existe: $VMLINUX"

OUT="${OUT:-$HOME/kernel-pgo/$KVER.afdo}"
mkdir -p "$(dirname -- "$OUT")"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

log "Perfil del kernel en ejecución: $KVER (vmlinux: $VMLINUX)"
info "Muestreo de $DURATION s a 999 Hz (usa este tiempo para tu carga real, no lo cortes)."
if ! perf record -o "$TMPD/perf.data" -F 999 -a -g -- sleep "$DURATION"; then
  warn "perf record terminó con error; comprueba kernel.perf_event_paranoid y que el script corre como root."
  exit 1
fi
ok "Muestreo completado ($DURATION s)."

if command -v llvm-profgen >/dev/null 2>&1; then
  CONVERT=(llvm-profgen --binary "$VMLINUX" --perfdata "$TMPD/perf.data" --output "$OUT")
elif command -v create_llvm_prof >/dev/null 2>&1; then
  # Variante antigua (tools/autofdo de la era pre-llvm-profgen).
  CONVERT=(create_llvm_prof --binary="$VMLINUX" --profile="$TMPD/perf.data" --out="$OUT")
  warn "Usando create_llvm_prof (legacy): prefiere llvm-profgen cuando esté disponible."
else
  fatal "No está 'llvm-profgen' (sudo pacman -S llvm-profgen) ni create_llvm_prof; la conversión del perfil es obligatoria."
fi
"${CONVERT[@]}"
ok "Perfil AutoFDO: $OUT"

info "Rebuild con PGO (motor v27.31.45+): CIZEN_PGO_PROFILE=$OUT kernel-update.sh build"
info "Para comparar sin PGO: kernel-update.sh build --no-lto  (y sin CIZEN_PGO_PROFILE)."