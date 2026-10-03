#!/usr/bin/env bash
# ============================================================
# pgo-load.sh — capturar AutoFDO con una carga de COMPILACIÓN de verdad
#
# Por qué existe esto: el perfil que hay en ~/kernel-pgo/7.2.8-cizen-v3.afdo se
# capturó con 900 s de LBR y 18.918.656 muestras, y aun así no sirve para
# optimizar el kernel. Mirando los símbolos que contiene, la carga fue btrfs
# (580 símbolos), i915/drm (552) y block (181): es decir, un escritorio
# encendiéndose. De 581 símbolos, ni uno de compilación. AutoFDO no optimiza el
# kernel para la tarea que se hace en esta máquina, que es compilar el kernel
# siguiente. Es un perfil perfectamente válido de la sesión equivocada.
#
# `pgo-collect.sh` sigue siendo el que sabe muestrear con LBR y convertir con
# llvm-profgen, y este script NO lo reimplementa: le pone alrededor una carga de
# compilación sostenida, que es el motivo por el que el perfil anterior salió
# como salió. Se separan porque son dos problemas distintos — capturar bien y
# capturar lo correcto — y quien sabe tomar LBR bien no tiene por qué saber qué carga
# tiene sentido para un kernel.
#
# La carga es compile-bench.sh en bucle: el banco determinista que se escribió
# para esto. Se usa con la puerta de carga saltada a propósito (COMPILE_BENCH_FORCE=1):
# aquí no se quiere medir nada, se quiere QUEMAR CPU con compilación. La puerta
# existe para no anotar cifras contaminadas, y una carga de compilación contiene toda la máquina por definición.
#
# Detalles que importan y que no son evidentes:
#
# - La carga corre como USUARIO y la captura como root. pgo-collect.sh se eleva
#   solo con exec sudo, así que si este script se lanzara entero con sudo, la
#   carga también saldría como root: fork/exec de root tiene una firma distinta
#   (y no es la que se quiere perfilar). Por eso NO se pide sudo aquí.
#
# - Se avisa ANTES de los 15 minutos si la máquina está ocupada. Con el
#   escritorio abierto, el perfil se vuelve a contaminar con i915 y btrfs y se
#   repite exactamente el problema que motiva este script. Aquí el consejo es
#   literal: cierra el navegador.
#
# - Se hace PRE-VUELO del vmlinux. El perfil se convierte contra el vmlinux del
#   kernel que corre; si no está en el store, llvm-profgen falla AL FINAL, tras
#   quince minutos de muestreo, y se pierde la sesión. Se comprueba antes.
#
# - El perfil anterior se aparta, no se pisa. Los 18.918.656 símbolos del
#   escritorio son un activo: si el nuevo perfil sale peor, se vuelve al
#   anterior. Con --fuerza se acepta perderlo.
#
# Uso (mismos argumentos que pgo-collect.sh; --duration por defecto 900):
#   pgo-load.sh [--duration N] [--vmlinux RUTA] [--out FICH]
#              [--period N] [--keep-perfdata] [--fuerza]
# ============================================================

set -uo pipefail
export LC_ALL=C

B=$'\033[1m'; Y=$'\033[33m'; C=$'\033[36m'; R=$'\033[31m'; N=$'\033[0m'
log(){  printf '%s[%s]%s %s\n' "$B" "$(date +%H:%M:%S)" "$N" "$*"; }
info(){ printf '%s  •%s %s\n' "$C" "$N" "$*"; }
warn(){ printf '%s  ⚠%s %s\n' "$Y" "$N" "$*"; }
fatal(){ printf '%s  ✗%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

DIR="$(cd "$(dirname "$0")" && pwd)"
COLLECT="$DIR/pgo-collect.sh"
BENCH="$DIR/compile-bench.sh"

# 900 s, no los 600 de pgo-collect.sh. Quince minutos es lo que hace falta para
# que AutoFDO tenga suficientes muestras por función: con menos, LLVM optimiza
# las funciones que ya salen hot y deja el resto igual.
DURATION=900
VMLINUX=""; OUT=""; PERIOD=""; KEEP=0; FORCE=0; PREFLIGHT=0
CARGA_TU="${CIZEN_PGO_CARGA_TU:-60}"

while [ $# -gt 0 ]; do
  case "$1" in
    --duration) DURATION="${2:-}"; [ -n "$DURATION" ] || fatal "--duration requiere segundos"; shift 2 ;;
    --vmlinux)  VMLINUX="${2:-}"; [ -n "$VMLINUX" ] || fatal "--vmlinux requiere una ruta"; shift 2 ;;
    --out)      OUT="${2:-}"; [ -n "$OUT" ] || fatal "--out requiere una ruta"; shift 2 ;;
    --period)   PERIOD="${2:-}"; [ -n "$PERIOD" ] || fatal "--period requiere ciclos"; shift 2 ;;
    --keep-perfdata) KEEP=1; shift ;;
    --fuerza|--force) FORCE=1; shift ;;
    --preflight) PREFLIGHT=1; shift ;;
    -h|--help) sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fatal "Opción desconocida: $1  (mira --help)" ;;
  esac
done

[ -x "$COLLECT" ] || fatal "No encuentro pgo-collect.sh junto a este script ($COLLECT)."
[ -x "$BENCH" ]   || fatal "No encuentro compile-bench.sh junto a este script ($BENCH)."
[ "$(id -u)" != 0 ] || fatal "Lánzalo SIN sudo.
  pgo-collect.sh se eleva solo cuando hace falta. Si lo lanzas con sudo, la carga
  de compilación también correrá como root y se perfilará un fork/exec de root,
  que no es el trabajo que hace esta máquina."

case "$DURATION" in ''|*[!0-9]*) fatal "--duration debe ser un entero (vale '$DURATION')" ;; esac

KVER="$(uname -r)"

# ---------- estado de la máquina: la carga tiene que dominar ----------
#
# Esto es lo que arruinó el perfil anterior. Si ahora el escritorio está
# encendido, el LBR va a seguir viendo sobre todo i915 y btrfs aunque haya un
# compilador corriendo, porque el perfil se reparte por muestras y el escritorio
# genera las suyas. Se avisa, no se bloquea: puede que el usuario sepa que su
# navegador está parado y sí quiera seguir.
psi_some() {
  awk '/^some/ { for (i = 1; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/avg60=/, "", $i); print $i; exit } }' /proc/pressure/cpu 2>/dev/null
}
PSI="$(psi_some)"; LOAD1="$(cut -d' ' -f1 /proc/loadavg)"
log "Carga actual: $(cut -d' ' -f1-3 /proc/loadavg) sobre $(nproc) núcleos, PSI ${PSI}%."
if [ -n "$PSI" ] && awk -v p="$PSI" 'BEGIN{exit !(p+0 >= 10)}'; then
  warn "La máquina está ocupada (PSI ${PSI}%). Si el escritorio sigue encendido, el"
  warn "perfil va a volver a salir de escritorio y no de compilación, que es"
  warn "justo lo que pasó con el perfil que este script viene a sustituir."
  warn "CIERRA EL NAVEGADOR Y CUALQUIER COMPILACIÓN antes de continuar."
  if [ "$FORCE" != 1 ]; then
    printf '  ¿Seguir de todos modos? [s/N] '
    read -r r </dev/tty || r=n
    case "${r:-n}" in [sSyY]|[sS][iI]|[sS][íI]) : ;; *) fatal "Cancelado. Sin máquina quieta no hay perfil." ;; esac
  fi
fi

# ---------- pre-vuelo del vmlinux: quince minutos no se pierden al final ----------
if [ -z "$VMLINUX" ]; then
  STORE="${CIZEN_VMLINUX_STORE:-/var/cache/cizen-kernel/vmlinux}"
  for cand in "/lib/modules/$KVER/build/vmlinux" "$STORE/$KVER/vmlinux" "$STORE/$KVER/vmlinux.unstripped"; do
    [ -f "$cand" ] && { VMLINUX="$cand"; break; }
  done
  if [ -z "$VMLINUX" ] && [ -f "$STORE/$KVER.meta" ]; then VMLINUX="$STORE/$KVER/vmlinux"; fi
fi
if [ -z "$VMLINUX" ] || [ ! -f "$VMLINUX" ]; then
  fatal "No encuentro el vmlinux de '$KVER' para convertir el perfil.
  Con esto, llvm-profgen fallaría DESPUÉS de muestrear quince minutos.
  Reconstruye una vez con el motor (el archivado lo deja en el store) o pásalo
  a mano:  pgo-load.sh --vmlinux /ruta/al/vmlinux"
fi
info "vmlinux: $VMLINUX ($(stat -c %s -- "$VMLINUX") bytes)"
warn "AVISO IMPORTANTE: AutoFDO se convierte contra ESTE vmlinux."
warn "Las direcciones y tamaños de función son los de este binario. Si luego"
warn "cambias -O3 o -march al compilar, los símbolos no casarán y el perfil"
warn "servirá de mucho menos. Para un A/B honesto de -O3/march hay que"
warn "recapturar contra el vmlinux de ESAS opciones, no reutilizar este."

# Destino por defecto ANTES del preflight, que lo muestra: el preflight se
# puso antes de este bloque al principio y salía con "perfil a crear:" vacío,
# porque $OUT todavía no tenía valor por defecto. Referencia a una variable no
# inicializada: el fallo más barato de todos y el que más despista.
if [ -z "$OUT" ]; then OUT="$HOME/kernel-pgo/$KVER.afdo"; fi

# ---------- preflight: comprobar todo y salir sin muestrear ----------
#
# Muestrear son quince minutos y sudo. Comprobar que el vmlinux existe, que la
# carga arranca y que el sitio de destino está bien, se puede comprobar en un
# segundo. Esto no aparta el perfil viejo: --preflight no toca nada.
if [ "$PREFLIGHT" = 1 ]; then
  echo
  log "Preflight: todo lo comprobable está bien."
  info "vmlinux       : $VMLINUX"
  info "perfil a crear: $OUT$([ -f "$OUT" ] && echo "  (existe; se apartará a .bak-<fecha> salvo --fuerza)")"
  info "duración      : ${DURATION} s de LBR"
  info "carga         : compile-bench.sh en bucle, TU=$CARGA_TU, como usuario"
  echo
  [ -n "$PSI" ] && awk -v p="$PSI" 'BEGIN{exit !(p+0 >= 10)}' && \
    warn "Falta silenciar la máquina: PSI ${PSI}%. El perfil se contaminaría."
  exit 0
fi

# ---------- el perfil viejo se aparta, no se pisa ----------
if [ -z "$OUT" ]; then OUT="$HOME/kernel-pgo/$KVER.afdo"; fi
if [ -f "$OUT" ] && [ "$FORCE" != 1 ]; then
  bak="$OUT.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$OUT" "$bak" || fatal "No puedo apartar el perfil viejo a $bak"
  info "Perfil anterior apartado en $(basename -- "$bak") (era $(stat -c %s -- "$OUT") bytes)."
  info "Si el nuevo sale peor, se vuelve a éste:"
  info "  cp $bak $OUT"
fi

# ---------- la carga ----------
CARGA_DIR="$(mktemp -d -t pgo-carga.XXXXXX)"
CARGA_PID=""
limpiar() {
  if [ -n "$CARGA_PID" ] && kill -0 "$CARGA_PID" 2>/dev/null; then
    kill -TERM "$CARGA_PID" 2>/dev/null
    # El bucle de carga tiene subshells; se mata el grupo entero.
    kill -TERM -- "-$CARGA_PID" 2>/dev/null || true
    wait "$CARGA_PID" 2>/dev/null || true
  fi
  rm -rf "$CARGA_DIR"
}
trap limpiar EXIT
trap 'limpiar; exit 130' INT TERM

fin=$(( $(date +%s) + DURATION ))
log "Encendiendo la carga de compilación durante ${DURATION} s (TU=$CARGA_TU por vuelta)."
(
  while [ "$(date +%s)" -lt "$fin" ]; do
    COMPILE_BENCH_FORCE=1 COMPILE_BENCH_TU="$CARGA_TU" COMPILE_BENCH_REPS=1 \
      CIZEN_VERIFY_STATE_DIR="$CARGA_DIR" CIBENCH_VARIANT=carga \
      "$BENCH" >/dev/null 2>&1 || true
  done
) &
CARGA_PID=$!
sleep 3
if ! kill -0 "$CARGA_PID" 2>/dev/null; then
  fatal "La carga no arrancó. Pruébala a mano:
  COMPILE_BENCH_FORCE=1 COMPILE_BENCH_TU=$CARGA_TU COMPILE_BENCH_REPS=1 CIZEN_VERIFY_STATE_DIR=$CARGA_DIR $BENCH"
fi
info "Carga en marcha (pid $CARGA_PID)."
info "Ahora no compiles, no navegues y no abras el navegador: en 15 minutos se"
info "decide si este perfil sirve para algo."
log "Muestreando..."

args=( --duration "$DURATION" --vmlinux "$VMLINUX" --out "$OUT" )
[ -n "$PERIOD" ] && args+=( --period "$PERIOD" )
[ "$KEEP" = 1 ] && args+=( --keep-perfdata )

"$COLLECT" "${args[@]}"
rc=$?

limpiar
trap - EXIT

if [ "$rc" -ne 0 ]; then
  fatal "pgo-collect.sh devolvió $rc. La carga se ha parado; revisa el error de arriba."
fi

echo
if [ -f "$OUT" ]; then
  log "Perfil nuevo: $OUT ($(stat -c %s -- "$OUT") bytes)"
  info "Siguiente paso: reconstruir con él y MEDIR con compile-bench.sh."
  info "Un perfil no es una mejora: es una hipótesis. Si tras recompilar no sube"
  info "el número de TU/s, el perfil no vale y se vuelve al anterior."
else
  warn "pgo-collect.sh terminó sin error pero no hay perfil en $OUT. Revisa su salida."
fi