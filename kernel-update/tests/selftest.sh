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
export ROOT
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
# fatal en el motor hace exit 1; en el harness NO debe matar el selftest, solo
# señalizar el fallo con rc=1 a la función que lo invocó.
fatal(){ return 1; }
# build_effective_arrays llama a resolve_symbol (mapa de renames). Sin mapa en
# el harness: identidad.
declare -A RENAME_MAP=()
resolve_symbol() { printf '%s' "$1"; }

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
download_file_good() {
  local url="$1" out="$2"
  DL_CALLED=$((DL_CALLED + 1))
  printf '%s\n' "$url" >> "$ROOT/dl.log"
  case "$url" in
    *"/sched/0001-bore-cachy.patch") LAST_SERVED="cachy";    cp -- "$ROOT/patch-cachy.patch" "$out" 2>/dev/null; return 0 ;;
    *"/sched/0001-bore.patch")       LAST_SERVED="upstream"; cp -- "$ROOT/patch-cachy.patch" "$out" 2>/dev/null; return 0 ;;
    *"/sched/0001-prjc-cachy.patch") LAST_SERVED="cachy";    cp -- "$ROOT/patch-bmq.patch" "$out" 2>/dev/null; return 0 ;;
    *"/sched/0001-prjc.patch")       LAST_SERVED="upstream"; cp -- "$ROOT/patch-bmq.patch" "$out" 2>/dev/null; return 0 ;;
    *"/misc/0001-acpi-call.patch")     LAST_SERVED="upstream"; cp -- "$ROOT/patch-misc.patch" "$out" 2>/dev/null; return 0 ;;
    *"/misc/acpi-call.patch")          LAST_SERVED="upstream"; cp -- "$ROOT/patch-misc.patch" "$out" 2>/dev/null; return 0 ;;
    *"/misc/0001-rt-i915.patch")       LAST_SERVED="upstream"; cp -- "$ROOT/patch-misc.patch" "$out" 2>/dev/null; return 0 ;;
    *"/misc/rt-i915.patch")            LAST_SERVED="upstream"; cp -- "$ROOT/patch-misc.patch" "$out" 2>/dev/null; return 0 ;;
  esac
  return 1
}
download_file() { download_file_good "$@"; }
# El probe de releases usa download_small_file (un hilo); en el harness se
# sirve con el mismo stub de download_file para no tocar la red.
download_small_file() { download_file "$@"; }

# parches de prueba (contienen el PATCH_MAGIC que exige el motor)
printf 'config SCHED_BORE\n--- a/init/Kconfig\n+++ b/init/Kconfig\n' > "$ROOT/patch-cachy.patch"
cp -- "$ROOT/patch-cachy.patch" "$ROOT/patch-upstream.patch"

# stub del blob embebido (v27.31.5): el motor NO extrae la función real de
# 2283+ líneas al harness; se sustituye por base64(gzip) de un parche sintético
# con el mismo PATCH_MAGIC que bmq y un marcador propio del harness. El test del
# camino embebido reemplaza este stub por uno con marcador FORWARD-EMBED-TEST
# para distinguir qué parche (main vs embed) está pasando por el dry-run.
patch_embed_b64_prjc_cachy() {
  printf 'config SCHED_BMQ\n--- a/init/Kconfig\n+++ b/init/Kconfig\n' \
    | gzip | base64 | tr -d '\n'
}

# --- extraer funciones del motor -------------------------------------
extract() { # $1 = nombre de función (hasta el `}` inicial en columna 0)
  sed -n "/^[[:space:]]*$1() {/,/^}/p" "$MOTOR"
}
{
  extract bore_branch_from_version
  extract patch_desc_bore
  extract _patch_desc_scheduler_base
  # descriptores compactos de una línea (pds/bmq/lfbmq/muqss)
  sed -n '/^patch_desc_\(pds\|bmq\|lfbmq\|muqss\)()[[:space:]]*{/p' "$MOTOR"
  extract patch_desc_ntsync
  extract patch_desc_fsync
  extract kernel_version_ge
  extract _resolve_cc_compiler
  extract resolve_kernel_tree
  extract cachyos_release_tagrel
  extract resolve_cachyos_release
  extract confirm_newer_release
  extract process_frag_file
  extract apply_config_fragments
  extract patch_markers_hit
  extract apply_patch_register
  extract apply_patch_plugin
  extract _sched_alt_rtmutex_futex_fixup
  extract add_unique
  extract build_effective_arrays
  extract check_profile_contradictions
  extract _misc_extract_kconfig_symbols
  extract apply_cachy_misc_symbols
  extract apply_cachy_misc_single
  extract apply_cachy_misc_patchset
  extract secure_boot_guided_setup
  # v27.31.17: identidad del árbol de fuentes y desmontaje inteligente
  extract source_tree_valid
  extract source_tree_kind
  extract tree_identity
  extract tmpfs_is_mounted
  extract tmpfs_umount_all
  extract auto_add_ntsync_patch
  extract tree_usable_for
  extract source_tree_reusable
  extract write_tree_meta
  extract reconcile_tmpfs_trees
  extract get_mem_available_mb
  extract unmount_tmpfs_build
  extract effective_scheduler
  extract write_verify_signature
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
# restaurar el stub bueno (el de arriba solo valía para el test anterior)
download_file() { download_file_good "$@"; }

printf '%s\n' "== apply_patch_plugin: nombre desconocido =="
PATCHES_APPLIED=(); BORE_ENABLED=false
if apply_patch_plugin foo; then
  rec fail "parche desconocido debía devolver 1"
else
  rec ok "devuelve 1"
fi

# ============================================================
# v27.30.0 — schedulers alternativos, skip por versión y frags
# ============================================================
printf '%s\n' "== kernel_version_ge (v27.30.0) =="
kernel_version_ge 6.10 6.10 && rec ok "6.10 >= 6.10" || rec fail "6.10>=6.10"
kernel_version_ge 7.2.6 6.8 && rec ok "7.2.6 >= 6.8" || rec fail "7.2.6>=6.8"
! kernel_version_ge 6.1.77 6.2 && rec ok "6.1.77 < 6.2" || rec fail "6.1.77>=6.2"
! kernel_version_ge 5.15 6.1 && rec ok "5.15 < 6.1" || rec fail "5.15>=6.1"

printf '%s\n' "== patch_desc: schedulers alternativos =="
patch_desc_pds
[ "$PATCH_MAIN_FILE" = "0001-prjc-cachy.patch" ] && rec ok "PDS: MAIN=prjc-cachy" || rec fail "PDS MAIN: $PATCH_MAIN_FILE"
[ "$PATCH_FALLBACK_FILE" = "0001-prjc.patch" ] && rec ok "PDS: FALLBACK=prjc" || rec fail "PDS FALLBACK: $PATCH_FALLBACK_FILE"
case " ${PATCH_CHOICE_DISABLE[*]:-} " in
  *SCHED_BMQ*) rec ok "PDS deshabilita SCHED_BMQ (choice Kconfig)" ;;
  *) rec fail "PDS choice-disable: [${PATCH_CHOICE_DISABLE[*]:-}]" ;;
esac
PATCHES_APPLIED=(); PATCH_DISABLE_ALL=()
apply_patch_register pds
case " ${PATCH_DISABLE_ALL[*]:-} " in
  *SCHED_BMQ*) rec ok "register 'pds' -> PATCH_DISABLE_ALL acumula SCHED_BMQ" ;;
  *) rec fail "PATCH_DISABLE_ALL tras pds: [${PATCH_DISABLE_ALL[*]:-}]" ;;
esac
case " ${PATCH_ENABLE_ALL[*]:-} " in
  *SCHED_ALT*SCHED_PDS*) rec ok "PDS registra SCHED_ALT y SCHED_PDS en ENABLE" ;;
  *) rec fail "PDS ENABLE: [${PATCH_ENABLE_ALL[*]:-}]" ;;
esac

patch_desc_muqss
[ "$PATCH_MAIN_FILE" = "0001-muqss-cachy.patch" ] && rec ok "MuQSS: MAIN=muqss-cachy" || rec fail "MuQSS MAIN: $PATCH_MAIN_FILE"
case " ${PATCH_SYMBOLS[*]:-} " in
  *SCHED_MUQSS*) rec ok "MuQSS: símbolo SCHED_MUQSS" ;;
  *) rec fail "MuQSS símbolos: [${PATCH_SYMBOLS[*]:-}]" ;;
esac

printf '%s\n' "== apply_patch_plugin: plugins sin pin SHA256 (bmq) no crashean (set -u) =="
rm -rf "$SRC/kernel/sched"; mkdir -p "$SRC"
PATCHES_APPLIED=(); PATCH_ENABLE_ALL=(); PATCH_REBEL_ALL=(); PATCH_DISABLE_ALL=(); BORE_ENABLED=false
# bmq exige el árbol del fork CachyOS: en el harness se fuerza ese árbol para
# que el flujo de aplicación llegue al final (v27.31.0).
KERNEL_TREE=cachyos
unset CIZEN_PATCH_SHA256_MAIN CIZEN_PATCH_SHA256_FALLBACK
printf 'config SCHED_BMQ\n--- a/init/Kconfig\n+++ b/init/Kconfig\n' > "$ROOT/patch-bmq.patch"
: > "$ROOT/dl.log"
if apply_patch_plugin bmq; then
  rec ok "bmq (sin pin en el descriptor): flujo completo aplica sin 'unbound variable'"
else
  rec fail "bmq (sin pin): crasheó o degradó (regresión fix 2026-09-24)"
fi
case " ${PATCH_ENABLE_ALL[*]:-} " in
  *SCHED_BMQ*) rec ok "bmq registra SCHED_BMQ en ENABLE" ;;
  *) rec fail "bmq ENABLE: [${PATCH_ENABLE_ALL[*]:-}]" ;;
esac
rm -f -- "$ROOT/patch-bmq.patch"

printf '%s\n' "== _sched_alt_rtmutex_futex_fixup (v27.31.9): hooks futex del rtmutex en SCHED_ALT =="
rm -rf "$SRC"; mkdir -p "$SRC/kernel/sched" "$SRC/kernel/locking"
: > "$SRC/kernel/sched/alt_core.c"
printf '%s\n' \
  "	int rt_mutex_futex_pre_schedule();" \
  "	rt_mutex_futex_post_schedule();" > "$SRC/kernel/locking/rtmutex_api.c"
_sched_alt_rtmutex_futex_fixup
grep -q 'void rt_mutex_futex_pre_schedule' "$SRC/kernel/sched/alt_core.c" \
  && rec ok "fixup añade rt_mutex_futex_pre_schedule a alt_core.c (hueco forward-port)" \
  || rec fail "fixup: rt_mutex_futex_pre_schedule no añadido a alt_core.c"
grep -q 'void rt_mutex_futex_post_schedule' "$SRC/kernel/sched/alt_core.c" \
  && rec ok "fixup añade rt_mutex_futex_post_schedule a alt_core.c" \
  || rec fail "fixup: rt_mutex_futex_post_schedule no añadido"
n1="$(grep -c 'void rt_mutex_futex_pre_schedule' "$SRC/kernel/sched/alt_core.c")"
_sched_alt_rtmutex_futex_fixup
n2="$(grep -c 'void rt_mutex_futex_pre_schedule' "$SRC/kernel/sched/alt_core.c")"
[ "$n1" = "1" ] && [ "$n2" = "1" ] \
  && rec ok "fixup idempotente (no duplica las definiciones al reintentar)" \
  || rec fail "fixup idempotencia: n1=$n1 n2=$n2"
: > "$SRC/kernel/sched/alt_core.c"
printf '%s\n' "	int rtmputex_plain;" > "$SRC/kernel/locking/rtmutex_api.c"
_sched_alt_rtmutex_futex_fixup
[ "$(grep -c 'void rt_mutex_futex_pre_schedule' "$SRC/kernel/sched/alt_core.c")" = "0" ] \
  && rec ok "sin hooks futex en rtmutex_api.c el fixup no toca nada (kernel anterior)" \
  || rec fail "fixup: debería ser no-op sin hooks futex (añadió spurious)"
rm -rf "$SRC/kernel"; mkdir -p "$SRC"
_sched_alt_rtmutex_futex_fixup
rec ok "fixup no-op si no hay alt_core.c (arbol no-SCHED_ALT)"

printf '%s\n' "== resolve_release_tree (v27.31.0): selección del árbol CachyOS =="
KERNEL_TREE=""
CIZEN_KERNEL_TREE=auto
PATCH_NAMES=(bmq)
resolve_kernel_tree
[ "$KERNEL_TREE" = "cachyos" ] && rec ok "auto + bmq -> árbol cachyos" || rec fail "auto+bmq -> KERNEL_TREE=$KERNEL_TREE"
PATCH_NAMES=(bore)
resolve_kernel_tree
[ "$KERNEL_TREE" = "vanilla" ] && rec ok "auto + bore -> árbol vanilla" || rec fail "auto+bore -> KERNEL_TREE=$KERNEL_TREE"
PATCH_NAMES=(pds)
resolve_kernel_tree
[ "$KERNEL_TREE" = "cachyos" ] && rec ok "auto + pds -> árbol cachyos" || rec fail "auto+pds -> KERNEL_TREE=$KERNEL_TREE"
PATCH_NAMES=(lfbmq)
resolve_kernel_tree
[ "$KERNEL_TREE" = "cachyos" ] && rec ok "auto + lfbmq -> árbol cachyos" || rec fail "auto+lfbmq -> KERNEL_TREE=$KERNEL_TREE"
PATCH_NAMES=(muqss)
resolve_kernel_tree
[ "$KERNEL_TREE" = "cachyos" ] && rec ok "auto + muqss -> árbol cachyos" || rec fail "auto+muqss -> KERNEL_TREE=$KERNEL_TREE"
PATCH_NAMES=(bore)
CIZEN_KERNEL_TREE=vanilla
resolve_kernel_tree
[ "$KERNEL_TREE" = "vanilla" ] && rec ok "vanilla forzado se respeta" || rec fail "vanilla forzado -> KERNEL_TREE=$KERNEL_TREE"
PATCH_NAMES=(bmq)
CIZEN_KERNEL_TREE=cachyos
resolve_kernel_tree
[ "$KERNEL_TREE" = "cachyos" ] && rec ok "cachyos forzado se respeta" || rec fail "cachyos forzado -> KERNEL_TREE=$KERNEL_TREE"
CIZEN_KERNEL_TREE=auto
PATCH_NAMES=()
resolve_kernel_tree
[ "$KERNEL_TREE" = "vanilla" ] && rec ok "auto sin parches -> vanilla" || rec fail "auto sin parches -> KERNEL_TREE=$KERNEL_TREE"
PATCH_NAMES=()
( set -e; PATCH_NAMES=(bmq)
  resolve_kernel_tree; [ "$KERNEL_TREE" = "cachyos" ] ) \
  && rec ok "resolve_kernel_tree no aborta bajo set -e (regresión fix v27.31.3)" \
  || rec fail "resolve_kernel_tree aborta bajo set -e (regresión fix v27.31.3)"

printf '%s\n' "== resolve_cachyos_release (v27.31.0): parseo del JSON de releases =="
releases_json() {
  printf '%s\n' '[
  {"tag_name": "cachyos-7.2.8-1", "draft": false},
  {"tag_name": "cachyos-7.2.7-2", "draft": false},
  {"tag_name": "cachyos-7.2.7-1", "draft": false},
  {"tag_name": "cachyos-7.2.7-rc4-1", "draft": false},
  {"tag_name": "cachyos-7.2.6-1", "draft": false}
]'
}
download_file() {
  local url="$1" out="$2"
  case "$url" in
    *"releases?per_page=20") printf '%s\n' "$(releases_json)" > "$out"; return 0 ;;
  esac
  return 1
}
CACHYOS_TAGREL=""
if resolve_cachyos_release 7.2.7; then
  if [ "$CACHYOS_TAGREL" = "2" ]; then
    rec ok "API: tagrel máximo cachyos-7.2.7-2"
  elif [ "$CACHYOS_TAGREL" = "1" ]; then
    rec fail "API: eligió tagrel 1 (debía coger el máximo, el -2)"
  else
    rec fail "API: tagrel=$CACHYOS_TAGREL (esperado 2)"
  fi
else
  rec fail "resolve_cachyos_release falló con JSON de releases válido"
fi

printf '%s\n' "== resolve_cachyos_release (v27.31.0): sondeo directo de .asc =="
download_file() {
  local url="$1" out="$2"
  case "$url" in
    *"cachyos-7.2.7-3.tar.gz.asc") : > "$out"; return 0 ;;
  esac
  return 1
}
CACHYOS_TAGREL=""
if resolve_cachyos_release 7.2.7; then
  [ "$CACHYOS_TAGREL" = "3" ] \
    && rec ok "sondeo: API caída -> probó .asc y halló tagrel 3" \
    || rec fail "sondeo: tagrel=$CACHYOS_TAGREL (esperado 3)"
else
  rec fail "resolve_cachyos_release falló en el camino de sondeo directo"
fi

printf '%s\n' "== resolve_cachyos_release (v27.31.15): versión sin publicar en el fork bajo set -Eeuo pipefail =="
# El motor corre con `set -Eeuo pipefail` + trap ERR. Si el fork todavía no
# publicó la versión (la recién salida en kernel.org), el último grep de la
# tubería se quedaba sin entrada y devolvía 1: con pipefail eso MATABA la run
# ("Error 1 en línea N: tail -n1") sin llegar al sondeo directo ni al fatal
# explicativo. Aquí se reproduce ese marco y el marcador solo se escribe si la
# función llega a su propio fatal.
# OJO: el marco va en un subshell SIN `||`/`&&` alrededor; una sustitución de
# comandos metida en una lista `||` hereda errexit desactivado y el test
# pasaría siempre (falso verde). Los marcadores van a un fichero.
probe_cachyos() { # $1 = versión -> rastro en $ROOT/probe.out, rc en $_probe_rc
  rm -f -- "$ROOT/probe.out"
  (
    set -Eeuo pipefail
    fatal() { printf 'REACHED-FATAL\n' >> "$ROOT/probe.out"; return 1; }
    CACHYOS_TAGREL=""
    resolve_cachyos_release "$1"
    printf 'TAGREL=%s\n' "$CACHYOS_TAGREL" >> "$ROOT/probe.out"
  )
  _probe_rc=$?
  return 0
}
download_file() {
  local url="$1" out="$2"
  case "$url" in
    *"releases?per_page=20") cat > "$out" <<'JSON'
[
  {"tag_name": "cachyos-7.2.7-1", "draft": false},
  {"tag_name": "cachyos-7.3-rc4-1", "draft": false},
  {"tag_name": "cachyos-7.2.6-1", "draft": false}
]
JSON
      return 0 ;;
  esac
  return 1
}
probe_cachyos 7.2.8
if grep -q REACHED-FATAL "$ROOT/probe.out" 2>/dev/null; then
  rec ok "fork sin esa versión: la tubería no aborta la run (llega a su fatal)"
else
  rec fail "fork sin esa versión: la tubería aborta antes del fatal (rc=$_probe_rc; rastro: $(cat "$ROOT/probe.out" 2>/dev/null || echo ninguno))"
fi
# Y el camino feliz no se rompe por el `|| true` de la guarda.
download_file() {
  local url="$1" out="$2"
  case "$url" in
    *"releases?per_page=20") printf '%s\n' "$(releases_json)" > "$out"; return 0 ;;
  esac
  return 1
}
probe_cachyos 7.2.7
if grep -q '^TAGREL=2$' "$ROOT/probe.out" 2>/dev/null; then
  rec ok "fork con esa versión: la guarda '|| true' no rompe la resolución"
else
  rec fail "con la guarda '|| true' dejó de resolver (rc=$_probe_rc; rastro: $(cat "$ROOT/probe.out" 2>/dev/null || echo ninguno))"
fi

# ============================================================
printf '%s\n' "== confirm_newer_release (v27.31.18): no ofrecer lo que el fork no tiene =="
# El harness también corre contra motores antiguos (para verlos en rojo), donde
# estas funciones no existen: se inicializan los globales que leen los tests
# para que la ausencia se traduzca en FAIL y no en un `set -u` que mata la
# suite entera.
CACHYOS_TAGREL=""; CACHYOS_API_OK=""; CACHYOS_SEEN_TAGS=""
CACHYOS_LATEST_MINOR=""; CACHYOS_FOUND_VIA=""
KERNEL_TREE=""; TREE_FORCE_NOTE=""
# El menú (v27.31.16) ofrece la release del fork cuando el scheduler es de los
# que solo viven allí, pero el motor volvía a preguntar por la stable de
# kernel.org: el usuario aceptaba 7.2.7 y acto seguido le ofrecía 7.2.8, que con
# bmq aborta en resolve_cachyos_release. Aquí se comprueba que la pregunta se
# consulta al fork y, si no tiene la versión, NO se formula.
# El harness no tiene TTY, así que la rama que llega a read es indistinguible de
# la que aborta antes; lo que se comprueba es qué se imprime y si se consultó
# la red: la versión no compilable se detecta por el aviso, sin llegar a read.
capture_warn() { warn() { printf 'WARN: %s\n' "$*" >> "$ROOT/ui.log"; }; }
capture_info() { info() { printf 'INFO: %s\n' "$*" >> "$ROOT/ui.log"; }; }
fork_json_missing_728() {
  cat > "$1" <<'JSON'
[
  {"tag_name": "cachyos-7.2.7-1", "draft": false},
  {"tag_name": "cachyos-7.2.6-2", "draft": false},
  {"tag_name": "cachyos-7.3-rc4-1", "draft": false}
]
JSON
}
download_file() {
  local url="$1" out="$2"
  case "$url" in
    *"releases?per_page=20") fork_json_missing_728 "$out"; return 0 ;;
  esac
  return 1
}
# 1) bmq + stable 7.2.8 sin publicar en el fork -> no pregunta y lo explica.
#    Se pide 7.2.6 para que además aparezca la pista accionable: la última 7.2.x
#    del fork (7.2.7) es distinta de la solicitada, y con la 7.2.7 ya pedida esa
#    línea sería ruido (la cubre el mensaje del llamante).
rm -f "$ROOT/ui.log"; capture_warn; capture_info
KERNEL_TREE=cachyos; TREE_FORCE_NOTE="lo fuerza el parche/scheduler 'bmq'"
CACHYOS_TAGREL=""
confirm_newer_release 7.2.6 7.2.8 >/dev/null 2>&1
if grep -q "aún no publica 7.2.8" "$ROOT/ui.log" 2>/dev/null; then
  rec ok "bmq sin 7.2.8 en el fork: avisa en vez de ofrecer la que aborta"
else
  rec fail "no avisó de que el fork no tiene 7.2.8 (log: $(cat "$ROOT/ui.log" 2>/dev/null || echo vacío))"
fi
if grep -q "Su última 7.2.x publicada es 7.2.7" "$ROOT/ui.log" 2>/dev/null; then
  rec ok "el aviso nombra la última 7.2.x del fork (7.2.7), accionable"
else
  rec fail "el aviso no nombró la última 7.2.x del fork (log: $(cat "$ROOT/ui.log" 2>/dev/null || echo vacío))"
fi
# 1b) Si lo solicitado ES la última del fork, no se repite el consejo.
rm -f "$ROOT/ui.log"; capture_warn; capture_info
confirm_newer_release 7.2.7 7.2.8 >/dev/null 2>&1
if grep -q "aún no publica 7.2.8" "$ROOT/ui.log" 2>/dev/null \
   && ! grep -q "Su última 7.2.x" "$ROOT/ui.log" 2>/dev/null; then
  rec ok "ya se pidió la última del fork: avisa sin repetir el consejo"
else
  rec fail "aconsejó de nuevo la versión ya solicitada (log: $(cat "$ROOT/ui.log" 2>/dev/null || echo vacío))"
fi
# 2) Con vanilla no se pregunta nada al fork (el árbol sí admite 7.2.8).
rm -f "$ROOT/ui.log"; capture_warn; capture_info
KERNEL_TREE=vanilla; TREE_FORCE_NOTE=""
: > "$ROOT/dl.log"
CACHYOS_TAGREL=""
confirm_newer_release 7.2.7 7.2.8 >/dev/null 2>&1
if [ "$(wc -l < "$ROOT/dl.log")" = "0" ] \
   && grep -q "release estable más nueva" "$ROOT/ui.log" 2>/dev/null; then
  rec ok "vanilla: la release más nueva se ofrece sin preguntar al fork"
else
  rec fail "vanilla se saltó la oferta o consultó el fork (log: $(cat "$ROOT/ui.log" 2>/dev/null || echo vacío))"
fi
# 3) Si el fork SÍ tiene la versión, la oferta sigue en pie (no la esconde).
download_file() {
  local url="$1" out="$2"
  case "$url" in
    *"releases?per_page=20") releases_json > "$out"; return 0 ;;
  esac
  return 1
}
rm -f "$ROOT/ui.log"; capture_warn; capture_info
KERNEL_TREE=cachyos; TREE_FORCE_NOTE="lo fuerza el parche/scheduler 'bmq'"
CACHYOS_TAGREL="1"
confirm_newer_release 7.2.7 7.2.8 >/dev/null 2>&1
if grep -q "sí publica 7.2.8 (cachyos-7.2.8-1)" "$ROOT/ui.log" 2>/dev/null \
   && ! grep -q "aún no publica" "$ROOT/ui.log" 2>/dev/null; then
  rec ok "fork con 7.2.8: la oferta sigue disponible y avisa de que es compilable"
else
  rec fail "con 7.2.8 en el fork se saltó la oferta (log: $(cat "$ROOT/ui.log" 2>/dev/null || echo vacío))"
fi
# 4) Check inconcluso (sin red): fail-open, no se esconde la opción.
download_file() { return 1; }
rm -f "$ROOT/ui.log"; capture_warn; capture_info
CACHYOS_TAGREL="1"
confirm_newer_release 7.2.7 7.2.8 >/dev/null 2>&1
if grep -q "No se pudo comprobar en el fork" "$ROOT/ui.log" 2>/dev/null \
   && ! grep -q "aún no publica" "$ROOT/ui.log" 2>/dev/null; then
  rec ok "fork inalcanzable: check inconcluso, no se afirma una ausencia falsa"
else
  rec fail "sin red: se afirmó la ausencia sin poder comprobarla (log: $(cat "$ROOT/ui.log" 2>/dev/null || echo vacío))"
fi
# 5) La consulta al fork no puede arrastrar su tagrel al flujo posterior.
if [ "$CACHYOS_TAGREL" = "1" ]; then
  rec ok "la consulta al fork no pisa CACHYOS_TAGREL del flujo principal"
else
  rec fail "CACHYOS_TAGREL quedó como '$CACHYOS_TAGREL' tras la consulta"
fi
# 6) Guardia estática: la comprobación no se puede volver a borrar en silencio.
if grep -q 'cachyos_release_tagrel "\$latest"' "$MOTOR" \
   && awk '/^confirm_newer_release\(\)/,/^}/' "$MOTOR" | grep -q 'KERNEL_TREE:-}" = "cachyos"'; then
  rec ok "confirm_newer_release sigue consultando al fork cuando el árbol es cachyos"
else
  rec fail "confirm_newer_release ya no consulta al fork antes de ofrecer la release"
fi
# 7) El árbol se decide antes de la pregunta (si no, KERNEL_TREE valdría "auto").
if awk '/^# v27.31.18: el árbol se decide ANTES/,0' "$MOTOR" \
     | sed -n '1,/^if \[ -n "\$VERSION" \]; then$/p' \
     | grep -q '^resolve_kernel_tree$'; then
  rec ok "resolve_kernel_tree se llama antes de preguntar por la release nueva"
else
  rec fail "resolve_kernel_tree ya no se decide antes de confirm_newer_release"
fi

printf '%s\n' "== cachyos_release_tagrel (v27.31.18): consulta sin abortar =="
download_file() {
  local url="$1" out="$2"
  case "$url" in
    *"releases?per_page=20") releases_json > "$out"; return 0 ;;
  esac
  return 1
}
if cachyos_release_tagrel 7.2.7; then
  [ "$CACHYOS_TAGREL" = "2" ] && [ "$CACHYOS_LATEST_MINOR" = "7.2.8" ] \
    && rec ok "consulta: tagrel máximo 2 y última de la línea 7.2.8 (sort -V, no la 7.2.7)" \
    || rec fail "consulta: tagrel=$CACHYOS_TAGREL latest=$CACHYOS_LATEST_MINOR"
else
  rec fail "consulta: 7.2.7 está en el JSON y no se resolvió"
fi
download_file() {
  local url="$1" out="$2"
  case "$url" in
    *"releases?per_page=20") fork_json_missing_728 "$out"; return 0 ;;
  esac
  return 1
}
if cachyos_release_tagrel 7.2.8; then
  rec fail "consulta: 7.2.8 no está en el fixture ausente y aun así se resolvió"
else
  if [ -z "$CACHYOS_TAGREL" ] && [ "$CACHYOS_FOUND_VIA" = "" ] && [ "$CACHYOS_API_OK" = "1" ] \
     && [ "$CACHYOS_LATEST_MINOR" = "7.2.7" ]; then
    rec ok "consulta: versión ausente -> rc=1, sin tagrel, sin fatal, última 7.2.x=7.2.7"
  else
    rec fail "consulta ausente: tagrel='$CACHYOS_TAGREL' via='$CACHYOS_FOUND_VIA' api='$CACHYOS_API_OK' latest='$CACHYOS_LATEST_MINOR'"
  fi
fi

printf '%s\n' "== apply_patch_plugin: guardia de árbol del fork (bmq sobre vanilla) =="
rm -rf "$SRC/kernel/sched"; mkdir -p "$SRC"
PATCHES_APPLIED=(); PATCH_ENABLE_ALL=(); PATCH_REBEL_ALL=(); PATCH_DISABLE_ALL=(); BORE_ENABLED=false
KERNEL_TREE=vanilla; DL_CALLED=0
printf 'config SCHED_BMQ\n--- a/init/Kconfig\n+++ b/init/Kconfig\n' > "$ROOT/patch-bmq.patch"
: > "$ROOT/dl.log"
if apply_patch_plugin bmq; then
  rec fail "bmq sobre árbol vanilla debía omitirse (fail-soft)"
else
  rec ok "bmq + árbol vanilla -> omitido con WARN (fail-soft)"
fi
[ "$DL_CALLED" = 0 ] && rec ok "guardia: no descargó nada" || rec fail "guardia descargó pese a omitir (DL_CALLED=$DL_CALLED)"
[ "${PATCHES_APPLIED[*]:-}" = "" ] && rec ok "guardia: bmq no se registró" || rec fail "guardia registró bmq: [${PATCHES_APPLIED[*]:-}]"
KERNEL_TREE=cachyos
rm -f -- "$ROOT/patch-bmq.patch"
# restaura el stub bueno de descarga para el resto del harness
download_file() { download_file_good "$@"; }
unset releases_json

printf '%s\n' "== apply_patch_plugin: forward-port embebido como fallback (v27.31.5) =="
# Escenario: el main upstream no aplica (LAST_SERVED=cachy -> dry-run rc=1) y el
# stub patch distingue el parche embebido por su marcador... pero el stub patch()
# DEL HARNESS decide por LAST_SERVED, no por contenido. Para ejercitar el camino
# embebido sin árbol real, se sustituye PATCH_EMBED_B64 por base64(gzip) de un
# parche con marcador único y se reemplaza patch() por uno que lee stdin:
#   - si el fichero contiene FORWARD-EMBED-TEST  -> aplica (rc=0)   [embebido]
#   - si no                                    -> rechaza (rc=1)  [main/upstream]
rm -rf "$SRC/kernel/sched"; mkdir -p "$SRC"
PATCHES_APPLIED=(); PATCH_ENABLE_ALL=(); PATCH_REBEL_ALL=(); PATCH_DISABLE_ALL=(); BORE_ENABLED=false
KERNEL_TREE=cachyos; DL_CALLED=0
patch() {
  local contenido
  IFS= read -r -d '' contenido || true
  case "$contenido" in
    *FORWARD-EMBED-TEST*) return 0 ;;
    *) return 1 ;;
  esac
}
patch_embed_b64_prjc_cachy() {
  printf 'config SCHED_BMQ\nFORWARD-EMBED-TEST\n--- a/init/Kconfig\n+++ b/init/Kconfig\n' \
    | gzip | base64 | tr -d '\n'
}
: > "$ROOT/dl.log"
if apply_patch_plugin bmq; then
  rec ok "fallback embebido: flujo completo aplica (embebido > upstream)"
else
  rec fail "fallback embebido debía aplicar (degrade upstream)"
fi
if grep -q 'FORWARD-EMBED-TEST' "$KERNEL_BUILD_ROOT/prjc-bmq-7.2.patch" 2>/dev/null; then
  rec ok "el parche real usado es el embebido (marcador presente en dest)"
else
  rec fail "el destino no contiene el parche embebido: [$(ls "$KERNEL_BUILD_ROOT" 2>/dev/null)]"
fi
[ "${PATCHES_APPLIED[*]:-}" = "bmq" ] && rec ok "bmq registrado tras camino embebido" || rec fail "PATCHES_APPLIED= [${PATCHES_APPLIED[*]:-}]"
# solo el main se descarga; el embebido NO toca la red y evita el upstream
[ "$DL_CALLED" -le 1 ] && rec ok "embebido evita descargas extra (DL_CALLED=$DL_CALLED)" || rec fail "descargas inesperadas (DL_CALLED=$DL_CALLED)"
# restaura el stub patch() del harness (decide por LAST_SERVED)
patch() {
  if [ "$LAST_SERVED" = "cachy" ]; then return 1; else return 0; fi
}
patch_embed_b64_prjc_cachy() {
  printf 'config SCHED_BMQ\n--- a/init/Kconfig\n+++ b/init/Kconfig\n' \
    | gzip | base64 | tr -d '\n'
}

printf '%s\n' "== patch_desc: skip por versión (ntsync / fsync) =="
VERSION_SAVE="$VERSION"
VERSION=7.2.6
patch_desc_ntsync
[ -n "${PATCH_SKIP_REASON:-}" ] && rec ok "ntsync 7.2 -> skip (mainline nativo)" || rec fail "ntsync 7.2 debía saltar"
VERSION=6.1.77
patch_desc_ntsync
[ -z "${PATCH_SKIP_REASON:-}" ] && rec ok "ntsync 6.1 -> aplica backport (sin skip)" || rec fail "ntsync 6.1 no debía saltar"
patch_desc_fsync
[ -z "${PATCH_SKIP_REASON:-}" ] && rec ok "fsync 6.1 -> aplica (futex_waitv)" || rec fail "fsync 6.1 saltó sin motivo"
VERSION=6.13
patch_desc_fsync
[ -z "${PATCH_SKIP_REASON:-}" ] && rec ok "fsync 6.13 -> aplica (últimos soportados)" || rec fail "fsync 6.13 saltó sin motivo"
patch_desc_ntsync
[ -n "${PATCH_SKIP_REASON:-}" ] && rec ok "ntsync 6.13 -> skip (mainline nativo)" || rec fail "ntsync 6.13 debía saltar"
VERSION=6.14
patch_desc_fsync
[ -n "${PATCH_SKIP_REASON:-}" ] && rec ok "fsync 6.14 -> skip (recomienda ntsync)" || rec fail "fsync 6.14 debía saltar"
VERSION="$VERSION_SAVE"

printf '%s\n' "== apply_patch_plugin: skip por versión (sin descargar, sin registrar) =="
VERSION=6.14
PATCHES_APPLIED=(); PATCH_DISABLE_ALL=(); DL_CALLED=0
if apply_patch_plugin ntsync; then
  rec fail "ntsync >= 6.10 debía degradar vanilla"
else
  [ "$DL_CALLED" = 0 ] && rec ok "ntsync: skip sin llamar a download_file" || rec fail "ntsync descargó pese a skip (DL_CALLED=$DL_CALLED)"
  [ "${PATCHES_APPLIED[*]:-}" = "" ] && rec ok "ntsync: no se registró" || rec fail "ntsync se registró"
fi
if apply_patch_plugin fsync; then
  rec fail "fsync >= 6.14 debía degradar vanilla"
else
  rec ok "fsync >= 6.14 degrada a vanilla (PATCHES_APPLIED=${PATCHES_APPLIED[*]:-})"
fi
VERSION="$VERSION_SAVE"

printf '%s\n' "== process_frag_file / apply_config_fragments (.frag v27.30.0) =="
export CIZEN_FRAGS_DIR="$ROOT/frags"
mkdir -p "$CIZEN_FRAGS_DIR" "$SRC/scripts"
cat > "$SRC/scripts/config" <<'FRAGCC_STUB'
#!/usr/bin/env bash
# stub de scripts/config: registra los argumentos y devuelve 0.
# Se ejecuta con cd al árbol, así que el log queda en $PWD (=$SRC).
printf '%s\n' "$*" >> scripts-config.log
exit 0
FRAGCC_STUB
chmod +x "$SRC/scripts/config"
cat > "$CIZEN_FRAGS_DIR/base.frag" <<'FRAG_BASE'
CONFIG_FOO=y
CONFIG_BAR=m
# CONFIG_BAZ is not set
CONFIG_ZAP=42
FRAG_BASE
: > "$SRC/scripts-config.log"
apply_config_fragments
grep -q -- '--enable FOO' "$SRC/scripts-config.log" 2>/dev/null \
  && rec ok "frag: CONFIG_FOO=y -> --enable FOO" || rec fail "FOO=y no aplicado"
grep -q -- '--module BAR' "$SRC/scripts-config.log" 2>/dev/null \
  && rec ok "frag: CONFIG_BAR=m -> --module BAR" || rec fail "BAR=m no aplicado"
grep -q -- '--disable BAZ' "$SRC/scripts-config.log" 2>/dev/null \
  && rec ok "frag: '# CONFIG_BAZ is not set' -> --disable BAZ" || rec fail "BAZ no deshabilitado"
grep -q -- '--set-val ZAP 42' "$SRC/scripts-config.log" 2>/dev/null \
  && rec ok "frag: CONFIG_ZAP=42 -> --set-val ZAP 42" || rec fail "ZAP no como valor"
cat > "$CIZEN_FRAGS_DIR/main.frag" <<'FRAG_MAIN'
#include base.frag
CONFIG_EXTRA=y
FRAG_MAIN
: > "$SRC/scripts-config.log"
apply_config_fragments
grep -q -- '--enable EXTRA' "$SRC/scripts-config.log" 2>/dev/null \
  && rec ok "frag: include resuelto desde CIZEN_FRAGS_DIR" || rec fail "include base.frag no se resolvió"
grep -q -- '--enable FOO' "$SRC/scripts-config.log" 2>/dev/null \
  && rec ok "frag: directivas del include aplicadas" || rec fail "directivas del include ausentes"
export CIZEN_FRAGS_DIR="$ROOT/no-existe"
apply_config_fragments && rec ok "frag: sin directorio -> no-op rc=0" || rec fail "sin frag-dir debía ser no-op"
unset CIZEN_FRAGS_DIR

printf '%s\n' "== apply_cachy_misc_patchset: splitting del CIZEN_CACHY_PATCH_SET (fix 2026-09-24) =="
download_file() { download_file_good "$@"; }
printf 'diff --git a/init/Kconfig b/init/Kconfig\n--- a/init/Kconfig\n+++ b/init/Kconfig\n' > "$ROOT/patch-misc.patch"
export CIZEN_CACHY_PATCHES=1
export CIZEN_CACHY_PATCH_SET="acpi-call rt-i915"
: > "$ROOT/dl.log"
apply_cachy_misc_patchset
grep -q "misc/0001-acpi-call.patch" "$ROOT/dl.log" 2>/dev/null \
  && rec ok "cachy: intentó acpi-call (splitting correcto)" || rec fail "cachy: acpi-call no se intentó (splitting roto)"
grep -q "misc/0001-rt-i915.patch" "$ROOT/dl.log" 2>/dev/null \
  && rec ok "cachy: intentó rt-i915 (splitting correcto)" || rec fail "cachy: rt-i915 no se intentó"
grep -qE "misc/0001-(nap|reflex)-governor" "$ROOT/dl.log" 2>/dev/null \
  && rec fail "cachy: set por defecto ya no debe usar nap/reflex (retirados)" || rec ok "cachy: sin referencias a nap/reflex"
unset CIZEN_CACHY_PATCH_SET
: > "$ROOT/dl.log"
apply_cachy_misc_patchset
grep -q "misc/0001-acpi-call.patch" "$ROOT/dl.log" 2>/dev/null \
  && rec ok "cachy: default (sin CIZEN_CACHY_PATCH_SET) = acpi-call" || rec fail "cachy: default no intentó acpi-call"
unset CIZEN_CACHY_PATCHES

printf '%s\n' "== _misc_extract_kconfig_symbols + apply_cachy_misc_symbols (auto-enable del CONFIG que el parche introduce) =="
cat > "$ROOT/patch-kconfig-syms.patch" <<'EOF'
diff --git a/drivers/platform/x86/Kconfig b/drivers/platform/x86/Kconfig
--- a/drivers/platform/x86/Kconfig
+++ b/drivers/platform/x86/Kconfig
@@ -1,3 +1,8 @@
+config ACPI_CALL
+	tristate "ACPI Call"
+	boolconn
+config CIZEN_BOOL
+	bool "Cizen bool"
+menuconfig CIZEN_MENU
+	bool "menu"
+config CIZEN_INNER
+	def_bool y
EOF
SYMS_OK=$(_misc_extract_kconfig_symbols "$ROOT/patch-kconfig-syms.patch" | sort)
EXPECTED_SYMS=$'ACPI_CALL=m\nCIZEN_BOOL=y\nCIZEN_INNER=y'
[ "$SYMS_OK" = "$EXPECTED_SYMS" ] \
  && rec ok "cachy: extrae símbolos y tipo (ACPI_CALL=m, CIZEN_BOOL=y, CIZEN_INNER=y)" \
  || rec fail "cachy: extracción de símbolos inesperada: [$SYMS_OK]"
mkdir -p "$ROOT/src/scripts"
cat > "$ROOT/src/scripts/config" <<'EOF'
#!/bin/bash
echo "$*" >> "$ROOT/config-calls.log"
exit 0
EOF
chmod +x "$ROOT/src/scripts/config"
: > "$ROOT/config-calls.log"
CACHY_MISC_SYMBOLS=(ACPI_CALL=m CIZEN_BOOL=y CIZEN_INNER=y)
apply_cachy_misc_symbols
grep -q -- "--module ACPI_CALL" "$ROOT/config-calls.log" \
  && rec ok "cachy: apply_cachy_misc_symbols habilita ACPI_CALL como módulo" \
  || rec fail "cachy: ACPI_CALL no se habilitó como módulo"
grep -q -- "--enable CIZEN_BOOL" "$ROOT/config-calls.log" \
  && rec ok "cachy: apply_cachy_misc_symbols habilita CIZEN_BOOL como builtin" \
  || rec fail "cachy: CIZEN_BOOL no se habilitó"
grep -q -- "--enable CIZEN_INNER" "$ROOT/config-calls.log" \
  && rec ok "cachy: CIZEN_INNER (def_bool) como builtin" \
  || rec fail "cachy: CIZEN_INNER no se habilitó"
CACHY_MISC_SYMBOLS=()
apply_cachy_misc_symbols
[ ! -s "$ROOT/config-calls.log" ] \
  && rec fail "cachy: apply_cachy_misc_symbols sin símbolos no debe tocar scripts/config" \
  || rec ok "cachy: con lista vacía no toca scripts/config"
rm -f -- "$ROOT/src/scripts/config" "$ROOT/src/scripts/.." >/dev/null 2>&1 || true
rm -f -- "$ROOT/config-calls.log" "$ROOT/patch-kconfig-syms.patch"
unset SYMS_OK EXPECTED_SYMS

printf '%s\n' "== apply_cachy_misc_single: recolecta símbolos tras aplicar (end-to-end) =="
printf 'diff --git a/aaa b/aaa\nindex 0000000..1111111\n--- /dev/null\n+++ b/cachy-dummy\n@@ -0,0 +1,2 @@\n+config ACPI_CALL\n+\ttristate "ACPI Call"\n' > "$ROOT/patch-misc.patch"
: > "$ROOT/dl.log"
CACHY_MISC_SYMBOLS=()
download_file() { download_file_good "$@"; }
CIZEN_CACHY_PATCHES=1
apply_cachy_misc_single "7.2" "acpi-call"
cnt="${#CACHY_MISC_SYMBOLS[@]}"
[ "$cnt" -ge 1 ] && printf '%s\n' "${CACHY_MISC_SYMBOLS[@]}" | grep -q "^ACPI_CALL=m$" \
  && rec ok "cachy: al aplicar recolectó ACPI_CALL=m" \
  || rec fail "cachy: no recolectó símbolos al aplicar (array=[${CACHY_MISC_SYMBOLS[*]:-}] )"
rm -f -- "$SRC/cachy-dummy"
CACHY_MISC_SYMBOLS=()
unset CIZEN_CACHY_PATCHES

printf '%s\n' "== secure_boot_guided_setup: guarda final de pendientes (fix 2026-09-24) =="
# Stubs del marco sbctl/BIOS para aislar el setup guiado.
ask_user_yes(){ return 0; }
sbctl_keys_present(){ return 0; }
sbctl_setup_mode(){ [ "$SB_SCENARIO" = pending ] && return 0; return 1; }
sbctl_pk_enrolled(){ [ "$SB_SCENARIO" = pending ] && return 1; return 0; }
sbctl_enroll_keys(){ [ "$SB_SCENARIO" = pending ] && return 1; return 0; }
collect_systemd_boot_targets(){ printf '%s\n' "$ROOT/systemd-bootx64.efi"; }
: > "$ROOT/systemd-bootx64.efi"
cizen_uki_sign_targets_verify(){ [ "$SB_SCENARIO" = pending ] && return 1; return 0; }
cizen_uki_sign_targets(){ [ "$SB_SCENARIO" = pending ] && return 1; return 0; }
secure_boot_active(){ return 0; }
secure_boot_bios_guide(){ :; }
SB_SCENARIO=all_ok
if secure_boot_guided_setup; then
  rec ok "cadena completa (claves/enroll/boot firmado) -> rc=0, no aborta"
else
  rec fail "cadena completa abortaba (bug guarda invertida)"
fi
SB_SCENARIO=pending
if secure_boot_guided_setup; then
  rec fail "pasos pendientes debían abortar (fail-closed)"
else
  rec ok "pasos pendientes -> rc=1 (fail-closed)"
fi
SB_SCENARIO=all_ok
unset SB_SCENARIO

printf '%s\n' "== orden definición vs llamada en el flujo principal (fix luks_fde_audit) =="
for _fn in uki_backup_prev module_sign_installed luks_fde_audit apply_cachy_misc_symbols; do
  _def="$(grep -nE "^${_fn}\(\)" "$MOTOR" | cut -d: -f1 | head -1)"
  _call="$(grep -nE "^[[:space:]]*${_fn}[[:space:]]*$" "$MOTOR" | cut -d: -f1 | head -1)"
  if [ -n "$_def" ] && [ -n "$_call" ] && [ "$_call" -gt "$_def" ]; then
    rec ok "${_fn}: definición (L$_def) antes de la llamada (L$_call)"
  else
    rec fail "${_fn}: orden inválido def=[$_def] call=[$_call]"
  fi
done
unset _fn _def _call

printf '%s\n' "== compilador de preferencia (--cc): familias, versiones y rutas (_resolve_cc_compiler) =="
CIZEN_CC=auto; CIZEN_LLVM_LTO=0; CLANG_REQUESTED=false; _resolve_cc_compiler
[ "$CC_FAMILY" = gcc ] && [ "$CC_LAUNCHER" = gcc ] && [ "$CLANG_REQUESTED" = false ] \
  && rec ok "auto sin LTO -> GCC (launcher gcc, CLANG_REQUESTED=false)" \
  || rec fail "auto sin LTO -> esperaba gcc/gcc/false (got $CC_FAMILY/$CC_LAUNCHER/$CLANG_REQUESTED)"
CIZEN_CC=auto; CIZEN_LLVM_LTO=thin; CLANG_REQUESTED=false; _resolve_cc_compiler
[ "$CC_FAMILY" = clang ] && [ "$CC_LAUNCHER" = clang ] && [ "$CLANG_REQUESTED" = true ] \
  && rec ok "auto con LTO -> clang (LLVM=1)" \
  || rec fail "auto+LTO -> esperaba clang/clang/true (got $CC_FAMILY/$CC_LAUNCHER)"
CIZEN_CC=gcc; CIZEN_LLVM_LTO=thin; CLANG_REQUESTED=true; _resolve_cc_compiler
[ "$CC_FAMILY" = gcc ] && [ "$CLANG_REQUESTED" = false ] \
  && rec ok "gcc explícito gana sobre --clang/LTO previos (CLANG_REQUESTED=false)" \
  || rec fail "gcc explícito -> esperaba gcc/false (got $CC_FAMILY/$CLANG_REQUESTED)"
CIZEN_CC=clang; CIZEN_LLVM_LTO=0; CLANG_REQUESTED=false; _resolve_cc_compiler
[ "$CC_FAMILY" = clang ] && [ "$CC_LAUNCHER" = clang ] && [ "$CLANG_REQUESTED" = true ] \
  && rec ok "clang -> familia clang, launcher clang, CLANG_REQUESTED=true" \
  || rec fail "clang -> esperaba clang/clang/true (got $CC_FAMILY/$CC_LAUNCHER)"
CIZEN_CC=gcc-14; CIZEN_LLVM_LTO=0; CLANG_REQUESTED=true; _resolve_cc_compiler
[ "$CC_FAMILY" = gcc ] && [ "$CC_LAUNCHER" = "gcc-14" ] \
  && rec ok "gcc-14 -> familia gcc, launcher gcc-14, gana sobre --clang" \
  || rec fail "gcc-14 -> esperaba gcc/gcc-14 (got $CC_FAMILY/$CC_LAUNCHER)"
CIZEN_CC=gcc14; CLANG_REQUESTED=false; _resolve_cc_compiler
[ "$CC_FAMILY" = gcc ] && [ "$CC_LAUNCHER" = gcc14 ] \
  && rec ok "gcc14 (sin guion) -> familia gcc, launcher gcc14" \
  || rec fail "gcc14 -> esperaba gcc/gcc14 (got $CC_FAMILY/$CC_LAUNCHER)"
CIZEN_CC=clang-17; CLANG_REQUESTED=false; _resolve_cc_compiler
[ "$CC_FAMILY" = clang ] && [ "$CC_LAUNCHER" = "clang-17" ] && [ "$CLANG_REQUESTED" = true ] \
  && rec ok "clang-17 -> familia clang, launcher clang-17, CLANG_REQUESTED=true" \
  || rec fail "clang-17 -> esperaba clang/clang-17/true (got $CC_FAMILY/$CC_LAUNCHER)"
CIZEN_CC=/opt/toolchain/llvm/bin/clang-custom; CLANG_REQUESTED=false; _resolve_cc_compiler
[ "$CC_FAMILY" = clang ] && [ "$CC_LAUNCHER" = "/opt/toolchain/llvm/bin/clang-custom" ] \
  && rec ok "ruta con basename clang -> familia clang (LLVM)" \
  || rec fail "ruta clang -> esperaba clang/launcher (got $CC_FAMILY/$CC_LAUNCHER)"
CIZEN_CC=afl-gcc-fast; _resolve_cc_compiler
[ "$CC_FAMILY" = gcc ] && [ "$CC_LAUNCHER" = afl-gcc-fast ] \
  && rec ok "binario afl-gcc-fast -> familia gcc" \
  || rec fail "afl-gcc-fast -> esperaba gcc (got $CC_FAMILY)"
unset CC_FAMILY CC_LAUNCHER
CIZEN_CC=zapache; CLANG_REQUESTED=false; _resolve_cc_compiler
[ -z "${CC_FAMILY:-}" ] \
  && rec ok "nombre sin gcc/clang (zapache) -> fatal (familia sin clasificar)" \
  || rec fail "zapache -> esperaba fatal con CC_FAMILY vacío (got $CC_FAMILY)"

printf '%s\n' "== clang/lld como dependencias OBLIGATORIAS según el compilador elegido =="
if grep -q 'tools+=(ld.lld llvm-ar llvm-nm llvm-objcopy llvm-strip llvm-objdump llvm-readelf)' "$MOTOR" && grep -Fq '"$CC_LAUNCHER" = "clang" ] && tools+=(clang)' "$MOTOR"; then
  rec ok "check_prerequisites exige la toolchain LLVM completa (ld.lld + llvm-* + clang genérico)"
else
  rec fail "check_prerequisites: falta la exigencia por familia (ld.lld / clang genérico)"
fi
if grep -q 'missing_pkgs+=("${_ccb//-/}")' "$MOTOR"; then
  rec ok "compilador versionado ausente -> paquete Arch homónimo (gcc-14 -> gcc14)"
else
  rec fail "versiones: falta derivar el paquete homónimo del basename"
fi
if grep -Fq '[ld.lld]=lld' "$MOTOR"; then
  rec ok "TOOL_PKG mapea ld.lld -> lld (autoinstalación 'sudo pacman -S lld')"
else
  rec fail "TOOL_PKG: falta '[ld.lld]=lld'"
fi
if grep -q 'sin clang/lld instalados; se ignora el LTO'; then
  rec fail "LTO ya no debe degradar/ignorarse por faltar clang/lld (rama eliminada)"
else
  rec ok "LTO con clang/lld ausentes ya no se ignora; se exige la toolchain"
fi
if grep -q 'se degrada a GCC (sudo pacman -S clang lld)'; then
  rec fail "--clang ya no debe degradar a GCC (rama eliminada)"
else
  rec ok "--clang sin toolchain ya no degrada a gcc (fatal en su lugar)"
fi
if grep -q 'Nunca se degrada' "$MOTOR"; then
  rec ok "check_prerequisites documenta que la elección del compilador es vinculante"
else
  rec fail "check_prerequisites: falta la sanidad/documentación de la elección vinculante"
fi
if grep -Fq '"$CIZEN_LLVM_LTO" != "0" ] && [ "$CC_FAMILY" = "gcc" ]; then' "$MOTOR"; then
  rec ok "sanity LTO usa CC_FAMILY (gcc elegido -> se ignora el LTO)"
else
  rec fail "sanity LTO: falta la guarda por familia"
fi
if grep -q '"CC=ccache $CC_LAUNCHER"' "$MOTOR"; then
  rec ok "make usa CC/HOSTCC=ccache $""CC_LAUNCHER (tu compilador con ccache)"
else
  rec fail "make: falta la emisión con CC_LAUNCHER bajo ccache"
fi
if grep -q "'CC=ccache gcc'"; then
  rec fail "queda hardcode 'CC=ccache gcc' (debería ser $CC_LAUNCHER)"
else
  rec ok "no queda hardcode 'CC=ccache gcc' en la emisión de make"
fi

if grep -q 'declare -a PATCH_RETIRED_ALL=()' "$MOTOR"; then
  rec ok "motor declara PATCH_RETIRED_ALL (símbolos imposibles con SCHED_ALT)"
else
  rec fail "motor: falta 'PATCH_RETIRED_ALL'"
fi
if grep -q 'PATCH_RETIRED_SYMBOLS=()' "$MOTOR"; then
  rec ok "_patch_desc_scheduler_base declara PATCH_RETIRED_SYMBOLS vacío por defecto"
else
  rec fail "_patch_desc_scheduler_base: falta PATCH_RETIRED_SYMBOLS por defecto"
fi
if grep -q 'PATCH_RETIRED_SYMBOLS=(PSI PSI_DEFAULT_DISABLED SCHED_AUTOGROUP NUMA_BALANCING SCHED_CACHE)' "$MOTOR"; then
  rec ok "bmq/pds/lfbmq retiran PSI/PSI_DEFAULT_DISABLED/SCHED_AUTOGROUP/NUMA_BALANCING/SCHED_CACHE"
else
  rec fail "descriptor bmq/pds/lfbmq: falta la lista de símbolos retirados"
fi

if grep -q '\$\{[A-Za-z0-9_]*\[@\]:-' "$MOTOR"; then
  rec fail "motor: hay bad substitution \${#arr[@]:-...} (no válido en bash; usó culpa en validate_config v27.31.6)"
else
  rec ok "motor sin bad substitution \${#arr[@]:-...} (pattern detectado en v27.31.6)"
fi

printf '%s\n' "== build_effective_arrays: símbolos retirados por el scheduler alternativo (v27.31.6) =="
declare -a EFF_ENABLE=() EFF_DISABLE=() EFF_CRITICAL=()
declare -A EFF_SETVAL=() EFF_SETSTR=()
declare -A APPLIED_RENAMES=()
declare -A SEEN_ENABLE=() SEEN_DISABLE=() SEEN_CRITICAL=()
OPTS_ENABLE=(DEBUG_INFO SCHED_AUTOGROUP)
CRITICAL_OPTS=(SCHED_AUTOGROUP X86_NATIVE_CPU)
unset OPTS_SETVAL OPTS_SETSTR OPTS_DISABLE
declare -A OPTS_SETVAL=([PSI]="y" [PSI_DEFAULT_DISABLED]="n" [HZ]="1000")
declare -A OPTS_SETSTR=()
declare -A EXPECTED_REBEL_SET=()
declare -A PATCH_KCONFIG_FILTER=()
PATCH_DISABLE_ALL=()
PATCH_RETIRED_ALL=(PSI PSI_DEFAULT_DISABLED SCHED_AUTOGROUP)
PATCH_ENABLE_ALL=()
PATCH_REBEL_ALL=()
BTF_REQUESTED=false
build_effective_arrays
_contains_ok=true
for __x in PSI PSI_DEFAULT_DISABLED SCHED_AUTOGROUP; do
  case " ${EFF_ENABLE[*]:-} ${EFF_CRITICAL[*]:-} ${!EFF_SETVAL[*]:-} ${!EFF_SETSTR[*]:-} " in
    *" $__x "*) _contains_ok=false;;
  esac
done
unset __x
if [ "$_contains_ok" = true ]; then
  rec ok "símbolos retirados desaparecen de EFF_ENABLE/EFF_CRITICAL/EFF_SETVAL"
else
  rec fail "un símbolo retirado sigue exigido en los arrays efectivos"
fi
unset _contains_ok
if [ "${#EFF_CRITICAL[@]}" = 1 ] && [ "${EFF_CRITICAL[0]}" = X86_NATIVE_CPU ]; then
  rec ok "EFF_CRITICAL conserva solo el símbolo realizable (SCHED_AUTOGROUP retirado)"
else
  rec fail "EFF_CRITICAL inesperado tras retiro: ${EFF_CRITICAL[*]:-}"
fi
# _contains_ok=${#...}; retirados de SETVAL
if [ -z "${EFF_SETVAL[PSI]+x}" ] && [ -z "${EFF_SETVAL[PSI_DEFAULT_DISABLED]+x}" ]; then
  rec ok "PSI y PSI_DEFAULT_DISABLED retirados de EFF_SETVAL"
else
  rec fail "SETVAL mantiene símbolos retirados: ${!EFF_SETVAL[*]}"
fi
# check_profile_contradictions no debe fatal con el retiro
if check_profile_contradictions 2>/dev/null; then
  rec ok "check_profile_contradictions tolera el retiro (sin falsa contradicción)"
else
  rec fail "check_profile_contradictions rompió tras retirar símbolos"
fi

if grep -Fq 'tools+=(ld.lld llvm-ar llvm-nm llvm-objcopy llvm-strip llvm-objdump llvm-readelf)' "$MOTOR"; then
  rec ok "familia clang exige ld.lld + llvm-* completos (LLVM=1 usa llvm-ar/nm/objcopy/strip/objdump/readelf)"
else
  rec fail "check_prerequisites: con clang faltaba la toolchain llvm-* completa (paquete llvm)"
fi
if grep -Fq '[llvm-ar]=llvm' "$MOTOR" && grep -Fq '[llvm-nm]=llvm' "$MOTOR" && grep -Fq '[llvm-objcopy]=llvm' "$MOTOR" && grep -Fq '[llvm-strip]=llvm' "$MOTOR" && grep -Fq '[llvm-readelf]=llvm' "$MOTOR"; then
  rec ok "TOOL_PKG mapea la toolchain llvm-* -> llvm (autoinstalación 'sudo pacman -S llvm')"
else
  rec fail "TOOL_PKG: faltan mapeos llvm-* -> llvm"
fi

printf '%s\n' "== KCONFIG_CC_OPTS: las fases de preparación usan el compilador del build (v27.31.7) =="
if grep -q 'declare -a KCONFIG_CC_OPTS=()' "$MOTOR"; then
  rec ok "motor declara KCONFIG_CC_OPTS (opts de CC para fases Kconfig)"
else
  rec fail "KCONFIG_CC_OPTS: falta la declaración del array"
fi
if grep -qE 'CC_FAMILY" = "clang"' "$MOTOR" && grep -Fq "KCONFIG_CC_OPTS+=('LLVM=1')" "$MOTOR"; then
  rec ok "KCONFIG_CC_OPTS (+=LLVM=1) cuando la familia es clang"
else
  rec fail "KCONFIG_CC_OPTS: falta la rama LLVM=1 para familia clang"
fi
if grep -q 'make "\${KCONFIG_CC_OPTS\[@\]}" olddefconfig' "$MOTOR"; then
  rec ok "run_kconfig_audit llama olddefconfig con KCONFIG_CC_OPTS (mismo CC que el build)"
else
  rec fail "run_kconfig_audit: olddefconfig sin KCONFIG_CC_OPTS"
fi
if grep -q 'make "\${KCONFIG_CC_OPTS\[@\]}" listnewconfig' "$MOTOR"; then
  rec ok "listnewconfig también ve el compilador del build"
else
  rec fail "listnewconfig sin KCONFIG_CC_OPTS"
fi
if grep -q 'make "\${KCONFIG_CC_OPTS\[@\]}" ARCH="\$karch" olddefconfig' "$MOTOR"; then
  rec ok "prepare_lite_config usa KCONFIG_CC_OPTS en su olddefconfig final"
else
  rec fail "lite: olddefconfig final sin KCONFIG_CC_OPTS"
fi
if grep -q 'make "\${KCONFIG_CC_OPTS\[@\]}" olddefconfig; then' "$MOTOR"; then
  rec ok "apply_patch_and_recheck usa KCONFIG_CC_OPTS al re-configurar con parche"
else
  rec fail "apply_patch_and_recheck: olddefconfig sin KCONFIG_CC_OPTS"
fi

if grep -q 'CIZEN_MODPROBED_DB="\${CIZEN_MODPROBED_DB:-1}"' "$MOTOR"; then
  rec ok "modprobed-db: default auto-descubrimiento (base instalada)"
else
  rec fail "modprobed-db: default sigue desactivado (CIZEN_MODPROBED_DB:-0)"
fi

if grep -q 'yay -S modprobed-db' "$MOTOR" && grep -q 'CIZEN_MODPROBED_DB:-1.*command -v modprobed-db' "$MOTOR"; then
  rec ok "modprobed-db: dependencia requerida con sugerencia yay -S modprobed-db"
else
  rec fail "modprobed-db: no se exige como requerida ni se sugiere yay"
fi

if grep -q '(--no-modprobed-db) la exime' "$MOTOR"; then
  rec ok "modprobed-db: --no-modprobed-db exime la obligatoriedad"
else
  rec fail "modprobed-db: falta la exención explícita (--no-modprobed-db)"
fi

if grep -qE '"\$_pf_uid" = "0"' "$MOTOR"; then
  rec ok "perfil: acepta propietario root o del usuario actual (instalación con sudo)"
else
  rec fail "perfil: el check sigue exigiendo solo el uid del usuario actual"
fi

# Orden de definiciones: bash ejecuta el archivo secuencialmente, así que una
# llamada top-level a una función definida más abajo aborta con "orden no
# encontrada" aunque `bash -n` pase. Pasó dos veces: v27.31.13 con
# collect_build_artifact y v27.31.17 con kernel_version_ge (además dentro de un
# `! ...`, donde el 127 no abortaba pero invertía la decisión: ntsync se
# añadía a TODOS los kernels). Texto en dos pasadas: definiciones, luego
# llamadas del flujo principal. Se examina toda la línea, no solo $1, para
# pillar también las llamadas dentro de condiciones (`if ! f ...`, `x && f`).
find_late_calls() {
  # sq = comilla simple (el programa awk va entrecomillado simple: no puede
  # llevar comillas simples dentro).
  local sq="'"
  awk -v sq="$sq" '
    FNR == NR {
      if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/) {
        n = $0; sub(/\(\)[ \t]*\{.*$/, "", n)
        if (!(n in def)) def[n] = FNR
      }
      next
    }
    $0 ~ /^#/ || $0 ~ /^[[:space:]]/ { next }
    {
      line = $0
      gsub(/"[^"]*"/, "", line); gsub(sq "[^" sq "]*" sq, "", line)   # fuera las cadenas
      # Solo interesan los nombres que SON funciones definidas en el fichero
      # (así no hay falsos positivos con cualquier palabra) y solo si la
      # definición está por debajo. En shell una llamada no lleva paréntesis:
      # `! kernel_version_ge "$v" 6.10` es una llamada igual que `f(x)`.
      for (name in def) {
        if (FNR >= def[name]) continue
        if (line ~ ("(^|[^A-Za-z0-9_])" name "([^A-Za-z0-9_]|$)"))
          print name " (línea " FNR ", def " def[name] ")"
      }
    }
  ' "$1" "$1" | sort -u
}
_late_calls="$(find_late_calls "$MOTOR")"
if [ -z "$_late_calls" ]; then
  rec ok "orden de funciones: ninguna llamada top-level anterior a su definición"
else
  rec fail "orden de funciones: llamadas top-level antes de su def -> $(printf '%s; ' $_late_calls)"
fi
# El detector no puede ser vacuo: con el mismo análisis, un fichero que llama
# antes de definir SÍ tiene que aparecer.
printf 'tope() {\n  :\n}\nif ! helper; then\n  tope\nfi\nhelper() {\n  :\n}\n' > "$ROOT/late.sh"
if [ -n "$(find_late_calls "$ROOT/late.sh")" ]; then
  rec ok "detector de orden: detecta también llamadas dentro de condiciones"
else
  rec fail "detector de orden: no ve una llamada claramente tardía (test inútil)"
fi
# Y el ntsync automático: solo para kernels sin soporte nativo.
declare -a _pn=()
PATCH_NAMES=(); VERSION=7.2.7; CIZEN_PATCH_NTSYNC=0; auto_add_ntsync_patch
[ "${PATCH_NAMES[*]:-}" = "" ] && rec ok "ntsync: 7.2.7 (soporte nativo) no añade el parche" \
  || rec fail "ntsync: 7.2.7 añadió '${PATCH_NAMES[*]:-}'"
CIZEN_PATCH_NTSYNC=1
PATCH_NAMES=(); VERSION=6.9.1; auto_add_ntsync_patch
[ "${PATCH_NAMES[*]:-}" = "ntsync" ] && rec ok "ntsync: 6.9.1 (sin soporte nativo) añade el parche" \
  || rec fail "ntsync: 6.9.1 no añadió el parche"
PATCH_NAMES=(bmq); VERSION=6.9.1; auto_add_ntsync_patch
[ "${PATCH_NAMES[*]:-}" = "bmq ntsync" ] && rec ok "ntsync: se añade sin pisar el scheduler elegido" \
  || rec fail "ntsync: '${PATCH_NAMES[*]:-}'"
PATCH_NAMES=(ntsync); VERSION=6.9.1; auto_add_ntsync_patch
[ "${PATCH_NAMES[*]:-}" = "ntsync" ] && rec ok "ntsync: no se duplica si ya está pedido" \
  || rec fail "ntsync: duplicado ('${PATCH_NAMES[*]:-}')"
PATCH_NAMES=(); VERSION=6.9.1; CIZEN_PATCH_NTSYNC=0; auto_add_ntsync_patch
[ "${PATCH_NAMES[*]:-}" = "" ] && rec ok "ntsync: CIZEN_PATCH_NTSYNC=0 lo desactiva" \
  || rec fail "ntsync: CIZEN_PATCH_NTSYNC=0 no lo desactiva"
PATCH_NAMES=(); VERSION=""; CIZEN_PATCH_NTSYNC=0; auto_add_ntsync_patch
[ "${PATCH_NAMES[*]:-}" = "" ] && rec ok "ntsync: sin VERSION (--check-update) no decide nada" \
  || rec fail "ntsync: sin VERSION añadió '${PATCH_NAMES[*]:-}'"

# --- kernel-update-menu.sh: aviso de versión ausente en el fork (v27.31.16) ---
# El menú avisa antes de compilar cuando la stable de kernel.org todavía no
# está publicada en CachyOS/linux (ahí es donde viven pds/bmq/lfbmq/muqss).
MENU="$(dirname "$MOTOR")/kernel-update-menu.sh"
if [ -r "$MENU" ]; then
  bash -n "$MENU" 2>/dev/null \
    && rec ok "menú: bash -n limpio" \
    || rec fail "menú: no pasa bash -n"
  sed -n '/^load_fork_tags() {/,/^}/p; /^fork_tagrel() {/,/^}/p; /^fork_latest_minor() {/,/^}/p' \
    "$MENU" > "$ROOT/menufns.sh"
  if [ -s "$ROOT/menufns.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    source "$ROOT/menufns.sh"
    _ft() { FORK_TAGS="$1"; shift; "$@" 2>/dev/null; }
    _tags_real='cachyos-7.2.7-1
cachyos-7.2.7-2
cachyos-7.3-rc4-1
cachyos-7.2.6-1
cachyos-6.18.52-1'
    if [ -z "$(_ft "$_tags_real" fork_tagrel 7.2.8)" ] \
       && [ "$(_ft "$_tags_real" fork_tagrel 7.2.7)" = "2" ]; then
      rec ok "menú fork: 7.2.8 no existe (vacío) y 7.2.7 da el tagrel mayor (2)"
    else
      rec fail "menú fork: tagrel mal calculado (7.2.8='$(_ft "$_tags_real" fork_tagrel 7.2.8)' 7.2.7='$(_ft "$_tags_real" fork_tagrel 7.2.7)')"
    fi
    if [ "$(_ft "$_tags_real" fork_latest_minor 7.2.8)" = "7.2.7" ] \
       && [ -z "$(_ft "$_tags_real" fork_latest_minor 7.3.1)" ]; then
      rec ok "menú fork: fallback de la línea 7.2.x = 7.2.7 y 7.3 (solo rc) no inventa release"
    else
      rec fail "menú fork: fallback incorrecto (7.2.8 -> '$(_ft "$_tags_real" fork_latest_minor 7.2.8)', 7.3.1 -> '$(_ft "$_tags_real" fork_latest_minor 7.3.1)')"
    fi
    if [ -z "$(_ft "$_tags_real
cachyos-7.2.80-1" fork_tagrel 7.2.8)" ]; then
      rec ok "menú fork: 7.2.80 no se confunde con 7.2.8 (regex anclada)"
    else
      rec fail "menú fork: 7.2.80 se confundió con 7.2.8"
    fi
  else
    rec fail "menú: no se pudieron extraer load_fork_tags/fork_tagrel/fork_latest_minor"
  fi
  # Sin red el menú no debe avisar ni bloquear (fail-open), y la pregunta de la
  # versión alternativa solo se hace en terminal.
  if grep -q '\[ -n "\$tags" \] || return 1' "$MENU" \
     && grep -q 'CIZEN_MENU_SKIP_FORK_CHECK' "$MENU" \
     && grep -q 'FORK_TAGS_TTL' "$MENU" \
     && grep -q '\[ -t 0 \]' "$MENU"; then
    rec ok "menú fork: fail-open sin red, caché con TTL y pregunta solo en TTY"
  else
    rec fail "menú fork: falta el fail-open, la caché con TTL o la guarda de TTY"
  fi
else
  printf '  (sin %s: se omiten los tests del menú)\n' "$MENU"
fi

# --- identidad del árbol de fuentes y desmontaje inteligente (v27.31.17) ---
# El directorio del árbol solo lleva la versión, así que dos builds con
# distinto parche/scheduler (vanilla vs cachyos) o distinta versión pueden
# acabar en el mismo camino. Reutilizar el equivocado no falla de forma
# visible: o compila el kernel que no es, o revienta con ENOSPC a mitad.
printf '%s\n' "== source_tree_kind / tree_identity / source_tree_reusable =="
TREE_META_NAME=".cizen-tree"
CIZEN_KEEP_TMPFS=0
CIZEN_SMART_UMOUNT=1
TREE_FORCE_NOTE=""
TMPFS_MOUNTED=true
TMPFS_CREATED_BY_SCRIPT=false
TMPFS_ROOT="$ROOT/tmpfs"
rm -rf "$TMPFS_ROOT"; mkdir -p "$TMPFS_ROOT"
# El estado del "tmpfs" vive en ficheros, no en variables del shell: las
# funciones del motor lo consultan dentro de tuberías (subshell) y un contador
# en variable se perdería en cada "|".
MOUNTED_FLAG="$ROOT/tmpfs.mounted"
STACKED_FLAG="$ROOT/tmpfs.stacked"
BUSY_FLAG="$ROOT/tmpfs.busy"
: > "$MOUNTED_FLAG"; rm -f "$STACKED_FLAG" "$BUSY_FLAG"
findmnt() { # stub del tmpfs de pruebas: -M TARGET/FSTYPE, como findmnt -M real
  case "$*" in
    *FSTYPE*) [ -f "$MOUNTED_FLAG" ] || return 1; printf 'tmpfs\n'; return 0 ;;
    *TARGET*) [ -f "$MOUNTED_FLAG" ] || return 1
              local n i
              n="$(cat "$STACKED_FLAG" 2>/dev/null || echo 1)"
              i=0; while [ "$i" -lt "$n" ]; do printf '%s\n' "$TMPFS_ROOT"; i=$((i + 1)); done
              return 0 ;;
  esac
  command findmnt "$@"
}
sudo() { # stub: registra la llamada y "desmonta" de verdad (baja un montaje)
  case "$*" in
    *umount*) printf '%s\n' "$*" >> "$ROOT/umount.log"
              if [ -f "$BUSY_FLAG" ]; then return 1; fi
              if [ -f "$STACKED_FLAG" ]; then
                local n; n="$(cat "$STACKED_FLAG")"
                if [ "$n" -gt 1 ]; then echo $((n - 1)) > "$STACKED_FLAG"
                else rm -f "$STACKED_FLAG" "$MOUNTED_FLAG"; fi
              else
                rm -f "$MOUNTED_FLAG"
              fi ;;
  esac
  return 0
}

_mktree() { # $1=versión $2=tipo -> crea el árbol con su testigo
  local d="$TMPFS_ROOT/linux-$1" k="$2"
  mkdir -p "$d/kernel/sched"
  : > "$d/Makefile"; : > "$d/kernel/Makefile"
  [ "$k" = "cachyos" ] && : > "$d/kernel/sched/poc_selector.c"
  printf 'version=%s\nkind=%s\n' "$1" "$k" > "$d/$TREE_META_NAME"
  printf '%s' "$d"
}
SRC="$(_mktree 7.2.7 cachyos)"
VERSION=7.2.7
KERNEL_TREE=cachyos
source_tree_reusable && rec ok "árbol cachyos 7.2.7 reutilizable para un build cachyos 7.2.7" \
  || rec fail "árbol cachyos 7.2.7 debería ser reutilizable"
[ "$(tree_identity "$SRC")" = "7.2.7|cachyos" ] \
  && rec ok "identidad leída del testigo .cizen-tree" || rec fail "identidad: $(tree_identity "$SRC")"

VERSION=7.2.7; KERNEL_TREE=vanilla
! source_tree_reusable \
  && rec ok "el MISMO árbol no se reutiliza para un build vanilla (bmq es lo que fuerza cachyos)" \
  || rec fail "un árbol cachyos se reutilizó para vanilla: mezcla de árboles"
VERSION=7.2.8; KERNEL_TREE=cachyos
! source_tree_reusable && rec ok "otra versión tampoco es reutilizable" || rec fail "versión distinta reutilizada"
VERSION=7.2.7; KERNEL_TREE=cachyos
source_tree_reusable || rec fail "el árbol propio dejó de ser reutilizable"

# Sin testigo (árbol de una versión anterior de la herramienta): la identidad
# se deduce del árbol (kernel/sched/poc_selector.c = cachyos).
SRC="$TMPFS_ROOT/linux-7.2.9"; mkdir -p "$SRC/kernel/sched"
: > "$SRC/Makefile"; : > "$SRC/kernel/Makefile"
: > "$SRC/kernel/sched/poc_selector.c"
VERSION=7.2.9; KERNEL_TREE=cachyos
if [ "$(tree_identity "$SRC")" = "7.2.9|cachyos" ] && source_tree_reusable; then
  rec ok "árbol sin testigo: la identidad se deduce del propio árbol"
else
  rec fail "árbol sin testigo mal identificado: $(tree_identity "$SRC")"
fi
VERSION=7.2.7; KERNEL_TREE=cachyos

printf '%s\n' "== reconcile_tmpfs_trees: purga y desmontaje inteligente =="
# El caso real del usuario: hay un vanilla 7.2.8 en el tmpfs y se va a
# compilar 7.2.7 del fork (bmq). No se mezcla: se descarta y, como no queda
# nada aprovechable y el tmpfs no guarda nada más, se desmonta entero.
rm -rf "$TMPFS_ROOT"; mkdir -p "$TMPFS_ROOT"
: > "$MOUNTED_FLAG"; rm -f "$STACKED_FLAG" "$ROOT/umount.log"
SRC="$TMPFS_ROOT/linux-7.2.7"
_mktree 7.2.8 vanilla >/dev/null
TREE_FORCE_NOTE="lo fuerza el parche/scheduler 'bmq' (solo existe en el fork CachyOS/linux)"
reconcile_tmpfs_trees
if [ ! -d "$TMPFS_ROOT/linux-7.2.8" ] && grep -qE '^(-n )?umount ' "$ROOT/umount.log" \
   && [ "$TMPFS_MOUNTED" = false ] && [ ! -f "$MOUNTED_FLAG" ]; then
  rec ok "árbol vanilla incompatible: descartado y tmpfs desmontado (RAM devuelta)"
else
  rec fail "no se descartó/desmontó como se esperaba (umount.log: $(tr '\n' ' ' < "$ROOT/umount.log" 2>/dev/null))"
fi

# Con algo más que conservar en el tmpfs (p. ej. un paquete) NO se desmonta:
# solo se purgan los árboles que no sirven.
: > "$MOUNTED_FLAG"; TMPFS_MOUNTED=true; : > "$ROOT/umount.log"
_mktree 7.2.8 vanilla >/dev/null
: > "$TMPFS_ROOT/linux-7.2.7-cizen-v3-1-x86_64.pkg.tar.zst"
reconcile_tmpfs_trees
if [ ! -d "$TMPFS_ROOT/linux-7.2.8" ] && [ -f "$TMPFS_ROOT/linux-7.2.7-cizen-v3-1-x86_64.pkg.tar.zst" ] \
   && [ ! -s "$ROOT/umount.log" ] && [ "$TMPFS_MOUNTED" = true ]; then
  rec ok "con un paquete en el tmpfs: se purga el árbol pero no se desmonta"
else
  rec fail "no se respetó el paquete del tmpfs (umount.log: $(tr '\n' ' ' < "$ROOT/umount.log" 2>/dev/null))"
fi

# Si el árbol de este build es correcto, no se toca nada ni se desmonta.
rm -f "$TMPFS_ROOT"/*.pkg.tar.zst; : > "$ROOT/umount.log"; TMPFS_MOUNTED=true
SRC="$(_mktree 7.2.7 cachyos)"; _mktree 7.2.8 vanilla >/dev/null
reconcile_tmpfs_trees
if [ -d "$TMPFS_ROOT/linux-7.2.7" ] && [ ! -d "$TMPFS_ROOT/linux-7.2.8" ] \
   && [ ! -s "$ROOT/umount.log" ] && [ "$TMPFS_MOUNTED" = true ]; then
  rec ok "árbol propio reutilizable: se conserva y se purga el ajeno, sin desmontar"
else
  rec fail "el árbol reutilizable no se conservó (umount.log: $(tr '\n' ' ' < "$ROOT/umount.log" 2>/dev/null))"
fi

# CIZEN_SMART_UMOUNT=0 y CIZEN_KEEP_TMPFS=1: se purga dentro, sin desmontar.
for v in CIZEN_SMART_UMOUNT=0 CIZEN_KEEP_TMPFS=1; do
  rm -rf "$TMPFS_ROOT"; mkdir -p "$TMPFS_ROOT"
  : > "$MOUNTED_FLAG"; TMPFS_MOUNTED=true
  SRC="$TMPFS_ROOT/linux-7.2.7"; _mktree 7.2.8 vanilla >/dev/null
  : > "$ROOT/umount.log"
  if [ "$v" = "CIZEN_SMART_UMOUNT" ]; then CIZEN_SMART_UMOUNT=0; else CIZEN_KEEP_TMPFS=1; fi
  reconcile_tmpfs_trees
  if [ ! -d "$TMPFS_ROOT/linux-7.2.8" ] && [ ! -s "$ROOT/umount.log" ] && [ "$TMPFS_MOUNTED" = true ]; then
    rec ok "$v: purga en sitio sin desmontar"
  else
    rec fail "$v: comportamiento inesperado (umount.log: $(tr '\n' ' ' < "$ROOT/umount.log" 2>/dev/null))"
  fi
  unset "$v"
done
CIZEN_SMART_UMOUNT=1; CIZEN_KEEP_TMPFS=0

# Un árbol a medias (extracción interrumpida: tiene Makefile y su identidad,
# pero el testigo de "extrayéndose" sigue vivo) NO es reutilizable: si lo fuera,
# la siguiente build compilaría contra un árbol incompleto.
rm -rf "$TMPFS_ROOT"; mkdir -p "$TMPFS_ROOT"
: > "$MOUNTED_FLAG"; TMPFS_MOUNTED=true
SRC="$(_mktree 7.2.7 cachyos)"
VERSION=7.2.7; KERNEL_TREE=cachyos
source_tree_reusable || rec fail "el árbol completo dejó de ser reutilizable"
: > "$TMPFS_ROOT/.cizen-extracting-7.2.7"
! source_tree_reusable \
  && rec ok "árbol a medias (testigo de extracción vivo): no se reutiliza" \
  || rec fail "un árbol a medio extraer se reutilizaría"
: > "$ROOT/umount.log"
reconcile_tmpfs_trees
if [ ! -d "$TMPFS_ROOT/linux-7.2.7" ] && grep -qE '^(-n )?umount ' "$ROOT/umount.log" \
   && [ ! -e "$TMPFS_ROOT/.cizen-extracting-7.2.7" ]; then
  rec ok "el árbol a medias se descarta, se desmonta el tmpfs y vanish su testigo"
else
  rec fail "el árbol a medias no se descartó limpiamente (umount.log: $(tr '\n' ' ' < "$ROOT/umount.log" 2>/dev/null))"
fi

# El tmpfs sin montar no se toca (lo montará prepare_tmpfs_build).
rm -f "$MOUNTED_FLAG" "$ROOT/umount.log"; TMPFS_MOUNTED=false
mkdir -p "$TMPFS_ROOT/linux-7.2.8"; : > "$TMPFS_ROOT/linux-7.2.8/Makefile"
reconcile_tmpfs_trees
if [ ! -s "$ROOT/umount.log" ] && [ -d "$TMPFS_ROOT/linux-7.2.8" ]; then
  rec ok "tmpfs no montado: la reconciliación no toca nada"
else
  rec fail "la reconciliación actuó sin tmpfs montado"
fi

# El motor llama a la reconciliación antes del chequeo de espacio, y el margen
# de espacio se decide por identidad real, no por [ -d $SRC ].
if grep -q '^reconcile_tmpfs_trees$' "$MOTOR" \
   && [ "$(grep -c 'if source_tree_reusable; then' "$MOTOR")" -ge 3 ]; then
  rec ok "el motor reconcilia antes de check_build_memory y usa source_tree_reusable en los 3 márgenes de espacio"
else
  rec fail "faltan la llamada a reconcile_tmpfs_trees o el uso de source_tree_reusable en los márgenes de espacio"
fi

# --- montajes apilados: el umount tiene que devolver toda la RAM ---------
# Un umount interrumpido (proceso usando el tmpfs) deja montajes APILADOS en el
# mismo punto. findmnt -M devuelve una línea por montaje, así que sin head -n1
# las comparaciones veían "tmpfs\ntmpfs" y el motor se paraba con un error
# ilegible; y un solo umount no devolvía la RAM, que es justo lo que se busca.
: > "$MOUNTED_FLAG"; TMPFS_MOUNTED=true
echo 3 > "$STACKED_FLAG"
: > "$ROOT/umount.log"
# v27.31.19: el umount es `sudo -n` (no interactivo: nunca puede quedarse
# esperando una contraseña a mitad del build) y su stderr se conserva en
# TMPFS_UMOUNT_ERR en vez de descartarse, que es lo que escondía el EBUSY.
if tmpfs_umount_all && [ ! -f "$MOUNTED_FLAG" ] \
   && [ "$(grep -cE '^(-n )?umount ' "$ROOT/umount.log")" -eq 3 ] \
   && ! grep -qE '^umount ' "$ROOT/umount.log"; then
  rec ok "tmpfs_umount_all: desmonta también los apilados (3 umount, tmpfs limpio) y con sudo -n"
else
  rec fail "tmpfs_umount_all: log=$(tr '\n' ' ' < "$ROOT/umount.log" 2>/dev/null) stacked=$(cat "$STACKED_FLAG" 2>/dev/null || echo 0) montado=$([ -f "$MOUNTED_FLAG" ] && echo sí || echo no)"
fi
: > "$MOUNTED_FLAG"; TMPFS_MOUNTED=true; : > "$ROOT/umount.log"; : > "$BUSY_FLAG"
if ! tmpfs_umount_all && [ -f "$MOUNTED_FLAG" ]; then
  rec ok "tmpfs_umount_all: si está ocupado devuelve error en vez de forzar (-l)"
else
  rec fail "tmpfs_umount_all: no detectó el tmpfs ocupado"
fi
rm -f "$BUSY_FLAG"
# Y el resto de consultas a findmnt del tmpfs toman solo la primera línea.
_n_m="$(grep -c 'findmnt -n -M "\$TMPFS_ROOT"' "$MOTOR")"
_n_h="$(grep 'findmnt -n -M "\$TMPFS_ROOT"' "$MOTOR" | grep -c 'head -n1\|grep -c\|grep -q')"
if [ "$_n_m" = "$_n_h" ]; then
  rec ok "findmnt: las $_n_m consultas del TMPFS_ROOT toleran montajes apilados"
else
  rec fail "findmnt: $_n_h de $_n_m consultas del TMPFS_ROOT toman solo la primera línea"
fi
unset -f findmnt sudo

# ============================================================
# v27.31.19: scheduler efectivo, firma sched=, desmontaje post-éxito
# ============================================================
printf '%s\n' "== effective_scheduler (scheduler efectivo que se graba) =="
for _sch in bore pds bmq lfbmq muqss; do
  BORE_ENABLED=false
  declare -a PATCHES_APPLIED=("$_sch")
  if [ "$(effective_scheduler)" = "$_sch" ]; then
    rec ok "effective_scheduler: $_sch (pedido explícito) -> $_sch"
  else
    rec fail "effective_scheduler: $_sch dio $(effective_scheduler)"
  fi
done
BORE_ENABLED=true; declare -a PATCHES_APPLIED=()
[ "$(effective_scheduler)" = "bore" ] && rec ok "effective_scheduler: BORE_ENABLED sin parches -> bore" || rec fail "effective_scheduler: BORE_ENABLED dio $(effective_scheduler)"
BORE_ENABLED=false; declare -a PATCHES_APPLIED=("ntsync" "bore")
[ "$(effective_scheduler)" = "bore" ] && rec ok "effective_scheduler: bore dentro de PATCHES_APPLIED -> bore" || rec fail "effective_scheduler: parche bore dentro de la lista dio $(effective_scheduler)"
BORE_ENABLED=false; declare -a PATCHES_APPLIED=()
[ "$(effective_scheduler)" = "eevdf" ] && rec ok "effective_scheduler: sin nada aplicado -> eevdf (mainline)" || rec fail "effective_scheduler: vacío dio $(effective_scheduler)"
BORE_ENABLED=false; declare -a PATCHES_APPLIED=("ntsync")
[ "$(effective_scheduler)" = "eevdf" ] && rec ok "effective_scheduler: solo ntsync sigue siendo eevdf" || rec fail "effective_scheduler: solo ntsync dio $(effective_scheduler)"
# El nombre de la opción pedida no debe filtrarse: "inherit" se resuelve.
BORE_ENABLED=false; declare -a PATCHES_APPLIED=("bmq")
if effective_scheduler | grep -qx inherit; then
  rec fail "effective_scheduler: devolvió 'inherit' (no es comprobable)"
else
  rec ok "effective_scheduler: nunca devuelve 'inherit' (se graba el efectivo)"
fi
# La firma tiene que llevar sched= para que el verificador post-boot lo compare.
if grep -q "printf 'sched=%s\\\\n' \"\$(effective_scheduler)\"" "$MOTOR"; then
  rec ok "la firma del verificador graba sched= con el scheduler efectivo"
else
  rec fail "write_verify_signature no graba sched= con el scheduler efectivo"
fi

printf '%s\n' "== write_verify_signature: retired= (símbolos que el parche retira) =="
# v27.31.22: sin retired= en la firma, el verificador post-boot no puede saber que
# SCHED_AUTOGROUP (depends on !SCHED_ALT) es imposible con bmq/pds/lfbmq y lo
# cuenta como incidencia de perfil en cada arranque.
# Necesita effective_scheduler, así que va ANTES de su unset.
_saved_vsdir="${VERIFY_STATE_DIR:-}"
VERIFY_STATE_DIR="$ROOT/vsig"; mkdir -p "$VERIFY_STATE_DIR"
PROFILE_FILE="$ROOT/perfil.conf"; : > "$PROFILE_FILE"
VERSION="7.2.6"; LOCALVERSION_SUFFIX="-cizen-v3"
BTF_REQUESTED=true; CLANG_BUILD=true; DO_SIGN_UKI=true; PKGREL=7
BORE_ENABLED=false; PATCHES_APPLIED=(bmq)
declare -a PATCH_RETIRED_ALL=(PSI PSI_DEFAULT_DISABLED SCHED_AUTOGROUP NUMA_BALANCING SCHED_CACHE)
write_verify_signature
if grep -q '^retired=PSI PSI_DEFAULT_DISABLED SCHED_AUTOGROUP NUMA_BALANCING SCHED_CACHE$' \
     "$VERIFY_STATE_DIR/last-build"; then
  rec ok "la firma graba retired= con los símbolos que PATCH_RETIRED_ALL retiró"
else
  rec fail "write_verify_signature no graba retired= (el verificador no podrá saltarlos)"
fi
# Sin parche de scheduler no hay retirados: la línea no debe aparecer (para que el
# verificador deduzca por sched= en vez de fiarse de una lista vacía).
PATCH_RETIRED_ALL=()
write_verify_signature
if grep -q '^retired=' "$VERIFY_STATE_DIR/last-build"; then
  rec fail "la firma graba retired= vacío: el verificador se fiaría de una lista vacía"
else
  rec ok "sin símbolos retirados la firma omite retired= (el verificador deduce por sched=)"
fi
# La firma no puede romperse por añadir una línea: todo lo de siempre sigue ahí.
_sig_ok=yes
for _k in version sched btf sb pkgrel ts; do
  grep -q "^$_k=" "$VERIFY_STATE_DIR/last-build" || { _sig_ok="le falta $_k="; }
done
grep -q '^sched=bmq$' "$VERIFY_STATE_DIR/last-build" || _sig_ok="sched= no es el efectivo"
[ "$_sig_ok" = yes ] \
  && rec ok "la firma sigue íntegra al añadir retired= (version/sched/btf/sb/pkgrel/ts)" \
  || rec fail "la firma del verificador se rompió al añadir retired= ($_sig_ok)"
unset _k _sig_ok
[ -n "$_saved_vsdir" ] && VERIFY_STATE_DIR="$_saved_vsdir" || unset VERIFY_STATE_DIR
unset _saved_vsdir
rm -rf "$ROOT/vsig" "$ROOT/perfil.conf"
unset -f write_verify_signature
unset -f effective_scheduler

printf '%s\n' "== unmount_tmpfs_build: éxito total desmonta siempre =="
# El selftest corre con `set -u`: se inicializan para que la ejecución en rojo
# contra un motor anterior (sin estos flags) falle por los tests, no por abortar.
TMPFS_UMOUNT_STATUS=""; TMPFS_UMOUNT_NOTE=""; TMPFS_UMOUNT_ERR=""
# Stubs de findmnt/sudo idénticos a los del grupo de reconciliación.
# El stub imprime tmpfs solo si se pide TARGET; para FSTYPE imprime tmpfs cuando
# el flag de "montado" existe, que es lo que consulta tmpfs_is_mounted (FSTYPE).
findmnt() { # shellcheck disable=SC2317
  if [ -f "$MOUNTED_FLAG" ]; then
    case " $* " in
      *" FSTYPE "*) printf 'tmpfs\n' ;;
      *)           printf '%s\n' "$TMPFS_ROOT" ;;
    esac
  fi
  return 0
}
sudo() { # shellcheck disable=SC2317
  case "$*" in
    *umount*)
      printf '%s\n' "$*" >> "$ROOT/umount.log"
      if [ -f "$BUSY_FLAG" ]; then return 1; fi
      if [ -f "$STACKED_FLAG" ]; then
        local n; n="$(cat "$STACKED_FLAG")"
        if [ "$n" -gt 1 ]; then echo $((n - 1)) > "$STACKED_FLAG"
        else rm -f "$STACKED_FLAG" "$MOUNTED_FLAG"; fi
      else
        rm -f "$MOUNTED_FLAG"
      fi ;;
  esac
  return 0
}
ok()  { :; }
warn() { printf 'WARN: %s\n' "$*" >> "$ROOT/warn.log"; }
info() { :; }
get_avail_mb() { printf '1024\n'; }
# get_mem_available_mb se extrae del motor: lee /proc/meminfo real, así que
# not-used=$TMPFS_UMOUNT_NOTE puede ser 0 y la comprobación solo mira el estado.
TMPFS_ROOT="$ROOT/tmpfs"
FULL_PIPELINE_OK=true
CIZEN_KEEP_TMPFS=0
: > "$MOUNTED_FLAG"; TMPFS_MOUNTED=true; : > "$ROOT/umount.log"
unmount_tmpfs_build
if [ ! -f "$MOUNTED_FLAG" ] && [ "$TMPFS_UMOUNT_STATUS" = unmounted ] && [ "$TMPFS_MOUNTED" != true ]; then
  rec ok "unmount_tmpfs_build: éxito total -> tmpfs desmontado y RAM devuelta"
else
  rec fail "unmount_tmpfs_build: éxito total dejó status=$TMPFS_UMOUNT_STATUS montado=$([ -f "$MOUNTED_FLAG" ] && echo sí || echo no)"
fi
# Montajes apilados: los 3 umount del punto apilado.
: > "$MOUNTED_FLAG"; TMPFS_MOUNTED=true; : > "$ROOT/umount.log"; echo 3 > "$STACKED_FLAG"
unmount_tmpfs_build
if [ ! -f "$MOUNTED_FLAG" ] && [ "$(grep -cE '^(-n )?umount ' "$ROOT/umount.log")" -eq 3 ]; then
  rec ok "unmount_tmpfs_build: también devuelve la RAM de los montajes apilados"
else
  rec fail "unmount_tmpfs_build: apilados mal desmontados ($(tr '\n' ' ' < "$ROOT/umount.log" 2>/dev/null))"
fi
# EBUSY: dos intentos, avisa y conserva (con el motivo del error).
: > "$MOUNTED_FLAG"; TMPFS_MOUNTED=true; : > "$ROOT/umount.log"; : > "$ROOT/warn.log"; : > "$BUSY_FLAG"
unmount_tmpfs_build
if [ -f "$MOUNTED_FLAG" ] && [ "$TMPFS_UMOUNT_STATUS" = failed ] \
   && [ "$(grep -c 'umount' "$ROOT/umount.log")" -ge 2 ] \
   && grep -q 'No se pudo desmontar' "$ROOT/warn.log"; then
  rec ok "unmount_tmpfs_build: EBUSY -> reintenta, avisa con el motivo y conserva el tmpfs"
else
  rec fail "unmount_tmpfs_build: EBUSY mal gestionado (status=$TMPFS_UMOUNT_STATUS, umounts=$(grep -c 'umount' "$ROOT/umount.log" 2>/dev/null))"
fi
rm -f "$BUSY_FLAG"
# Override explícito.
: > "$MOUNTED_FLAG"; TMPFS_MOUNTED=true; : > "$ROOT/umount.log"; CIZEN_KEEP_TMPFS=1
unmount_tmpfs_build
if [ -f "$MOUNTED_FLAG" ] && [ "$TMPFS_UMOUNT_STATUS" = kept ] && [ ! -s "$ROOT/umount.log" ]; then
  rec ok "unmount_tmpfs_build: CIZEN_KEEP_TMPFS=1 conserva a propósito y lo dice"
else
  rec fail "unmount_tmpfs_build: CIZEN_KEEP_TMPFS=1 no respetado (status=$TMPFS_UMOUNT_STATUS)"
fi
CIZEN_KEEP_TMPFS=0
# Flujo parcial (solo check): NO desmonta, para que el build reutilice el árbol.
: > "$MOUNTED_FLAG"; TMPFS_MOUNTED=true; : > "$ROOT/umount.log"; FULL_PIPELINE_OK=false
unmount_tmpfs_build
if [ -f "$MOUNTED_FLAG" ] && [ ! -s "$ROOT/umount.log" ] && [ "$TMPFS_MOUNTED" = true ]; then
  rec ok "unmount_tmpfs_build: flujo parcial (check) NO desmonta, el árbol queda reutilizable"
else
  rec fail "unmount_tmpfs_build: un check desmontó el tmpfs"
fi
FULL_PIPELINE_OK=true
# Red de seguridad: el trap EXIT desmonta si un éxito total no pasó por cleanup_success.
if grep -q 'if \[ "\$rc" -eq 0 \] && \[ "\$FULL_PIPELINE_OK" = true \] && \[ "\$CLEANUP_DONE" != true \]' "$MOTOR" \
   && grep -q 'unmount_tmpfs_build' "$MOTOR" && grep -q '^trap cleanup_tmpfs_on_exit EXIT' "$MOTOR"; then
  rec ok "trap EXIT: un éxito total que no llegó a cleanup_success desmonta igualmente"
else
  rec fail "el trap EXIT no monta la red de seguridad del desmontaje"
fi
# El informe final tiene que decir la verdad: estado del tmpfs + verificador.
if grep -q 'Build tmpfs : \$TMPFS_ROOT (size=\$TMPFS_SIZE) → \$TMPFS_LINE' "$MOTOR" \
   && grep -q 'Verificador: \$VERIFY_STATE_MSG' "$MOTOR" \
   && grep -q 'Para arrancarlo (no se reinicia solo)' "$MOTOR"; then
  rec ok "el resumen final informa del tmpfs y del verificador, y solo sugiere el reinicio"
else
  rec fail "el resumen final no informa del estado del tmpfs/verificador o no aclara que no reinicia solo"
fi
# El resumen no puede prometer un servicio que no exista.
if grep -q 'verify_service_state()' "$MOTOR" && grep -q 'kernel-update-verify.sh' "$MOTOR"; then
  rec ok "el resumen comprueba si el verificador está instalado/habilitado antes de prometerlo"
else
  rec fail "el resumen sigue prometiendo kernel-update-verify.service sin comprobarlo"
fi
unset -f findmnt sudo unmount_tmpfs_build

printf '%s\n' "== kernel-update-verify.sh: todos los schedulers =="
VERIFY_SRC="$(cd "$(dirname "$0")/.." && pwd)/kernel-update-verify.sh"
_sx() { # extrae una función del verificador
  sed -n "/^$1() {/,/^}/p" "$VERIFY_SRC"
}
_sx run_state > "$ROOT/vfns.sh"
_sx sched_symbol_for >> "$ROOT/vfns.sh"
_sx sched_label >> "$ROOT/vfns.sh"
_sx expected_sched_from_signature >> "$ROOT/vfns.sh"
_sx running_sched >> "$ROOT/vfns.sh"
# shellcheck disable=SC1090,SC1091
source "$ROOT/vfns.sh"
declare -A RUN_CFG=()
for _s in SCHED_BORE SCHED_PDS SCHED_BMQ SCHED_LFBMQ SCHED_MUQSS; do RUN_CFG["$_s"]="n"; done
_miss=0
for pair in "bore SCHED_BORE" "pds SCHED_PDS" "bmq SCHED_BMQ" "lfbmq SCHED_LFBMQ" "muqss SCHED_MUQSS"; do
  set -- $pair
  if [ "$(sched_symbol_for "$1")" = "$2" ]; then
    RUN_CFG["$2"]="y"
    if [ "$(running_sched)" = "$1" ]; then
      RUN_CFG["$2"]="n"
      [ "$(running_sched)" = "eevdf" ] || _miss=1
      RUN_CFG["$2"]="y"
    else
      _miss=1
    fi
    RUN_CFG["$2"]="n"
  else
    _miss=1
  fi
done
[ "$_miss" = 0 ] && rec ok "running_sched: detecta bore/pds/bmq/lfbmq/muqss y eevdf sin ninguno" || rec fail "running_sched no cubre todos los schedulers"
[ "$(sched_symbol_for eevdf)" = "-" ] && rec ok "sched_symbol_for: eevdf no tiene símbolo propio (mainline)" || rec fail "sched_symbol_for eevdf dio $(sched_symbol_for eevdf)"
[ "$(sched_symbol_for inventado)" = "" ] && rec ok "sched_symbol_for: lo desconocido no inventa símbolo" || rec fail "sched_symbol_for inventado dio algo"
# La firma manda; los fallbacks cubren las firmas anteriores a v27.31.19.
[ "$(expected_sched_from_signature bmq no bmq)" = bmq ] && rec ok "expected: sched= de la firma nueva" || rec fail "expected: sched= bmq"
[ "$(expected_sched_from_signature "" yes "")" = bore ] && rec ok "expected: firma antigua con bore=yes" || rec fail "expected: bore=yes legacy"
[ "$(expected_sched_from_signature "" no "bmq pds")" = bmq ] && rec ok "expected: firma antigua deduce el scheduler de patches=" || rec fail "expected: patches= bmq pds"
[ "$(expected_sched_from_signature "" no "")" = eevdf ] && rec ok "expected: firma sin nada asumible -> eevdf" || rec fail "expected: vacío"
_miss=""
for _pair in "bore BORE" "pds PDS" "bmq BMQ" "lfbmq LF-BMQ" "muqss MuQSS" "eevdf EEVDF"; do
  set -- $_pair
  case "$(sched_label "$1")" in "$2"*) ;; *) _miss="$_miss $1->$(sched_label "$1")" ;; esac
done
[ -z "$_miss" ] && rec ok "sched_label: etiqueta legible para los 6 schedulers" || rec fail "sched_label:$_miss"
# sched_check tiene que ser un paso propio: dentro de profile_check (subshell)
# los globales que fija se perderían y el resumen siempre saldría "unknown".
if grep -q '^sched_check() {' "$VERIFY_SRC" \
   && grep -q '^sched_check$' "$VERIFY_SRC" \
   && ! sed -n '/^profile_check() {/,/^}/p' "$VERIFY_SRC" | grep -q 'sched_check\|running_sched'; then
  rec ok "sched_check es un paso propio (profile_check corre en subshell y perdería los globales)"
else
  rec fail "sched_check se ejecuta dentro de profile_check: el resumen mostraría scheduler unknown"
fi
if grep -qi '/proc/config.gz legible: el scheduler' "$VERIFY_SRC"; then
  rec ok "sin /proc/config.gz el verificador lo dice en vez de afirmar el scheduler"
else
  rec fail "el verificador no contempla la ausencia de /proc/config.gz"
fi
# La unit que hace que esto ocurra en cada arranque. Se mira donde vive de verdad
# en cada layout: en el repo `systemd/user/`, y al correr instalado la copia de
# `~/.config/systemd/user/`. Con la ruta relativa sola (../..) el test era
# imposible de satisfacer desde /usr/local/bin: daba falso rojo sin ningún motivo
# real, y un test que no puede pasar en uno de los dos layouts entrena a ignorar
# los tests que fallan.
_repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
_unit_ok=no
for _u in "$_repo_root/systemd/user/kernel-update-verify.service" \
         "$HOME/.config/systemd/user/kernel-update-verify.service"; do
  if [ -f "$_u" ] && grep -q 'ExecStart=/usr/local/bin/kernel-update/kernel-update-verify.sh' "$_u" \
     && grep -q 'WantedBy=default.target' "$_u" && grep -q 'After=graphical-session.target' "$_u"; then
    _unit_ok=" $_u"   # con espacio delante: el mensaje quita el prefijo con ${_unit_ok# }
  fi
done
if [ "$_unit_ok" != "no" ]; then
  rec ok "existe la unit de usuario kernel-update-verify.service apuntando al script instalado (${_unit_ok# })"
else
  rec fail "falta o está mal la unit systemd/user/kernel-update-verify.service (ni en el repo ni en ~/.config/systemd/user/)"
fi
# Si están las dos copias, no pueden haber divergido: la instalada es la que corre.
if [ -f "$_repo_root/systemd/user/kernel-update-verify.service" ] \
   && [ -f "$HOME/.config/systemd/user/kernel-update-verify.service" ]; then
  if cmp -s "$_repo_root/systemd/user/kernel-update-verify.service" \
            "$HOME/.config/systemd/user/kernel-update-verify.service"; then
    rec ok "la unit instalada no ha divergido de la del repo"
  else
    rec fail "la unit instalada difiere de la del repo"
  fi
fi
unset -f sched_symbol_for sched_label expected_sched_from_signature running_sched

printf '%s\n' "== kernel-update-verify.sh: símbolos retirados por el parche =="
# v27.31.22. El parche PRJC (pds/bmq/lfbmq) pone `depends on !SCHED_ALT` en
# SCHED_AUTOGROUP y compañía: imposibles de habilitar, así que el motor los saca
# de las exigencias efectivas. El verificador los contaba como incidencia de
# perfil → "Perfil: FALLO" + notificación critical en CADA arranque.
# El grupo anterior ya unsetó sched_label y expected_sched_from_signature, que
# estas funciones necesitan: se extraen otra vez en un fichero aparte.
{
  _sx sched_label
  _sx expected_sched_from_signature
  _sx build_sig_field
  _sx retired_symbols_for_sched
  _sx load_retired_symbols
  _sx sym_retired
  _sx retired_reason
} > "$ROOT/vret.sh"
# El estado del que dependen va fuera de las funciones (en el script es global).
declare -A RETIRED=()
RETIRED_SCHED=""; RETIRED_SRC=""; RETIRED_LIST=""
BUILD_SIG="$ROOT/last-build"
# alog solo escribe en el log del verificador; aquí no existe.
alog() { :; }
# shellcheck disable=SC1090,SC1091
source "$ROOT/vret.sh"
_miss=""
for _s in pds bmq lfbmq; do
  retired_symbols_for_sched "$_s" | grep -qx SCHED_AUTOGROUP || _miss="$_miss $_s"
done
[ -z "$_miss" ] && rec ok "retired: pds/bmq/lfbmq retiran SCHED_AUTOGROUP (depends on !SCHED_ALT)" \
  || rec fail "retired: la tabla no cubre SCHED_AUTOGROUP en:$_miss"
# bore/muqss NO lo retiran: su patch no toca ese símbolo ni su `depends on`.
# Confundirlos dejaría sin vigilar un perfil que sí se puede cumplir entero.
_miss=""
for _s in bore muqss eevdf; do
  [ -z "$(retired_symbols_for_sched "$_s")" ] || _miss="$_miss $_s"
done
[ -z "$_miss" ] && rec ok "retired: bore/muqss/eevdf no retiran nada (tabla = la del motor)" \
  || rec fail "retired: la tabla inventa retirados para:$_miss"
# La firma manda; sin retired= se deduce del scheduler (firmas anteriores).
_mk_sig() { printf '%s\n' "$@" > "$BUILD_SIG"; }
_mk_sig "version=7.2.7-cizen-v3" "bore=no" "patches=bmq" "btf=yes" "sb=yes"
load_retired_symbols
if sym_retired SCHED_AUTOGROUP && [ "${#RETIRED[@]}" -eq 5 ] && [ -n "$RETIRED_SRC" ]; then
  rec ok "retired: firma sin retired= + patches=bmq -> deduce los 5 retirados (firma legacy)"
else
  rec fail "retired: con bmq y sin retired= no se deduce la lista (${#RETIRED[@]}, origen: ${RETIRED_SRC:-ninguno})"
fi
sym_retired SCHED_BMQ && rec fail "retired: da por retirado un símbolo que el parche no toca" \
  || rec ok "retired: no marca símbolos que el parche no retira (SCHED_BMQ sigue exigible)"
# El motivo tiene que decir quién retiró el símbolo: si no, el "omitida" del
# perfil es un misterio cada vez que aparece en el log.
case "$(retired_reason)" in
  *BMQ*) rec ok "retired: el motivo nombra al scheduler responsable (BMQ)" ;;
  *)     rec fail "retired: el motivo no identifica al scheduler: $(retired_reason)" ;;
esac
_mk_sig "version=7.2.7-cizen-v3" "bore=no" "patches=bore" "btf=yes" "sb=yes"
load_retired_symbols
sym_retired SCHED_AUTOGROUP && rec fail "retired: con bore da por retirado SCHED_AUTOGROUP" \
  || rec ok "retired: con bore no se salta nada (el perfil sí se puede cumplir entero)"
_mk_sig "version=7.2.7-cizen-v3" "retired=SCHED_AUTOGROUP" "sched=bmq" "btf=yes" "sb=yes"
load_retired_symbols
if sym_retired SCHED_AUTOGROUP && ! sym_retired PSI; then
  rec ok "retired: retired= de la firma manda sobre la tabla (lista exacta, sin inventar)"
else
  rec fail "retired: retired= de la firma no se respeta tal cual"
fi
# Sin firma no hay excusas: el verificador no debe inventar una lista.
_mk_sig; load_retired_symbols
sym_retired SCHED_AUTOGROUP && rec fail "retired: sin firma se salta un símbolo sin motivo" \
  || rec ok "retired: sin firma del build no se salta nada (no se inventa)"
# Y el salto tiene que estar en los cuatro bucles del perfil, no solo en CRITICAL:
# el motor los saca de ENABLE/SETVAL/SETSTR también.
_miss=""
for _loop in OPTS_ENABLE CRITICAL_OPTS OPTS_SETVAL OPTS_SETSTR; do
  _start="$(grep -n "for opt in .*${_loop}\[" "$VERIFY_SRC" | head -n1 | cut -d: -f1)"
  if [ -z "$_start" ] || ! sed -n "${_start},$((_start + 14))p" "$VERIFY_SRC" | grep -q 'sym_retired'; then
    _miss="$_miss $_loop"
  fi
  unset _start
done
[ -z "$_miss" ] && rec ok "retired: ENABLE/CRITICAL/SETVAL/SETSTR saltan los retirados" \
  || rec fail "retired: estos bucles no saltan los retirados:$_miss"
# Y tienen que SALTÁRSELO, no solo mencionarlo: la incidencia se cuenta en el
# `bad+=` de cada bucle, así que el skip tiene que ser un `continue`/&&-continue.
_pc="$(sed -n '/^profile_check() {/,/^}/p' "$VERIFY_SRC")"
printf '%s\n' "$_pc" | grep -qE 'sym_retired .*\{ *skipped\+=|sym_retired .*continue' \
  && rec ok "retired: el skip se aplica antes de contar la incidencia" \
  || rec fail "retired: se detecta el símbolo retirado pero no se salta la comprobación"
unset -f alog build_sig_field retired_symbols_for_sched load_retired_symbols \
      sym_retired retired_reason sched_label expected_sched_from_signature
rm -f "$ROOT/vret.sh" "$BUILD_SIG"
unset RETIRED RETIRED_SCHED RETIRED_SRC RETIRED_LIST BUILD_SIG _pc _miss _mk_sig


# ============================================================
# v27.31.21: la notificación solo cuando el estado cambia
# ============================================================
printf '%s\n' "== la notificación solo dispara ante un cambio de estado =="
grep -q 'verify-notify-state' "$VERIFY_SRC" && grep -q 'notify_state_changed()' "$VERIFY_SRC" \
  && rec ok "el estado de notificación se persiste (verify-notify-state)" || rec fail "no hay estado de notificación persistido"
if grep -q 'verify_state_fingerprint' "$VERIFY_SRC" \
   && sed -n '/^verify_state_fingerprint() {/,/^}/p' "$VERIFY_SRC" | grep -qF 'perfil=%s|sched=%s/%s|journal=%s|fw=%s|sb=%s|iss=%s'; then
  rec ok "la firma del estado cubre perfil/sched/journal/fw/sb/incidencias"
else
  rec fail "la firma del estado no cubre los componentes relevantes"
fi
# El tiempo de arranque NO puede estar en la firma: 15.8675 vs 15.8671 no es un
# cambio de estado y con él dentro no se callaría nunca.
if ! sed -n '/^verify_state_fingerprint() {/,/^}/p' "$VERIFY_SRC" | grep -qE '\$TOT|\$TOT_TXT|Boot'; then
  rec ok "el tiempo de arranque queda fuera de la firma (no dispara notificaciones por milisegundos)"
else
  rec fail "el tiempo de arranque está en la firma del estado: notificaría en cada arranque"
fi
# Comportamiento real de notify_state_changed, con un estado escrito a mano.
NSTATE="$ROOT/notify-state"
_sx_nsc() { sed -n "/^$1() {/,/^}/p" "$VERIFY_SRC"; }
{ _sx_nsc verify_state_fingerprint; _sx_nsc notify_state_changed; } > "$ROOT/nfns.sh"
# shellcheck disable=SC1090,SC1091
source "$ROOT/nfns.sh"
BASE_ISSUES=0; SCHED_EXPECTED=bmq; SCHED_RUNNING=bmq; JCOUNT=0; FW_COUNT=0
SB_STATE="no (SB desconocido)"; ISSUES=0
NOTIFY_STATE="$NSTATE"
: > "$NSTATE"
if notify_state_changed; then
  rec ok "sin estado previo: la primera verificación sí notifica"
else
  rec fail "sin estado previo no se notifica (se perdería el aviso inicial)"
fi
verify_state_fingerprint > "$NSTATE"
if notify_state_changed; then
  rec fail "estado idéntico: vuelve a notificar (ruido en cada arranque)"
else
  rec ok "estado idéntico: NO se repite la notificación"
fi
ISSUES=2
if notify_state_changed; then
  rec ok "estado distinto (aparecen incidencias): sí notifica"
else
  rec fail "no avisa de un cambio real de estado"
fi
ISSUES=0
: > "$NSTATE"
verify_state_fingerprint > "$NSTATE"; notify_state_changed
ISSUES=3
if notify_state_changed; then
  rec ok "cambio de número de incidencias: notifica"
else
  rec fail "no detecta el cambio en el número de incidencias"
fi
unset -f verify_state_fingerprint notify_state_changed
# El cuerpo de la notificación dice qué cambió, y sin incidencias no es alarma.
if grep -q 'notify_state_diff' "$VERIFY_SRC" && grep -q 'sev=normal; icon=emblem-ok' "$VERIFY_SRC"; then
  rec ok "la notificación incluye el diff y baja a aviso normal cuando se resuelve"
else
  rec fail "la notificación no explica qué cambió / no baja de severidad al resolverse"
fi
if grep -q 'if \[ "\$DRY" != true \]; then' "$VERIFY_SRC" \
   && grep -qF "{ verify_state_fingerprint; printf '\n'; } > \"\$NOTIFY_STATE\"" "$VERIFY_SRC"; then
  rec ok "--dry-run no guarda el estado (una simulación no puede callar la notificación real)"
else
  rec fail "--dry-run guarda el estado y podría silenciar la notificación real"
fi
# El fichero de estado debe terminar en \n: sin él `while read` se salta la
# última línea, que es precisamente la que dice qué estado se guardó.
if grep -qF "printf '\n'; } > \"\$NOTIFY_STATE\"" "$VERIFY_SRC"; then
  rec ok "el estado se guarda con salto de línea final (while read no perdería la línea)"
else
  rec fail "el estado se guarda sin salto de línea final: while read se saltaría la última línea"
fi

# ============================================================
# v27.31.21: el estado real de Secure Boot (regresión)
# ============================================================
# El verificador daba "SB desconocido" en un equipo con Secure Boot perfectamente
# activo, porque el patrón era *'enabled': exige que la línea TERMINE en
# "enabled" y bootctl imprime "Secure Boot: enabled (user)". El desenlace era el
# peor posible: una incidencia inventada que pedía "activar Secure Boot" a quien
# ya lo tenía activo, y que se repetía en cada arranque.
printf '%s\n' "== Secure Boot: se lee el valor real, no un sufijo =="
if grep -qF "*'Secure Boot: enabled'*)" "$VERIFY_SRC" && grep -qF "*'Secure Boot: disabled'*)" "$VERIFY_SRC"; then
  rec ok "el patrón de Secure Boot está anclado al campo (con comodín final)"
else
  rec fail "el patrón de Secure Boot no está anclado: *'enabled' nunca casa con 'enabled (user)'"
fi
# Comportamiento real contra un bootctl de mentira con la salida auténtica.
_sbx="$ROOT/sbprobe"
mkdir -p "$_sbx/bin"
sed -n '/^secureboot_check() {/,/^}/p' "$VERIFY_SRC" > "$ROOT/sbcheck.sh"
printf 'sb=yes\n' > "$_sbx/build-sig"
# shellcheck disable=SC1090,SC1091
source "$ROOT/sbcheck.sh"
warn() { :; }
info() { :; }
_sb_probe() { # $1 = línea que emite el bootctl falso
  {
    printf '#!/usr/bin/env bash\n'
    printf '[ "$1" = status ] || exit 1\n'
    printf "printf '%%s\\\\n' '%s'\n" "$1"
  } > "$_sbx/bin/bootctl"
  chmod +x "$_sbx/bin/bootctl"
  # OJO: en bash 5.3 las asignaciones que preceden a una llamada a función
  # (SB_STATE=... secureboot_check) son locales a ella, así que al volver
  # seguirían los valores viejos de antes y la sonda mediría lo que le da la gana.
  # Asignación normal y llamada aparte, y así lo que sale es lo que devolvió.
  local _oldpath="$PATH"
  PATH="$_sbx/bin:$PATH"
  BUILD_SIG="$_sbx/build-sig"
  SB_STATE=""
  ISSUES=0
  DRY=true
  secureboot_check
  printf '%s|%s' "$SB_STATE" "$ISSUES"
  PATH="$_oldpath"
}
_r=$(_sb_probe '   Secure Boot: enabled (user)')
case "$_r" in
  *"HABILITADO"*)
    if [ "${_r##*|}" = 0 ]; then
      rec ok "«Secure Boot: enabled (user)» se lee como HABILITADO y no cuenta incidencia"
    else
      rec fail "«enabled (user)» se lee bien pero suma incidencia: $_r"
    fi ;;
  *) rec fail "«Secure Boot: enabled (user)» NO se reconoce como HABILITADO (sale: $_r)" ;;
esac
_r=$(_sb_probe '   Secure Boot: disabled')
case "$_r" in
  *"desactivado"*) rec ok "«Secure Boot: disabled» se lee como desactivado" ;;
  *)               rec fail "«Secure Boot: disabled» mal leído (sale: $_r)" ;;
esac
_r=$(_sb_probe '')
case "$_r" in
  *"desconocido"*) rec ok "sin dato de bootctl se declara desconocido, no se inventa" ;;
  *)               rec fail "sin dato de bootctl se inventa un estado (sale: $_r)" ;;
esac
unset -f secureboot_check _sb_probe

printf '%s\n' "== falsos positivos del verificador (los aceptaba el motor) =="
# El motor cuenta y|m como OPTS_ENABLE satisfecho (validate_config) porque el
# modo lite degrada con localmodconfig. El verificador no puede ser más estricto.
_motor_ok=0
if sed -n '/^validate_config() {/,/^}/p' "$MOTOR" | grep -q 'if \[ "\$state" = y \] || \[ "\$state" = m \]'; then
  _motor_ok=1
fi
if [ "$_motor_ok" = 1 ] \
   && sed -n '/^profile_check() {/,/^}/p' "$VERIFY_SRC" | grep -q 'm) demoted+=' \
   && ! sed -n '/^profile_check() {/,/^}/p' "$VERIFY_SRC" | grep -q 'bad+=.*=m'; then
  rec ok "OPTS_ENABLE en =m: el verificador coincide con validate_config del motor (aviso, no incidencia)"
else
  rec fail "el verificador cobra como incidencia un =m que el motor acepta"
fi
# Un firmware presente en el árbol (comprimido) que la carga no|goals a resolver no
# es una incidencia; uno ausente del todo sí lo es.
if grep -q 'kpresent' "$VERIFY_SRC" && grep -q 'FIRMWARE_DIR/\$fw_rel.zst' "$VERIFY_SRC"; then
  rec ok "firmware: 'carga fallida con el fichero presente en el árbol' se informa, no se cuenta"
else
  rec fail "el verificador no distingue firmware presente de firmware ausente"
fi
if grep -q 'kfail+=("\$line")' "$VERIFY_SRC" && grep -q 'ISSUES=\$((ISSUES + FW_COUNT))' "$VERIFY_SRC"; then
  rec ok "firmware: lo que de verdad falta del árbol sigue contando como incidencia"
else
  rec fail "el firmware ausente dejó de contar como incidencia (no debe pasar)"
fi
# La extracción del nombre tiene que admitir rutas con '/' (i915/..., intel/ice/...).
if bash -c 'printf "%s\n" "Direct firmware load for i915/kbl_dmc_ver1_04.bin failed" | sed -nE -e "s#^Direct firmware load for ([^ ]+) failed.*#\\1#p" | grep -q "^i915/kbl_dmc_ver1_04.bin$"'; then
  rec ok "extracción del nombre de firmware: admite rutas con subdirectorios"
else
  rec fail "la extracción del nombre de firmware rompe con rutas tipo i915/..."
fi

# --- resumen ---
echo
printf 'Totales: %d ok, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]