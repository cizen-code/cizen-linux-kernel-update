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
# Igual, pero contando llaves: `extract` se come todo hasta el primer `}` en
# columna 0, y con una función de una línea ({ ...; }) eso se lleva por delante
# las siguientes (y la función preguntada no llega a definirse).
extract_fn() { # $1 = nombre de función
  awk -v fn="$1" '
    !f && $0 ~ "^[[:space:]]*" fn "[[:space:]]*\\(\\)[[:space:]]*\\{" {f=1}
    f {
      l=$0; n=gsub(/\{/, "", l); m=gsub(/\}/, "", l)
      d+=n-m
      print
      if (d==0) exit
    }' "$MOTOR"
}
# Igual que extract, pero de OTRO fichero: pgo-collect.sh no vive en el motor.
extract_from() { # $1 = fichero, $2 = nombre de función
  sed -n "/^[[:space:]]*$2() {/,/^}/p" "$1"
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
  # v27.31.52: las variantes SIN subshell que ahora llaman las funciones de
  # arriba. No son opcionales: `apply_patch_register` llama a
  # kconfig_symbol_type_into y `build_effective_arrays` a resolve_symbol_into de
  # forma DIRECTA, así que si el arnés no las define el "orden no encontrada"
  # aborta con `set -u` en vez de degradarse. Antes iban dentro de `$( )`, que se
  # tragaba el 127 y devolvía vacío, y por eso nunca se notó que faltaban.
  extract kconfig_symbol_type
  extract kconfig_symbol_type_into
  extract build_kconfig_indexes
  extract resolve_symbol
  extract resolve_symbol_into
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
  extract tree_identity_into
  extract tmpfs_is_mounted
  extract tmpfs_umount_all
  extract auto_add_ntsync_patch
  extract tree_usable_for
  extract source_tree_reusable
  extract write_tree_meta
  # v27.31.54: estado de parches del árbol. extract_tarball entra porque el
  # defecto que corrigió era SU reutilización silenciosa de un árbol parcheado.
  extract tree_patches_list
  extract tree_record_patch
  extract tree_clean_reusable
  extract extract_tarball
  extract reconcile_tmpfs_trees
  extract get_mem_available_mb
  extract unmount_tmpfs_build
  extract effective_scheduler
  extract write_verify_signature
  # v27.31.24: rollback por paquete (no solo por ficheros)
  extract installed_pkgver
  extract rollback_manifest_field
  extract rollback_manifest_set
  # v27.31.52: preserve_rollback_package escribe las seis claves con
  # rollback_manifest_set_many y desvincula el archive con rollback_manifest_unset.
  # Sin estas dos, el "orden no encontrada" se tragaba el manifiesto entero y
  # rollback_manifest_field devolvía "" para pkgfile y sched.
  extract rollback_manifest_set_many
  extract rollback_manifest_unset
  extract rollback_manifest_matches
  extract preserve_rollback_package
  extract ask_build_pgo
  extract pgo_disp_suffix
  extract pgo_profile_dir
  # v27.33.6: pgo-collect.sh es un script aparte, no el motor. Sus decisiones se
  # extraen del SCRIPT hermano; si no está (la suite instalada no lo copia), los
  # tests de PGO se omiten en vez de tumbar el arnés entero.
  PGO="$(dirname -- "$MOTOR")/pgo-collect.sh"
  [ -f "$PGO" ] || PGO="$HOME/Proyectos/cizen-linux-kernel-update/kernel-update/pgo-collect.sh"
  if [ -f "$PGO" ]; then
    extract_from "$PGO" pgo_perf_args
    extract_from "$PGO" pgo_perf_event
    extract_from "$PGO" pgo_target_home
    extract_from "$PGO" pgo_running_autofdo
  fi
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
# v27.31.52: estado global que las variantes sin subshell leen directamente.
# El motor lo declara con `declare -A`/`=false` al cargarse, pero aquí las
# funciones se extraen a un fns.sh aparte, así que hay que declararlo a mano
# (igual que BORE_ENABLED): con `set -u` leer una global no declarada es
# "variable sin asignar" y tumba el arnés.
declare -A KCONFIG_SYMBOL_KNOWN=() KCONFIG_SYMBOL_TYPE=()
KCONFIG_TYPE_INDEX_BUILT=false
KCONFIG_SYMBOL_INDEX_BUILT=false
declare -A RENAME_MAP=() RESOLVED_SYMBOL=()
# tree_identity_into indexa por RUTA, así que sin `declare -A` bash evalúa
# "/tmp/.../linux-7.2.7" como expresión aritmética y falla con "error de
# sintaxis aritmética", devolviendo identidad vacía.
declare -A TREE_IDENTITY=()
# El motor declara TREE_META_NAME al cargarse, pero las funciones se extraen a un
# fns.sh aparte, así que hay que declararla a mano aquí: apply_patch_register
# llama a tree_record_patch, que la consulta, y con `set -u` leerla sin asignar
# tumba el arnés. Solo se usa a partir de la sección de estado de parches.
TREE_META_NAME=".cizen-tree"

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

# v27.31.52: regresión del símbolo vacío. El idioma "${PATCH_SYMBOLS[@]:-}" itera
# UNA vez con cadena vacía cuando el array está vacío, así que apply_patch_register
# terminaba metiendo "" en PATCH_ENABLE_ALL y PATCH_REBEL_ALL. Invisible desde
# fuera porque "${PATCH_ENABLE_ALL[*]:-}" devuelve "" tanto para un array vacío
# como para uno con un único elemento vacío: los dos dan la misma cadena.
# Aquí se mira el NÚMERO de elementos, que sí distingue los dos casos.
PATCHES_APPLIED=(); PATCH_ENABLE_ALL=(); PATCH_REBEL_ALL=(); PATCH_VALUE_SYMBOLS=()
declare -a PATCH_SYMBOLS=()
apply_patch_register bore
[ "${#PATCH_ENABLE_ALL[@]}" -eq 0 ] && [ "${#PATCH_REBEL_ALL[@]}" -eq 0 ] \
  && rec ok "register sin símbolos no mete entradas vacías (${#PATCH_ENABLE_ALL[@]}/${#PATCH_REBEL_ALL[@]})" \
  || rec fail "register sin símbolos metió un elemento vacío: ENABLE=${#PATCH_ENABLE_ALL[@]} REBEL=${#PATCH_REBEL_ALL[@]}"

# Y el camino con símbolos, que es donde el tipo decide a qué array va: un int
# forzado a "=y" es un valor inválido y olddefconfig lo revierte, así que debe
# caer en PATCH_VALUE_SYMBOLS y no en ENABLE/REBEL.
kconfig_index_invalidate
KCONFIG_SYMBOL_KNOWN=([SCHED_BORE]=1 [MIN_BASE_SLICE_NS]=1 [FAKE_BOOL]=1)
KCONFIG_SYMBOL_TYPE=([SCHED_BORE]=bool [MIN_BASE_SLICE_NS]=int [FAKE_BOOL]=tristate)
KCONFIG_SYMBOL_INDEX_BUILT=true; KCONFIG_TYPE_INDEX_BUILT=true
PATCHES_APPLIED=(); PATCH_ENABLE_ALL=(); PATCH_REBEL_ALL=(); PATCH_VALUE_SYMBOLS=()
PATCH_SYMBOLS=(SCHED_BORE MIN_BASE_SLICE_NS FAKE_BOOL)
apply_patch_register bore
[ "${PATCH_ENABLE_ALL[*]:-}" = "SCHED_BORE FAKE_BOOL" ] \
  && rec ok "register reparte por tipo: los bool/tristate van a ENABLE (${PATCH_ENABLE_ALL[*]:-})" \
  || rec fail "register no separó bool de int (ENABLE=${PATCH_ENABLE_ALL[*]:-}, VALUE=${PATCH_VALUE_SYMBOLS[*]:-})"
[ "${PATCH_VALUE_SYMBOLS[*]:-}" = "MIN_BASE_SLICE_NS" ] \
  && rec ok "register manda el int a VALUE, no a ENABLE (=y no valdría)" \
  || rec fail "el int no fue a VALUE (VALUE=${PATCH_VALUE_SYMBOLS[*]:-})"
kconfig_index_invalidate

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
  # v27.31.52: el reparto por tipo ahora se aplica de verdad. Antes este test
  # pedía los DOS símbolos en ENABLE y pasaba, pero solo porque el arnés no
  # extraía kconfig_symbol_type_into: la llamada devolvía 127 dentro de `$( )`,
  # el tipo salía vacío y el `case` polycayo en la rama `""`, que manda a ENABLE.
  # Con el índice real, min_base_slice_ns es un int y "=y" no le valdría, así que
  # va a PATCH_VALUE_SYMBOLS; SCHED_BORE (bool) sí va a ENABLE/REBEL.
  case " ${PATCH_ENABLE_ALL[*]:-} " in
  *SCHED_BORE*) rec ok "SCHED_BORE (bool) registrado en ENABLE" ;;
  *) rec fail "SCHED_BORE no registrado en ENABLE: [${PATCH_ENABLE_ALL[*]:-}]" ;;
  esac
  case " ${PATCH_REBEL_ALL[*]:-} " in
  *SCHED_BORE*) rec ok "SCHED_BORE (bool) registrado en REBEL" ;;
  *) rec fail "SCHED_BORE no registrado en REBEL: [${PATCH_REBEL_ALL[*]:-}]" ;;
  esac
  case " ${PATCH_VALUE_SYMBOLS[*]:-} " in
  *MIN_BASE_SLICE_NS*) rec ok "MIN_BASE_SLICE_NS (int) va a VALUE, no a ENABLE (=y no valdría)" ;;
  *) rec fail "MIN_BASE_SLICE_NS no fue a VALUE: [${PATCH_VALUE_SYMBOLS[*]:-}]" ;;
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
# v27.31.37: la exigencia por familia vive en require_cc_toolchain, que la
# reutiliza también la pregunta tardía del compilador (si se elige clang DESPUÉS
# de validar, su toolchain tiene que exigirse igual que en el arranque).
if grep -q 'for _ccb in ld.lld llvm-ar llvm-nm llvm-objcopy llvm-strip llvm-objdump llvm-readelf; do' "$MOTOR" \
   && grep -Fq '[ "$CC_LAUNCHER" = "clang" ] && ! command -v clang' "$MOTOR" \
   && grep -q 'if ! require_cc_toolchain; then' "$MOTOR"; then
  rec ok "require_cc_toolchain exige la toolchain LLVM completa (ld.lld + llvm-* + clang genérico)"
else
  rec fail "require_cc_toolchain: falta la exigencia por familia (ld.lld / clang genérico)"
fi
if grep -q 'CC_MISSING_PKGS+=("${_ccb//-/}")' "$MOTOR"; then
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

if grep -Fq 'for _ccb in ld.lld llvm-ar llvm-nm llvm-objcopy llvm-strip llvm-objdump llvm-readelf; do' "$MOTOR"; then
  rec ok "familia clang exige ld.lld + llvm-* completos (LLVM=1 usa llvm-ar/nm/objcopy/strip/objdump/readelf)"
else
  rec fail "require_cc_toolchain: con clang faltaba la toolchain llvm-* completa (paquete llvm)"
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
  # v27.31.24: la opción 9 dice en la propia etiqueta qué kernel hay para
  # deshacer (y con qué scheduler). Sin esto se entra al rollback para descubrir
  # que no hay nada, o que es otro kernel del que uno creía.
  sed -n '/^rollback_resumen() {/,/^}/p' "$MENU" > "$ROOT/rbfn.sh"
  if [ -s "$ROOT/rbfn.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    source "$ROOT/rbfn.sh"
    RB2="$ROOT/menu-rb"
    rm -rf "$RB2"; mkdir -p "$RB2"
    ROLLBACK_DIR="$RB2"
    # Sin manifiesto: lo dice, sin inventarse un paquete.
    out="$(rollback_resumen)"
    if [ -n "$out" ] && ! printf '%s' "$out" | grep -qE 'cizen_v3-[0-9]'; then
      rec ok "menú rollback: sin manifiesto no inventa un kernel anterior ('$out')"
    else
      rec fail "menú rollback: sin manifiesto inventó un paquete ('$out')"
    fi
    # Manifiesto con paquete presente: pkgver + scheduler, que es lo que hace
    # falta para distinguir bore de bmq (misma release, distinto pkgrel).
    printf 'pkgbase=linux-cizen-v3\npkgver=7.2.7_cizen_v3-2\nsched=bmq\npkgfile=linux-cizen-v3-7.2.7_cizen_v3-2-x86_64.pkg.tar.zst\n' > "$RB2/rollback.info"
    : > "$RB2/linux-cizen-v3-7.2.7_cizen_v3-2-x86_64.pkg.tar.zst"
    out="$(rollback_resumen)"
    if [ "$out" = "linux-cizen-v3-7.2.7_cizen_v3-2 (bmq)" ]; then
      rec ok "menú rollback: la etiqueta muestra el kernel anterior con su scheduler"
    else
      rec fail "menú rollback: etiqueta inesperada ('$out')"
    fi
    # Manifiesto que dice un paquete que ya no está: hay que avisar, porque un
    # rollback a medias es peor que saber que no hay nada.
    rm -f "$RB2/linux-cizen-v3-7.2.7_cizen_v3-2-x86_64.pkg.tar.zst"
    out="$(rollback_resumen)"
    if printf '%s' "$out" | grep -q "sin paquete"; then
      rec ok "menú rollback: avisa si el manifiesto apunta a un paquete que no está"
    else
      rec fail "menú rollback: no_avisa de un paquete ausente ('$out')"
    fi
    rm -rf "$RB2"
  else
    rec fail "menú: no se pudo extraer rollback_resumen"
  fi
  # El script de rollback vive FUERA del motor y se instala por su cuenta: si no
  # está, un `exec` a un path inexistente solo suelta un error de bash.
  if grep -q 'CIZEN_KROLLBACK_SCRIPT' "$MENU" && grep -q 'if \[ -x "\$ROLLBACK_SCRIPT" \]' "$MENU"; then
    rec ok "menú rollback: comprueba que el script exista y admite CIZEN_KROLLBACK_SCRIPT"
  else
    rec fail "menú rollback: exec sin comprobar el script (error ilegible si falta)"
  fi

  # ── Las preguntas de variante y compilador viven en el MOTOR (v27.31.37) ──
  # Y solo se hacen detrás del «¿Desea continuar con la compilación?». Aquí se
  # comprueba lo contrario de lo que se comprobaba antes: que el menú NO las
  # haga (preguntarlas antes de validar es cambiar de opinión a mitad), que no
  # se cuele ningún flag que las silencie por la vía rápida, y que la 14 siga
  # con su propio prompt de Scheduler (su elección sí es definitiva).
  faltan=""
  for n in 1 2 3 4 5 7 8 15 16; do
    grep -qE "^ +$n\) build_and_exec (baja|alta) (ask|bore|none) " "$MENU" || faltan="$faltan $n"
  done
  if [ -z "$faltan" ]; then
    rec ok "menú: las 9 opciones que compilan (1,2,3,4,5,7,8,15,16) pasan por build_and_exec"
  else
    rec fail "menú: opciones de build que no pasan por build_and_exec:$faltan"
  fi
  # Y la etiqueta tiene que decirlo: "validar config" sin más prometía una
  # validación corta y la opción compilaba (build de 33 min en 7.2.8). Se
  # comprueba el texto de las dos, no la intención.
  mentir=""
  for n in 1 2; do
    grep -E "^opt $n " "$MENU" | grep -q 'validar y compilar' || mentir="$mentir $n"
  done
  if [ -z "$mentir" ]; then
    rec ok "menú: las opciones 1 y 2 dicen que compilan, no solo que validan"
  else
    rec fail "menú: la etiqueta de$mentir promete validar sin mencionar la compilación"
  fi
  # El menú no puede tener ni las funciones ni los submenús: si vuelve a
  # preguntar aquí, el usuario ve la pregunta dos veces (una sin efecto).
  if ! grep -qE '^(ask_cc|ask_variant)\(\)' "$MENU" \
     && ! grep -q 'Variante (Enter usa el default)' "$MENU" \
     && ! grep -q 'CC (Enter usa el default)' "$MENU"; then
    rec ok "menú: no pregunta variante ni compilador (las dos preguntas están en el motor)"
  else
    rec fail "menú: vuelve a preguntar la variante o el compilador antes de validar la config"
  fi
  # build_and_exec no puede silenciar por la vía rápida las preguntas que ahora
  # hace el motor, ni elegir compilador por su cuenta: --no-ask-variant lo
  # convertiría en un build sin pregunta, y --cc lo dejaría atado al default.
  : > "$ROOT/bafn.sh"
  sed -n '/^build_and_exec() {/,/^}/p' "$MENU" >> "$ROOT/bafn.sh"
  if ! grep -qE -- '--no-ask-variant|--cc' "$ROOT/bafn.sh"; then
    rec ok "menú: build_and_exec no pasa --no-ask-variant ni --cc (las preguntas son del motor)"
  else
    rec fail "menú: build_and_exec silencia o adelanta una pregunta que debe hacer el motor"
  fi
  # La 14 ya NO es excepción: desde v27.31.37 el menú no pregunta nada de
  # variante/compilador; la 14 simplemente lanza el motor (como las demás
  # opciones de build) y el motor pregunta tras confirmar "¿Desea continuar?".
  # El fallback del fork lo gestiona el motor (fork_release_guard).
  if grep -q '^ *14)' "$MENU" \
     && grep -A 15 '^ *14)' "$MENU" | grep -q 'exec "\$SCRIPT"' \
     && ! grep -q 'args="\$args --no-ask-variant"' "$MENU" \
     && ! grep -q 'Scheduler%b \[Enter=%blinherit%b\]' "$MENU"; then
    rec ok "menú: la 14 lanza el motor sin preguntar (el motor gestiona variante/CC y fork fallback)"
  else
    rec fail "menú: la 14 no sigue el nuevo diseño (lanza motor sin UI propia)"
  fi
  # El fallback del fork (ofrecer la última release del CachyOS) lo decide el
  # motor en fork_release_guard, no el menú. El menú ya no llama a
  # fork_fallback_for para la opción 14.
  if grep -q 'fork_release_guard' "$MOTOR"; then
    rec ok "motor: fork_release_guard gestiona el fallback del fork para schedulers solo-fork"
  else
    rec fail "motor: falta fork_release_guard para gestionar fallback del fork"
  fi

  # Funcional: build_and_exec solo compone la llamada. Sin preguntas, la fila del
  # motor es lo único que sale, y lo que entre se tiene que ver llegar tal cual.
  : > "$ROOT/ccfn.sh"
  sed -n '/^fork_fallback_for() {/,/^}/p' "$MENU" >> "$ROOT/ccfn.sh"
  # v27.33.0: resolve_btf_flag se extrae también, para que el test use la
  # definición REAL del menú y no una copia suya (si el menú se rompe, el test
  # tiene que enterarse).
  sed -n '/^resolve_btf_flag() {/,/^}/p'   "$MENU" >> "$ROOT/ccfn.sh"
  sed -n '/^build_and_exec() {/,/^}/p'   "$MENU" >> "$ROOT/ccfn.sh"
  cat > "$ROOT/fake-engine.sh" <<'FAKE'
#!/bin/bash
printf 'ARGS:'; printf ' <%s>' "$@"; printf ' PRIO=%s\n' "${CIZEN_BUILD_PRIORITY:-unset}"
FAKE
  chmod +x "$ROOT/fake-engine.sh"
  cat > "$ROOT/cc-run.sh" <<RUNNER
W=''; G=''; Y=''; N=''
FORK_MISSING=0; FORK_FALLBACK=''; REMOTE=''
# shellcheck disable=SC1090
source "$ROOT/ccfn.sh"
SCRIPT="$ROOT/fake-engine.sh"
build_and_exec "\$@"
RUNNER
  eng() { sed -n 's/^.*\(ARGS:.*\)$/\1/p'; }
  out_ask="$(bash "$ROOT/cc-run.sh" baja ask --absorb-rebels 2>/dev/null | eng)"
  if [ "$out_ask" = "ARGS: <--absorb-rebels> <--no-btf> PRIO=unset" ]; then
    rec ok "menú: una build sin variante impuesta llega al motor tal cual, más --no-btf"
  else
    rec fail "menú: build_and_exec añade o quita algo de la llamada ('$out_ask')"
  fi
  out_bore="$(bash "$ROOT/cc-run.sh" baja bore --absorb-rebels 2>/dev/null | eng)"
  if [ "$out_bore" = "ARGS: <--absorb-rebels> <--no-btf> <--patch> <bore> PRIO=unset" ]; then
    rec ok "menú: la opción que ya impone bore sigue pasándolo como --patch"
  else
    rec fail "menú: bore no llega al motor ('$out_bore')"
  fi
  out_alta="$(bash "$ROOT/cc-run.sh" alta ask --absorb-rebels 2>/dev/null | eng)"
  if [ "$out_alta" = "ARGS: <--absorb-rebels> <--no-btf> PRIO=normal" ]; then
    rec ok "menú: la prioridad «alta» sigue llegando al motor por CIZEN_BUILD_PRIORITY"
  else
    rec fail "menú: prioridad mal pasada ('$out_alta')"
  fi
  # Y lo más importante: el menú no imprime NADA de UI de preferencias. La UI
  # la imprime el motor, en su momento.
  ui_menu="$(bash "$ROOT/cc-run.sh" baja ask --absorb-rebels 2>&1)"
  if ! printf '%s' "$ui_menu" | grep -qE 'Variante|CC \(Enter|ask_cc|ask_variant'; then
    rec ok "menú: build_and_exec no imprime ninguna UI de variante/compilador"
  else
    rec fail "menú: build_and_exec imprime UI de preferencias ('$ui_menu')"
  fi

  # ── v27.33.0: BTF apagado en todas las builds ──────────────────
  # El equipo usa solo BORE. BTF solo servía para sched_ext, que con BORE no
  # tiene dónde anclarse, y pahole se come 6,7 GB de RSS por build. El motor lo
  # enciende por defecto (BTF_REQUESTED=true) y el perfil no puede apagarlo, así
  # que el menú es el único sitio donde el flag puede entrar. Si esto se rompe,
  # el síntoma es silencioso: se vuelve a pagar pahole sin avisar.
  if grep -q '^resolve_btf_flag() {' "$MENU" \
     && grep -q 'btf_arg="\$(resolve_btf_flag)"' "$MENU" \
     && sed -n '/^build_and_exec() {/,/^}/p' "$MENU" | grep -q 'btf_arg'; then
    rec ok "menú: resolve_btf_flag existe y build_and_exec lo usa"
  else
    rec fail "menú: build_and_exec no resuelve el flag de BTF"
  fi
  # La 14 no pasa por build_and_exec: es el camino que se olvidaría.
  if grep -A 15 '^ *14)' "$MENU" | grep -q 'resolve_btf_flag'; then
    rec ok "menú: la 14 también pasa --no-btf (no va por build_and_exec)"
  else
    rec fail "menú: la 14 construye fuera de build_and_exec y se queda sin --no-btf"
  fi
  # Escape hatch: CIZEN_BTF=1 tiene que devolver la llamada a como estaba.
  out_btf1="$(CIZEN_BTF=1 bash "$ROOT/cc-run.sh" baja ask --absorb-rebels 2>/dev/null | eng)"
  if [ "$out_btf1" = "ARGS: <--absorb-rebels> PRIO=unset" ]; then
    rec ok "menú: CIZEN_BTF=1 reactiva BTF y no deja un argumento vacío colgado"
  else
    rec fail "menú: CIZEN_BTF=1 no deja la llamada limpia ('$out_btf1')"
  fi
  # El porqué: si algún día el motor deja de encender BTF por defecto, este test
  # falla y obliga a mirar el menú en vez de dejar un --no-btf inofensivo.
  if grep -q '^BTF_REQUESTED=true' "$MOTOR" \
     && grep -q 'CIZEN_NO_BTF' "$MOTOR" \
     && grep -q '\-\-no-btf' "$MOTOR"; then
    rec ok "motor: BTF sigue siendo opt-out (--no-btf / CIZEN_NO_BTF), que es lo que el menú supone"
  else
    rec fail "motor: BTF ya no es opt-out; revisa si el menú debe seguir pasando --no-btf"
  fi

  # ── Motor: las dos preguntas, y solo con la respuesta SÍ ──
  # Estructura: # Motor: las dos preguntas, y solo con la respuesta SÍ.
  # Hay DOS bloques con confirm_build_after_check: uno en CHECK_ONLY (L9768)
  # y otro en build directo (L9787). En AMBOS, ask_build_prefs debe estar solo
  # en la rama then. Verificamos cada bloque por separado.
  ok_count=0
  for block_start in $(grep -n '^  if confirm_build_after_check; then' "$MOTOR" | cut -d: -f1); do
    then_has=$(awk -v start="$block_start" 'NR>=start && /^  if confirm_build_after_check; then/ && ++c>1 {exit} NR>=start {print}' "$MOTOR" | awk '/^  if confirm_build_after_check; then/{f=1} f&&/^  else$/{f=0} f{print}' | grep -c 'ask_build_prefs')
    else_has=$(awk -v start="$block_start" 'NR>=start && /^  if confirm_build_after_check; then/ && ++c>1 {exit} NR>=start {print}' "$MOTOR" | awk '/^  if confirm_build_after_check; then/{f=1} f&&/^  else$/{f=2} f==2{print}' | grep -cE 'ask_build_prefs|ask_build_variant|ask_build_cc')
    if [ "$then_has" -ge 1 ] && [ "$else_has" -eq 0 ]; then
      ok_count=$((ok_count+1))
    fi
  done
  if [ "$ok_count" -eq 2 ]; then
    rec ok "motor: ask_build_prefs solo en rama SÍ de ambos confirm_build_after_check"
  else
    rec fail "motor: ask_build_prefs mal ubicado (ok_count=$ok_count, esperado 2)"
  fi
  # El prompt al que se responde SÍ tiene que ser el de siempre: es el ancla de
  # todo este comportamiento.
  if grep -q '¿Desea continuar con la compilación del kernel \$VERSION? \[S/n\]' "$MOTOR"; then
    rec ok "motor: el prompt de confirmación previo a las preguntas no ha cambiado"
  else
    rec fail "motor: el prompt «¿Desea continuar…?» ya no es el esperado"
  fi
  # La UI de las dos preguntas, tal cual la pidió el usuario. Se comprueba
  # RENDERIZADA (ejecutando las funciones del motor con una entrada tecleada),
  # no leyendo el fuente: así lo que se testea es lo que se ve.
  : > "$ROOT/prefs.sh"
  extract_fn prefs_read          >> "$ROOT/prefs.sh"
  extract_fn prefs_interactive   >> "$ROOT/prefs.sh"
  extract_fn ask_build_variant   >> "$ROOT/prefs.sh"
  extract_fn ask_build_cc        >> "$ROOT/prefs.sh"
  cat > "$ROOT/prefs-run.sh" <<'PREFS'
W=''; Y=''; N=''
PATCH_NAMES=(); NO_ASK_VARIANT="${NO_ASK_VARIANT:-false}"; NO_ASK_CC="${NO_ASK_CC:-false}"
CC_EXPLICIT="${CC_EXPLICIT:-false}"; CIZEN_CC="${CIZEN_CC:-auto}"; CC_LAUNCHER="${CC_LAUNCHER:-gcc}"
log(){ :; }; ok(){ printf '  ok: %s\n' "$*"; }; warn(){ printf '  warn: %s\n' "$*"; }
# shellcheck disable=SC1090
source "$ROOT/prefs.sh"
# El test es una tubería: no hay tty, así que se simula una sesión
# interactiva y la lectura viene de stdin (no de /dev/tty, que sería la del
# propio runner).
prefs_interactive(){ return 0; }
prefs_read(){ local __v=""; read -r __v || __v=""; printf -v "$1" '%s' "$__v"; }
ask_build_variant
ask_build_cc
printf 'CHOICE variant=%s cc=%s\n' "${VARIANT_CHOICE:-vacio}" "${CC_CHOICE:-vacio}"
PREFS
  ui_p="$(printf '2\nclang\n' | bash "$ROOT/prefs-run.sh" 2>"$ROOT/prefs.err")"
  ui_p_err="$(cat "$ROOT/prefs.err")"
  if printf '%s' "$ui_p" | grep -q 'Variante (Enter usa el default)' \
     && printf '%s' "$ui_p" | grep -q 'CC (Enter usa el default)' \
     && [ -z "$ui_p_err" ]; then
    rec ok "motor: los dos submenús se ven enteros y van a stdout (también si stderr no es la terminal)"
  else
    rec fail "motor: submenús incompletos o no están en stdout ('$ui_p_err')"
  fi
  for linea in '1  Vanilla (EEVDF)' '2  BORE' '3  PDS (prjc)' '4  BMQ (prjc)' \
               '5  LFBMQ (prjc)' '6  MuQSS' 'Variante [Enter=1]: ' \
               'auto  elige según el sistema' 'gcc   compilador GCC' \
               'clang Clang/LLVM' 'otro  teclea TU compilador' \
               'CC [Enter=auto]: '; do
    if printf '%s' "$ui_p" | grep -qF -- "$linea"; then
      rec ok "motor: sale «$linea»"
    else
      rec fail "motor: no sale «$linea» del submenú"
    fi
  done
  if printf '%s' "$ui_p" | grep -q 'CHOICE variant=bore cc=clang'; then
    rec ok "motor: 2 → bore y clang → las respuestas llegan en sus globales"
  else
    rec fail "motor: las respuestas no llegan donde deben ('$ui_p')"
  fi
  # Enter = default: Vanilla, y el compilador que se deja tal cual (el motor ya
  # lo resolvió al arrancar; no hay que volver a decidirlo).
  ui_def="$(printf '\n\n' | bash "$ROOT/prefs-run.sh" 2>/dev/null)"
  if printf '%s' "$ui_def" | grep -q 'CHOICE variant=vacio cc=vacio'; then
    rec ok "motor: Enter en los dos = Vanilla + el compilador ya resuelto (no se re-pregunta)"
  else
    rec fail "motor: Enter no equivale a los defaults ('$ui_def')"
  fi
  # Los alias también (una palabra suelta, como siempre).
  ui_alias="$(printf 'muqss\ngcc-14\n' | bash "$ROOT/prefs-run.sh" 2>/dev/null)"
  if printf '%s' "$ui_alias" | grep -q 'CHOICE variant=muqss cc=gcc-14'; then
    rec ok "motor: alias por nombre (muqss / gcc-14) aceptados tal cual"
  else
    rec fail "motor: los alias no se aceptan ('$ui_alias')"
  fi
  # Una respuesta que no vale repregunta, no se traga.
  ui_bad="$(printf '9\n7\n6\nx\n' | bash "$ROOT/prefs-run.sh" 2>/dev/null)"
  if printf '%s' "$ui_bad" | grep -q 'Respuesta no válida' \
     && printf '%s' "$ui_bad" | grep -q 'CHOICE variant=muqss'; then
    rec ok "motor: una respuesta inválida repregunta y no se cuela como elección"
  else
    rec fail "motor: respuesta inválida aceptada en silencio ('$ui_bad')"
  fi
  # Quien ya lo dijo (--cc explícito) no se pregunta otra vez.
  ui_cc="$(CIZEN_CC=gcc-14 CC_EXPLICIT=true NO_ASK_CC=true NO_ASK_VARIANT=true \
            bash "$ROOT/prefs-run.sh" 2>/dev/null <<<'')"
  if ! printf '%s' "$ui_cc" | grep -qE 'Variante|CC .*\[Enter='; then
    rec ok "motor: con --cc explícito (o --no-ask-cc) no se imprime ningún submenú"
  else
    rec fail "motor: se pregunta el compilador aunque ya venga decidido ('$ui_cc')"
  fi
  # Sin terminal: se avisa y se sigue con los defaults, en vez de colgarse
  # leyendo de un stdin que no existe.
  ui_notty="$(printf '\n\n' | bash -c '
    W=""; Y=""; N=""; PATCH_NAMES=(); NO_ASK_VARIANT=false; NO_ASK_CC=false
    CC_EXPLICIT=false; CIZEN_CC=auto; CC_LAUNCHER=gcc
    log(){ :; }; ok(){ printf "  ok: %s\n" "$*"; }; warn(){ printf "  warn: %s\n" "$*"; }
    prefs_interactive(){ return 1; }
    source "'"$ROOT"'/prefs.sh"
    ask_build_variant; ask_build_cc
    printf "CHOICE variant=%s cc=%s\n" "${VARIANT_CHOICE:-vacio}" "${CC_CHOICE:-vacio}"' 2>&1)"
  if printf '%s' "$ui_notty" | grep -q 'warn: Sin terminal interactiva' \
     && printf '%s' "$ui_notty" | grep -q 'CHOICE variant=vacio cc=vacio'; then
    rec ok "motor: sin terminal no se pregunta y se continúa con los defaults"
  else
    rec fail "motor: sin terminal no cae en los defaults ('$ui_notty')"
  fi
  # Orden: variante antes que compilador, siempre.
  if sed -n '/^ask_build_prefs() {/,/^}/p' "$MOTOR" | grep -nE '^ *(ask_build_variant|ask_build_cc)$' \
       | head -2 | cut -d: -f2 | tr -d ' ' | paste -sd'|' - | grep -qx 'ask_build_variant|ask_build_cc'; then
    rec ok "motor: la variante se pregunta antes que el compilador"
  else
    rec fail "motor: orden de las preguntas distinto de variante→compilador"
  fi
  # ---- PGO / AutoFDO (v27.31.53) ------------------------------------------
  # Es una decisión propia: ni el parche ni el compilador la controlan, así que
  # tiene que existir como pregunta propia, no colarse dentro de otra.
  : > "$ROOT/pgo.sh"
  extract_fn pgo_profile_dir  >> "$ROOT/pgo.sh"
  extract_fn pgo_list_profiles >> "$ROOT/pgo.sh"
  extract_fn pgo_pick_profile >> "$ROOT/pgo.sh"
  extract_fn pgo_disp_suffix  >> "$ROOT/pgo.sh"
  extract_fn ask_build_pgo    >> "$ROOT/pgo.sh"
  # Sin perfiles: se dice cómo tener uno y se sigue sin PGO. Un menú que
  # ofrece PGO cuando no hay nada que usar solo enseña aSay "sí" y luego
  # compila sin PGO, que es el peor resultado posible: silencioso.
  rm -rf "$ROOT/kp"; mkdir -p "$ROOT/kp"
  cat > "$ROOT/pgo-run.sh" <<'PGORUN'
W=''; Y=''; N=''
VERSION="${VERSION:-7.2.8}"; CC_FAMILY="${CC_FAMILY:-clang}"; CC_LAUNCHER="${CC_LAUNCHER:-clang}"
CIZEN_PGO_DIR="${CIZEN_PGO_DIR:?}"; CIZEN_PGO_PROFILE="${CIZEN_PGO_PROFILE:-}"
PGO_REQUESTED="${PGO_REQUESTED:-false}"; PGO_EXPLICIT="${PGO_EXPLICIT:-false}"; PGO_CHANGED=0
log(){ :; }
ok(){ printf '  ok: %s\n' "$*"; }
info(){ printf '  info: %s\n' "$*"; }
warn(){ printf '  warn: %s\n' "$*"; }
fatal(){ printf '  fatal: %s\n' "$*"; FATAL=1; }
FATAL=0
prefs_interactive(){ return 0; }
prefs_read(){ local __v=''; read -r __v || __v=''; printf -v "$1" '%s' "$__v"; }
# shellcheck disable=SC1090
source "$ROOT_FNS"
ask_build_pgo
printf 'RES req=%s chg=%s perfil=%s\n' "$PGO_REQUESTED" "$PGO_CHANGED" \
  "$(basename -- "${CIZEN_PGO_PROFILE:-<ninguno>}")"
PGORUN
  pgo_run() { # $1=stdin, resto=entorno
    ( ROOT_FNS="$ROOT/pgo.sh"; export ROOT_FNS
      CIZEN_PGO_DIR="$ROOT/kp"; export CIZEN_PGO_DIR
      eval "$@"
      export CC_FAMILY CC_LAUNCHER PGO_REQUESTED PGO_EXPLICIT FATAL 2>/dev/null || :
      bash "$ROOT/pgo-run.sh" 2>&1 )
  }
  ui_pgo_none="$(printf '\n' | pgo_run ':')"
  if printf '%s' "$ui_pgo_none" | grep -q 'todavía no hay ningún perfil' \
     && printf '%s' "$ui_pgo_none" | grep -q 'pgo-collect.sh --duration 900' \
     && printf '%s' "$ui_pgo_none" | grep -q 'RES req=false chg=0 perfil=<ninguno>'; then
    rec ok "motor: PGO sin ningún perfil explica cómo obtenerlo y sigue SIN PGO (no finge)"
  else
    rec fail "motor: sin perfiles, el PGO no explica nada o finge activarse ('$ui_pgo_none')"
  fi
  # Con perfiles: Enter se lleva el marcado con *, y 'n' pasa. Antes el Enter
  # se ignoraba y el '*' de la pantalla mentía.
  head -c 512 /dev/urandom > "$ROOT/kp/7.2.7.afdo"
  head -c 640 /dev/urandom > "$ROOT/kp/7.2.8-cizen-v3.afdo"
  ui_pgo_enter="$(printf '\n' | pgo_run ':')"
  if printf '%s' "$ui_pgo_enter" | grep -q '\*2) 7.2.8-cizen-v3.afdo' \
     && printf '%s' "$ui_pgo_enter" | grep -q 'RES req=true chg=1 perfil=7.2.8-cizen-v3.afdo'; then
    rec ok "motor: PGO con perfiles → Enter usa el recomendado (y lo marca con *)"
  else
    rec fail "motor: Enter no se lleva el perfil recomendado ('$ui_pgo_enter')"
  fi
  ui_pgo_n="$(printf 'n\n' | pgo_run ':')"
  if printf '%s' "$ui_pgo_n" | grep -q 'RES req=false chg=0 perfil=<ninguno>'; then
    rec ok "motor: PGO → 'n' compila sin PGO a propósito"
  else
    rec fail "motor: con 'n' se activa PGO igualmente ('$ui_pgo_n')"
  fi
  ui_pgo_idx="$(printf '1\n' | pgo_run ':')"
  if printf '%s' "$ui_pgo_idx" | grep -q 'RES req=true chg=1 perfil=7.2.7.afdo'; then
    rec ok "motor: PGO → elegir un número de la lista coge ese perfil"
  else
    rec fail "motor: el número de la lista no se respeta ('$ui_pgo_idx')"
  fi
  # gcc: AutoFDO es de LLVM. Se explica y se sigue sin PGO; jamás se finge.
  ui_pgo_gcc="$(printf '\n' | pgo_run 'CC_FAMILY=gcc CC_LAUNCHER=gcc')"
  if printf '%s' "$ui_pgo_gcc" | grep -q 'PGO AutoFDO exige clang' \
     && printf '%s' "$ui_pgo_gcc" | grep -q 'RES req=false chg=0 perfil=<ninguno>'; then
    rec ok "motor: con gcc, PGO dice que AutoFDO es de clang y compila sin él"
  else
    rec fail "motor: con gcc el PGO no se explica o se cuela igual ('$ui_pgo_gcc')"
  fi
  # --pgo a secas y sin perfiles: se para con instrucciones, no con un fallo sordo.
  rm -f "$ROOT"/kp/*.afdo
  ui_pgo_expl="$(printf '\n' | pgo_run 'PGO_REQUESTED=true PGO_EXPLICIT=true')"
  if printf '%s' "$ui_pgo_expl" | grep -q 'fatal: Se pidió PGO' \
     && printf '%s' "$ui_pgo_expl" | grep -q 'pgo-collect.sh --duration 900'; then
    rec ok "motor: --pgo sin ningún perfil separa con el cómo, no con un error pelado"
  else
    rec fail "motor: --pgo sin perfil no explica cómo obtenerlo ('$ui_pgo_expl')"
  fi
  # --pgo a secas y con perfil: elige solo, sin preguntar (es lo que pide la opción 18).
  head -c 512 /dev/urandom > "$ROOT/kp/7.2.7.afdo"
  head -c 640 /dev/urandom > "$ROOT/kp/7.2.8-cizen-v3.afdo"
  ui_pgo_auto="$(printf '\n' | pgo_run 'PGO_REQUESTED=true PGO_EXPLICIT=true')"
  if printf '%s' "$ui_pgo_auto" | grep -q 'RES req=true chg=1 perfil=7.2.8-cizen-v3.afdo'; then
    rec ok "motor: --pgo elige el perfil de la versión objetivo sin preguntar"
  else
    rec fail "motor: --pgo no auto-elige el perfil ('$ui_pgo_auto')"
  fi
  # Orden: PGO se pregunta DESPUÉS del compilador, para poder exigir clang.
  if sed -n '/^ask_build_prefs() {/,/^}/p' "$MOTOR" \
       | grep -E '^ *(apply_cc_choice|ask_build_pgo)' | sed 's/^ *//' | awk '{print $1}' \
       | head -2 | paste -sd'|' - | grep -qx 'apply_cc_choice|ask_build_pgo'; then
    rec ok "motor: PGO se pregunta después del compilador (para poder exigir clang)"
  else
    rec fail "motor: PGO se pregunta antes del compilador, o no se pregunta en ask_build_prefs"
  fi
  # El perfil elegido tiene que entrar en la fase de config y disparar la
  # revalidación, igual que el compilador. Si no, CONFIG_AUTOFDO_CLANG se
  # encendería a medias sin pasar por la auditoría.
  #
  # OJO: esto se mira DENTRO de ask_build_prefs y no en el motor entero. El
  # motor ya mete CLANG_AUTOFDO_PROFILE en KCONFIG_CC_OPTS al arrancar (para
  # cuando el perfil viene por flag o por el entorno), así que un grep global
  # daba verde aunque la inyección TARDÍA —la de un perfil elegido en la
  # pregunta, que es justo la nueva— hubiera desaparecido. Ese fallo es
  # silencioso: el .config se prepara sin PGO, la compilación usa
  # -fprofile-sample-use sin CONFIG_AUTOFDO_CLANG detrás, y ni la auditoría ni
  # la validación se enteran.
  prefs_block="$(sed -n '/^ask_build_prefs() {/,/^}/p' "$MOTOR")"
  for trozo in 'ask_build_pgo' \
               'KCONFIG_CC_OPTS+=("CLANG_AUTOFDO_PROFILE=$CIZEN_PGO_PROFILE")'; do
    if printf '%s' "$prefs_block" | grep -qF -- "$trozo"; then
      rec ok "motor: dentro de ask_build_prefs, «$trozo»"
    else
      rec fail "motor: «$trozo» no está en ask_build_prefs (config y build se desincronizarían)"
    fi
  done
  if printf '%s' "$prefs_block" | grep -qF 'revalidate_config_chain "$why"' \
     && printf '%s' "$prefs_block" | grep -qF '|| [ "$PGO_CHANGED" = 1 ]; then'; then
    rec ok "motor: cambiar el PGO obliga a revalidar la config"
  else
    rec fail "motor: se puede cambiar el PGO sin revalidar la config"
  fi
  # Y la inyección no puede quedar suelta: tiene que ir DENTRO del guard de
  # PGO_CHANGED. Con el guard puesto pero la línea fuera, o al revés, el grep
  # anterior daba verde y el perfil no llegaba a la fase de config.
  # (los comentarios se quitan antes, o la distancia entre el guard y la línea
  # que guarda depende de cuántos explicadores se hayan escrito encima)
  prefs_sin_comentarios="$(printf '%s' "$prefs_block" | grep -vE '^[[:space:]]*#')"
  if printf '%s' "$prefs_sin_comentarios" \
       | grep -A2 'if \[ "\$PGO_CHANGED" = 1 \]; then' \
       | grep -qF 'KCONFIG_CC_OPTS+=("CLANG_AUTOFDO_PROFILE=$CIZEN_PGO_PROFILE")'; then
    rec ok "motor: el perfil entra en KCONFIG_CC_OPTS solo cuando PGO ha cambiado"
  else
    rec fail "motor: el perfil no entra en KCONFIG_CC_OPTS tras elegirlo"
  fi
  # Si no hay perfil de la versión exacta, el recommended cae al más reciente
  # (no a nada). Con un kernel nuevo y perfiles viejos, devolver vacío haría que
  # el Enter se comiera el PGO sin avisar.
  ui_pgo_fallback="$(printf '\n' | pgo_run 'VERSION=99.99')"
  if printf '%s' "$ui_pgo_fallback" | grep -q 'RES req=true chg=1 perfil=7.2.8-cizen-v3.afdo'; then
    rec ok "motor: sin perfil de la versión exacta, PGO ofrece el más reciente"
  else
    rec fail "motor: sin perfil de la versión exacta, PGO se queda sin nada ('$ui_pgo_fallback')"
  fi
  # El sufijo del resumen. Con PGO_CHANGED=0 debe ser VACÍO. Antes el mensaje
  # usaba ${PGO_CHANGED:+ + PGO}, y :+ pregunta por "vacío", no por "distinto
  # de 1": el 0 no está vacío, así que TODAS las compilaciones anunciaban
  # "+ PGO". Se vio en una build real sin ningún perfil. Es la clase de fallo
  # másníkmolesta que hay: la build es correcta y el resumen miente.
  # Las funciones de PGO viven en el fichero extraído, que se sourcea dentro
  # del subbanco; para medirlas aquí hace falta un shell que las cargue.
  pgo_suf() { ROOT_FNS="$ROOT/pgo.sh"; export ROOT_FNS
              bash -c 'source "$ROOT_FNS"; PGO_CHANGED="$1"; pgo_disp_suffix' _ "$1" 2>/dev/null; }
  suf0="$(pgo_suf 0)"; suf1="$(pgo_suf 1)"
  if [ -z "$suf0" ] && [ "$suf1" = ' + PGO' ]; then
    rec ok "motor: el resumen dice «+ PGO» solo si el PGO se Activó de verdad"
  else
    rec fail "motor: el resumen miente sobre el PGO (0→'$suf0', 1→'$suf1')"
  fi
  # Y que las dos líneas que lo usan no usen la forma peligrosa.
  if printf '%s' "$prefs_block" | grep -qF '$(pgo_disp_suffix).' \
     && ! printf '%s' "$prefs_block" | grep -qF '${PGO_CHANGED:+'; then
    rec ok "motor: el resumen de la build usa el sufijo, no ${VAR:+}"
  else
    rec fail "motor: el resumen vuelve al idioma peligroso ${PGO_CHANGED:+}"
  fi
  # La pantalla tiene que explicar QUÉ se está eligiendo, no solo listar: una
  # lista de nombres de fichero sin encabezado no dice qué es PGO ni qué hace
  # el Enter.
  if printf '%s' "$ui_pgo_enter" | grep -q 'PGO (AutoFDO)' \
     && printf '%s' "$ui_pgo_enter" | grep -q 'Enter usa el marcado con \*'; then
    rec ok "motor: la pantalla de PGO dice qué se elige y qué hace el Enter"
  else
    rec fail "motor: la pantalla de PGO no explica el encabezado ni el Enter ('$ui_pgo_enter')"
  fi
  # Una ruta tecleada a mano que no existe tiene que parar, no compilar con un
  # perfil imaginario: -fprofile-sample-use con un fichero ausente falla mucho
  # más tarde y en mitad de la build.
  ui_pgo_ruta="$(printf '/no/existe/p.afdo\n' | pgo_run ':')"
  if printf '%s' "$ui_pgo_ruta" | grep -q 'fatal: El perfil PGO elegido no es un fichero legible'; then
    rec ok "motor: una ruta de PGO inexistente se rechaza con un error claro"
  else
    rec fail "motor: una ruta de PGO inexistente se acepta en silencio ('$ui_pgo_ruta')"
  fi
  # Los flags existen y son opt-in explícito. Se buscan en la posición del
  # parser (sangrados cuatro, como el resto de los casos), no en cualquier
  # sitio: la cadena «--pgo)» también sale en el texto de error, y un grep
  # global daba verde con el flag fuera del parser.
  for flag in '--pgo)' '--no-pgo)'; do
    if grep -qE "^ +${flag}\$" "$MOTOR"; then
      rec ok "motor: el flag «$flag» está en el parser"
    else
      rec fail "motor: falta el flag «$flag» en el parser"
    fi
  done
  # --pgo a secas busca el perfil, --no-pgo lo apaga, y los dos marcan la
  # decisión como explícita para que la pregunta no se repita.
  if grep -qE '^ +PGO_REQUESTED=false; PGO_EXPLICIT=true; CIZEN_PGO_PROFILE=""' "$MOTOR"; then
    rec ok "motor: --no-pgo limpia el perfil heredado del entorno (si no, no apagaba nada)"
  else
    rec fail "motor: --no-pgo deja el CIZEN_PGO_PROFILE del entorno y PGO sigue encendido"
  fi
  if grep -qE '^ +PGO_REQUESTED=true; PGO_EXPLICIT=true$' "$MOTOR" \
     && grep -qE '^ +PGO_REQUESTED=false; PGO_EXPLICIT=true; CIZEN_PGO_PROFILE=""' "$MOTOR"; then
    rec ok "motor: --pgo y --no-pgo cuentan como decisión explícita (no se vuelve a preguntar)"
  else
    rec fail "motor: --pgo/--no-pgo no marcan PGO_EXPLICIT"
  fi
  # La opción del menú: propia, y el rango la incluye.
  MENU="$(dirname "$MOTOR")/kernel-update-menu.sh"
  if grep -q 'opt 18 "pgo"' "$MENU" && grep -q '\[0-18\]' "$MENU" \
     && grep -q '18) build_and_exec.*--pgo' "$MENU"; then
    rec ok "menú: PGO tiene su propia opción (18) y el rango la cubre"
  else
    rec fail "menú: la opción 18 de PGO no está, o el rango no llega a 18"
  fi

  # La UI a stdout, no a stderr (si stderr no es la terminal, el submenú
  # desaparecería), y el prompt impreso, no `read -p`.
  if grep -q 'prefs_read()' "$MOTOR" && ! grep -q "read -r -t 300 -p '  %bVariante" "$MOTOR"; then
    rec ok "motor: las preguntas leen de /dev/tty con el prompt ya impreso (visible sin terminal en stderr)"
  else
    rec fail "motor: la UI de las preguntas depende de stderr o de `read -p`"
  fi
  # Quien llama puede silenciarlas (14, o quien ya las preguntó por su cuenta).
  if grep -q 'NO_ASK_VARIANT' "$MOTOR" && grep -q 'NO_ASK_CC' "$MOTOR" \
     && grep -q 'Variante ya elegida por quien invoca el motor' "$MOTOR" \
     && grep -q 'Pregunta del compilador desactivada' "$MOTOR"; then
    rec ok "motor: --no-ask-variant y --no-ask-cc evitan la pregunta duplicada"
  else
    rec fail "motor: --no-ask-cc / --no-ask-variant no están respetados"
  fi
  # Un --cc explícito ES una elección hecha: no se vuelve a preguntar.
  if grep -q 'CC_EXPLICIT=true' "$MOTOR" && grep -q 'Compilador ya indicado explícitamente' "$MOTOR"; then
    rec ok "motor: --cc explícito no se vuelve a preguntar"
  else
    rec fail "motor: se pregunta el compilador aunque se haya pasado --cc"
  fi
  # Elegir compilador después de validar tiene que re-resolver y revalidar: si no,
  # la config se validó con un CC y se compila con otro (y LTO puede quedarse
  # puesto con gcc, que no lo soporta).
  for trozo in 'apply_cc_choice()' '_resolve_cc_compiler ||' 'KCONFIG_CC_OPTS=()' \
               'CIZEN_LLVM_LTO=0' 'require_cc_toolchain; then' 'revalidate_config_chain' \
               'LTO (${CIZEN_LLVM_LTO}) exige clang'; do
    if grep -qF -- "$trozo" "$MOTOR"; then
      rec ok "motor: la elección tardía de CC llega a «$trozo»"
    else
      rec fail "motor: la elección tardía de CC no llega a «$trozo» (config y build se desincronizarían)"
    fi
  done
  # Un scheduler de solo-fork sobre un árbol vanilla no puede "aplicarse y ya":
  # o se relanza con el árbol del fork, o se dice por qué no.
  if grep -q 'fork_release_guard' "$MOTOR" && grep -q 'fork_release_guard "\$VARIANT_CHOICE"' "$MOTOR"; then
    rec ok "motor: la elección de scheduler se comprueba contra el árbol antes de aplicarla"
  else
    rec fail "motor: no se comprueba que el scheduler elegido exista en el árbol actual"
  fi
  if grep -q 'exec "\$ENGINE_SELF" .*--tree cachyos --sched "\$2"' "$MOTOR"; then
    rec ok "motor: el relanzamiento al árbol del fork lleva --tree cachyos y el scheduler"
  else
    rec fail "motor: el relanzamiento al fork no pasa --tree cachyos (volvería a fallar igual)"
  fi
  if ! grep -q 'se continúa compilando Vanilla' "$MOTOR" \
     && ! sed -n '/^ask_build_prefs() {/,/^}/p' "$MOTOR" | grep -q 'se continúa compilando Vanilla'; then
    rec ok "motor: si el scheduler elegido no se puede aplicar, se aborta (no degrada a Vanilla en silencio)"
  else
    rec fail "motor: un scheduler pedido que no se aplica degrada a Vanilla en silencio"
  fi

  # ── Kconfig: el índice no sobrevive a un parche, y los tipos se respetan ──
  # El bug que motivó esto: el índice de símbolos se cacheaba una sola vez por
  # proceso, ANTES de aplicar el parche BORE. Al validar, el motor decía
  # "CONFIG_SCHED_BORE no existe en esta versión" para un símbolo que el propio
  # parche acababa de añadir en init/Kconfig, y proponía un --rename que no
  # arreglaba nada (era cache, no renombre).
  mkdir -p "$ROOT/src/init" "$ROOT/src/kernel"
  cat > "$ROOT/src/init/Kconfig" <<'KCFG'
config SCHED_BORE
	bool "Enable BORE"
	default y
config FOO_BAR_A
	bool
config FOO_BAR_B
	bool
config FOO_BAR_BAZ
	bool
config ZZZ_TEST_ALPHA
	bool
KCFG
  cat > "$ROOT/src/kernel/Kconfig.hz" <<'KCFG'
config HZ
	int "Default HZ"
	default 250
config MIN_BASE_SLICE_NS
	int "Minimal time slice"
	default 2000000
KCFG
  cat > "$ROOT/kfn.sh" <<'EXTRACT'
SRC="$ROOT/src"
EXTRACT
  : > "$ROOT/kfn.sh"
  for f in kconfig_index_invalidate build_kconfig_indexes build_kconfig_symbol_index \
           build_kconfig_type_index kconfig_symbol_type kconfig_symbol_known \
           kconfig_auto_candidate; do
    sed -n "/^$f() {/,/^}/p" "$MOTOR" >> "$ROOT/kfn.sh"
  done
  cat > "$ROOT/kprobe.sh" <<'PROBE'
set -u
# v27.31.29: el motor trabaja con IFS=$'\n\t'. Sin reproducirlo aquí, un
# "read -r sym tipo" parte por el espacio en el arnés y no en el motor, y los
# bugs de parseo del índice de tipos pasan desapercibidos (pasó en v27.31.28:
# las claves acababan siendo "SIMBOLO int" y ningún tipo se encontraba).
printf 'IFS=%q\n' $'\n\t'
SRC="$ROOT/src"
declare -A KCONFIG_SYMBOL_KNOWN=() KCONFIG_SYMBOL_TYPE=()
KCONFIG_TYPE_INDEX_BUILT=false
KCONFIG_SYMBOL_INDEX_BUILT=false
# shellcheck disable=SC1090
source "$ROOT/kfn.sh"
build_kconfig_symbol_index >/dev/null 2>&1
build_kconfig_type_index  >/dev/null 2>&1
printf 'CLAVE_SIMP %s\n' "$(kconfig_symbol_type HZ >/dev/null; echo HZ)"
printf 'TIPOS %s %s %s %s\n' \
  "$(kconfig_symbol_type SCHED_BORE)" "$(kconfig_symbol_type HZ)" \
  "$(kconfig_symbol_type MIN_BASE_SLICE_NS)" "$(kconfig_symbol_type FOO_BAR_A)"
printf 'NUEVO %s\n' "$(kconfig_symbol_known NUEVO_DE_PATCH && echo sí || echo no)"
printf 'CAND_SIMILAR %s\n' "$(kconfig_auto_candidate ZZZ_TEST_BETA)"
printf 'CAND_SPLIT %s\n' "$(kconfig_auto_candidate SCHED_BORE_MITIGATION)"
printf 'CAND_NSA %s\n' "$(kconfig_auto_candidate MIN_BASE_SLICE_NZ)"
printf 'CAND_TIE %s\n' "$(kconfig_auto_candidate FOO_BAR_C)"
printf 'CAND_FAR %s\n' "$(kconfig_auto_candidate X86_X2APIC_PRESERVE)"
PROBE
  if [ -s "$ROOT/kfn.sh" ]; then
    p1="$(bash "$ROOT/kprobe.sh" 2>&1)"
    # El síntoma exacto del bug: el tipo se busca por el nombre del símbolo, y
    # con el IFS del motor la clave se guardaba con el tipo pegado ("HZ int").
    if [ "$(printf '%s\n' "$p1" | grep '^CLAVE_SIMP ')" = "CLAVE_SIMP HZ" ]; then
      rec ok "kconfig: con el IFS del motor las claves del índice de tipos son el nombre pelado"
    else
      rec fail "kconfig: las claves del índice de tipos llevan el tipo pegado ('$(printf '%s\n' "$p1" | grep '^CLAVE_SIMP ')')"
    fi
    if [ "$(printf '%s\n' "$p1" | grep '^TIPOS ')" = "TIPOS bool int int bool" ]; then
      rec ok "kconfig: el índice distingue bool de int (un int no se fuerza a =y)"
    else
      rec fail "kconfig: tipos mal leídos ('$(printf '%s\n' "$p1" | grep '^TIPOS ')', esperado 'TIPOS bool int int bool')"
    fi
    if [ "$(printf '%s\n' "$p1" | grep '^NUEVO ')" = "NUEVO no" ]; then
      rec ok "kconfig: un símbolo que aún no está en el árbol se detecta como desconocido"
    else
      rec fail "kconfig: símbolo inexistente dado por bueno"
    fi
    if [ "$(printf '%s\n' "$p1" | grep '^CAND_SIMILAR ')" = "CAND_SIMILAR ZZZ_TEST_ALPHA" ] &&
       [ "$(printf '%s\n' "$p1" | grep '^CAND_NSA ')" = "CAND_NSA MIN_BASE_SLICE_NS" ]; then
      rec ok "kconfig: el renombrado automático encuentra el candidato único"
    else
      rec fail "kconfig: el renombrado automático no encuentra lo evidente ('$p1')"
    fi
    # v27.31.29: dos casos que PARECEN renombres y no lo son. Con la regla laxa se
    # "renombraban" y activaban un símbolo que el perfil no pidió nunca
    # (PREEMPT_DYNAMIC_KSYMS -> PREEMPT_DYNAMIC, PERF_GUEST_EVENTS -> PERF_EVENTS).
    if [ "$(printf '%s\n' "$p1" | grep '^CAND_SPLIT ')" = "CAND_SPLIT " ]; then
      rec ok "kconfig: una división de feature no se confunde con un renombrado"
    else
      rec fail "kconfig: se renombra un símbolo que solo es parte de otro ('$p1')"
    fi
    if [ "$(printf '%s\n' "$p1" | grep '^CAND_TIE ')" = "CAND_TIE " ]; then
      rec ok "kconfig: con dos candidatos parecidos no se inventa ninguno"
    else
      rec fail "kconfig: ante un empate se elige un símbolo al azar ('$p1')"
    fi
    if [ "$(printf '%s\n' "$p1" | grep '^CAND_FAR ')" = "CAND_FAR " ]; then
      rec ok "kconfig: un símbolo sin parecido real se omite en vez de renombrar por fuerza"
    else
      rec fail "kconfig: renombrado por la fuerza donde no hay parecido ('$p1')"
    fi
    # El parche añade un símbolo nuevo: si el índice no se tira, el validador va
    # a decir que no existe y el build se queda en 37/38 sin explicación.
    printf 'config NUEVO_DE_PATCH\n\tbool\n' >> "$ROOT/src/init/Kconfig"
    if [ "$(bash "$ROOT/kprobe.sh" 2>&1 | grep '^NUEVO ')" = "NUEVO sí" ]; then
      rec ok "kconfig: al invalidar el índice aparece el símbolo que añadió el parche"
    else
      rec fail "kconfig: el índice sobrevive al parche (bug del 37/38)"
    fi
  else
    rec fail "kconfig: no se pudieron extraer las funciones del índice del motor"
  fi
  if grep -q 'kconfig_index_invalidate' "$MOTOR" &&
     awk '/^  if ! patch -p1 -d "\$SRC"/,/^  apply_patch_register "\$name"/' "$MOTOR" |
       grep -q 'kconfig_index_invalidate'; then
    rec ok "kconfig: aplicar un parche tira el índice antes de registrar sus símbolos"
  else
    rec fail "kconfig: el parche no invalida el índice (el símbolo recién añadido saldría como inexistente)"
  fi
  if grep -q 'bool|tristate|"")' "$MOTOR" &&
     grep -q 'PATCH_VALUE_SYMBOLS+=' "$MOTOR"; then
    rec ok "kconfig: los símbolos no booleanos de un parche van a su propia lista, no a =y"
  else
    rec fail "kconfig: apply_patch_register sigue forzando a =y símbolos que no son booleanos"
  fi
  if grep -q 'activación(es) sin satisfacer' "$MOTOR" &&
     grep -q 'ENABLE_FAIL\[@\]}' "$MOTOR"; then
    rec ok "kconfig: el resumen de validación nombra los símbolos que faltan"
  else
    rec fail "kconfig: la validación sigue diciendo 37/38 sin decir de qué símbolo"
  fi
  if grep -q 'auto_resolve_effective_symbols' "$MOTOR" &&
     grep -q 'save-auto-renames' "$MOTOR"; then
    rec ok "kconfig: los renombres automáticos se aplican y se pueden guardar con --save-auto-renames"
  else
    rec fail "kconfig: los renombres automáticos no se aplican ni se pueden persistir"
  fi

  # v27.31.29 (regresión de v27.31.28): al reconstruir los arrays por un
  # renombre automático, SETVAL/SETSTR se codificaban como "SYM=$>valor" y se
  # recuperaban con ${x%%=*>}/${x#*=>}. Ese patrón exige un '>' al FINAL del
  # match, pero el valor va detrás del separador, así que NUNCA casaba: la clave
  # quedaba siendo el string entero ("HZ=$>1000") y el validador contaba 28
  # SETVAL + 1 SETSTR como inexistentes con una .config correcta. Se fertilizers
  # scripts/config writing basura real a .config (CONFIG_DRM_I915_FORCE_PROBE).
  : > "$ROOT/arn.sh"
  sed -n '/^auto_resolve_effective_symbols() {/,/^}/p' "$MOTOR" >> "$ROOT/arn.sh"
  if [ -s "$ROOT/arn.sh" ]; then
    cat > "$ROOT/arn_probe.sh" <<'ARNPROBE'
set -u
declare -A EFF_SETVAL=() EFF_SETSTR=() APPLIED_RENAMES=() AUTO_RENAMES=()
declare -a EFF_ENABLE=() EFF_DISABLE=() EFF_CRITICAL=()
build_kconfig_symbol_index() { :; }
kconfig_symbol_known() { [ "$1" = VIEJO ] && return 1 || return 0; }
kconfig_auto_candidate() { [ "$1" = VIEJO ] && printf 'NUEVO'; }
EFF_ENABLE=(NO_HZ_IDLE VIEJO); EFF_DISABLE=(); EFF_CRITICAL=()
EFF_SETVAL=( [HZ]=1000 [VIEJO]=y [KVM_MAX_NR_VCPUS]=1024 )
EFF_SETSTR=( [DRM_PANIC_SCREEN]=user [DRM_I915_FORCE_PROBE]= )
SRC=/tmp
# shellcheck disable=SC1090
source "$1"
auto_resolve_effective_symbols
for k in "${!EFF_SETVAL[@]}"; do printf 'SV %s=%s\n' "$k" "${EFF_SETVAL[$k]}"; done
for k in "${!EFF_SETSTR[@]}"; do printf 'SS %s=%s\n' "$k" "${EFF_SETSTR[$k]}"; done
ARNPROBE
    p2="$(bash "$ROOT/arn_probe.sh" "$ROOT/arn.sh" 2>&1)"
    if printf '%s\n' "$p2" | grep -q '\$>' &&
       printf '%s\n' "$p2" | grep -q 'SV HZ=HZ=\$>1000'; then
      rec fail "kconfig: el renombrado corrompe las claves SETVAL ('$p2')"
    else
      rec ok "kconfig: el renombrado automático conserva intactas las claves y valores SETVAL/SETSTR"
    fi
    if [ "$(printf '%s\n' "$p2" | grep -c '^SV ')" = "3" ] &&
       printf '%s\n' "$p2" | grep -q '^SV NUEVO=y$' &&
       printf '%s\n' "$p2" | grep -q '^SS DRM_PANIC_SCREEN=user$'; then
      rec ok "kconfig: el renombrado también se propaga a SETVAL y conserva los valores"
    else
      rec fail "kconfig: el renombrado perdió o duplicó entradas de SETVAL ('$p2')"
    fi
  else
    rec fail "kconfig: no se pudo extraer auto_resolve_effective_symbols"
  fi

  # ── sudo: fallar pronto y con explicación, no con una línea de código ──
  # Un `sudo -v` pelado que falla aborta con el ERR trap ("Error 1 en línea
  # 8614: sudo -v"), que no dice por qué ni qué hacer; y como el ticket caduca a
  # los 5 minutos, el segundo prompt cae tras la compilación, cuando 20 minutos
  # ya están gastados. Aquí se ejercita el preflight con un sudo falso.
  if grep -qE '^\s*sudo -v\s*$' "$MOTOR"; then
    rec fail "sudo: queda un 'sudo -v' que aborta el build con el ERR trap en vez de usar preflight_sudo"
  else
    rec ok "sudo: ningún 'sudo -v' pelado (usa preflight_sudo o es best-effort)"
  fi
  if [ "$(grep -c 'preflight_sudo' "$MOTOR")" -ge 3 ]; then
    rec ok "sudo: preflight_sudo tanto al arrancar como tras compilar"
  else
    rec fail "sudo: preflight_sudo no cubre los dos puntos donde caduca el ticket"
  fi
  # El inventario de operaciones privilegiadas tiene que seguir existiendo: si el
  # motor empieza a usar un comando nuevo, el aviso "no puede seguir" lo nombra.
  descuadre=""
  for op in mount umount install pacman chown mkdir rm; do
    grep -q "sudo $op" "$MOTOR" || descuadre="$descuadre $op(al-motor)"
    grep -qE "^SUDO_OPS_REQUERIDOS=.*\b$op\b" "$MOTOR" || descuadre="$descuadre $op(inventario)"
  done
  if [ -z "$descuadre" ]; then
    rec ok "sudo: el inventario de operaciones privilegiadas está sincronizado con el motor"
  else
    rec fail "sudo: inventario de operaciones desincronizado:$descuadre"
  fi

  # Un sed por rango: con dos rangos en la misma expresión GNU sed deja el
  # primero abierto y duplica las líneas de los Intermediate (parece un bug del
  # propio GNU sed; verificado con un fichero mínimo).
  : > "$ROOT/sudofn.sh"
  sed -n '/^SUDO_OPS_REQUERIDOS=/,/)/p'      "$MOTOR" >> "$ROOT/sudofn.sh"
  sed -n '/^SUDO_OPS_OPCIONALES=/,/)/p'     "$MOTOR" >> "$ROOT/sudofn.sh"
  sed -n '/^sudo_nopasswd_cover() {/,/^}/p' "$MOTOR" >> "$ROOT/sudofn.sh"
  sed -n '/^sudo_missing_ops() {/,/^}/p'    "$MOTOR" >> "$ROOT/sudofn.sh"
  sed -n '/^sudo_explain_no_ticket() {/,/^}/p' "$MOTOR" >> "$ROOT/sudofn.sh"
  sed -n '/^preflight_sudo() {/,/^}/p'      "$MOTOR" >> "$ROOT/sudofn.sh"
  if ! bash -n "$ROOT/sudofn.sh" 2>/dev/null; then
    rec fail "sudo: no se pudieron extraer las funciones del preflight (el sed de los tests quedó desfasado)"
    sudofn_ok=false
  else
    sudofn_ok=true
  fi
  cat > "$ROOT/sudo-stub.sh" <<'STUB'
warn() { echo "WARN: $*"; }
info() { echo "INFO: $*"; }
log()  { echo "LOG: $*"; }
ok()   { echo "OK: $*"; }
fatal(){ echo "FATAL: $*"; exit 9; }
STUB
  mkdir -p "$ROOT/fakebin"
  # sudo falso, con el comportamiento elegido por FAKE_SUDO:
  #   ticket   -> `sudo -n true` funciona (ticket vigente)
  #   passwd   -> `sudo -v` falla como cuando la contraseña no es la correcta
  #   nopasswd -> el allowlist cubre lo imprescindible y `sudo -v` falla
  cat > "$ROOT/fakebin/sudo" <<'FAKESUDO'
#!/bin/bash
case "$FAKE_SUDO" in
  ticket) exit 0 ;;
  passwd|nopasswd|nopasswdall)
    if [ "$1" = "-n" ] && [ "$2" = "-l" ]; then
      # Ruido real de `sudo -l`: nada de esto es una lista de comandos, y sus
      # rutas deben filtrarse (si no, salen "bin", "sbin", "visudo", "binRunas").
      echo "Matching Defaults entries for cizen on archlinux:"
      echo "    secure_path=/usr/local/sbin\\:/usr/local/bin\\:/usr/bin"
      echo "Runas and Command-specific defaults for cizen:"
      echo "    Defaults!/usr/bin/visudo env_keep+=\"SUDO_EDITOR EDITOR VISUAL\""
      echo "    (ALL) ALL"
      if [ "$FAKE_SUDO" = nopasswd ]; then
        # con continuación de línea, como sudo envuelve las listas largas
        echo "    (root) NOPASSWD: /usr/bin/mount, /usr/bin/umount, \\"
        echo "        /usr/bin/install, /usr/bin/pacman, /usr/bin/chown, \\"
        echo "        /usr/bin/mkdir, /usr/bin/rm, /usr/bin/swapon, /usr/bin/swapoff, \\"
        echo "        /usr/bin/systemctl"
      elif [ "$FAKE_SUDO" = nopasswdall ]; then
        echo "    (root) NOPASSWD: ALL"
      else
        echo "    (root) NOPASSWD: /usr/bin/mount, /usr/bin/umount, /usr/bin/install, /usr/bin/pacman"
      fi
      exit 0
    fi
    [ "$1" = "-n" ] && [ "$2" = "true" ] && exit 1
    echo "[sudo] password for cizen: " >&2
    echo "Sorry, try again." >&2
    echo "sudo: 3 incorrect password attempts" >&2
    exit 1 ;;
esac
exit 1
FAKESUDO
  chmod +x "$ROOT/fakebin/sudo"
  cat > "$ROOT/sudo-run.sh" <<'SRUN'
PATH="$ROOT/fakebin:$PATH"; export PATH
# shellcheck disable=SC1090,SC1091
source "$ROOT/sudofn.sh"
source "$ROOT/sudo-stub.sh"
TMPFS_ROOT=/tmp/fake-tmpfs
preflight_sudo
echo "RC=$?"
SRUN
  if [ "$sudofn_ok" = true ]; then
  out_ticket="$(FAKE_SUDO=ticket bash "$ROOT/sudo-run.sh" 2>&1)"
  case "$out_ticket" in
    *"RC=0"*) rec ok "sudo: con ticket vigente el preflight no preguntar y sigue" ;;
    *)        rec fail "sudo: con ticket vigente el preflight falla ('$out_ticket')" ;;
  esac
  out_passwd="$(FAKE_SUDO=passwd bash "$ROOT/sudo-run.sh" 2>&1)"
  if printf '%s' "$out_passwd" | grep -q "sin ticket vigente" &&
     printf '%s' "$out_passwd" | grep -q "necesita privilegios que NO están en esa lista"; then
    rec ok "sudo: sin ticket explica qué falta en vez de abortar con una línea de código"
  else
    rec fail "sudo: el preflight no explica el hueco de privilegios ('$out_passwd')"
  fi
  if printf '%s' "$out_passwd" | grep -q "sudo -k; sudo -v" &&
     printf '%s' "$out_passwd" | grep -q "passwd -S"; then
    rec ok "sudo: el aviso dice cómo comprobar la contraseña (sudo -v a secas, y passwd si tampoco entra)"
  else
    rec fail "sudo: el aviso no dice cómo resolverlo ('$out_passwd')"
  fi
  if printf '%s' "$out_passwd" | grep -q "FATAL:" &&
     printf '%s' "$out_passwd" | grep -q "aún no se ha compilado nada"; then
    rec ok "sudo: si faltan privilegios, avisa de que aún no se ha compilado nada"
  else
    rec fail "sudo: falta el aviso de que no se pierde trabajo ('$out_passwd')"
  fi
  out_np="$(FAKE_SUDO=nopasswd bash "$ROOT/sudo-run.sh" 2>&1)"
  if printf '%s' "$out_np" | grep -q "Se sigue sin ticket sudo" && printf '%s' "$out_np" | grep -q "RC=0"; then
    rec ok "sudo: con el allowlist cubriendo lo imprescindible sigue sin ticket en vez de rendirse"
  else
    rec fail "sudo: no aprovecha un allowlist NOPASSWD suficiente ('$out_np')"
  fi
  if printf '%s' "$out_np" | grep -q "pedirá contraseña más adelante" &&
     printf '%s' "$out_np" | grep -q "cizen-uki-sync"; then
    rec ok "sudo: avisa de qué operaciones pedirán contraseña después (no se rompe a media instalación)"
  else
    rec fail "sudo: no avisa de las operaciones que pedirán contraseña ('$out_np')"
  fi
  # La lista de cubiertos sale de `sudo -l`, cuya salida tiene más cosas que no
  # son comandos (secure_path, Defaults!, "Runas and Command-specific..."). Si se
  # cuela, el aviso le dice al usuario que tiene cubiertos "bin" o "visudo".
  cubiertos="$(printf '%s\n' "$out_np" | sed -n 's/.*NOPASSWD): //p')"
  if [ -n "$cubiertos" ] && ! printf '%s' "$cubiertos" | grep -qE 'bin|sbin|visudo|Runas'; then
    rec ok "sudo: la lista de cubiertos sale limpia (sin rutas de secure_path ni de Defaults)"
  else
    rec fail "sudo: la lista de cubiertos arrastra basura de 'sudo -l' ('$cubiertos')"
  fi
  # sudo también usa continuaciones de línea para listas largas: si no se unen,
  # la segunda mitad de la lista se pierde y parece que falta un comando cubierto.
  if ! printf '%s' "$out_np" | grep -q "Y el build necesita privilegios"; then
    rec ok "sudo: lee listas NOPASSWD partidas en varias líneas (las que envuelve sudo)"
  else
    rec fail "sudo: no se unen las continuaciones de línea de 'sudo -l'; falta algo que sí está cubierto"
  fi
  out_all="$(FAKE_SUDO=nopasswdall bash "$ROOT/sudo-run.sh" 2>&1)"
  if printf '%s' "$out_all" | grep -q "RC=0" && ! printf '%s' "$out_all" | grep -q "FATAL:"; then
    rec ok "sudo: con NOPASSWD: ALL no se para a preguntar nada"
  else
    rec fail "sudo: no reconoce un NOPASSWD: ALL ('$out_all')"
  fi
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

# --- sched-bench.sh: la brújula para comparar schedulers (v27.31.23) ---
# Los schedulers alternativos compiten en latencia interactiva, no en arranque
# ni en throughput. El banco mide las tres cosas; aquí solo se comprueba que no
# se rompe ni arranca una medición de 2 minutos por un argumento mal escrito.
BENCH="$(dirname "$MOTOR")/sched-bench.sh"
if [ -r "$BENCH" ]; then
  bash -n "$BENCH" 2>/dev/null \
    && rec ok "banco: bash -n limpio" \
    || rec fail "banco: no pasa bash -n"
  # Un argumento inválido tiene que salir YA: si se cuela, el usuario se come una
  # medición entera (minutos de CPU al 100%) pensando que va a ver un resumen.
  bash "$BENCH" --basura >/dev/null 2>&1
  [ "$?" -eq 2 ] && rec ok "banco: un argumento desconocido sale con rc=2 sin medir" \
                 || rec fail "banco: un argumento desconocido no corta (rc=$?)"
  SCHED_BENCH_ITERS=0 bash "$BENCH" >/dev/null 2>&1
  [ "$?" -eq 2 ] && rec ok "banco: parámetro fuera de rango sale con rc=2 sin medir" \
                 || rec fail "banco: ITERS=0 no se rechaza"
  CIZEN_VERIFY_STATE_DIR="$ROOT/bench" bash "$BENCH" --resumen >/dev/null 2>&1
  [ "$?" -eq 0 ] && rec ok "banco: --resumen funciona sin historial" \
                 || rec fail "banco: --resumen falla sin ficheros"
  # El scheduler va en el NOMBRE del resultado: dos builds del mismo kernel
  # (7.2.7-cizen-v3 con bore y con bmq) se llaman igual y el segundo machacaba al
  # primero, con lo que la comparación se comparaba consigo misma.
  if grep -q 'sched-bench-\$(uname -r)-\$sched\.txt' "$BENCH"; then
    rec ok "banco: el resultado se nombra por kernel Y scheduler (no se pisan entre builds)"
  else
    rec fail "banco: el nombre del resultado no incluye el scheduler"
  fi
  # Y el scheduler se lee del kernel EN MARCHA, no del pedido: si el arranque
  # Felló y arrancó otro, hay que medir el que hay.
  if grep -q 'sched_actual()' "$BENCH" && grep -q '/proc/config\.gz' "$BENCH" \
     && ! grep -qE 'CIZEN_SCHED|\$SCHED_.*-e |--sched' "$BENCH"; then
    rec ok "banco: el scheduler se deduce de /proc/config.gz, no del que se pidió"
  else
    rec fail "banco: el scheduler medido puede no ser el que está en marcha"
  fi

  # Una fila que no mide nada no puede decidir la mediana. El histórico real tenía
  # dos (iteraciones 0 → 1 ms) y basta una tercera para que la fila entera se
  # mueva: el número basura no se ve, pero sale en la mediana. El resumen tiene
  # que filtrarlas Y decir cuántas deja fuera, que es lo que permite fiarse de él.
  # El histórico se escribe a medias: si dos ejecuciones terminan a la vez, sus
  # bloques quedan PEGADOS y la línea en blanco cae donde sea —incluso en medio
  # de un bloque—. Por eso el delimitante de bloque del resumen tiene que ser la
  # línea `fecha`, no el blanco. Este histórico va pegado y con un blanco dentro
  # del primer bloque: con el blanco como separador, ese bloque se parte en dos y
  # se pierde entero.
  BD="$ROOT/bench-sintetico"
  mkdir -p "$BD"
  (
    fila() { # $1=iteraciones $2=1 hilo $3=N hilos $4=latencia fg
      echo "fecha        : 2026-01-01T00:00:00+00:00"
      echo "kernel       : 0.0.0-test  (build test)"
      echo "scheduler    : TEST"
      echo "núcleos      : 4   carga: 4   iteraciones: $1   fichero: 1MB"
      echo "load medio   : 0.10 0.10 0.10 (antes de medir)"
      echo "1 hilo       : $2 ms"
      if [ -n "${5:-}" ]; then echo; fi
      echo "4 hilos  : $3 ms"
      echo "latencia fg  : $4 ms (mediana de 3 con 4 tareas en carga)"
    }
    fila 1 100  300 10 blanco
    fila 1 200  600 20
    fila 1 400 1200 40
    fila 0   1    1  1
    fila 0   1    1  1
  ) > "$BD/sched-bench-0.0.0-test-TEST.txt"
  # Mediana de las 3 buenas = 200 / 600 / 20. Si las basura contaran, 100 / 300 / 10.
  # Las cifras van con " ms" detrás, así que en la fila son los campos 6, 8 y 10.
  resumen_fila="$(CIZEN_VERIFY_STATE_DIR="$BD" bash "$BENCH" --resumen 2>/dev/null \
    | awk 'NR==2{print $4, $5, $6, $8, $10}')"
  if [ "$resumen_fila" = "3 2 200 600 20" ]; then
    rec ok "banco: --resumen ignora las filas degeneradas y cuenta cuántas deja fuera"
  else
    rec fail "banco: --resumen no filtra las filas con iteraciones 0 (n/desc/medianas: '$resumen_fila')"
  fi

  # Red de seguridad al escribir: si no se midió nada, no se anota. Tiene que salir
  # con rc=1 SIN dejar fila; si anota, el histórico se pudre por dentro aunque el
  # --resumen la filtrara después.
  #
  # Aquí se congela ALSO el reloj, y es lo que hace el test determinista. Con solo
  # el sha256sum nulo, lo que se mide es la latencia de arranque del proceso: aquí
  # 3-4 ms contra un suelo de 5 ms (20 MB x 1 vuelta / 4). Un margen de 1-2 ms, así
  # que basta con que haya una build de kernel corriendo para que la medición se
  # pase el suelo, el guard no dispare y el test se ponga rojo. El suelo está
  # calibrado para el caso REAL (sha256sum leyendo 20 MB a ~400 MB/s), no para el
  # stub, que no lee nada: por eso el reloj fijo, que reproduce el "no pasó tiempo"
  # que el propio guard describe en su comentario, y no una latencia de proceso.
  STUB="$ROOT/stub-sin-hash"; mkdir -p "$STUB"
  printf '#!/bin/sh\nexit 0\n' > "$STUB/sha256sum"; chmod +x "$STUB/sha256sum"
  # date solo se usa en ms() (reloj de la medición) y en la cabecera 'fecha' del
  # histórico, que está DESPUÉS del guard: aquí nunca se llega. Salida constante
  # -> toda medición vale 0 ms -> guard siempre.
  printf '#!/bin/sh\necho 1000000000000\n' > "$STUB/date"; chmod +x "$STUB/date"
  BD2="$ROOT/bench-degenerado"; mkdir -p "$BD2"
  PATH="$STUB:$PATH" CIZEN_VERIFY_STATE_DIR="$BD2" SCHED_BENCH_SIZE_MB=20 \
    SCHED_BENCH_ITERS=1 SCHED_BENCH_REPS=1 SCHED_BENCH_LOAD_N=1 \
    bash "$BENCH" >/dev/null 2>&1
  rc_deg=$?
  n_deg="$(find "$BD2" -name 'sched-bench-*' 2>/dev/null | wc -l)"
  if [ "$rc_deg" -eq 1 ] && [ "$n_deg" -eq 0 ]; then
    rec ok "banco: una medición degenerada no se anota (rc=1, histórico intacto)"
  else
    rec fail "banco: la medición degenerada se anota igual (rc=$rc_deg, ficheros=$n_deg)"
  fi

  # Y lo contrario, porque una guarda que siempre suena no es una guarda: una
  # medición diminuta pero REAL (20 MB, una vuelta) tiene que pasar y anotarse.
  BD3="$ROOT/bench-mini"; mkdir -p "$BD3"
  CIZEN_VERIFY_STATE_DIR="$BD3" SCHED_BENCH_SIZE_MB=20 SCHED_BENCH_ITERS=1 \
    SCHED_BENCH_REPS=1 SCHED_BENCH_LOAD_N=1 bash "$BENCH" >/dev/null 2>&1
  rc_mini=$?
  n_mini="$(find "$BD3" -name 'sched-bench-*' 2>/dev/null | wc -l)"
  if [ "$rc_mini" -eq 0 ] && [ "$n_mini" -eq 1 ]; then
    rec ok "banco: una medición diminuta pero real sí se anota (la guarda no es ruido)"
  else
    rec fail "banco: la guarda salta con una medición real (rc=$rc_mini, ficheros=$n_mini)"
  fi
else
  printf '  (sin %s: se omiten los tests del banco)\n' "$BENCH"
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

_mktree() { # $1=versión $2=tipo [$3=estado de parches|"legacy" para omitir la clave]
  local d="$TMPFS_ROOT/linux-$1" k="$2" p="${3-none}"
  mkdir -p "$d/kernel/sched"
  : > "$d/Makefile"; : > "$d/kernel/Makefile"
  [ "$k" = "cachyos" ] && : > "$d/kernel/sched/poc_selector.c"
  printf 'version=%s\nkind=%s\n' "$1" "$k" > "$d/$TREE_META_NAME"
  # "legacy" = testigo escrito por una versión de la herramienta que no
  # declaraba el estado de parches (v27.31.54 y anteriores).
  [ "$p" = "legacy" ] || printf 'patches=%s\n' "$p" >> "$d/$TREE_META_NAME"
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

printf '%s\n' "== estado de parches del árbol (v27.31.54) =="
# El fallo que motivó esto: la identidad del árbol era solo "<ver>|<tipo>". Un
# vanilla al que la ejecución anterior le aplicó BORE seguía siendo
# "<7.2.8>|vanilla", así que la run siguiente lo reutilizaba y compilaba con el
# parche mientras anunciaba "vanilla" (y el menú ofrecía SCHED_BORE).
#
# Esta sección mueve el estado global (VERSION, KERNEL_TREE, SRC) que las
# secciones siguientes heredan: la de reconcile_tmpfs_trees NO los reasigna en
# su primer test, así que sin restaurarlos acabaría creyendo que el build es
# vanilla 7.2.8 e invirtiendo todas sus expectativas. Se guarda y se devuelve
# igual que los stubs del subshell de más abajo.
_SAVED_VERSION="$VERSION"; _SAVED_TREE="$KERNEL_TREE"; _SAVED_SRC="$SRC"
_SAVED_NOTE="${TREE_FORCE_NOTE:-}"

# Árbol recién extraído: limpio y reutilizable.
rm -rf "$TMPFS_ROOT"; mkdir -p "$TMPFS_ROOT"; : > "$MOUNTED_FLAG"
SRC="$(_mktree 7.2.8 vanilla)"; VERSION=7.2.8; KERNEL_TREE=vanilla
[ "$(tree_patches_list "$SRC")" = "" ] \
  && rec ok "árbol recién extraído (patches=none): limpio" \
  || rec fail "un árbol recién extraído no se lee como limpio: $(tree_patches_list "$SRC")"
tree_clean_reusable "$SRC" 7.2.8 vanilla \
  && rec ok "árbol limpio: reutilizable" \
  || rec fail "un árbol limpio debería ser reutilizable"

# Testigo heredado (sin la clave) y árbol sin testigo: no se puede probar que
# estén limpios, así que NO se reutilizan. Es el mismo criterio que el resto del
# motor: si no se puede probar algo, no se da por bueno.
SRC="$(_mktree 7.2.8 vanilla legacy)"
[ "$(tree_patches_list "$SRC")" = "unknown" ] \
  && rec ok "testigo heredado sin la clave patches: unknown" \
  || rec fail "testigo heredado mal leído: $(tree_patches_list "$SRC")"
! tree_clean_reusable "$SRC" 7.2.8 vanilla \
  && rec ok "testigo heredado: no se reutiliza sin poder probar que está limpio" \
  || rec fail "un árbol de estado desconocido se reutilizó"
SRC="$TMPFS_ROOT/linux-7.2.8-sinte"; mkdir -p "$SRC/kernel/sched"
: > "$SRC/Makefile"; : > "$SRC/kernel/Makefile"
[ "$(tree_patches_list "$SRC")" = "unknown" ] \
  && rec ok "árbol sin testigo: unknown" \
  || rec fail "árbol sin testigo mal leído: $(tree_patches_list "$SRC")"

# El caso real: se aplica BORE y el árbol deja de ser limpio.
SRC="$(_mktree 7.2.8 vanilla)"; VERSION=7.2.8; KERNEL_TREE=vanilla
tree_record_patch bore
[ "$(tree_patches_list "$SRC")" = "bore" ] \
  && rec ok "tras aplicar bore, el testigo lo declara" \
  || rec fail "bore no quedó registrado: $(tree_patches_list "$SRC")"
! tree_clean_reusable "$SRC" 7.2.8 vanilla \
  && rec ok "árbol parcheado con bore: NO se reutiliza como vanilla limpio" \
  || rec fail "un vanilla con BORE se seguiría reutilizando: el fallo original"
# La decisión es "no heredar un estado que este build no ha pedido", no "descartar
# los árboles parcheados siempre". Que el árbol lleve BORE y el build ALSO Acabar
# pidiendo BORE es un caso LEGÍTIMO; que no lo pida, no. El punto ciego era que,
# hasta v27.31.54, el motor no miraba en absoluto este estado.

# Idempotencia y acumulación, sin perder el resto del testigo.
tree_record_patch bore
[ "$(tree_patches_list "$SRC")" = "bore" ] \
  && rec ok "registrar dos veces el mismo parche no lo duplica" \
  || rec fail "parche duplicado: $(tree_patches_list "$SRC")"
tree_record_patch pds
[ "$(tree_patches_list "$SRC")" = "bore,pds" ] \
  && rec ok "dos parches distintos se acumulan" \
  || rec fail "acumulación incorrecta: $(tree_patches_list "$SRC")"
if grep -qx "version=7.2.8" "$SRC/$TREE_META_NAME" \
   && grep -qx "kind=vanilla" "$SRC/$TREE_META_NAME"; then
  rec ok "reescribir patches= conserva version y kind del testigo"
else
  rec fail "reescribir patches= rompió el resto del testigo: $(tr '\n' ' ' < "$SRC/$TREE_META_NAME")"
fi
# Un testigo heredado al que se le registra un parche queda ya verificable.
SRC="$(_mktree 7.2.8 vanilla legacy)"; tree_record_patch bore
[ "$(tree_patches_list "$SRC")" = "bore" ] \
  && rec ok "testigo heredado: al registrar un parche queda con estado conocido" \
  || rec fail "no se pudo registrar sobre un testigo heredado: $(tree_patches_list "$SRC")"

# El gancho de verdad: no basta con que tree_record_patch funcione, tiene que
# estar LLAMADA desde apply_patch_register, que es por donde pasan los dos
# caminos de éxito (parche recién aplicado y parche que ya venía del árbol
# conservado). Si se desconecta, el registro sigue siendo correcto en las
# pruebas unitarias y el fallo vuelve en producción, que es donde estaba.
SRC="$(_mktree 7.2.8 vanilla)"
unset PATCH_SYMBOLS
PATCHES_APPLIED=(); PATCH_ENABLE_ALL=(); PATCH_REBEL_ALL=(); PATCH_VALUE_SYMBOLS=()
apply_patch_register bore
if [ "$(tree_patches_list "$SRC")" = "bore" ]; then
  rec ok "apply_patch_register deja el árbol marcado como parcheado (gancho conectado)"
else
  rec fail "apply_patch_register NO registró el parche en el árbol: $(tree_patches_list "$SRC")"
fi
PATCHES_APPLIED=(); PATCH_ENABLE_ALL=(); PATCH_REBEL_ALL=(); PATCH_VALUE_SYMBOLS=()
apply_patch_register foo
if [ "$(tree_patches_list "$SRC")" = "bore,foo" ]; then
  rec ok "varios parches registrados en orden"
else
  rec fail "acumulación por apply_patch_register: $(tree_patches_list "$SRC")"
fi
PATCHES_APPLIED=(); PATCH_ENABLE_ALL=(); PATCH_REBEL_ALL=(); PATCH_VALUE_SYMBOLS=()
unset PATCH_SYMBOLS

# El registro no puede fallar la build: sin árbol o sin testigo no se rompe nada.
SRC="/nonexistent/arbol"; tree_record_patch bore \
  && rec ok "registrar sin árbol no es un error" || rec fail "registrar sin árbol falló"
SRC="$(_mktree 7.2.8 vanilla)"; rm -f "$SRC/$TREE_META_NAME"
tree_record_patch bore \
  && rec ok "registrar sin testigo no es un error" || rec fail "registrar sin testigo falló"

# extract_tarball en el caso del fallo: un árbol vanilla con BORE encima NO se
# reutiliza, se descarta y se vuelve a extraer, avisando del motivo real.
#
# Todo esto va en un subshell a propósito. extract_tarball arrastra make, tar y
# source_tree_valid, y redefinirlas aquí las filtra a las secciones siguientes
# (las de reconcile_tmpfs_trees, que vuelven a redefinir ok/warn/log pero no
# findmnt/sudo): el síntoma es una cascada de fallos que no tienen nada que ver
# con este cambio. El veredicto se escribe a fichero y se puntúa fuera.
VEREDICTO="$ROOT/et.veredicto"; : > "$VEREDICTO"
rm -rf "$TMPFS_ROOT"; mkdir -p "$TMPFS_ROOT"; : > "$MOUNTED_FLAG"
VERSION=7.2.8; KERNEL_TREE=vanilla; TARBALL="$ROOT/linux-7.2.8.tar.xz"
: > "$TARBALL"
(
  cleanup_old_source_trees() { :; }
  make() { # el Makefile de pruebas responde la versión sin hacer nada real
    local a; for a in "$@"; do
      [ "$a" = kernelversion ] && { printf '7.2.8\n'; return 0; }
    done; return 0
  }
  tar() { # simula la extracción: aparece el árbol limpio donde toca
    local -a a=("$@") i cdir=""
    for ((i = 0; i < ${#a[@]}; i++)); do
      [ "${a[$i]}" = "-C" ] && cdir="${a[$((i + 1))]}"
    done
    mkdir -p "$cdir/linux-7.2.8/kernel/sched"
    : > "$cdir/linux-7.2.8/Makefile"; : > "$cdir/linux-7.2.8/kernel/Makefile"
    return 0
  }
  WARNS="$ROOT/et.warn"
  warn() { printf 'WARN:%s\n' "$*" >> "$WARNS"; }
  ok()  { printf 'OK:%s\n' "$*" >> "$WARNS"; }
  log() { printf 'LOG:%s\n' "$*" >> "$WARNS"; }
  err() { printf 'ERR:%s\n' "$*" >> "$WARNS"; }

  # 1) El fallo original: vanilla con BORE encima.
  : > "$WARNS"; rm -rf "$TMPFS_ROOT"; mkdir -p "$TMPFS_ROOT"
  SRC="$(_mktree 7.2.8 vanilla bore)"
  extract_tarball
  if grep -q "conserva el parche bore de una ejecución anterior" "$WARNS" \
     && ! grep -q "^OK:Reutilizando" "$WARNS" \
     && ! grep -q "^ERR:" "$WARNS" \
     && grep -qx "patches=none" "$SRC/$TREE_META_NAME"; then
    echo "sucio ok" >> "$VEREDICTO"
  else
    echo "sucio fail $(tr '\n' ' ' < "$WARNS")" >> "$VEREDICTO"
  fi

  # 2) Un árbol limpio sí se reutiliza, sin volver a extraer.
  : > "$WARNS"; rm -rf "$TMPFS_ROOT"; mkdir -p "$TMPFS_ROOT"
  SRC="$(_mktree 7.2.8 vanilla)"
  extract_tarball
  if grep -q "^OK:Reutilizando" "$WARNS" && ! grep -q "^LOG:Extrayendo" "$WARNS"; then
    echo "limpio ok" >> "$VEREDICTO"
  else
    echo "limpio fail $(tr '\n' ' ' < "$WARNS")" >> "$VEREDICTO"
  fi

  # 3) El estado desconocido (testigo heredado) también fuerza reextracción,
  #    pero con su propio motivo en el aviso.
  : > "$WARNS"; rm -rf "$TMPFS_ROOT"; mkdir -p "$TMPFS_ROOT"
  SRC="$(_mktree 7.2.8 vanilla legacy)"
  extract_tarball
  if grep -q "no declara su estado de parches" "$WARNS" \
     && ! grep -q "^OK:Reutilizando" "$WARNS" && ! grep -q "^ERR:" "$WARNS"; then
    echo "desconocido ok" >> "$VEREDICTO"
  else
    echo "desconocido fail $(tr '\n' ' ' < "$WARNS")" >> "$VEREDICTO"
  fi
) 2>/dev/null
# El veredicto viaja como "<caso> <ok|fail> [detalle]". El ok/fail va en su
# propio campo a propósito: en un intento anterior el detalle iba pegado al
# nombre ("sucio fail: ...") y el `read caso` se llevaba "sucio", que es
# justamente el caso bueno, así que los cuatro escenarios se puntuaban como
# correctos MIENTRAS el motor estaba mutado. Un arnés que no puede fallar no
# prueba nada: por eso el token va separado.
while read -r caso vered detalle; do
  case "$caso" in
    sucio)       d="extract_tarball descarta el vanilla con BORE, lo dice y vuelve a extraer limpio" ;;
    limpio)      d="extract_tarball sigue reutilizando un árbol limpio" ;;
    desconocido) d="extract_tarball no hereda un árbol de estado desconocido" ;;
    *)           d="escenario inesperado '$caso'" ;;
  esac
  case "$vered" in
    ok)   rec ok "$d" ;;
    fail) rec fail "$d -> ${detalle:-sin detalle}" ;;
    *)    rec fail "$d -> veredicto ilegible: '${vered:-vacio}'" ;;
  esac
done < "$VEREDICTO"
# Si el subshellmurió antes de emitir veredictos, estos cuatro tests NO existen
# y la sección entera pasa sin comprobar nada. Se cuenta lo que se esperaba.
_esperados=3
_emitidos="$(grep -c ' ok$' "$VEREDICTO" 2>/dev/null || echo 0)"
_totales_v="$(grep -c '' "$VEREDICTO" 2>/dev/null || echo 0)"
[ "$_totales_v" -eq "$_esperados" ] \
  && rec ok "los $_esperados escenarios de extract_tarball emitieron veredicto (ninguno se coló sin comprobar)" \
  || rec fail "solo emitieron $_totales_v de $_esperados veredictos: el subshell no llegó al final"
# La puerta de get_tarball debe usar "reutilizable Y limpio": si el árbol se va a
# descartar, extract_tarball necesitará $TARBALL y no puede saltarse la descarga.
if grep -q 'if tree_clean_reusable "\$SRC" "\$VERSION" "\$KERNEL_TREE"; then' "$MOTOR"; then
  rec ok "la descarga del tarball se exige también cuando el árbol está parcheado (hace falta para reextraer)"
else
  rec fail "la puerta de get_tarball no comprueba que el árbol esté limpio: se reextraería sin tarball"
fi
# Estado global de vuelta a como estaba, para las secciones siguientes.
VERSION="$_SAVED_VERSION"; KERNEL_TREE="$_SAVED_TREE"; SRC="$_SAVED_SRC"
TREE_FORCE_NOTE="$_SAVED_NOTE"
unset _SAVED_VERSION _SAVED_TREE _SAVED_SRC _SAVED_NOTE VEREDICTO

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

# El verificador se busca en los DOS layouts —el del repo (kernel-update/) y el
# instalado junto al harness— en vez de asumir ../. La copia plana del harness
# en /usr/local/bin/kernel-update/selftest.sh no cumple ese supuesto: los 31
# tests de este bloque fallaban todos, sin que hubiera un solo defecto detrás
# (VERIFY_SRC apuntaba a /usr/local/bin/kernel-update-verify.sh, que no existe).
# Un test que solo puede pasar en uno de los dos layouts no mide nada: entrena a
# ignorar los que fallan. Y si de verdad no está el verificador, se OMITE el
# bloque diciendo por qué, en vez de producir 31 rojos sin explicación.
_here="$(cd "$(dirname "$0")" && pwd)"
VERIFY_SRC=""
for _c in "$_here/../kernel-update-verify.sh" "$_here/kernel-update-verify.sh"; do
  [ -f "$_c" ] && { VERIFY_SRC="$_c"; break; }
done
if [ -z "$VERIFY_SRC" ]; then
  printf '  -- omitidos los tests del verificador: no hay kernel-update-verify.sh en %s/ ni en %s/\n' "$_here" "$_here/.."
else
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
# v27.33.7: arrancar un kernel NUEVO del mismo PKGVER no se anunciaba
# `_12` y `_13` son ambos `7.2.8-cizen-v3`. Con `uname -r` como identidad, el
# verificador se callaba al arrancar el kernel recién compilado, que es el caso
# para el que existe. Estos tests miran el VALOR (la firma y la comparación de
# First_boot), no el texto impreso: un test que grepa la salida pasaría aunque
# el comportamiento volviera a estar roto.
# ============================================================
_sx_v27_33_7=0

# Guard de existencia. Sin él, un test que hace `if fn ...; then ok else ok fi`
# pasa en verde contra un script donde la función NO EXISTE (la condición sale
# falsa y el `else` dice "ok"): siete de los tests de este bloque seDeclare
# correctos contra un fichero que no tiene la función. Se comprueba que las tres
# se extraen y no vienen vacías.
_sx_missing=""
for _fn in running_pkgv first_boot_detected build_label; do
  [ -n "$(_sx_nsc "$_fn")" ] || _sx_missing="$_sx_missing $_fn"
done
if [ -z "$_sx_missing" ]; then
  rec ok "las tres funciones del bloque de identidad de build existen y son extraíbles"
else
  rec fail "funciones ausentes o no extraíbles:$_sx_missing (los tests que las usan pasarían en falso)"
fi

# --- running_pkgv: con paquete devuelve "<pkgver-pkgrel>", SIN espacios ---
_rbid_bin="$ROOT/rbid-bin"; mkdir -p "$_rbid_bin"
cat > "$_rbid_bin/uname" <<'EOF'
#!/usr/bin/env bash
printf '7.2.8-cizen-v3\n'
EOF
cat > "$_rbid_bin/pacman" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-Qo" ] || exit 1
printf '/usr/lib/modules/7.2.8-cizen-v3/ está contenido en linux-cizen-v3 7.2.8_cizen_v3-13\n'
EOF
chmod +x "$_rbid_bin/uname" "$_rbid_bin/pacman"
{ _sx_nsc running_pkgv; } > "$ROOT/rbid.sh"
# shellcheck disable=SC1090,SC1091
source "$ROOT/rbid.sh"
_rbid_oldpath="$PATH"; PATH="$_rbid_bin:$PATH"
_rbid="$(running_pkgv)"
PATH="$_rbid_oldpath"
if [ "$_rbid" = '7.2.8_cizen_v3-13' ]; then
  rec ok "running_pkgv devuelve el pkgver-pkgrel del paquete del kernel en marcha"
  _sx_v27_33_7=$((_sx_v27_33_7 + 1))
elif [ -z "$_rbid" ]; then
  rec fail "running_pkgv NO devuelve el pkgrel: volvería a no distinguir _12 de _13"
else
  rec fail "running_pkgv devuelve algo inesperado: '$_rbid'"
fi

# El valor NO puede llevar espacios: se guarda en verify-last/verify-history, que
# son líneas delimitadas por ESPACIOS. Una identidad con un espacio dentro añade
# un campo de más, `read` lee 10 campos donde esperaba 9 y el campo del build
# queda vacío. Ese fue el bug que hizo que esta misma versión no anunciara nada
# en su prueba de extremo a extremo, con todos los tests en verde.
case "$_rbid" in
  *' '*) rec fail "running_pkgv devuelve un valor con espacios: rompe el formato de verify-last" ;;
  *)     rec ok "running_pkgv devuelve un valor sin espacios (verify-last es space-delimited)" ;;
esac

# Sin pacman (o sin base de datos de paquetes) no debe reventar: devuelve vacío.
# Se prueba la MISMA función extraída; no una reimplementación escrita aquí, que
# probaría el test y no el script.
# shellcheck disable=SC2123  # PATH es el search path y aquí se aísla a propósito
_rbid_nopath="$PATH"
# shellcheck disable=SC2123  # idem, segundo comando de la línea anterior
PATH=/nonexistent
_rbid="$(running_pkgv 2>/dev/null || true)"
PATH="$_rbid_nopath"
if [ -z "$_rbid" ]; then
  rec ok "sin pacman (ni uname), running_pkgv devuelve vacío sin fallar"
else
  rec fail "sin pacman debería devolver vacío; devolvió '$_rbid'"
fi
# Y con pacman presente pero sin coincidencia (base vacía, kernel sin paquete):
# no debe inventarse un build, pero tampoco perder el nombre.
cat > "$_rbid_bin/pacman" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$_rbid_bin/pacman"
# shellcheck disable=SC2123  # PATH a proposito: se aísla el pacman falso
_rbid_oldpath="$PATH"; PATH="$_rbid_bin:$PATH"
_rbid="$(running_pkgv)"
PATH="$_rbid_oldpath"
if [ -z "$_rbid" ]; then
  rec ok "pacman sin coincidencia: running_pkgv devuelve vacío en vez de inventar un build"
else
  rec fail "pacman sin coincidencia devolvió '$_rbid'"
fi
unset -f running_pkgv

# --- la FIRMA cambia entre dos builds aunque todo lo demás sea idéntico ---
# Este es el corazón del fallo: mismo perfil, mismo scheduler, 0 incidencias, y
# aun así la firma tiene que cambiar para que salte la notificación.
_sx_nsc verify_state_fingerprint > "$ROOT/sx_fp.sh"
# shellcheck disable=SC1090,SC1091
source "$ROOT/sx_fp.sh"
BASE_ISSUES=0; SCHED_EXPECTED=bore; SCHED_RUNNING=bore; JCOUNT=0; FW_COUNT=0
SB_STATE="yes (UKI firmada; SB HABILITADO)"; ISSUES=0
CUR_VERSION='7.2.8-cizen-v3'
CUR_PKGV='7.2.8_cizen_v3-12'; _fp12="$(verify_state_fingerprint)"
CUR_PKGV='7.2.8_cizen_v3-13'; _fp13="$(verify_state_fingerprint)"
if [ "$_fp12" != "$_fp13" ]; then
  rec ok "la firma distingue _12 de _13 con el resto del estado idéntico (arrancar un build nuevo se anuncia)"
  _sx_v27_33_7=$((_sx_v27_33_7 + 1))
else
  rec fail "la firma es idéntica entre _12 y _13: arrancar un kernel recién compilado se callaría"
fi
# Y al revés: con el MISMO build la firma no cambia (esto sigue siendo ruido
# que no debe notificarse en cada arranque).
CUR_PKGV='7.2.8_cizen_v3-13'; _fp13b="$(verify_state_fingerprint)"
if [ "$_fp13" = "$_fp13b" ]; then
  rec ok "la firma NO cambia entre dos verificaciones del mismo build (sin ruido)"
else
  rec fail "la firma cambia sin motivo: se notificaría en cada arranque"
fi
# La firma debe LLEVAR el build, no solo el nombre: si se usara CUR_VERSION a
# pelo, los dos casos de arriba darían la misma cadena.
if printf '%s' "$_fp13" | grep -qF '7.2.8_cizen_v3-13'; then
  rec ok "la firma incluye la identidad completa del build, no solo uname -r"
else
  rec fail "la firma no incluye el pkgrel: no distinguiría dos builds del mismo PKGVER"
fi
unset -f verify_state_fingerprint

# --- First_boot compara IDENTIDADES, no nombres ---
# Se ejecuta la FUNCIÓN REAL extraída del script. La primera versión de estos
# tres tests copiaba la comparación dentro del test, y por eso pasaban contra el
# código viejo: no medían el script, se medían a sí mismos.
{ _sx_nsc first_boot_detected; } > "$ROOT/sx_fbfn.sh"
# shellcheck disable=SC1090,SC1091
source "$ROOT/sx_fbfn.sh"
CUR_VERSION='7.2.8-cizen-v3'
# shellcheck disable=SC2034  # los leen las funciones extraidas (sourced), no este fichero
CUR_PKGV='7.2.8_cizen_v3-13'
P_VER='7.2.8-cizen-v3'
if first_boot_detected '7.2.8_cizen_v3-12'; then
  rec ok "build anterior _12 → ahora _13: First_boot salta aunque uname -r sea idéntico"
  _sx_v27_33_7=$((_sx_v27_33_7 + 1))
else
  rec fail "primera vez que arranca _13 tras _12 no se reconoce como novedad: es el fallo original"
fi
if first_boot_detected '7.2.8_cizen_v3-13'; then
  rec fail "reiniciar el mismo build se anuncia como kernel nuevo"
else
  rec ok "mismo build otra vez: First_boot NO salta (no se re-anuncia en cada arranque)"
fi
if first_boot_detected ''; then
  rec fail "una línea vieja de verify-last provoca un falso primer arranque"
else
  rec ok "línea vieja de verify-last (sin campo build) y mismo kernel: no se marca como primer arranque"
fi
# Y al revés: línea vieja, pero el nombre SÍ es distinto (arranque de otro
# kernel) → sí debe marcar primer arranque. Es el caso que el nombre cubría
# antes y que no puede perderse al añadir el campo nuevo.
CUR_VERSION='7.2.8-cizen-v3'; P_VER='6.18.54-2.1-lts'
CUR_PKGV='7.2.8_cizen_v3-13'
if first_boot_detected ''; then
  rec ok "línea vieja con otro kernel de nombre: First_boot sigue saltando por el nombre"
else
  rec fail "el campo nuevo tapó la detección por nombre de líneas viejas"
fi
# Un build con la misma versión y el mismo pkgrel tampoco es novedad: es el
# guard contra el falso positivo de re-notificar en cada arranque.
# shellcheck disable=SC2034  # los leen las funciones extraidas (sourced), no este fichero
CUR_PKGV='6.18.54-2.1-lts'
# shellcheck disable=SC2034  # idem: first_boot_detected lo lee en la rama de linea vieja
P_VER='6.18.54-2.1-lts'
CUR_VERSION='6.18.54-2.1-lts'
if first_boot_detected '6.18.54-2.1-lts'; then
  rec fail "el linux-lts, cuyo pkgver ya trae su propia revisión, se anunciaría como nuevo en cada arranque"
else
  rec ok "un pkgver que ya incluye revisión (linux-lts) tampoco da falsos positivos"
fi
unset -f first_boot_detected

# --- el campo nuevo va AL FINAL de la línea: no desplaza lo que ya se leía ---
# El campo 1 tiene que seguir siendo la versión, porque boot_ref filtra por él.
# OJO con las comillas: en comillas SIMPLES '\$' es un backslash literal, así que
# el patrón llevaría la barra invertida y no casaría con nada (mismo tipo de
# trampa que el IFS de v27.31.45).
if grep -qF "printf '%s %s %s %s %s %s %s %s %s\\n' \"\$CUR_VERSION\"" "$VERIFY_SRC" \
   && grep -qF '"$CUR_PKGV" > "$LAST"' "$VERIFY_SRC"; then
  rec ok "la identidad del build se añade como último campo de verify-last (no desplaza los anteriores)"
  _sx_v27_33_7=$((_sx_v27_33_7 + 1))
else
  rec fail "la identidad del build no está como último campo: rompería las lecturas antiguas de verify-last"
fi
if sed -n '/^boot_ref() {/,/^}/p' "$VERIFY_SRC" | grep -qF '[ "$v" = "$want" ] || continue'; then
  rec ok "boot_ref sigue filtrando el historial por el campo 1 (versión): la mediana de referencia no cambia de alcance"
else
  rec fail "boot_ref ya no filtra por la versión: la referencia de arranque mezclaría builds"
fi

# --- la etiqueta de build se USA, no solo existe ---
# Test del flag/valor, no del texto: comprueba que el rótulo entra en el título
# de las dos notificaciones. Es el mismo criterio que el test de PGO_CHANGED
# (§50.5): un test que grepea la cadena impresa pasa aunque el título vuelva a
# esconder el número de build.
{ _sx_nsc build_label; _sx_nsc notify_issues; _sx_nsc notify_first_boot; } > "$ROOT/sx_titles.sh"
# shellcheck disable=SC1090,SC1091
source "$ROOT/sx_titles.sh"
CUR_REL='13'
if [ "$(build_label)" = ' (build 13)' ]; then
  rec ok "build_label produce la etiqueta ' (build 13)'"
else
  rec fail "build_label no produce la etiqueta esperada: '$(build_label)'"
fi
CUR_REL=''
if [ -z "$(build_label)" ]; then
  rec ok "build_label vacío sin pkgrel: no añade ruido donde no hay nada que decir"
else
  rec fail "build_label inventa una etiqueta sin pkgrel: '$(build_label)'"
fi
# shellcheck disable=SC2034  # igual: lo consume build_label, que se extrae
CUR_REL='13'
# notify_first_boot no necesita red: con DRY=true solo imprime lo que haría.
if sed -n '/^notify_first_boot() {/,/^}/p' "$VERIFY_SRC" | grep -q 'title="\$CUR_VERSION\$bl arrancado'; then
  rec ok "el aviso de kernel nuevo lleva el número de build en el título"
  _sx_v27_33_7=$((_sx_v27_33_7 + 1))
else
  rec fail "el aviso de kernel nuevo no dice qué build arrancó: '7.2.8-cizen-v3 arrancado' es ambiguo entre _12 y _13"
fi
if sed -n '/^notify_issues() {/,/^}/p' "$VERIFY_SRC" | grep -q 'title="\$CUR_VERSION\$bl: '; then
  rec ok "el aviso de incidencias también lleva el número de build"
else
  rec fail "las incidencias de un kernel nuevo no dicen en cuál"
fi
# Si bl se calculase pero no se usara, los dos greps de arriba pasarían: se
# exige que exista la asignación Y que el título la interpole.
if sed -n '/^notify_first_boot() {/,/^}/p' "$VERIFY_SRC" | grep -q 'bl="\$(build_label)"'; then
  rec ok "notify_first_boot calcula la etiqueta y la usa en el título"
else
  rec fail "notify_first_boot no usa la etiqueta que debería calcular"
fi
unset -f build_label notify_issues notify_first_boot
# El informe de consola también lo dice: si no, el usuario tiene que abrir el
# log para saber que el kernel en marcha no es el que esperaba.
if grep -qF 'echo " Build (paquete)     : $CUR_PKGV"' "$VERIFY_SRC"; then
  rec ok "el informe de consola muestra el pkgver-pkgrel del build en marcha"
else
  rec fail "el informe no dice qué build está en marcha"
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

# --- v27.33.1: la comparación de boot no puede ser contra UNA muestra ---
# En este host el total de arranque va de 11.8 a 22.8 s (desv 2.9). Con el
# criterio viejo (factor 1.35x y +3 s contra el arranque INMEDIATAMENTE
# anterior) el 17.795 s de un 1-oct se contaba como incidencia: 17.795 era la
# mediana del propio kernel. En el historial real, el criterio viejo daba 5
# notificaciones de boot en 77 verificaciones y el nuevo 3, sin el flapping de
# "dispara y en la siguiente verificación del MISMO arranque no".
_br_hist="$ROOT/boot-ref.hist"
_br_last="$ROOT/boot-ref.last"
{ _sx float_ge; _sx boot_ref; _sx boot_check; } > "$ROOT/bootref.sh"
# shellcheck disable=SC1090,SC1091
source "$ROOT/bootref.sh"
BOOT_REF_N=7; BOOT_REF_MIN=3; BOOT_FACTOR=1.35; BOOT_MIN_DELTA=3
HIST="$_br_hist"; LAST="$_br_last"; CUR_VERSION="k-test"
warn() { :; }; info() { :; }; DRY=false
_br_line() { printf 'k-test 1.2 3.7 %s 0 0 2026-01-01T00:00:00Z %s\n' "$1" "$2"; }
# Variante con kernel explícito, para comprobar que la referencia NO se
# contruye con arranques de otro (escribir 22 s de "LTS" con k-test no probaría
# nada: la línea seguiría siendo del kernel que se está consultando).
_br_line_k() { printf '%s 1.2 3.7 %s 0 0 2026-01-01T00:00:00Z %s\n' "$1" "$2" "$3"; }
_br_check() { ISSUES=0; boot_check 0 0 1.2 3.7 "$1" >/dev/null 2>&1; printf '%s' "$ISSUES"; }
: > "$HIST"; : > "$LAST"
# 5 arranques NORMALES y muy juntos en el tiempo (12.4-12.9): la referencia
# tiene que ser ~12.6, no "el último".
for i in 1 2 3 4 5; do _br_line 12.4 "b$i" >> "$HIST"; _br_line 12.9 "b$i" >> "$HIST"; _br_last="$(sed -n '$p' "$HIST")"; printf '%s\n' "$_br_last" > "$LAST"; done
_br_ref="$(boot_ref k-test)"
case "$_br_ref" in
  12.*|13.*) rec ok "boot_ref: la referencia es una mediana de arranques, no el último (${_br_ref}s)" ;;
  *)         rec fail "boot_ref dio '${_br_ref}' en vez de la mediana ~12.6s" ;;
esac
[ "$(_br_check 12.7)" = "0" ] \
  && rec ok "boot: un arranque dentro de la norma no genera incidencia" \
  || rec fail "boot: un arranque normal se cuenta como incidencia"
[ "$(_br_check 18.5)" = "1" ] \
  && rec ok "boot: una regresión clara contra la mediana sí genera incidencia" \
  || rec fail "boot: una regresión sostenida ya no se detecta (el umbral se ha comido el rango)"
# El caso exacto que-notificaba: 17.795 s con la mediana del kernel en 17.8.
: > "$HIST"
for i in 1 2 3 4 5 6 7; do _br_line 17.8 "n$i" >> "$HIST"; done
printf 'k-test 1.2 3.7 17.8 0 0 2026-01-01T00:00:00Z n7\n' > "$LAST"
[ "$(_br_check 17.795)" = "0" ] \
  && rec ok "boot: el arranque de 17.795 s que-avISó ya no es incidencia (era la mediana)" \
  || rec fail "boot: 17.795s contra su propia mediana sigue disparando (falso positivo)"
# Varias verificaciones del MISMO arranque no son varios arranques: sin esto la
# mediana se pondera por cuántas veces se verificó.
: > "$HIST"
for i in 1 2 3; do for _ in 1 2 3 4 5; do _br_line 13.0 "mismo$i" >> "$HIST"; done; done
# El caso que hay que discriminar bien: 3 arranques rápidos verificados una vez
# cada uno, y UN arranque lento verificado 5 veces (que es justo lo que pasaba
# con el bug de --dry-run, que metía líneas de un mismo arranque).
#   - deduplicando por boot_id -> 4 muestras [13,13,13,40] -> mediana 13.000
#   - sin deduplicar          -> 8 muestras, 5 de ellas a 40 -> mediana 40.0
# Las dos respuestas son distintas, así que el test mide de verdad.
: > "$HIST"
_br_line 40.0 "lento" >> "$HIST"
for _ in 1 2 3 4 5; do _br_line 40.0 "lento" >> "$HIST"; done
_br_line 13.0 "r1" >> "$HIST"
_br_line 13.0 "r2" >> "$HIST"
_br_line 13.0 "r3" >> "$HIST"
_br_ref2="$(boot_ref k-test)"
[ "$_br_ref2" = "13.000" ] \
  && rec ok "boot_ref: un arranque verificado 5 veces no pesa como 5 arranques" \
  || rec fail "boot_ref no deduplica por boot_id: mediana '$_br_ref2' (13.000 si deduplica, 40.0 si no)"
# Y el determinista: 3 arranques IDÉNTICOS con boot_id distinto son 3 muestras,
# no 1. Deduplicar por "total igual al anterior" colapsaba estos casos y la
# mediana no se usaba nunca.
: > "$HIST"
_br_line 13.0 d1 >> "$HIST"; _br_line 13.0 d2 >> "$HIST"; _br_line 13.0 d3 >> "$HIST"
[ -n "$(boot_ref k-test)" ] \
  && rec ok "boot_ref: arranques idénticos con boot_id distinto son muestras distintas" \
  || rec fail "boot_ref colapsa arranques deterministas y nunca alcanza la mediana"
# Con menos muestras que el mínimo se cae al arranque previo (compatibilidad).
: > "$HIST"; _br_line 15.0 u1 >> "$HIST"
printf 'k-test 1.2 3.7 15.0 0 0 2026-01-01T00:00:00Z u1\n' > "$LAST"
[ -z "$(boot_ref k-test)" ] && [ "$(_br_check 15.0)" = "0" ] \
  && rec ok "boot: sin historial suficiente se usa el arranque previo, sin inventarbaseline" \
  || rec fail "boot: con 1 sola muestra el comportamiento cambió sin avisar"
# La referencia NO puede cruzar de kernel: el 22.797s del LTS no es una
# regresión del Cizen.
: > "$HIST"
for i in 1 2 3 4 5; do _br_line_k 6.18.54-1.1-lts 22.0 "lts$i" >> "$HIST"; done
[ -z "$(boot_ref k-test)" ] \
  && rec ok "boot_ref: la referencia solo usa arranques del MISMO kernel" \
  || rec fail "boot_ref mezcla arranques de otro kernel en la referencia"
# Y al revés: las líneas del LTS no pueden servir de referencia para el LTS si
# son en realidad de otro kernel (comprobación simétrica del parseo del campo).
: > "$HIST"
for i in 1 2 3 4 5; do _br_line_k k-test 22.0 "cizen$i" >> "$HIST"; done
[ "$(boot_ref k-test)" = "22.0" ] \
  && rec ok "boot_ref: con 5 muestras del kernel pedido sí construye referencia" \
  || rec fail "boot_ref no encuentra referencias válidas del kernel pedido ('$(boot_ref k-test)')"
unset -f float_ge boot_ref boot_check
rm -f "$ROOT/bootref.sh" "$_br_hist" "$_br_last"

# --- v27.33.1: --dry-run no puede cambiar la línea base ---
# Se anunciaba como "imprime sin notificar", pero sí escribía verify-last y
# verify-history. Como boot_check y journal_check leen verify-last, una
# auditoría manual dejaba el "previo" apuntando al ARRANQUE EN CURSO: la
# comparación quedaba consigo misma. Y metía líneas en el historial, que es
# justo de donde sale la referencia de boot.
if grep -qF 'if [ "$DRY" != true ]; then' "$VERIFY_SRC" \
   && grep -qE '^\s+printf .* > "\$LAST"' "$VERIFY_SRC" \
   && grep -qF 'BOOT_ID="$(cat /proc/sys/kernel/random/boot_id' "$VERIFY_SRC"; then
  rec ok "--dry-run no escribe verify-last/verify-history (ni el boot_id sin él)"
else
  rec fail "--dry-run sigue persistiendo estado: falsea la línea base de la verificación real"
fi
# --- v27.33.2: "el kernel es anterior al perfil" es UN hecho, no N ---
# Se contaba dos veces: una por cada símbolo que el perfil pide y el kernel no
# tiene (bad[], issues += 1 por símbolo) y otra por el sha distinto del build.
# Con un desfase real son la MISMA causa y el arreglo es el mismo (reconstruir),
# así que se cuentan una vez y los símbolos quedan como detalle del aviso.
#
# El banco usa perfil y firma sintéticos para cubrir los dos lados: con
# el perfil real de esta máquina solo se puede provocar un lado.
_pfx="$ROOT/profcheck"
rm -rf "$_pfx"; mkdir -p "$_pfx"
# Perfil mínimo: un símbolo en OPTS_ENABLE y otro que el kernel sí tendrá.
cat > "$_pfx/perfil.conf" <<'PC'
OPTS_ENABLE=(TEST_SYM_ROTO TEST_SYM_BUENO)
PC
_sha_real="$(sha256sum "$_pfx/perfil.conf" | cut -d' ' -f1)"
printf 'version=7.2.8\nprofile_sha=%s\n' "$_sha_real" > "$_pfx/firma-igual"
printf 'version=7.2.8\nprofile_sha=%s\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$_pfx/firma-distinta"
# run_state stub: TEST_SYM_ROTO está en n, TEST_SYM_BUENO en y.
# OJO: find_profile tiene que apuntar al perfil del banco, o profile_check
# cargaría el perfil real de la máquina (donde casi nada falla y el contador no
# mide lo que el test cree). Las funciones que usa profile_check y que aquí no
# se sustituyen (build_sig_field y las del scheduler) también se extraen, o
# fallan con «orden no encontrada» y el banco mide el fallo de bash, no el del
# verificador.
{
  _sx build_sig_field
  _sx expected_sched_from_signature
  _sx sched_label
  _sx retired_symbols_for_sched
  # RETIRED es un associative array global del verificador; sin inicializarlo,
  # load_retired_symbols explota al indexarlo y profile_check aborta a mitad.
  printf 'declare -A RENAMES=()\ndeclare -A RETIRED=()\nRETIRED_SCHED=""; RETIRED_SRC=""; RETIRED_LIST=""; RUN_CFG_X=1\n'
  _sx load_renames
  _sx load_retired_symbols
  _sx sym_retired
  _sx retired_reason
  _sx resolve_sym
  _sx profile_check
  printf 'run_state() { case "$1" in TEST_SYM_ROTO) printf "%%s\\n" n ;; *) printf "%%s\\n" y ;; esac; return 0; }\n'
  printf 'find_profile() { printf "%%s\\n" "%s/perfil.conf"; }\n' "$_pfx"
  # El selftest va con `set -u`, y load_renames usa RENAME_MAP_FILE tal cual.
  # Aquí las globales no existen (el script real las define arriba del todo),
  # así que sin esto profile_check aborta por RENAME_MAP_FILE sin asignar y el
  # banco mide un fallo de bash en vez de la lógica del verificador. El valor
  # apunta a un fichero inexistente, que es lo mismo que pasa en un equipo sin
  # rename-map.
  printf 'RENAME_MAP_FILE="%s/no-existe"\n' "$_pfx"
} > "$_pfx/fns.sh"
# shellcheck disable=SC1090,SC1091
source "$_pfx/fns.sh"
_pc() { # $1 = firma -> "incidencias|lineas de warn"
  declare -A RUN_CFG=()
  # El perfil del banco solo define OPTS_ENABLE. profile_check NO limpia
  # CRITICAL_OPTS/OPTS_SETVAL/OPTS_SETSTR, y en el script real los define el
  # perfil siempre, así que ahí no se nota; pero dentro del selftest esos
  # arrays vienen de pruebas anteriores y si se dejan, cada fila que contengan
  # se cuela como incidencia y el banco mide datos ajenos.
  unset CRITICAL_OPTS OPTS_SETVAL OPTS_SETSTR
  # El contador va por STDOUT y los avisos por STDERR (contrato de
  # profile_check), así que se capturan por separado: si se juntan en una
  # sola captura el número que sale es la cuenta de warnings, no la de
  # incidencias, y el banco mide otra cosa.
  BUILD_SIG="$1"
  _n="$(profile_check 2>/dev/null)"
  _out="$(profile_check 2>&1 >/dev/null)"
  printf '%s|%s' "$_n" "$(printf '%s\n' "$_out" | grep -c '⚠')"
}
# Desfase: el sha del build no es el del perfil vigente.
_r="$(_pc "$_pfx/firma-distinta")"
_n="${_r%%|*}"; _w="${_r##*|}"
if [ "$_n" = "1" ] && [ "$_w" = "1" ]; then
  rec ok "perfil: con sha desfasado, 1 símbolo roto cuenta 1 sola vez (antes 2)"
else
  rec fail "perfil desfasado: ${_n} incidencias y ${_w} warns; debe ser 1 y 1"
fi
# Sin desfase: el kernel se compiló con ESE perfil, así que no cumplirlo sí es
# un fallo del build y cada símbolo cuenta por separado.
_r="$(_pc "$_pfx/firma-igual")"
_n="${_r%%|*}"; _w="${_r##*|}"
if [ "$_n" = "1" ] && [ "$_w" = "1" ]; then
  rec ok "perfil: sin sha desfasado, cada símbolo roto cuenta aparte (como antes)"
else
  rec fail "perfil sin desfase: ${_n} incidencias y ${_w} warns; debe ser 1 y 1"
fi
# El detalle de los símbolos no puede perderse al agrupar: quien lo lea tiene
# que saber QUÉ falta, no solo que falta algo.
BUILD_SIG="$_pfx/firma-distinta"
_pc_txt="$(profile_check 2>&1 >/dev/null)"
if printf '%s\n' "$_pc_txt" | grep -q 'TEST_SYM_ROTO' \
   && printf '%s\n' "$_pc_txt" | grep -q 'símbolo(s) que el perfil pide'; then
  rec ok "perfil: al agrupar, los símbolos siguen apareciendo uno a uno en el aviso"
else
  rec fail "perfil: al agrupar se perdió el detalle de qué símbolos faltan"
fi
# Desfase SIN síntomas (el kernel cumple todo): se informa pero no cuenta.
# El run_state cambia a "todo y", y con eso el perfil NO tiene nada que
# incumplir; el resto de funciones extraídas son las mismas.
{
  _sx build_sig_field
  _sx expected_sched_from_signature
  _sx sched_label
  _sx retired_symbols_for_sched
  # RETIRED es un associative array global del verificador; sin inicializarlo,
  # load_retired_symbols explota al indexarlo y profile_check aborta a mitad.
  printf 'declare -A RENAMES=()\ndeclare -A RETIRED=()\nRETIRED_SCHED=""; RETIRED_SRC=""; RETIRED_LIST=""; RUN_CFG_X=1\n'
  _sx load_renames
  _sx load_retired_symbols
  _sx sym_retired
  _sx retired_reason
  _sx resolve_sym
  _sx profile_check
  printf 'run_state() { printf "%%s\\n" y; return 0; }\n'
  printf 'find_profile() { printf "%%s\\n" "%s/perfil.conf"; }\n' "$_pfx"
  printf 'RENAME_MAP_FILE="%s/no-existe"\n' "$_pfx"
} > "$_pfx/fns-ok.sh"
# shellcheck disable=SC1090,SC1091
source "$_pfx/fns-ok.sh"
# El unset tiene que estar TAMBIÉN aquí: _pc lo hace, pero estas dos llamadas
# sueltas no. El perfil sintético no define OPTS_SETVAL, y si sobrevive el del
# perfil real (traído por otro test) aparecen filas SETVAL que este banco no
# pidió, y entonces mide otra cosa.
unset CRITICAL_OPTS OPTS_SETVAL OPTS_SETSTR
_r="$(_pc "$_pfx/firma-distinta")"
_pc_txt="$(BUILD_SIG="$_pfx/firma-distinta"; profile_check 2>&1 >/dev/null)"
# 0 incidencias y 0 warns: sin síntomas no hay nada roto, así que ni cuenta ni
# avisa en ⚠; el desfase solo sale como línea informativa (•).
if [ "$_r" = "0|0" ] && printf '%s\n' "$_pc_txt" | grep -q 'anterior al perfil vigente' \
   && printf '%s\n' "$_pc_txt" | grep -q '•'; then
  rec ok "perfil: desfase sin síntomas se informa pero no cuenta incidencia"
else
  rec fail "perfil: desfase sin símbolos dio '${_r}' (debe ser 0|0)"
fi
# Firma antigua sin profile_sha: se omite el desfase, no se rompe. Con el
# run_state de "todo y" (el de arriba) el perfil se cumple entero, así que sin
# profile_sha tampoco hay nada que contar: tiene que dar 0, no 1.
printf 'version=7.2.8\n' > "$_pfx/firma-sin-sha"
_n="$(_pc "$_pfx/firma-sin-sha")"
if [ "$_n" = "0|0" ]; then
  rec ok "perfil: una firma sin profile_sha omite el desfase y no inventa nada"
else
  rec fail "perfil: firma sin profile_sha dio '${_n}' (debe ser 0|0)"
fi
# El desfase NO puede decidirse por mtime: un `touch` o un checkout de git no
# cambian el contenido del perfil, así que avisar por la fecha sería ruido.
if grep -qE 'stat -c *%Y.*profile|profile.*stat -c *%Y' "$VERIFY_SRC"; then
  rec fail "el verificador vuelve a mirar el mtime del perfil: eso no significa que cambie"
else
  rec ok "el desfase del perfil se decide por sha, no por mtime"
fi
unset -f profile_check run_state load_retired_symbols sym_retired retired_reason resolve_sym load_renames
rm -rf "$_pfx"

# El boot_id tiene que estar en la línea del historial: es lo que permite saber
# si dos verificaciones son el mismo arranque.
if grep -qE 'verify-history|\$HIST' "$VERIFY_SRC" && grep -q 'random/boot_id' "$VERIFY_SRC"; then
  rec ok "el historial registra el boot_id (una línea por arranque, no por verificación)"
else
  rec fail "el historial no registra el boot_id: la deduplicación por arranque no puede funcionar"
fi

# --- rollback por PAQUETE, no solo por ficheros (v27.31.24) ---
# El fallo que motivó esto: el archive de rollback guarda ficheros y krollback los
# extraía, así que pacman seguía diciendo que estaba instalado el kernel NUEVO.
# Con CleanMethod=KeepCurrent, además, pacman borra de su caché el paquete
# anterior al instalar el siguiente, y la build vive en un tmpfs que se desmonta
# al terminar: el kernel anterior no quedaba en ninguna parte del host.
fi

printf '%s\n' "== rollback: manifiesto y paquete preservado =="

RB="$ROOT/rollback"
rm -rf "$RB"; mkdir -p "$RB"
ROLLBACK_DIR="$RB"
ROLLBACK_MANIFEST="$RB/rollback.info"
ROLLBACK_PKG_FILE=""
ROLLBACK_PKG_ENABLED=1
KROLLBACK_SCRIPT="/usr/local/bin/kernel-update/kernel-update-rollback.sh"
CIZEN_PKGBASE="linux-cizen-v3"
VERSION="7.2.7"
LOCALVERSION_SUFFIX="-cizen-v3"
PATCHES_APPLIED=(bmq)
# sudo como stub: los tests no son root y no deben serlo. Todo lo que pide
# privilegio (cp/tee/mv/cat/du/test) va contra un directorio del usuario.
sudo() { [ "$1" = sudo ] && shift; "$@"; }
# effective_scheduler se unset más arriba de la suite (tras su propio test), y
# preserve_rollback_package lo usa para firmar el paquete: se reextrae.
eval "$(extract effective_scheduler)"
PACMAN_Q_VERSION=""
pacman() { case "$1" in -Q) printf '%s %s\n' "$CIZEN_PKGBASE" "$PACMAN_Q_VERSION" ;; *) return 1 ;; esac; }

# El manifiesto es un mapa clave=valor: se escribe una clave, se relee, y una
# clave que no existe no inventa nada (si "devolviera" algo, krollback podría
# reinstalar un paquete con nombre vacío).
rollback_manifest_set pkgbase "linux-cizen-v3"
rollback_manifest_set pkgver "7.2.7_cizen_v3-2"
rollback_manifest_set sched "bmq"
[ "$(rollback_manifest_field pkgver)" = "7.2.7_cizen_v3-2" ] \
  && rec ok "rollback: el manifiesto guarda y relee el pkgver" \
  || rec fail "rollback: el manifiesto no relee pkgver ('$(rollback_manifest_field pkgver)')"
[ -z "$(rollback_manifest_field noexiste)" ] \
  && rec ok "rollback: una clave ausente devuelve vacío (no inventa un paquete)" \
  || rec fail "rollback: clave inexistente devolvió algo"
rollback_manifest_set pkgver "7.2.7_cizen_v3-3"
[ "$(rollback_manifest_field pkgver)" = "7.2.7_cizen_v3-3" ] \
  && rec ok "rollback: reescribir una clave no duplica entradas" \
  || rec fail "rollback: la clave se quedó con el valor viejo"
[ "$(grep -c '^pkgver=' "$ROLLBACK_MANIFEST")" = "1" ] \
  && rec ok "rollback: el manifiesto no acumula líneas repetidas" \
  || rec fail "rollback: el manifiesto duplicó la clave pkgver"
[ "$(rollback_manifest_field sched)" = "bmq" ] \
  && rec ok "rollback: el manifiesto guarda el scheduler del paquete anterior" \
  || rec fail "rollback: el scheduler no quedó en el manifiesto"

# La comprobación que faltaba y hacía peligroso el "rollback": un archive de la
# MISMA release pero de otro pkgrel (bore vs bmq comparten 7.2.7-cizen-v3) no
# puede darse por bueno. Solo vale si el pkgver del manifiesto es el instalado.
rollback_manifest_set pkgver "7.2.7_cizen_v3-2"
PACMAN_Q_VERSION="7.2.7_cizen_v3-2"
rollback_manifest_matches "7.2.7-cizen-v3" \
  && rec ok "rollback: el archive de la release vale si es el paquete instalado" \
  || rec fail "rollback: se rechazó un archive que sí correspondía"
rollback_manifest_set pkgver "7.2.7_cizen_v3-2"
PACMAN_Q_VERSION="7.2.7_cizen_v3-3"
if rollback_manifest_matches "7.2.7-cizen-v3"; then
  rec fail "rollback: un archive de la MISMA release pero de otro pkgrel se dio por bueno"
else
  rec ok "rollback: un archive de la misma release y OTRO pkgrel se rechaza (bore vs bmq)"
fi
rm -f "$ROLLBACK_MANIFEST"
if rollback_manifest_matches "7.2.7-cizen-v3"; then
  rec fail "rollback: sin manifiesto dio por bueno un archive desconocido"
else
  rec ok "rollback: sin manifiesto el archive se rehace en vez de confiar a ciegas"
fi

# preserve_rollback_package: copia el paquete tmpfs al directorio de rollback y
# deja constancia de a qué kernel y scheduler corresponde.
PACMAN_Q_VERSION="7.2.7_cizen_v3-2"
mkdir -p "$SRC"
printf 'paquete falso\n' > "$SRC/linux-cizen-v3-7.2.7_cizen_v3-2-x86_64.pkg.tar.zst"
PKG="$SRC/linux-cizen-v3-7.2.7_cizen_v3-2-x86_64.pkg.tar.zst"
PKG_VERSION="7.2.7_cizen_v3-2"
preserve_rollback_package
if [ -s "$ROLLBACK_DIR/linux-cizen-v3-7.2.7_cizen_v3-2-x86_64.pkg.tar.zst" ]; then
  rec ok "rollback: el paquete instalado queda copiado al directorio de rollback"
else
  rec fail "rollback: el paquete no se copió (quedaría el kernel anterior en el tmpfs)"
fi
[ "$(rollback_manifest_field pkgfile)" = "linux-cizen-v3-7.2.7_cizen_v3-2-x86_64.pkg.tar.zst" ] \
  && rec ok "rollback: el manifiesto apunta al paquete copiado" \
  || rec fail "rollback: pkgfile incorrecto ('$(rollback_manifest_field pkgfile)')"
[ "$(rollback_manifest_field sched)" = "bmq" ] \
  && rec ok "rollback: el paquete preservado firma su scheduler (bmq)" \
  || rec fail "rollback: el scheduler del paquete preservado no es el efectivo"

# Solo "actual + previo": un paquete más viejo se va (son ~100 MB cada uno).
printf 'viejo\n' > "$ROLLBACK_DIR/linux-cizen-v3-7.2.7_cizen_v3-1-x86_64.pkg.tar.zst"
printf 'firma vieja\n' > "$ROLLBACK_DIR/linux-cizen-v3-7.2.7_cizen_v3-1-x86_64.pkg.tar.zst.sig"
printf 'firma del actual\n' > "$ROLLBACK_DIR/linux-cizen-v3-7.2.7_cizen_v3-2-x86_64.pkg.tar.zst.sig"
preserve_rollback_package
[ -f "$ROLLBACK_DIR/linux-cizen-v3-7.2.7_cizen_v3-1-x86_64.pkg.tar.zst" ] \
  && rec fail "rollback: se acumuló un paquete más viejo que el actual" \
  || rec ok "rollback: se poda el paquete de un build anterior (solo actual + previo)"
[ -f "$ROLLBACK_DIR/linux-cizen-v3-7.2.7_cizen_v3-1-x86_64.pkg.tar.zst.sig" ] \
  && rec fail "rollback: la firma .sig del paquete viejo se quedó huérfana" \
  || rec ok "rollback: la firma suelta del paquete viejo se poda con él"
[ -f "$ROLLBACK_DIR/linux-cizen-v3-7.2.7_cizen_v3-2-x86_64.pkg.tar.zst.sig" ] \
  && rec ok "rollback: la firma del paquete vigente se conserva con él" \
  || rec fail "rollback: se podó la firma del paquete que se acaba de preservar"

# Sin paquete que copiar no se rompe nada, pero se dice (fallo blando: que el
# paquete no quede en ningún sitio es justo lo que hace inútil el rollback).
PKG=""
ROLLBACK_PKG_ENABLED=1
warn() { printf 'WARN: %s\n' "$*" >> "$ROOT/warn.log"; }
preserve_rollback_package
grep -q "No hay paquete que preservar" "$ROOT/warn.log" 2>/dev/null \
  && rec ok "rollback: sin paquete que preservar avisa en vez de fingir que está todo bien" \
  || rec fail "rollback: la falta de paquete pasa silenciosa"
ROLLBACK_PKG_ENABLED=0
rm -f "$ROOT/warn.log"
preserve_rollback_package
[ -s "$ROOT/warn.log" ] \
  && rec fail "rollback: CIZEN_ROLLBACK_PKG=0 no desactiva la preservación" \
  || rec ok "rollback: CIZEN_ROLLBACK_PKG=0 desactiva la preservación del paquete"

# prune_rollback_archives: el archive que prepare_rollback_archive acaba de dejar
# es el del kernel EN EJECUCIÓN, y la regla de poda excluía siempre esa release.
# Resultado real del build del 2026-09-29: se creaba y se podaba en la misma
# pasada ("Rollback preparado: …/7.2.8-cizen-v3.tar.xz" y acto seguido "Pruning
# archive de rollback antiguo: 7.2.8-cizen-v3.tar.xz"), así que el resumen
# anunciaba un fichero inexistente y el manifiesto quedaba colgando.
eval "$(extract prune_rollback_archives)"
eval "$(extract rollback_manifest_unset)"
RUNREL="$(uname -r)"
printf 'viejo\n'   > "$ROLLBACK_DIR/$VERSION.tar.xz"
printf 'sello\n'    > "$ROLLBACK_DIR/$VERSION.timestamp"
printf 'vigente\n'  > "$ROLLBACK_DIR/$RUNREL.tar.xz"
rollback_manifest_set archive "$RUNREL.tar.xz"
prune_rollback_archives "$ROLLBACK_DIR/$RUNREL.tar.xz"
[ -f "$ROLLBACK_DIR/$RUNREL.tar.xz" ] \
  && rec ok "rollback: el archive del kernel en ejecución sobrevive al prune (lo protege quien lo dejó)" \
  || rec fail "rollback: el prune borró el archive recién preparado (desaparece la red del build)"
[ -f "$ROLLBACK_DIR/$VERSION.tar.xz" ] \
  && rec fail "rollback: se acumularon dos archives de rollback" \
  || rec ok "rollback: el archive viejo se poda aunque el nuevo esté protegido"
[ "$(rollback_manifest_field archive)" = "$RUNREL.tar.xz" ] \
  && rec ok "rollback: el manifiesto sigue apuntando al archive que sobrevive" \
  || rec fail "rollback: el manifiesto perdió el archive superviviente ('$(rollback_manifest_field archive)')"

# Y al revés: si el archive announcing el manifiesto es el que se poda, la clave
# desaparece en vez de quedar apuntando a un fichero que ya no está.
rollback_manifest_set archive "$VERSION.tar.xz"
printf 'viejo\n' > "$ROLLBACK_DIR/$VERSION.tar.xz"
printf 'otro\n'  > "$ROLLBACK_DIR/7.2.6.tar.xz"
prune_rollback_archives "$ROLLBACK_DIR/$RUNREL.tar.xz"
[ -z "$(rollback_manifest_field archive)" ] \
  && rec ok "rollback: al podar el archive del manifiesto, la clave se limpia" \
  || rec fail "rollback: el manifiesto sigue anunciando un archive podado ('$(rollback_manifest_field archive)')"
grep -q '^archive=' "$ROLLBACK_MANIFEST" 2>/dev/null \
  && rec fail "rollback: quedó una línea archive= en el manifiesto tras la poda" \
  || rec ok "rollback: la línea archive= desaparece del manifiesto al podarse"
rm -rf "$RB"; rm -f "$SRC"/*.pkg.tar.zst

# krollback reinstala con pacman -U y regenera la UKI: si se queda en extraer
# ficheros, la base de datos sigue mintiendo sobre qué kernel está instalado.
KROLLBACK="$(dirname "$MOTOR")/kernel-update-rollback.sh"
if [ -r "$KROLLBACK" ]; then
  bash -n "$KROLLBACK" 2>/dev/null \
    && rec ok "krollback: bash -n limpio" \
    || rec fail "krollback: no pasa bash -n"
  if grep -q 'pacman -U "\$pkgpath"' "$KROLLBACK"; then
    rec ok "krollback: el plan A reinstala el paquete con pacman -U"
  else
    rec fail "krollback: no reinstala el paquete (sigue siendo solo extraer ficheros)"
  fi
  # Sin regenerar la UKI, reiniciar volvería a arrancar el kernel que se acaba
  # de sustituir: el UKI del ESP apunta al kernel nuevo.
  if grep -q 'cizen-uki-sync' "$KROLLBACK"; then
    rec ok "krollback: regenera el UKI tras reinstalar (si no, se reinicia al kernel nuevo)"
  else
    rec fail "krollback: no regenera el UKI; el reboot volvería al kernel que se sustituyó"
  fi
  # El scheduler del paquete anterior se nombra explícitamente: bore y bmq se
  # llaman igual, y el usuario tiene que ver a cuál vuelve.
  if grep -q 'scheduler: %s' "$KROLLBACK" && grep -q 'sched' "$KROLLBACK"; then
    rec ok "krollback: --list enseña el scheduler del kernel anterior"
  else
    rec fail "krollback: no enseña qué scheduler tiene el kernel anterior"
  fi
  # El plan B (ficheros) tiene que existir pero decir lo que cuesta: deja la base
  # de datos de pacman mintiendo.
  if grep -q 'NO es un downgrade de paquete' "$KROLLBACK"; then
    rec ok "krollback: el plan B advierte de que deja pacman desincronizado"
  else
    rec fail "krollback: el plan B no advierte de la desincronización de pacman"
  fi
  CIZEN_ROLLBACK_DIR="$ROOT/empty-rollback" bash "$KROLLBACK" --list >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rec ok "krollback: --list avisa (no revienta) si no hay nada que restaurar"
  else
    rec fail "krollback: --list con el directorio vacío devolvió rc=0"
  fi
else
  printf '  (sin %s: se omiten los tests de krollback)\n' "$KROLLBACK"
fi

# --- v27.31.30: la UKI se construye con ukify y sin --uname el propio ukify
# avisa ("Kernel version not specified, starting autodetection 😖") y adivina la
# versión por su cuenta: con varios kernels instalados puede quedarse con otra,
# y la UKI queda firmada con una .uname que no corresponde. Trampa: el flag es
# --uname, NO --version (este imprime la versión de ukify y sale con rc=0 sin
# construir nada, o sea: UKI vacía "con éxito").
UKISYNC="$(dirname "$MOTOR")/cizen-uki-sync"
if [ -r "$UKISYNC" ]; then
  export UKIREL="7.9.9-cizen-v3"   # el probe de abajo lo lee (heredoc entrecomillado)
  mkdir -p "$ROOT/ukibuild/usr/lib/modules/$UKIREL" "$ROOT/ukifake"
  : > "$ROOT/ukibuild/usr/lib/modules/$UKIREL/vmlinuz"
  printf 'root=UUID=cizen-test rw\n' > "$ROOT/ukibuild/cmdline"
  cat > "$ROOT/ukifake/ukify" <<'UKIFY'
#!/bin/bash
printf '%s\n' "$@" > "$UKIFY_ARGS"
UKIFY
  chmod +x "$ROOT/ukifake/ukify"
  sed -n '/^build_uki() {/,/^}/p' "$UKISYNC" > "$ROOT/ukibuild/build_uki.sh"
  cat > "$ROOT/ukibuild/probe.sh" <<'PROBE'
set -u
CIZEN_UKI_SUFFIX="-cizen-v3"
CIZEN_UKI_PKGBASE="linux-cizen-test"
CIZEN_UKI_ALLOW_RAW_KERNEL_FALLBACK=0
export UKIFY_ARGS="$ROOT/ukibuild/args"
PATH="$ROOT/ukifake:$PATH"
ok() { :; }
warn() { :; }
info() { :; }
# v27.31.39: build_uki ya no embebe /boot/initramfs-*.img a ciegas, pide el
# initramfs a cizen_initramfs_prepare (que lo regenera y lo valida). Aquí se
# sustituye por un stub que dice "no hay ninguno" para no meter un /boot de
# verdad en el test; el comportamiento del prepare+validate tiene sus propios
# tests más abajo.
cizen_initramfs_prepare() { INITRAMFS_PATH=""; return 1; }
# shellcheck disable=SC1090
source "$ROOT/ukibuild/build_uki.sh"
build_uki "$ROOT/ukibuild/usr/lib/modules/$UKIREL/vmlinuz" \
          "$ROOT/ukibuild/cmdline" "$ROOT/ukibuild/out.efi" >/dev/null 2>&1
PROBE
  bash "$ROOT/ukibuild/probe.sh"
  if grep -qx -- "--uname=$UKIREL" "$ROOT/ukibuild/args" 2>/dev/null; then
    rec ok "uki: ukify recibe --uname con la versión del kernel (sin autodetección)"
  else
    rec fail "uki: ukify NO recibe --uname=$UKIREL (args: $(tr '\n' ' ' < "$ROOT/ukibuild/args" 2>/dev/null))"
  fi
  if grep -q -- '--version' "$ROOT/ukibuild/args" 2>/dev/null; then
    rec fail "uki: ukify recibe --version (imprime su versión y sale: UKI sin construir)"
  else
    rec ok "uki: no se usa --version, que en ukify es la versión del programa"
  fi
else
  printf '  (sin %s: se omiten los tests de la UKI)\n' "$UKISYNC"
fi

# --- v27.31.41: build_uki con initramfs no puede reventar con "unbound variable"
# El camino NORMAL de la UKI (CON initramfs) moría con
#   "cizen-uki-sync: line 744: ucode_tmp: unbound variable"
# justo después de que ukify escribiera el UKI en /tmp: el script se llevaba por
# delante el firma, la copia al ESP y la limpieza. Causa: `ucode_tmp` se
# declaraba con `local` DENTRO de la rama `if have_initrd -eq 0` (el microcode
# standalone), pero la limpieza `[ -n "$ucode_tmp" ] && rm -f ...` está FUERA, y
# con `set -u` usarla sin declarar es error fatal. O sea que solo moría en el
# camino que se usa siempre.
#
# El test de arriba no podía verlo: su stub hace `cizen_initramfs_prepare(){ return 1; }`,
# o sea que ejercita justo la rama donde la variable SÍ se declara. Este la
# invierte: prepare devuelve initramfs y se comprueba que build_uki llega al
# ukify con --initrd, sin --microcode (el microcode ya va en el initramfs) y sin
# morir. Es además el primer test que fija el comportamiento de v27.31.38 en el
# camino que realmente corre.
if [ -r "$UKISYNC" ] && [ -s "$ROOT/ukibuild/build_uki.sh" ]; then
  printf 'initramfs-de-prueba\n' > "$ROOT/ukibuild/initrd.img"
  cat > "$ROOT/ukibuild/probe-initrd.sh" <<'PROBEINITRD'
# LC_ALL=C como en los scripts reales: el mensaje de variable sin asignar sale
# en el idioma del entorno, y una aserción atada a "unbound variable" no
# detectaría nada en una sesión en español.
set -u
export LC_ALL=C
CIZEN_UKI_SUFFIX="-cizen-v3"
CIZEN_UKI_PKGBASE="linux-cizen-test"
CIZEN_UKI_ALLOW_RAW_KERNEL_FALLBACK=0
export UKIFY_ARGS="$ROOT/ukibuild/args-initrd"
PATH="$ROOT/ukifake:$PATH"
ok() { :; }
warn() { :; }
info() { :; }
err() { :; }
cizen_initramfs_prepare() { INITRAMFS_PATH="$ROOT/ukibuild/initrd.img"; return 0; }
# shellcheck disable=SC1090
source "$ROOT/ukibuild/build_uki.sh"
build_uki "$ROOT/ukibuild/usr/lib/modules/$UKIREL/vmlinuz" \
          "$ROOT/ukibuild/cmdline" "$ROOT/ukibuild/out-initrd.efi"
echo "RC=$?"
PROBEINITRD
  out_initrd="$(bash "$ROOT/ukibuild/probe-initrd.sh" 2>&1)"
  # Se aceptan las dos grafías del mensaje por si el locale se colara.
  if printf '%s' "$out_initrd" | grep -qE 'ucode_tmp: (unbound variable|variable sin asignar)'; then
    rec fail "uki: build_uki con initramfs muere por una variable sin declarar: $(printf '%s' "$out_initrd" | grep -E 'ucode_tmp: ' | head -1)"
  else
    rec ok "uki: build_uki con initramfs no muere por variables sin declarar (el camino normal)"
  fi
  if grep -qx -- "--initrd=$ROOT/ukibuild/initrd.img" "$ROOT/ukibuild/args-initrd" 2>/dev/null; then
    rec ok "uki: con initramfs, ukify recibe el initrd que validó prepare"
  else
    rec fail "uki: con initramfs, ukify NO recibe el initrd (args: $(tr '\n' ' ' < "$ROOT/ukibuild/args-initrd" 2>/dev/null))"
  fi
  if grep -q -- '--microcode' "$ROOT/ukibuild/args-initrd" 2>/dev/null; then
    rec fail "uki: con initramfs se inyecta --microcode además (el microcode ya va en el initramfs)"
  else
    rec ok "uki: con initramfs NO se inyecta --microcode (el microcode ya va dentro, sin duplicar)"
  fi
fi

# --- v27.31.42: un 'sbctl verify' que no encuentra la ESP no es "UKI sin firmar"
# En producción: sbctl sign decía OK, la UKI se escribía y firmaba en el ESP, y
# acto seguido el script moría con "La UKI no quedó firmada con Secure Boot
# ACTIVO: el sistema no arrancaría". La UKI estaba firmada; lo que no funcionaba
# era el VERIFICADOR, porque 'sbctl verify' exige descubrir la ESP y en este host
# no la encuentra (§33.6). O sea: un fallo del verificador se confundía con un
# fallo de firma, y la consecuencia de creerlo era dejar el equipo sin arrancar.
#
# Regla que se fija aquí: el veredicto es el código de salida de 'sbctl sign'
# (que no devuelve 0 si no firmó). 'sbctl verify' y la sección .sig son apoyo y
# solo avisan; nunca convierten un fichero firmado en un fallo.
if [ -r "$UKISYNC" ]; then
  mkdir -p "$ROOT/signfake"
  # sbctl que FIRMA (escribe el fichero, como haria sbctl) pero cuyo 'verify'
  # falla siempre con el error de la ESP, igual que en este equipo.
  cat > "$ROOT/signfake/sbctl" <<'SBCTLSIGN'
#!/bin/bash
# v27.31.43: el destino es el ULTIMO argumento, no el segundo. El motor firma con
# 'sbctl sign --save <file>' (el flag va primero, como en sbctl), asi que con
# ${2} este stub se comia el --save como nombre de fichero y sembraba un
# archivo llamado '--save' en el directorio de trabajo: uno llego a commitearse
# en el repo. Ademas lo que sbctl sign --save escribe es <file>.sig, y el motor
# mira justamente esa seccion.
case "${1:-}" in
  sign)
    f=""
    for a in "$@"; do case "$a" in -*) ;; *) f="$a" ;; esac; done
    [ -n "$f" ] || { echo "sign sin fichero" >&2; exit 2; }
    # .sig con contenido, como la firma real: el motor mira esa seccion, y un
    # fichero vacio no es una seccion.
    printf 'EFI_SIGNATURE_LIST-falsa\n' > "$f.sig"; printf 'firmado\n'
    exit 0 ;;
  verify) echo "failed to find EFI system partition" >&2; exit 1 ;;
  *) exit 0 ;;
esac
SBCTLSIGN
  chmod +x "$ROOT/signfake/sbctl"
  # El objetivo "ya firmado":UKI con contenido reconocible, para saber si la
  # restauraron o la dejaron como la nueva.
  printf 'UKI-VIEJA\n' > "$ROOT/signobj.efi"
  printf 'UKI-NUEVA\n' > "$ROOT/signnew.efi"
  sed -n '/^uki_prev_stage() {/,/^}/p;/^uki_prev_restore() {/,/^}/p;/^uki_prev_drop() {/,/^}/p' "$UKISYNC" > "$ROOT/signblk.sh"
  sed -n '/^sign_uki_targets() {/,/^}/p' "$UKISYNC" >> "$ROOT/signblk.sh"
  res="$(SIGNOBJ="$ROOT/signobj.efi" SIGNNEW="$ROOT/signnew.efi" \
    SBCTL_BIN="$ROOT/signfake/sbctl" PATH="$ROOT/signfake:$PATH" \
    bash -c 'set -u; SUDO=(); ok(){ echo "OK:$1"; }; warn(){ echo "WARN:$1"; }; err(){ echo "ERR:$1"; }; . "$0"
             # 1) firma bien: el verificador roto NO puede convertirlo en fallo
             sign_uki_targets "$SIGNOBJ" >/dev/null 2>&1; echo "rc_firmado=$?"
             # 2) stage + restauracion, en el ORDEN REAL: se respalda lo que hay
             # (la UKI vieja) ANTES de sobrescribir, y si al final no hay firma
             # se vuelve a ella. Respaldar despues de escribir seria respaldar la
             # nueva, que es justo el fallo que el guard evita.
             uki_prev_stage "$SIGNOBJ" >/dev/null 2>&1
             cp -f "$SIGNNEW" "$SIGNOBJ"
             uki_prev_restore "$SIGNOBJ" >/dev/null 2>&1; echo "rc_restore=$?"
             echo "contenido=$(cat "$SIGNOBJ")"' \
    "$ROOT/signblk.sh" 2>/dev/null)"
  # El flag --save va ANTES del fichero: si un consumidor lo toma por el nombre
  # del destino acaba escribiendo un archivo llamado --save, y deja la seccion
  # .sig sin crear, que es lo que el motor mira para saber que si se firmo.
  if [ -s "$ROOT/signobj.efi.sig" ] && [ ! -e "$ROOT/--save" ] && [ ! -e "./--save" ]; then
    rec ok "firma: 'sbctl sign --save <file>' trata el flag como flag y deja la seccion .sig"
  else
    rec fail "firma: el destino de 'sbctl sign --save' no es el fichero (--save tomado por nombre, o .sig sin crear)"
  fi
  if printf '%s' "$res" | grep -q 'rc_firmado=0'; then
    rec ok "firma: sbctl sign OK + sbctl verify roto NO se lee como UKI sin firmar"
  else
    rec fail "firma: un verify que no encuentra la ESP se está tomando por una UKI sin firmar (${res:-sin salida})"
  fi
  if printf '%s' "$res" | grep -q 'contenido=UKI-VIEJA'; then
    rec ok "firma: si la UKI nueva no se puede firmar, se restaura la anterior (no se deja sin firmar en el ESP)"
  else
    rec fail "firma: la UKI anterior NO se restauró tras un fallo de firma (${res:-sin salida})"
  fi
  # 3) Y al revés: si sbctl sign falla de verdad, el veredicto tiene que ser
  #    fallo, no un aviso. Un guard que restaurase UKIs sobre una suposición
  #    sería peor que no tener guard.
  cat > "$ROOT/signfake/sbctl" <<'SBCTLSIGNFAIL'
#!/bin/bash
case "${1:-}" in
  sign)   echo "error al firmar" >&2; exit 1 ;;
  verify) echo "failed to find EFI system partition" >&2; exit 1 ;;
  *) exit 0 ;;
esac
SBCTLSIGNFAIL
  chmod +x "$ROOT/signfake/sbctl"
  res2="$(SIGNOBJ="$ROOT/signobj.efi" SBCTL_BIN="$ROOT/signfake/sbctl" PATH="$ROOT/signfake:$PATH" \
    bash -c 'set -u; SUDO=(); ok(){ :; }; warn(){ :; }; err(){ :; }; . "$0"; sign_uki_targets "$SIGNOBJ" >/dev/null 2>&1; echo "rc=$?"' \
    "$ROOT/signblk.sh" 2>/dev/null)"
  if printf '%s' "$res2" | grep -q 'rc=1'; then
    rec ok "firma: si sbctl sign falla de verdad, el veredicto es fallo (y entonces sí se restaura)"
  else
    rec fail "firma: sbctl sign fallando NO da veredicto de fallo (${res2:-sin salida}); se firmaría sin comprobar"
  fi
  # 4) El motor replica la misma regla: su veredicto es el codigo de sbctl sign.
  if sed -n '/^cizen_uki_sign_targets() {/,/^}/p' "$MOTOR" | grep -qE '\[ "\$fail" -eq 0 \] \|\| return 1'; then
    rec ok "firma: el motor aplica la misma regla (veredicto = sbctl sign, no el verify)"
  else
    rec fail "firma: el motor no replica la regla del veredicto; puede volver a declarar sin firmar una UKI firmada"
  fi
fi

# --- v27.31.32: el nombre +N del boot counting rompía cada 'pacman -Syu' ---
# El UKI se escribía como arch-linux-cizen-v3+3.efi, se firmaba con
# 'sbctl sign --save' (que registra ESE nombre en /var/lib/sbctl/files.json) y
# systemd-bless-boot lo renombraba a plano al completar el arranque: la entrada
# quedaba huérfana y el hook zzz-sbctl.hook ('sbctl sign-all -g') abortaba con
# "does not exist", dejando el -Syu en "error: la orden no se ejecutó
# correctamente". El default pasa a UKI PLANA + purge de la BD de sbctl.
if [ -r "$UKISYNC" ]; then
  # a) El default declarado es 0 en los DOS scripts (motor y cizen-uki-sync):
  #    si alguien lo vuelve a poner a 3 sin saber lo que cuesta, cae el test.
  if grep -q 'CIZEN_BOOT_TRIES="${CIZEN_BOOT_TRIES:-0}"' "$UKISYNC" \
     && grep -q 'CIZEN_BOOT_TRIES="${CIZEN_BOOT_TRIES:-0}"' "$MOTOR"; then
    rec ok "uki: CIZEN_BOOT_TRIES=0 (nombre plano) por defecto en motor y cizen-uki-sync"
  else
    rec fail "uki: CIZEN_BOOT_TRIES ya no es 0 por defecto (vuelve el UKI +N.efi y pacman falla)"
  fi

  # b) uki_efi_name: plano sin contador, +N solo si se pide explícitamente.
  sed -n '/^uki_efi_name() {/,/^}/p' "$UKISYNC" > "$ROOT/ukiname.sh"
  n_def="$(CIZEN_UKI_NAME=arch-linux-cizen-v3.efi bash -c 'set -u; . "$0"; uki_efi_name' "$ROOT/ukiname.sh" 2>/dev/null || true)"
  n_3="$(CIZEN_UKI_NAME=arch-linux-cizen-v3.efi CIZEN_BOOT_TRIES=3 \
         bash -c 'set -u; . "$0"; uki_efi_name' "$ROOT/ukiname.sh" 2>/dev/null || true)"
  if [ "$n_def" = "arch-linux-cizen-v3.efi" ]; then
    rec ok "uki: el nombre por defecto es arch-linux-cizen-v3.efi (el que pide el preset de mkinitcpio)"
  else
    rec fail "uki: el nombre por defecto no es el plano (obtenido: '${n_def:-vacio}')"
  fi
  if [ "$n_3" = "arch-linux-cizen-v3+3.efi" ]; then
    rec ok "uki: CIZEN_BOOT_TRIES=3 sigue dando el +3.efi (opt-in explícito, no el default)"
  else
    rec fail "uki: CIZEN_BOOT_TRIES=3 no produce el nombre con contador (obtenido: '${n_3:-vacio}')"
  fi

  # c) La BD de sbctl: solo se detectan como huérfanas las entradas cuyo
  #    fichero NO existe (el +3 renombrado), nunca las que sí están.
  mkdir -p "$ROOT/esp/Linux" "$ROOT/esp/BOOT"
  : > "$ROOT/esp/Linux/arch-linux-cizen-v3.efi"
  : > "$ROOT/esp/Linux/arch-linux-lts.efi"
  cat > "$ROOT/sbdb.json" <<JSON
{
    "/boot/EFI/Linux/arch-linux-cizen-v3+3.efi": {
        "file": "/boot/EFI/Linux/arch-linux-cizen-v3+3.efi",
        "output_file": "/boot/EFI/Linux/arch-linux-cizen-v3+3.efi"
    },
    "$ROOT/esp/Linux/arch-linux-cizen-v3.efi": {
        "file": "$ROOT/esp/Linux/arch-linux-cizen-v3.efi",
        "output_file": "$ROOT/esp/Linux/arch-linux-cizen-v3.efi"
    },
    "$ROOT/esp/Linux/arch-linux-lts.efi": {
        "file": "$ROOT/esp/Linux/arch-linux-lts.efi",
        "output_file": "$ROOT/esp/Linux/arch-linux-lts.efi"
    }
}
JSON
  sed -n '/^sbctl_stale_entries() {/,/^}/p' "$UKISYNC" > "$ROOT/stale.sh"
  # SUDO se define DENTRO del bash -c: un array no se puede pasar por el
  # entorno (llegaría como la cadena "()" y "${SUDO[@]}" sería una orden).
  stale="$(bash -c 'set -u; SUDO=(); . "$0"; sbctl_stale_entries "$1"' "$ROOT/stale.sh" "$ROOT/sbdb.json" 2>/dev/null || true)"
  if [ "$stale" = "/boot/EFI/Linux/arch-linux-cizen-v3+3.efi" ]; then
    rec ok "sbctl: la BD solo marca como huérfana la entrada +3 renombrada, no las UKIs existentes"
  else
    rec fail "sbctl: la detección de huérfanos no aísla el +3.efi (obtenido: '${stale:-vacio}')"
  fi

  # d) El purge llama a 'sbctl remove-file' SOLO con la huérfana. Con un sbctl
  #    falso que registra sus argumentos: si 'sign-all' siguiera viendo la
  #    entrada, el próximo pacman -Syu moriría igual.
  mkdir -p "$ROOT/sbctlfake"
  cat > "$ROOT/sbctlfake/sbctl" <<'SBCTL'
#!/bin/bash
[ "${1:-}" = remove-file ] && printf '%s\n' "${2:-}" >> "$SBCTL_LOG"
exit 0
SBCTL
  chmod +x "$ROOT/sbctlfake/sbctl"
  sed -n '/^sbctl_prune_stale() {/,/^}/p' "$UKISYNC" >> "$ROOT/stale.sh"
  : > "$ROOT/sbctl.log"
  SBCTL_LOG="$ROOT/sbctl.log" SBCTL_BIN="$ROOT/sbctlfake/sbctl" \
  bash -c 'set -u; SUDO=(); . "$0"; SBCTL_DB_FILE="$1"; sbctl_prune_stale' \
    "$ROOT/stale.sh" "$ROOT/sbdb.json" >/dev/null 2>&1
  if [ "$(cat "$ROOT/sbctl.log" 2>/dev/null)" = "/boot/EFI/Linux/arch-linux-cizen-v3+3.efi" ]; then
    rec ok "sbctl: el purge elimina la entrada huérfana y deja intactas las que existen"
  else
    rec fail "sbctl: el purge no quitó la entrada huérfana (log: $(tr '\n' ' ' < "$ROOT/sbctl.log" 2>/dev/null))"
  fi

  # e) El motor tiene su propio prune (lo usa cuando firma sin pasar por
  #    cizen-uki-sync) y detecta la misma huérfana.
  if sed -n '/^cizen_uki_sbctl_prune() {/,/^}/p' "$MOTOR" | grep -q 'remove-file'; then
    rec ok "uki: el motor sanea la BD de sbctl antes de firmar (ruta directa, sin cizen-uki-sync)"
  else
    rec fail "uki: el motor no sanea la BD de sbctl; un +3 muerto rompe el hook de pacman igual"
  fi

  # f) v27.31.33: el ESP vfat no distingue mayúsculas, así que /boot/efi y
  #    /boot/EFI son el MISMO directorio y recorrer las tres raíces devolvía el
  #    UKI dos veces: se escribía y firmaba dos veces. 'sort -u' no lo arregla,
  #    porque deduplica cadenas, no ficheros — la identidad real es el inodo.
  #    Falso ESP: un directorio real y un alias con otra grafía al mismo sitio,
  #    como hace vfat con mayúsculas. Las raíces se sustituyen por $TEST_ROOTS
  #    (nunca definido en producción) para no depender del /boot real.
  mkdir -p "$ROOT/esp/boot/EFI/Linux"
  : > "$ROOT/esp/boot/EFI/Linux/arch-linux-cizen-v3.efi"
  : > "$ROOT/esp/boot/EFI/Linux/arch-linux-cizen-v3+3.efi"   # variante vieja
  ln -sfn EFI "$ROOT/esp/boot/efi"                          # alias en minúsculas
  cat > "$ROOT/fakeesp.sh" <<'FAKE'
# find() que aterriza en el ESP falso. El directorio se resuelve con realpath (como
# haría el vfat al no distinguir mayúsculas) pero la RUTA DEVUELTA conserva la
# grafía con la que se llegó: eso es justo lo que hace que dos rutas distintas
# apunten al mismo fichero, que es lo que hay que deduplicar.
find() {
  local root="$1" real
  case "$root" in
    "$FAKE_ESP"/*) : ;;
    *) command find "$@" ;;
  esac
  [ -d "$root" ] || return 0
  real="$(realpath -m -- "$root")"
  shift
  command find "$real" "$@" | sed "s|^$real|$root|"
}
FAKE
  # find_uki_targets + cleanup_uki_variants + el resolutor de nombres, con la
  # lista de raíces sustituida por el ESP falso (las dos grafías posibles de esa
  # lista, para que el arnés no dependa de en qué orden la escribió el código).
  # OJO: al sustituir la lista entera por $TEST_ROOTS, el orden del código deja
  # demeasurable aquí — eso lo fijan los tests de grep de más abajo. Lo que sí
  # miden estos dos es la deduplicación: de varias grafías del mismo inodo gana
  # la primera, y con $TEST_ROOTS en orden de punto de montaje el superviviente
  # es la grafía buena.
  { sed -n '/^uki_efi_name() {/,/^}/p; /^find_uki_targets() {/,/^}/p; /^cleanup_uki_variants() {/,/^}/p' \
      "$UKISYNC" \
    | sed -e 's|^\( *\)for r in /boot /efi /boot/efi; do|\1for r in ${TEST_ROOTS}; do|' \
           -e 's|^\( *\)for r in /efi /boot/efi /boot; do|\1for r in ${TEST_ROOTS}; do|'
    cat "$ROOT/fakeesp.sh"; } > "$ROOT/tgt.sh"
  n_t="$(FAKE_ESP="$ROOT/esp" TEST_ROOTS="$ROOT/esp/boot $ROOT/esp/efi $ROOT/esp/boot/efi" \
    bash -c 'set -u; SUDO=(); . "$0"
      CIZEN_UKI_NAME=arch-linux-cizen-v3.efi; CIZEN_BOOT_TRIES=0
      find_uki_targets arch-linux-cizen-v3.efi' "$ROOT/tgt.sh" 2>/dev/null)"
  if [ "$(printf '%s\n' "$n_t" | wc -l)" = 1 ] && [ "$n_t" = "$ROOT/esp/boot/EFI/Linux/arch-linux-cizen-v3.efi" ]; then
    rec ok "uki: el UKI se localiza una sola vez, con la grafía del punto de montaje real"
  else
    rec fail "uki: find_uki_targets devolvió [$(printf '%s' "$n_t" | tr '\n' ' ')]: duplica o elige un alias del ESP"
  fi
  # El cleanup tampoco puede intentar borrar dos veces la misma variante: rm
  # interceptado que solo registra (así el fixture sobrevive al test).
  : > "$ROOT/rm.log"
  FAKE_ESP="$ROOT/esp" TEST_ROOTS="$ROOT/esp/boot $ROOT/esp/efi $ROOT/esp/boot/efi" \
    RM_LOG="$ROOT/rm.log" bash -c 'set -u; SUDO=(); . "$0"
      rm() { printf "%s\n" "${*: -1}" >> "$RM_LOG"; }
      CIZEN_UKI_NAME=arch-linux-cizen-v3.efi; CIZEN_BOOT_TRIES=0
      cleanup_uki_variants' "$ROOT/tgt.sh" 2>/dev/null
  n_rm="$(wc -l < "$ROOT/rm.log")"
  if [ "${n_rm:-0}" = 1 ] \
     && grep -q "$ROOT/esp/boot/EFI/Linux/arch-linux-cizen-v3+3.efi" "$ROOT/rm.log" \
     && ! grep -q 'arch-linux-cizen-v3\.efi$' "$ROOT/rm.log"; then
    rec ok "uki: cleanup_uki_variants borra la variante +N una sola vez y respeta el nombre plano"
  else
    rec fail "uki: cleanup_uki_variants no borró la +N exactamente una vez (log: $(tr '\n' ' ' < "$ROOT/rm.log" 2>/dev/null))"
  fi
  # Y el motor (ruta directa, sin cizen-uki-sync) deduplica igual.
  if sed -n '/^find_cizen_uki_targets() {/,/^}/p' "$MOTOR" | grep -q "stat -c '%d:%i'"; then
    rec ok "uki: el motor deduplica los objetivos por inodo (find_cizen_uki_targets)"
  else
    rec fail "uki: find_cizen_uki_targets no deduplica por inodo; el UKI se escribe y firma dos veces"
  fi
  if sed -n '/^cizen_uki_cleanup_variants() {/,/^}/p' "$MOTOR" | grep -q "stat -c '%d:%i'"; then
    rec ok "uki: cizen_uki_cleanup_variants deduplica por inodo (no borra dos veces la misma variante)"
  else
    rec fail "uki: cizen_uki_cleanup_variants no deduplica por inodo"
  fi

  # h) v27.31.35: el orden de las raíces decide con qué GRAFÍA se firma, y eso
  #    es lo que mete claves de más en la BD de sbctl. Esto es lo que mide el
  #    orden de verdad (los dos probes de arriba no lo pueden: sustituyen la
  #    lista entera por $TEST_ROOTS). En vfat /boot/efi y
  #    /boot/EFI son el mismo fichero; si gana la primera raíz que lo encuentra
  #    y esa es un alias, 'sbctl sign --save' inscribe una clave NUEVA para un
  #    fichero que ya estaba inscrito con su nombre bueno (inocuo, pero en cada
  #    sync). Por eso /boot —el punto de montaje real— va el primero.
  for f in find_uki_targets detect_esp_root cleanup_uki_variants; do
    if sed -n "/^$f() {/,/^}/p" "$UKISYNC" | grep -q 'for r in /boot /efi /boot/efi'; then
      rec ok "uki: $f recorre /boot primero (gana la grafía del punto de montaje real)"
    else
      rec fail "uki: $f no empieza por /boot; firmaría la grafía de un alias del ESP"
    fi
  done
  for f in find_cizen_uki_targets detect_cizen_esp_root cizen_uki_cleanup_variants collect_systemd_boot_targets; do
    if sed -n "/^$f() {/,/^}/p" "$MOTOR" | grep -q 'for r in /boot /efi /boot/efi'; then
      rec ok "uki: $f (motor) recorre /boot primero"
    else
      rec fail "uki: $f (motor) no empieza por /boot; firmaría la grafía de un alias del ESP"
    fi
  done
  if sed -n '/^collect_systemd_boot_targets() {/,/^}/p' "$MOTOR" | grep -q "stat -c '%d:%i'"; then
    rec ok "uki: el gestor también se deduplica por inodo (si no, se firma dos veces con dos grafías)"
  else
    rec fail "uki: collect_systemd_boot_targets no deduplica por inodo; 'sort -u' solo deduplica cadenas"
  fi

  # g) v27.31.34: un comentario que pierde el '#' NO lo caza ni 'bash -n' ni
  #    la revisión estática. La línea «# /boot/efi y /boot/EFI son el MISMO
  #    directorio» sin el '#' inicial es una ORDEN perfectamente válida
  #    ('/boot/efi' con argumentos), así que pasa las dos revisiones estáticas y
  #    solo revienta al ejecutarse: aquí abortó el sync entero en producción con
  #    'line 165: /boot/efi: Is a
  #    directory'. Deuda de v27.31.33 (§32.12).
  #    Humo de verdad: ejecutar el script. Con un suffix inexistente no hay
  #    kernel que buscar, así que debe morir con SU propio mensaje y solo con él.
  smoke="$(CIZEN_UKI_SUFFIX=-cizen-inexistente bash "$UKISYNC" --dry-run 2>&1)"; smoke_rc=$?
  if [ "$smoke_rc" -eq 0 ] \
     && ! printf '%s' "$smoke" | grep -qiE 'is a directory|command not found|syntax error|no such file or directory'; then
    rec ok "uki: --dry-run solo imprime (no escribe, sale 0) aunque no haya kernel (v27.31.44)"
  else
    rec fail "uki: --dry-run escupió errores o no salió 0: $(printf '%s' "$smoke" | tr '\n' ' ')"
  fi
  # El motor, con su parser de opciones: una opción inválida solo puede dar
  # su propio mensaje de error.
  smoke_m="$(timeout 60 bash "$MOTOR" --opcion-inventada 2>&1 || true)"
  if printf '%s' "$smoke_m" | grep -q 'Opción desconocida: --opcion-inventada' \
     && ! printf '%s' "$smoke_m" | grep -qiE 'is a directory|command not found|syntax error|no such file or directory'; then
    rec ok "uki: el motor arranca limpio y rechaza lo que no es una opción (humo del parser)"
  else
    rec fail "uki: el motor escupió errores al arrancar: $(printf '%s' "$smoke_m" | tr '\n' ' ')"
  fi
else
  printf '  (sin %s: se omiten los tests del nombre de UKI)\n' "$UKISYNC"
fi

# --- v27.31.39: el UKI que arrancaba no era el que creíamos ---
# El preset de mkinitcpio (default_uki=) es un SEGUNDO productor de la misma
# UKI: lo dispara el hook 90-mkinitcpio-install al instalar el kernel y
# `mkinitcpio -P` con cualquier actualización de /usr/lib/initcpio/*. Como este
# proyecto nunca llama a mkinitcpio, ese hook era además el único que generaba
# el initramfs, y la UKI se construía embebiendo a ciegas el fichero que
# hubiera en /boot.
#
# El arranque degraded venía de la sección .ucode, que llevaba el microcode
# Intel en crudo en vez de un cpio: el kernel recibe .ucode + .initrd
# concatenados, el primer byte no es ninguna magic y aborta el desempaquetado
# entero con "invalid magic at start of compressed archive". Como btrfs va
# built-in el equipo arrancaba igual, sin /init, sin udev y sin microcode, y
# solo se veía en una línea del log.
#
# Aquí se comprueba, contra funciones extraídas de los dos scripts:
#   1. el preset deja de construir la UKI y se queda con el initramfs;
#   2. el initramfs se valida antes de embeberlo, recorriendo los segmentos
#      como el kernel: el cpio concatenado de mkinitcpio PASA (es legítimo), y
#      se rechazan la corrupción, el truncamiento, el concatenado sin alinear y
#      un microcode crudo por delante;
#   3. la UKI construida se verifica: la sección .initrd tiene que medir lo
#      que el initramfs validado, la .ucode tiene que ser un cpio, y sin
#      initramfs se avisa del arranque degradado en vez de dejarlo pasar.
if [ -r "$UKISYNC" ]; then
  mkdir -p "$ROOT/initrd/raiz"
  : > "$ROOT/initrd/raiz/init"          # el /init que el kernel busca
  (cd "$ROOT/initrd/raiz" && find . | cpio -o -H newc --quiet) > "$ROOT/initrd/ok.img"
  mkdir -p "$ROOT/initrd/vacio"
  (cd "$ROOT/initrd/vacio" && find . | cpio -o -H newc --quiet) > "$ROOT/initrd/early.img"
  # CPIO temprano + cpio comprimido, que es lo que produce mkinitcpio con zstd.
  # El kernel solo pasa al segundo segmento si el offset cae alineado a 4, así
  # que el relleno de NUL no es decorativo: es parte del formato.
  early_len="$(stat -c '%s' "$ROOT/initrd/early.img")"
  cat "$ROOT/initrd/early.img" > "$ROOT/initrd/concat.img"
  head -c "$(( (4 - early_len % 4) % 4 ))" /dev/zero >> "$ROOT/initrd/concat.img"
  cat "$ROOT/initrd/ok.img" >> "$ROOT/initrd/concat.img"
  # El mismo concatenado con UN byte de relleno en vez de alinear a 4: el
  # kernel se come el NUL, pero el segundo cpio sigue sin caer alineado y ahí
  # se para. Es lo que separa "relleno de alineación" de "relleno de mentira".
  cat "$ROOT/initrd/early.img" > "$ROOT/initrd/desalineado.img"
  head -c 1 /dev/zero >> "$ROOT/initrd/desalineado.img"
  cat "$ROOT/initrd/ok.img" >> "$ROOT/initrd/desalineado.img"
  head -c 4096 /dev/urandom > "$ROOT/initrd/basura.img"
  head -c 200 "$ROOT/initrd/ok.img" > "$ROOT/initrd/truncada.img"
  # Blob de microcode Intel crudo: version=1 (LE) en 0x00 y tamano total en
  # 0x1C. Es exactamente lo que ukify metía en la sección .ucode.
  {
    printf '\001\000\000\000'
    head -c 28 /dev/zero
    printf '\000\002\000\000'
    head -c 564 /dev/zero
  } > "$ROOT/initrd/microcode.img"

  sed -n '/^cizen_uki_claim_preset() {/,/^}/p' \
      "$UKISYNC" > "$ROOT/initrd/claim.sh"
  sed -n '/^cizen_initramfs_path() {/,/^}/p;/^cizen_initramfs_walk() {/,/^}/p;/^cizen_initramfs_validate() {/,/^}/p' \
      "$UKISYNC" >> "$ROOT/initrd/claim.sh"
  cat > "$ROOT/initrd/probe_claim.sh" <<'PROBE'
set -u
SUDO=()
CIZEN_UKI_PKGBASE="linux-cizen-test"
CIZEN_UKI_NAME="arch-linux-cizen-test.efi"
CIZEN_UKI_PRESET_DIR="$ROOT/initrd/preds"
ok(){ :; }; warn(){ :; }; info(){ :; }; err(){ :; }; log(){ :; }
# shellcheck disable=SC1090
source "$ROOT/initrd/claim.sh"
cizen_uki_claim_preset >/dev/null 2>&1
PROBE
  mkdir -p "$ROOT/initrd/preds"
  cat > "$ROOT/initrd/preds/linux-cizen-test.preset" <<'PRESET'
ALL_kver="/boot/vmlinuz-linux-cizen-test"
PRESETS=('default')
#default_config="/etc/mkinitcpio.conf"
#default_image="/boot/initramfs-linux-cizen-test.img"
default_uki="/boot/EFI/Linux/arch-linux-cizen-test.efi"
PRESET
  bash "$ROOT/initrd/probe_claim.sh"
  claimed="$ROOT/initrd/preds/linux-cizen-test.preset"
  if grep -q '^#CIZEN-UKI-OWNED default_uki=' "$claimed"; then
    rec ok "initramfs: el preset de mkinitcpio deja de construir la UKI (ya no hay dos productores)"
  else
    rec fail "initramfs: el preset sigue construyendo la UKI en paralelo"
  fi
  if grep -qE '^[[:space:]]*default_image="/boot/initramfs-linux-cizen-test.img"' "$claimed"; then
    rec ok "initramfs: el preset conserva la producción del initramfs (el hook de pacman no se queda sin hacer nada)"
  else
    rec fail "initramfs: el preset se quedó sin salida; mkinitcpio avisaría 'No image or UKI specified'"
  fi
  if [ -f "$claimed.cizen-orig" ] && grep -q '^default_uki=' "$claimed.cizen-orig"; then
    rec ok "initramfs: el preset original se conserva en .cizen-orig (se puede revertir a mano)"
  else
    rec fail "initramfs: no se guardó copia del preset original"
  fi
  # Idempotencia: la segunda pasada no debe comentarlo dos veces ni duplicar
  # la línea de salida.
  bash "$ROOT/initrd/probe_claim.sh"
  if [ "$(grep -c 'CIZEN-UKI-OWNED' "$claimed")" = 1 ] \
     && [ "$(grep -cE '^[[:space:]]*default_image=' "$claimed")" = 1 ]; then
    rec ok "initramfs: reclamar el preset es idempotente (no se acumula ni en la 2ª pasada ni en la 3ª)"
  else
    rec fail "initramfs: reclamar el preset no es idempotente"
  fi
  # Con el override no se toca nada: preset nuevo, con la UKI activa, y el
  # override puesto tiene que dejarlo byte a byte como estaba.
  mkdir -p "$ROOT/initrd/preds2"
  cp "$ROOT/initrd/preds/linux-cizen-test.preset.cizen-orig" \
     "$ROOT/initrd/preds2/linux-cizen-test.preset"
  sed -n '/^cizen_uki_claim_preset() {/,/^}/p' "$UKISYNC" > "$ROOT/initrd/claim_one.sh"
  cat > "$ROOT/initrd/probe_allow.sh" <<'PROBE2'
set -u
SUDO=()
CIZEN_UKI_PKGBASE="linux-cizen-test"
CIZEN_UKI_NAME="arch-linux-cizen-test.efi"
CIZEN_UKI_PRESET_DIR="$ROOT/initrd/preds2"
CIZEN_UKI_ALLOW_MKINITCPIO_UKI=1
ok(){ :; }; warn(){ :; }; info(){ :; }; err(){ :; }; log(){ :; }
# shellcheck disable=SC1090
source "$ROOT/initrd/claim_one.sh"
cizen_uki_claim_preset >/dev/null 2>&1
PROBE2
  bash "$ROOT/initrd/probe_allow.sh"
  if diff -q "$ROOT/initrd/preds/linux-cizen-test.preset.cizen-orig" \
             "$ROOT/initrd/preds2/linux-cizen-test.preset" >/dev/null 2>&1; then
    rec ok "initramfs: CIZEN_UKI_ALLOW_MKINITCPIO_UKI=1 deja el preset como estaba (opt-in explícito)"
  else
    rec fail "initramfs: el override no se respetó; el preset se modificó igual"
  fi

  cat > "$ROOT/initrd/probe_val.sh" <<'PROBE3'
set -u
ok(){ :; }; warn(){ :; }; err(){ :; }; info(){ :; }; log(){ :; }
# shellcheck disable=SC1090
source "$ROOT/initrd/claim.sh"
for f in ok concat desalineado basura truncada microcode; do
  if cizen_initramfs_validate "$ROOT/initrd/$f.img" >/dev/null 2>&1; then echo "$f OK"; else echo "$f NO"; fi
done
PROBE3
  vals="$(bash "$ROOT/initrd/probe_val.sh" 2>/dev/null || true)"
  if printf '%s\n' "$vals" | grep -qx 'ok OK'; then
    rec ok "initramfs: se acepta un cpio único que trae init"
  else
    rec fail "initramfs: un initramfs correcto se rechaza (vals: $(printf '%s' "$vals" | tr '\n' ' '))"
  fi
  # El diseño real de mkinitcpio con zstd: CPIO temprano (los .ko.zst, el
  # firmware, el microcode) + cpio comprimido detrás. El kernel recorre
  # segmentos, así que esto es un initramfs BUENO. Una versión anterior de
  # esta comprobación lo rechazaba y recetaba COMPRESSION="cat", que además
  # no arreglaba nada: con 'cat' el CPIO temprano sigue ahí, sin comprimir.
  if printf '%s\n' "$vals" | grep -qx 'concat OK'; then
    rec ok "initramfs: se ACEPTA el cpio concatenado de mkinitcpio (temprano + comprimido)"
  else
    rec fail "initramfs: el cpio concatenado de mkinitcpio se rechaza (vals: $(printf '%s' "$vals" | tr '\n' ' '))"
  fi
  if printf '%s\n' "$vals" | grep -qx 'desalineado NO'; then
    rec ok "initramfs: el concatenado sin alinear a 4 bytes se rechaza, como hace el kernel"
  else
    rec fail "initramfs: un concatenado sin alinear pasa la validación (vals: $(printf '%s' "$vals" | tr '\n' ' '))"
  fi
  # El fallo de verdad: microcode Intel crudo delante. Es lo que se colaba en
  # la sección .ucode de la UKI y tumbaba el arranque de los dos kernels.
  if printf '%s\n' "$vals" | grep -qx 'microcode NO'; then
    rec ok "initramfs: se rechaza el microcode Intel crudo (el bug de la sección .ucode)"
  else
    rec fail "initramfs: el microcode crudo pasa la validación (vals: $(printf '%s' "$vals" | tr '\n' ' '))"
  fi
  if printf '%s\n' "$vals" | grep -qx 'basura NO' \
     && printf '%s\n' "$vals" | grep -qx 'truncada NO'; then
    rec ok "initramfs: se rechazan también la imagen corrupta y la truncada"
  else
    rec fail "initramfs: corrupta/truncada no se rechazan (vals: $(printf '%s' "$vals" | tr '\n' ' '))"
  fi

  # La UKI construida se verifica contra el initramfs validado: ukify lo mete
  # tal cual, así que los tamaños tienen que coincidir. Para no depender de
  # tener ukify/objcopy de verdad, el objdump es un stub que anuncia el tamaño
  # de .initrd que le pidamos; lo que se comprueba es el parsing y la
  # comparación, que es donde se decidiría escribir un UKI equivocado.
  sed -n '/^cizen_uki_verify_image() {/,/^}/p' "$UKISYNC" > "$ROOT/initrd/verify.sh"
  mkdir -p "$ROOT/initrd/bin"
  cat > "$ROOT/initrd/bin/objdump" <<'OBJDUMP'
#!/bin/bash
# Stub: imprime las cabeceras de seccion que le pidan por FAKE_INITRD_HEX y
# FAKE_UCODE_HEX. Lo que se comprueba es el parsing y la comparacion.
if [ -n "${FAKE_INITRD_HEX:-}" ]; then
  printf ' 10 .initrd       %s  000000014ef42000  000000014ef42000  00faaa00  2**2\n' "$FAKE_INITRD_HEX"
fi
if [ -n "${FAKE_UCODE_HEX:-}" ]; then
  printf ' 11 .ucode        %s  0000000151bd9000  0000000151bd9000  03c40600  2**2\n' "$FAKE_UCODE_HEX"
fi
exit 0
OBJDUMP
  cat > "$ROOT/initrd/bin/objcopy" <<'OBJCOPY'
#!/bin/bash
# Stub: solo sabe --dump-section .ucode=FICHERO, y pone ahi lo que diga
# FAKE_UCODE_SRC. Es lo que hace el ukify/objcopy de verdad con la seccion.
dest=""
for a in "$@"; do
  case "$a" in
    .ucode=*) dest="${a#.ucode=}" ;;
  esac
done
[ -n "$dest" ] || exit 1
cp -- "${FAKE_UCODE_SRC:?}" "$dest"
OBJCOPY
  chmod +x "$ROOT/initrd/bin/objdump" "$ROOT/initrd/bin/objcopy"
  : > "$ROOT/initrd/uki.efi"
  ok_bytes="$(stat -c '%s' "$ROOT/initrd/ok.img")"
  ok_hex="$(printf '%x' "$ok_bytes")"
  other_bytes="$(stat -c '%s' "$ROOT/initrd/concat.img")"
  other_hex="$(printf '%x' "$other_bytes")"
  ucode_bytes="$(stat -c '%s' "$ROOT/initrd/ok.img")"
  ucode_hex="$(printf '%x' "$ucode_bytes")"
  cat > "$ROOT/initrd/probe_ver.sh" <<'PROBE4'
set -u
SUDO=()
PATH="$ROOT/initrd/bin:$PATH"
ok(){ :; }; warn(){ :; }; err(){ :; }; info(){ :; }; log(){ :; }
# shellcheck disable=SC1090
source "$ROOT/initrd/verify.sh"
# .initrd del mismo tamaño que ok.img -> la UKI es la que se ha validado
FAKE_INITRD_HEX="$OK_HEX" cizen_uki_verify_image "$ROOT/initrd/uki.efi" "$ROOT/initrd/ok.img" >/dev/null 2>&1 \
  && echo "coincide OK" || echo "coincide NO"
# .initrd del tamaño de OTRA imagen -> no es lo que se validó: no se escribe
FAKE_INITRD_HEX="$OTHER_HEX" cizen_uki_verify_image "$ROOT/initrd/uki.efi" "$ROOT/initrd/ok.img" >/dev/null 2>&1 \
  && echo "descuadre NO" || echo "descuadre OK"
# UKI sin .initrd cuando sí se iba a embeber un initramfs -> tampoco se escribe
FAKE_INITRD_HEX="" cizen_uki_verify_image "$ROOT/initrd/uki.efi" "$ROOT/initrd/ok.img" >/dev/null 2>&1 \
  && echo "sin-seccion NO" || echo "sin-seccion OK"
# sin initramfs (arranque degradado): avisa, no aborta
FAKE_INITRD_HEX="" cizen_uki_verify_image "$ROOT/initrd/uki.efi" "" >/dev/null 2>&1 \
  && echo "sin-initrd OK" || echo "sin-initrd NO"
# .ucode que SÍ es un cpio: el kernel lo desempaqueta y sigue con el .initrd
FAKE_INITRD_HEX="$OK_HEX" FAKE_UCODE_HEX="$UCODE_HEX" \
  cizen_uki_verify_image "$ROOT/initrd/uki.efi" "$ROOT/initrd/ok.img" >/dev/null 2>&1 \
  && echo "ucode-cpio OK" || echo "ucode-cpio NO"
# .ucode con el microcode Intel crudo: el kernel concatena .ucode + .initrd,
# el primer byte no es ninguna magic y aborta TODO el desempaquetado. Esto es
# lo que dejo los dos kernels arrancando sin initramfs y sin que se notara.
FAKE_INITRD_HEX="$OK_HEX" FAKE_UCODE_HEX="$UCODE_HEX" FAKE_UCODE_SRC="$ROOT/initrd/microcode.img" \
  cizen_uki_verify_image "$ROOT/initrd/uki.efi" "$ROOT/initrd/ok.img" >/dev/null 2>&1 \
  && echo "ucode-crudo NO" || echo "ucode-crudo OK"
PROBE4
  vals_v="$(OK_HEX="$ok_hex" OTHER_HEX="$other_hex" UCODE_HEX="$ucode_hex" \
             bash "$ROOT/initrd/probe_ver.sh" 2>/dev/null || true)"
  if printf '%s\n' "$vals_v" | grep -qx 'coincide OK'; then
    rec ok "uki: .initrd del tamaño del initramfs validado pasa la verificación"
  else
    rec fail "uki: la verificación rechaza una UKI correcta (vals: $(printf '%s' "$vals_v" | tr '\n' ' '))"
  fi
  if printf '%s\n' "$vals_v" | grep -qx 'descuadre OK' \
     && printf '%s\n' "$vals_v" | grep -qx 'sin-seccion OK'; then
    rec ok "uki: .initrd que no cuadra (o que no está) bloquea la escritura del UKI"
  else
    rec fail "uki: la verificación deja pasar un .initrd que no es el initramfs validado (vals: $(printf '%s' "$vals_v" | tr '\n' ' '))"
  fi
  if printf '%s\n' "$vals_v" | grep -qx 'sin-initrd OK'; then
    rec ok "uki: sin initramfs la verificación avisa del arranque degradado y no aborta"
  else
    rec fail "uki: sin initramfs la verificación se traga el caso y no avisa"
  fi
  if printf '%s\n' "$vals_v" | grep -qx 'ucode-cpio OK'; then
    rec ok "uki: una .ucode que es un cpio pasa la verificación"
  else
    rec fail "uki: la verificación rechaza una .ucode que sí es un cpio (vals: $(printf '%s' "$vals_v" | tr '\n' ' '))"
  fi
  if printf '%s\n' "$vals_v" | grep -qx 'ucode-crudo OK'; then
    rec ok "uki: una .ucode con microcode crudo BLOQUEA la UKI (el bug que tumbó los dos kernels)"
  else
    rec fail "uki: la verificación deja pasar una .ucode con microcode crudo (vals: $(printf '%s' "$vals_v" | tr '\n' ' '))"
  fi

  # Los dos scripts tienen que seguir haciendo lo mismo: la UKI se genera en
  # ambos, y si uno se queda sin initramfs validado, el otro también.
  for fn in cizen_uki_claim_preset cizen_initramfs_path cizen_initramfs_walk \
            cizen_initramfs_validate cizen_initramfs_prepare cizen_uki_verify_image; do
    if sed -n "/^$fn() {/,/^}/p" "$UKISYNC" | grep -q . \
       && sed -n "/^$fn() {/,/^}/p" "$MOTOR" | grep -q .; then
      rec ok "initramfs: $fn está en el motor y en cizen-uki-sync (réplica, no dos versiones distintas)"
    else
      rec fail "initramfs: $fn falta en el motor o en cizen-uki-sync"
    fi
  done
  # Y lo importante: que ninguno embeba ya el fichero a ciegas.
  if sed -n '/^build_uki() {/,/^}/p' "$UKISYNC" | grep -q 'cizen_initramfs_prepare' \
     && sed -n '/^build_cizen_uki() {/,/^}/p' "$MOTOR" | grep -q 'cizen_initramfs_prepare'; then
    rec ok "initramfs: la UKI solo se construye con el initramfs pasado por prepare+validate"
  else
    rec fail "initramfs: algún constructor de UKI sigue embebiendo /boot/initramfs-*.img sin validar"
  fi
else
  printf '  (sin %s: se omiten los tests de initramfs/UKI)\n' "$UKISYNC"
fi

# --- v27.31.43: el hermano primero, y el staging de una run muerta no sobrevive ---
# En producción (§33): el motor invocaba 'sudo cizen-uki-sync' por nombre
# desnudo, así que decidía el PATH. Con la copia plana en /usr/local/bin y la
# de la suite en kernel-update/, ganaba la que estuviera antes; la copia vieja
# Metía el microcode Intel en crudo en la sección .ucode y la UKI arrancaba
# degradada y en silencio. El fichero se borró, pero el despliegue de las 20:07
# lo volvió a crear: el defecto era de código, no de disco. Aquí se fija que la
# resolución da prioridad al HERMANO (el que se despliega con el motor) y que
# ningún script vuelve a invocarlo por nombre desnudo.
if [ -r "$MOTOR" ]; then
  # a) Funcional: con un hermano disponible y OTRO cizen-uki-sync antes en el
  #    PATH, gana el hermano.
  mkdir -p "$ROOT/hermano" "$ROOT/path"
  printf '#!/bin/bash\necho hermano\n' > "$ROOT/hermano/cizen-uki-sync"
  printf '#!/bin/bash\necho path\n'    > "$ROOT/path/cizen-uki-sync"
  chmod +x "$ROOT/hermano/cizen-uki-sync" "$ROOT/path/cizen-uki-sync"
  sed -n '/^cizen_uki_sync_bin() {/,/^}/p' "$MOTOR" > "$ROOT/syncbin.sh"
  if [ -s "$ROOT/syncbin.sh" ]; then
    got="$(SCRIPT_DIR="$ROOT/hermano" PATH="$ROOT/path:$PATH" \
           bash -c 'set -u; . "$0"; cizen_uki_sync_bin' "$ROOT/syncbin.sh" 2>/dev/null || true)"
    if [ "$got" = "$ROOT/hermano/cizen-uki-sync" ]; then
      rec ok "uki: con dos cizen-uki-sync, gana el HERMANO y no el del PATH"
    else
      rec fail "uki: la resolución no da prioridad al hermano (obtenido: '${got:-vacio}')"
    fi
    # b) Sin hermano, el PATH es el recurso: no se rompe la instalación a mano.
    got2="$(SCRIPT_DIR="$ROOT/no-existe" PATH="$ROOT/path:$PATH" \
            bash -c 'set -u; . "$0"; cizen_uki_sync_bin' "$ROOT/syncbin.sh" 2>/dev/null || true)"
    if [ "$got2" = "$ROOT/path/cizen-uki-sync" ]; then
      rec ok "uki: sin hermano, cae al PATH (instalación manual sigue funcionando)"
    else
      rec fail "uki: sin hermano no encuentra el del PATH (obtenido: '${got2:-vacio}')"
    fi
  else
    rec fail "uki: el motor no tiene cizen_uki_sync_bin (la resolución por nombre desnudo vuelve)"
  fi

  # c) Estático: el punto de llamada usa la variable, no el nombre desnudo. Es
  #    la forma exacta en que §33 se coló en producción.
  if grep -qE '^[[:space:]]*(if[[:space:]]+![[:space:]]+)?sudo[[:space:]]+"?\$\{?UKI_SYNC_BIN' "$MOTOR" \
     && ! grep -qE '^[[:space:]]*sudo[[:space:]]+cizen-uki-sync([[:space:]]|$)' "$MOTOR"; then
    rec ok "uki: el motor invoca cizen-uki-sync por ruta resuelta, nunca por nombre"
  else
    rec fail "uki: el motor vuelve a invocar 'sudo cizen-uki-sync' por nombre (PATH puede elegir una copia vieja)"
  fi

  # d) Y que no se exija en el PATH como dependencia: si el hermano está, no
  #    hay nada que instalar (TOOL_PKG no lo tiene, así que sería fatal).
  if sed -n '/^check_prerequisites() {/,/^}/p' "$MOTOR" \
       | grep -qE 'tools=\([^)]*cizen-uki-sync' ; then
    rec fail "prereq: cizen-uki-sync sigue en la lista de tools (exige estar en el PATH)"
  elif sed -n '/^check_prerequisites() {/,/^}/p' "$MOTOR" \
       | grep -q 'cizen_uki_sync_bin'; then
    rec ok "prereq: cizen-uki-sync se comprueba por SCRIPT_DIR, no como comando del PATH"
  else
    rec fail "prereq: no se comprueba cizen-uki-sync por SCRIPT_DIR (ni por tools ni por helper)"
  fi
fi

if [ -r "$KROLLBACK" ]; then
  if sed -n '/^cizen_uki_sync_bin() {/,/^}/p' "$KROLLBACK" | grep -q . \
     && ! grep -qE '^[[:space:]]*sudo[[:space:]]+cizen-uki-sync([[:space:]]|$)' "$KROLLBACK"; then
    rec ok "rollback: regenera la UKI con el hermano, no con el del PATH"
  else
    rec fail "rollback: sigue llamando a cizen-uki-sync por nombre (misma mina que §33)"
  fi
fi

if [ -r "$UKISYNC" ]; then
  # e) cleanup_uki_variants tiene que llevarse también el staging de una run
  #    muerta (.cizen-prev / .cizen-tmp): son 47 MB por UKI en el ESP y solo
  #    sirven dentro de la run que los crea (uki_prev_drop los borra al final).
  mkdir -p "$ROOT/esp/boot/EFI/Linux" "$ROOT/esp/efi"
  for n in "arch-linux-cizen-v3.efi" "arch-linux-cizen-v3+3.efi" \
           "arch-linux-cizen-v3.efi.cizen-prev" "arch-linux-cizen-v3.efi.cizen-tmp" \
           "arch-linux-cizen-v3+3.efi.cizen-prev" "arch-linux-lts.efi"; do
    : > "$ROOT/esp/boot/EFI/Linux/$n"
  done
  sed -n '/^uki_efi_name() {/,/^}/p;/^cleanup_uki_variants() {/,/^}/p' "$UKISYNC" > "$ROOT/cleanup.sh"
  CIZEN_UKI_ROOT_PREFIX="$ROOT/esp" CIZEN_UKI_NAME="arch-linux-cizen-v3.efi" CIZEN_BOOT_TRIES=0 \
    bash -c 'set -u; SUDO=(); . "$0"; cleanup_uki_variants' "$ROOT/cleanup.sh" >/dev/null 2>&1
  if [ -f "$ROOT/esp/boot/EFI/Linux/arch-linux-cizen-v3.efi" ]; then
    rec ok "esp: cleanup_uki_variants conserva la UKI vigente"
  else
    rec fail "esp: cleanup_uki_variants borró la UKI vigente (se arrancaría sin UKI)"
  fi
  if [ -f "$ROOT/esp/boot/EFI/Linux/arch-linux-lts.efi" ]; then
    rec ok "esp: cleanup_uki_variants no toca la UKI de otro kernel"
  else
    rec fail "esp: cleanup_uki_variants borró una UKI que no es suya"
  fi
  leftovers=""
  for n in "arch-linux-cizen-v3+3.efi" "arch-linux-cizen-v3.efi.cizen-prev" \
           "arch-linux-cizen-v3.efi.cizen-tmp" "arch-linux-cizen-v3+3.efi.cizen-prev"; do
    [ -e "$ROOT/esp/boot/EFI/Linux/$n" ] && leftovers="$leftovers $n"
  done
  if [ -z "$leftovers" ]; then
    rec ok "esp: se lleva la variante +N y el staging (.cizen-prev/.cizen-tmp) de una run muerta"
  else
    rec fail "esp: cleanup_uki_variants deja basura en el ESP:$leftovers"
  fi

  # v27.31.43: los *.efi.bak de la ESP. En produccion eran dos, de dos kernels
  # distintos, y rompian 'sbctl verify' con panic (go-uefi: bytes.Buffer:
  # truncation out of range) ademas de que el hook de pacman firmaba cada copia.
  # El borrado es por patron GLOBAL a proposito: con el patron atado al kernel
  # actual, el .bak del lts se queda con su panic y su firma indefinidamente.
  # Y lo que NO se toca son los *.efi a secas, ni los de otros kernels: de ahi
  # se arranca.
  mkdir -p "$ROOT/esp/boot/EFI/Linux" "$ROOT/esp/efi"
  for n in "arch-linux-cizen-v3.efi" "arch-linux-cizen-v3+3.efi" "arch-linux-lts.efi" \
           "arch-linux-cizen-v3.efi.bak" "arch-linux-cizen-v3+3.efi.bak" \
           "arch-linux-lts.efi.bak" "grubx64.efi" "BOOTX64.EFI"; do
    : > "$ROOT/esp/boot/EFI/Linux/$n"
  done
  sed -n '/^cleanup_efi_bak_copies() {/,/^}/p' "$UKISYNC" > "$ROOT/bak.sh"
  _bak_n=0
  if [ -s "$ROOT/bak.sh" ]; then
    CIZEN_UKI_ROOT_PREFIX="$ROOT/esp" CIZEN_UKI_NAME="arch-linux-cizen-v3.efi" CIZEN_BOOT_TRIES=0 \
      bash -c 'set -u; SUDO=(); log(){ :; }; . "$0"; cleanup_efi_bak_copies' "$ROOT/bak.sh" >/dev/null 2>&1
    _bak_n="$(find "$ROOT/esp" -type f -name '*.efi.bak' | wc -l)"
  fi
  # OJO: que la funcion NO exista tiene que ser un fallo explicito. Si el
  # sed no la encuentra, el bloque no corre, no queda ningun .bak... y el
  # `find` cuenta 0 igual que cuando barre bien: el test pasaba en vacio y no
  # media nada. Un test que no puede fallar no es un test.
  if [ ! -s "$ROOT/bak.sh" ]; then
    rec fail "esp: cizen-uki-sync no tiene cleanup_efi_bak_copies (los .efi.bak se acumulan en el ESP)"
  elif [ "$_bak_n" = 0 ] \
     && [ -f "$ROOT/esp/boot/EFI/Linux/arch-linux-cizen-v3.efi" ] \
     && [ -f "$ROOT/esp/boot/EFI/Linux/arch-linux-cizen-v3+3.efi" ] \
     && [ -f "$ROOT/esp/boot/EFI/Linux/arch-linux-lts.efi" ] \
     && [ -f "$ROOT/esp/boot/EFI/Linux/grubx64.efi" ] \
     && [ -f "$ROOT/esp/boot/EFI/Linux/BOOTX64.EFI" ]; then
    rec ok "esp: se lleva los *.efi.bak de CUALQUIER kernel y deja los .efi que se arrancan"
  else
    rec fail "esp: cleanup_efi_bak_copies deja .efi.bak ($_bak_n) o se ha comido un .efi de verdad"
  fi

  # La copia del motor tiene que hacer lo mismo: si divergen, la UKI escrita por
  # un camino deja basura que el otro no limpia. Antes solo barria los +N.
  if sed -n '/^cizen_uki_cleanup_efi_bak() {/,/^}/p' "$MOTOR" | grep -q "name '\*.efi.bak'" \
     && sed -n '/^cizen_uki_cleanup_variants() {/,/^}/p' "$MOTOR" | grep -q 'cizen-prev' \
     && sed -n '/^cizen_uki_cleanup_variants() {/,/^}/p' "$MOTOR" | grep -q 'cizen-tmp' \
     && grep -q 'cizen_uki_cleanup_efi_bak' "$MOTOR"; then
    rec ok "motor: su copia del desbarate barre tambien .efi.bak y el staging"
  else
    rec fail "motor: cizen_uki_cleanup_variants/cizen_uki_cleanup_efi_bak divergen de cizen-uki-sync"
  fi
fi

# --- v27.31.44: regresiones de la auditoría exhaustiva del flujo ---
PODAR_="$(dirname "$MOTOR")/podar-modulos.sh"
VERIFYSRC_="$(dirname "$MOTOR")/kernel-update-verify.sh"
NOTIFY_="$(dirname "$MOTOR")/kernel-update-notify.sh"
MANAGER_="$(dirname "$MOTOR")/kernel-update-manager.sh"

if [ -f "$PODAR_" ] && [ -f "$VERIFYSRC_" ] && [ -f "$NOTIFY_" ] && [ -f "$MANAGER_" ]; then
# Parser del motor: cada opción del case tiene que consumir su argumento. Sin
# el 'shift', '--save-auto-renames' giraba el bucle al 100% de CPU para
# siempre (timeout 3 bash kernel-update.sh --save-auto-renames -> exit 124).
if grep -qE -- '--save-auto-renames\)' "$MOTOR" \
   && awk '/--save-auto-renames\)/{found=1} found{print} /--rename=\*/{exit}' "$MOTOR" | grep -q 'shift'; then
  rec ok "motor: --save-auto-renames consume su argumento (shift) y no puede girar al vacío"
else
  rec fail "motor: --save-auto-renames no hace shift: el parser gira al 100% de CPU"
fi

# call-before-definition: en bash con set -e, llamar una función antes de
# definirla es "command not found" (127) y aborta. Pasó con
# check_installed_release_generic en los backends no-arch.
_def_l="$(grep -n '^check_installed_release_generic()' "$MOTOR" | cut -d: -f1 | head -n1)"
_use_l="$(grep -n '^[[:space:]]*check_installed_release_generic$' "$MOTOR" | cut -d: -f1 | head -n1)"
if [ -n "$_def_l" ] && [ -n "$_use_l" ] && [ "$_def_l" -lt "$_use_l" ]; then
  rec ok "motor: check_installed_release_generic se define antes de usarse (backends no-arch)"
else
  rec fail "motor: check_installed_release_generic se llama antes de definirse (def=$_def_l use=$_use_l)"
fi
unset _def_l _use_l

# El motor delega en cizen-uki-sync, pero si este falla tiene que intentar su
# camino directo (ensure_cizen_efi_updated), no abortar antes.
if grep -qE '^[[:space:]]*if[[:space:]]+!.+UKI_SYNC_BIN' "$MOTOR" \
   && sed -n '/^ensure_cizen_efi_updated() {/,/^}/p' "$MOTOR" | grep -q 'sync_cizen_efi'; then
  rec ok "motor: un fallo de cizen-uki-sync deriva al camino directo en lugar de abortar"
else
  rec fail "motor: el fallo del sync externo aborta con 'set -e' sin probar el camino directo"
fi

# menú: `read` con stdin cerrado (cron/notify) entraba en bucle infinito.
if grep -qE 'read[[:space:]]+-r[[:space:]]+-p[[:space:]]+"[^"]*"[[:space:]]+choice[[:space:]]*\|\|[[:space:]]*break' "$MENU"; then
  rec ok "menú: read EOF sale del bucle (choice || break) en vez de girar para siempre"
else
  rec fail "menú: read sin '|| break': stdin cerrado -> bucle infinito"
fi

# podar-modulos: modules.dep separa dependencias con espacios; con IFS='\n\t'
# global el cierre transitivo no añadía nada (dependencias muertas).
if [ "$(grep -c "IFS=' ' read -r -a _deparr" "$PODAR_")" -ge 2 ]; then
  rec ok "podar: el cierre transitivo parte las dependencias por espacios (2 bucles)"
else
  rec fail "podar: dependencias de modules.dep no se parten (IFS='\n\t'): cierre transitivo muerto"
fi

# verify: el conteo por módulos debe aceptar la misma extensión de firmware que
# el del journal (.zst/.xz/.gz); antes marcaba como ausente un binario .xz/.gz.
if sed -n '/^firmware_missing_for_module() {/,/^}/p' "$VERIFYSRC_" | grep -qE '\.xz|\.gz'; then
  rec ok "verify: firmware por módulos acepta .xz/.gz igual que el journal"
else
  rec fail "verify: firmware por módulos solo ve .zst -> falsa alarma permanente"
fi

# notify: no marcar como entregada una notificación que no se envió.
# El patrón no fija el nombre de la variable local de la versión (fue 'local',
# que chocaba con el builtin, y ahora es 'local_ver'): lo que se comprueba es
# que la llamada se guarda su rc y solo entonces se escribe LAST_FILE.
if sed -n '/^notify_update() {/,/^}/p' "$NOTIFY_" | grep -q 'return "$rc"' \
   && sed -n '/notify_update "\$/,/^[[:space:]]*return 0/p' "$NOTIFY_" | grep -q 'if \[ "\$ok" = 0 \]'; then
  rec ok "notify: solo se registra como notificada si notify-send entregó (rc=0)"
else
  rec fail "notify: se registra como notificada aunque notify-send fallara"
fi

# notify: la versión local NO se puede llamar 'local' dentro de una función:
# 'local remote local last_notified=""' deja una variable llamada 'local' (que
# bash acepta, pero shellcheck marca como SC2316 error y confunde al que lea).
if sed -n '/^main() {/,/^}/p' "$NOTIFY_" | grep -qE '^[[:space:]]*local [a-z_]*\blocal\b'; then
  rec fail "notify: main() declara una variable llamada 'local' (SC2316)"
else
  rec ok "notify: main() no usa 'local' como nombre de variable"
fi

# rollback: si el archive del manifiesto no está, usar el *.tar.xz más reciente.
if grep -q 'resolve_archive()' "$KROLLBACK" \
   && sed -n '/^list_archives() {/,/^}/p' "$KROLLBACK" | grep -q 'resolve_archive' \
   && sed -n '/^restore_from_archive() {/,/^}/p' "$KROLLBACK" | grep -q 'resolve_archive'; then
  rec ok "rollback: resolve_archive cae al *.tar.xz más reciente si el del manifiesto falta"
else
  rec fail "rollback: manifiesto obsoleto = archive ignorado pese a existir"
fi

# v27.31.45: el default del motor es Thin-LTO (clang). Si vuelve a 0, 'auto'
# resuelve a gcc y la build pierde LTO en silencio.
if grep -q 'CIZEN_LLVM_LTO="\${CIZEN_LLVM_LTO:-thin}"' "$MOTOR" \
   && grep -q -- '--no-lto' "$MOTOR"; then
  rec ok "LTO: default thin en el motor con escape --no-lto (no se vuelve a gcc en silencio)"
else
  rec fail "LTO: el default del motor no es thin o falta --no-lto (revisar CIZEN_LLVM_LTO)"
fi

# v27.31.46: el overlay de LTO no puede pasar la opción ELEGIDA por disable. El
# disable se aplica después del enable, así que el mismo símbolo en ambos arrays
# salía con CONFIG_LTO_CLANG_THIN=n y la build moría en validación ("[ENABLE]
# CONFIG_LTO_CLANG_THIN quedó n") con el perfil y la toolchain correctos.
# Se evalúa el bloque REAL del motor (no una copia) con stubs mínimos.
_lto_case="$(sed -n '/^inject_build_overlay() {/,/^}/p' "$MOTOR" \
            | sed -n '/case "$CIZEN_LLVM_LTO" in/,/^  esac/p')"
_lto_bad=""
if [ -z "$_lto_case" ]; then
  rec fail "LTO: no se encuentra el bloque 'case CIZEN_LLVM_LTO' en inject_build_overlay"
else
  for _v in thin full 0; do
    _lto_out="$(MOTOR="$MOTOR" LCASE="$_lto_case" CIZEN_LLVM_LTO="$_v" bash -c '
      eval "$(sed -n "/^eff_remove() {/,/^}/p"  "$MOTOR")"
      eval "$(sed -n "/^add_unique() {/,/^}/p"  "$MOTOR")"
      info() { :; }
      declare -a EFF_ENABLE=() EFF_DISABLE=()
      declare -A SEEN_ENABLE=() SEEN_DISABLE=()
      declare -A EXPECTED_REBEL_SET=() PATCH_KCONFIG_FILTER=()
      eval "$LCASE"
      printf "%s|%s" "${EFF_ENABLE[*]}" "${EFF_DISABLE[*]}"
    ' 2>/dev/null)"
    _lto_e="${_lto_out%%|*}"; _lto_d="${_lto_out##*|}"
    # 1) ningún símbolo puede estar en las dos listas a la vez
    for _s in $_lto_e; do
      case " $_lto_d " in *" $_s "*) _lto_bad="$_v:en Ambas listas($_s)" ;; esac
    done
    # 2) la elegida tiene que quedar habilitada, y solo ella
    case "$_v" in
      thin) [ "$_lto_e" = "LTO_CLANG_THIN" ] || _lto_bad="$_v:enable='$_lto_e'" ;;
      full) [ "$_lto_e" = "LTO_CLANG_FULL" ] || _lto_bad="$_v:enable='$_lto_e'" ;;
      0)    [ "$_lto_e" = "LTO_NONE" ]       || _lto_bad="$_v:enable='$_lto_e'" ;;
    esac
    # 3) las alternativas tienen que quedar desactivadas (una por una: un unico
    # glob con dos literales exigiria dos espacios entre medias y nunca cuela)
    case "$_v" in
      thin) _lto_want_d="LTO_CLANG_FULL LTO_NONE" ;;
      full) _lto_want_d="LTO_CLANG_THIN LTO_NONE" ;;
      0)    _lto_want_d="LTO_CLANG_THIN LTO_CLANG_FULL" ;;
    esac
    for _s in $_lto_want_d; do
      case " $_lto_d " in *" $_s "*) ;; *) _lto_bad="$_v:falta disable $_s ('$_lto_d')" ;; esac
    done
  done
  if [ -z "$_lto_bad" ]; then
    rec ok "LTO: el overlay habilita la opción elegida y NO la vuelve a deshabilitar (thin/full/0)"
  else
    rec fail "LTO: el overlay de LTO se contradice ($_lto_bad) -> '[ENABLE] CONFIG_LTO_CLANG_THIN quedó n'"
  fi
fi

# v27.31.46: add_unique mantiene EFF_ENABLE y EFF_DISABLE disjuntas (última
# intención gana). Antes un enable+disable del mismo símbolo convivían y el
# disable pisaba al enable sin dejar rastro.
_au_bad="$(bash -c '
  eval "$(sed -n "/^eff_remove() {/,/^}/p" "$0")"
  eval "$(sed -n "/^add_unique() {/,/^}/p"   "$0")"
  declare -a EFF_ENABLE=() EFF_DISABLE=()
  declare -A SEEN_ENABLE=() SEEN_DISABLE=()
  add_unique enable FOO; add_unique disable BAR
  add_unique disable FOO; add_unique enable BAZ
  printf "%s|%s" "${EFF_ENABLE[*]}" "${EFF_DISABLE[*]}"
' "$MOTOR" 2>/dev/null)"
if [ "$_au_bad" = "BAZ|BAR FOO" ]; then
  rec ok "add_unique: un símbolo no queda a la vez en ENABLE y DISABLE (gana la última intención)"
else
  rec fail "add_unique: EFF_ENABLE/EFF_DISABLE se solapan ($_au_bad)"
fi

# v27.31.48: ORDEN DE DEFINICIÓN. El motor se ejecuta línea a línea mientras bash
# lo lee, así que una llamada a nivel superior solo ve lo que ya ha leído.
# build_effective_arrays() se invoca en el nivel superior y su cierre transitivo
# usaba eff_remove() y apply_config_requests(), definidos miles de líneas más
# abajo. Con un símbolo a la vez en OPTION_ENABLE y en OPTION_DISABLE (el motor
# activaba DEBUG_INFO_BTF y el perfil lo desactivaba) add_unique() reventaba con
# "line 1538: eff_remove: orden no encontrada" y el preflight abortaba con
# Error 127 sin llegar a compilar.
# Los tests de arriba NO lo detectaban: evalúan a mano eff_remove y add_unique en
# el orden correcto, así que el fallo solo se manifiesta en la ejecución real.
# Aquí se comprueba el orden real del fichero.
_ord_bad=""
_ord_call="$(grep -n '^build_effective_arrays$' "$MOTOR" | head -1 | cut -d: -f1)"
if [ -z "$_ord_call" ]; then
  rec fail "orden: no aparece la invocación de nivel superior de build_effective_arrays"
else
  for _f in build_kconfig_symbol_index kconfig_symbol_known kconfig_auto_candidate \
           auto_resolve_effective_symbols eff_remove apply_config_requests; do
    _ord_def="$(grep -n "^${_f}() {" "$MOTOR" | head -1 | cut -d: -f1)"
    if [ -z "$_ord_def" ]; then
      _ord_bad="$_ord_bad ${_f}(sin definicion);"
    elif [ "$_ord_def" -ge "$_ord_call" ]; then
      _ord_bad="$_ord_bad ${_f}(L${_ord_def}>=L${_ord_call});"
    fi
  done
  if [ -z "$_ord_bad" ]; then
    rec ok "orden: el cierre transitivo de build_effective_arrays() esta definido antes de su llamada (L${_ord_call})"
  else
    rec fail "orden: build_effective_arrays() usa funciones definidas despues de la llamada ($_ord_bad) -> 'orden no encontrada'"
  fi
fi

# Barrido en cizen-uki-sync: el fallback objcopy tiene que embeber
# .initrd (antes producía una UKI sin initrd que la verificación descartaba).
if sed -n '/^build_uki() {/,/^}/p' "$UKISYNC" | grep -q -- '--add-section .initrd="\$initrd"'; then
  rec ok "sync: el fallback objcopy embeble .initrd (ya no sale una UKI sin initrd)"
else
  rec fail "sync: el fallback objcopy no embeble .initrd -> cizen_uki_verify_image fatal"
fi

# v27.31.51: el motor tiene el mismo problema, y el test de arriba solo miraba la
# copia de cizen-uki-sync. En build_cizen_uki() el initramfs se preparaba DENTRO
# de la rama `if [ -n "$ukify_bin" ]`, así que sin ukify el fallback de objcopy
# se encontraba con have_initrd=0 sin haberlo preparado: UKI sin initrd en el
# equipo que precisamente no tiene ukify.
_uki_body="$(sed -n '/^build_cizen_uki() {/,/^}/p' "$MOTOR")"
_ord_prep="$(printf '%s\n' "$_uki_body" | grep -n 'cizen_initramfs_prepare' | head -1 | cut -d: -f1)"
_ord_ukify="$(printf '%s\n' "$_uki_body" | grep -n 'if \[ -n "\$ukify_bin" \]' | head -1 | cut -d: -f1)"
_ord_objcopy="$(printf '%s\n' "$_uki_body" | grep -n 'if \[ -n "\$stub" \] && command -v objcopy' | head -1 | cut -d: -f1)"
_ord_calls="$(printf '%s\n' "$_uki_body" | grep -c 'cizen_initramfs_prepare')"
if [ -n "$_ord_prep" ] && [ -n "$_ord_ukify" ] && [ -n "$_ord_objcopy" ] \
   && [ "$_ord_prep" -lt "$_ord_ukify" ] && [ "$_ord_prep" -lt "$_ord_objcopy" ] \
   && [ "$_ord_calls" -eq 1 ]; then
  rec ok "motor: build_cizen_uki prepara el initramfs ANTES de elegir constructor (prepare L${_ord_prep} < ukify L${_ord_ukify} < objcopy L${_ord_objcopy})"
else
  rec fail "motor: el initramfs se prepara tarde o de más (prepare=${_ord_prep:-none} calls=$_ord_calls ukify=${_ord_ukify:-none} objcopy=${_ord_objcopy:-none}) -> fallback UKI sin initrd"
fi
if printf '%s\n' "$_uki_body" | grep -q -- '--add-section .initrd="\$initrd"'; then
  rec ok "motor: el fallback objcopy embeble .initrd"
else
  rec fail "motor: el fallback objcopy no embeble .initrd"
fi
unset _uki_body _ord_prep _ord_ukify _ord_objcopy _ord_calls

# manager: flip/backup solo consideran UKIs Cizen con patrón '.*suffix*.efi', no
# el primer *.efi cualquiera (podía fijar oneshot al LTS).
if grep -q 'cizen_ukis()' "$MANAGER_" \
   && grep -q 'find_esp_root' "$MANAGER_"; then
  rec ok "manager: flip/backup filtran UKIs por sufijo Cizen y derivan el ESP como la suite"
else
  rec fail "manager: flip/backup usan el primer *.efi y /boot/EFI fijo (puede oneshot al LTS)"
fi
else
  printf '  (sin scripts auxiliares en el árbol: se omiten las regresiones de v27.31.44)\n'
fi
unset PODAR_ VERIFYSRC_ NOTIFY_ MANAGER_

# --- v27.31.45: rendimiento (perfil v5.13.0, Thin-LTO default, PGO plumbing) ---
PROFILE_="$(dirname "$MOTOR")/profiles/cizen-optiplex7050.conf"
PGO_="$(dirname "$MOTOR")/pgo-collect.sh"
if [ -f "$PROFILE_" ] && [ -f "$PGO_" ]; then
  if bash -n "$PROFILE_" && bash -n "$PGO_" && bash -n "$MOTOR"; then
    rec ok "sintaxis OK (motor, perfil Cizen y pgo-collect.sh)"
  else
    rec fail "v27.31.45: error de sintaxis (motor/perfil/pgo-collect.sh)"
  fi
  # v5.16.0: el usuario elige BORE y renuncia a sched_ext. BORE sustituye a
  # SCHED_CORE, que es donde sched_ext se engancha, así que SCHED_CLASS_EXT pasa
  # de OPTS_ENABLE a OPTS_DISABLE (y con él, por dependencia, DEBUG_INFO_BTF).
  # El awk ignora comentarios: el perfil explica por qué NO lista BTF y cita
  # "DEBUG_INFO_BTF" entrecomillado, que antes contaba como si fuera una entrada.
  _prof_sym() { # $1=fichero $2=bloque(ENABLE|DISABLE) $3=símbolo
    awk -v blk="declare -a OPTS_$2=(" -v want="\"$3\"" 'BEGIN{b=0;n=0}
      /^[[:space:]]*#/ {next}
      index($0,blk)==1 {b=1;next}
      /^\)$/ {b=0}
      b && index($0,want) {n++}
      END{print n+0}' "$1"
  }
  ES_="$(_prof_sym "$PROFILE_" ENABLE  SCHED_CLASS_EXT)"
  DS_="$(_prof_sym "$PROFILE_" DISABLE SCHED_CLASS_EXT)"
  DK_="$(_prof_sym "$PROFILE_" DISABLE KALLSYMS_ALL)"
  DM_="$(_prof_sym "$PROFILE_" DISABLE SLAB_MERGE_DEFAULT)"
  if [ "$ES_" -eq 0 ] && [ "$DS_" -eq 1 ] && [ "$DK_" -eq 1 ] && [ "$DM_" -eq 1 ]; then
    rec ok "perfil v5.16.0: sched_ext en DISABLE (BORE) y KALLSYMS_ALL/SLAB_MERGE_DEFAULT en DISABLE"
  else
    rec fail "perfil v5.16.0: bloques sched_ext/KALLSYMS/SLAB_MERGE incorrectos (EN_scx=$ES_ DIS_scx=$DS_ KA=$DK_ SM=$DM_)"
  fi
  if grep -q 'CIZEN_PGO_PROFILE' "$MOTOR" \
     && grep -q 'CLANG_AUTOFDO_PROFILE=$CIZEN_PGO_PROFILE' "$MOTOR" \
     && grep -q 'AUTOFDO_CLANG' "$MOTOR" \
     && grep -q 'llvm-profgen' "$PGO_"; then
    rec ok "PGO: plumbing CIZEN_PGO_PROFILE→CLANG_AUTOFDO_PROFILE + AUTOFDO_CLANG + helper llvm-profgen"
  else
    rec fail "PGO: falta plumbing CIZEN_PGO_PROFILE / CLANG_AUTOFDO_PROFILE / AUTOFDO_CLANG / llvm-profgen"
  fi
else
  printf '  (sin perfiles/pgo-collect.sh en el árbol: se omiten las regresiones de v27.31.45)\n'
fi
unset PROFILE_ PGO_ ES_ DS_ DK_ DM_

# --- v27.31.51 / perfil v5.16.1: poda de subsistemas verificada con Kconfig ---
# El .config generado se comprobó aplicando el perfil entero con scripts/config
# y normalizando con `make olddefconfig` sobre linux-7.2.8: ENABLE 35/35,
# CRITICAL 13/13, DISABLE 303/303, 0 DISABLE_WARN, y -112 símbolos y/m.
# Estas regresiones son la red de seguridad de esa verificación.
# Ojo: PROFILE_ se ha borrado justo arriba con el unset del bloque v27.31.45,
# así que esta sección vuelve a derivar la ruta con su propia variable.
PROFV_="$(dirname "$MOTOR")/profiles/cizen-optiplex7050.conf"
if [ -f "$PROFV_" ]; then
  # Los símbolos se listan por RAÍZ: Kconfig cascada a los hijos y listarlos uno
  # a uno los convierte en "RETIRED / símbolo inexistente" al validarlos.
  for _root in XEN INTEL_TDX_HOST FTRACE NUMA_BALANCING ZSWAP_DEFAULT_ON \
              TRACE_GPU_MEM PM_DEBUG; do
    _n="$(_prof_sym "$PROFV_" DISABLE "$_root")"
    if [ "$_n" -eq 1 ]; then
      rec ok "perfil v5.16.1: raíz $_root en OPTS_DISABLE (cascada verificada con olddefconfig)"
    else
      rec fail "perfil v5.16.1: raíz $_root no está exactamente una vez en DISABLE (n=$_n)"
    fi
  done
  unset _root _n

  # XEN_PVH/KVM_INTEL_TDX cuelgan de sus raíces: listarlos sería ruido RETIRED.
  for _child in XEN_PVH XEN_HYPERVISOR X86_XEN_HYPERVISOR KVM_INTEL_TDX \
                FUNCTION_TRACER EVENT_TRACING PM_TRACE PM_SLEEP_DEBUG; do
    _n="$(_prof_sym "$PROFV_" DISABLE "$_child")"
    if [ "$_n" -eq 0 ]; then
      rec ok "perfil v5.16.1: $_child NO se lista (lo apaga su raíz, sin ruido RETIRED)"
    else
      rec fail "perfil v5.16.1: $_child se lista en DISABLE además de su raíz (n=$_n)"
    fi
  done
  unset _child _n

  # v5.16.1: símbolos que NO existen en linux-7.2.8 (0 coincidencias en el árbol
  # Kconfig*). Pedirlos solo generaba "CONFIG_x ya no existe en esta versión".
  for _dead in PERF_GUEST_EVENTS MQ_IOSCHED_ADIOS; do
    _n="$(_prof_sym "$PROFV_" DISABLE "$_dead")"
    if [ "$_n" -eq 0 ]; then
      rec ok "perfil v5.16.1: $_dead retirado (símbolo inexistente en 7.2.8)"
    else
      rec fail "perfil v5.16.1: $_dead sigue pedido aunque no exista en 7.2.8 (n=$_n)"
    fi
  done
  unset _dead _n

  # Secure Boot: MODULE_SIG_ALL salía =y solo por `default y`; se ancla.
  _n="$(_prof_sym "$PROFV_" ENABLE MODULE_SIG_ALL)"
  if [ "$_n" -eq 1 ]; then
    rec ok "perfil v5.16.1: MODULE_SIG_ALL anclado en ENABLE (no depende del default de Kconfig)"
  else
    rec fail "perfil v5.16.1: MODULE_SIG_ALL no está anclado en ENABLE (n=$_n)"
  fi
  unset _n

  # KVM_INTEL hace `select X86_FRED if X86_64` sin condiciones: es imposible
  # apagarlo con KVM, y sin declararlo saldría un DISABLE_WARN en cada build.
  if awk '/^[[:space:]]*#/ {next} /^declare -a EXPECTED_REBELS=\(/ {b=1;next} /^\)/ {b=0}
         b && index($0,"\"X86_FRED\"") {n++} END{print n+0}' "$PROFV_" | grep -qx 1; then
    rec ok "perfil v5.16.1: X86_FRED en EXPECTED_REBELS (lo selecciona KVM_INTEL)"
  else
    rec fail "perfil v5.16.1: X86_FRED no está en EXPECTED_REBELS (DISABLE_WARN eterno)"
  fi

  # Duplicados DENTRO de la misma array. add_unique() los absorbe sin avisar, así
  # que un "PM_DEBUG" repetido no rompe la build: solo indica que la lista se
  # está editando a ciegas. Salió uno de verdad al añadir el bloque v5.16.1.
  for _arr in ENABLE DISABLE; do
    _dups="$(awk -v blk="declare -a OPTS_$_arr=(" '/^[[:space:]]*#/ {next}
                   index($0,blk)==1 {b=1;next} /^\)/ {b=0}
                   b {for(i=1;i<=NF;i++){gsub(/"/,"",$i); if($i!="") print $i}}' "$PROFV_" \
                 | sort | uniq -d | tr '\n' ' ')"
    if [ -z "${_dups// /}" ]; then
      rec ok "perfil v5.16.1: sin símbolos repetidos dentro de OPTS_$_arr"
    else
      rec fail "perfil v5.16.1: símbolos repetidos en OPTS_$_arr: $_dups"
    fi
  done
  unset _arr _dups

  # Invariante general: ningún símbolo puede estar a la vez en ENABLE y DISABLE.
  # El motor aplicaría los dos scripts/config y ganaría el último, así que la
  # validación nunca lo detectaría: solo se ve leyendo el perfil.
  _enset=""
  _nen=0
  while read -r _s; do
    [ -z "$_s" ] && continue
    _nen=$((_nen+1)); _enset="$_enset|$_s|"
  done < <(awk '/^[[:space:]]*#/ {next}
                 /^declare -a OPTS_ENABLE=\(/ {b=1;next}
                 /^\)/ {b=0}
                 b {for(i=1;i<=NF;i++){gsub(/"/,"",$i); if($i!="") print $i}}' "$PROFV_")
  _dups=""
  while read -r _s; do
    [ -z "$_s" ] && continue
    case "$_enset" in *"|$_s|"*) _dups="$_dups $_s" ;; esac
  done < <(awk '/^[[:space:]]*#/ {next}
                 /^declare -a OPTS_DISABLE=\(/ {b=1;next}
                 /^\)/ {b=0}
                 b {for(i=1;i<=NF;i++){gsub(/"/,"",$i); if($i!="") print $i}}' "$PROFV_")
  if [ -z "${_dups// /}" ]; then
    rec ok "perfil v5.16.1: ningún símbolo en OPTS_ENABLE y OPTS_DISABLE a la vez ($_nen en ENABLE)"
  else
    rec fail "perfil v5.16.1: símbolos a la vez en ENABLE y DISABLE:$_dups"
  fi
  unset _enset _nen _dups _s
fi
unset PROFV_

# Los frag se|sourcean con el .config: un CONFIG_ que no exista en Kconfig lo
# descarta olddefconfig y genera un aviso de "símbolo no solicitado".
FRAGD_="$(dirname "$MOTOR")/profiles/frags"
if [ -d "$FRAGD_" ]; then
  _badfrags=0
  for _f in "$FRAGD_"/*.frag; do
    [ -f "$_f" ] || continue
    # Solo asignaciones: el frag documenta en un comentario POR QUÉ se retiró
    # CONFIG_EXTRA_FIRMWARE_FILE, y ese comentario no debe contar como uso.
    if grep -v '^[[:space:]]*#' "$_f" | grep -q 'CONFIG_EXTRA_FIRMWARE_FILE'; then
      _badfrags=$((_badfrags+1))
    fi
  done
  if [ "$_badfrags" -eq 0 ]; then
    rec ok "perfil v5.16.1: ningún frag usa CONFIG_EXTRA_FIRMWARE_FILE (no es símbolo de Kconfig)"
  else
    rec fail "perfil v5.16.1: $_badfrags frag(s) con CONFIG_EXTRA_FIRMWARE_FILE (símbolo inexistente)"
  fi
  unset _badfrags _f FRAGD_
fi

# --- v27.31.51: sudo sin TTY, y `set -u` con local sin valor ---
# Los tres fallos que aparecieron al ejecutar contra el sistema real, no contra
# un mock: los tres hacen que un script LIMPIO se caiga cuando el allowlist de
# sudoers cumple su parte y el ESP es root-only.
{
  # 1. `sudo test` / `sudo du` / `sudo ls` sin -n abren prompt SIEMPRE, aunque el
  #    comando esté en el allowlist: el prompt ocurre antes de mirar la lista.
  #    Sin eso `rollback --list` no corre en cron, en un agente o sin terminal.
  #    Se comparan solo líneas de código: los comentarios DESCRIBEN el
  #    `sudo -n test` que había antes, y si no se filtran el test pasa/falla
  #    por su propia explicación.
  _RB="$(dirname "$MOTOR")/kernel-update-rollback.sh"
  if [ -f "$_RB" ] \
     && ! grep -vE '^[[:space:]]*#' "$_RB" \
          | grep -qE '^[[:space:]]*sudo[[:space:]]+(-n[[:space:]]+)?(test|ls|du|cat)[[:space:]]' \
     && grep -qE '^[[:space:]]*_priv\(\)' "$_RB"; then
    rec ok "rollback: las lecturas van por _priv (nada de 'sudo cmd' que pida TTY)"
  else
    rec fail "rollback: sigue usando 'sudo <cmd>' sin -n (pide contraseña para --list)"
  fi

  # 2. `sudo -n test` con `test` como builtin de bash: sudo no puede ejecutarlo
  #    (no está en el PATH de secure_path) y falla con 127 aunque /usr/bin/test
  #    sea ejecutable. Se usa la ruta absoluta.
  _MB="$(dirname "$MOTOR")/kernel-update-manager.sh"
  if [ -f "$_MB" ] \
     && ! grep -vE '^[[:space:]]*#' "$_MB" \
          | grep -qE 'sudo[[:space:]]+(-n[[:space:]]+)?test[[:space:]]'; then
    rec ok "manager: no invoca 'sudo test' (builtin, no ejecutable por sudo)"
  else
    rec fail "manager: usa 'sudo test'; sudo no puede correr un builtin de bash"
  fi

  # 3. objdump/dd por sudo -n: sin ruta absoluta el allowlist NOPASSWD no casa
  #    con el nombre desnudo y el parseo de .uname se cae en silencio.
  if [ -f "$_MB" ] && grep -q '/usr/bin/objdump' "$_MB" && grep -q '/usr/bin/dd' "$_MB"; then
    rec ok "manager: objdump y dd con ruta absoluta (casan con el allowlist)"
  else
    rec fail "manager: objdump/dd sin ruta absoluta; el allowlist NOPASSWD no casa"
  fi

  # 4. `set -u` + `local x` sin asignar = 'unbound variable'. list_archives
  #    declaraba pkgpath y solo lo asignaba si el manifiesto traía pkgfile, así
  #    que un manifiesto sin ese campo abortaba el `list` entero.
  if [ -f "$_RB" ] && grep -qE 'local[^;]*pkgpath=""' "$_RB"; then
    rec ok "rollback: pkgpath se inicializa (manifiesto sin pkgfile no aborta con set -u)"
  else
    rec fail "rollback: pkgpath sin inicializar; 'set -u' aborta si el manifiesto no trae pkgfile"
  fi

  # 5. sort -V y no sort: los archives se nombran por release, y con byte-sort
  #    '7.2.10-cizen-v3' es MENOR que '7.2.9'. tail -n1 devolvía un kernel más
  #    viejo que el que se iba a retirar.
  if [ -f "$_RB" ] && grep -qE 'ls -1 "\$ROLLBACK_DIR"/\*\.tar\.xz.*\| *sort -V' "$_RB"; then
    rec ok "rollback: los archives se ordenan con sort -V (7.2.10 > 7.2.9)"
  else
    rec fail "rollback: sin sort -V; el plan B puede restaurar un kernel más viejo"
  fi

  # 6. cizen-uki-sync hace `*) break` en el parseo de argumentos: un argumento
  #    desconocido se ignoraba y la REGENERACIÓN se ligaba igual. Escribiendo
  #    encima del fichero del que arranca el equipo: `cizen-uki-sync --help`
  #    regeneraba la UKI de verdad.
  _UK="$(dirname "$MOTOR")/cizen-uki-sync"
  if [ -f "$_UK" ] \
     && ! grep -qE '^[[:space:]]*\*\) break ;;' "$_UK" \
     && grep -q -- '-h|--help' "$_UK"; then
    rec ok "uki-sync: argumento desconocido es error, no cae en la regeneración"
  else
    rec fail "uki-sync: '*) break' hace que --help regenere y sobrescriba la UKI"
  fi

  # 7. La red que salva al equipo de una firma fallida (uki_prev_restore) se
  #    apoyaba en `sudo test`, que es un builtin: sudo no lo encuentra en
  #    secure_path, devolvía 127, el script creía que no había copia .cizen-prev
  #    y se iba sin restaurar. UKI sin firmar + Secure Boot = no arranca.
  if [ -f "$_UK" ] \
     && ! grep -vE '^[[:space:]]*#' "$_UK" \
          | grep -qE '\$\{SUDO\[@\]\}[[:space:]]+test[[:space:]]' \
     && grep -qF '"${SUDO[@]}" /usr/bin/test -f "$t.cizen-prev"' "$_UK"; then
    rec ok "uki-sync: la restauración de la UKI previa usa /usr/bin/test (no builtin)"
  else
    rec fail "uki-sync: uki_prev_restore usa 'sudo test'; la red anti-firma-fallida no dispara"
  fi

  # 8. Una UKI sin .initrd no debe poder sustituir a una que sí lo tiene: el
  #    aviso de 'arranque degradado' salía, y la escritura continuaba igual.
  if [ -f "$_UK" ] \
     && grep -q 'CIZEN_UKI_ALLOW_DEGRADED_INITRD' "$_UK" \
     && grep -q 'uki_image_has_initrd' "$_UK"; then
    rec ok "uki-sync: no deja que una UKI sin .initrd pise a una que sí lo tiene"
  else
    rec fail "uki-sync: sin guard de initrd, un mkinitcpio fallido degrada el arranque"
  fi
  unset _RB _MB _UK
}
# --- v27.31.52: PGO puede cerrar su ciclo (vmlinux persistente) ---
# El árbol de compilación está en un tmpfs que se desmonta al final del pipeline,
# así que el vmlinux (imprescindible para llvm-profgen) se perdía siempre y
# pgo-collect.sh solo podía abortar. Estas regresiones comprueban que el motor lo
# archive en disco y que el colector lo encuentre ahí sin --vmlinux a mano.
_VMLINUX_STORE_DEF='/var/cache/cizen-kernel/vmlinux'
# El bloque de v27.31.45 hizo unset de PGO_ al terminar: se re-deriva aquí.
PGO_="$(dirname "$MOTOR")/pgo-collect.sh"
if grep -q 'archive_vmlinux' "$MOTOR" \
   && grep -q 'VMLINUX_STORE="\${CIZEN_VMLINUX_STORE:-/var/cache/cizen-kernel/vmlinux}"' "$MOTOR" \
   && grep -q 'prune_vmlinux_store' "$MOTOR"; then
  rec ok "PGO: el motor archiva el vmlinux en un store persistente y lo poda"
else
  rec fail "PGO: falta archive_vmlinux/prune_vmlinux_store o el store por defecto en el motor"
fi
# La llamada tiene que ocurrir en el cuerpo del pipeline (no dentro de una función
# sin invocar) y ANTES de la sincronización de UKI, que es donde ya se da por bueno
# el build. Si se llamara solo al definir la función, el store quedaría vacío.
if awk '/^archive_vmlinux$/{f=1} f&&/^log "Sincronizando UKI\.\.\."$/{u=1} END{exit !(f&&u)}' "$MOTOR"; then
  rec ok "PGO: archive_vmlinux se invoca en el pipeline antes de sincronizar la UKI"
else
  rec fail "PGO: archive_vmlinux no se invoca antes de la sincronización de UKI"
fi
# El colector debe probar el store como fallback y explicar el flujo cuando no lo
# encuentra, en vez de un mensaje seco que no menciona ni el tmpfs ni el rebuild.
if grep -q 'VMLINUX_STORE="\${CIZEN_VMLINUX_STORE:-/var/cache/cizen-kernel/vmlinux}"' "$PGO_"; then
  rec ok "PGO: pgo-collect.sh busca el vmlinux en el store persistente"
else
  rec fail "PGO: pgo-collect.sh no conoce el store de vmlinux"
fi
if grep -q 'tmpfs' "$PGO_" && grep -q 'kernel-update.sh build' "$PGO_"; then
  rec ok "PGO: el fallo por vmlinux ausente explica el tmpfs y el rebuild que lo arregla"
else
  rec fail "PGO: el mensaje de vmlinux ausente no explica la causa (tmpfs) ni el remedy"
fi
unset _VMLINUX_STORE_DEF

# --- contrato wrapper/_into (v27.31.52) ---
# resolve_symbol, config_symbol_state, kconfig_symbol_type y tree_identity son
# ENVOLTES: imprimen por stdout y toman UN argumento. Sus gemelas _into toman
# DOS y asignan con `printf -v`, sin subshell. La v27.31.52 convirtió los call
# sites de los perfiles a las variantes _into (para no abrir miles de forks) y
# en uno se coló la forma WRONG: `resolve_symbol "$sym" resolved` en
# verify_build_tree. El segundo argumento se ignora, nada se asigna a `resolved`
# y el valor sale por stdout, así que la línea siguiente leía una variable sin
# asignar: "resolved: unbound variable" YA EN LA VALIDACIÓN de una build real,
# con el árbol extraído y el tmpfs montado. El self-test no lo veía porque
# verify_build_tree no está en la lista de funciones extraídas.
#
# Este chequeo es estático a propósito: es barato y cubre toda la suite, no solo
# las funciones que el arnés extrae. Un wrapper con dos argumentos es siempre un
# error, porque su segundo parámetro no existe.
printf '%s\n' "== contrato wrapper/_into: ningún envuelto con dos argumentos =="
for _w in resolve_symbol config_symbol_state kconfig_symbol_type tree_identity; do
  _mal="$(grep -nE "^[[:space:]]*${_w}[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+" "$MOTOR" \
          | grep -vE ":[0-9]+:[[:space:]]*#" || true)"
  if [ -z "$_mal" ]; then
    rec ok "$_w: sin llamadas de dos argumentos (imprime por stdout, un solo arg)"
  else
    rec fail "$_w: llamada(s) con dos argumentos, el segundo se ignora en silencio -> $(printf '%s' "$_mal" | tr '\n' ' ')"
  fi
  unset _mal
done
unset _w

# ═══════════════════════════════════════════════════════════════════════════
# v27.33.3 — auditoría del 2026-10-01 (siete defectos, siete redes)
# ═══════════════════════════════════════════════════════════════════════════

printf '%s\n' "== apply_patch_plugin: el estado de un parche no se filtra al siguiente =="
# `--sched pds --bore` (o CIZEN_PATCHES="pds,bore") deja PATCH_NAMES=(pds bore).
# patch_desc_bore NO declara PATCH_CHOICE_DISABLE, PATCH_RETIRED_SYMBOLS ni
# PATCH_EMBED_B64 —no los necesita: BORE no activa SCHED_ALT y no lleva parche
# embebido—, así que sin el unset de apply_patch_plugin los heredaba del primero.
# LoObservable es triple: BORE registraba un --disable SCHED_PDS que no pidió
# nadie, duplicaba en PATCH_RETIRED_ALL los cinco símbolos de BMQ, y sobre todo
# reutilizaba el parche BMQ embebido como fallback: si el parche BORE de red
# fallaba, se aplicaba el de otro scheduler y el build continuaba creyendo que
# llevaba BORE (BORE_ENABLED=true, PATCHES_APPLIED=+bore).
# OJO al排查: PATCH_RETIRED_ALL es un ACUMULADOR GLOBAL por diseño (si PDS quita
# SCHED_AUTOGROUP del árbol, el build combinado no debe exigírselo a nadie más),
# así que lo que se comprueba no es que quede igual, sino que bore NO lo crezca
# ni lo duplique.
(
  KERNEL_TREE=cachyos
  PATCHES_APPLIED=(); PATCH_ENABLE_ALL=(); PATCH_REBEL_ALL=(); PATCH_VALUE_SYMBOLS=()
  PATCH_CHOICE_DISABLE=(); PATCH_RETIRED_SYMBOLS=(); PATCH_EMBED_B64=""
  BORE_ENABLED=false
  # El arnés borra patch-bmq.patch tras sus propios tests (el stub de descarga lo
  # recrea cuando lo necesita), así que aquí hay que volver a crearlo para que
  # el pin SHA256 sea el del fichero que se sirve de verdad.
  printf 'config SCHED_BMQ\n--- a/init/Kconfig\n+++ b/init/Kconfig\n' > "$ROOT/patch-bmq.patch"
  # El pin SHA256 tiene que ser el del fichero que sirve el stub para CADA
  # parche: 0001-prjc*.patch entrega patch-bmq.patch y 0001-bore*.patch entrega
  # patch-cachy.patch. Con el pin equivocado el parche se rechaza por hash y el
  # arnés probaría el estado de un plugin que ni se aplicó.
  CIZEN_PATCH_SHA256_MAIN="$(sha256sum "$ROOT/patch-bmq.patch" | cut -d' ' -f1)"
  CIZEN_PATCH_SHA256_FALLBACK="$CIZEN_PATCH_SHA256_MAIN"
  export CIZEN_PATCH_SHA256_MAIN CIZEN_PATCH_SHA256_FALLBACK
  # bmq: magic "config SCHED_BMQ" == el que sirve el stub para 0001-prjc*.patch.
  apply_patch_plugin bmq >/dev/null 2>&1 || true
  rm -f -- "$ROOT/patch-bmq.patch"
  printf 'acc-ret-bmq=%s\n' "${#PATCH_RETIRED_ALL[@]}"
  printf 'acc-dup-bmq=%s\n' "$(printf '%s\n' "${PATCH_RETIRED_ALL[@]:-}" | sort | uniq -d | tr '\n' ' ')"
  printf 'desc-choice-bmq=%s\n' "${PATCH_CHOICE_DISABLE[*]:-<vacío>}"
  printf 'desc-ret-bmq=%s\n' "${PATCH_RETIRED_SYMBOLS[*]:-<vacío>}"
  printf 'desc-embed-bmq=%s\n' "${PATCH_EMBED_B64:-<vacío>}"
  CIZEN_PATCH_SHA256_MAIN="$(sha256sum "$ROOT/patch-cachy.patch" | cut -d' ' -f1)"
  CIZEN_PATCH_SHA256_FALLBACK="$(sha256sum "$ROOT/patch-upstream.patch" | cut -d' ' -f1)"
  export CIZEN_PATCH_SHA256_MAIN CIZEN_PATCH_SHA256_FALLBACK
  apply_patch_plugin bore >/dev/null 2>&1 || true
  printf 'acc-ret-bore=%s\n' "${#PATCH_RETIRED_ALL[@]}"
  printf 'acc-dup-bore=%s\n' "$(printf '%s\n' "${PATCH_RETIRED_ALL[@]:-}" | sort | uniq -d | tr '\n' ' ')"
  printf 'desc-choice-bore=%s\n' "${PATCH_CHOICE_DISABLE[*]:-<vacío>}"
  printf 'desc-ret-bore=%s\n' "${PATCH_RETIRED_SYMBOLS[*]:-<vacío>}"
  printf 'desc-embed-bore=%s\n' "${PATCH_EMBED_B64:-<vacío>}"
) > "$ROOT/leak.txt" 2>&1
_leak_get() { sed -n "s/^$1=//p" "$ROOT/leak.txt"; }
_lk_acc_bmq="$(_leak_get acc-ret-bmq)"
_lk_dup_bmq="$(_leak_get acc-dup-bmq)"
_lk_choice_bmq="$(_leak_get desc-choice-bmq)"
_lk_ret_bmq="$(_leak_get desc-ret-bmq)"
_lk_emb_bmq="$(_leak_get desc-embed-bmq)"
_lk_acc_bore="$(_leak_get acc-ret-bore)"
_lk_dup_bore="$(_leak_get acc-dup-bore)"
_lk_choice_bore="$(_leak_get desc-choice-bore)"
_lk_ret_bore="$(_leak_get desc-ret-bore)"
_lk_emb_bore="$(_leak_get desc-embed-bore)"
case "$_lk_ret_bmq" in
  *SCHED_AUTOGROUP*) rec ok "bmq sí retira símbolos (el arnés monta el caso real)" ;;
  *) rec fail "bmq no registró PATCH_RETIRED_SYMBOLS: [$_lk_ret_bmq]" ;;
esac
if [ "$_lk_choice_bmq" = "SCHED_PDS" ] && [ -n "$_lk_emb_bmq" ]; then
  rec ok "bmq deja CHOICE=SCHED_PDS y parche embebido (el estado que antes se heredaba)"
else
  rec fail "bmq no montó el caso: CHOICE=[$_lk_choice_bmq] EMBED=[$_lk_emb_bmq]"
fi
if [ "$_lk_choice_bore" = "<vacío>" ]; then
  rec ok "BORE no hereda PATCH_CHOICE_DISABLE (no registra un --disable SCHED_PDS)"
else
  rec fail "BORE heredó PATCH_CHOICE_DISABLE: [$_lk_choice_bore]"
fi
if [ "$_lk_ret_bore" = "<vacío>" ]; then
  rec ok "BORE no hereda PATCH_RETIRED_SYMBOLS"
else
  rec fail "BORE heredó PATCH_RETIRED_SYMBOLS: [$_lk_ret_bore]"
fi
if [ "$_lk_emb_bore" = "<vacío>" ]; then
  rec ok "BORE no hereda el parche embebido de BMQ (si lo heredase, ese caería por el fallback)"
else
  rec fail "BORE heredó PATCH_EMBED_B64: aplicaría el parche de otro scheduler como fallback"
fi
if [ "${_lk_acc_bore:-0}" = "${_lk_acc_bmq:-x}" ] && [ -z "$_lk_dup_bore" ]; then
  rec ok "BORE no crece ni duplica PATCH_RETIRED_ALL ($_lk_acc_bmq símbolos, los de bmq)"
else
  rec fail "BORE tocó el acumulador retirado (bmq=$_lk_acc_bmq bore=$_lk_acc_bore dup=[$_lk_dup_bore])"
fi
# El unset que lo arregla tiene que existir; si alguien lo quita, los tests de
# arriba empiezan a fallar, pero este dice exactamente qué se perdió.
_apf_unset="$(sed -n '/^apply_patch_plugin() {/,/^}/p' "$MOTOR" \
              | sed -n '/unset PATCH_TREE_REQUIRED/,+1p')"
for _v in PATCH_CHOICE_DISABLE PATCH_RETIRED_SYMBOLS PATCH_EMBED_B64; do
  case "$_apf_unset" in
    *"$_v"*) : ;;
    *) rec fail "apply_patch_plugin no resetea $_v (vuelve la fuga entre parches)" ;;
  esac
done
case "$_apf_unset" in
  *PATCH_CHOICE_DISABLE*PATCH_EMBED_B64*|*PATCH_EMBED_B64*PATCH_CHOICE_DISABLE*)
    rec ok "apply_patch_plugin resetea los tres estado que filtraba" ;;
  *) rec fail "apply_patch_plugin no resetea CHOICE_DISABLE/RETIRED/EMBED_B64 juntos" ;;
esac
unset _bmq_leak _bmq_retired _bmq_choice _bore_retired _bore_choice _apf_unset _v

printf '%s\n' "== módulo firmado: SECURE_BOOT no se leía sin existir (module-sign) =="
# `if [ "$SECURE_BOOT" = true ]` dentro de module_sign_installed. La variable no
# está declarada en ningún punto del motor (grep: una sola aparición, la del
# propio test), así que con `set -Eeuo pipefail` el build moría con
# "SECURE_BOOT: variable sin asignar" — AL FINAL: compilación hecha, paquete
# instalado y módulos sin firmar. La segunda ejecución sí pasaba (ya existía el
# certificado), que es lo que lo hacía parecer intermitente.
_secboot_reads="$(grep -n '\$SECURE_BOOT\b' "$MOTOR" | grep -v '^[0-9]*:[[:space:]]*#' || true)"
if [ -z "$_secboot_reads" ]; then
  rec ok "el motor no lee \$SECURE_BOOT (usa secure_boot_active, que sí existe)"
else
  rec fail "lectura de \$SECURE_BOOT sin declarar: $(printf '%s' "$_secboot_reads" | tr '\n' ' ')"
fi
if sed -n '/^module_sign_installed() {/,/^}/p' "$MOTOR" | grep -q 'secure_boot_active'; then
  rec ok "module_sign_installed decide por secure_boot_active"
else
  rec fail "module_sign_installed no consulta secure_boot_active"
fi
unset _secboot_reads

printf '%s\n' "== módulo comprimido: la firma alcanza a .ko.zst (MODULE_COMPRESS_ALL) =="
# El perfil de este equipo lleva CONFIG_MODULE_COMPRESS_ZSTD=y y
# CONFIG_MODULE_COMPRESS_ALL=y, así que el árbol instalado no tiene ni un .ko
# pelado. El bucle anterior buscaba solo -name '*.ko', no encontraba nada y aun
# así informaba "ok: 0 módulos firmados".
_ms_body="$(sed -n '/^module_sign_installed() {/,/^}/p' "$MOTOR")"
case "$_ms_body" in
  *"-name '*.ko.*'"*) rec ok "module_sign_installed busca también los comprimidos" ;;
  *) rec fail "module_sign_installed sigue buscando solo '*.ko': con MODULE_COMPRESS_ALL firma 0" ;;
esac
case "$_ms_body" in
  *"NINGÚN módulo firmado"*) rec ok "module_sign_installed avisa cuando no firma nada" ;;
  *) rec fail "module_sign_installed no distingue '0 firmados' de un éxito" ;;
esac
if sed -n '/^_sign_installed_module() {/,/^}/p' "$MOTOR" | grep -q '\*.ko.zst'; then
  rec ok "el firmador sabe descomprimir/firmar/recomprimir un .ko.zst"
else
  rec fail "_sign_installed_module no contempla la compresión zstd"
fi
# Y el perfil tiene que ser el que activa ese camino, que es lo que lo hace
# necesario: si algún día el perfil deja de comprimir, el test avisa de que la
# cobertura ya no está probando nada.
if grep -rq '^CONFIG_MODULE_COMPRESS_ALL=y' "$(dirname "$MOTOR")/profiles/" 2>/dev/null; then
  rec ok "el caso .ko.zst aplica a este perfil (MODULE_COMPRESS_ALL=y)"
else
  rec ok "el perfil ya no comprime módulos; el camino .ko.zst queda como preventivo"
fi
# Ida y vuelta real de la firma sobre un módulo comprimido, con stubs de root y
# de firmador: si el descompresor, el firmador o el recompresor no se encadenan
# bien, el módulo se queda a medio camino (sin comprimir, o comprimido sin
# firmar) y Secure Boot lo rechaza igual, pero más tarde y con otro mensaje.
if command -v zstd >/dev/null 2>&1; then
  _msdir="$ROOT/modsign"
  mkdir -p "$_msdir/bin" "$_msdir/mod"
  printf '#!/bin/sh\nexec "$@"\n' > "$_msdir/bin/sudo"
  printf '#!/bin/sh\nfor a in "$@"; do last="$a"; done\nprintf FIRMA-SIMULADA >> "$last"\n' \
    > "$_msdir/bin/sign-file"
  chmod +x "$_msdir/bin/sudo" "$_msdir/bin/sign-file"
  printf 'MODULO-ORIGINAL\n' | zstd -q -o "$_msdir/mod/test.ko.zst" -f
  sed -n '/^_sign_installed_module() {/,/^}/p' "$MOTOR" > "$_msdir/fn.sh"
  _msrc=1
  PATH="$_msdir/bin:$PATH" bash -c '
    set -u
    source '"$_msdir"'/fn.sh
    _sign_installed_module '"$_msdir"'/mod/test.ko.zst clave.crt cert.crt '"$_msdir"'/bin/sign-file
  ' >/dev/null 2>&1 && _msrc=0
  if [ "$_msrc" = 0 ] && zstd -t "$_msdir/mod/test.ko.zst" >/dev/null 2>&1; then
    rec ok "módulo .ko.zst firmado: sigue siendo zstd válido tras descomprimir/firmar/recomprimir"
  else
    rec fail "el firmado de un .ko.zst dejó el módulo inservible (rc=$_msrc)"
  fi
  if zstd -dc "$_msdir/mod/test.ko.zst" 2>/dev/null | grep -q '^FIRMA-SIMULADA$'; then
    rec ok "la firma queda DENTRO del módulo comprimido (no en un .ko suelto)"
  else
    rec fail "la firma no aparece dentro del .ko.zst"
  fi
  if zstd -dc "$_msdir/mod/test.ko.zst" 2>/dev/null | grep -q '^MODULO-ORIGINAL$'; then
    rec ok "el contenido original sobrevive al ciclo"
  else
    rec fail "el firmado perdió el contenido del módulo"
  fi
  # Un módulo corrupto no puede firmarse: tiene que quedar como estaba, no
  # truncado ni "--firmado" a medias.
  printf 'no-es-zstd' > "$_msdir/mod/malo.ko.zst"
  cp -- "$_msdir/mod/malo.ko.zst" "$_msdir/mod/malo.ref"
  PATH="$_msdir/bin:$PATH" bash -c '
    set -u
    source '"$_msdir"'/fn.sh
    _sign_installed_module '"$_msdir"'/mod/malo.ko.zst clave.crt cert.crt '"$_msdir"'/bin/sign-file
  ' >/dev/null 2>&1
  if cmp -s "$_msdir/mod/malo.ko.zst" "$_msdir/mod/malo.ref"; then
    rec ok "un módulo corrupto no se toca al fallar el firmado"
  else
    rec fail "el fallo de compresión dejó el módulo modificado"
  fi
  unset _msdir _msrc
fi
unset _ms_body

printf '%s\n' "== migración de paquete: la prueba usa el resolutor de la retirada =="
# `pacman -Q linux-upstream` resuelve `provides` y el propio motor declara
# provides=(\"linux-upstream\") en su paquete: la consulta respondía 0 SIEMPRE
# (con "linux-cizen-v3" en la salida), la retirada `pacman -R linux-upstream`
# —que solo acepta nombres— fallaba con "target not found", y el motor lo
# reportaba como "linux-upstream ya no estaba instalado" más el error crudo por
# stderr, en cada build.
_ikp="$(sed -n '/^install_kernel_package() {/,/^}/p' "$MOTOR")"
case "$_ikp" in
  *'pacman -Q "$LEGACY_PKGBASE"'*)
    rec fail "install_kernel_package sigue probando con -Q, que resuelve provides" ;;
  *)
    rec ok "install_kernel_package ya no prueba la migración con pacman -Q" ;;
esac
case "$_ikp" in
  *'pacman -R --print'*) rec ok "la prueba usa pacman -R --print (mismo resolutor, no toca nada)" ;;
  *) rec fail "la prueba de migración no usa el resolutor de pacman -R" ;;
esac
unset _ikp

printf '%s\n' "== extracción de fuentes: el rc de tar se comprueba =="
# extract_tarball se invoca como `extract_tarball || fatal`, y eso desactiva
# errexit en todo su cuerpo. Con el tar a pelo, un tarball corrupto o un ENOSPC a
# mitad se comían el fallo; como el resto de la función solo mira que exista
# $SRC/Makefile, el árbol truncado pasaba por bueno y se compilaba un kernel
# fuente incompleto sin un solo aviso.
_et_body="$(sed -n '/^extract_tarball() {/,/^}/p' "$MOTOR")"
case "$_et_body" in
  *'if ! tar -xf'*) rec ok "extract_tarball comprueba el rc de tar" ;;
  *) rec fail "extract_tarball sigue con 'tar -xf' a pelo: un árbol truncado compila" ;;
esac
if printf '%s' "$_et_body" | sed -n '/if ! tar -xf/,/fi/p' | grep -q 'rm -rf "\$SRC"'; then
  rec ok "extract_tarball borra el árbol a medias cuando tar falla"
else
  rec fail "extract_tarball deja el árbol parcial tras un fallo de tar"
fi
unset _et_body

printf '%s\n' "== frags: el recuento de directivas cuenta directivas =="
# $(( ${#__args[@]} / 2 )): --enable/--module/--disable gastan 2 tokens, pero
# --set-val y --set-str gastan 3. Tres --set-str se anunciaban como "4
# directivas", y ese número es la única señal de que el frag se leyó entero.
_fdirs="$(
  CIZEN_FRAGS_DIR="$ROOT/frags-count"
  mkdir -p "$CIZEN_FRAGS_DIR" "$ROOT/src-frag"
  printf 'CONFIG_X86_X2APIC=y\nCONFIG_HZ=500\nCONFIG_LOCALVERSION="-cizen-v3"\n' \
    > "$CIZEN_FRAGS_DIR/cuenta.frag"
  mkdir -p "$ROOT/src-frag/scripts"
  cat > "$ROOT/src-frag/scripts/config" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$ROOT/src-frag/scripts/config"
  SRC="$ROOT/src-frag"
  info() { printf 'INFO> %s\n' "$*"; }
  apply_config_fragments 2>&1 | sed -n 's/^INFO> Frag aplicado.*(\([0-9]*\) directivas).*/\1/p'
)"
if [ "$_fdirs" = "3" ]; then
  rec ok "frag con 3 directivas cuenta 3 (no ${_fdirs:-?})"
else
  rec fail "un frag de 3 directivas (1 enable + 2 set-str) cuenta ${_fdirs:-?} directivas"
fi
unset _fdirs

printf '%s\n' "== podar-modulos.sh: la poda no se aborta con un módulo sin dependencias =="
# `for _d in "${_deparr[@]:-}"` itera UNA vez con la cadena vacía cuando el módulo
# conservado no tiene `depends=`, y esa vacía se usaba como subíndice de un array
# asociativo: bash aborta con "bad array subscript". El motor inyecta este
# script con `|| true`, así que la consecuencia era un paquete instalado SIN poda
# y sin índices de dependencias, sin ningún aviso.
PODAR="$(dirname "$MOTOR")/podar-modulos.sh"
if [ -r "$PODAR" ]; then
  if command -v depmod >/dev/null 2>&1; then
    _pt="$ROOT/prune/lib/modules/9.9.9"
    mkdir -p "$_pt/kernel/drivers/usb/storage" "$_pt/kernel/drivers/decoy"
    : > "$_pt/kernel/drivers/usb/storage/usb-storage.ko"   # conservado, SIN depends
    : > "$_pt/kernel/drivers/decoy/foo_decoy.ko"            # debe podarse
    depmod -b "$ROOT/prune" 9.9.9 >/dev/null 2>&1
    if out="$(bash "$PODAR" "$_pt" usb-storage 2>&1)"; then
      if [ -f "$_pt/kernel/drivers/usb/storage/usb-storage.ko" ]; then
        rec ok "módulo conservado sin dependencias no tumba la poda (rc=0)"
      else
        rec fail "la poda se llevó el módulo sin dependencias que se pidió conservar"
      fi
      if [ ! -f "$_pt/kernel/drivers/decoy/foo_decoy.ko" ]; then
        rec ok "la poda sigue retirando lo que no se usa"
      else
        rec fail "la poda no retiró el módulo señuelo"
      fi
    else
      rec fail "la poda devolvió error con un módulo sin dependencias: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    fi
    unset _pt out
  else
    rec ok "depmod no disponible: poda con módulo sin dependencias no comprobada"
  fi
  # /etc/modules-load.d admite "kvm_intel   # para KVM": el comentario se quita
  # con sed, pero los espacios que lo precedían se quedaban pegados al nombre y
  # la clave del allowlist no casaba con el nombre canónico.
  if grep -q "s/\[\[:space:\]\]\*#\.\*\$//; s/\^\[\[:space:\]\]" "$PODAR"; then
    rec ok "podar-modulos.sh recorta espacios y comentario de /etc/modules-load.d"
  else
    rec fail "podar-modulos.sh no recorta las líneas de /etc/modules-load.d con comentario"
  fi
  if grep -q '_deparr\[@\]+' "$PODAR"; then
    rec ok "podar-modulos.sh itera el array de deps sin el elemento vacío"
  else
    rec fail "podar-modulos.sh sigue con \"\${_deparr[@]:-}\" (elemento vacío -> bad array subscript)"
  fi
else
  rec ok "podar-modulos.sh no está junto al motor: su poda no se comprobó"
fi

printf '%s\n' "== sched-bench.sh: con carga de 1 hilo la medición se cuenta =="
# `/^1 hilo/` (sin ancla final) también casa con la línea "1 hilos : ..." del
# brazo paralelo cuando SCHED_BENCH_LOAD_N=1: se la comía antes de la regla
# siguiente, `par` nunca se fijaba y flush() descartaba TODAS las muestras
# (contadas=0, descartadas=n) — el histórico se llenaba de "desc".
SB="$(dirname "$MOTOR")/sched-bench.sh"
if [ -r "$SB" ]; then
  sed -n "/awk '\$/,/^  ' \"\$1\"/p" "$SB" | sed '1d;$d' > "$ROOT/sb.awk" 2>/dev/null
  if [ -s "$ROOT/sb.awk" ]; then
    printf 'fecha 2026-10-01\niteraciones: 20\n1 hilo       : 120 ms\n1 hilos  : 90 ms\nlatencia fg   : 40 ms\n' > "$ROOT/sb1.log"
    printf 'fecha 2026-10-01\niteraciones: 20\n1 hilo       : 120 ms\n4 hilos  : 90 ms\nlatencia fg   : 40 ms\n' > "$ROOT/sb4.log"
    _s1="$(awk -f "$ROOT/sb.awk" "$ROOT/sb1.log" 2>/dev/null | awk '{print $1}')"
    _s4="$(awk -f "$ROOT/sb.awk" "$ROOT/sb4.log" 2>/dev/null | awk '{print $1}')"
    if [ "${_s1:-0}" -ge 1 ]; then
      rec ok "con SCHED_BENCH_LOAD_N=1 la muestra se cuenta (contadas=$_s1)"
    else
      rec fail "con 1 hilo la medición se descarta (contadas=${_s1:-0}); la regla /^1 hilo/ se come '1 hilos'"
    fi
    if [ "${_s4:-0}" -ge 1 ]; then
      rec ok "con 4 hilos la muestra se cuenta (contadas=$_s4)"
    else
      rec fail "con 4 hilos la medición se descarta (contadas=${_s4:-0})"
    fi
    unset _s1 _s4
  else
    rec ok "no se pudo extraer el awk de sched-bench.sh: el parser no se comprobó"
  fi
fi

printf '%s\n' "== pgo-collect.sh: --help y los argumentos no pasan por sudo =="
# El `exec sudo` estaba ANTES de parsear: `pgo-collect.sh --help` pedía
# contraseña para imprimir un texto, y CIZEN_PGO_DURATION/VMLINUX/OUT exportadas
# por el usuario se perdían con el env_reset de sudo (sin env_keep), de modo que
# un perfil de 60 s se compilaba con 600 s en silencio.
PGOC="$(dirname "$MOTOR")/pgo-collect.sh"
if [ -r "$PGOC" ]; then
  mkdir -p "$ROOT/fakesudo"
  printf '#!/bin/sh\necho "PIDIENDO-SUDO-INESPERADO" >&2\nexit 77\n' > "$ROOT/fakesudo/sudo"
  chmod +x "$ROOT/fakesudo/sudo"
  _hp="$(PATH="$ROOT/fakesudo:$PATH" bash "$PGOC" --help 2>&1 || true)"
  case "$_hp" in
    *PIDIENDO-SUDO-INESPERADO*) rec fail "pgo-collect.sh --help sigue pidiendo sudo" ;;
    *pgo-collect.sh*) rec ok "pgo-collect.sh --help responde sin elevar" ;;
    *) rec ok "pgo-collect.sh --help no imprime su ayuda (no se elevó, pero tampoco se ve)" ;;
  esac
  _bp="$(PATH="$ROOT/fakesudo:$PATH" bash "$PGOC" --bogus 2>&1 || true)"
  case "$_bp" in
    *"Argumento desconocido"*) rec ok "un argumento desconocido se rechaza sin pedir sudo" ;;
    *PIDIENDO-SUDO-INESPERADO*) rec fail "un argumento desconocido pide sudo antes de comprobarlo" ;;
    *) rec ok "argumento desconocido: sin mensaje reconocible" ;;
  esac
  if [ "$(grep -n 'exec "\${SUDO\[@\]}"' "$PGOC" | cut -d: -f1)" \
       -gt "$(grep -n 'while \[ \$# -gt 0 \]' "$PGOC" | head -1 | cut -d: -f1)" ]; then
    rec ok "pgo-collect.sh parsea los argumentos antes de elevar"
  else
    rec fail "pgo-collect.sh eleva antes de parsear (--help y env perdidos)"
  fi
  if grep -q 'CIZEN_PGO_DURATION="\$DURATION"' "$PGOC"; then
    rec ok "pgo-collect.sh pasa el entorno de PGO al proceso elevado"
  else
    rec fail "pgo-collect.sh no propaga CIZEN_PGO_* a través de sudo"
  fi
  unset _hp _bp
fi

printf '%s\n' "== menú: el gestor de kernels se resuelve como el rollback =="
if [ -r "$MENU" ]; then
  if grep -q 'CIZEN_KMANAGER_SCRIPT' "$MENU" && grep -q 'if \[ -x "\$MANAGER_SCRIPT" \]' "$MENU"; then
    rec ok "la opción 17 resuelve el gestor (env + hermano + instalación) y avisa si falta"
  else
    rec fail "la opción 17 sigue con la ruta fija de /usr/local/bin (sin env ni hermano)"
  fi
fi

# --- v27.33.4: el store de vmlinux se escribía con sudo cp + sudo mv + sudo sh -c
# Este host tiene una allowlist en /etc/sudoers.d/99-cizen-build sin `mv` ni `sh`:
# las tres llamadas fallaban, el store quedaba VACÍO y el ciclo de PGO no se
# podía cerrar sin que alguien archivase el fichero a mano. Aquí se comprueba que
# (a) el archivado funciona de verdad con un árbol falso, (b) solo se usan
# comandos de la allowlist, y (c) pgo-collect.sh no se come un vmlinux a medias.
ARCH="$ROOT/archive"
rm -rf "$ARCH"; mkdir -p "$ARCH"
: > "$ARCH/fns.sh"
extract_fn store_install   >> "$ARCH/fns.sh"
extract_fn archive_vmlinux >> "$ARCH/fns.sh"
extract_fn prune_vmlinux_store >> "$ARCH/fns.sh"
VMLINUX_STORE="$ARCH/store"; export VMLINUX_STORE
VMLINUX_STORE_KEEP=2; export VMLINUX_STORE_KEEP
cat > "$ARCH/run.sh" <<'ARCHRUN'
set -uo pipefail
SRC="${SRC:?}"; VMLINUX_STORE="${VMLINUX_STORE:?}"; VMLINUX_STORE_KEEP="${VMLINUX_STORE_KEEP:-2}"
log(){ printf '  log: %s\n' "$*"; }
ok(){ printf '  ok: %s\n' "$*"; }
warn(){ printf '  warn: %s\n' "$*"; }
info(){ printf '  info: %s\n' "$*"; }
fatal(){ printf '  fatal: %s\n' "$*"; exit 1; }
sudo(){ printf '  [sudo] %s\n' "$*" >&2; "$@"; }
kernel_release(){ printf '%s\n' "${FAKE_REL:-7.2.8-cizen-v3-1}"; }
# shellcheck disable=SC1090
. "$FNS"
archive_vmlinux
ARCHRUN
# (a) con un store escribible por el usuario: NO debe hacer falta sudo para nada
mkdir -p "$ARCH/src"; printf 'ELF-vmlinux-falso\0\0\0' > "$ARCH/src/vmlinux"
printf 'ELF-unstripped\n' > "$ARCH/src/vmlinux.unstripped"
if ( FNS="$ARCH/fns.sh" SRC="$ARCH/src" FAKE_REL=7.2.8-test-1 VMLINUX_STORE="$ARCH/store" \
        bash "$ARCH/run.sh" > "$ARCH/out1" 2> "$ARCH/err1" ); then
  if cmp -s "$ARCH/src/vmlinux" "$ARCH/store/7.2.8-test-1/vmlinux" \
     && cmp -s "$ARCH/src/vmlinux.unstripped" "$ARCH/store/7.2.8-test-1/vmlinux.unstripped" \
     && [ -f "$ARCH/store/7.2.8-test-1.meta" ]; then
    rec ok "store: el build archiva vmlinux y vmlinux.unstripped con su testigo .meta"
  else
    rec fail "store: el vmlinux o el .meta no quedaron donde tocaba"
  fi
  if [ ! -s "$ARCH/err1" ]; then
    rec ok "store: con un store escribible no hace falta sudo ni una vez"
  else
    rec fail "store: pidió sudo aun pudiendo escribir sin él: $(tr '\n' ' ' < "$ARCH/err1")"
  fi
else
  rec fail "store: archive_vmlinux no llegó al final (salida: $(tr '\n' ' ' < "$ARCH/out1" 2>/dev/null)$(tr '\n' ' ' < "$ARCH/err1" 2>/dev/null))"
fi
# el .meta tiene que llevar el tamaño real, que es lo que valida pgo-collect.sh
mvsize="$(stat -c %s "$ARCH/store/7.2.8-test-1/vmlinux" 2>/dev/null)"
if [ -n "$mvsize" ] && grep -qx "size $mvsize vmlinux" "$ARCH/store/7.2.8-test-1.meta" 2>/dev/null; then
  rec ok "store: el testigo .meta anota el tamaño real del vmlinux"
else
  rec fail "store: el testigo .meta no anota el tamaño real del vmlinux"
fi
# (b) regresión con el CONTRATO del motor, no con una lista de comandos escrita a
# mano. El motor declara sus dependencias de sudo en SUDO_OPS_REQUERIAS /
# _OPCIONALES, y preflight_sudo lo dice al build. El store no es una
# funcionalidad opcional: sin su vmlinux el ciclo de PGO no existe, así que sus
# comandos tienen que estar en las REQUERIDAS. Con el código viejo usaba
# `sudo sh` —que no está en ninguna de las dos listas, o sea una dependencia sin
# declarar— y `sudo mv`, que solo es opcional: por eso `preflight_sudo` no lo
# avisaba y el store quedaba vacío en silencio.
reqs="$(sed -n 's/^SUDO_OPS_REQUERIDOS=(\(.*\))/\1/p' "$MOTOR" | tr ' ' '\n' | sed '/^$/d')"
# El rango va de VMLINUX_STORE= al final de prune_vmlinux_store: con un `/^}/`
# que para en la primera llave se quedaba solo con store_install y daba una
# cobertura aparente que no era real. Y de las líneas se descartan las llamadas
# a los log, porque el texto de un `ok`/`warn` puede citar un comando sudo
# (`para  sudo pgo-collect.sh …`) sin que nadie lo ejecute.
storeblk="$(sed -n '/^VMLINUX_STORE=/,/^# Poda del store/p' "$MOTOR" \
            | grep -vE '^[[:space:]]*(#|warn|ok|log|info|err|fatal) ')"
storeops="$(printf '%s\n' "$storeblk" | grep -oE '\bsudo [a-z][a-z0-9-]*' | awk '{print $2}' | sort -u)"
if [ -z "$storeops" ]; then
  rec fail "store: no se ve cómo se escriben los ficheros (el rango de análisis no los encuentra)"
elif printf '%s\n' "$storeops" | while read -r op; do
        printf '%s\n' "$reqs" | grep -qx -- "$op" || { printf '%s' "$op"; break; }
      done | grep -q .; then
  rec fail "store: usa sudo fuera de SUDO_OPS_REQUERIDOS: $(printf '%s\n' "$storeops" \
            | while read -r op; do printf '%s\n' "$reqs" | grep -qx -- "$op" || printf '%s ', "$op"; done)"
elif printf '%s\n' "$storeblk" | grep -qE 'sudo[[:space:]]+install'; then
  rec ok "store: sus comandos sudo ($(printf '%s' "$storeops" | tr '\n' ' ')) están todos en SUDO_OPS_REQUERIDOS"
else
  rec fail "store: no se ve cómo se escribe el fichero en el store"
fi
# y que el store se lea igual de automático que se escribe
if grep -q 'CIZEN_VMLINUX_STORE:-' "$PGO_" \
   && grep -q 'pgo_vmlinux_committed' "$PGO_"; then
  rec ok "pgo-collect: exige el testigo .meta antes de usar un vmlinux del store"
else
  rec fail "pgo-collect: usa el vmlinux del store sin comprobar su testigo .meta"
fi
# (c) un store a medias (sin .meta, o con tamaño que no cuadra) se rechaza.
# Las dos funciones se prueban tal cual están en pgo-collect.sh, con stubs de
# los log: no se reescriben aquí, que un test que copia el código no lo prueba.
{
  cat <<'FINDSTUB'
set -uo pipefail
KVER="${KVER:-}"; VMLINUX_STORE="${VMLINUX_STORE:-}"; VMLINUX=""
log(){ :; }
ok(){ :; }
info(){ :; }
warn(){ printf 'warn: %s\n' "$*"; }
fatal(){ printf 'fatal: %s\n' "$*" >&2; exit 1; }
FINDSTUB
  sed -n '/^pgo_vmlinux_committed() {/,/^}/p' "$PGO_"
  sed -n '/^pgo_find_vmlinux() {/,/^}/p' "$PGO_"
  printf 'pgo_find_vmlinux || true\nprintf "VMLINUX=%%s\\n" "${VMLINUX:-<ninguno>}"\n'
} > "$ARCH/find-real.sh"
SD="$ARCH/sd"; rm -rf "$SD"; mkdir -p "$SD/7.2.8-k"
printf 'vmlinux-bueno' > "$SD/7.2.8-k/vmlinux"
find1="$(KVER=7.2.8-k VMLINUX_STORE="$SD" bash "$ARCH/find-real.sh" 2>&1)"
if [ "$(printf '%s\n' "$find1" | grep '^VMLINUX=')" = "VMLINUX=<ninguno>" ]; then
  rec ok "pgo-collect: sin testigo, el vmlinux del store NO se usa"
else
  rec fail "pgo-collect: usó un vmlinux sin testigo (salida: $find1)"
fi
{ printf 'release 7.2.8-k\ndate ahora\nsize 999999 vmlinux\n' > "$SD/7.2.8-k.meta"; }
find2="$(KVER=7.2.8-k VMLINUX_STORE="$SD" bash "$ARCH/find-real.sh" 2>&1)"
if [ "$(printf '%s\n' "$find2" | grep '^VMLINUX=')" = "VMLINUX=<ninguno>" ]; then
  rec ok "pgo-collect: con el tamaño que no cuadra, el vmlinux del store NO se usa"
else
  rec fail "pgo-collect: aceptó un vmlinux con tamaño distinto del testigo (salida: $find2)"
fi
{ printf 'release 7.2.8-k\ndate ahora\nsize %s vmlinux\n' "$(stat -c %s "$SD/7.2.8-k/vmlinux")" > "$SD/7.2.8-k.meta"; }
find3="$(KVER=7.2.8-k VMLINUX_STORE="$SD" bash "$ARCH/find-real.sh" 2>&1)"
if [ "$(printf '%s\n' "$find3" | grep '^VMLINUX=')" = "VMLINUX=$SD/7.2.8-k/vmlinux" ]; then
  rec ok "pgo-collect: con testigo y tamaño correcto, el vmlinux SÍ se usa"
else
  rec fail "pgo-collect: rechazó un vmlinux archivado bien (salida: $find3)"
fi
if grep -q 'CIZEN_VMLINUX_STORE="\${CIZEN_VMLINUX_STORE:-}" "\$0"' "$PGO_"; then
  rec ok "pgo-collect: el store personalizado sobrevive a la elevación con sudo"
else
  rec fail "pgo-collect: al elevar con sudo se pierde CIZEN_VMLINUX_STORE (env_reset)"
fi

# --- v27.33.5: el resumen de acierto de ccache no se imprimió NUNCA -------------
# El IFS del motor es $'\n\t' (línea 147), sin espacio. Un `read -r a b c` de
# tres variables NO reparte por espacios con ese IFS, así que la foto
# "41407 34418 0" se iba entera a la primera variable y las otras dos quedaban
# vacías: error de aritmética al final del build y `CCACHE_STATS` vacío, o sea
# que el bloque no había impreso nada desde que existe (v27.31.52). Se comprueba
# comprueba con la foto real que dejó el build del 2-oct.
CCT="$ROOT/ccache"
rm -rf "$CCT"; mkdir -p "$CCT"
extract_fn ccache_snapshot_parse > "$CCT/fn.sh"
cat > "$CCT/t.sh" <<'CCTSTUB'
set -uo pipefail
IFS=$'\n\t'   # el IFS real del motor: sin espacio, que es la trampa
# shellcheck disable=SC1090
. "$FNF"
mapfile -t _cbs < <(ccache_snapshot_parse "${1:-}")
printf '%s|%s|%s\n' "${_cbs[0]:-0}" "${_cbs[1]:-0}" "${_cbs[2]:-0}"
CCTSTUB
cc_parse() { FNF="$CCT/fn.sh" bash "$CCT/t.sh" "$1"; }
if [ "$(cc_parse '41407 34418 0')" = "41407|34418|0" ]; then
  rec ok "ccache: la foto de antes se reparte en tres cifras (no se va entera a una)"
else
  rec fail "ccache: la foto '41407 34418 0' se parseó como $(cc_parse '41407 34418 0')"
fi
if [ "$(cc_parse 'basura')" = "0|0|0" ] && [ "$(cc_parse '')" = "0|0|0" ]; then
  rec ok "ccache: una foto vacía o no numérica da 0 y no revienta la aritmética"
else
  rec fail "ccache: con la foto mal formada sale $(cc_parse 'basura') / $(cc_parse '')"
fi
# y el contrato completo: con la foto bien leída, el delta tiene que ser un número
# (el bloque inline que la usa es lo que se quedaba en blanco)
if sed -n '/^CCACHE_STATS=""$/,/^fi$/p' "$MOTOR" | grep -q 'ccache_snapshot_parse'; then
  rec ok "ccache: el resumen del build usa el parseo testeable, no un read en línea"
else
  rec fail "ccache: el resumen del build no usa ccache_snapshot_parse (IFS lo rompe)"
fi

# --- PGO: por qué la captura de 15 min no servía para nada ----------------
# Las tres funciones viven en pgo-collect.sh, no en el motor. Se prueban en un
# subshell con stubs, sustituyendo /proc/cpuinfo y perf porCollaboradores de
# pega: la máquina de quien correr esto no tiene por qué ser Intel con LBR.
if [ -f "$PGO" ] && declare -f pgo_perf_event >/dev/null 2>&1; then
  PGT="$ROOT/pg"; mkdir -p "$PGT"
  # La función recibe el fichero de cpuinfo como $1 (en producción, /proc/cpuinfo),
  # así que el arnés le pasa cpuinfos de mentira y solo tiene que doblar `perf list`.
  cat > "$PGT/ev.sh" <<'HEOF'
set -u
IFS=$'\n\t'   # el IFS REAL del script: sin espacio, que es la trampa
HAS_NEAR="${HAS_NEAR:-0}"
perf() { # imita `perf list <patrón>`: imprime los eventos que encuentra, o nada
  case "$*" in
    *br_inst_retired.near_taken*)
      [ "$HAS_NEAR" = 1 ] || return 1
      printf '  br_inst_retired.near_taken\n       [Taken branch instructions retired]\n'
      ;;
  esac
  return 1
}
HEOF
  sed -n "/^pgo_perf_args() {/,/^}/p" "$PGO" >> "$PGT/ev.sh"
  printf 'PGO_PERF_ARGS=()\n' >> "$PGT/ev.sh"
  sed -n "/^pgo_perf_event() {/,/^}/p" "$PGO" >> "$PGT/ev.sh"
  printf 'pgo_perf_event "$1"\n' >> "$PGT/ev.sh"
  # Y el mismo arnés pero por la variante con array: es la que llama a `perf
  # record`, y su partición en tokens es lo que se rompió (el IFS del script no
  # tiene espacio, así que "$var" sin comillas no parte nada).
  cat > "$PGT/arr.sh" <<'HEOF'
set -u
IFS=$'\n\t'   # el IFS REAL del script: sin espacio, que es la trampa
HAS_NEAR="${HAS_NEAR:-0}"
perf() {
  case "$*" in
    *br_inst_retired.near_taken*)
      [ "$HAS_NEAR" = 1 ] || return 1
      printf '  br_inst_retired.near_taken\n'
      ;;
  esac
  return 1
}
HEOF
  sed -n "/^pgo_perf_args() {/,/^}/p" "$PGO" >> "$PGT/arr.sh"
  cat >> "$PGT/arr.sh" <<'HEOF'
pgo_perf_args "$1" || exit 1
printf 'N=%s\n' "${#PGO_PERF_ARGS[@]}"
printf '[%s]\n' "${PGO_PERF_ARGS[@]}"
HEOF
  arr() { HAS_NEAR="$1" bash "$PGT/arr.sh" "$2"; }
  printf 'vendor_id\t: GenuineIntel\nmodel name\t: Intel(R) Core(TM) i5-7500\n' > "$PGT/intel-ok"
  printf 'vendor_id\t: AuthenticAMD\nmodel name\t: AMD Ryzen 9 5950X\nflags\t: fpu vme de pse tsc\nbrs\n' > "$PGT/amd-brs"
  printf 'vendor_id\t: AuthenticAMD\nmodel name\t: AMD Ryzen 9 5950X\nflags\t: fpu vme de pse tsc\namd_lbr_v2\n' > "$PGT/amd-lbrv2"
  printf 'vendor_id\t: AuthenticAMD\nmodel name\t: AMD Ryzen 5 3600\nflags\t: fpu vme de pse tsc\n' > "$PGT/amd-no"
  printf 'vendor_id\t: RISC-V\n' > "$PGT/otro"
  ev() { HAS_NEAR="$1" bash "$PGT/ev.sh" "$2"; }

  # 1. Intel con el evento LBR presente: la receta de la doc, con -b (sin -b el
  #    perfil no tiene ramas y llvm-profgen no puede ponderar nada).
  if [ "$(ev 1 "$PGT/intel-ok")" = "-e br_inst_retired.near_taken:k -b" ]; then
    rec ok "pgo: Intel con LBR pide el evento de la doc y -b (rama)"
  else
    rec fail "pgo: Intel con LBR dio '$(ev 1 "$PGT/intel-ok")'"
  fi
  # 2. Intel SIN el evento en perf list: no se inventa un evento, se rinde (rc=1)
  if ev 0 "$PGT/intel-ok" >/dev/null 2>&1; then
    rec fail "pgo: Intel sin near_taken fingió tener LBR"
  else
    rec ok "pgo: Intel sin el evento LBR devuelve error en vez de capturar sin ramas"
  fi
  # 3. AMD Zen3 con BRS y Zen4 con amd_lbr_v2: --pfm-events, no un evento de Intel
  if [ "$(ev 0 "$PGT/amd-brs")" = "--pfm-events RETIRED_TAKEN_BRANCH_INSTRUCTIONS:k -b" ] \
     && [ "$(ev 0 "$PGT/amd-lbrv2")" = "--pfm-events RETIRED_TAKEN_BRANCH_INSTRUCTIONS:k -b" ]; then
    rec ok "pgo: AMD con BRS o con amd_lbr_v2 usa --pfm-events (y no el evento de Intel)"
  else
    rec fail "pgo: AMD con LBR dio '$(ev 0 "$PGT/amd-brs")' / '$(ev 0 "$PGT/amd-lbrv2")'"
  fi
  # 4. AMD sin LBR (Zen1/Zen2) y un vendor que no sea Intel/AMD: mismo silencio
  if ! ev 0 "$PGT/amd-no" >/dev/null 2>&1 && ! ev 0 "$PGT/otro" >/dev/null 2>&1; then
    rec ok "pgo: AMD sin BRS/amd_lbr_v2, y un vendor desconocido, devuelven error"
  else
    rec fail "pgo: se fingió LBR donde no hay (amd-no u otro vendor)"
  fi
  # 5. La aritmética es irrelevante pero el string de args tiene que llevar -b
  RECETA="$(ev 1 "$PGT/intel-ok")"
  if grep -q -- '-b' <<<"$RECETA" && grep -q -- '-b' <<<"$(ev 0 "$PGT/amd-brs")"; then
    rec ok "pgo: toda receta de captura incluye -b (llvm-profgen lo exige)"
  else
    rec fail "pgo: alguna receta de captura se quedó sin -b"
  fi
  # 5a. Y la receta se imprime en UNA línea: con el IFS del script, "${arr[*]}"
  #     une por \n y el mensaje salía partido en tres renglones. La comparación
  #     exacta ya lo cubre: una versión con saltos de línea no puede igualarla.
  if [ "$RECETA" = "-e br_inst_retired.near_taken:k -b" ]; then
    rec ok "pgo: la receta se imprime en una línea (el join no usa el IFS del script)"
  else
    rec fail "pgo: la receta sale partida: '$(printf %s "$RECETA" | tr '\n' '|')'"
  fi
  # 5b. La forma que de verdad llega a `perf record` son tokens sueltos. Con el
  #     IFS=$'\n\t' del script, partir una cadena sin comillas no la parte:
  #     perf llegó a recibir "-e br_inst_retired.near_taken:k -b" como UN evento
  #     («event syntax error: '..ar_taken:k -b'») y no arrancó el muestreo.
  A_INTEL="$(arr 1 "$PGT/intel-ok")"
  A_AMD="$(arr 0 "$PGT/amd-brs")"
  if [ "$(head -1 <<<"$A_INTEL")" = "N=3" ] && [ "$(head -1 <<<"$A_AMD")" = "N=3" ]; then
    rec ok "pgo: los args de perf son 3 tokens, no una frase (el IFS del script no parte strings)"
  else
    rec fail "pgo: args de perf mal partidos: Intel=$(tr '\n' ' ' <<<"$A_INTEL") AMD=$(tr '\n' ' ' <<<"$A_AMD")"
  fi
  if [ "$(sed -n '2p' <<<"$A_INTEL")" = "[-e]" ] && [ "$(sed -n '3p' <<<"$A_INTEL")" = "[br_inst_retired.near_taken:k]" ] \
     && [ "$(sed -n '2p' <<<"$A_AMD")" = "[--pfm-events]" ]; then
    rec ok "pgo: -e y --pfm-events van en su propio token (perf no los traga pegados)"
  else
    rec fail "pgo: token mal colocado: $(tr '\n' ' ' <<<"$A_INTEL")"
  fi
  # 5c. Y la línea de captura tiene que expandir el array, no la cadena.
  if grep -q '"${PGO_PERF_ARGS\[@\]}"' "$PGO" && ! grep -qE '[^-] \$PGO_PERF_ARGS[^-]' "$PGO"; then
    rec ok "pgo: perf record expande \"\${PGO_PERF_ARGS[@]}\", no el string"
  else
    rec fail "pgo: perf record no expande el array: vuelve el «event syntax error»"
  fi
  # 6. Contrato con llvm-profgen: --kernel debe estar en la conversión. Esta es la
  #    línea que daba «No relevant mmap event is found in perf data» tras 15 min.
  if grep -q 'llvm-profgen --kernel' "$PGO"; then
    rec ok "pgo: la conversión pasa --kernel (si no, no encuentra mmap events)"
  else
    rec fail "pgo: la conversión NO pasa --kernel: abortará con «No relevant mmap event»"
  fi
  # 7. Y la captura no se tira con el fallo: el trap tiene que conservar el perf.data
  if sed -n '/^pgo_cleanup() {/,/^}/p' "$PGO" | grep -q 'pgo_keep_perfdata'; then
    rec ok "pgo: si la conversión falla, el perf.data se conserva (no se pierde la captura)"
  else
    rec fail "pgo: el trap borra el perf.data aunque la conversión falle"
  fi
  # 8. El periodo por defecto es primo, como pide la doc
  if grep -q 'CIZEN_PGO_PERIOD:-500009' "$PGO"; then
    rec ok "pgo: el periodo por defecto es 500009 ciclos (primo, el de la doc)"
  else
    rec fail "pgo: el periodo por defecto no es 500009"
  fi
  # 9. El destino no es /root cuando hay un usuario detrás del sudo
  cat > "$PGT/home.sh" <<'HEOF'
set -u
SUDO_USER="${SUDO_USER:-}"
HEOF
  sed -n '/^pgo_target_home() {/,/^}/p' "$PGO" >> "$PGT/home.sh"
  printf 'pgo_target_home\n' >> "$PGT/home.sh"
  H_Cizen="$(SUDO_USER=cizen bash "$PGT/home.sh")"
  H_ROOT="$(SUDO_USER=root bash "$PGT/home.sh")"
  H_NONE="$(SUDO_USER= bash "$PGT/home.sh")"
  if [ -n "$H_Cizen" ] && [ "$H_Cizen" != "/root" ]; then
    rec ok "pgo: con sudo, el .afdo va al home del usuario ($H_Cizen), no a /root"
  else
    rec fail "pgo: con SUDO_USER=cizen el destino fue '$H_Cizen' (debería ser el home de cizen)"
  fi
  if [ "$H_ROOT" = "$H_NONE" ]; then
    rec ok "pgo: sin usuario detrás (root directo), el destino es el \$HOME de quien lo lanza"
  else
    rec fail "pgo: root directo dio '$H_ROOT' y sin SUDO_USER '$H_NONE'"
  fi
  # 10. El aviso de que el kernel en marcha no era AutoFDO se basa en el config real
  cat > "$PGT/autofdo.sh" <<'HEOF'
set -u
KVER="x"
HEOF
  sed -n '/^pgo_running_autofdo() {/,/^}/p' "$PGO" >> "$PGT/autofdo.sh"
  printf 'pgo_running_autofdo "$1"\n' >> "$PGT/autofdo.sh"
  printf 'CONFIG_AUTOFDO_CLANG=y\nCONFIG_LTO_CLANG=y\n' > "$PGT/cfg-si"
  printf '# CONFIG_AUTOFDO_CLANG is not set\nCONFIG_LTO_CLANG=y\n' > "$PGT/cfg-no"
  A_SI="$(bash "$PGT/autofdo.sh" "$PGT/cfg-si" >/dev/null 2>&1 && echo si || echo no)"
  A_NO="$(bash "$PGT/autofdo.sh" "$PGT/cfg-no" >/dev/null 2>&1 && echo si || echo no)"
  A_VACIO="$(bash "$PGT/autofdo.sh" "$PGT/inexistente" >/dev/null 2>&1 && echo si || echo no)"
  if [ "$A_SI" = si ] && [ "$A_NO" = no ] && [ "$A_VACIO" = no ]; then
    rec ok "pgo: avisa del kernel en marcha sin CONFIG_AUTOFDO_CLANG (y calla si no hay config)"
  else
    rec fail "pgo: la detección de AUTOFDO da con=$A_SI sin=$A_NO inexistente=$A_VACIO"
  fi
  # 11. Y el motor tiene que buscar el perfil donde el colector lo dejó
  if sed -n '/^pgo_profile_dir() {/p' "$MOTOR" | grep -q 'HOME/kernel-pgo'; then
    rec ok "pgo: el motor (--pgo a secas) busca en ~/kernel-pgo, el mismo destino"
  else
    rec fail "pgo: el motor ya no busca en ~/kernel-pgo: el perfil no aparecería"
  fi
  # 12. El directorio de salida nace del usuario: si fuera de root, el .afdo sería
  #     suyo pero no podría borrarlo (unlink pide escritura en el DIRECTORIO).
  if grep -q 'OUT_DIR_NUEVO' "$PGO" && sed -n '/^if \[ -n "$OUT_DIR_NUEVO" \]/p' "$PGO" | grep -q pgo_chown; then
    rec ok "pgo: el directorio de salida se crea con el usuario como dueño (borrar sin sudo)"
  else
    rec fail "pgo: el directorio de salida nace root:root: el .afdo no se puede borrar sin sudo"
  fi
else
  # Ojo: que no haya nada que probar NO es lo mismo que estar bien. Si el script
  # está pero sus decisiones no son extraíbles, el arnés está ciego y eso se dice.
  if [ -f "$PGO" ]; then
    rec fail "pgo: $PGO existe pero no expone pgo_perf_event/pgo_target_home: sus decisiones no son testeables"
  else
    rec ok "pgo: pgo-collect.sh no está junto al motor; tests de PGO omitidos"
  fi
fi

# --- PGO: el resumen debe decir que la build lleva perfil ------------------------
# `--pgo <fichero>` es la forma que documenta el README, y era la única que
# llegaba al resumen sin " + PGO": el build llevaba -fprofile-sample-use igual
# (el perfil viaja por KCONFIG_CC_OPTS, que no mira PGO_CHANGED) pero la pantalla
# juraba que no. Un resumen que miente sobre lo que lleva la build es peor que no
# resumir, así que aquí se comprueba el flag que lo alimenta, no el texto.
if declare -f ask_build_pgo >/dev/null 2>&1; then
  AP="$ROOT/ap"; mkdir -p "$AP"
  printf 'perfil de mentira\n' > "$AP/perfil.afdo"
  cat > "$AP/case.sh" <<'HEOF'
set -u
ok() { :; }
warn() { :; }
info() { :; }
log() { :; }
err() { :; }
fatal() { return 1; }
pgo_profile_dir() { printf '%s' "$(dirname "$1")"; }
pgo_list_profiles() { printf '%s\n' "$PERFIL" 2>/dev/null; }
pgo_pick_profile() { printf '%s' "$PERFIL"; }
# Entradas: $1=PGO_EXPLICIT $2=PGO_REQUESTED $3=CIZEN_PGO_PROFILE $4=PERFIL
PGO_EXPLICIT="$1"; PGO_REQUESTED="$2"; CIZEN_PGO_PROFILE="$3"; PERFIL="$4"
HEOF
  sed -n '/^pgo_profile_dir() {/,/^}/p' "$MOTOR" >> "$AP/case.sh"
  sed -n '/^pgo_disp_suffix() {/,/^}/p' "$MOTOR" >> "$AP/case.sh"
  sed -n '/^ask_build_pgo() {/,/^}/p' "$MOTOR" >> "$AP/case.sh"
  # La llamada va AL FINAL: con las definiciones detrás, bash daría «command not
  # found», el 2>/dev/null lo escondería y el test leería changed=0 siempre.
  cat >> "$AP/case.sh" <<'HEOF'
ask_build_pgo >/dev/null 2>&1
printf 'changed=%s suffix=[%s]\n' "${PGO_CHANGED:-0}" "$(pgo_disp_suffix)"
HEOF
  apc() { bash "$AP/case.sh" "$1" "$2" "$3" "$4" 2>/dev/null; }
  # 1. La forma del README: --pgo con ruta explícita.
  R_EXP="$(apc true true "$AP/perfil.afdo" "$AP/perfil.afdo")"
  if [ "$R_EXP" = "changed=1 suffix=[ + PGO]" ]; then
    rec ok "pgo: --pgo <fichero> marca el cambio y el resumen anuncia + PGO"
  else
    rec fail "pgo: --pgo <fichero> dio '$R_EXP' (se esperaba changed=1 con + PGO)"
  fi
  # 2. --pgo a secas: sigue funcionando (auto-elige el perfil y marca el cambio).
  R_AUTO="$(apc false true "" "$AP/perfil.afdo")"
  if [ "$R_AUTO" = "changed=1 suffix=[ + PGO]" ]; then
    rec ok "pgo: --pgo a secas elige perfil y también anuncia + PGO"
  else
    rec fail "pgo: --pgo a secas dio '$R_AUTO'"
  fi
  # 3. --no-pgo: ni cambio ni anuncio. Este es el caso que NO puede romperse.
  R_NO="$(apc false false "" "")"
  if [ "$R_NO" = "changed=0 suffix=[]" ]; then
    rec ok "pgo: sin PGO no se anuncia (el resumen no miente al revés)"
  else
    rec fail "pgo: sin PGO dio '$R_NO' (no debe anunciar perfil)"
  fi
  # 4. Bandera explícita pero SIN perfil detrás: no se puede anunciar lo que no hay.
  R_VACIO="$(apc true false "" "")"
  if [ "$R_VACIO" = "changed=0 suffix=[]" ]; then
    rec ok "pgo: --pgo sin perfil detrás no inventa un + PGO"
  else
    rec fail "pgo: con el perfil vacío-annunció '$R_VACIO'"
  fi
else
  rec fail "pgo: no se pudo extraer ask_build_pgo: el resumen de PGO queda sin cubrir"
fi

# --- despliegue: la suite se copia a /usr/local/bin A MANO --------------------
# No hay PKGBUILD ni script de instalación en el repo: el README documenta un
# `install -Dm755` POR FICHERO, y esa es la trampa. El 2-oct-2026 el motor y
# pgo-collect.sh quedaron en 644 en la suite instalada y el arranque directo
# respondió "Permiso denegado", mientras los otros siete sí eran ejecutables:
# nadie se dio cuenta porque el motor que avisa es el que ya no arrancaba. Aquí se
# vigila la mitad que el repo controla (que lo que hay que ejecutar, se pueda
# ejecutar) y el README lleva ya la receta completa para la otra mitad.
SUITE="$(dirname -- "$MOTOR")"
[ -f "$SUITE/pgo-collect.sh" ] || SUITE="$HOME/Proyectos/cizen-linux-kernel-update/kernel-update"
N_DEPLOY=0; SIN_X=''
for s in "$SUITE"/*.sh "$SUITE"/cizen-uki-sync; do
  [ -f "$s" ] || continue
  N_DEPLOY=$((N_DEPLOY + 1))
  [ -x "$s" ] || SIN_X="${SIN_X}$(basename -- "$s") "
done
if [ "$N_DEPLOY" = 0 ]; then
  rec fail "despliegue: no encuentro la suite en '$SUITE'; este test no vigila nada"
elif [ -z "$SIN_X" ]; then
  rec ok "despliegue: los $N_DEPLOY ejecutables de la suite tienen bit +x en el repo"
else
  rec fail "despliegue: sin bit +x en el repo: $SIN_X"
fi

# ============================================================
# v27.33.8: guarda anti-root del motor.
#
# Contexto real: el build de 7.2.9 se lanzó como `sudo kernel-update.sh ...` y
# makepkg abortó con "Ejecutar makepkg como superusuario no está permitido" al
# empaquetar, tras haber configurado ysquiado todo. Además, y en silencio, el
# build había corrido con HOME=/root: ccache y la caché de fuentes del usuario
# se ignoraron. Estos tests fijan las dos propiedades que lo evitan.
# ============================================================
_sx_v27_33_8=0

# El motor no es un fichero de funciones, así que no vale _sx_nsc (que extrae de
# VERIFY_SRC). La guarda es un `if` de primer nivel sin `if` anidados: se extrae
# del `if` hasta el primer `^fi$`.
_sx_guard() {
  awk '
    /if \[ "\$\(id -u\)" = "0" \]; then/ { ing = 1 }
    ing { print }
    ing && /^fi$/ { exit }
  ' "$MOTOR"
}
_SX_GUARD="$(_sx_guard)"
if [ -n "$_SX_GUARD" ]; then
  rec ok "el motor tiene guarda anti-root (id -u = 0) y es extraíble"
  _sx_v27_33_8=$(( _sx_v27_33_8 + 1 ))
else
  rec fail "el motor NO tiene guarda anti-root: 'sudo kernel-update.sh' llega hasta makepkg y revienta el build"
fi

# Posición: DESPUÉS del dispatch de los modos de mantenimiento que no compilan
# (--selftest/--changelog/--hardened son válidos como root) y ANTES de
# prepare_dirs, que es el primer punto compartido por todo modo que compila.
_sx_l_guard="$(grep -n 'if \[ "\$(id -u)" = "0" \]; then' "$MOTOR" | head -1 | cut -d: -f1)"
_sx_l_chlog="$(grep -n 'changelog_bump || exit 1' "$MOTOR" | head -1 | cut -d: -f1)"
_sx_l_prep="$(grep -n '^prepare_dirs$' "$MOTOR" | head -1 | cut -d: -f1)"
if [ -n "$_sx_l_guard" ] && [ -n "$_sx_l_chlog" ] && [ -n "$_sx_l_prep" ] && \
   [ "$_sx_l_chlog" -lt "$_sx_l_guard" ] && [ "$_sx_l_guard" -lt "$_sx_l_prep" ]; then
  rec ok "la guarda va tras el dispatch de mantenimiento ($_sx_l_chlog < $_sx_l_guard) y antes de prepare_dirs ($_sx_l_guard < $_sx_l_prep)"
  _sx_v27_33_8=$(( _sx_v27_33_8 + 1 ))
else
  rec fail "la guarda está mal colocada (changelog=$_sx_l_chlog guarda=$_sx_l_guard prepare_dirs=$_sx_l_prep): debe ir entre ambos, o --selftest/--changelog/--hardened quedan bloqueados como root"
fi

# Comportamiento real, no solo el texto: se ejecuta el bloque con `id` y `fatal`
# simulados, que es la única forma de probar la rama EUID==0 sin ser root.
{
  printf 'id(){ [ "${1:-}" = "-u" ] && echo "${SX_FAKE_UID:-0}"; }\n'
  printf 'fatal(){ printf "FATAL:%%s\\n" "$*"; exit 42; }\n'
  printf '%s\n' "$_SX_GUARD"
  printf 'echo LLEGO_A_PREPARE\n'
} > "$ROOT/guard-probe.sh"

_sx_out_root="$(SX_FAKE_UID=0 bash "$ROOT/guard-probe.sh" 2>&1 || true)"
if ! printf '%s' "$_sx_out_root" | grep -q 'LLEGO_A_PREPARE'; then
  rec ok "como root (uid 0) la guarda aborta antes de prepare_dirs"
  _sx_v27_33_8=$(( _sx_v27_33_8 + 1 ))
else
  rec fail "como root la guarda NO aborta: el build llega a makepkg y muere con Error 10"
fi

_sx_out_user="$(SX_FAKE_UID=1000 bash "$ROOT/guard-probe.sh" 2>&1 || true)"
if printf '%s' "$_sx_out_user" | grep -q 'LLEGO_A_PREPARE'; then
  rec ok "como usuario (uid 1000) la guarda deja continuar: el build normal no se rompe"
  _sx_v27_33_8=$(( _sx_v27_33_8 + 1 ))
else
  rec fail "la guarda aborta tambien como usuario (uid 1000): dejaria el build inutilizable"
fi

# El mensaje tiene que nombrar LAS DOS causas. Con solo la primera el usuario
# quita el sudo, compila, y pierde la caché caliente sin enterarse de por qué.
if printf '%s' "$_sx_out_root" | grep -q 'makepkg' && printf '%s' "$_sx_out_root" | grep -qi 'ccache'; then
  rec ok "el aviso de root explica las dos causas (makepkg y ccache), no solo la primera"
  _sx_v27_33_8=$(( _sx_v27_33_8 + 1 ))
else
  rec fail "el aviso no menciona a la vez makepkg y ccache: con sudo se pierde la caché caliente sin explicar por qué"
fi

if [ "$_sx_v27_33_8" -eq 5 ]; then
  ok "v27.33.8: 5/5 pruebas de la guarda anti-root"
else
  err "v27.33.8: solo $_sx_v27_33_8/5 pruebas de la guarda anti-root"
fi

# ============================================================
# v27.33.9: archivo local del UKI para rollback.
#
# Contexto real: el UKI del ESP es `-rwx------ root`, así que una copia hecha con
# `sudo cp` sin `chown` acaba root 700 en el home del usuario: inútil para un
# rollback. Y `~/kernel-pgo/ukis/` puede contener cosas del usuario que la poda
# no debe tocar. Estos tests fijan las tres cosas: que se archive legible, que se
# poden a N, y que la poda no salga de su subdirectorio.
# ============================================================
_sx_v27_33_9=0

# _sx_nsc extrae de VERIFY_SRC; estas funciones están en el motor.
_sx_fnm() { sed -n "/^$1() {/,/^}/p" "$MOTOR"; }
_SX_ARC="$(_sx_fnm uki_archive_current)"
if [ -n "$_SX_ARC" ]; then
  rec ok "uki_archive_current existe y es extraíble"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "uki_archive_current no existe o no es extraíble: el UKI nuevo no se archivaría para rollback"
fi

# Sonda: stubs + la función real tal cual. `sudo` se stubea como FUNCIÓN (bash
# da prioridad a las funciones sobre el PATH), de modo que `sudo install ...`
# acaba siendo `install ...` y se puede probar sin ser root.
{
  cat <<'PROBE'
set -Eeuo pipefail
IFS=$'\n\t'
VERSION="7.2.9"; LOCALVERSION_SUFFIX="-cizen-v3"; PKGREL="${FAKEPKGREL:-1}"
CIZEN_UKI_KEEP="${FAKEKEEP:-1}"
CIZEN_UKI_KEEP_DIR="$ARCDIR"; CIZEN_UKI_KEEP_SUBDIR="auto"; CIZEN_UKI_KEEP_N="${FAKEKEEPN:-2}"
FAKE_UKI="$FAKEUKI"
ok(){ printf 'ok: %s\n' "$*"; }
warn(){ printf 'warn: %s\n' "$*"; }
info(){ :; }
sudo(){ [ "$1" = sudo ] && shift; "$@"; }
find_cizen_uki_targets(){ printf '%s\n' "$FAKE_UKI"; }
cizen_uki_efi_name(){ printf 'arch-linux-cizen-v3.efi'; }
cizen_uki_has_sig_section(){ [ -s "$1" ] || return 1; command -v objdump >/dev/null 2>&1 || return 2; objdump -h "$1" 2>/dev/null | grep -qE '[.][sS][iI][gG]'; }
if [ "${LIESTAT:-0}" = 1 ]; then
  # Miente SOLO del tamaño del origen: si mintiera también del destino, los dos
  # valores casarían y la comprobación de descuadre no vería nada.
  stat(){ local a; for a in "$@"; do if [ "$a" = "$FAKE_UKI" ]; then echo 999999; return 0; fi; done; command stat "$@"; }
fi
PROBE
  printf '%s\n' "$_SX_ARC"
  printf 'uki_archive_current\necho "RC=$?"\n'
} > "$ROOT/arc-probe.sh"

# --- B: archiva legible y con el contenido intacto ---
_ARC="$ROOT/arc"; mkdir -p "$_ARC"
_UKI="$ROOT/uki-falso.efi"
printf 'UKI-DE-PRUEBA\n%.0s' $(seq 1 500) > "$_UKI"
_out="$(ARCDIR="$_ARC" FAKEUKI="$_UKI" bash "$ROOT/arc-probe.sh" 2>&1 || true)"
_f="$(find "$_ARC/auto" -name 'uki-*.efi' 2>/dev/null | head -1)"
if [ -n "$_f" ] && [ -r "$_f" ] && [ "$(stat -c '%a' "$_f")" = 644 ] && cmp -s "$_f" "$_UKI"; then
  rec ok "archiva el UKI en auto/ con modo 644 y el contenido intacto (leible sin sudo)"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "no archiva un UKI legible e intacto en auto/ (fichero='$_f' modo=$( [ -n "$_f" ] && stat -c '%a' "$_f" 2>/dev/null || echo -)) salida: $(printf '%s' "$_out" | tr '\n' '|')"
fi
# La etiqueta debe llevar pkgrel: dos builds con el mismo uname -r son distintos
# (v27.33.7) y un rollback necesita poder distinguirlos.
if printf '%s' "$_f" | grep -q 'uki-7\.2\.9-cizen-v3-1-'; then
  rec ok "la etiqueta del archivo incluye pkgrel (uki-7.2.9-cizen-v3-1-...)"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "la etiqueta no incluye pkgrel: '$_f'. Dos builds con el mismo uname -r quedarían indistinguibles"
fi
if printf '%s' "$_out" | grep -q 'RC=0'; then
  rec ok "uki_archive_current termina en RC=0: un respaldo fallido no puede tumbar el build"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "uki_archive_current no devuelve 0 (salida: $(printf '%s' "$_out" | tr '\n' '|')): un fallo de archivado rompería el build ya instalado"
fi

# --- C: poda a N=2, quedándose con las dos más recientes ---
_ARC2="$ROOT/arc2"; mkdir -p "$_ARC2"
# Cada build escribe un UKI de prueba con un distintivo distinto, y el mtime se
# fija a mano: los tres archivos caen en el mismo segundo y la poda ordena por
# mtime, así que sin esto el test no sería determinista. El fichero de cada
# iteración se localiza por su CONTENIDO, no con 'find | head -1', que con dos
# candidatos ya no sabe cuál es el recién creado.
for i in 1 2 3; do
  printf 'build-%s\n' "$i" > "$_UKI"
  ARCDIR="$_ARC2" FAKEUKI="$_UKI" FAKEPKGREL="$i" bash "$ROOT/arc-probe.sh" >/dev/null 2>&1 || true
  _got="$(grep -l "build-$i" "$_ARC2"/auto/uki-*.efi 2>/dev/null | head -1)"
  [ -n "$_got" ] && touch -d "2026-01-0$i 00:00:00" "$_got"
done
_n="$(find "$_ARC2/auto" -name 'uki-*.efi' 2>/dev/null | wc -l)"
_keep_cur="$(grep -l 'build-3' "$_ARC2"/auto/uki-*.efi 2>/dev/null | wc -l)"
_keep_prev="$(grep -l 'build-2' "$_ARC2"/auto/uki-*.efi 2>/dev/null | wc -l)"
_gone_old="$(grep -l 'build-1' "$_ARC2"/auto/uki-*.efi 2>/dev/null | wc -l)"
if [ "$_n" -eq 2 ] && [ "$_keep_cur" -eq 1 ] && [ "$_keep_prev" -eq 1 ] && [ "$_gone_old" -eq 0 ]; then
  rec ok "poda a 2: tras tres builds quedan la anterior y la actual, y la vieja se borra"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "la poda no deja la anterior y la actual (hay $_n; actual=$_keep_cur anterior=$_keep_prev, la más vieja sigue=$_gone_old)"
fi

# --- D: la poda no toca lo que hay alrededor ---
_ARC3="$ROOT/arc3"; mkdir -p "$_ARC3/auto"
printf 'copia manual del usuario\n' > "$_ARC3/arch-linux-cizen-v3.efi"
printf 'notas\n' > "$_ARC3/auto/notes.txt"
for i in 1 2 3; do
  printf 'build-%s\n' "$i" > "$_UKI"
  ARCDIR="$_ARC3" FAKEUKI="$_UKI" FAKEPKGREL="$i" bash "$ROOT/arc-probe.sh" >/dev/null 2>&1 || true
  _g="$(find "$_ARC3/auto" -name 'uki-*.efi' | head -1)"; [ -n "$_g" ] && touch -d "2026-01-0$i" "$_g"
done
if [ -f "$_ARC3/arch-linux-cizen-v3.efi" ] && [ -f "$_ARC3/auto/notes.txt" ]; then
  rec ok "la poda no toca la copia manual de ukis/ ni un .txt dentro de auto/"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "la poda se ha comido algo del usuario: manual=$([ -f "$_ARC3/arch-linux-cizen-v3.efi" ] && echo ok || echo BORRADO) notes=$([ -f "$_ARC3/auto/notes.txt" ] && echo ok || echo BORRADO)"
fi

# --- E: copia que no cuadra con el origen -> se borra, no se deja ---
_ARC4="$ROOT/arc4"; mkdir -p "$_ARC4"
printf 'contenido\n' > "$_UKI"
_out4="$(ARCDIR="$_ARC4" FAKEUKI="$_UKI" LIESTAT=1 bash "$ROOT/arc-probe.sh" 2>&1 || true)"
if [ -z "$(find "$_ARC4" -name 'uki-*.efi' 2>/dev/null)" ] && printf '%s' "$_out4" | grep -q 'RC=0'; then
  rec ok "si el tamaño no cuadra, borra la copia en vez de dejar un backup truncado"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "deja una copia que no cuadra con el original (quedan $(find "$_ARC4" -name 'uki-*.efi' 2>/dev/null | wc -l))"
fi

# --- F: se puede desactivar ---
_ARC5="$ROOT/arc5"; mkdir -p "$_ARC5"
ARCDIR="$_ARC5" FAKEUKI="$_UKI" FAKEKEEP=0 bash "$ROOT/arc-probe.sh" >/dev/null 2>&1 || true
if [ -z "$(find "$_ARC5" -name 'uki-*.efi' 2>/dev/null)" ]; then
  rec ok "CIZEN_UKI_KEEP=0 desactiva el archivado"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "CIZEN_UKI_KEEP=0 no desactiva nada: se archivan ficheros"
fi

# --- G: un N no numérico en el entorno no rompe la poda ---
_ARC6="$ROOT/arc6"; mkdir -p "$_ARC6"
for i in 1 2 3; do
  printf 'build-%s\n' "$i" > "$_UKI"
  ARCDIR="$_ARC6" FAKEUKI="$_UKI" FAKEPKGREL="$i" FAKEKEEPN=lars bash "$ROOT/arc-probe.sh" >/dev/null 2>&1 || true
  _g="$(find "$_ARC6/auto" -name 'uki-*.efi' | head -1)"; [ -n "$_g" ] && touch -d "2026-01-0$i" "$_g"
done
if [ "$(find "$_ARC6/auto" -name 'uki-*.efi' 2>/dev/null | wc -l)" -eq 2 ]; then
  rec ok "un CIZEN_UKI_KEEP_N no numérico cae a 2 en vez de romper la aritmética"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "con CIZEN_UKI_KEEP_N='lars' quedan $(find "$_ARC6/auto" -name 'uki-*.efi' 2>/dev/null | wc -l) ficheros: la poda no sanea el valor"
fi

# --- H: regresión de uki_backup_prev, que llevaba años sin hacer nada ---
_BP="$(_sx_fnm uki_backup_prev)"
if printf '%s' "$_BP" | grep -q 'find_cizen_uki_targets "\$(cizen_uki_efi_name)"'; then
  rec ok "uki_backup_prev pasa el nombre del UKI: antes 'find -iname \"\"' no encontraba nada y no respaldaba nunca"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "uki_backup_prev sigue llamando a find_cizen_uki_targets sin nombre: el backup de /var/lib está muerto"
fi
# El motivo de cambiar `cp` por `install -m644` NO es el allowlist (cp sí está en
# §3): es que `cp` sin -p hereda el modo del origen, y el UKI del ESP es 700.
if printf '%s' "$_BP" | grep -q 'install -m644'; then
  rec ok "uki_backup_prev copia con 'install -m644': \`cp\` sin -p heredaría el 700 del UKI del ESP"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "uki_backup_prev vuelve a copiar con 'cp': la copia heredaría el modo 700 del UKI del ESP y sería ilegible"
fi
# --- I: el UKI del ESP está en un directorio 0700 root ---
# Con `[ -s "$tgt" ]` a secas, el usuario no puede ni hacer stat del fichero: el
# test da FALSO para todos los targets, el bucle no itera y la función no
# archiva NADA sin decir nada. Los tests unitarios no lo ven porque su UKI de
# mentira sí es legible; lo detectó una ejecución real contra el ESP de este
# equipo. Aquí se fija el requisito en el texto, que es lo que se puede fijar.
if printf '%s' "$_SX_ARC" | grep -q 'sudo test -s'; then
  rec ok "uki_archive_current comprueba el tamaño con 'sudo test -s': con /boot/EFI/Linux en 0700 root, un [ -s ] a secas se salta la lista entera"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "uki_archive_current usa '[ -s ]' sin sudo: con el ESP en 0700 root el test da falso y no se archiva ninguna UKI"
fi
# Y que no juzgue la firma: en esta máquina /boot es 0077 y `sbctl verify` no
# lista la UKI del ESP, así que un veredicto basedo en la sección .sig daría un
# "no arrancará" falso en cada build.
if printf '%s' "$_SX_ARC" | grep -q 'cizen_uki_has_sig_section "$dst"'; then
  rec fail "uki_archive_current juzga la firma por la sección .sig: aquí esa señal no es fiable y daría un aviso falso en cada build"
else
  rec ok "uki_archive_current no juzga la firma por la sección .sig (la verifica 'sbctl sign', un exit code que no miente)"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
fi

_sx_l_arc="$(grep -n '^[[:space:]]*uki_archive_current$' "$MOTOR" | tail -1 | cut -d: -f1)"
_sx_l_fpo="$(grep -n '^FULL_PIPELINE_OK=true$' "$MOTOR" | head -1 | cut -d: -f1)"
if [ -n "$_sx_l_arc" ] && [ "$_sx_l_arc" -lt "$_sx_l_fpo" ]; then
  rec ok "la llamada va antes de FULL_PIPELINE_OK: un respaldo fallido no ensucia el veredicto del build"
  _sx_v27_33_9=$(( _sx_v27_33_9 + 1 ))
else
  rec fail "la llamada a uki_archive_current no está antes de FULL_PIPELINE_OK (arc=$_sx_l_arc fpo=$_sx_l_fpo)"
fi

if [ "$_sx_v27_33_9" -eq 14 ]; then
  ok "v27.33.9: 14/14 pruebas del archivo local del UKI"
else
  err "v27.33.9: solo $_sx_v27_33_9/14 pruebas del archivo local del UKI"
fi

# ═══ v5.19.0: ajuste de runtime (sysctl.d + udev), el §7 del documento maestro ═══
_sx_rt=0
_rt_src="${CIZEN_TEST_RUNTIME_SRC:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/runtime}"

if [ -d "$_rt_src/sysctl.d" ] && [ -d "$_rt_src/udev" ]; then
  rec ok "runtime/: hay fuentes sysctl.d y udev que desplegar"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime/: faltan runtime/sysctl.d o runtime/udev en el repo (dir=$_rt_src)"
fi

# Los tres sysctl que el usuario decidió no tocar están medidos en
# /etc/sysctl.d/99-optimizaciones.conf. Si aparecen en el fichero nuevo, el
# despliegue los sobreescribiría y se perdería la medición que los respalda.
if ! grep -qE '^[[:space:]]*vm\.(swappiness|vfs_cache_pressure|watermark_boost_factor)[[:space:]]*=' "$_rt_src/sysctl.d/99-cizen-memory.conf" 2>/dev/null; then
  rec ok "runtime: el fichero de memoria no toca swappiness, vfs_cache_pressure ni watermark_boost_factor"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime: el fichero de memoria pisa un sysctl medido en 99-optimizaciones.conf"
fi

# La regla del documento maestro ponía queue/rotational=0 a todo sd[a-z], lo que
# habría marcado como no rotacional el Kingston DataTraveler USB (rotational=1).
# Se filtra el comentario antes de buscar: el fichero CITA la regla rota a
# propósito, para dejar escrito lo que se corrigió, y buscar en el fichero entero
# daría un falso positivo sobre su propia documentación.
_rt_rules="$(grep -vE '^[[:space:]]*(#|$)' "$_rt_src/udev/99-cizen-sata-ssd.rules" 2>/dev/null)"
if ! printf '%s' "$_rt_rules" | grep -qE 'rotational}="0"'; then
  rec ok "runtime: la regla udev no ESCRIBE rotational=0 (solo lo exige como condición)"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime: la regla udev sigue asignando rotational=0 y mentiría sobre el USB rotacional"
fi

if printf '%s' "$_rt_rules" | grep -q 'ACTION=="add|change"'; then
  rec fail "runtime: la regla udev sigue con ACTION==\"add|change\"; debe ser solo add"
else
  rec ok "runtime: la regla udev usa ACTION==\"add\" y no se re-dispara en cada cambio"
  _sx_rt=$(( _sx_rt + 1 ))
fi

# Sonda: stubs + las cuatro funciones reales tal cual, con los destinos en un
# tmpdir. `sudo` se stubea como FUNCIÓN (bash prioriza funciones sobre el PATH),
# así que se ejercita el despliegue entero sin root y sin tocar /etc.
_rt_probe() { # $1=modo (ok|sudo-falla|sin-sudo)  $2=directorio de trabajo
  local modo="$1" dir="$2"
  mkdir -p "$dir"
  {
    cat <<'PROBE'
set -Eeuo pipefail
log()  { printf 'LOG %s\n' "$*"; }
ok()   { printf 'OK  %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
info() { printf 'INFO %s\n' "$*"; }
sudo() {
  # OJO: hay que quitar '-n' y el NOMBRE del comando antes de ejecutar el resto.
  # Con un `shift` a secas y un `command install "$@"` de después salía
  # `install install -Dm644 ...`; como el motor llama a sudo con 2>/dev/null el
  # error quedaba invisible y el test informaba de un fallo del motor que era
  # del stub.
  while [ "${1:-}" = "-n" ]; do shift; done
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    install)
      if [ "$RT_MODO" = sudo-falla ]; then return 1; fi
      command install "$@"
      ;;
    sysctl|udevadm)
      if [ "$RT_MODO" = sin-sudo ]; then return 1; fi
      printf 'SUDO %s\n' "$*"
      return 0
      ;;
    *) return 0 ;;
  esac
}
PROBE
    for _fn in runtime_tuning_pairs runtime_tuning_state runtime_tuning_install deploy_runtime_tuning; do
      _sx_fnm "$_fn"
    done
    cat <<PROBE2
RT_MODO="$modo"
RUNTIME_TUNING_SRC_DIR="$_rt_src"
RUNTIME_TUNING_SYSCTL_DIR="$dir/sysctl.d"
RUNTIME_TUNING_UDEV_DIR="$dir/udev"
RUNTIME_TUNING_BACKUP_DIR="$dir/backups"
CIZEN_RUNTIME_TUNING="\${RT_TOGGLE:-1}"
PROFILE_FILE="/no/existe/perfil"
mkdir -p "\$RUNTIME_TUNING_SYSCTL_DIR" "\$RUNTIME_TUNING_UDEV_DIR"
"\${RT_ACTION:-deploy_runtime_tuning}"
PROBE2
  } > "$dir/probe.sh"
  bash "$dir/probe.sh"
}

_rt1="$ROOT/rt1"
if _rt_probe ok "$_rt1" >"$_rt1.log" 2>&1 \
   && [ -f "$_rt1/sysctl.d/99-cizen-memory.conf" ] \
   && [ -f "$_rt1/sysctl.d/99-cizen-net.conf" ] \
   && [ -f "$_rt1/udev/99-cizen-sata-ssd.rules" ] \
   && cmp -s "$_rt_src/sysctl.d/99-cizen-memory.conf" "$_rt1/sysctl.d/99-cizen-memory.conf"; then
  rec ok "runtime: despliega los 3 ficheros y el contenido llega intacto"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime: el despliegue no dejó los 3 ficheros con el contenido del repo"
fi

# Idempotencia por inode: si la segunda pasada reescribiera el fichero, el inode
# cambiaría. Comparar contenido no valdría, porque el contenido es el mismo.
_rt_inode1="$(stat -c%i "$_rt1/sysctl.d/99-cizen-net.conf" 2>/dev/null || echo 0)"
if _rt_probe ok "$_rt1" >"$_rt1.log2" 2>&1 \
   && [ "$_rt_inode1" = "$(stat -c%i "$_rt1/sysctl.d/99-cizen-net.conf" 2>/dev/null || echo 0)" ] \
   && grep -q 'sin cambios' "$_rt1.log2"; then
  rec ok "runtime: la segunda pasada no reescribe nada (mismo inode) y lo dice"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime: el despliegue no es idempotente; reescribe ficheros que ya estaban al día"
fi

# Respaldo del contenido ANTERIOR cuando el destino difiere. La aserción mira
# solo LÍNEAS ACTIVAS (`^clave=`): un grep plano de "swappiness" encuentra el
# nombre en un comentario del fichero nuevo y daría un falso negativo.
_rt2="$ROOT/rt2"
mkdir -p "$_rt2/sysctl.d"
printf 'vm.swappiness = 999\n# contenido viejo\n' > "$_rt2/sysctl.d/99-cizen-memory.conf"
if _rt_probe ok "$_rt2" >"$_rt2.log" 2>&1 \
   && grep -q 'vm.swappiness = 999' "$_rt2"/backups/*/etc"$_rt2"'/sysctl.d/99-cizen-memory.conf' 2>/dev/null \
   && ! grep -qE '^[[:space:]]*vm\.swappiness[[:space:]]*=' "$_rt2/sysctl.d/99-cizen-memory.conf"; then
  rec ok "runtime: al cambiar un destino guarda el contenido viejo en el respaldo"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime: al sobrescribir no deja copia del contenido anterior en el respaldo"
fi

# El respaldo va a /var/lib, nunca al lado del original: systemd-sysctl se come
# todo /etc/sysctl.d y un *.conf.bak con una clave vieja puede abortar el arranque.
if _rt_probe ok "$_rt2" >/dev/null 2>&1 \
   && [ -z "$(find "$_rt2/sysctl.d" "$_rt2/udev" -name '*.bak*' 2>/dev/null)" ]; then
  rec ok "runtime: no deja *.bak* dentro de /etc/sysctl.d ni de /etc/udev/rules.d"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime: el respaldo se ha escrito dentro del directorio de destino"
fi

# Desactivar por variable de entorno.
_rt3="$ROOT/rt3"
if RT_TOGGLE=0 _rt_probe ok "$_rt3" >"$_rt3.log" 2>&1 \
   && [ ! -e "$_rt3/sysctl.d/99-cizen-memory.conf" ] \
   && grep -q 'CIZEN_RUNTIME_TUNING=0' "$_rt3.log"; then
  rec ok "runtime: CIZEN_RUNTIME_TUNING=0 no escribe nada y lo dice"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime: CIZEN_RUNTIME_TUNING=0 no impide el despliegue"
fi

# sysctl y udevadm no están en el allowlist NOPASSWD de este host. El despliegue
# tiene que avisar con el comando copiable, no quedarse mudo.
_rt4="$ROOT/rt4"
if _rt_probe sin-sudo "$_rt4" >"$_rt4.log" 2>&1 \
   && grep -q 'sudo sysctl -p' "$_rt4.log" \
   && grep -q 'udevadm control --reload-rules' "$_rt4.log"; then
  rec ok "runtime: sin sudo para sysctl/udevadm avisa con el comando exacto para aplicar a mano"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime: sin permisos de sudo no da el comando para aplicar los cambios"
fi

# Nada de lo que pase al desplegar puede marcar el build como fallido.
_rt5="$ROOT/rt5"; mkdir -p "$_rt5/sysctl.d" "$_rt5/udev"
if _rt_probe sudo-falla "$_rt5" >"$_rt5.log" 2>&1; then
  rec ok "runtime: si no se puede escribir nada, deploy_runtime_tuning devuelve 0 igual"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime: un despliegue fallido devuelve error y ensuciaría el veredicto del build"
fi

# runtime_tuning_pairs: formato y cobertura de los dos destinos.
if RT_ACTION=runtime_tuning_pairs _rt_probe ok "$ROOT/rt6" 2>/dev/null \
   | grep -q "^$ROOT/rt6/udev/99-cizen-sata-ssd.rules"$'\t' ; then
  rec ok "runtime: runtime_tuning_pairs emite destino<TAB>origen para sysctl y udev"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime: runtime_tuning_pairs no emite los pares destino<TAB>origen esperados"
fi

# La llamada tiene que estar antes de FULL_PIPELINE_OK, igual que el archivado.
_rt_l_call="$(grep -nE '^[[:space:]]*deploy_runtime_tuning$' "$MOTOR" | head -1 | cut -d: -f1)"
_rt_l_fpo="$(grep -nE '^[[:space:]]*FULL_PIPELINE_OK=true$' "$MOTOR" | head -1 | cut -d: -f1)"
if [ -n "$_rt_l_call" ] && [ -n "$_rt_l_fpo" ] && [ "$_rt_l_call" -lt "$_rt_l_fpo" ]; then
  rec ok "runtime: se despliega antes de FULL_PIPELINE_OK, así no ensucia el veredicto"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime: la llamada a deploy_runtime_tuning no está antes de FULL_PIPELINE_OK (call=$_rt_l_call fpo=$_rt_l_fpo)"
fi

# Y después de instalar el paquete: si se desplegara antes, el ajuste se aplicaría
# aunque la instalación hubiera fallado.
_rt_l_pkg="$(grep -nE '^[[:space:]]*FULL_PIPELINE_OK=true$' "$MOTOR" | head -1 | cut -d: -f1)"
_rt_l_mn="$(grep -n 'pacman -S --needed\|--noconfirm' "$MOTOR" | tail -1 | cut -d: -f1)"
if [ -n "$_rt_l_mn" ] && [ -n "$_rt_l_call" ] && [ "$_rt_l_mn" -lt "$_rt_l_call" ]; then
  rec ok "runtime: se despliega después de la instalación del paquete (L$_rt_l_mn -> L$_rt_l_call)"
  _sx_rt=$(( _sx_rt + 1 ))
else
  rec fail "runtime: no se puede confirmar que el despliegue vaya tras instalar el paquete"
fi

if [ "$_sx_rt" -eq 14 ]; then
  ok "v5.19.0: 14/14 pruebas del ajuste de runtime"
else
  err "v5.19.0: solo $_sx_rt/14 pruebas del ajuste de runtime"
fi

# ═══ v5.19.0: los dos bancos de Kconfig, que son la evidencia de los 14 símbolos ═══
# El perfil v5.19.0 se justificaba con 14 símbolos de 65. Ese "de 65" sale de
# ejecutar un banco contra el Kconfig REAL, así que los bancos se versionan y se
# comprueban. Aquí NO se ejecutan de verdad ( que no necesitan 1,8 GiB de fuentes), pero sí
# se comprueba lo que un banco mal escrito haría: tragarse un error en silencio.
_sx_kc=0
for _b in kconfig-validate.sh kconfig-bench.sh; do
  _KB="$(dirname "$MOTOR")/$_b"
  if [ ! -r "$_KB" ]; then
    rec fail "bancos: falta $_b junto al motor"
    continue
  fi
  # if/then en vez de "&& rec ok || rec fail": si el brazo bueno llegara a fallar,
  # el || ejecutaría el fallo y se contaría dos veces. Es el mismo aviso que ya
  # tienen otras 157 líneas del arnés, pero aquí no hace falta añadir uno más.
  if bash -n "$_KB" 2>/dev/null; then
    rec ok "bancos: $_b pasa bash -n"; _sx_kc=$((_sx_kc+1))
  else
    rec fail "bancos: $_b no pasa bash -n"
  fi
  # Sin el árbol de fuentes tiene que salir con rc=2 y DECIR por qué. Un banco que
  # se limita a un error de "no such file" deja al usuario creyendo que su perfil
  # pasa, cuando lo único que ha comprobado es que no encuentra un directorio.
  # La salida va a $ROOT y NO a "$_KB.salida": al correr desde /usr/local el
  # directorio del motor es de root, el redirect falla antes de lanzar el banco,
  # y el test concluye que el banco no explica nada cuando lo que no pudo escribir
  # fue su propio fichero de salida.
  _rc=0
  _salida="$ROOT/$(basename -- "$_KB").salida"
  KCONFIG_SRC_DIR="$ROOT/no-existe" CIZEN_VERIFY_STATE_DIR="$ROOT/no-estado" \
    bash "$_KB" >"$_salida" 2>&1 || _rc=$?
  if [ "$_rc" -eq 2 ] && grep -q 'árbol de fuentes' "$_salida"; then
    rec ok "bancos: $_b sin fuentes sale con rc=2 explicando que hace falta el Kconfig real"
    _sx_kc=$((_sx_kc+1))
  else
    rec fail "bancos: $_b sin fuentes no explica la falta (rc=$_rc)"
  fi
done

# El fallo que estos bancos existen para evitar: `load_config_state()` del motor
# devuelve el VALOR CRUDO de un int, no un estado y/m/n. Un banco que solo mire
# y/m/n declara "missing" a HZ=1000 y da por roto un SETVAL correcto.
if grep -q 'CONFIG_\$1=' "$(dirname "$MOTOR")/kconfig-validate.sh" \
   && grep -q 'is not set' "$(dirname "$MOTOR")/kconfig-validate.sh"; then
  rec ok "bancos: kconfig-validate.sh distingue el valor crudo de un int y el 'not set' de un bool"
  _sx_kc=$((_sx_kc+1))
else
  rec fail "bancos: kconfig-validate.sh no tiene las dos reglas de estado del motor"
fi

# El banco explorador tiene que distinguir "no existe" de "Kconfig lo poda", y para
# eso necesita el conjunto de símbolos DECLARADOS, generado y cacheado (350 KB que
# no se versionan). Sin ese paso, los dos casos salen idénticos.
if grep -q 'menu)?config' "$(dirname "$MOTOR")/kconfig-bench.sh" \
   && grep -q 'NO EXISTE' "$(dirname "$MOTOR")/kconfig-bench.sh"; then
  rec ok "bancos: kconfig-bench.sh genera los símbolos declarados y separa 'no existe' de 'podado'"
  _sx_kc=$((_sx_kc+1))
else
  rec fail "bancos: kconfig-bench.sh no genera el conjunto de símbolos declarados"
fi

# La cascada de verdad es un DIFF de los dos .config, no una etiqueta sobre los
# símbolos de las listas: el banco solo toca los que están listados, así que un
# símbolo listado que se apaga lo apagó él, no su raíz. La primera versión del
# banco llamaba "cascada" justo a eso y era mentira.
if grep -q 'Efecto cascada real' "$(dirname "$MOTOR")/kconfig-bench.sh" \
   && grep -q 'EN_LISTA' "$(dirname "$MOTOR")/kconfig-bench.sh"; then
  rec ok "bancos: la cascada se mide por diff del .config, no por los símbolos listados"
  _sx_kc=$((_sx_kc+1))
else
  rec fail "bancos: la cascada sigue siendo una etiqueta y no un diff"
fi

# Las cuatro listas del documento maestro, tal cual, para que el banco siga siendo
# el banco DEL DOCUMENTO y no una lista reescrita que siempre da lo que quiere.
if grep -q 'QUOTA QFMT_V1 QFMT_V2 QUOTACTL AUTOFS_FS' "$(dirname "$MOTOR")/kconfig-bench.sh" \
   && grep -q 'SUSPEND HIBERNATION PM_SLEEP' "$(dirname "$MOTOR")/kconfig-bench.sh"; then
  rec ok "bancos: las listas del documento están transcritas, no reescritas a conveniencia"
  _sx_kc=$((_sx_kc+1))
else
  rec fail "bancos: las listas de símbolos del documento no están en el banco"
fi

# El banco NO puede descargar 1,8 GiB por su cuenta: la cabecera dice cómo traerlo
# con su sha256. Un banco que se auto-servía la red sorprendería al usuario.
if grep -q 'sha256sums.asc' "$(dirname "$MOTOR")/kconfig-validate.sh" \
   && ! grep -qE '^\s*(curl|wget)\b' "$(dirname "$MOTOR")/kconfig-bench.sh"; then
  rec ok "bancos: la cabecera explica cómo traer el árbol con su sha256, y no lo baja solo"
  _sx_kc=$((_sx_kc+1))
else
  rec fail "bancos: falta el sha256 en la cabecera o el banco se descarga las fuentes"
fi

if [ "$_sx_kc" -eq 11 ]; then
  ok "v5.19.0: 11/11 pruebas de los bancos de Kconfig"
else
  err "v5.19.0: solo $_sx_kc/11 pruebas de los bancos de Kconfig"
fi

# --- resumen ---
echo
printf 'Totales: %d ok, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]