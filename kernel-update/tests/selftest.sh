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
  extract resolve_cachyos_release
  extract process_frag_file
  extract apply_config_fragments
  extract patch_markers_hit
  extract apply_patch_register
  extract apply_patch_plugin
  extract _misc_extract_kconfig_symbols
  extract apply_cachy_misc_symbols
  extract apply_cachy_misc_single
  extract apply_cachy_misc_patchset
  extract secure_boot_guided_setup
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
if grep -q 'tools+=(ld.lld)' "$MOTOR" && grep -Fq '"$CC_LAUNCHER" = "clang" ] && tools+=(clang)' "$MOTOR"; then
  rec ok "check_prerequisites exige ld.lld (familia clang) y clang si el launcher es genérico"
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

# --- resumen ---
echo
printf 'Totales: %d ok, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]