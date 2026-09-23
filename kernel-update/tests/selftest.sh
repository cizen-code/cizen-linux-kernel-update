#!/usr/bin/env bash
# ============================================================
# tests/selftest.sh — harness funcional del framework de parches.
#
# Extrae las funciones del motor (kernel-update.sh) por rango y las ejercita
# aisladas con stubs (sin red, sin sudo, sin árbol kernel real). Cubre:
#   - bore_branch_from_version            (rama X.Y desde una versión X.Y.Z)
#   - patch_markers_hit                   (árbol ya parcheado por marcadores)
#   - apply_patch_register                (registro de símbolos + BORE_ENABLED)
#   - apply_patch_plugin                  (flujo completo: descarga→dry-run→
#                                          apply→registro, y los degrades)
#
# Llamado por: kernel-update.sh --selftest / kselftest. También ejecutable
# en solitario:  bash tests/selftest.sh [ruta_al_motor]
# ============================================================
set -u
MOTOR="${1:-/usr/local/bin/kernel-update/kernel-update.sh}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cizen-selftest.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
rec() { # ok -> $1 | nombre de test -> $2
  if [ "$1" = ok ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$2"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$2"
  fi
}

# --- stubs del entorno del motor -------------------------------------
ok()  { :; }
warn(){ :; }
info(){ :; }
log() { :; }
err() { :; }

# stub de patch(1): no se aplica nada real. Como el motor usa `patch ... < f`,
# el fichero llega por stdin (no por argumento); la decisión se toma con la
# variable que download_file deja sobre el ÚLTIMO parche servido:
#   cachy    -> el forward-port no aplica sobre X.Y.Z (return 1)
#   upstream -> aplica limpio (return 0)
patch() {
  if [ "$LAST_SERVED" = "cachy" ]; then return 1; else return 0; fi
}

# stub de download_file(1): sirve los parches de prueba según la URL y marca
# cuál se sirvió. Devuelve 1 si la URL no coincide con ninguna rama conocida.
DL_CALLED=0
LAST_SERVED=""
download_file() {
  local url="$1" out="$2"
  DL_CALLED=$((DL_CALLED + 1))
  case "$url" in
    *"/sched/0001-bore-cachy.patch") LAST_SERVED="cachy";    cp -- "$ROOT/patch-cachy.patch" "$out" 2>/dev/null; return 0 ;;
    *"/sched/0001-bore.patch")       LAST_SERVED="upstream"; cp -- "$ROOT/patch-upstream.patch" "$out" 2>/dev/null; return 0 ;;
  esac
  return 1
}

# parches de prueba (contienen el PATCH_MAGIC que exige el motor)
printf 'config SCHED_BORE\n--- a/init/Kconfig\n+++ b/init/Kconfig\n' > "$ROOT/patch-cachy.patch"
cp -- "$ROOT/patch-cachy.patch" "$ROOT/patch-upstream.patch"

# --- extraer funciones del motor -------------------------------------
extract() { # $1 = nombre de función (hasta el `}` inicial en columna 0)
  sed -n "/^$1() {/,/^}/p" "$MOTOR"
}
{
  extract bore_branch_from_version
  extract patch_desc_bore
  extract patch_markers_hit
  extract apply_patch_register
  extract apply_patch_plugin
} > "$ROOT/fns.sh"

if [ ! -s "$ROOT/fns.sh" ]; then
  echo "  FAIL  no se pudieron extraer funciones de $MOTOR"
  exit 1
fi
# shellcheck disable=SC1090,SC1091
source "$ROOT/fns.sh"

# --- entorno de ejecución ---
export VERSION="7.2.6"
export KERNEL_BUILD_ROOT="$ROOT/build"
export SRC="$ROOT/src"
mkdir -p "$KERNEL_BUILD_ROOT" "$SRC"
BORE_ENABLED=false
declare -a PATCHES_APPLIED=()
declare -a PATCH_ENABLE_ALL=()
declare -a PATCH_REBEL_ALL=()

printf '%s\n' "== bore_branch_from_version =="
[ "$(bore_branch_from_version 7.2.6)" = "7.2" ] && rec ok "7.2.6 -> 7.2" || rec fail "7.2.6 -> 7.2"
[ "$(bore_branch_from_version 7.2)" = "7.2" ] && rec ok "7.2 -> 7.2" || rec fail "7.2 -> 7.2"
[ "$(bore_branch_from_version 6.1.77)" = "6.1" ] && rec ok "6.1.77 -> 6.1" || rec fail "6.1.77 -> 6.1"

printf '%s\n' "== patch_markers_hit (árbol ya parcheado) =="
mkdir -p "$SRC/kernel/sched"
: > "$SRC/kernel/sched/bore.c"
printf '%s\n' "static bool burst_ok; SCHED_BORE defined" > "$SRC/kernel/sched/fair.c"
patch_desc_bore
patch_markers_hit && rec ok "marcadores del descriptor detectan el árbol parcheado" || rec fail "marcadores no detectados"
rm -f "$SRC/kernel/sched/bore.c"
! patch_markers_hit && rec ok "sin bore.c los marcadores fallan (árbol vanilla)" || rec fail "marcadores erróneos en árbol vanilla"
rm -f "$SRC/kernel/sched/fair.c"

printf '%s\n' "== apply_patch_register =="
unset PATCH_SYMBOLS
apply_patch_register foo
[ "${PATCHES_APPLIED[*]:-}" = "foo" ] && rec ok "register añade el nombre a PATCHES_APPLIED" || rec fail "PATCHES_APPLIED"
[ "$BORE_ENABLED" = false ] && rec ok "register de 'foo' no marca BORE (solo bore lo hace)" || rec fail "BORE_ENABLED no debe cambiar con foo"
[ "${PATCH_ENABLE_ALL[*]:-}" = "" ] && rec ok "sin símbolos no hay entradas ENABLE" || rec fail "PATCH_ENABLE_ALL vacío esperado"
apply_patch_register bore
[ "$BORE_ENABLED" = true ] && rec ok "register de 'bore' marca BORE_ENABLED" || rec fail "BORE_ENABLED tras bore"
printf '%s\n' "    BORE_ENABLED=$BORE_ENABLED PATCHES_APPLIED=${PATCHES_APPLIED[*]:-}"

printf '%s\n' "== apply_patch_plugin: flujo completo (degrade cachy->upstream) =="
PATCHES_APPLIED=()
PATCH_ENABLE_ALL=()
PATCH_REBEL_ALL=()
BORE_ENABLED=false
DL_CALLED=0
# Anclaje SHA256 activo: los parches de prueba son sintéticos, así que se fija
# el pin a su hash para que el flujo completo se valide por el camino "hash OK".
export CIZEN_PATCH_SHA256_MAIN="$(sha256sum "$ROOT/patch-cachy.patch" | cut -d' ' -f1)"
export CIZEN_PATCH_SHA256_FALLBACK="$(sha256sum "$ROOT/patch-upstream.patch" | cut -d' ' -f1)"
# destino sucio previo: el motor DEBE borrarlo antes de cada descarga
printf 'BASURA-STALE\n' > "$KERNEL_BUILD_ROOT/bore-7.2.patch"
if apply_patch_plugin bore; then
  rec ok "apply_patch_plugin devuelve 0 para bore (nto. cachy falla, upstream aplica)"
  [ "$BORE_ENABLED" = true ] && rec ok "BORE_ENABLED=true tras el flujo" || rec fail "BORE_ENABLED tras flujo"
  case " ${PATCH_ENABLE_ALL[*]:-} " in
    *SCHED_BORE*MIN_BASE_SLICE_NS*) rec ok "SCHED_BORE y MIN_BASE_SLICE_NS en ENABLE" ;;
    *) rec fail "símbolos BORE no registrados en ENABLE: [${PATCH_ENABLE_ALL[*]:-}]" ;;
  esac
  case " ${PATCH_REBEL_ALL[*]:-} " in
    *SCHED_BORE*MIN_BASE_SLICE_NS*) rec ok "símbolos BORE rebeldes esperados" ;;
    *) rec fail "símbolos BORE no en REBEL: [${PATCH_REBEL_ALL[*]:-}]" ;;
  esac
  stale_c="$(grep -c 'BASURA' "$KERNEL_BUILD_ROOT/bore-7.2.patch" 2>/dev/null || true)"
  [ "${stale_c:-1}" = "0" ] \
    && rec ok "destino borrado antes de descargar (resultado fresco, sin stale)" \
    || rec fail "el fichero stale no se limpió (BASURA=$stale_c)"
  [ "$DL_CALLED" -ge 2 ] && rec ok "se descargaron cachy y upstream (2 intentos)" || rec fail "no hubo 2 descargas (DL_CALLED=$DL_CALLED)"
else
  rec fail "el flujo completo debía aplicar (upstream aplicable)"
fi

printf '%s\n' "== apply_patch_plugin: pin SHA256 rechaza hash no anclado =="
rm -rf "$SRC/kernel/sched" "$KERNEL_BUILD_ROOT"/*
mkdir -p "$SRC"
PATCHES_APPLIED=(); PATCH_ENABLE_ALL=(); PATCH_REBEL_ALL=(); BORE_ENABLED=false
export CIZEN_PATCH_SHA256_FALLBACK="0000000000000000000000000000000000000000000000000000000000000000"
if apply_patch_plugin bore; then
  rec fail "el pin SHA256 incorrecto debía rechazar el parche"
else
  rec ok "pin SHA256 incorrecto -> rechaza el parche (fatal suave, degrada vanilla)"
fi
[ "${PATCHES_APPLIED[*]:-}" = "" ] && rec ok "pin rechazado: bore no se registró" || rec fail "bore se registró pese al pin no válido"
unset CIZEN_PATCH_SHA256_FALLBACK

printf '%s\n' "== apply_patch_plugin: árbol conservado ya parcheado (v27.22.4) =="
mkdir -p "$SRC/kernel/sched"
: > "$SRC/kernel/sched/bore.c"
printf '%s\n' "burst SCHED_BORE" > "$SRC/kernel/sched/fair.c"
PATCHES_APPLIED=(); PATCH_ENABLE_ALL=(); PATCH_REBEL_ALL=(); BORE_ENABLED=false
DL_CALLED=0
if apply_patch_plugin bore; then
  rec ok "devuelve 0 sin volver a aplicar (árbol ya parcheado)"
  case " ${PATCHES_APPLIED[*]:-} " in
    *" bore "*) rec ok "aun no descargado, registra el parche" ;;
    *) rec fail "no registró bore" ;;
  esac
  [ "$DL_CALLED" = "0" ] && rec ok "no se llamó a download_file (marcadores)" || rec fail "se descargó pese a los marcadores (DL_CALLED=$DL_CALLED)"
else
  rec fail "debía detectar los marcadores y aplicar sin red"
fi

printf '%s\n' "== apply_patch_plugin: sin parche disponible (fatal suave) =="
rm -rf "$SRC/kernel/sched" "$KERNEL_BUILD_ROOT"/*
mkdir -p "$SRC"
PATCHES_APPLIED=(); PATCH_ENABLE_ALL=(); PATCH_REBEL_ALL=(); BORE_ENABLED=false
# forzar fallo de BOTH: sustituir el stub de download_file por uno que no sirve nada
download_file() { DL_CALLED=$((DL_CALLED + 1)); return 1; }
if apply_patch_plugin bore; then
  rec fail "sin parche disponible debía devolver 1"
else
  rec ok "devuelve 1 (degrade a vanilla)"
  [ "$BORE_ENABLED" = false ] && rec ok "BORE_ENABLED se mantiene false" || rec fail "BORE_ENABLED no debe activarse"
fi

printf '%s\n' "== apply_patch_plugin: nombre desconocido =="
PATCHES_APPLIED=(); BORE_ENABLED=false
if apply_patch_plugin foo; then
  rec fail "parche desconocido debía devolver 1"
else
  rec ok "devuelve 1"
fi

# --- resumen ---
echo
printf 'Totales: %d ok, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]