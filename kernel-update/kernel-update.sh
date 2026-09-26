#!/usr/bin/env bash
# ============================================================
# kernel-update.sh — Cizen v27.31.2 (PRODUCCIÓN)
# Dell OptiPlex 7050 / Intel Core i5-7500 / HD 630 / Q270
# 12 GiB DDR4 / Btrfs / XFS / systemd / KVM-libvirt / QEMU-OVMF
#
# CHANGELOG: historial completo en CHANGELOG.md (raíz del repo
# cizen-code/cizen-linux-kernel-update). Desde v27.26.0 el mantenimiento
# (--changelog) escribe el borrador en ese archivo; la cabecera del motor
# ya no acumula el historial y queda para la doc breve (OBJETIVOS/USO).
#
# OBJETIVOS
#   - Mantener la lógica Cizen existente.
#   - Ser idempotente: repetir el mismo comando no debe degradar el estado.
#   - Usar Cizen como base y /proc/config.gz como fallback.
#   - Aplicar solo poda razonablemente segura para este hardware.
#   - Dejar que Kconfig resuelva dependencias.
#   - Auditar listnewconfig + olddefconfig.
#   - Distinguir FATAL / WARNING / REBELDE ESPERADO.
#   - No permitir --force para saltarse errores críticos.
#   - Evitar instalar un paquete viejo por error.
#   - Conservar el tarball y el estado de trabajo útil si la compilación falla; no generar logs/reportes persistentes fuera del árbol de trabajo.
#   - No crear backups persistentes de .config; la única configuración estable
#     persistente es $CONFIG_DIR/linux-<versión>-cizen-v3.config, promovida atómicamente.
#   - Cargar y validar siempre el perfil externo, pero no repetir su resumen si no cambió.
#   - Limpiar el cache persistente de kernel para conservar únicamente el tarball y su firma de la versión objetivo, eliminando artefactos antiguos y residuos de descarga.
#   - Mantener en el tmpfs de compilación únicamente el árbol de fuentes de la versión objetivo más reciente.
#   - Mantener en el cache persistente solo el tarball/firma de la versión más nueva y eliminar residuos .bad/.download/.partial.
#   - Mantener en el tmpfs de compilación solo el árbol de fuentes de la versión más nueva.
#   - No crear archivos auxiliares .base.config/.newconfig/.olddefconfig/.diffconfig.
#     Las salidas de Kconfig se mantienen en memoria; no se generan reportes auxiliares.
#   - Mostrar únicamente cambios reales del perfil desde la última ejecución registrada.
#   - Tampoco repetir los conteos del perfil en la fase "Preparando" si no hubo cambios.
#
# USO
#   ./kernel-update.sh [versión]
#   kcheck [versión]              # alias/enlace al mismo script; sin versión usa stable actual
#   kbuild [versión]              # alias/enlace al mismo script; sin versión usa autodetección
#   ./kernel-update.sh --check-update
#   ./kernel-update.sh [versión] --check
#     Tras validar y confirmar la compilación, pregunta la variante del
#     scheduler: 1) Vanilla (EEVDF estándar) o 2) BORE (Burst-Oriented
#     Response Enhancer). Aplica igual en check/checkfast del menú.
#   ./kernel-update.sh <versión> --strict
#   ./kernel-update.sh <versión> --absorb-rebels
#     Si la auditoría reporta desactivaciones que Kconfig conserva, el check
#     preguntará antes de compilar si absorberlas a EXPECTED_REBELS (v27.25.1).
#     --absorb-rebels lo hace siempre de forma incondicional.
#   ./kernel-update.sh <versión> --force
#   ./kernel-update.sh <versión> --keep-src
#   ./kernel-update.sh <versión> --no-prune                  # sin poda de módulos
#   El modo lite es el ÚNICO modo de compilación (v27.25.4): la config siempre
#   se adelgaza con make localmodconfig (módulos cargados + allowlist del podador);
#   no existe --no-lite ni CIZEN_LITE. El paquete se poda igual siempre.
#   CIZEN_KEEP_MODULES="kvm_intel,vfio_pci" ./kernel-update.sh <versión>  # módulos extra a conservar en la poda
#   CIZEN_KEEP_TMPFS=1 ./kernel-update.sh <versión>        # conservar el tmpfs tras éxito (defecto: se desmonta)
#   CIZEN_SMART_UMOUNT=0 ./kernel-update.sh <versión>       # no desmontar el tmpfs aunque no sirva su árbol
#     v27.31.17: antes de compilar, los árboles del tmpfs que no corresponden a
#     este build (otra versión, o vanilla<->cachyos según el parche/scheduler)
#     se descartan siempre; si no queda ninguno aprovechable, el tmpfs se
#     DESMONTA entero para devolver la RAM y se vuelve a montar limpio.
#     CIZEN_SMART_UMOUNT=0 (o CIZEN_KEEP_TMPFS=1) los purga sin desmontar.
#   ./kernel-update.sh <versión> --patch bore                 # framework de parches
#   ./kernel-update.sh <versión> --bore                       # alias de --patch bore
#   CIZEN_PATCHES="bore" ./kernel-update.sh <versión>         # parches por env
#   ./kernel-update.sh <versión> --no-btf                     # sin CONFIG_DEBUG_INFO_BTF (opt-out; default: BTF=y)
#   ./kernel-update.sh <versión> --clang                      # build LLVM/clang (opt-in)
#   ./kernel-update.sh <versión> --cc gcc-14                  # tu compilador: auto|gcc|clang|versión (gcc-14, clang-17)|rutas
#   ./kernel-update.sh <versión> --tree auto|vanilla|cachyos  # árbol de fuentes: auto (pds/bmq/lfbmq/muqss -> fork CachyOS) | vanilla | cachyos
#   ./kernel-update.sh <versión> --menuconfig                 # editar config con menuconfig
#   ./kernel-update.sh [versión] --publish-repo               # publicar pkg a repo pacman local
#   CIZEN_PUBLISH_REPO=/srv/repo ./kernel-update.sh <versión> # dónde publicar (default /var/lib/kernel-update/repo)
#   ./kernel-update.sh --selftest                             # autoevaluación interna
#   ./kernel-update.sh --hardened                             # auditoría hardening del kernel en ejecución
#   ./kernel-update.sh --changelog                            # bump versión + borrador en CHANGELOG.md
#   CIZEN_BOOT_TRIES=3 ./kernel-update.sh <versión>           # boot counting sd-boot (0 = UKI plana)
#   ./kernel-update.sh <versión> --sign                       # firmar la UKI con sbctl (Secure Boot)
#   ./kernel-update.sh <versión> --no-sign                    # NO firmar la UKI (evitar con Secure Boot activo)
#   CIZEN_SIGN_UKI=auto ./kernel-update.sh <versión>          # firma de la UKI con sbctl (auto|yes|no; default auto)
#     auto: sbctl es dependencia OBLIGATORIA (se ofrece autoinstalarlo) y al
#     confirmar la compilación (build o recompilación) se sugiere firmar la UKI
#     (S/n). Si la aceptas o la rechazas, la decisión se RECUERDA para los
#     siguientes builds (en modo auto no vuelve a preguntar; reversa con --sign /
#     --no-sign o CIZEN_SIGN_UKI=yes|no). Con Secure Boot ACTIVO en el firmware
#     la UKI se firma SIEMPRE: sin firma el sistema no arrancaría. Al aceptar la
#     firma se abre el SETUP GUIADO de Secure Boot: genera las claves
#     (sbctl create-keys), firma systemd-boot y matricula las claves en la BIOS
#     (sbctl enroll-keys, con reintento automático con --microsoft si sbctl exige
#     flag por falta de TPM Eventlog — TPM deshabilitado o ausente), preguntando solo lo
#     que queda pendiente, pregunta a pregunta (S/n).
#   CIZEN_PATCH_SHA256_VERIFY=0 ./kernel-update.sh <versión>  # desactivar pin SHA256 de los parches
#   JOBS=3 ./kernel-update.sh <versión>
#   CIZEN_DOWNLOAD_PARALLEL=8 ./kernel-update.sh <versión>   # conexiones paralelas (aria2c)
#   CIZEN_DOWNLOADER=wget ./kernel-update.sh <versión>       # fuerza el wget clásico
#   CIZEN_NO_AUTOINSTALL=1 ./kernel-update.sh <versión>      # sin prompts de instalación
#   KERNEL_BUILD_ROOT=/tmp/kbuild ./kernel-update.sh <versión>
#   ./kernel-update.sh --save-auto-renames   # persiste los renombres detectados
#   ./kernel-update.sh --rename VIEJO=NUEVO
#   ./kernel-update.sh --list-renames
#   CIZEN_KERNEL_TRACK=longterm ./kernel-update.sh   # seguir LTS mayor en vez de stable
#   CIZEN_SNAPSHOT=0 ./kernel-update.sh              # sin snapshot btrfs previo
#   CIZEN_ROLLBACK_DIR=/ruta ./kernel-update.sh      # dónde guardar el archivo de rollback
#   CIZEN_VERIFY_STATE_DIR=/ruta                     # estado del verificador post-boot
#
# NOTAS DE PRODUCCIÓN
#   - --force NO ignora fallos críticos ni de auditoría Kconfig. Su único
#     efecto es permitir reinstalar un pkgrel igual o menor al ya instalado
#     (ver el chequeo de INSTALLED_VERSION más abajo).
#   - --keep-src no tiene efecto: las fuentes siempre se conservan en el
#     tmpfs entre ejecuciones para reutilizarse. Se mantiene por
#     compatibilidad con invocaciones existentes.
#   - Usa un tmpfs anidado de 10 GiB bajo /tmp para el árbol de compilación; el montaje /tmp existente se respeta.
#   - Si el árbol objetivo ya existe, usa KERNEL_TMPFS_EXISTING_SRC_MIN_FREE_MB
#     (2048 MB por defecto) como margen incremental para reutilización.
#   - El chequeo de espacio del tmpfs en check_build_memory solo aplica si el
#     tmpfs de build ESTÁ montado (`df` sobre un punto sin montar leería el /tmp
#     padre, ~5,8G, y falsearía "espacio insuficiente"); en frío, prepare_tmpfs_build
#     lo monta de 10G y valida su espacio. Si el tmpfs arrastra el árbol de una
#     ejecución anterior y no llega al mínimo de espacio libre, se libera solo:
#     purga los artefactos re-generables del enlace (vmlinux*/System.map) y
#     elimina los árboles huérfanos de otras versiones antes de abortar.
#   - Mantiene el timestamp sudo durante builds largas sin pedir contraseña en
#     segundo plano; si el ticket caduca, el keep-alive se detiene de forma segura.
#   - El tmpfs de build usa exec (necesario para generar/ejecutar herramientas host); /tmp del sistema sigue noexec.
#   - Kconfig es la autoridad final sobre dependencias.
#   - KVM_SMM es crítico para el uso QEMU/OVMF del equipo.
#   - LOCK_FILE es deliberadamente global y NO se deriva de KERNEL_BUILD_ROOT:
#     solo puede instalarse un kernel a la vez en este sistema, sin importar
#     con qué KERNEL_BUILD_ROOT se haya lanzado cada ejecución.
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Salida de herramientas predecible para validaciones y logs.
export LC_ALL=C

SCRIPT_VERSION="27.31.29"
PROFILE="cizen-optiplex7050"
LOCALVERSION_SUFFIX="-cizen-v3"
# Nombre del paquete Arch y pkgbase Cizen. El KERNELRELEASE seguirá siendo
# VERSION-cizen-v3; este pkgbase es el que mkinitcpio usa para nombrar el preset.
CIZEN_PKGBASE="linux-cizen-v3"
LEGACY_PKGBASE="linux-upstream"

RENAME_MAP_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/kernel-update/rename-map.conf"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# Config base persistente (linux-<versión>-cizen-v3.config): por defecto junto
# a los perfiles, dentro de la propia suite. Debe ser escribible por el usuario
# que compila (se promueve tras un build/check exitoso).
CONFIG_DIR="${CIZEN_CONFIG_DIR:-$SCRIPT_DIR/profiles}"
PROFILE_FILE=""

# El perfil es externo al motor. Buscamos primero la ubicación explícita y
# después las ubicaciones estándar de una instalación manual o empaquetada.
PROFILE_CANDIDATES=(
  "${CIZEN_PROFILE_FILE:-}"
  "$SCRIPT_DIR/profiles/cizen-optiplex7050.conf"
  "$SCRIPT_DIR/cizen-optiplex7050.conf"
  "$HOME/.config/kernel-update/profiles/cizen-optiplex7050.conf"
  "$HOME/.config/kernel-update/cizen-optiplex7050.conf"
)
for _candidate in "${PROFILE_CANDIDATES[@]}"; do
  if [ -n "$_candidate" ] && [ -f "$_candidate" ]; then
    PROFILE_FILE="$_candidate"
    break
  fi
done
unset _candidate
# KERNEL_BUILD_ROOT sigue siendo la raíz persistente para el tarball/cache.
# El árbol de compilación se coloca durante la ejecución en un tmpfs dedicado.
KERNEL_BUILD_ROOT="${KERNEL_BUILD_ROOT:-$HOME/.cache/kernel-kbuild}"
# /tmp ya es tmpfs en este sistema, pero está montado noexec. Creamos un
# tmpfs hijo con exec exclusivamente para el árbol de compilación.
TMPFS_SIZE="${KERNEL_TMPFS_SIZE:-10G}"
TMPFS_MIN_FREE_MB="${KERNEL_TMPFS_MIN_FREE_MB:-4096}"
TMPFS_EXISTING_SRC_MIN_FREE_MB="${KERNEL_TMPFS_EXISTING_SRC_MIN_FREE_MB:-2048}"
TMPFS_ROOT="${KERNEL_TMPFS_ROOT:-/tmp/cizen-kernel-build}"
TMPFS_MOUNTED=false
TMPFS_CREATED_BY_SCRIPT=false
# Tras el flujo completo exitoso (compilación + instalación + UKI) el tmpfs ya
# no tiene motivo de existir y se desmonta. CIZEN_KEEP_TMPFS=1 conserva el
# comportamiento anterior (reutilización del árbol entre ejecuciones).
CIZEN_KEEP_TMPFS="${CIZEN_KEEP_TMPFS:-0}"
# v27.31.19: resultado del desmontaje de fin de build para el informe final.
TMPFS_UMOUNT_STATUS=""
TMPFS_UMOUNT_NOTE=""
# Desmontaje inteligente (v27.31.17). El directorio del árbol solo lleva la
# versión (linux-X.Y.Z), de modo que un vanilla conservado y un build del fork
# pueden acabar en el mismo camino y "reutilizarse" sin que se note (los
# parches -cachy no aplican y el kernel compilado no es el pedido). Al arrancar
# se reconcilia el tmpfs con lo que este build va a compilar (versión + tipo,
# y el tipo depende del parche/scheduler elegido). Lo que no sirve se descarta
# y, si no queda nada aprovechable, se DESMONTA el tmpfs entero para devolver
# la RAM de golpe y montar limpio. CIZEN_SMART_UMOUNT=0 desactiva solo el
# desmontaje (los árboles incompatibles se siguen descartando, no mezclando).
CIZEN_SMART_UMOUNT="${CIZEN_SMART_UMOUNT:-1}"
# Testigo de identidad de cada árbol extraído (version + kind). Los árboles
# anteriores a v27.31.17 no lo tienen: se deducen del propio árbol.
TREE_META_NAME=".cizen-tree"
# Motivo por el que KERNEL_TREE no es "vanilla" (lo rellena
# resolve_kernel_tree), para explicar los descartes con el parche concreto.
TREE_FORCE_NOTE=""
# Se marca solo al terminar el pipeline completo con éxito (instalación + UKI
# sincronizada); los flujos parciales (p. ej. solo check) no desmontan.
FULL_PIPELINE_OK=false
# Deliberadamente NO derivado de $KERNEL_BUILD_ROOT: el lock es global a
# propósito, porque solo puede instalarse un kernel a la vez en este
# sistema sin importar con qué KERNEL_BUILD_ROOT se lance cada ejecución.
LOCK_FILE="${KERNEL_UPDATE_LOCK:-$HOME/.cache/kernel-kbuild/kernel-update.lock}"

VERSION=""
PKGREL=""
PKGVER_BASE=""
CHECK_ONLY=false
FORCE=false
STRICT=false
ABSORB_REBELS=false
KEEP_SRC=false
BORE_ENABLED=false
DO_RENAME=false
RENAME_PAIR=""
DO_LIST=false
CHECK_UPDATE=false

# Poda de módulos (v27.25.0): tras empaquetar, se conservan únicamente los
# módulos que este hardware usa (ver podar-modulos.sh). 1=activada (default),
# 0=desactivada. La env CIZEN_PRUNE_MODULES también la controla; el flag
# --no-prune/--prune tiene prioridad (se procesan después de esta lectura).
PRUNE_MODULES="${CIZEN_PRUNE_MODULES:-1}"

# Modo lite (v27.25.2): desde v27.25.4 es el ÚNICO modo de compilación de esta
# suite. make localmodconfig reduce la config para NO compilar los módulos que
# la poda descartaría, acortando el build. No hay toggle ni escape hatch.

# ── Framework de parches, BTF, clang y utilidades (v27.24.0) ──
# PATCH_NAMES: lista de parches de terceros solicitados (--patch / CIZEN_PATCHES
# / --bore). PATCHES_APPLIED: los que realmente se aplicaron en este run.
PATCH_REQUESTED=false
declare -a PATCH_NAMES=()
declare -a PATCHES_APPLIED=()
# Símbolos Kconfig que aportan los parches aplicados y BTF: entran en ENABLE y
# se reconocen como rebeldes esperados (no ensucian la auditoría ni --strict).
declare -a PATCH_ENABLE_ALL=() PATCH_REBEL_ALL=()
# v27.31.28: símbolos que aporta un parche pero NO son booleanos (int/hex/string).
# No se fuerzan a "=y": se dejan al valor que declara el propio parche.
declare -a PATCH_VALUE_SYMBOLS=()
# Símbolos que un parche obliga a DESACTIVAR para fijar una "choice" Kconfig
# (p. ej. elegir SCHED_PDS exige CONFIG_SCHED_BMQ=n). Selectores de scheduler.
declare -a PATCH_DISABLE_ALL=()
# Símbolos que un scheduler alternativo (SCHED_ALT) RETIRA del kernel: su
# Kconfig los hace imposibles (`depends on !SCHED_ALT`). Si el perfil los
# exigía (CRITICAL/SETVAL/ENABLE), build_effective_arrays los excluye de la
# exigencia y la validación los reporta como retirados por diseño del parche.
declare -a PATCH_RETIRED_ALL=()
declare -A PATCH_KCONFIG_FILTER=()   # símbolos nuevos esperados de parches/BTF
# BTF por defecto activo (el perfil lo trae =y): systemd/bpf-restrict-fs lo
# necesita. Se desactiva con --no-btf / CIZEN_NO_BTF=1.
BTF_REQUESTED=true
CLANG_REQUESTED=false
MENUCONFIG_REQUESTED=false
SELFTEST=false
DO_CHANGELOG=false
HARDENED_AUDIT=false
PUBLISH_REPO=false
PUBLISH_REPO_DIR=""
PUBLISH_REPO_MSG=""

# Firma de la UKI con sbctl (Secure Boot, v27.29.3). auto (default): si sbctl
# está instalado se sugiere firmar al confirmar la compilación; con Secure Boot
# activo se firma siempre (una UKI sin firmar no arrancaría). La última decisión
# explícita (sí/no en el prompt) se RECUERDA en
# ${XDG_STATE_HOME:-$HOME/.local/state}/kernel-update/sign-uki.state y se
# reutiliza en los siguientes builds sin volver a preguntar. Al aceptar la firma
# se abre el setup guiado (create-keys / enroll-keys / systemd-boot) para dejar
# la cadena Secure Boot lista. Override por env CIZEN_SIGN_UKI=yes|no|auto; los
# flags --sign/--no-sign (más abajo) tienen prioridad.
SIGN_UKI="${CIZEN_SIGN_UKI:-auto}"
DO_SIGN_UKI=false
SBCTL_BIN="$(command -v sbctl 2>/dev/null || true)"
SIGN_UKI_REASON=""
# Estado recordado de la decisión de firma (no requiere root; ~/.local/state).
SIGN_UKI_STATE_DIR="${CIZEN_SIGN_UKI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/kernel-update}"
SIGN_UKI_STATE_FILE="$SIGN_UKI_STATE_DIR/sign-uki.state"

# Rama de kernel.org a seguir: stable (default) o longterm/LTS mayor.
CIZEN_KERNEL_TRACK="${CIZEN_KERNEL_TRACK:-stable}"
[ "$CIZEN_KERNEL_TRACK" = "longterm" ] || [ "$CIZEN_KERNEL_TRACK" = "lts" ] || [ "$CIZEN_KERNEL_TRACK" = "stable" ] \
  || fatal "CIZEN_KERNEL_TRACK inválido: $CIZEN_KERNEL_TRACK (use stable, longterm o lts)."

# Rollback dual-kernel: directorio (root) donde se archiva el kernel previo al instalar.
ROLLBACK_DIR="${CIZEN_ROLLBACK_DIR:-/var/lib/kernel-update/rollback}"
# Además del archive de ficheros, se preserva el PAQUETE del kernel instalado
# (rollback.info + un .pkg.tar.zst). Es lo que permite volver atrás con pacman -U
# en vez de dejar la base de datos mintiendo sobre qué kernel hay instalado.
ROLLBACK_PKG_ENABLED="${CIZEN_ROLLBACK_PKG:-1}"
ROLLBACK_MANIFEST="$ROLLBACK_DIR/rollback.info"
ROLLBACK_PKG_FILE=""
# Los helpers de la suite viven en /usr/local/bin/kernel-update/ y NO están en el
# PATH (por diseño: no se mezclan con otras herramientas). Los mensajes que
# invocan krollback llevan la ruta entera, o el usuario no puede copiarlos.
KROLLBACK_SCRIPT="${CIZEN_KROLLBACK_SCRIPT:-/usr/local/bin/kernel-update/kernel-update-rollback.sh}"
# Snapshot btrfs readonly de la raíz antes de instalar: 1=auto (si / es btrfs), 0=off.
CIZEN_SNAPSHOT="${CIZEN_SNAPSHOT:-1}"
SNAPSHOT_SUBVOL=".snapshots"
# Estado del verificador post-boot (firma del build, tiempos).
VERIFY_STATE_DIR="${CIZEN_VERIFY_STATE_DIR:-$HOME/.local/state/kernel-update}"

# Marcas de tiempo de las fases para el informe final (feature 7).
T_ALL=0; T_DL=0; T_CFG=0; T_END=0

# Modo invocado por nombre: permite que kcheck/kbuild sean simples enlaces
# al mismo motor, sin wrappers que obliguen a pasar una versión.
COMMAND_NAME="$(basename -- "$0")"
case "$COMMAND_NAME" in
  kcheck) CHECK_ONLY=true ;;
  kbuild) CHECK_ONLY=false ;;
esac

calc_default_jobs() {
  local cpus ram_kb ram_gb ram_jobs
  cpus="$(nproc)"
  ram_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  ram_gb=$((ram_kb / 1024 / 1024))
  ram_jobs=$((ram_gb / 2))
  [ "$ram_jobs" -ge 1 ] || ram_jobs=1
  [ "$ram_jobs" -lt "$cpus" ] && echo "$ram_jobs" || echo "$cpus"
}
JOBS="${JOBS:-$(calc_default_jobs)}"

# MAKEFLAGS global: todos los sub-makes (menú, headers, modules, pkg)
# heredan la misma paralelidad que el make principal.
export MAKEFLAGS="-j$JOBS"

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

# Reducir la prioridad de CPU/I/O del build para mantener el escritorio usable.
# CIZEN_BUILD_PRIORITY=normal salta nice/ionice y compila a plena prioridad:
# la compilación del kernel es CPU-bound, por lo que nice/ionice solo
# alargan el build (~20-40%) sin beneficio si la máquina está seca.
# CIZEN_BUILD_PRIORITY lo define el usuario ANTES de ejecutar (export).
BUILD_PRIORITY="${CIZEN_BUILD_PRIORITY:-low}"
case "$BUILD_PRIORITY" in normal) BUILD_PRIORITY_LABEL="máxima" ;; *) BUILD_PRIORITY_LABEL="$BUILD_PRIORITY" ;; esac
if [ "$BUILD_PRIORITY" = "normal" ]; then
  declare -a BUILD_PRIORITY_WRAP=()
  info "Compilación a plena prioridad (máxima velocidad; sin nice/ionice)"
else
  declare -a BUILD_PRIORITY_WRAP=()
  if command -v nice >/dev/null 2>&1; then
    BUILD_PRIORITY_WRAP+=(nice -n 10)
  fi
  if command -v ionice >/dev/null 2>&1; then
    BUILD_PRIORITY_WRAP+=(ionice -c 3)
  fi
fi

# ============================================================
# PERFIL DE COMPILACIÓN EXTENDIDO  —  v27.30.0
# Compilador, optimización, scheduler, frags, modprobed-db, empaquetado y
# firma de módulos. Los defaults NO son invasivos ("inherit"/0/auto): no
# tocan el perfil cizen salvo que el usuario lo pida explícitamente.
# ============================================================
# Compilador de preferencia: auto (clang si LTO pedido o ya instalado previo;
# si no gcc) | gcc | clang | versión (gcc-14, clang-17) | binario/ruta (la
# familia la decide el basename). --clang == clang. Elegir un compilador lo
# vuelve OBLIGATORIO: si falta, check_prerequisites lo ofrece e instala igual
# que cualquier dependencia (nunca degrada a gcc ni cambia tu elección).
CIZEN_CC="${CIZEN_CC:-auto}"
CC_FAMILY=gcc
CC_LAUNCHER=gcc
# LTO únicamente con clang: 0=off (default), 1|thin=CONFIG_LTO_CLANG_THIN,
# full=CONFIG_LTO_CLANG_FULL.
CIZEN_LLVM_LTO="${CIZEN_LLVM_LTO:-0}"
# Nivel de optimización de los archivos C: inherit (respetar perfil) | 2 | 3.
# Se materializa en el par de CONFIG CC_OPTIMIZE_FOR_PERFORMANCE/O3 (choice).
CIZEN_CFLAGS_OLEVEL="${CIZEN_CFLAGS_OLEVEL:-inherit}"
# Arquitectura objetivo: inherit (sin -march extra) | generic | native | <march>.
# Se añade a KCFLAGS (afecta a los .c del kernel; -march=x86-64 en generic).
CIZEN_CPU_OPT="${CIZEN_CPU_OPT:-inherit}"
# Frecuencia del timer (override de CONFIG_HZ del perfil): inherit | 100|250|300|500|1000.
CIZEN_TIMER_FREQ="${CIZEN_TIMER_FREQ:-inherit}"
# Scheduler de compilación: inherit | eevdf (vanilla) | bore | pds | bmq | lfbmq | muqss.
CIZEN_SCHED="${CIZEN_SCHED:-inherit}"
# v27.31.28: la pregunta interactiva de variante (choose_build_variant_after_check)
# es el último recurso para quien llama al motor por CLI. Si quien llama ya la
# hizo (el menú), se desactiva con --no-ask-variant.
NO_ASK_VARIANT="${NO_ASK_VARIANT:-false}"
# Árbol de fuentes del kernel: auto (vanilla salvo que un scheduler seleccionado
# exija el fork CachyOS) | vanilla (kernel.org) | cachyos (fork CachyOS/linux).
# Los schedulers PRJC (pds/bmq/lfbmq) y MuQSS solo se publican como parches
# -cachy que aplican sobre el árbol del fork, NO sobre la release vanilla.
CIZEN_KERNEL_TREE="${CIZEN_KERNEL_TREE:-auto}"
# Sincronización Wine (ntsync/fsync): ntsync en mainline >= 6.10 como CONFIG
# NTSYNC; para < 6.10 se intenta el parche de CachyOS (--patch ntsync). fsync
# legacy (serie futex_waitv) solo tiene sentido < 6.14 y es excluyente con
# ntsync; por defecto 0.
CIZEN_PATCH_NTSYNC="${CIZEN_PATCH_NTSYNC:-auto}"
CIZEN_PATCH_FSYNC="${CIZEN_PATCH_FSYNC:-0}"
# Pack misc de CachyOS (best-effort, cada parche fail-soft). Set editable vía
# CIZEN_CACHY_PATCH_SET (nombres separados por espacio entre los soportados).
# Default verificado para árbol vanilla 7.x: 'acpi-call'. nap-governor y
# reflex-governor fueron retirados del stack CachyOS (2026-09: no existen en
# CachyOS/kernel-patches ni en los PKGBUILD de linux-cachyos).
CIZEN_CACHY_PATCHES="${CIZEN_CACHY_PATCHES:-0}"
CIZEN_CACHY_PATCH_SET="${CIZEN_CACHY_PATCH_SET:-acpi-call}"
# Símbolos Kconfig que los parches misc introducen; apply_cachy_misc_symbols los
# re-habilita tras perfil+frags para que sobrevivan a la config lite.
declare -a CACHY_MISC_SYMBOLS=()
# Parches propios del usuario: directorio con .patch/.diff que se aplican tras
# los de terceros. Un fallo aquí es fatal (responsabilidad del usuario).
CIZEN_USER_PATCHES_DIR="${CIZEN_USER_PATCHES_DIR:-}"
# Frags de configuración reutilizables (.frag). Default: $CONFIG_DIR/frags.
CIZEN_FRAGS_DIR="${CIZEN_FRAGS_DIR:-$CONFIG_DIR/frags}"
# Modprobed-db: 0=off, 1=auto-descubrimiento (default), o ruta a la bbdd.
# Alimenta make localmodconfig con el historial persistente de módulos.
CIZEN_MODPROBED_DB="${CIZEN_MODPROBED_DB:-1}"
# Empaquetado multi-backend (v27.30.0): arch (default) | deb | rpm | generic | gentoo.
CIZEN_PKG_BACKEND="${CIZEN_PKG_BACKEND:-arch}"
# Firma persistente de módulos estilo MOK: no (default) | yes. Las claves viven
# en CIZEN_MODULE_SIGN_DIR (enrollment del MOK documentado en README).
CIZEN_MODULE_SIGN="${CIZEN_MODULE_SIGN:-no}"
CIZEN_MODULE_SIGN_DIR="${CIZEN_MODULE_SIGN_DIR:-/etc/cizen/kernel-sign}"
# Backup del UKI anterior en cada sincronización: 1 (default) | 0.
CIZEN_UKI_BACKUP="${CIZEN_UKI_BACKUP:-1}"
CIZEN_UKI_BACKUP_DIR="${CIZEN_UKI_BACKUP_DIR:-/var/lib/kernel-update/uki-backups}"
# Auditoría LUKS/FDE en cada build (integración; avisa si el root cifrado
# carece del parámetro cryptdevice/rd.luks). No cifra nada en el arranque.
CIZEN_LUKS_AUDIT="${CIZEN_LUKS_AUDIT:-0}"

# Guarda OOM pre-build: aborta pronto y con mensaje claro si no hay memoria
# suficiente (el enlace con BTF es el punto más hambriento, ver historial de
# OOM al compilar con DEBUG_INFO_BTF) o si el tmpfs de compilación ya montado
# no tiene espacio libre. Umbrales superables por env.
# El chequeo del tmpfs SOLO se hace si el tmpfs de build está efectivamente
# montado: si no lo está (arranque de sesión), `df -Pk $TMPFS_ROOT` devolvería
# las estadísticas del /tmp padre (5,8G en este sistema) y daría un falso
# "espacio insuficiente" cuando todavía no hay nada que limpiar. En ese caso
# prepare_tmpfs_build lo monta de 10G y valida su propio espacio.
# Si el tmpfs arrastra árboles/artefactos de una ejecución anterior, primero
# se intenta liberar (liberate_tmpfs_space) y con el árbol de esta versión ya
# reutilizable se aplica el margen incremental TMPFS_EXISTING_SRC_MIN_FREE_MB,
# coherente con prepare_tmpfs_build.
CIZEN_BUILD_MIN_MEM_MB="${CIZEN_BUILD_MIN_MEM_MB:-8192}"
CIZEN_BUILD_MIN_TMPFS_MB="${CIZEN_BUILD_MIN_TMPFS_MB:-6144}"
CIZEN_BUILD_MIN_MEM_BTF_MB="${CIZEN_BUILD_MIN_MEM_BTF_MB:-12288}"
CIZEN_BUILD_MIN_TMPFS_BTF_MB="${CIZEN_BUILD_MIN_TMPFS_BTF_MB:-8192}"
check_build_memory() {
  local min_mem min_tmp min_tmp_used avail swapfree mem free_mb
  if [ "$BTF_REQUESTED" = true ]; then
    min_mem="${CIZEN_BUILD_MIN_MEM_BTF_MB}"; min_tmp="${CIZEN_BUILD_MIN_TMPFS_BTF_MB}"
  else
    min_mem="${CIZEN_BUILD_MIN_MEM_MB}"; min_tmp="${CIZEN_BUILD_MIN_TMPFS_MB}"
  fi
  avail="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  swapfree="$(awk '/^SwapFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  mem=$(( (avail + swapfree) / 1024 ))
  if [ "$mem" -lt "$min_mem" ]; then
    fatal "Memoria insuficiente para el build (BTF=$BTF_REQUESTED): MemAvailable+SwapFree=${mem} MB < ${min_mem} MB. Cierra aplicaciones o ajusta CIZEN_BUILD_MIN_MEM_MB (o _BTF_MB)."
  fi
  if tmpfs_is_mounted; then
    free_mb="$(df -Pk "$TMPFS_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
    [ -n "$free_mb" ] && free_mb=$((free_mb / 1024))
    if [ -n "$free_mb" ] && [ "$free_mb" -lt "$min_tmp" ]; then
      # El tmpfs guarda el árbol de la ejecución anterior: en vez de abortar, se
      # intenta liberar espacio (purgar artefactos regenerables del enlace del
      # árbol de esta versión + eliminar árboles huérfanos de versiones
      # distintas) y se vuelve a medir. Evita el bloqueo clásico: el árbol del
      # propio 7.2.7 (~4-5 GB) deja el tmpfs de 10G por debajo del mínimo BTF.
      info "tmpfs de build escaso (${free_mb} MB libres < ${min_tmp} MB mínimos); liberando espacio del árbol anterior…"
      liberate_tmpfs_space
      free_mb="$(df -Pk "$TMPFS_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
      [ -z "$free_mb" ] || free_mb=$((free_mb / 1024))
      # Si queda el árbol de esta versión se reutiliza: basta el margen
      # incremental de reutilización (2048 MB), el mismo que aplica
      # prepare_tmpfs_build para ese caso exacto. El margen de build completo
      # (min_tmp) solo se exige cuando no hay nada reutilizable y hay que
      # extraer un árbol nuevo desde cero.
      if source_tree_reusable; then
        min_tmp_used="$TMPFS_EXISTING_SRC_MIN_FREE_MB"
      else
        min_tmp_used="$min_tmp"
      fi
      if [ -z "$free_mb" ] || [ "$free_mb" -lt "$min_tmp_used" ]; then
        fatal "Espacio libre insuficiente en el tmpfs de build ($TMPFS_ROOT): ${free_mb:-?} MB < ${min_tmp_used} MB (árbol reutilizable=$(source_tree_reusable && echo sí || echo no)). Tras purgar los artefactos regenerables sigue lleno: el desmontaje automático no ha podido (CIZEN_SMART_UMOUNT=0, CIZEN_KEEP_TMPFS=1 o tmpfs en uso); hazlo a mano (sudo umount $TMPFS_ROOT) o ajusta CIZEN_BUILD_MIN_TMPFS_MB (o _BTF_MB)."
      fi
      ok "Espacio del tmpfs liberado tras limpieza: ${free_mb} MB libres (mín ${min_tmp_used} MB)."
    fi
  fi
  if tmpfs_is_mounted; then
    ok "Build memory ok (BTF=$BTF_REQUESTED): MemAvailable+SwapFree=${mem} MB (mín ${min_mem} MB), tmpfs libre=${free_mb:-?} MB (mín ${min_tmp} MB)."
  else
    ok "Build memory ok (BTF=$BTF_REQUESTED): MemAvailable+SwapFree=${mem} MB (mín ${min_mem} MB), tmpfs de build no montado (lo monta prepare_tmpfs_build)."
  fi
}

# Libera espacio en el tmpfs de build cuando una ejecución anterior lo dejó
# ocupado. Solo toca lo re-generable: artefactos del enlace final (vmlinux*,
# System.map, .tmp_vmlinux*) del árbol de esta versión y árboles huérfanos de
# versiones distintas. NUNCA borra el árbol de la versión en curso (es la
# inversión reutilizable del build; se vuelve a enlazar en minutos).
liberate_tmpfs_space() {
  local purged=0 art
  tmpfs_is_mounted || return 0

  # 1. Artefactos del enlace final del árbol de esta versión. El vmlinux con
  #    .BTF es el mayor consumidor del tmpfs; su purga devuelve varios GB.
  #    Solo si el árbol es realmente reutilizable: si es de otro tipo o
  #    versión, reconcile_tmpfs_trees lo descarta entero (o desmonta el tmpfs)
  #    y purgar sus artefactos sería tirar tiempo.
  if source_tree_reusable; then
    while IFS= read -r -d '' art; do
      rm -f -- "$art"
      purged=1
    done < <(find "$SRC" -maxdepth 1 -type f \( -name 'vmlinux' -o -name 'vmlinux.o' -o \
        -name 'vmlinux.unstripped' -o -name 'System.map' -o -name '.tmp_vmlinux*' \) -print0 2>/dev/null || true)
    unset art
    if [ "$purged" = 1 ]; then
      log "Artefactos del enlace purgados del árbol reutilizable (se regenerarán durante el build)."
    fi
  fi

  # 2. Árboles de versiones distintas (misma semántica que cleanup_old_source_trees,
  #    que se ejecuta más adelante y ya encontrará estos directorios libres).
  cleanup_old_source_trees
}

on_err() {
  local rc=$?
  err "Error $rc en línea ${BASH_LINENO[0]}: ${BASH_COMMAND}"
  err "La operación fue abortada; el árbol tmpfs se conserva para diagnóstico."
  exit "$rc"
}
trap on_err ERR

# Compilador de preferencia (--cc / CIZEN_CC): valida el valor elegido y deduce
# la FAMILIA (gcc|clang) y el BINARIO EFECTIVO (CC_LAUNCHER) que se usará en
# make. Acepta los lógicos auto|gcc|clang, compiladores versionados de Arch
# (gcc-14/gcc14, clang-17/clang17) o una ruta/binario propios (la familia se
# infiere del basename: contiene gcc → GCC, clang → LLVM). En familia clang se
# marca CLANG_REQUESTED (o si ya venía de --clang/LTO): el compilador elegido
# se exige como dependencia obligatoria en check_prerequisites. La elección
# explícita (--cc gcc) gana sobre la bandera --clang previa: el compilador que
# pediste es el que se usa.
_resolve_cc_compiler() {
  case "$CIZEN_CC" in
    auto)
      if [ "$CIZEN_LLVM_LTO" != "0" ] || [ "$CLANG_REQUESTED" = true ]; then
        CC_FAMILY=clang; CC_LAUNCHER=clang; CLANG_REQUESTED=true
      else
        CC_FAMILY=gcc; CC_LAUNCHER=gcc
      fi ;;
    gcc)
      CC_FAMILY=gcc; CC_LAUNCHER=gcc; CLANG_REQUESTED=false ;;
    clang)
      CC_FAMILY=clang; CC_LAUNCHER=clang; CLANG_REQUESTED=true ;;
    *)
      case "$(basename -- "$CIZEN_CC")" in
        *clang*) CC_FAMILY=clang; CLANG_REQUESTED=true ;;
        *gcc*)   CC_FAMILY=gcc;   CLANG_REQUESTED=false ;;
        *) fatal "CIZEN_CC inválido: $CIZEN_CC (use auto, gcc, clang, gcc-14, clang-17 o una ruta a tu compilador)." ;;
      esac
      CC_LAUNCHER="$CIZEN_CC" ;;
  esac
}

# ============================================================
# ARGUMENTOS
# ============================================================
while [ $# -gt 0 ]; do
  case "$1" in
    --check-update)
      CHECK_UPDATE=true; shift ;;
    --check)
      CHECK_ONLY=true; shift ;;
    --force)
      FORCE=true; shift ;;
    --strict)
      STRICT=true; shift ;;
    --absorb-rebels)
      ABSORB_REBELS=true; shift ;;
    --patch)
      PATCH_REQUESTED=true
      if [ -n "${2:-}" ] && [[ ! "$2" =~ ^-- ]]; then
        IFS=',' read -r -a __patchs <<< "$2"
        for __patchn in "${__patchs[@]:-}"; do [ -n "$__patchn" ] && PATCH_NAMES+=("$__patchn"); done
        unset __patchs __patchn
        shift 2
      else
        err "--patch requiere un nombre de parche (p. ej. bore). Todos: --patch <nombre>"
        exit 1
      fi ;;
    --patch=*)
      PATCH_REQUESTED=true
      IFS=',' read -r -a __patchs <<< "${1#--patch=}"
      for __patchn in "${__patchs[@]:-}"; do [ -n "$__patchn" ] && PATCH_NAMES+=("$__patchn"); done
      unset __patchs __patchn
      shift ;;
    --bore)
      PATCH_REQUESTED=true
      PATCH_NAMES+=(bore)
      shift ;;
    --btf)
      BTF_REQUESTED=true; shift ;;
    --no-btf)
      BTF_REQUESTED=false; shift ;;
    --clang)
      CLANG_REQUESTED=true; shift ;;
    --menuconfig)
      MENUCONFIG_REQUESTED=true; shift ;;
    --selftest)
      SELFTEST=true; shift ;;
    --hardened)
      HARDENED_AUDIT=true; shift ;;
    --publish-repo)
      PUBLISH_REPO=true; shift ;;
    --changelog)
      DO_CHANGELOG=true; shift ;;
    --keep-src)
      KEEP_SRC=true; shift ;;
    --no-prune)
      PRUNE_MODULES=0; shift ;;
    --prune)
      PRUNE_MODULES=1; shift ;;
    --sign)
      SIGN_UKI="yes"; shift ;;
    --no-sign)
      SIGN_UKI="no"; shift ;;
    --list-renames)
      DO_LIST=true; shift ;;
    --rename)
      DO_RENAME=true
      if [ -n "${2:-}" ] && [[ ! "$2" =~ ^-- ]]; then
        RENAME_PAIR="$2"; shift 2
      else
        err "--rename requiere VIEJO=NUEVO"; exit 1
      fi ;;
    --save-auto-renames)
      SAVE_AUTO_RENAMES=true ;;
    --rename=*)
      DO_RENAME=true
      RENAME_PAIR="${1#--rename=}"
      shift ;;
    --cc)
      CIZEN_CC="${2:-}"; [ -n "$CIZEN_CC" ] || { err "--cc requiere auto|gcc|clang, una versión (gcc-14, clang-17) o una ruta a tu compilador"; exit 1; }
      shift 2 ;;
    --cc=*)
      CIZEN_CC="${1#--cc=}"; shift ;;
    --lto-thin)
      CIZEN_LLVM_LTO=thin; shift ;;
    --lto-full)
      CIZEN_LLVM_LTO=full; shift ;;
    --no-lto)
      CIZEN_LLVM_LTO=0; shift ;;
    --o3)
      CIZEN_CFLAGS_OLEVEL=3; shift ;;
    --o2)
      CIZEN_CFLAGS_OLEVEL=2; shift ;;
    --native)
      CIZEN_CPU_OPT=native; shift ;;
    --march)
      CIZEN_CPU_OPT="${2:-}"; [ -n "$CIZEN_CPU_OPT" ] || { err "--march requiere un valor (p. ej. native, znver4, skylake, x86-64-v3)"; exit 1; }
      shift 2 ;;
    --march=*)
      CIZEN_CPU_OPT="${1#--march=}"; shift ;;
    --timer-freq)
      CIZEN_TIMER_FREQ="${2:-}"; [ -n "$CIZEN_TIMER_FREQ" ] || { err "--timer-freq requiere 100|250|300|500|1000"; exit 1; }
      shift 2 ;;
    --timer-freq=*)
      CIZEN_TIMER_FREQ="${1#--timer-freq=}"; shift ;;
    --sched)
      CIZEN_SCHED="${2:-}"; [ -n "$CIZEN_SCHED" ] || { err "--sched requiere un scheduler (eevdf, bore, pds, bmq, lfbmq, muqss)"; exit 1; }
      shift 2 ;;
    --sched=*)
      CIZEN_SCHED="${1#--sched=}"; shift ;;
    --tree)
      CIZEN_KERNEL_TREE="${2:-}"; [ -n "$CIZEN_KERNEL_TREE" ] || { err "--tree requiere auto|vanilla|cachyos"; exit 1; }
      shift 2 ;;
    --tree=*)
      CIZEN_KERNEL_TREE="${1#--tree=}"; shift ;;
    --no-ask-variant)
      # v27.31.28: el menú ya preguntó la variante (antes que el compilador) y no
      # tiene sentido que el motor vuelva a preguntar 9 minutos después, con la
      # descarga y la validación ya gastadas.
      NO_ASK_VARIANT=true; shift ;;
    --ask-variant)
      NO_ASK_VARIANT=false; shift ;;
    --ntsync)
      CIZEN_PATCH_NTSYNC=1; shift ;;
    --no-ntsync)
      CIZEN_PATCH_NTSYNC=0; shift ;;
    --fsync)
      CIZEN_PATCH_FSYNC=1; shift ;;
    --no-fsync)
      CIZEN_PATCH_FSYNC=0; shift ;;
    --cachy)
      CIZEN_CACHY_PATCHES=1; shift ;;
    --no-cachy)
      CIZEN_CACHY_PATCHES=0; shift ;;
    --frag-dir)
      CIZEN_FRAGS_DIR="${2:-}"; [ -n "$CIZEN_FRAGS_DIR" ] || { err "--frag-dir requiere una ruta"; exit 1; }
      shift 2 ;;
    --frag-dir=*)
      CIZEN_FRAGS_DIR="${1#--frag-dir=}"; shift ;;
    --modprobed-db)
      CIZEN_MODPROBED_DB=1; shift ;;
    --no-modprobed-db)
      CIZEN_MODPROBED_DB=0; shift ;;
    --pkg-backend)
      CIZEN_PKG_BACKEND="${2:-}"; [ -n "$CIZEN_PKG_BACKEND" ] || { err "--pkg-backend requiere arch|deb|rpm|generic|gentoo"; exit 1; }
      shift 2 ;;
    --pkg-backend=*)
      CIZEN_PKG_BACKEND="${1#--pkg-backend=}"; shift ;;
    --user-patches)
      CIZEN_USER_PATCHES_DIR="${2:-}"; [ -n "$CIZEN_USER_PATCHES_DIR" ] || { err "--user-patches requiere una ruta"; exit 1; }
      shift 2 ;;
    --user-patches=*)
      CIZEN_USER_PATCHES_DIR="${1#--user-patches=}"; shift ;;
    --module-sign)
      CIZEN_MODULE_SIGN=yes; shift ;;
    --no-module-sign)
      CIZEN_MODULE_SIGN=no; shift ;;
    --uki-backup)
      CIZEN_UKI_BACKUP=1; shift ;;
    --no-uki-backup)
      CIZEN_UKI_BACKUP=0; shift ;;
    --luks-audit)
      CIZEN_LUKS_AUDIT=1; shift ;;
    --*)
      err "Opción desconocida: $1"
      exit 1 ;;
    *)
      if [ -n "$VERSION" ]; then
        err "Solo se puede especificar una versión. Ya existe: $VERSION"
        exit 1
      fi
      VERSION="$1"
      shift ;;
  esac
done

# Entorno para parches/BTF/clang (se suma a los flags; CIZEN_ENABLE_BORE
# sigue funcionando igual que antes como forma de pedir BORE).
if [ "${CIZEN_ENABLE_BORE:-0}" = "1" ]; then
  PATCH_NAMES+=(bore)
  PATCH_REQUESTED=true
fi
if [ -n "${CIZEN_PATCHES:-}" ]; then
  PATCH_REQUESTED=true
  IFS=',' read -r -a __patchs <<< "$CIZEN_PATCHES"
  for __patchn in "${__patchs[@]:-}"; do [ -n "$__patchn" ] && PATCH_NAMES+=("$__patchn"); done
  unset __patchs __patchn
fi
[ "${CIZEN_BTF:-0}" = "1" ] && BTF_REQUESTED=true
[ "${CIZEN_NO_BTF:-0}" = "1" ] && BTF_REQUESTED=false
[ "${CIZEN_CLANG:-0}" = "1" ] && CLANG_REQUESTED=true

# ── Perfil de compilación extendido: validación de valores por env ──
case "$CIZEN_LLVM_LTO" in 0|1|thin|full) ;; *) fatal "CIZEN_LLVM_LTO inválido: $CIZEN_LLVM_LTO (use 0, 1, thin o full)." ;; esac
# Compilador de preferencia: deduce familia/binario y marca CLANG_REQUESTED
# (la elección explícita en --cc gana sobre la bandera --clang previa).
_resolve_cc_compiler
# LTO solo es viable con la familia clang (LLVM=1): si el compilador elegido es
# GCC se ignora el LTO AHORA, antes de la fase de config, para no inyectar
# CONFIG_LTO_CLANG_* en un build gcc (olddefconfig los descartaría y la
# validación ENABLE fallaría).
if [ "$CIZEN_LLVM_LTO" != "0" ] && [ "$CC_FAMILY" = "gcc" ]; then
  warn "LTO (${CIZEN_LLVM_LTO}) exige clang; el compilador elegido es GCC (${CC_LAUNCHER}); se ignora el LTO."
  CIZEN_LLVM_LTO=0
fi
# v27.31.7: las fases de preparación de config (listnewconfig/olddefconfig/
# localmodconfig) deben ver el MISMO compilador que la build real. Si se
# preparan con gcc y se compila con LLVM=1 (clang), los símbolos que solo
# existen con CC_IS_CLANG (p. ej. AUTOFDO_CLANG) quedan fuera de .config y el
# syncconfig del build los trata como (NEW) → conf pide respuestas interactivas
# (prompt "Restart config...") y cuelga una compilación no interactiva.
declare -a KCONFIG_CC_OPTS=()
if [ "$CC_FAMILY" = "clang" ]; then
  KCONFIG_CC_OPTS+=('LLVM=1')
fi
case "$CC_LAUNCHER" in
  gcc|clang) ;;  # genérico: Kbuild resuelve por PATH
  *) KCONFIG_CC_OPTS+=("CC=$CC_LAUNCHER" "HOSTCC=$CC_LAUNCHER") ;;
esac
case "$CIZEN_CFLAGS_OLEVEL" in inherit|2|3) ;; *) fatal "CIZEN_CFLAGS_OLEVEL inválido: $CIZEN_CFLAGS_OLEVEL (use inherit, 2 o 3)." ;; esac
case "$CIZEN_CPU_OPT" in
  inherit|generic|native) ;;
  *) case "$CIZEN_CPU_OPT" in
       -*|*[[:space:]]*|*/*) fatal "CIZEN_CPU_OPT inválido: $CIZEN_CPU_OPT" ;;
     esac ;;
esac
case "$CIZEN_TIMER_FREQ" in inherit|100|250|300|500|1000) ;; *) fatal "CIZEN_TIMER_FREQ inválido: $CIZEN_TIMER_FREQ (use inherit, 100, 250, 300, 500 o 1000)." ;; esac
case "$CIZEN_PATCH_NTSYNC" in auto|0|1) ;; *) fatal "CIZEN_PATCH_NTSYNC inválido: $CIZEN_PATCH_NTSYNC (auto, 0 o 1)." ;; esac
case "$CIZEN_PATCH_FSYNC" in 0|1) ;; *) fatal "CIZEN_PATCH_FSYNC inválido: $CIZEN_PATCH_FSYNC (0 o 1)." ;; esac
case "$CIZEN_CACHY_PATCHES" in 0|1) ;; *) fatal "CIZEN_CACHY_PATCHES inválido: $CIZEN_CACHY_PATCHES (0 o 1)." ;; esac
case "$CIZEN_MODPROBED_DB" in
  0|1) ;;
  *) [ -s "$CIZEN_MODPROBED_DB" ] || fatal "CIZEN_MODPROBED_DB debe ser 0, 1 o una ruta a una base de datos existente: $CIZEN_MODPROBED_DB" ;;
esac
case "$CIZEN_PKG_BACKEND" in arch|deb|rpm|generic|gentoo) ;;
  *) fatal "CIZEN_PKG_BACKEND inválido: $CIZEN_PKG_BACKEND (use arch, deb, rpm, generic o gentoo)." ;;
esac
case "$CIZEN_MODULE_SIGN" in yes|no) ;; *) fatal "CIZEN_MODULE_SIGN inválido: $CIZEN_MODULE_SIGN (use yes o no)." ;; esac
case "$CIZEN_KERNEL_TREE" in auto|vanilla|cachyos) ;; *) fatal "CIZEN_KERNEL_TREE inválido: $CIZEN_KERNEL_TREE (use auto, vanilla o cachyos)." ;; esac
if [ -n "$CIZEN_USER_PATCHES_DIR" ] && [ ! -d "$CIZEN_USER_PATCHES_DIR" ]; then
  fatal "CIZEN_USER_PATCHES_DIR no existe o no es un directorio: $CIZEN_USER_PATCHES_DIR"
fi
# Compilador explícito por env sobre la auto-detección: resuelto por
# _resolve_cc_compiler (familias, versiones y rutas incluidas).
# CIZEN_SCHED como alias de --patch (evita que dedupe lo pierda).
case "$CIZEN_SCHED" in
  inherit|eevdf) ;;
  bore|pds|bmq|lfbmq|muqss) PATCH_NAMES+=("$CIZEN_SCHED") ;;
  *) fatal "CIZEN_SCHED inválido: $CIZEN_SCHED (use inherit, eevdf, bore, pds, bmq, lfbmq o muqss)." ;;
esac
# ntsync para kernels SIN soporte nativo (< 6.10): se pide el parche CachyOS.
# NO se resuelve aquí: kernel_version_ge está definida unas 5000 líneas más
# abajo, y llamarla en este punto top-level daba "orden no encontrada" en
# todas las ejecuciones. Como la llamada iba dentro de `! ...`, el 127 no
# abortaba (contexto de condición) pero el resultado era el contrario del
# buscado: se añadía ntsync SIEMPRE, incluso a kernels con soporte nativo, y
# se ensuciaba el stderr. La decisión vive ahora en auto_add_ntsync_patch(),
# llamada desde el flujo principal con todas las definiciones ya cargadas.

case "$PRUNE_MODULES" in
  0|1) ;;
  *) fatal "CIZEN_PRUNE_MODULES inválido: $PRUNE_MODULES (use 0 o 1)." ;;
esac
case "$SIGN_UKI" in
  auto|yes|no) ;;
  *) fatal "CIZEN_SIGN_UKI inválido: $SIGN_UKI (use auto, yes o no)." ;;
esac
# Ruta al podador: en la suite instalada o junto al motor (preferencia a la env).
if [ -n "${CIZEN_PRUNE_SCRIPT:-}" ]; then
  PRUNER_SCRIPT="$CIZEN_PRUNE_SCRIPT"
else
  PRUNER_SCRIPT="$SCRIPT_DIR/podar-modulos.sh"
fi
[ -n "${CIZEN_PUBLISH_REPO:-}" ] && PUBLISH_REPO=true
PUBLISH_REPO_DIR="${CIZEN_PUBLISH_REPO:-/var/lib/kernel-update/repo}"

# Deduplicar PATCH_NAMES conservando el orden.
if [ "${#PATCH_NAMES[@]}" -gt 0 ]; then
  declare -A __seen=()
  declare -a __uniq=()
  for __patchn in "${PATCH_NAMES[@]}"; do
    [ -n "${__seen[$__patchn]:-}" ] && continue
    __seen["$__patchn"]=1
    __uniq+=("$__patchn")
  done
  unset __seen
  PATCH_NAMES=("${__uniq[@]}")
  unset __uniq __patchn
  if [ "${#PATCH_NAMES[@]}" -eq 0 ]; then
    PATCH_REQUESTED=false
  fi
fi

# ============================================================
# RENAME MAP
# ============================================================
declare -A RENAME_MAP=()
# v27.31.28: renombres detectados solo (no confirmados por el usuario). Se
# aplican en memoria siempre; para que sobrevivan al siguiente kernel hay que
# pasar --save-auto-renames.
declare -A AUTO_RENAMES=()
SAVE_AUTO_RENAMES=false

do_rename() {
  local pair="$1" old new tmp line found=false
  if [[ ! "$pair" =~ ^([A-Za-z0-9_]+)=([A-Za-z0-9_]+)$ ]]; then
    err "Formato inválido. Use: VIEJO=NUEVO"
    exit 1
  fi
  old="${BASH_REMATCH[1]}"
  new="${BASH_REMATCH[2]}"

  mkdir -p "$(dirname "$RENAME_MAP_FILE")"
  touch "$RENAME_MAP_FILE"
  tmp=$(mktemp "${RENAME_MAP_FILE}.XXXXXX")

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^${old}[[:space:]]*= ]]; then
      printf '%s=%s\n' "$old" "$new" >> "$tmp"
      found=true
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$RENAME_MAP_FILE"

  if [ "$found" = false ]; then
    printf '%s=%s\n' "$old" "$new" >> "$tmp"
  fi

  if ! mv -- "$tmp" "$RENAME_MAP_FILE"; then
    rm -f -- "$tmp"
    fatal "No se pudo actualizar el mapa de renombres: $RENAME_MAP_FILE"
  fi

  if [ "$found" = true ]; then
    ok "Mapa actualizado: $old → $new"
  else
    ok "Mapa añadido: $old → $new"
  fi
  cat "$RENAME_MAP_FILE"
}

load_rename_map() {
  RENAME_MAP=()
  [ -f "$RENAME_MAP_FILE" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*([A-Za-z0-9_]+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      RENAME_MAP["$key"]="$val"
    fi
  done < "$RENAME_MAP_FILE"
}

resolve_symbol() {
  local sym="$1" next
  local -A seen=()
  while [ -n "${RENAME_MAP[$sym]:-}" ]; do
    if [ -n "${seen[$sym]:-}" ]; then
      warn "Ciclo detectado en RENAME_MAP para '$sym'; se detiene la resolución." >&2
      break
    fi
    seen["$sym"]=1
    next="${RENAME_MAP[$sym]}"
    sym="$next"
  done
  printf '%s\n' "$sym"
}

if [ "$DO_LIST" = true ]; then
  load_rename_map
  if [ "${#RENAME_MAP[@]}" -eq 0 ]; then
    echo "El mapa de renombres está vacío o no existe: $RENAME_MAP_FILE"
  else
    echo "── Mapa de renombres (${#RENAME_MAP[@]} entradas) ──"
    while IFS= read -r key; do
      printf '  %s → %s\n' "$key" "${RENAME_MAP[$key]}"
    done < <(printf '%s\n' "${!RENAME_MAP[@]}" | sort)
  fi
  exit 0
fi

if [ "$DO_RENAME" = true ]; then
  do_rename "$RENAME_PAIR"
  exit 0
fi

if [ -n "$VERSION" ] && [ "$CHECK_UPDATE" = true ]; then
  err "--check-update no acepta una versión explícita."
  exit 1
fi

if [ -n "$VERSION" ]; then
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
    err "Versión inválida: $VERSION"
    err "Use una release oficial de kernel.org en formato X.Y o X.Y.Z; ejemplo: 7.2.2"
    exit 1
  fi

  # kernel.org publica la release base X.Y sin '.0'. Canonicalizamos X.Y.0 -> X.Y.
  if [[ "$VERSION" =~ ^([0-9]+\.[0-9]+)\.0$ ]]; then
    warn "Normalizando release X.Y.0 de kernel.org: $VERSION -> ${BASH_REMATCH[1]}"
    VERSION="${BASH_REMATCH[1]}"
  fi
fi

if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  err "JOBS debe ser un entero positivo: JOBS=3"
  exit 1
fi

# ============================================================
# AGENTE DE RELEASES KERNEL.ORG
# ============================================================
KERNEL_RELEASES_JSON_URL="${KERNEL_RELEASES_JSON_URL:-https://www.kernel.org/releases.json}"

version_is_valid() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]]
}

version_gt() {
  local a="$1" b="$2" first second
  first="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)"
  [ "$first" = "$b" ] && [ "$a" != "$b" ]
}

get_local_kernel_version() {
  local installed path base candidate="" best_local_version=""

  # Primero consultamos el paquete Cizen actual. Durante la migración también
  # aceptamos linux-upstream como referencia local para no perder la detección
  # de la versión instalada antes del primer paquete linux-cizen-v3.
  local pkgbase installed_pkg
  for pkgbase in "$CIZEN_PKGBASE" "$LEGACY_PKGBASE"; do
    if pacman -Q "$pkgbase" >/dev/null 2>&1; then
      installed_pkg="$pkgbase"
      installed="$(pacman -Q "$installed_pkg" | awk 'NR==1 {print $2}')"
      if [[ "$installed" =~ ^([0-9]+\.[0-9]+([.][0-9]+)?)_cizen_v3-[0-9]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
      elif [[ "$installed" =~ ^([0-9]+\.[0-9]+([.][0-9]+)?)-[0-9]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
      fi
    fi
  done

  shopt -s nullglob
  for path in "$CONFIG_DIR"/linux-*-cizen-v3.config; do
    base="$(basename -- "$path")"
    if [[ "$base" =~ ^linux-([0-9]+\.[0-9]+([.][0-9]+)?)-cizen-v3\.config$ ]]; then
      candidate="${BASH_REMATCH[1]}"
      if [ -z "$best_local_version" ] || version_gt "$candidate" "$best_local_version"; then
        best_local_version="$candidate"
      fi
    fi
  done
  shopt -u nullglob
  printf '%s\n' "${best_local_version:-}"
}

get_kernel_org_latest_stable() {
  local json latest="" track
  json="$(wget -qO- --timeout=30 --tries=2 "$KERNEL_RELEASES_JSON_URL")" || return 1
  track="${CIZEN_KERNEL_TRACK:-stable}"

  case "$track" in
    longterm|lts)
      # releases.json: cada release estable lleva su moniker. La mayor con
      # moniker longterm/lts es la que se sigue. Requiere jq; sin jq se degrada
      # a latest_stable con warning (documentado en cabecera).
      if command -v jq >/dev/null 2>&1; then
        latest="$(printf '%s\n' "$json" | jq -r '[.releases[] | select((.moniker // "" | ascii_downcase | test("longterm|lts"))) | .version] | sort_by(. | split(".") | map(tonumber)) | last // empty' 2>/dev/null || true)"
      fi
      if [ -z "$latest" ]; then
        warn "CIZEN_KERNEL_TRACK=longterm requiere jq (o no hay release LTS en releases.json); se usa latest_stable."
      fi
      ;;
    *)
      # jq es la vía preferida cuando está disponible; el parsing sed se conserva
      # como fallback para sistemas sin jq y cubre el esquema actual de kernel.org.
      if command -v jq >/dev/null 2>&1; then
        latest="$(printf '%s\n' "$json" | jq -r '.latest_stable.version // empty' 2>/dev/null || true)"
      fi
      ;;
  esac

  if [ -z "$latest" ]; then
    latest="$(printf '%s\n' "$json" | tr '\n' ' ' | sed -n 's/.*"latest_stable"[[:space:]]*:[[:space:]]*{[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^" ]*\)"[[:space:]]*}.*/\1/p')"
  fi
  version_is_valid "$latest" || return 1
  printf '%s\n' "$latest"
}

resolve_latest_release() {
  local latest local_version track_txt
  latest="$(get_kernel_org_latest_stable)" || fatal "No se pudo consultar la release estable de kernel.org: $KERNEL_RELEASES_JSON_URL"
  REMOTE_STABLE_VERSION="$latest"

  local_version="$(get_local_kernel_version)"
  LOCAL_KERNEL_VERSION="$local_version"

  case "${CIZEN_KERNEL_TRACK:-stable}" in
    longterm|lts) track_txt="(longterm LTS)" ;;
    *) track_txt="(stable)" ;;
  esac

  if [ -n "$local_version" ]; then
    if version_gt "$latest" "$local_version"; then
      ok "Nueva release $track_txt detectada: $local_version → $latest"
    else
      ok "Kernel Cizen ya está en $local_version; kernel.org $track_txt: $latest"
    fi
  else
    info "kernel.org $track_txt detectado: $latest (sin versión Cizen instalada como referencia)"
  fi
}

# Decide KERNEL_TREE (vanilla | cachyos) una vez resuelta VERSION.
# En "auto" (defecto) los schedulers PRJC/MuQSS fuerzan el fork CachyOS: sus
# parches -cachy solo aplican sobre el árbol del fork CachyOS/linux; sobre la
# release vanilla de kernel.org los ficheros vanilla (0001-prjc.patch) ya no se
# publican para ramas recientes y el resultado es build vanilla silencioso.
resolve_kernel_tree() {
  local __p
  KERNEL_TREE="$CIZEN_KERNEL_TREE"
  TREE_FORCE_NOTE=""
  if [ "$KERNEL_TREE" = "auto" ]; then
    for __p in "${PATCH_NAMES[@]:-}"; do
      case "$__p" in
        pds|bmq|lfbmq|muqss)
          KERNEL_TREE="cachyos"
          TREE_FORCE_NOTE="lo fuerza el parche/scheduler '$__p' (solo existe en el fork CachyOS/linux)"
          break ;;
      esac
    done
    if [ "$KERNEL_TREE" = "auto" ]; then
      KERNEL_TREE="vanilla"
    fi
  else
    TREE_FORCE_NOTE="CIZEN_KERNEL_TREE=$CIZEN_KERNEL_TREE"
  fi
}

# Determina el tagrel del release del fork CachyOS/linux para $VERSION. Los
# releases se publican como cachyos-<VERSION>-<N> (p. ej. cachyos-7.2.7-1, con
# assets .tar.gz + .tar.gz.asc firmados por los mantenedores). Resolución:
#   1) API de releases (cacho de 20, más recientes primero; basta para la
#      estable actual y ahorra el ~2MB de per_page=100 que GitHub sirve a
#      menudo a <100KB/s): se queda con el mayor tagrel para la versión
#      (patrón cachyos-$VERSION-[0-9]+).
#   2) Fallback sin depender de rate limits ni paginación: sondeo directo del
#      .asc de los tags cachyos-$VERSION-1..8 (asset mínimo; 404 = tag ausente).
# ¿El fork CachyOS/linux ha publicado ya <ver>?
#
# Mitad "consulta" de resolve_cachyos_release, separada para poder preguntar por
# la EXISTENCIA de un release sin abortar nunca. Deja el tagrel en
# CACHYOS_TAGREL (vacío = el fork no lo tiene) y el contexto del sondeo en
# CACHYOS_API_OK / CACHYOS_SEEN_TAGS / CACHYOS_LATEST_MINOR para que el fatal
# pueda explicar. No imprime nada (solo deja resultados; el que llama informa).
# v27.31.18: confirm_newer_release la usa para no ofrecer una stable de
# kernel.org que este build no puede compilar porque el fork va con retraso.
cachyos_release_tagrel() {
  local ver="$1" i cand_url probes
  CACHYOS_TAGREL=""
  CACHYOS_API_OK=0
  CACHYOS_SEEN_TAGS=""
  CACHYOS_LATEST_MINOR=""
  CACHYOS_FOUND_VIA=""
  probes="$KERNEL_BUILD_ROOT/.cizen-cachy-probe-$$"
  rm -f -- "$probes"

  if download_small_file "https://api.github.com/repos/CachyOS/linux/releases?per_page=20" "$probes" >/dev/null 2>&1; then
    CACHYOS_API_OK=1
    # v27.31.15: `|| true` en la tubería. Sin él, cuando el fork aún no publicó
    # la versión (p. ej. stable 7.2.8 recién salida en kernel.org) el último
    # grep se queda sin entrada y devuelve 1; con `set -Eeuo pipefail` + trap
    # ERR eso abortaba la run entera con "Error 1 en línea N: tail -n1" y sin
    # llegar al sondeo directo ni al fatal explicativo. Ahora la tubería
    # devuelve vacío y el flujo sigue su curso (sondeo → fatal claro).
    CACHYOS_TAGREL="$(
      grep -oE 'cachyos-'"$ver"'-[-A-Za-z0-9.]+' "$probes" \
      | sed -E 's/^cachyos-'"$ver"'-([0-9]+)$/\1/' \
      | grep -E '^[0-9]+$' \
      | sort -n | tail -n1 || true
    )"
    # Últimos tags vistos, para el diagnóstico final si esta versión no existe.
    CACHYOS_SEEN_TAGS="$(grep -oE '"tag_name": *"cachyos-[^"]+"' "$probes" 2>/dev/null \
      | sed -E 's/.*"(cachyos-[^"]+)"/\1/' | head -6 | tr '\n' ' ' || true)"
    # Última X.Y.Z publicada en la MISMA línea de la versión consultada (los tags
    # -rc de otra línea no cuentan). Sirve para decir "su última 7.2.x es 7.2.7".
    CACHYOS_LATEST_MINOR="$(
      grep -oE '"tag_name": *"cachyos-'"${ver%.*}"'\.[0-9]+-[0-9]+"' "$probes" 2>/dev/null \
      | sed -E 's/.*cachyos-([0-9]+\.[0-9]+\.[0-9]+)-.*/\1/' \
      | sort -V -u | tail -n1 || true
    )"
    rm -f -- "$probes"
    if [ -n "$CACHYOS_TAGREL" ]; then
      CACHYOS_FOUND_VIA="api"
      return 0
    fi
  fi

  # Fallback: probar .asc de los candidatos directos.
  rm -f -- "$probes"
  for i in $(seq 1 8); do
    cand_url="https://github.com/CachyOS/linux/releases/download/cachyos-${ver}-${i}/cachyos-${ver}-${i}.tar.gz.asc"
    if download_small_file "$cand_url" "$probes" >/dev/null 2>&1; then
      CACHYOS_TAGREL="$i"
      rm -f -- "$probes"
      CACHYOS_FOUND_VIA="sondeo"
      return 0
    fi
  done
  rm -f -- "$probes"
  CACHYOS_FOUND_VIA=""
  return 1
}

resolve_cachyos_release() {
  local ver="$1"
  cachyos_release_tagrel "$ver" || {
    # v27.31.15: diagnóstico accionable. Lo normal es que kernel.org ya tenga la
    # release y el fork CachyOS todavía no (los tags van con retraso): decirlo
    # claro evita que parezca un fallo de red.
    err "El fork CachyOS/linux no tiene ningún release para ${ver}."
    if [ "$CACHYOS_API_OK" = 1 ] && [ -n "$CACHYOS_SEEN_TAGS" ]; then
      err "Últimos tags publicados por el fork: ${CACHYOS_SEEN_TAGS}"
    else
      warn "No se pudo consultar la API de releases del fork (¿red?)."
    fi
    err "Los schedulers/tuning del proyecto (pds/bmq/lfbmq/muqss) solo existen en el fork CachyOS."
    fatal "Opciones: compila una versión que el fork sí tenga publicado (p. ej. la estable del fork) con --version <VER>, o usa un scheduler de mainline (eevdf) que sí puede compilar ${ver} vanilla desde kernel.org."
  }
  if [ "$CACHYOS_FOUND_VIA" = "api" ]; then
    ok "Release CachyOS detectado (API): cachyos-${ver}-${CACHYOS_TAGREL}"
  else
    ok "Release CachyOS detectado (sondeo): cachyos-${ver}-${CACHYOS_TAGREL}"
  fi
}

# ============================================================
# RUTAS / ESTADO
# ============================================================
MAJOR=""
# TARBALL/SRC/URL se calculan después de resolver VERSION.
TARBALL=""
SRC=""
URL=""
# Árbol de fuentes resuelto (vanilla | cachyos), tagrel del release CachyOS y
# rutas .asc/.sign derivadas. Se fijan tras la resolución de VERSION.
KERNEL_TREE=""
CACHYOS_TAGREL=""
SIG_FILE=""
SIG_URL=""

TS="$(date +%Y%m%d-%H%M%S)"
BUILD_MARKER="$TMPFS_ROOT/.build-marker-$TS"
NEWCONFIG_OUTPUT=""
OLDCONFIG_OUTPUT=""

REMOTE_STABLE_VERSION=""
LOCAL_KERNEL_VERSION=""

# ============================================================
# PERFIL EXTERNO
# ============================================================
declare -A EXPECTED_REBEL_SET=()

# IMPORTANTE: el perfil debe ser sourceado en el ámbito global.
# Si se hace `source` dentro de una función, un `declare -a/-A` del perfil
# puede quedar local a esa función y desaparecer al retornar, produciendo
# falsos 0/0 en la preparación y validación.
load_profile() {
  local _name _decl _r
  for _name in OPTS_ENABLE OPTS_DISABLE OPTS_SETVAL OPTS_SETSTR CRITICAL_OPTS EXPECTED_REBELS; do
    if ! declare -p "$_name" >/dev/null 2>&1; then
      fatal "Perfil inválido: falta $_name en '$PROFILE_FILE'"
    fi
  done

  for _name in OPTS_ENABLE OPTS_DISABLE CRITICAL_OPTS EXPECTED_REBELS; do
    _decl="$(declare -p "$_name")"
    [[ "$_decl" == "declare -a "* ]] || fatal "Perfil inválido: $_name debe ser un array indexado en '$PROFILE_FILE'"
  done

  for _name in OPTS_SETVAL OPTS_SETSTR; do
    _decl="$(declare -p "$_name")"
    [[ "$_decl" == "declare -A "* ]] || fatal "Perfil inválido: $_name debe ser un array asociativo (declare -A) en '$PROFILE_FILE'"
  done

  EXPECTED_REBEL_SET=()
  for _r in "${EXPECTED_REBELS[@]}"; do EXPECTED_REBEL_SET["$_r"]=1; done

  local _enable_n _disable_n _setval_n _setstr_n _critical_n _rebels_n
  _enable_n="${#OPTS_ENABLE[@]}"
  _disable_n="${#OPTS_DISABLE[@]}"
  _setval_n="${#OPTS_SETVAL[@]}"
  _setstr_n="${#OPTS_SETSTR[@]}"
  _critical_n="${#CRITICAL_OPTS[@]}"
  _rebels_n="${#EXPECTED_REBELS[@]}"

  # Validación fuerte: este perfil de producción nunca debe aceptarse vacío.
  [ "$_enable_n" -gt 0 ] || fatal "Perfil inválido: OPTS_ENABLE está vacío en '$PROFILE_FILE'"
  [ "$_disable_n" -gt 0 ] || fatal "Perfil inválido: OPTS_DISABLE está vacío en '$PROFILE_FILE'"
  [ "$_setval_n" -gt 0 ] || fatal "Perfil inválido: OPTS_SETVAL está vacío en '$PROFILE_FILE'"
  [ "$_setstr_n" -gt 0 ] || fatal "Perfil inválido: OPTS_SETSTR está vacío en '$PROFILE_FILE'"
  [ "$_critical_n" -gt 0 ] || fatal "Perfil inválido: CRITICAL_OPTS está vacío en '$PROFILE_FILE'"

  # La validación y la carga siempre ocurren, pero el resumen no se repite en
  # cada ejecución. Guardamos únicamente un estado canónico del perfil (no es
  # un backup de .config) para poder detectar altas, bajas y cambios reales.
  PROFILE_STATE_DIR="${CIZEN_PROFILE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/kernel-update}"
  PROFILE_STATE_FILE="$PROFILE_STATE_DIR/profile-${PROFILE}.state"

  profile_state_dump() {
    local _k
    {
      printf '%s\n' '[ENABLE]'
      printf '%s\n' "${OPTS_ENABLE[@]}" | sed '/^$/d' | sort
      printf '%s\n' '[DISABLE]'
      printf '%s\n' "${OPTS_DISABLE[@]}" | sed '/^$/d' | sort
      printf '%s\n' '[SETVAL]'
      for _k in "${!OPTS_SETVAL[@]}"; do printf '%s=%s\n' "$_k" "${OPTS_SETVAL[$_k]}"; done | sort
      printf '%s\n' '[SETSTR]'
      for _k in "${!OPTS_SETSTR[@]}"; do printf '%s=%q\n' "$_k" "${OPTS_SETSTR[$_k]}"; done | sort
      printf '%s\n' '[CRITICAL]'
      printf '%s\n' "${CRITICAL_OPTS[@]}" | sed '/^$/d' | sort
      printf '%s\n' '[REBELS]'
      printf '%s\n' "${EXPECTED_REBELS[@]}" | sed '/^$/d' | sort
    }
  }

  report_profile_changes() {
    local current_file="$1" previous_file="$2"
    local current_section="" line key value
    local -A old_lines=() new_lines=()

    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^\[(.*)\]$ ]]; then
        current_section="${BASH_REMATCH[1]}"
        continue
      fi
      [ -n "$current_section" ] || continue
      [ -n "$line" ] || continue
      old_lines["$current_section|$line"]=1
    done < "$previous_file"

    current_section=""
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^\[(.*)\]$ ]]; then
        current_section="${BASH_REMATCH[1]}"
        continue
      fi
      [ -n "$current_section" ] || continue
      [ -n "$line" ] || continue
      new_lines["$current_section|$line"]=1
    done < "$current_file"

    local changed=false section
    for section in ENABLE DISABLE CRITICAL REBELS; do
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ -z "${old_lines["$section|$line"]:-}" ]; then
          printf '  + [%s] %s\n' "$section" "$line"
          changed=true
        fi
      done < <(awk -v s="[$section]" '$0==s{f=1;next} /^\[[^]]+\]$/{f=0} f && NF{print}' "$current_file")

      while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ -z "${new_lines["$section|$line"]:-}" ]; then
          printf '  - [%s] %s\n' "$section" "$line"
          changed=true
        fi
      done < <(awk -v s="[$section]" '$0==s{f=1;next} /^\[[^]]+\]$/{f=0} f && NF{print}' "$previous_file")
    done

    # SETVAL / SETSTR se muestran como cambios de valor y no como una baja+alta.
    for section in SETVAL SETSTR; do
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        key="${line%%=*}"
        value="${line#*=}"
        if [ -z "${old_lines["$section|$line"]:-}" ]; then
          local found_old="" old_line
          while IFS= read -r old_line; do
            [ -n "$old_line" ] || continue
            if [[ "$old_line" == "$key="* ]]; then found_old="${old_line#*=}"; break; fi
          done < <(awk -v s="[$section]" '$0==s{f=1;next} /^\[[^]]+\]$/{f=0} f && NF{print}' "$previous_file")
          if [ -n "$found_old" ]; then
            printf '  ~ [%s] %s: %s → %s\n' "$section" "$key" "$found_old" "$value"
          else
            printf '  + [%s] %s=%s\n' "$section" "$key" "$value"
          fi
          changed=true
        fi
      done < <(awk -v s="[$section]" '$0==s{f=1;next} /^\[[^]]+\]$/{f=0} f && NF{print}' "$current_file")

      while IFS= read -r line; do
        [ -n "$line" ] || continue
        key="${line%%=*}"
        if [ -z "${new_lines["$section|$line"]:-}" ]; then
          # Si la clave no existe en el perfil nuevo, informar la eliminación.
          local still_present=false current_line
          while IFS= read -r current_line; do
            [ -n "$current_line" ] || continue
            if [[ "$current_line" == "$key="* ]]; then still_present=true; break; fi
          done < <(awk -v s="[$section]" '$0==s{f=1;next} /^\[[^]]+\]$/{f=0} f && NF{print}' "$current_file")
          if [ "$still_present" = false ]; then
            printf '  - [%s] %s\n' "$section" "$line"
            changed=true
          fi
        fi
      done < <(awk -v s="[$section]" '$0==s{f=1;next} /^\[[^]]+\]$/{f=0} f && NF{print}' "$previous_file")
    done

    [ "$changed" = true ]
  }

  show_profile_status() {
    local current_file tmp_new changed=false
    mkdir -p "$PROFILE_STATE_DIR"
    tmp_new="$(mktemp "$PROFILE_STATE_DIR/.profile.XXXXXX")"
    profile_state_dump > "$tmp_new"

    if [ ! -f "$PROFILE_STATE_FILE" ]; then
      echo
      PROFILE_CHANGED=true
      ok "Perfil registrado por primera vez: $PROFILE_FILE"
      info "Perfil: ENABLE=$_enable_n DISABLE=$_disable_n SETVAL=$_setval_n SETSTR=$_setstr_n CRITICAL=$_critical_n REBELS=$_rebels_n"
      mv -f -- "$tmp_new" "$PROFILE_STATE_FILE"
      return 0
    fi

    if cmp -s "$PROFILE_STATE_FILE" "$tmp_new"; then
      rm -f -- "$tmp_new"
      return 0
    fi

    PROFILE_CHANGED=true
    echo
    log "Perfil actualizado: $PROFILE_FILE"
    if ! report_profile_changes "$tmp_new" "$PROFILE_STATE_FILE"; then
      warn "El perfil cambió, pero no se pudieron calcular diferencias legibles; se conserva el nuevo estado."
    fi
    info "Nuevo total: ENABLE=$_enable_n DISABLE=$_disable_n SETVAL=$_setval_n SETSTR=$_setstr_n CRITICAL=$_critical_n REBELS=$_rebels_n"
    mv -f -- "$tmp_new" "$PROFILE_STATE_FILE"
  }

  PROFILE_CHANGED=false
  show_profile_status
}

# Cargar el perfil FUERA de una función para conservar el alcance global de
# los arrays declarados mediante `declare -a` y `declare -A`.
[ -n "$PROFILE_FILE" ] || fatal "No se encontró el perfil Cizen. Use CIZEN_PROFILE_FILE=/ruta/cizen-optiplex7050.conf o instale el perfil junto al script en profiles/."
[ -f "$PROFILE_FILE" ] || fatal "No existe el perfil Cizen: $PROFILE_FILE"

# El perfil externo se ejecuta con `source`, así que debe estar bajo control
# del usuario actual (o de root en una instalación de sistema vía sudo) y no
# ser escribible por grupo u otros usuarios.
_pf_uid="$(stat -c '%u' "$PROFILE_FILE" 2>/dev/null || echo -1)"
_pf_mode="$(stat -c '%a' "$PROFILE_FILE" 2>/dev/null || echo 000)"
[ "$_pf_uid" = "$(id -u)" ] || [ "$_pf_uid" = "0" ] || \
  fatal "El perfil '$PROFILE_FILE' no pertenece al usuario actual ni a root (uid=$_pf_uid)."
case "${_pf_mode: -2}" in
  *[2367]*) fatal "El perfil '$PROFILE_FILE' es escribible por grupo u otros usuarios (mode=$_pf_mode)." ;;
esac
unset _pf_uid _pf_mode

# shellcheck source=/dev/null
source "$PROFILE_FILE"

load_profile

# ============================================================
# PREPARACIÓN EFECTIVA DE SÍMBOLOS
# ============================================================
load_rename_map

declare -a EFF_ENABLE=() EFF_DISABLE=() EFF_CRITICAL=()
declare -A EFF_SETVAL=() EFF_SETSTR=()
declare -A APPLIED_RENAMES=()

declare -A SEEN_ENABLE=() SEEN_DISABLE=() SEEN_CRITICAL=()

add_unique() {
  local arr_name="$1" sym="$2"
  case "$arr_name" in
    enable)
      if [ -z "${SEEN_ENABLE[$sym]:-}" ]; then EFF_ENABLE+=("$sym"); SEEN_ENABLE[$sym]=1; fi ;;
    disable)
      if [ -z "${SEEN_DISABLE[$sym]:-}" ]; then EFF_DISABLE+=("$sym"); SEEN_DISABLE[$sym]=1; fi ;;
    critical)
      if [ -z "${SEEN_CRITICAL[$sym]:-}" ]; then EFF_CRITICAL+=("$sym"); SEEN_CRITICAL[$sym]=1; fi ;;
    *) fatal "add_unique: array desconocido '$arr_name'" ;;
  esac
}

# Reconstruye los arrays efectivos EFF_* a partir de los OPTS_* del perfil.
# Se usa tanto en el arranque como tras --absorb-rebels (que re-sourcea el
# perfil ya editado). Las asignaciones sin `declare` caen sobre los arrays
# globales ya declarados arriba, por lo que es segura llamarla desde aquí.
build_effective_arrays() {
  local o r
  EFF_ENABLE=(); EFF_DISABLE=(); EFF_CRITICAL=()
  EFF_SETVAL=(); EFF_SETSTR=()
  APPLIED_RENAMES=()
  SEEN_ENABLE=(); SEEN_DISABLE=(); SEEN_CRITICAL=()

  for o in "${OPTS_ENABLE[@]}"; do
    r="$(resolve_symbol "$o")"
    [ "$r" != "$o" ] && APPLIED_RENAMES["$o"]="$r"
    add_unique enable "$r"
  done
  for o in "${OPTS_DISABLE[@]}"; do
    r="$(resolve_symbol "$o")"
    [ "$r" != "$o" ] && APPLIED_RENAMES["$o"]="$r"
    add_unique disable "$r"
  done
  for o in "${CRITICAL_OPTS[@]}"; do
    r="$(resolve_symbol "$o")"
    [ "$r" != "$o" ] && APPLIED_RENAMES["$o"]="$r"
    add_unique critical "$r"
  done
  for o in "${!OPTS_SETVAL[@]}"; do
    r="$(resolve_symbol "$o")"
    [ "$r" != "$o" ] && APPLIED_RENAMES["$o"]="$r"
    EFF_SETVAL["$r"]="${OPTS_SETVAL[$o]}"
  done
  for o in "${!OPTS_SETSTR[@]}"; do
    r="$(resolve_symbol "$o")"
    [ "$r" != "$o" ] && APPLIED_RENAMES["$o"]="$r"
    EFF_SETSTR["$r"]="${OPTS_SETSTR[$o]}"
  done

  # Parches de terceros (v27.24.0): cada parche aplicado aporta símbolos Kconfig
  # nuevos que deben entrar en ENABLE (apply_config_requests los fuerza a =y) y
  # registrarse como rebeldes esperados para que la auditoría/validación no
  # ensucie (ni el --strict bloquee por ellos).
  local __ps
  for __ps in "${PATCH_ENABLE_ALL[@]}"; do
    add_unique enable "$__ps"
    EXPECTED_REBEL_SET["$__ps"]=1
    PATCH_KCONFIG_FILTER[$__ps]=1
  done
  unset __ps
  for __ps in "${PATCH_REBEL_ALL[@]}"; do
    EXPECTED_REBEL_SET["$__ps"]=1
    PATCH_KCONFIG_FILTER[$__ps]=1
  done
  unset __ps
  # Símbolos que un parche desactiva para fijar una choice (SCHED_BMQ, etc.).
  for __ps in "${PATCH_DISABLE_ALL[@]:-}"; do
    [ -n "$__ps" ] || continue
    add_unique disable "$__ps"
    EXPECTED_REBEL_SET["$__ps"]=1
  done
  unset __ps

  # Símbolos que el scheduler alternativo RETIRA del kernel (dependen de
  # !SCHED_ALT): son imposibles de habilitar por diseño del parche, aunque el
  # perfil los exija como CRITICAL/SETVAL/ENABLE. Se eliminan de todas las
  # exigencias efectivas para que la validación degenere a aviso informativo en
  # lugar de un FATAL (v27.31.6: BMQ/PDS/LFBMQ con SCHED_ALT sobre cachyos-7.2).
  for __ps in "${PATCH_RETIRED_ALL[@]:-}"; do
    [ -n "$__ps" ] || continue
    local __n=() __v
    for __v in "${EFF_ENABLE[@]}"; do
      [ "$__v" != "$__ps" ] && __n+=("$__v")
    done
    EFF_ENABLE=("${__n[@]}")
    __n=()
    for __v in "${EFF_CRITICAL[@]}"; do
      [ "$__v" != "$__ps" ] && __n+=("$__v")
    done
    EFF_CRITICAL=("${__n[@]}")
    unset "EFF_SETVAL[$__ps]" "EFF_SETSTR[$__ps]"
    unset "EXPECTED_REBEL_SET[$__ps]" "SEEN_ENABLE[$__ps]" "SEEN_CRITICAL[$__ps]"
  done
  unset __ps

  # BTF (obligatorio por defecto): DEBUG_INFO + DEBUG_INFO_BTF =y, marcados como
  # esperados. El perfil base lo trae =y y systemd/bpf-restrict-fs lo necesita.
  if [ "$BTF_REQUESTED" = true ]; then
    add_unique enable "DEBUG_INFO"
    add_unique enable "DEBUG_INFO_BTF"
    EXPECTED_REBEL_SET["DEBUG_INFO"]=1
    EXPECTED_REBEL_SET["DEBUG_INFO_BTF"]=1
    PATCH_KCONFIG_FILTER[DEBUG_INFO]=1
    PATCH_KCONFIG_FILTER[DEBUG_INFO_BTF]=1
  else
    # Opt-out explícito (--no-btf / CIZEN_NO_BTF=1): sin BTF, paquete más pequeño.
    # DEBUG_INFO_BTF_MODULES cae solo (depende de DEBUG_INFO_BTF).
    add_unique disable "DEBUG_INFO_BTF"
  fi
}

build_effective_arrays

check_profile_contradictions() {
  local opt

  for opt in "${EFF_ENABLE[@]}"; do
    if [ -n "${SEEN_DISABLE[$opt]:-}" ]; then
      fatal "Contradicción en el perfil: '$opt' aparece tanto en ENABLE como en DISABLE."
    fi
    if [ -n "${EFF_SETVAL[$opt]:-}" ] || [ -n "${EFF_SETSTR[$opt]:-}" ]; then
      fatal "Contradicción en el perfil: '$opt' aparece en ENABLE y también en SETVAL/SETSTR."
    fi
  done

  for opt in "${EFF_DISABLE[@]}"; do
    if [ -n "${EFF_SETVAL[$opt]:-}" ] || [ -n "${EFF_SETSTR[$opt]:-}" ]; then
      fatal "Contradicción en el perfil: '$opt' aparece en DISABLE y también en SETVAL/SETSTR."
    fi
  done

  for opt in "${!EFF_SETVAL[@]}"; do
    if [ -n "${EFF_SETSTR[$opt]:-}" ]; then
      fatal "Contradicción en el perfil: '$opt' aparece simultáneamente en SETVAL y SETSTR."
    fi
  done
}

check_profile_contradictions

# ============================================================
# DEPENDENCIAS / PREREQUISITOS
# ============================================================
# Mapa comando -> paquete Arch para la instalación interactiva automática.
# Un comando exigido SIN entrada aquí (sudo, pacman, cizen-uki-sync...) no se
# puede autoinstalar de forma sensata y, si falta, aborta con instrucciones
# (igual que antes de esta versión).
declare -A TOOL_PKG=(
  [awk]=gawk          [bash]=bash          [bc]=bc
  [bison]=bison       [cat]=coreutils      [ccache]=ccache
  [cmp]=diffutils
  [cp]=coreutils      [date]=coreutils     [df]=coreutils
  [du]=coreutils      [find]=findutils     [findmnt]=util-linux
  [flex]=flex         [flock]=util-linux   [fuser]=psmisc
  [gcc]=gcc           [gpg]=gnupg          [grep]=grep
  [head]=coreutils    [id]=coreutils       [ls]=coreutils
  [make]=make         [mktemp]=coreutils   [mount]=util-linux
  [nproc]=coreutils   [pahole]=pahole     [perl]=perl        [rm]=coreutils
  [sed]=sed
  [sbctl]=sbctl
  [sleep]=coreutils   [sort]=coreutils     [stat]=coreutils
  [tar]=tar           [timeout]=coreutils  [tr]=coreutils
  [umount]=util-linux [wget]=wget          [xargs]=findutils
  [xz]=xz
  [clang]=clang          [lld]=lld          [llvm-ar]=llvm
  [llvm-nm]=llvm         [llvm-objcopy]=llvm [llvm-strip]=llvm
  [llvm-objdump]=llvm    [llvm-readelf]=llvm
  [ld.lld]=lld
  [mokutil]=mokutil      [openssl]=openssl  [dpkg]=dpkg
  [objcopy]=binutils     [readelf]=binutils
)

# Prompt sí/no interactivo siguiendo el patrón del script (leer de /dev/tty;
# sin terminal, la respuesta se declina al default "n"). Devuelve 0 = sí.
ask_user_yes() {
  local msg="$1" answer
  if [ "${CIZEN_NO_AUTOINSTALL:-0}" = "1" ]; then
    return 1
  fi
  if ! [ -t 0 ] && ! [ -t 1 ]; then
    warn "No hay terminal interactiva; se responde NO a: $msg"
    return 1
  fi
  read -r -p "$msg " answer < /dev/tty || answer="n"
  case "${answer:-s}" in
    s|S|si|SI|Sí|sí|y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Instala interactivamente los paquetes que faltan. Devuelve 0 si todo quedó
# instalado, 1 si la ejecución de pacman falló, 2 si fue rechazado/declinado.
install_dependency_packages() {
  local purpose="$1"; shift
  local -a pkgs=("$@")
  printf '\n'
  printf '  Faltan herramientas para %s: %s\n' "$purpose" "${pkgs[*]}"
  if ! ask_user_yes "¿Instalarlas con 'sudo pacman -S --needed ${pkgs[*]}'? [S/n]"; then
    warn "No se instalarán dependencias automáticamente."
    return 2
  fi
  if sudo pacman -S --needed "${pkgs[@]}"; then
    return 0
  fi
  err "Falló la instalación de dependencias: ${pkgs[*]}"
  return 1
}

check_prerequisites() {
  local cmd pkg rc _ccb
  local -a tools=(awk bash bc bison cat ccache cmp cp date df du find findmnt flex flock fuser grep gcc gpg head id ls make mktemp mount nproc pacman pahole perl rm sbctl sed sleep sort stat tar tr umount wget xargs xz timeout cizen-uki-sync)
  local -a missing_cmds=() missing_pkgs=()

  # Compilador de preferencia (--cc / CIZEN_CC): la familia clang exige ld.lld
  # (LLVM=1) y, con clang genérico, también clang. Un compilador CONCRETO
  # (gcc-14 / clang-17 / ruta) se exige igual que cualquier dependencia: si es
  # versionado se ofrece su paquete Arch homónimo (gcc14/clang17) vía el flujo
  # estándar de instalación; una ruta personal debe existir (no hay paquete que
  # adivinar) y se aborta si no. Nunca se degrada: tu elección es vinculante.
  if [ "$CC_FAMILY" = "clang" ]; then
    tools+=(ld.lld llvm-ar llvm-nm llvm-objcopy llvm-strip llvm-objdump llvm-readelf)
    [ "$CC_LAUNCHER" = "clang" ] && tools+=(clang)
  fi
  case "$CC_LAUNCHER" in
    gcc|clang) ;;
    *)
      _ccb="$(basename -- "$CC_LAUNCHER")"
      if [[ "$_ccb" =~ ^(gcc|clang)[-_]?[0-9]+$ ]]; then
        if ! command -v -- "$CC_LAUNCHER" >/dev/null 2>&1; then
          missing_cmds+=("$CC_LAUNCHER")
          missing_pkgs+=("${_ccb//-/}")
        fi
      else
        command -v -- "$CC_LAUNCHER" >/dev/null 2>&1 || \
          fatal "Compilador de preferencia no encontrado: $CC_LAUNCHER (instálalo o pasa una ruta válida)."
      fi
      unset _ccb
      ;;
  esac

  for cmd in "${tools[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      continue
    fi
    if [ -n "${TOOL_PKG[$cmd]:-}" ]; then
      missing_cmds+=("$cmd")
      missing_pkgs+=("${TOOL_PKG[$cmd]}")
    else
      fatal "Falta dependencia sin paquete Arch asociado: $cmd (instálala manualmente y reintenta)."
    fi
  done

  # sudo no puede autoinstalarse (ni funcionaría sin él): si falta, se aborta
  # con instrucciones, igual que siempre.
  if [ ! -x "$(command -v sudo 2>/dev/null || true)" ]; then
    fatal "Falta sudo en PATH (instálalo como root: pacman -S sudo)."
  fi

  # modprobed-db (AUR) es obligatorio para el keep-list persistente en modo
  # lite (default CIZEN_MODPROBED_DB=1 = auto-descubrimiento). No está en los
  # repos oficiales de Arch, así que no se autoinstala con pacman: si falta se
  # aborta sugiriendo la instalación AUR. CIZEN_MODPROBED_DB=0
  # (--no-modprobed-db) la exime explícitamente.
  if [ "${CIZEN_MODPROBED_DB:-1}" != "0" ] && ! command -v modprobed-db >/dev/null 2>&1; then
    fatal "modprobed-db (AUR) no está instalado (dependencia requerida del keep-list --lite). Instálalo con: yay -S modprobed-db"
  fi

  # Deduplicar paquetes: varios comandos comparten coreutils/util-linux/etc.
  local -a pkgs=()
  for pkg in "${missing_pkgs[@]}"; do
    case " ${pkgs[*]} " in
      *" $pkg "*) ;;
      *) pkgs+=("$pkg") ;;
    esac
  done

  [ "${#pkgs[@]}" -eq 0 ] && return 0

  install_dependency_packages "el flujo del kernel" "${pkgs[@]}"
  rc=$?
  if [ "$rc" = 0 ]; then
    for cmd in "${missing_cmds[@]}"; do
      command -v "$cmd" >/dev/null 2>&1 || fatal "La instalación no dejó '$cmd' disponible en PATH (paquete ${TOOL_PKG[$cmd]})."
    done
    ok "Dependencias requeridas instaladas: ${pkgs[*]}"
  elif [ "$rc" = 1 ]; then
    fatal "No se pudieron instalar las dependencias requeridas. Comando sugerido: sudo pacman -S ${pkgs[*]}"
  else
    fatal "Faltan dependencias requeridas: ${missing_cmds[*]}. Instálalas manualmente con: sudo pacman -S ${pkgs[*]}"
  fi
}

# aria2c es OPCIONAL (descarga paralela). Solo se sugiere cuando va a usarse:
# justo antes de una descarga real y a menos que se fuerce wget o el
# autoinstalado esté desactivado. Declinar nunca bloquea (se sigue con wget).
ensure_optional_aria2c() {
  [ "${CIZEN_DOWNLOADER:-}" != "wget" ] || return 0
  command -v aria2c >/dev/null 2>&1 && return 0

  if [ "${CIZEN_NO_AUTOINSTALL:-0}" != "1" ] && ask_user_yes "aria2c mejora la descarga (conexiones paralelas). ¿Instalarlo ('sudo pacman -S --needed aria2')? [S/n]"; then
    if sudo pacman -S --needed aria2 && command -v aria2c >/dev/null 2>&1; then
      ok "aria2c instalado; la descarga usará conexiones paralelas."
    else
      warn "No quedó aria2c disponible tras la instalación; se usará wget (un hilo)."
    fi
  else
    warn "Descarga con wget (un hilo). Para paralelismo: sudo pacman -S aria2"
  fi
  return 0
}

# Preflight opcional de privilegios: comprueba temprano, sin modificar nada,
# que las operaciones privilegiadas que el script usará más adelante están
# permitidas por el sudoers del sistema. La ausencia de alguna no aborta
# (la instalación puede fallar por otras razones), pero avisa ANTES de gastar
# minutos compilando si el sudoers es restrictivo y la fase final fallará.
# Requiere ticket sudo vigente (se invoca después de sudo -v); si no hay
# ticket, simplemente se omite la verificación.
check_sudo_capabilities() {
  local cmd
  local -a required=(mount umount find stat mkdir cp mv rm fuser sync pacman)
  local -a missing=()

  sudo -n true 2>/dev/null || {
    log "sudo sin ticket vigente; no se verifica la lista de comandos privilegiados."
    return 0
  }

  for cmd in "${required[@]}"; do
    if ! sudo -n "$cmd" --version >/dev/null 2>&1 &&
       ! sudo -n "$cmd" -V >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    warn "Verificación de privilegios sudo incompleta para: ${missing[*]}."
    warn "Si tu sudoers es restrictivo, estas operaciones fallarán en la instalación/sincronización de la UKI. Revisa la salida de: sudo -l"
  fi
}

# ============================================================
# PRIVILEGIOS: por qué sudo es un prerrequisito y no un trámite
# ============================================================
# Un `sudo -v` fallido abortaba el build con el ERR trap y un
# "Error 1 en línea 8614: sudo -v" que no dice ni por qué falló ni qué hacer.
# Con el ticket caducado (sudo caduca a los 5 minutos por defecto, y un build
# dura 20+) la pregunta sale igualmente, pero al final, cuando ya has gastado la
# compilación.
#
# La contraseña NO es opcional en general: el allowlist NOPASSWD de este host
# cubre mount/umount/install/pacman/swapon/swapoff/systemctl, pero el motor
# necesita además chown, mkdir, sbctl, cizen-uki-sync... Por eso "seguir sin
# ticket" solo es válido si todo lo imprescindible está cubierto, y eso es lo
# que se comprueba en vez de asumirlo.
#
# Inventario de las operaciones que el motor hace con sudo en el camino normal
# de un build. No es la lista de cada `sudo x` del script (hay llamadas
# condicionales, de otros backends y de mensajes al usuario), sino la de lo que
# se usa de verdad aquí; si añades una operación privilegiada al camino normal,
# añádela también (hay un test que lo vigila).
SUDO_OPS_REQUERIDOS=(mount umount install pacman chown mkdir rm)
SUDO_OPS_OPCIONALES=(swapon swapoff mv cp find stat test sync cat tee od tar
                     du openssl make sbctl mokutil fuser cizen-uki-sync)

# Comandos que el allowlist NOPASSWD cubre, uno por línea y solo el basename.
# `sudo -n -l` no necesita contraseña, así que esto se puede saber siempre, haya
# ticket o no.
#
# Solo se leen los bloques NOPASSWD: el resto de la salida de `sudo -l` no es una
# lista de comandos, y sus rutas (secure_path, Defaults!/usr/bin/visudo) producían
# basura tipo "bin", "sbin" o incluso "binRunas" al pegarse con la línea
# siguiente. Antes de filtrar se unen las líneas de continuación que usa sudo
# para las listas largas, y un "NOPASSWD: ALL" se marca como cobertura total.
sudo_nopasswd_cover() {
  local lista
  # OJO con el `&&`: dentro de una tubería se come la cola entera
  # (`... | grep -qx ALL && { ... } | sed | grep | sort` solo ejecutaba el resto
  # si aparecía un "ALL"), así que el chequeo va en su propia sentencia.
  lista="$(sudo -n -l 2>/dev/null |
    awk '
      {
        if (cont) { linea = linea $0; cont = 0 } else { linea = $0 }
        if (linea ~ /\\$/) { sub(/\\$/, "", linea); cont = 1 } else { print linea }
      }
      END { if (cont) print linea }
    ' |
    awk '
      /NOPASSWD:/ {
        sub(/^.*NOPASSWD:[ \t]*/, "")
        gsub(/\\/, " ")
        print
      }
    ' |
    tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if printf '%s\n' "$lista" | grep -qx 'ALL'; then
    printf '*\n'
    return 0
  fi
  printf '%s\n' "$lista" |
    grep -oE '/[a-zA-Z0-9._/+-]*/[a-zA-Z0-9._+-]+' | sed 's|.*/||' | sort -u
}

# Operaciones de un grupo que el allowlist no cubre. Vacío = todo cubierto.
sudo_missing_ops() { # $1=requeridos|opcionales
  local -a ops=()
  case "${1:-requeridos}" in
    opcionales) ops=("${SUDO_OPS_OPCIONALES[@]}") ;;
    *)          ops=("${SUDO_OPS_REQUERIDOS[@]}") ;;
  esac
  local cover op
  cover="$(sudo_nopasswd_cover)"
  # '*' = NOPASSWD: ALL: no falta nada, y sin este case cada operación saldría
  # como faltante porque "*" no es igual a ningún nombre de comando.
  [ "$cover" = "*" ] && return 0
  local out=""
  for op in "${ops[@]}"; do
    printf '%s\n' "$cover" | grep -qx -- "$op" || out="${out:+$out }$op"
  done
  printf '%s' "$out"
}

# Explica el hueco en vez de dejar que el ERR trap suelte una línea de código.
sudo_explain_no_ticket() { # $1=motivo $2=requeridos que faltan $3=opcionales que faltan
  local motivo="$1" faltan="$2" opcionales="$3"
  local user="${SUDO_USER:-$(id -un)}" cubiertos
  cubiertos="$(sudo_nopasswd_cover | tr '\n' ' ')"
  [ "$cubiertos" = "* " ] && cubiertos="todo (allowlist NOPASSWD: ALL)"
  warn "sudo sin ticket vigente: $motivo"
  if [ -n "$cubiertos" ]; then
    log "  Sí dispensan contraseña (allowlist NOPASSWD): $cubiertos"
  fi
  if [ -n "$faltan" ]; then
    warn "  Y el build necesita privilegios que NO están en esa lista: $faltan"
  fi
  if [ -n "$opcionales" ]; then
    warn "  Además, esto pedirá contraseña más adelante si hace falta: $opcionales"
  fi
  echo
  info "Comprueba la contraseña en una terminal, sin el build de por medio:"
  printf '    sudo -k; sudo -v\n'
  printf "  Si tampoco la acepta ahí, no es cosa del motor: tu contraseña de $user no es la que estás tecleando (o el teclado está en otro layout). 'passwd -S %s' dice cuándo se cambió por última vez.\n" "$(id -un)"
  printf '    passwd -S %s\n' "$(id -un)"
}

# Preflight de privilegios. Devuelve 0 si el build puede continuar.
preflight_sudo() { # [1]="tras compilar" para el mensaje del segundo prompt
  local fase="${1:-}" user motivo faltan opcionales

  # 1) Ya hay ticket: no preguntar nada (ni se puede si no hay tty).
  if sudo -n true 2>/dev/null; then
    return 0
  fi

  # 2) Sin ticket: hay que pedirlo, pero solo si hay a quién preguntar. Un
  #    build no-tty (cron, CI) no puede autenticarse: se dice, no se reintenta.
  if [ -t 0 ] && [ -t 1 ]; then
    if sudo -v; then
      return 0
    fi
    motivo="sudo rechazó la contraseña de ${SUDO_USER:-$(id -un)} tras 3 intentos"
  else
    motivo="no hay terminal para pedir la contraseña de ${SUDO_USER:-$(id -un)}"
  fi

  # 3) Ni ticket ni prompt posible: ver exactamente qué falta antes de decidir.
  faltan="$(sudo_missing_ops requeridos)"
  opcionales="$(sudo_missing_ops opcionales)"
  sudo_explain_no_ticket "$motivo" "$faltan" "$opcionales"

  if [ -n "$faltan" ]; then
    if [ -n "$fase" ]; then
      fatal "$fase: sudo rechaza la contraseña y faltan privilegios ($faltan). El build NO se pierde: el paquete está en el tmpfs y puedes instalarlo a mano con 'sudo pacman -U <pkg>'. No desmontes $TMPFS_ROOT (CIZEN_KEEP_TMPFS=1)."
    fi
    fatal "sudo rechaza la contraseña y faltan privilegios ($faltan): no se puede montar el tmpfs ni instalar el kernel. Arregla la contraseña (ver arriba) y repite; aún no se ha compilado nada."
  fi

  # Todo lo imprescindible va por NOPASSWD: se puede seguir sin ticket.
  warn "Se sigue sin ticket sudo: lo imprescindible está en el allowlist NOPASSWD."
  [ -n "$opcionales" ] && warn "  Si alguna de estas lo necesita, pedirá contraseña en su momento: $opcionales"
  return 0
}

# ============================================================
# ESPACIO / TMPFS / LOCK / DIRECTORIOS
# ============================================================
get_avail_mb() {
  local dir="$1" kb
  kb="$(df -Pk "$dir" | awk 'NR==2 {print $4}')"
  echo $(( ${kb:-0} / 1024 ))
}

# Memoria disponible del SISTEMA (no del tmpfs): es la magnitud que se recupera
# al desmontar el árbol de compilación, así que es la que se mide para poder
# decir cuántos GB volvieron a la RAM.
get_mem_available_mb() {
  local kb
  kb="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
  echo $(( ${kb:-0} / 1024 ))
}

prepare_dirs() {
  mkdir -p "$KERNEL_BUILD_ROOT" "$TMPFS_ROOT" "$(dirname "$LOCK_FILE")"
}

# La promoción de la config base (promote_base_config) exige que CONFIG_DIR sea
# escribible por el usuario que compila (CHANGELOG v27.21.17). Se verifica al
# arrancar la operación para fallar rápido y con mensaje claro, ANTES de
# descargar/compilar. Crea el directorio si no existía (equivale a prepare_dirs).
ensure_config_dir_writable() {
  if [ ! -e "$CONFIG_DIR" ]; then
    mkdir -p -- "$CONFIG_DIR" 2>/dev/null || {
      fatal "CONFIG_DIR no existe y no puede crearse: $CONFIG_DIR (apunta CIZEN_CONFIG_DIR a un directorio creable)."
    }
  fi
  if [ ! -d "$CONFIG_DIR" ] || [ ! -w "$CONFIG_DIR" ]; then
    fatal "CONFIG_DIR no es escribible por $(id -un): $CONFIG_DIR. La promoción de la config base la exige; dale ownership (chown) o apunta CIZEN_CONFIG_DIR a un directorio propio."
  fi
}

tmpfs_is_mounted() {
  [ "$(findmnt -n -M "$TMPFS_ROOT" -o FSTYPE 2>/dev/null | head -n1 || true)" = "tmpfs" ]
}

# Desmonta el tmpfs de compilación, incluidos los montajes APILADOS que hubiera
# (un solo umount no basta y dejaría la RAM retenida, que es justo lo que este
# flujo viene a devolver). Si algo lo usa, no se fuerza con -l: se informa.
#   0 = desmontado   1 = sigue montado (EBUSY, credenciales, lo que sea)
# Hasta v27.31.18 el stderr de umount se descartaba, así que un EBUSY (proceso
# del pipeline que aún sujetaba el árbol) era invisible: el build terminaba
# "bien" con 7 GB de tmpfs ocupado. Ahora el error se conserva y se reporta.
TMPFS_UMOUNT_ERR=""
tmpfs_umount_all() {
  local n=0 max=4
  TMPFS_UMOUNT_ERR=""
  while [ "$n" -lt "$max" ]; do
    findmnt -n -M "$TMPFS_ROOT" -o TARGET 2>/dev/null | grep -q . || return 0
    # OJO: sin sonda previa tipo `sudo -n true`. Con un allowlist de sudoers
    # por comando (como este host) la sonda se deniega aunque el umount sí esté
    # permitido, y se abortaba el desmontaje sin intentarlo nunca.
    if ! TMPFS_UMOUNT_ERR="$(sudo -n umount "$TMPFS_ROOT" 2>&1)"; then
      return 1
    fi
    n=$((n + 1))
  done
  if findmnt -n -M "$TMPFS_ROOT" -o TARGET 2>/dev/null | grep -q .; then
    return 1
  fi
  return 0
}

verify_tmpfs_ownership() {
  local expected_uid expected_gid actual_uid actual_gid
  expected_uid="$(id -u)"
  expected_gid="$(id -g)"
  actual_uid="$(stat -c '%u' "$TMPFS_ROOT" 2>/dev/null || echo -1)"
  actual_gid="$(stat -c '%g' "$TMPFS_ROOT" 2>/dev/null || echo -1)"

  if [ "$actual_uid" != "$expected_uid" ] || [ "$actual_gid" != "$expected_gid" ]; then
    warn "El remount no dejó el propietario esperado en el tmpfs; se corrige explícitamente con chown."
    sudo chown "$expected_uid:$expected_gid" "$TMPFS_ROOT"
    actual_uid="$(stat -c '%u' "$TMPFS_ROOT" 2>/dev/null || echo -1)"
    actual_gid="$(stat -c '%g' "$TMPFS_ROOT" 2>/dev/null || echo -1)"
  fi

  [ "$actual_uid" = "$expected_uid" ] && [ "$actual_gid" = "$expected_gid" ] || fatal "No se pudo establecer el propietario correcto del tmpfs: uid=$actual_uid gid=$actual_gid"
}

prepare_tmpfs_build() {
  local owner_uid owner_gid fstype mount_target avail_mb min_required

  mkdir -p "$TMPFS_ROOT"

  fstype="$(findmnt -n -M "$TMPFS_ROOT" -o FSTYPE 2>/dev/null | head -n1 || true)"
  mount_target="$(findmnt -n -M "$TMPFS_ROOT" -o TARGET 2>/dev/null | head -n1 || true)"
  # Montajes APILADOS en el mismo punto: se dan cuando un umount se queda a
  # medias (proceso usando el tmpfs) y se vuelve a montar encima. findmnt -M
  # devuelve una línea por montaje, así que sin head -n1 las comparaciones de
  # abajo fallaban con un "tmpfs\ntmpfs" ilegible y el motor se paraba sin
  # motivo aparente. Se avisa y se sigue con el montaje visible.
  local stacked
  stacked="$(findmnt -n -M "$TMPFS_ROOT" -o TARGET 2>/dev/null | grep -c . || true)"
  if [ "${stacked:-0}" -gt 1 ]; then
    warn "$TMPFS_ROOT tiene $stacked montajes apilados (umount interrumpido en alguna ejecución anterior); se sigue con el más reciente. Para limpiarlos todos: for i in $(seq $stacked); do sudo umount $TMPFS_ROOT; done"
  fi
  unset stacked

  if [ -n "$fstype" ]; then
    if [ "$fstype" != "tmpfs" ] || [ "$mount_target" != "$TMPFS_ROOT" ]; then
      fatal "KERNEL_TMPFS_ROOT ya está ocupado por '$fstype' en '$mount_target'; no se modifica."
    fi

    TMPFS_MOUNTED=true
    TMPFS_CREATED_BY_SCRIPT=false
    log "tmpfs de compilación ya montado; se reutiliza"
  else
    if find "$TMPFS_ROOT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      fatal "El punto de montaje $TMPFS_ROOT no está vacío; no se monta encima para proteger datos existentes."
    fi

    owner_uid="$(id -u)"
    owner_gid="$(id -g)"
    log "Montando tmpfs de $TMPFS_SIZE para la compilación: $TMPFS_ROOT"
    sudo -v >/dev/null 2>&1 || true   # el preflight ya validó esto; no repreguntar
    if ! sudo mount -t tmpfs -o "size=$TMPFS_SIZE,mode=0755,uid=$owner_uid,gid=$owner_gid,exec,nosuid,nodev,huge=advise" tmpfs "$TMPFS_ROOT"; then
      fatal "No se pudo montar el tmpfs de compilación en $TMPFS_ROOT."
    fi
    TMPFS_MOUNTED=true
    TMPFS_CREATED_BY_SCRIPT=true
    verify_tmpfs_ownership
  fi

  avail_mb="$(get_avail_mb "$TMPFS_ROOT")"
  min_required="$TMPFS_MIN_FREE_MB"
  if source_tree_reusable; then
    min_required="$TMPFS_EXISTING_SRC_MIN_FREE_MB"
  fi
  if [ "$avail_mb" -lt "$min_required" ]; then
    # v27.25.5: al reutilizar el árbol, los artefactos re-generables del enlace
    # final (vmlinux*, .tmp_vmlinux*, System.map) suelen llenar el tmpfs tras un
    # build reciente. Se purgan ANTES de declarar falta de espacio: se vuelven a
    # enlazar en minutos, y se conservan .o/.a (la inversión grande) y paquetes.
    if source_tree_reusable; then
      local __purged=0 __art
      while IFS= read -r -d '' __art; do
        rm -f -- "$__art"
        __purged=1
      done < <(find "$SRC" -maxdepth 1 -type f \( -name 'vmlinux' -o -name 'vmlinux.o' -o \
          -name 'vmlinux.unstripped' -o -name 'System.map' -o -name '.tmp_vmlinux*' \) -print0)
      unset __art
      if [ "$__purged" = 1 ]; then
        log "Artefactos del enlace purgados (se regenerarán durante el build)."
        avail_mb="$(get_avail_mb "$TMPFS_ROOT")"
      fi
      unset __purged
    fi
    if [ "$avail_mb" -lt "$min_required" ]; then
      fatal "El tmpfs deja solo ${avail_mb} MB libres; mínimo operativo requerido: ${min_required} MB. Ajusta KERNEL_TMPFS_MIN_FREE_MB/KERNEL_TMPFS_EXISTING_SRC_MIN_FREE_MB o reduce JOBS."
    fi
  fi
}

unmount_tmpfs_build() {
  [ "$TMPFS_MOUNTED" = true ] || return 0
  # Estado para el informe final: unmounted | failed | kept | not-mounted.
  TMPFS_UMOUNT_STATUS="not-mounted"
  TMPFS_UMOUNT_NOTE=""

  # Tras un flujo completo exitoso el tmpfs ya no hace falta: se desmonta SIEMPRE
  # (v27.31.19: requisito explícito — el éxito total implica devolver la RAM, y
  # no un optional que se puede perder). CIZEN_KEEP_TMPFS=1 es el único opt-out
  # y se dice en el informe final para que quede constancia.
  # Los flujos parciales (p. ej. solo check) nunca desmontan, para que un
  # kcheck prepare el entorno y el kbuild siguiente lo reutilice.
  if [ "$FULL_PIPELINE_OK" = true ] && [ "$CIZEN_KEEP_TMPFS" != "1" ]; then
    if tmpfs_is_mounted; then
      local used_mb=0 before_mb after_mb attempt
      before_mb="$(get_mem_available_mb)"
      log "Desmontando tmpfs de compilación (flujo completo exitoso): $TMPFS_ROOT"
      if sudo -v >/dev/null 2>&1 || true; then :; fi
      # Dos intentos: lo que suele sujetar el montaje es un subproceso del
      # propio pipeline que está terminando, y a los pocos segundos ya no está.
      for attempt in 1 2; do
        if tmpfs_umount_all; then
          after_mb="$(get_mem_available_mb)"
          used_mb=$(( after_mb - before_mb ))
          [ "$used_mb" -lt 0 ] && used_mb=0
          TMPFS_UMOUNT_STATUS="unmounted"
          TMPFS_UMOUNT_NOTE="$used_mb"
          if [ "$used_mb" -ge 1024 ]; then
            ok "tmpfs desmontado: $TMPFS_ROOT (~$(( used_mb / 1024 )) GB devueltos a la RAM)"
          else
            ok "tmpfs desmontado: $TMPFS_ROOT (~${used_mb} MB devueltos a la RAM)"
          fi
          TMPFS_MOUNTED=false
          TMPFS_CREATED_BY_SCRIPT=false
          return 0
        fi
        [ "$attempt" = "1" ] && sleep 2
      done
      TMPFS_UMOUNT_STATUS="failed"
      TMPFS_UMOUNT_NOTE="sigue montado tras 2 intentos"
      warn "No se pudo desmontar $TMPFS_ROOT; queda conservado y la RAM sigue ocupada."
      if printf '%s' "$TMPFS_UMOUNT_ERR" | grep -qi 'password is required\|a terminal\|not in the sudoers'; then
        warn "  Causa: sin credenciales sudo utilizables. Ejecuta 'sudo -v' en una terminal y repite el build."
      else
        warn "  Causa: $TMPFS_UMOUNT_ERR"
        if command -v fuser >/dev/null 2>&1; then
          local holders
          holders="$(fuser -m "$TMPFS_ROOT" 2>/dev/null | tr -s ' ' | cut -c1-200)"
          [ -n "$holders" ] && warn "  Procesos dentro del tmpfs:${holders}"
        fi
      fi
      warn "  Para liberarla a mano: sudo umount $TMPFS_ROOT"
      warn "  Para dejarla siempre montada entre builds: CIZEN_KEEP_TMPFS=1"
    else
      TMPFS_UMOUNT_STATUS="not-mounted"
    fi
  elif [ "$FULL_PIPELINE_OK" = true ] && [ "$CIZEN_KEEP_TMPFS" = "1" ]; then
    TMPFS_UMOUNT_STATUS="kept"
    TMPFS_UMOUNT_NOTE="CIZEN_KEEP_TMPFS=1"
    info "CIZEN_KEEP_TMPFS=1: el tmpfs se conserva montado a propósito ($TMPFS_ROOT)."
  fi

  # Por defecto el tmpfs dedicado se conserva montado deliberadamente entre
  # ejecuciones, para que un kcheck prepare el entorno y el kbuild siguiente
  # lo reutilice sin desmontar/recrear el filesystem temporal.
  if ! tmpfs_is_mounted; then
    TMPFS_MOUNTED=false
    TMPFS_CREATED_BY_SCRIPT=false
  fi
}

cleanup_kernel_cache() {
  local current_tarball current_sig current_verified item base keep
  current_tarball="$(basename -- "$TARBALL")"
  current_sig="$(basename -- "$SIG_FILE")"
  current_verified="${current_tarball}.verified-ok"

  mkdir -p "$KERNEL_BUILD_ROOT"

  # Solo se conservan el tarball, su firma y su huella de verificación de la
  # versión solicitada (del árbol vanilla linux-X.Y.Z.tar.xz o del fork
  # cachyos-X.Y.Z-N.tar.gz). No se tocan gnupg/, kernel-update.lock ni otros
  # elementos ajenos a artefactos.
  shopt -s nullglob
  # Limpia todos los artefactos de tarball/firma antiguos, incluidos temporales
  # de descargas interrumpidas. La versión objetivo se conserva solo bajo sus
  # nombres definitivos, nunca con sufijos .download/.bad/.partial.
  for item in "$KERNEL_BUILD_ROOT"/*.tar.xz* "$KERNEL_BUILD_ROOT"/*.tar.gz*; do
    base="$(basename -- "$item")"
    keep=false
    case "$base" in
      "$current_tarball"|"$current_sig"|"$current_verified") keep=true ;;
    esac
    if [ "$keep" = false ]; then
      rm -f -- "$item"
      log "Cache limpiado: $(basename -- "$item")"
    fi
  done
  shopt -u nullglob
}

cleanup_old_source_trees() {
  local dir name version_num
  [ -d "$TMPFS_ROOT" ] || return 0

  shopt -s nullglob
  local -a trees=("$TMPFS_ROOT"/linux-*)
  shopt -u nullglob
  [ "${#trees[@]}" -eq 0 ] && return 0

  # GUARDA: nunca borrar árboles bajo un directorio que NO sea el tmpfs de
  # compilación dedicado. Si TMPFS_ROOT no está montado como tmpfs (p. ej.
  # KERNEL_TMPFS_ROOT mal configurado apuntando a un directorio persistente
  # con árboles linux-*), no se puede distinguir fuentes de esta herramienta
  # de datos ajenos: no se elimina nada y prepare_tmpfs_build() abortará
  # después porque solo monta sobre un punto de montaje vacío. En el flujo
  # normal el tmpfs de la ejecución anterior sigue montado y esta limpieza
  # actúa exactamente igual que siempre.
  if ! tmpfs_is_mounted; then
    warn "TMPFS_ROOT no está montado como tmpfs ($TMPFS_ROOT); no se elimina ningún árbol de fuentes antiguo."
    return 0
  fi

  for dir in "${trees[@]}"; do
    [ -d "$dir" ] || continue
    name="$(basename -- "$dir")"
    version_num="${name#linux-}"
    [ "$version_num" = "$VERSION" ] && continue

    if [ -f "$dir/Makefile" ]; then
      log "Eliminando árbol de fuentes antiguo del tmpfs: $dir"
      rm -rf -- "$dir"
    fi
  done
}

# ============================================================
# RECONCILIACIÓN DEL tmpfs Y DESMONTAJE INTELIGENTE (v27.31.17)
# ============================================================
# El directorio del árbol solo lleva la versión ($TMPFS_ROOT/linux-X.Y.Z), así
# que "reutilizar el árbol" mixing es silencioso: un vanilla conservado de una
# ejecución anterior se reutilizaría para un build del fork de la MISMA versión
# (los parches -cachy no aplican) y un vanilla de OTRA versión se reutilizaría
# con el margen de espacio incremental. Nada de eso puede fallar en un sitio
# útil: o compila el kernel equivocado, o revienta con ENOSPC a mitad.
#
# Antes del chequeo de espacio (que decide con márgenes distintos según haya o
# no un árbol reutilizable) se reconcilia el tmpfs con lo que este build va a
# compilar. Cada linux-* se clasifica por su identidad real (versión + tipo, y
# el tipo lo determina el parche/scheduler elegido):
#
#   reutilizable  misma versión y mismo tipo -> se conserva tal cual
#   otro tipo     misma versión, vanilla<->cachyos -> NUNCA se mezcla
#   otra versión  no puede servir a este build
#
# Lo que no es reutilizable se descarta siempre (mezclar es peor que
# reextraer). Si tras el descarte no queda ningún árbol aprovechable y el
# tmpfs no guarda nada más que preservar (paquetes/artefactos), se DESMONTA
# entero: borra lo que quedaba de golpe, devuelve la RAM a la RAM del sistema
# y prepare_tmpfs_build lo vuelve a montar vacío y limpio, sin residuos de la
# ejecución anterior. Con CIZEN_SMART_UMOUNT=0 o CIZEN_KEEP_TMPFS=1 se purga
# dentro del tmpfs en lugar de desmontarlo.
reconcile_tmpfs_trees() {
  local dir id ver kind kept=0 purged=0 others
  tmpfs_is_mounted || return 0

  shopt -s nullglob
  local -a trees=("$TMPFS_ROOT"/linux-*)
  shopt -u nullglob
  [ "${#trees[@]}" -eq 0 ] && return 0

  for dir in "${trees[@]}"; do
    [ -d "$dir" ] && [ -f "$dir/Makefile" ] || continue
    id="$(tree_identity "$dir")"
    ver="${id%%|*}"
    kind="${id#*|}"
    if tree_usable_for "$dir" "$VERSION" "$KERNEL_TREE"; then
      kept=1
      log "Árbol de fuentes reutilizable: $dir ($ver, $kind)"
      continue
    fi
    if [ -f "$TMPFS_ROOT/.cizen-extracting-$ver" ] || [ -f "$TMPFS_ROOT/.cizen-extracting-$VERSION" ]; then
      warn "Descartando $dir: extracción interrumpida (a medias, versión $ver). No se reutiliza un árbol incompleto."
    elif [ "$ver" = "$VERSION" ] || [[ "$ver" == "$VERSION"-* ]]; then
      warn "Descartando $dir: es $kind y este build compila $KERNEL_TREE${TREE_FORCE_NOTE:+ ($TREE_FORCE_NOTE)}. Un árbol de otro tipo no se reutiliza nunca (los parches -cachy no aplican sobre vanilla y al revés)."
    else
      warn "Descartando $dir: es $ver y este build compila $VERSION."
    fi
    rm -rf -- "$dir"
    purged=1
  done
  unset dir id ver kind

  [ "$purged" = 1 ] || return 0
  # Los árboles descartados se van con su testigo de extracción; el único que
  # podría seguir vivo es el reutilizable, que por definición no lo tiene.
  rm -f "$TMPFS_ROOT"/.cizen-extracting-* 2>/dev/null || true
  if [ "$kept" = 1 ]; then
    ok "tmpfs depurado: se conserva el árbol de este build, ya no caben árboles ajenos."
    return 0
  fi
  if [ "$CIZEN_KEEP_TMPFS" = "1" ] || [ "$CIZEN_SMART_UMOUNT" = "0" ]; then
    info "CIZEN_KEEP_TMPFS/CIZEN_SMART_UMOUNT lo impiden: el tmpfs se conserva (ya sin árboles de fuentes incompatibles)."
    return 0
  fi
  # Solo se desmonta si no queda nada más en el tmpfs que merezca la pena
  # (paquetes o artefactos de una ejecución anterior). Los marcadores propios
  # (.build-marker-*, .cizen-*) no cuentan, y los árboles son directorios: un
  # fichero linux-*.pkg.tar.zst SÍ cuenta (no es un árbol).
  others="$(find "$TMPFS_ROOT" -mindepth 1 -maxdepth 1 \
    ! -name '.build-marker-*' ! -name '.cizen-*' \
    \( ! -type d -o ! -name 'linux-*' \) -print 2>/dev/null | head -n5 || true)"
  if [ -n "$others" ]; then
    info "El tmpfs guarda además otras entradas (paquetes/artefactos): no se desmonta, solo se descartaron los árboles incompatibles."
    return 0
  fi
  log "Ningún árbol del tmpfs sirve para este build ($VERSION, $KERNEL_TREE${TREE_FORCE_NOTE:+, $TREE_FORCE_NOTE}): se desmonta para devolver la RAM y empezar de un tmpfs limpio."
  # `sudo -v` aquí es solo para renovar la credencial cacheada: si no se puede
  # (sin TTY, credencial caducada...) NO se aborta la build, se intenta el
  # umount igualmente y, si tampoco, se sigue con el tmpfs actual: los árboles
  # incompatibles ya se descartaron, que es lo que evita la mezcla.
  sudo -v >/dev/null 2>&1 || true
  if tmpfs_umount_all; then
    ok "tmpfs desmontado (los árboles incompatibles se descartaron): $TMPFS_ROOT"
    TMPFS_MOUNTED=false
    TMPFS_CREATED_BY_SCRIPT=false
  else
    warn "No se pudo desmontar $TMPFS_ROOT (¿proceso usándolo?); los árboles incompatibles ya se descartaron, se continúa sobre el tmpfs actual."
  fi
}

check_disk_space() {
  local min_mb=8192 avail_mb

  # El tarball se almacena en persistencia.
  avail_mb="$(get_avail_mb "$KERNEL_BUILD_ROOT")"
  if [ "$avail_mb" -lt "$min_mb" ]; then
    fatal "Espacio insuficiente en el cache persistente ($KERNEL_BUILD_ROOT: ${avail_mb} MB disponibles, se requieren ${min_mb} MB). Libera espacio o establece KERNEL_BUILD_ROOT en otro filesystem."
  fi
}

# ============================================================
# SUDO KEEP-ALIVE PARA BUILDS LARGAS
# ============================================================
SUDO_KEEP_PID=""
sudo_keepalive_start() {
  [ -n "${SUDO_KEEP_PID:-}" ] && return 0
  (
    trap 'exit 0' TERM INT
    while kill -0 "$$" 2>/dev/null; do
      sudo -n -v 2>/dev/null || exit 0
      # El sleep se lanza en segundo plano y se espera con `wait` a propósito:
      # un `sleep` en primer plano difiere el trap TERM/INT hasta que el propio
      # sleep termina por sí solo (comportamiento documentado de Bash), lo que
      # dejaba a sudo_keepalive_stop() esperando hasta 60s tras cada build.
      # `wait` sobre un job en segundo plano sí es interrumpible de inmediato.
      sleep 60 &
      wait "$!"
    done
  ) &
  SUDO_KEEP_PID=$!
}

sudo_keepalive_stop() {
  if [ -n "${SUDO_KEEP_PID:-}" ]; then
    kill "$SUDO_KEEP_PID" 2>/dev/null || true
    wait "$SUDO_KEEP_PID" 2>/dev/null || true
    SUDO_KEEP_PID=""
  fi
}

# ============================================================
# TRAPS / LIMPIEZA
# ============================================================
CLEANUP_DONE=false
INTERRUPT_CAUGHT=false

cleanup_success() {
  [ "$CLEANUP_DONE" = true ] && return 0
  CLEANUP_DONE=true

  # Nunca intentar desmontar el tmpfs mientras el shell tenga su cwd dentro
  # del punto de montaje. El flujo principal hace `cd "$SRC"` durante la build.
  # Volver a un directorio persistente libera la referencia al mountpoint.
  cd "$HOME" || cd /

  rm -f "$BUILD_MARKER" 2>/dev/null || true

  # Tras un flujo COMPLETO y exitoso el tmpfs (y con él el árbol) se desmonta:
  # el requisito es devolver la RAM, no conservar 7 GB por si acaso. Solo los
  # flujos parciales (p. ej. un check que prepara el entorno) lo dejan montado
  # para que el build siguiente lo reutilice; y CIZEN_KEEP_TMPFS=1 lo mantiene
  # a propósito, en cuyo caso el árbol sí se conserva para reutilizarlo.
  if [ -d "$SRC" ] && [ "$CIZEN_KEEP_TMPFS" = "1" ]; then
    log "Fuentes conservadas para reutilización: $SRC"
  fi
  unmount_tmpfs_build
}


cleanup_interrupt() {
  local sig="$1"
  INTERRUPT_CAUGHT=true
  echo
  warn "Interrupción recibida ($sig)."
  if [ -d "$SRC" ]; then
    warn "Se conserva el árbol de fuentes para poder reanudar/depurar: $SRC"
  fi
  if [ -f "$TARBALL" ]; then
    log "Tarball conservado: $TARBALL"
  fi
  if [ "$TMPFS_MOUNTED" = true ]; then
    if [ "$TMPFS_CREATED_BY_SCRIPT" = true ]; then
      warn "El tmpfs montado por este script se mantiene disponible para diagnóstico: $TMPFS_ROOT"
      warn "Cuando termines el diagnóstico: sudo umount ${TMPFS_ROOT}"
    else
      warn "El tmpfs ya existente se mantiene montado: $TMPFS_ROOT"
    fi
  fi
  err "Operación cancelada."
  exit 130
}

trap 'cleanup_interrupt INT' INT
trap 'cleanup_interrupt TERM' TERM

cleanup_tmpfs_on_exit() {
  local rc=$?

  sudo_keepalive_stop

  # Nunca dejar temporales de descarga tras éxito, error o interrupción.
  if [ -n "${TARBALL:-}" ]; then
    rm -f -- "${TARBALL}.download-"* "${TARBALL}.partial-"* 2>/dev/null || true
    # La firma puede ser .sign (kernel.org) o .asc (fork CachyOS/linux).
    rm -f -- "${TARBALL}.sign.download-"* "${TARBALL}.sign.partial-"* 2>/dev/null || true
    if [ "$KERNEL_TREE" = "cachyos" ]; then
      rm -f -- "${TARBALL}.asc.download-"* "${TARBALL}.asc.partial-"* 2>/dev/null || true
    fi
  fi

  # Retirar cualquier copia temporal de configuración que haya quedado por una
  # interrupción antes del rename atómico. Nunca tocar la configuración estable.
  [ -n "${CHECK_CONFIG_TMP:-}" ] && rm -f -- "$CHECK_CONFIG_TMP" 2>/dev/null || true

  # Si una señal o un fallo inesperado interrumpe la build, no dejamos una
  # modificación permanente en el árbol de fuentes conservado.
  if [ -n "${SRC:-}" ] && [ -f "$SRC/scripts/Makefile.package.cizen-orig" ]; then
    mv -f -- "$SRC/scripts/Makefile.package.cizen-orig" "$SRC/scripts/Makefile.package" 2>/dev/null || true
  fi
  if [ -n "${SRC:-}" ] && [ -f "$SRC/scripts/package/PKGBUILD.cizen-orig" ]; then
    mv -f -- "$SRC/scripts/package/PKGBUILD.cizen-orig" "$SRC/scripts/package/PKGBUILD" 2>/dev/null || true
  fi

  # v27.31.19: red de seguridad del desmontaje. Si la ejecución terminó con
  # ÉXITO TOTAL por una vía que no pasó por cleanup_success, el tmpfs se
  # desmonta igualmente aquí: el requisito es que el éxito devuelva la RAM.
  # cleanup_success (ruta normal) ya lo hizo y marcó CLEANUP_DONE.
  if [ "$rc" -eq 0 ] && [ "$FULL_PIPELINE_OK" = true ] && [ "$CLEANUP_DONE" != true ]; then
    CLEANUP_DONE=true
    cd "$HOME" 2>/dev/null || cd / 2>/dev/null || true
    unmount_tmpfs_build
  fi

  # Las rutas normales llaman cleanup_success explícitamente.
  # Si algo falla inesperadamente, dejamos el tmpfs montado para diagnóstico.
  if [ "$TMPFS_MOUNTED" = true ] && [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 130 ] && [ "$INTERRUPT_CAUGHT" = true ]; then
      info "La compilación fue cancelada por el usuario; no es un error. Se conserva el tmpfs montado: $TMPFS_ROOT"
      info "Para desmontarlo después: sudo umount ${TMPFS_ROOT}"
    else
      warn "La ejecución terminó con error ($rc); se conserva el tmpfs montado para diagnóstico: $TMPFS_ROOT"
      warn "Para desmontarlo después: sudo umount ${TMPFS_ROOT}"
    fi
  fi
}
trap cleanup_tmpfs_on_exit EXIT

# ============================================================
# TAR / DESCARGA
# ============================================================
KERNEL_GPG_HOME="${KERNEL_GPG_HOME:-$KERNEL_BUILD_ROOT/gnupg}"

# Firmantes oficiales de kernel.org reconocidos por este script.
# Los releases "mainline" (X.Y) los firma Linus Torvalds; los releases
# estables (X.Y.Z) normalmente los firma Greg Kroah-Hartman. Como este
# script admite y normaliza explícitamente ambas formas de versión
# (ver la normalización X.Y.0 -> X.Y más abajo), debía reconocer a ambos
# firmantes: antes solo confiaba en Greg, así que cualquier release
# mainline fallaba la verificación de firma SIEMPRE, fuera válido o no.
# Huellas oficiales publicadas en https://www.kernel.org/signature.html;
# conviene revisarlas si kernel.org las actualiza.
declare -A KERNEL_TRUSTED_SIGNERS=(
  [gregkh@kernel.org]="647F28654894E3BD457199BE38DBBDC86092693E"
  [torvalds@kernel.org]="ABAF11C65A2970B130ABE3C479BE3E4300411886"
)

# Firmantes de las releases del fork CachyOS/linux (.asc): huellas recogidas de
# los validpgpkeys de los PKGBUILD linux-cachyos (Eric Naim — dnaim@cachyos.org
# — y Peter Jung — admin@ptr1337.dev —). Conviene revisarlas si CachyOS cambia
# de firmantes.
declare -A CACHYOS_TRUSTED_SIGNERS=(
  [dnaim@cachyos.org]="E18447AC260021D31F3FF6C4C8A2A4774B8B63C4"
  [admin@ptr1337.dev]="E8B9AA39F054E30E8290D492C3C4820857F654FE"
)

verify_tarball() {
  local file="$1"
  [ -f "$file" ] || return 1
  [ -s "$file" ] || return 1
  log "Verificando integridad del tarball ($(du -h "$file" | cut -f1))..."
  if [ "$KERNEL_TREE" = "cachyos" ]; then
    gzip -t "$file" >/dev/null 2>&1
  else
    xz -t "$file" >/dev/null 2>&1
  fi
}

prepare_gpg_home() {
  mkdir -p "$KERNEL_GPG_HOME"
  chmod 0700 "$KERNEL_GPG_HOME"
}

# Obtiene y fija (pinning) en el keyring dedicado cada firmante confiable
# cuya huella coincida con la oficial. Un firmante que no se pueda obtener,
# o cuya huella no coincida, se descarta (y se elimina del keyring si llegó
# a importarse) en vez de bloquear la ejecución: basta con que AL MENOS UNO
# de los firmantes reconocidos quede disponible para poder verificar.
# El conjunto de firmantes depende del árbol: kernel.org (WKD) o el fork
# CachyOS/linux (WKD + keyservers, porque sus claves no siempre publican WKD).
ensure_kernel_signing_keys() {
  local email fp expected pinned=0
  local origin="kernel.org"
  declare -A signers=()
  prepare_gpg_home

  if [ "$KERNEL_TREE" = "cachyos" ]; then
    origin="CachyOS"
    for email in "${!CACHYOS_TRUSTED_SIGNERS[@]}"; do
      signers[$email]="${CACHYOS_TRUSTED_SIGNERS[$email]}"
    done
  else
    for email in "${!KERNEL_TRUSTED_SIGNERS[@]}"; do
      signers[$email]="${KERNEL_TRUSTED_SIGNERS[$email]}"
    done
  fi

  for email in "${!signers[@]}"; do
    expected="${signers[$email]}"
    fp="$(gpg --homedir "$KERNEL_GPG_HOME" --batch --with-colons --fingerprint "$email" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"

    if [ "$fp" != "$expected" ]; then
      log "Clave de $email no disponible en el keyring dedicado; se obtiene mediante WKD de $origin."
      gpg --homedir "$KERNEL_GPG_HOME" --batch --yes --locate-keys "$email" >/dev/null 2>&1 || true
      fp="$(gpg --homedir "$KERNEL_GPG_HOME" --batch --with-colons --fingerprint "$email" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
    fi

    if [ "$fp" != "$expected" ] && [ "$KERNEL_TREE" = "cachyos" ]; then
      log "WKD no disponible para $email; se intenta por keyserver (openpgp.org, luego keys.cachyos.org)."
      gpg --homedir "$KERNEL_GPG_HOME" --batch --keyserver hkps://keys.openpgp.org --recv-key "$expected" >/dev/null 2>&1 \
        || gpg --homedir "$KERNEL_GPG_HOME" --batch --keyserver hkps://keys.cachyos.org --recv-key "$expected" >/dev/null 2>&1 \
        || true
      fp="$(gpg --homedir "$KERNEL_GPG_HOME" --batch --with-colons --fingerprint "$email" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
    fi

    if [ "$fp" = "$expected" ]; then
      ok "Clave PGP confiable disponible: $email ($fp)"
      pinned=$((pinned + 1))
    else
      warn "No se pudo confirmar la clave PGP de $email (obtenida: '${fp:-ninguna}'); no se usará para verificar firmas."
      if [ -n "$fp" ]; then
        # Nunca dejamos en el keyring dedicado una clave cuya huella no
        # coincide con la esperada, aunque WKD/keyserver haya devuelto algo.
        gpg --homedir "$KERNEL_GPG_HOME" --batch --yes --delete-keys "$fp" >/dev/null 2>&1 || true
      fi
    fi
  done
  unset signers

  [ "$pinned" -gt 0 ] || fatal "No se pudo confirmar ninguna clave PGP oficial de $origin (${!KERNEL_TRUSTED_SIGNERS[*]} / ${!CACHYOS_TRUSTED_SIGNERS[*]})."
}

verify_tarball_signature() {
  local tarball="$1" sig="$2" gpg_out signer=""
  [ -s "$tarball" ] || return 1
  [ -s "$sig" ] || return 1
  ensure_kernel_signing_keys
  log "Verificando firma PGP oficial del tarball..."
  if [ "$KERNEL_TREE" = "cachyos" ]; then
    # El fork CachyOS/linux firma el .tar.gz tal cual (el .asc del release).
    # gpg --verify sig archivo verifica la firma directa sobre el binario.
    gpg_out="$(gpg --homedir "$KERNEL_GPG_HOME" --batch --verify "$sig" "$tarball" 2>&1)" || true
  else
    # kernel.org firma el archivo .tar sin comprimir, mientras el archivo
    # descargado para la build es .tar.xz. La verificación correcta es
    # descomprimir por streaming y pasar el .tar a gpg mediante stdin.
    gpg_out="$(xz -cd -- "$tarball" | gpg --homedir "$KERNEL_GPG_HOME" --batch --verify "$sig" - 2>&1)" || true
  fi
  # El keyring dedicado solo contiene claves ya fijadas por huella en
  # ensure_kernel_signing_keys(), así que un "Good signature" de gpg aquí
  # implica necesariamente que la firma es de uno de los firmantes
  # confiables (LC_ALL=C está exportado al inicio del script, así que el
  # texto de salida de gpg es estable para este grep).
  if [ "${gpg_out%Good signature*}" != "$gpg_out" ]; then
    signer="$(printf '%s\n' "$gpg_out" | sed -n 's/.*Good signature from "\([^"]*\)".*/\1/p' | head -n1)"
    ok "Firma PGP del kernel verificada correctamente${signer:+ (firmante: $signer)}"
    return 0
  fi
  err "La firma PGP del tarball NO es válida."
  printf '%s\n' "$gpg_out" | tail -20 >&2 || true
  return 1
}

# Huella tamaño+mtime del tarball+firma. Solo se usa para saber si ya se
# verificaron criptográficamente en una ejecución anterior sin que nada los
# haya tocado desde entonces; nunca sustituye la verificación en sí. Si
# cualquiera de los dos archivos cambia (tamaño o mtime), la huella deja de
# coincidir y se vuelve a verificar todo desde cero.
# NOTA: esta huella es una optimización, no una frontera de seguridad. Está
# sujeta a colisiones teóricas (un sustituto del mismo tamaño con mtime
# ajustado) si alguien con escritura en el caché persistente reemplaza el
# tarball tras la verificación; se considera aceptable porque el tarball ya
# se verificó criptográficamente al menos una vez y esta caché vive bajo el
# control del propio usuario.
tarball_fingerprint() {
  local tarball="$1" sig="$2"
  printf '%s:%s' "$(stat -c '%s:%Y' "$tarball" 2>/dev/null)" "$(stat -c '%s:%Y' "$sig" 2>/dev/null)"
}

# Descarga pequeña de metadatos (JSON de releases, .asc de sondeo): SIEMPRE de
# un solo hilo y con timeout duro. La API de GitHub no atiende múltiples
# conexiones/descargas parciales fiablemente, y aria2c --split=4 contra esos
# endpoints abortaba con "Size mismatch" y (con --max-tries=5) se quedaba
# reintentando durante minutos sin salir — el cuelgue de v27.31.3 al elegir
# un árbol CachyOS. Aquí el punto es velocidad determinista, no throughput.
download_small_file() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --max-time 45 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --timeout=20 --tries=3 -q -O "$out" "$url"
  else
    return 2
  fi
}

# Descarga con un hilo (wget clásico) o con conexiones paralelas (aria2c) si
# está instalado y no se fuerza CIZEN_DOWNLOADER=wget. Múltiples CDN limitan
# el throughput POR conexión (se midió ~30 MB/s por hilo en cdn.kernel.org
# frente a ~54 MB/s agregados con 4 hilos), así que aria2c aprovecha mejor el
# enlace. parámetros de reintentos/continuación equivalentes a los del wget
# previo: --continue, 5 intentos, timeout 30s, espera 2s.
download_file() {
  local url="$1" out="$2"
  local parallel="${CIZEN_DOWNLOAD_PARALLEL:-4}"
  [[ "$parallel" =~ ^[1-9][0-9]?$ ]] || parallel=4
  if [ "${CIZEN_DOWNLOADER:-}" != "wget" ] && command -v aria2c >/dev/null 2>&1; then
    local summary_interval="${CIZEN_DOWNLOAD_SUMMARY_INTERVAL:-0}"
    local -a dl_progress=()
    if [ -t 2 ]; then
      if [[ "$summary_interval" =~ ^[0-9]+$ ]] && [ "$summary_interval" -gt 0 ]; then
        dl_progress=(--summary-interval="$summary_interval")
      else
        dl_progress=(--summary-interval=0)
      fi
    else
      dl_progress=(--quiet)
    fi
    aria2c --continue=true --max-tries=5 --timeout=30 --connect-timeout=30 \
      --retry-wait=2 --max-connection-per-server="$parallel" \
      --split="$parallel" --min-split-size=1M --file-allocation=none \
      --allow-overwrite=false --auto-file-renaming=false --console-log-level=warn "${dl_progress[@]}" \
      --dir="$(dirname -- "$out")" --out="$(basename -- "$out")" "$url"
  else
    local -a wget_progress=()
    if [ -t 2 ]; then
      wget_progress=(--show-progress)
    fi
    wget --continue --tries=5 --timeout=30 --waitretry=2 "${wget_progress[@]}" "$url" -O "$out"
  fi
}

get_tarball() {
  local tarball="$1" url="$2" tmp_download tmp_sign sig bad_name sign_url
  if [ "$KERNEL_TREE" = "cachyos" ]; then
    sig="${tarball}.asc"
    sign_url="${url}.asc"
  else
    sig="${tarball}.sign"
    sign_url="${url%.tar.xz}.tar.sign"
  fi
  local verified_marker="${tarball}.verified-ok"
  local signer_origin="kernel.org"
  [ "$KERNEL_TREE" = "cachyos" ] && signer_origin="CachyOS"

  # Limpia residuos temporales previos de esta misma versión antes de reutilizar
  # el caché. Nunca se considera válido un .download/.bad/.partial.
  shopt -s nullglob
  for item in "${tarball}.download-"* "${sig}.download-"* "${tarball}.partial-"* "${sig}.partial-"*; do
    [ -e "$item" ] || continue
    rm -f -- "$item"
    log "Residuo temporal eliminado: $(basename -- "$item")"
  done
  shopt -u nullglob

  # Si el tarball y la firma conservan exactamente el tamaño+mtime que tenían
  # la última vez que superaron la verificación criptográfica completa en
  # esta misma caché persistente, no repetimos la descompresión + gpg en cada
  # invocación. Cualquier cambio real en cualquiera de los dos archivos
  # invalida la huella y fuerza una verificación completa de nuevo: esto no
  # relaja el resultado final, solo evita repetirlo sobre un archivo que ya
  # demostramos íntegro y que no ha cambiado desde entonces.
  if [ -s "$tarball" ] && [ -s "$sig" ] && [ -f "$verified_marker" ] && \
     [ "$(cat -- "$verified_marker" 2>/dev/null)" = "$(tarball_fingerprint "$tarball" "$sig")" ]; then
    ok "Tarball y firma PGP ya verificados en una ejecución anterior (sin cambios); se omite la reverificación"
    return 0
  fi

  # verify_tarball_signature ya descomprime el tarball completo para pasarlo a
  # gpg (xz -cd | gpg --verify) con pipefail activo: si xz falla, la tubería
  # entera falla igual que con xz -t por separado. Una segunda descompresión
  # completa aquí no aporta ninguna garantía adicional, así que se omite en
  # esta ruta (el chequeo xz -t tras una descarga fresca, más abajo, sí se
  # mantiene: ahí sirve para fallar rápido antes de gastar tiempo bajando la
  # firma por separado).
  if [ -s "$tarball" ] && [ -s "$sig" ] && verify_tarball_signature "$tarball" "$sig"; then
    ok "Tarball y firma PGP válidos; no se descarga de nuevo"
    tarball_fingerprint "$tarball" "$sig" > "$verified_marker" 2>/dev/null || true
    return 0
  fi
  rm -f -- "$verified_marker"

  # Un tarball o firma existente que no pasa la verificación se elimina.
  # No se crean archivos .bad persistentes.
  if [ -e "$tarball" ]; then
    rm -f -- "$tarball"
    warn "Tarball existente no verificable eliminado: $(basename -- "$tarball")"
  fi
  if [ -e "$sig" ]; then
    rm -f -- "$sig"
    warn "Firma existente no verificable eliminada: $(basename -- "$sig")"
  fi

  tmp_download="${tarball}.download-${TS}"
  tmp_sign="${sig}.download-${TS}"
  rm -f -- "$tmp_download" "$tmp_sign"
  ensure_optional_aria2c
  log "Descargando: $url"

  # Todo temporal se elimina si cualquier paso falla. Además, el trap EXIT
  # global vuelve a limpiar estos nombres en caso de interrupción inesperada.
  if ! download_file "$url" "$tmp_download"; then
    rm -f -- "$tmp_download" "$tmp_sign"
    err "No se pudo descargar el tarball."
    return 1
  fi

  if ! verify_tarball "$tmp_download"; then
    err "El tarball descargado no supera xz -t."
    rm -f -- "$tmp_download" "$tmp_sign"
    return 1
  fi

  log "Descargando firma PGP: $sign_url"
  if ! download_file "$sign_url" "$tmp_sign"; then
    rm -f -- "$tmp_download" "$tmp_sign"
    err "No se pudo descargar la firma PGP del kernel."
    return 1
  fi

  if ! verify_tarball_signature "$tmp_download" "$tmp_sign"; then
    err "El tarball descargado no supera la verificación criptográfica oficial."
    rm -f -- "$tmp_download" "$tmp_sign"
    return 1
  fi

  # Promoción atómica desde temporales verificados a nombres definitivos.
  mv -f -- "$tmp_download" "$tarball"
  mv -f -- "$tmp_sign" "$sig"
  tarball_fingerprint "$tarball" "$sig" > "$verified_marker" 2>/dev/null || true
  ok "Tarball descargado, íntegro y firmado por $signer_origin"
}

# ============================================================
# EXTRACCIÓN / FUENTES
# ============================================================
source_tree_valid() {
  [ -d "$SRC" ] && [ -f "$SRC/Makefile" ]
}

# El tipo real de un árbol de fuentes ya extraído ("vanilla" | "cachyos").
# El árbol del fork CachyOS/linux lleva su elección de scheduler propia
# (kernel/sched/poc_selector.c, la "API moderna" del fork) y difiere del
# vanilla de kernel.org aunque makepkg kernelversion coincida (p. ej. 7.2.7).
# Sin este marcador, un árbol vanilla conservado de una build previa se
# reutilizaría para una build cachyos y los parches -cachy fallarían.
# Acepta un directorio para poder clasificar árboles que no son el de esta
# versión (los que conviven en el tmpfs).
source_tree_kind() {
  local dir="${1:-$SRC}"
  if [ -f "$dir/kernel/sched/poc_selector.c" ]; then
    printf 'cachyos\n'
  elif [ -f "$dir/Makefile" ]; then
    printf 'vanilla\n'
  else
    printf 'desconocido\n'
  fi
}

# Identidad de un árbol como "<versión>|<tipo>". Preferencia por el testigo
# .cizen-tree que se escribe al extraer; si no existe (árboles de versiones
# anteriores de esta herramienta) se deduce del propio árbol. La versión del
# directorio solo es un último recurso (un árbol recién extraído siempre tiene
# Makefile y por tanto kernelversion legible).
tree_identity() {
  local dir="$1" meta ver kind
  meta="$dir/$TREE_META_NAME"
  if [ -f "$meta" ]; then
    ver="$(sed -nE 's/^version=//p' "$meta" 2>/dev/null | head -n1 || true)"
    kind="$(sed -nE 's/^kind=//p' "$meta" 2>/dev/null | head -n1 || true)"
    if [ -n "$ver" ] && [ -n "$kind" ]; then
      printf '%s|%s\n' "$ver" "$kind"
      return 0
    fi
  fi
  ver="$(make -C "$dir" -s kernelversion 2>/dev/null || true)"
  if [ -z "$ver" ]; then
    ver="$(basename -- "$dir")"
    ver="${ver#linux-}"
    ver="${ver#cachyos-}"
  fi
  printf '%s|%s\n' "$ver" "$(source_tree_kind "$dir")"
}

# ¿Sirve el árbol $1 para compilar la versión $2 de tipo $3? $3 vacío o con un
# valor que no sea vanilla|cachyos = no se discrimina por tipo. Fuente única de
# verdad: la usan tanto el chequeo de espacio como la reconciliación del tmpfs.
#
# El tipo lo fija el parche/scheduler (pds/bmq/lfbmq/muqss -> cachyos), que es
# justamente la dimensión que hace que dos árboles NO sean intercambiables: el
# directorio del árbol solo lleva la versión, así que un vanilla conservado se
# reutilizaría para un build del fork de la misma versión (los parches -cachy no
# aplican) sin dar ningún error visible. Los parches de terceros se aplican
# encima en cada build y no invalidan nada.
tree_usable_for() {
  local dir="$1" ver_want="$2" kind_want="$3" id ver kind
  [ -d "$dir" ] && [ -f "$dir/Makefile" ] && [ -f "$dir/kernel/Makefile" ] || return 1
  # Testigo de "extrayéndose ahora": una ejecución interrumpida deja el árbol a
  # medias, con Makefile y todo, y se reutilizaría tal cual (al motor solo le
  # basta el Makefile para leer kernelversion). El testigo vive en la raíz del
  # tmpfs, no dentro del árbol, para no interferir con la extracción ni con el
  # renombrado del tarball del fork.
  [ ! -f "$TMPFS_ROOT/.cizen-extracting-$ver_want" ] || return 1
  id="$(tree_identity "$dir")"
  ver="${id%%|*}"
  kind="${id#*|}"
  [ "$ver" = "$ver_want" ] || [[ "$ver" == "$ver_want"-* ]] || return 1
  case "$kind_want" in
    vanilla|cachyos) [ "$kind" = "$kind_want" ] || return 1 ;;
  esac
  return 0
}

# ¿El árbol de $SRC sirve para ESTE build? Es la única comprobación válida
# para decidir que el tmpfs tiene algo reutilizable. Con un simple
# [ -d "$SRC" ] un árbol del tipo equivocado contaba como reutilizable: el
# chequeo de espacio aplicaba el margen incremental (2048 MB) y luego
# extract_tarball lo borraba para extraer 4-5 GB de cero, con ENOSPC a mitad.
source_tree_reusable() {
  tree_usable_for "$SRC" "$VERSION" "$KERNEL_TREE"
}

# Testigo de identidad del árbol recién extraído, para que la reconciliación
# del tmpfs de la siguiente ejecución no tenga que deducirlo del Makefile.
write_tree_meta() {
  local dir="$1" kver
  kver="$(make -C "$dir" -s kernelversion 2>/dev/null || true)"
  {
    printf 'version=%s\n' "${kver:-$VERSION}"
    printf 'kind=%s\n' "$(source_tree_kind "$dir")"
    printf 'ts=%s\n' "$(date +%s)"
  } > "$dir/$TREE_META_NAME" 2>/dev/null || true
}

extract_tarball() {
  local _top extract_top kver
  cleanup_old_source_trees

  if source_tree_reusable; then
    ok "Reutilizando el árbol de fuentes: $SRC ($VERSION, $KERNEL_TREE${TREE_FORCE_NOTE:+, $TREE_FORCE_NOTE})"
    return 0
  fi

  if source_tree_valid; then
    # Red de seguridad: reconcile_tmpfs_trees ya habrá descartado este árbol
    # antes del chequeo de espacio, pero si se llega aquí (p. ej. el árbol se
    # creó entre medias) se descarta igualmente: reutilizar un árbol de otro
    # tipo o de otra versión compilaría el kernel equivocado sin avisar.
    kver="$(make -C "$SRC" -s kernelversion 2>/dev/null || true)"
    if [ "$kver" = "$VERSION" ] || [[ "$kver" == "$VERSION"-* ]]; then
      warn "El árbol conservado es $(source_tree_kind "$SRC") y este build compila $KERNEL_TREE${TREE_FORCE_NOTE:+ ($TREE_FORCE_NOTE)}; se descarta y se vuelve a extraer $VERSION."
    else
      warn "El árbol existente es ${kver:-?} y este build compila $VERSION; se descarta y se vuelve a extraer."
    fi
    rm -rf "$SRC"
  fi

  log "Extrayendo fuentes en $(dirname "$SRC") ..."
  rm -f "$TMPFS_ROOT/.cizen-extracting-$VERSION" 2>/dev/null || true
  : > "$TMPFS_ROOT/.cizen-extracting-$VERSION"
  tar -xf "$TARBALL" -C "$(dirname "$SRC")"

  # El tarball de kernel.org extrae linux-X.Y.Z (== basename de $SRC); el del
  # fork CachyOS/linux extrae cachyos-X.Y.Z-N. Si el árbol esperado no quedó
  # donde debe, se mueve el directorio extraído a $SRC.
  if ! source_tree_valid; then
    _top="$(tar -tf "$TARBALL" 2>/dev/null | head -n1)"
    extract_top="${_top%%/*}"
    if [ -n "$extract_top" ] && [ "$extract_top" != "$(basename -- "$SRC")" ] \
       && [ -d "$(dirname "$SRC")/$extract_top" ] \
       && [ -f "$(dirname "$SRC")/$extract_top/Makefile" ]; then
      log "Reubicando árbol extraído ($extract_top) a $SRC"
      mv -- "$(dirname "$SRC")/$extract_top" "$SRC"
    fi
  fi

  if ! source_tree_valid; then
    err "Extracción incompleta: falta $SRC/Makefile"
    rm -rf "$SRC"
    return 1
  fi

  kver="$(make -C "$SRC" -s kernelversion 2>/dev/null || true)"
  if [ "$kver" != "$VERSION" ] && [[ "$kver" != "$VERSION"-* ]]; then
    err "La versión del árbol extraído no coincide con $VERSION (obtenida: '${kver:-?}')"
    rm -rf "$SRC"
    return 1
  fi
  write_tree_meta "$SRC"
  rm -f "$TMPFS_ROOT/.cizen-extracting-$VERSION" 2>/dev/null || true
}

# ============================================================
# FRAMEWORK DE PARCHES DE TERCEROS (OPCIONAL)  — v27.24.0
# ============================================================
# Mecanismo DECLARATIVO para aplicar parches de terceros sobre las fuentes
# vanilla. Cada parche es un descriptor (función `patch_desc_<nombre>`) que
# define TODOS los parámetros; la lógica de aplicación es genérica y común.
#
# Descriptor (variables que debe fijar patch_desc_<n>):
#   PATCH_DESC           descripción humana
#   PATCH_DISP_NAME      nombre corto para logs
#   PATCH_BRANCH         rama X.Y del kernel objetivo (7.2.6 -> 7.2)
#   PATCH_URL_PREFIX     base del repo donde se publica (incluye "master")
#   PATCH_CDN_SUBDIR     subdirectorio bajo la rama (sched/)
#   PATCH_MAIN_FILE      fichero principal (forward-port del mantenedor del repo)
#   PATCH_FALLBACK_FILE  respaldo del autor upstream (se sincroniza por release)
#   PATCH_SHA256_MAIN    hash SHA256 de confianza del fichero principal (pin)
#   PATCH_SHA256_FALLBACK  hash SHA256 de confianza del respaldo upstream (pin)
#   PATCH_CACHE_NAME     prefijo del fichero en KERNEL_BUILD_ROOT (-> name-$br.patch)
#   PATCH_SYMBOLS        símbolos Kconfig que el parche introduce (=y + rebelde)
#   PATCH_MAGIC          cadena que debe aparecer en un parche válido
#   PATCH_MARKERS        array "ruta:patrón" para detectar un árbol ya parcheado
#
# La lógica común (v27.22.2 y v27.22.4 heredadas de BORE):
#   - Detección de árbol conservado ya-parcheado por marcadores: no se vuelve a
#     descargar ni a aplicar (evita el "Reversed patch detected" del dry-run).
#   - El intento principal se baja a un TEMPORAL y solo se promueve al nombre
#     definitivo si valida (aplica limpio): un intento fallido no pisa el
#     destino, no deja .1 huérfanos y no muestra dos descargas idénticas.
#   - Degrade automático principal -> upstream si no aplica limpio sobre X.Y.Z.
#   - ANCLAJE SHA256 (pin): el fichero que se va a aplicar debe coincidir con el
#     hash de confianza del descriptor; si no, se descarta y se degrada a vanilla
#     (nunca se aplica un parche cuya procedencia no casa con el pin). Overrides:
#     CIZEN_PATCH_SHA256_MAIN / CIZEN_PATCH_SHA256_FALLBACK para otro hash bueno
#     conocido, y CIZEN_PATCH_SHA256_VERIFY=0 para desactivar (último recurso).
#   - Cualquier fallo es fatal suave: warning y build vanilla (nunca rompe).
#   - Al aplicar, los símbolos se registran (apply_patch_register) para que
#     build_effective_arrays los fuerce a =y y los marque como esperados.
bore_branch_from_version() {
  # 7.2.6 -> 7.2 ; 7.2 -> 7.2 ; 6.1.77 -> 6.1
  if [[ "$1" =~ ^([0-9]+\.[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "${1%%.*}"
  fi
}

# Descriptor del plugin BORE (firelzrd, reenviado por CachyOS).
patch_desc_bore() {
  PATCH_DESC="BORE scheduler (Burst-Oriented Response Enhancer)"
  PATCH_DISP_NAME="BORE"
  PATCH_BRANCH="$(bore_branch_from_version "$VERSION")"
  PATCH_URL_PREFIX="https://raw.githubusercontent.com/CachyOS/kernel-patches/master"
  PATCH_CDN_SUBDIR="sched"
  PATCH_MAIN_FILE="0001-bore-cachy.patch"
  PATCH_FALLBACK_FILE="0001-bore.patch"
  PATCH_SHA256_MAIN="1809a4d4d6508a2a3f92cd8b3b385640583f90bd6cee46584f4bf105affd24a0"
  PATCH_SHA256_FALLBACK="61b9543e400d6fb38a68ee2276538ae14834bec75d7b06d3e1ac9977174ff619"
  PATCH_CACHE_NAME="bore"
  PATCH_SYMBOLS=(SCHED_BORE MIN_BASE_SLICE_NS)
  PATCH_MAGIC="config SCHED_BORE"
  PATCH_MARKERS=( "kernel/sched/bore.c:" "kernel/sched/fair.c:SCHED_BORE|burst" )
  PATCH_SKIP_REASON=""
}

# Blob base64 (gzip) del forward-port de 0001-prjc-cachy.patch para la
# release cachyos-7.2.7-1 del fork CachyOS/linux. Se genera desde el árbol
# oficial (cachyos-7.2.7-1.tar.gz) cuando la rama master/7.2 de
# CachyOS/kernel-patches deja de aplicar limpio (refactors de 7.2.7); el motor
# lo decodifica (base64 + gunzip) y valida por dry-run en apply_patch_plugin.
# Formato del dato: una línea = 64 char base64 del .gz. NO EDITAR a mano.
patch_embed_b64_prjc_cachy() {
  cat <<'CIZEN_PATCH_EMBED_EOF'
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
CIZEN_PATCH_EMBED_EOF
}

# Descriptores de los demás schedulers (v27.30.0). Todos comparten la misma
# cadena CachyOS/kernel-patches; cambia el fichero y los símbolos Kconfig.
# El parche define una "choice" (SCHED_ALT + SCHED_PDS/SCHED_BMQ/SCHED_LFBMQ,
# o SCHED_MUQSS en muqss): para elegir una rama hay que desactivar la elegida
# por defecto, por eso PATCH_CHOICE_DISABLE (via PATCH_DISABLE_ALL).
_patch_desc_scheduler_base() {
  local kind="$1"
  PATCH_URL_PREFIX="https://raw.githubusercontent.com/CachyOS/kernel-patches/master"
  PATCH_CDN_SUBDIR="sched"
  PATCH_BRANCH="$(bore_branch_from_version "$VERSION")"
  PATCH_SKIP_REASON=""
  PATCH_SHA256_MAIN=""
  PATCH_SHA256_FALLBACK=""
  # Parche forward-port de emergencia incrustado en el motor (base64 de un .gz).
  # Sirve cuando el main remoto no aplica a la release publicada (v27.31.5:
  # CachyOS/kernel-patches master/7.2 no aplica limpio a cachyos-7.2.7-1 por
  # refactors de 7.2.7: tg_cpus/max(nr,1), put_pid extra en exit.c y
  # select GENERIC_ALLOCATOR en SCHED_CLASS_EXT). Se prueba DESPUÉS del main y
  # ANTES del fallback upstream, siempre validado por dry-run contra $SRC.
  PATCH_EMBED_B64=""
  # Símbolos que este scheduler alternativo retira del kernel (deben poder
  # mantenerse en OPTS_* del perfil sin bloquear la validación): con SCHED_ALT
  # activo, init/Kconfig los hace imposibles vía `depends on !SCHED_ALT`.
  # BMQ/PDS/LFBMQ activan SCHED_ALT (PSI, NUMA_BALANCING, SCHED_CACHE y
  # SCHED_AUTOGROUP quedan fuera; PSI_DEFAULT_DISABLED cae por depender de PSI).
  PATCH_RETIRED_SYMBOLS=()
  # PRJC/MuQSS solo se publican como parches -cachy que aplican sobre el árbol
  # del fork CachyOS/linux, nunca sobre la release vanilla de kernel.org.
  PATCH_TREE_REQUIRED="cachyos"
  case "$kind" in
    pds)
      PATCH_DESC="PRJC/PDS scheduler (Piotr Gorski)"
      PATCH_DISP_NAME="PDS"
      PATCH_MAIN_FILE="0001-prjc-cachy.patch"
      PATCH_FALLBACK_FILE="0001-prjc.patch"
      PATCH_CACHE_NAME="prjc-pds"
      PATCH_EMBED_B64="$(patch_embed_b64_prjc_cachy)"
      PATCH_SYMBOLS=(SCHED_ALT SCHED_PDS)
      PATCH_CHOICE_DISABLE=(SCHED_BMQ)
      PATCH_RETIRED_SYMBOLS=(PSI PSI_DEFAULT_DISABLED SCHED_AUTOGROUP NUMA_BALANCING SCHED_CACHE)
      PATCH_MAGIC="config SCHED_PDS"
      PATCH_MARKERS=( "kernel/sched/alt_core.c:" "kernel/sched/pds.h:" "kernel/sched/sched.h:SCHED_PDS" )
      ;;
    bmq)
      PATCH_DESC="PRJC/BMQ scheduler (Piotr Gorski)"
      PATCH_DISP_NAME="BMQ"
      PATCH_MAIN_FILE="0001-prjc-cachy.patch"
      PATCH_FALLBACK_FILE="0001-prjc.patch"
      PATCH_CACHE_NAME="prjc-bmq"
      PATCH_EMBED_B64="$(patch_embed_b64_prjc_cachy)"
      PATCH_SYMBOLS=(SCHED_ALT SCHED_BMQ)
      PATCH_CHOICE_DISABLE=(SCHED_PDS)
      PATCH_RETIRED_SYMBOLS=(PSI PSI_DEFAULT_DISABLED SCHED_AUTOGROUP NUMA_BALANCING SCHED_CACHE)
      PATCH_MAGIC="config SCHED_BMQ"
      PATCH_MARKERS=( "kernel/sched/alt_core.c:" "kernel/sched/bmq.h:" "kernel/sched/sched.h:SCHED_BMQ" )
      ;;
    lfbmq)
      PATCH_DESC="PRJC/BMQ low-frequency variant (LFBMQ)"
      PATCH_DISP_NAME="LFBMQ"
      PATCH_MAIN_FILE="0001-prjc-cachy-lfbmq.patch"
      PATCH_FALLBACK_FILE="0001-prjc-lfbmq.patch"
      PATCH_CACHE_NAME="prjc-lfbmq"
      PATCH_SYMBOLS=(SCHED_ALT SCHED_LFBMQ)
      PATCH_CHOICE_DISABLE=(SCHED_PDS SCHED_BMQ)
      PATCH_RETIRED_SYMBOLS=(PSI PSI_DEFAULT_DISABLED SCHED_AUTOGROUP NUMA_BALANCING SCHED_CACHE)
      PATCH_MAGIC="config SCHED_LFBMQ"
      PATCH_MARKERS=( "kernel/sched/alt_core.c:" "kernel/sched/sched.h:SCHED_LFBMQ" )
      ;;
    muqss)
      PATCH_DESC="MuQSS scheduler (Steven Rostedt / adaptación CachyOS)"
      PATCH_DISP_NAME="MUQSS"
      PATCH_MAIN_FILE="0001-muqss-cachy.patch"
      PATCH_FALLBACK_FILE="0001-prjc-cachy.patch"
      PATCH_CACHE_NAME="muqss"
      PATCH_SYMBOLS=(SCHED_MUQSS)
      PATCH_CHOICE_DISABLE=(SCHED_ALT)
      PATCH_MAGIC="config SCHED_MUQSS"
      PATCH_MARKERS=( "kernel/sched/build_muqss.c:" "include/linux/muqss.h:" )
      ;;
  esac
}

patch_desc_pds()  { PATCH_SKIP_REASON=""; _patch_desc_scheduler_base pds; }
patch_desc_bmq()  { PATCH_SKIP_REASON=""; _patch_desc_scheduler_base bmq; }
patch_desc_lfbmq(){ PATCH_SKIP_REASON=""; _patch_desc_scheduler_base lfbmq; }
patch_desc_muqss(){ PATCH_SKIP_REASON=""; _patch_desc_scheduler_base muqss; }

# ── Wine-sync ────────────────────────────────────────────────
# NTSync: en mainline desde 6.10 (API completa de usuario en 6.14); para
# kernels anteriores CachyOS publica el backport en misc/. Por encima de 6.10
# NO se parchea: el motor fuerza CONFIG_NTSYNC=nativo en inject_build_overlay.
patch_desc_ntsync() {
  PATCH_DESC="NTSync (primitivas NT de sincronización para Wine)"
  PATCH_DISP_NAME="NTSYNC"
  PATCH_BRANCH="$(bore_branch_from_version "$VERSION")"
  PATCH_URL_PREFIX="https://raw.githubusercontent.com/CachyOS/kernel-patches/master"
  PATCH_CDN_SUBDIR="misc"
  PATCH_MAIN_FILE="0001-ntsync.patch"
  PATCH_FALLBACK_FILE="0009-ntsync.patch"
  PATCH_SHA256_MAIN=""
  PATCH_SHA256_FALLBACK=""
  PATCH_CACHE_NAME="ntsync"
  PATCH_SYMBOLS=(NTSYNC)
  PATCH_CHOICE_DISABLE=()
  PATCH_MAGIC="ntsync"
  PATCH_MARKERS=( "drivers/misc/ntsync.c:" )
  if kernel_version_ge "$VERSION" "6.10"; then
    PATCH_SKIP_REASON="ntsync ya está en mainline ($VERSION >= 6.10); se fuerza CONFIG_NTSYNC nativo, sin parche."
    return 0
  fi
  PATCH_SKIP_REASON=""
}

# Fsync: serie legacy FUTEX_WAIT_MULTIPLE (futex_waitv). NUNCA llegó a mainline
# y su sucesor oficial es ntsync; en 6.14+ el backport deja de mantenerse.
patch_desc_fsync() {
  PATCH_DESC="fsync legacy (futex_waitv) para kernels < 6.14"
  PATCH_DISP_NAME="FSYNC"
  PATCH_BRANCH="$(bore_branch_from_version "$VERSION")"
  PATCH_URL_PREFIX="https://raw.githubusercontent.com/Frogging-Family/linux-tkg/master/linux-tkg-patches"
  PATCH_CDN_SUBDIR=""
  PATCH_MAIN_FILE="0007-${PATCH_BRANCH}-fsync_legacy_via_futex_waitv.patch"
  PATCH_FALLBACK_FILE="0007-v6.1-fsync_legacy_via_futex_waitv.patch"
  PATCH_SHA256_MAIN=""
  PATCH_SHA256_FALLBACK=""
  PATCH_CACHE_NAME="fsync"
  PATCH_SYMBOLS=()
  PATCH_CHOICE_DISABLE=()
  PATCH_MAGIC="FUTEX_WAIT_MULTIPLE"
  PATCH_MARKERS=( "include/uapi/linux/futex.h:FUTEX_WAIT_MULTIPLE" )
  if kernel_version_ge "$VERSION" "6.14"; then
    PATCH_SKIP_REASON="fsync legacy no aplica en $VERSION (>= 6.14): usa ntsync (CONFIG_NTSYNC) en su lugar."
    return 0
  fi
  if kernel_version_ge "$VERSION" "6.10"; then
    warn "fsync y ntsync son excluyentes; ntsync está disponible en $VERSION, se recomienda ntsync."
  fi
  PATCH_SKIP_REASON=""
}

# Comprueba los marcadores de "árbol ya parcheado" del descriptor actual.
# PATCH_MARKERS es "ruta:patrón" relativa a $SRC; patrón vacío = basta con que
# el fichero exista.
patch_markers_hit() {
  local m path pat
  for m in "${PATCH_MARKERS[@]:-}"; do
    path="${m%%:*}"
    pat="${m#*:}"
    [ -f "$SRC/$path" ] || return 1
    [ -z "$pat" ] || grep -Eq -- "$pat" "$SRC/$path" 2>/dev/null || return 1
  done
  return 0
}

# v27.31.9 — hueco del forward-port PRJC. Los mainlines recientes (7.x)
# referencian desde kernel/locking/rtmutex_api.c los hooks
# rt_mutex_futex_pre_schedule()/rt_mutex_futex_post_schedule() (definidos en
# kernel/sched/core.c). Los schedulers SCHED_ALT compilan kernel/sched/
# alt_core.c EN LUGAR de core.c, y PRJC no portó esos hooks → link final con
# "undefined symbol: rt_mutex_futex_pre_schedule". Fixup autocontenido e
# idempotente: si alt_core.c está activo, rtmutex_api.c los referencia y
# alt_core.c no los define, se añaden (mismas que core.c) al final del fichero.
# No afecta a muqss (no compila alt_core.c) ni a kernels sin esos hooks.
_sched_alt_rtmutex_futex_fixup() {
  local alt_core="$SRC/kernel/sched/alt_core.c"
  [ -f "$alt_core" ] || return 0
  grep -q 'rt_mutex_futex_pre_schedule' "$SRC/kernel/locking/rtmutex_api.c" 2>/dev/null || return 0
  grep -q 'void rt_mutex_futex_pre_schedule' "$alt_core" 2>/dev/null && return 0
  log "SCHED_ALT: añadiendo rt_mutex_futex_pre/post_schedule a alt_core.c (hueco del forward-port; mainline los llama desde rtmutex_api.c)..."
  cat >> "$alt_core" <<'ALT_EOF'

#ifdef CONFIG_RT_MUTEXES
#define CIZEN_FETCH_AND_SET(x, v) ({ int _x = (x); (x) = (v); _x; })
void rt_mutex_futex_pre_schedule(void)
{
	lockdep_assert(!(current->flags & (PF_WQ_WORKER | PF_IO_WORKER)));
	lockdep_assert(!current->plug);
	lockdep_assert(!CIZEN_FETCH_AND_SET(current->sched_rt_mutex, 1));
	}
void rt_mutex_futex_post_schedule(void)
{
	lockdep_assert(CIZEN_FETCH_AND_SET(current->sched_rt_mutex, 0));
	}
#endif /* CONFIG_RT_MUTEXES */
ALT_EOF
  ok "SCHED_ALT: rt_mutex_futex_pre/post_schedule definidos en alt_core.c (hueco del forward-port PRJC cubierto)."
  return 0
}

# Registra un parche como aplicado: añade a la lista de aplicados y acumula sus
# símbolos Kconfig para que build_effective_arrays los fuerce a =y y los marque
# como rebeldes esperados. BORE mantiene además BORE_ENABLED (resumen y firma).
apply_patch_register() {
  local p="$1" s
  PATCHES_APPLIED+=("$p")
  for s in "${PATCH_SYMBOLS[@]:-}"; do
    # Solo los booleanos se fuerzan a =y. Un símbolo int/hex/string al que se le
    # pone "=y" no es un valor válido: olddefconfig lo revierte a su default y
    # el validador lo cuenta como activación no satisfecha para siempre.
    case "$(kconfig_symbol_type "$s")" in
      bool|tristate|"")
        PATCH_ENABLE_ALL+=("$s")
        PATCH_REBEL_ALL+=("$s")
        ;;
      *)
        PATCH_VALUE_SYMBOLS+=("$s")
        ;;
    esac
  done
  # Elección de variante dentro de la "choice" Kconfig del scheduler.
  for s in "${PATCH_CHOICE_DISABLE[@]:-}"; do
    [ -n "$s" ] && PATCH_DISABLE_ALL+=("$s")
  done
  # Símbolos retirados por el parche (dependen de !SCHED_ALT): build_effective_
  # arrays los quita de CRITICAL/SETVAL/ENABLE (no son posibles de habilitar).
  for s in "${PATCH_RETIRED_SYMBOLS[@]:-}"; do
    [ -n "$s" ] && PATCH_RETIRED_ALL+=("$s")
  done
  unset s
  if [ "$p" = "bore" ]; then
    BORE_ENABLED=true
  fi
}

# Descarga y aplica el parche <nombre>. Devuelve 0 = aplicado, 1 = no
# (fatal suave: la build continúa vanilla tras un warning).
apply_patch_plugin() {
  local name="$1"
  local patch_file main_url fallback_url
  local main_tmp _mreason=

  # Carga el descriptor del parche (función patch_desc_<nombre> global).
  if ! declare -F "patch_desc_$name" >/dev/null 2>&1; then
    warn "Parche '$name' desconocido o sin descriptor en el motor; se omite."
    return 1
  fi
  # Cada descriptor decide PATCH_TREE_REQUIRED; se parte de vacío para que el
  # valor de un parche anterior (variable global) no se filtre.
  unset PATCH_TREE_REQUIRED PATCH_SKIP_REASON
"patch_desc_$name"

  # Un descriptor puede decidir que el parche NO aplica a esta versión (p. ej.
  # ntsync en mainline, fsync en 6.14+): declara PATCH_SKIP_REASON y se corta
  # aquí con aviso, sin tocar el árbol.
  if [ -n "${PATCH_SKIP_REASON:-}" ]; then
    warn "${PATCH_SKIP_REASON}"
    return 1
  fi

  # Si el parche exige un árbol de fuentes concreto (p. ej. schedulers PRJC/
  # MuQSS -> árbol CachyOS) y el build se hizo sobre otro, se omite de forma
  # fail-soft (build vanilla) con aviso, sin intentar descargar nada.
  if [ -n "${PATCH_TREE_REQUIRED:-}" ] && [ "$KERNEL_TREE" != "$PATCH_TREE_REQUIRED" ]; then
    warn "${PATCH_DISP_NAME:-$name} requiere el árbol de fuentes '$PATCH_TREE_REQUIRED' (compila con --tree $PATCH_TREE_REQUIRED); se omite y se continúa con el árbol actual ($KERNEL_TREE)."
    return 1
  fi

  log "Parche ${PATCH_DISP_NAME:-$name} habilitado: descargando para la rama ${PATCH_BRANCH:-?} ..."

  # Árbol conservado de una ejecución previa (p. ej. cancelada tras aplicar):
  # los marcadores del descriptor son la firma de que el parche YA está
  # aplicado. Volver a hacer `patch --dry-run` sobre un árbol ya parcheado
  # respondería "Reversed (or previously applied) patch detected" (rc=1) y se
  # degradaría a vanilla pese a que el árbol SÍ lo lleva.
  if patch_markers_hit; then
    ok "${PATCH_DISP_NAME:-$name} ya estaba aplicado en el árbol conservado."
    # El árbol conservado YA viene parcheado, pero el índice de símbolos puede
    # haberse construido antes (mismo proceso, otra rama). Se tira igual que en
    # la aplicación real: los tipos de PATCH_SYMBOLS (bool vs int) se deciden
    # con el árbol parcheado, y con el índice viejo un `int` como
    # MIN_BASE_SLICE_NS se clasificaba como bool y acababa forzado a "=y".
    kconfig_index_invalidate
    apply_patch_register "$name"
    _sched_alt_rtmutex_futex_fixup
    return 0
  fi

  if ! command -v patch >/dev/null 2>&1; then
    warn "patch no está instalado; no se puede aplicar $name. Instale con: sudo pacman -S patch"
    return 1
  fi

  patch_file="$KERNEL_BUILD_ROOT/${PATCH_CACHE_NAME}-${PATCH_BRANCH}.patch"

  PATCH_SHA256_MAIN="${CIZEN_PATCH_SHA256_MAIN:-${PATCH_SHA256_MAIN:-}}"
  PATCH_SHA256_FALLBACK="${CIZEN_PATCH_SHA256_FALLBACK:-${PATCH_SHA256_FALLBACK:-}}"
  PATCH_SHA256_VERIFY="${CIZEN_PATCH_SHA256_VERIFY:-1}"
  # Imprime el motivo si $1 difiere del pin $2 (vacío si pin válido/desactivado).
  verify_patch_sha() {
    local f="$1" pin="$2" got
    if [ "$PATCH_SHA256_VERIFY" != 1 ] || [ -z "$pin" ]; then printf ''; return 0; fi
    got="$(sha256sum "$f" | cut -d' ' -f1 2>/dev/null || true)"
    if [ -n "$got" ] && [ "$got" != "$pin" ]; then
      printf 'hash SHA256 %s… no coincide con el anclado %s… (¿el repo regeneró el parche?)' "${got:0:12}" "${pin:0:12}"
    else
      printf ''
    fi
    return 0
  }

  # Intento 1: parche principal (forward-port; p. ej. CachyOS lo regenera contra
  # su propio árbol, que lleva cambios extra de scheduler, así que a veces no
  # aplica limpio sobre la release vanilla final X.Y.Z). Se descarga a un
  # temporal y solo se promueve al nombre definitivo si valida (aplica limpio):
  # así un intento fallido no pisa el destino ni muestra dos descargas idénticas
  # al mismo fichero, y se anuncia la razón real del retroceso.
  main_url="${PATCH_URL_PREFIX}/${PATCH_BRANCH}/${PATCH_CDN_SUBDIR}/${PATCH_MAIN_FILE}"
  main_tmp="${patch_file}.intento1"
  rm -f -- "$patch_file" "$main_tmp"
  if download_file "$main_url" "$main_tmp"; then
    if [ ! -s "$main_tmp" ]; then
      _mreason="descarga vacía"
    elif ! grep -Fq "$PATCH_MAGIC" "$main_tmp"; then
      _mreason="sin marcador ${PATCH_MAGIC}"
    elif ! patch -p1 --dry-run -d "$SRC" < "$main_tmp" >/dev/null 2>&1; then
      _mreason="no aplica limpio sobre $VERSION (contexto Kconfig del árbol vanilla difiere del forward-port)"
    else
      ok "${PATCH_DISP_NAME:-$name}: ${PATCH_MAIN_FILE} válido para $VERSION."
      mv -f -- "$main_tmp" "$patch_file"
      _pin_reason="$(verify_patch_sha "$patch_file" "$PATCH_SHA256_MAIN")"
      if [ -n "$_pin_reason" ]; then
        rm -f -- "$patch_file"
        _mreason="$_pin_reason"
      fi
    fi
  else
    _mreason="no disponible (error al descargar $PATCH_MAIN_FILE; comprueba red/repositorio)"
  fi
  if [ -n "$_mreason" ]; then
    rm -f -- "$main_tmp"
    # Intento 1b: forward-port embebido en el motor. Prueba parches que el
    # mantenedor upstream regenera contra sus releases nuevas pero que ya no
    # aplican a la release publicada que estamos compilando (p. ej.
    # 0001-prjc-cachy.patch contra cachyos-7.2.7-1). La firma por contenido
    # (base64/gunzip + marcador + dry-run) decide; si no aplica, upstream.
    if [ -n "${PATCH_EMBED_B64:-}" ]; then
      _embed_tmp="${patch_file}.embebido"
      rm -f -- "$_embed_tmp"
      if printf '%s' "$PATCH_EMBED_B64" | base64 -d 2>/dev/null > "$_embed_tmp" \
         && gunzip -cff "$_embed_tmp" > "$patch_file" 2>/dev/null \
         && [ -s "$patch_file" ] \
         && grep -Fq "$PATCH_MAGIC" "$patch_file" \
         && patch -p1 --dry-run -d "$SRC" < "$patch_file" >/dev/null 2>&1; then
        warn "${PATCH_DISP_NAME:-$name}: ${PATCH_MAIN_FILE} $_mreason; usando forward-port incrustado para $VERSION."
        ok "${PATCH_DISP_NAME:-$name} incrustado: ${PATCH_MAIN_FILE} (forward-port) válido para $VERSION."
        rm -f -- "$_embed_tmp"
        _mreason=""
      else
        rm -f -- "$_embed_tmp" "$patch_file"
        warn "${PATCH_DISP_NAME:-$name}: forward-port embebido no aplica a esta release; se continúa con el upstream."
      fi
    fi
    if [ -n "$_mreason" ]; then
      warn "${PATCH_DISP_NAME:-$name}: ${PATCH_MAIN_FILE} $_mreason; probando upstream (${PATCH_FALLBACK_FILE}) ..."
      fallback_url="${PATCH_URL_PREFIX}/${PATCH_BRANCH}/${PATCH_CDN_SUBDIR}/${PATCH_FALLBACK_FILE}"
      if ! download_file "$fallback_url" "$patch_file" \
         || [ ! -s "$patch_file" ] \
         || ! grep -Fq "$PATCH_MAGIC" "$patch_file" \
         || ! patch -p1 --dry-run -d "$SRC" < "$patch_file" >/dev/null 2>&1; then
        rm -f -- "$patch_file"
        warn "Ningún parche ${PATCH_DISP_NAME:-$name} disponible que aplique para la rama ${PATCH_BRANCH:-?} / $VERSION; se continúa vanilla."
        return 1
      fi
      ok "${PATCH_DISP_NAME:-$name}: usando upstream ${PATCH_FALLBACK_FILE} (válido para $VERSION)."
      _pin_reason="$(verify_patch_sha "$patch_file" "$PATCH_SHA256_FALLBACK")"
      if [ -n "$_pin_reason" ]; then
        rm -f -- "$patch_file"
        warn "Parche ${PATCH_DISP_NAME:-$name}: $_pin_reason; se continúa vanilla. Si el hash es legítimo, actualiza el pin (CIZEN_PATCH_SHA256_MAIN / _FALLBACK) o usa CIZEN_PATCH_SHA256_VERIFY=0."
        return 1
      fi
    fi
  fi
  unset _mreason main_tmp _pin_reason _embed_tmp

  if ! patch -p1 -d "$SRC" < "$patch_file" >/dev/null 2>&1; then
    warn "Aplicación real del parche ${PATCH_DISP_NAME:-$name} falló inesperadamente; se continúa vanilla."
    return 1
  fi

  # El parche acaba de cambiar el árbol (y sus Kconfig): el índice de símbolos se
  # tira aquí, o el validador no verá los símbolos que el propio parche introduce.
  kconfig_index_invalidate
  apply_patch_register "$name"
  _sched_alt_rtmutex_futex_fixup
  ok "${PATCH_DESC:-${PATCH_DISP_NAME:-$name}} aplicado (${PATCH_SYMBOLS[0]:-símbolos nuevos}) sobre fuentes $VERSION."
  return 0
}

# ============================================================
# PARCHES DE USUARIO Y PACK MISC CACHYOS  —  v27.30.0
# ============================================================
# apply_user_patches(): aplica cada .patch/.diff de CIZEN_USER_PATCHES_DIR en
# orden alfabético. Un fallo (no aplica limpio o falla el patch real) es FATAL:
# el usuario pidió esos parches y la source debe compilar LOS con ellos.
apply_user_patches() {
  [ -n "$CIZEN_USER_PATCHES_DIR" ] || return 0
  [ -d "$CIZEN_USER_PATCHES_DIR" ] || fatal "CIZEN_USER_PATCHES_DIR no existe: $CIZEN_USER_PATCHES_DIR"
  command -v patch >/dev/null 2>&1 || fatal "No hay 'patch' para aplicar los parches de usuario (sudo pacman -S patch)."

  local -a ups=()
  local f n=0
  shopt -s nullglob
  while IFS= read -r -d '' f; do ups+=("$f"); done \
    < <(find "$CIZEN_USER_PATCHES_DIR" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) -print0 2>/dev/null | sort -z || true)
  shopt -u nullglob
  [ "${#ups[@]}" -gt 0 ] || { info "Directorio de parches de usuario vacío: $CIZEN_USER_PATCHES_DIR"; return 0; }
  info "Aplicando ${#ups[@]} parches de usuario desde $CIZEN_USER_PATCHES_DIR ..."
  for f in "${ups[@]}"; do
    if patch -p1 --dry-run -d "$SRC" < "$f" >/dev/null 2>&1; then
      if patch -p1 -d "$SRC" < "$f" >/dev/null 2>&1; then
        n=$((n + 1))
        ok "Parche de usuario aplicado: ${f##*/}"
      else
        fatal "Fallo REAL al aplicar el parche de usuario ${f##*/} (el dry-run sí valió; árbol inconsistente)."
      fi
    else
      fatal "El parche de usuario ${f##*/} no aplica limpio sobre $VERSION."
    fi
  done
  [ "$n" -gt 0 ] && ok "Parches de usuario: $n aplicado(s)."
  return 0
}

# _misc_extract_kconfig_symbols <fichero.patch>: extrae los símbolos Kconfig
# que un parche misc introduce (líneas '+config'/'+menuconfig') junto a su tipo
# (tristate→m, bool/def_bool→y). Por stdout: 'SIMBOLO=tipo' por línea.
_misc_extract_kconfig_symbols() {
  local pf="${1:-}"
  [ -s "$pf" ] || return 0
  awk '
    /^\+config[[:space:]]+[A-Za-z0-9_]+/ {
      if (sym != "") print sym "=" typ;
      sym = $2; typ = "m"; next;
    }
    /^\+menuconfig[[:space:]]+[A-Za-z0-9_]+/ {
      if (sym != "") print sym "=" typ;
      sym = ""; typ = "m"; next;
    }
    sym != "" && /^\+[[:space:]]*(bool|def_bool)([[:space:]]|$)/ { typ = "y"; next; }
    sym != "" && /^\+[[:space:]]*(tristate|def_tristate)([[:space:]]|$)/ { typ = "m"; next; }
    END { if (sym != "") print sym "=" typ; }
  ' "$pf"
}

# apply_cachy_misc_symbols(): re-habilita en la fase de config los símbolos que
# el pack misc introdujo y que la config lite habría descartado (módulos no
# cargados). Se invoca DESPUÉS de perfil+frags y ANTES de la auditoría: los
# símbolos quedan disponibles para olddefconfig y la validación no los reclama
# (no están en el perfil): si sus dependencias no existen, Kconfig los descarta
# en silencio, coherente con el fail-soft del pack.
apply_cachy_misc_symbols() {
  [ "${#CACHY_MISC_SYMBOLS[@]}" -gt 0 ] || return 0
  local -a args=()
  local symdef sym typ
  for symdef in "${CACHY_MISC_SYMBOLS[@]}"; do
    sym="${symdef%%=*}"; typ="${symdef#*=}"
    case "$typ" in
      y) args+=(--enable "$sym") ;;
      *) args+=(--module "$sym") ;;
    esac
  done
  if ( cd "$SRC" && scripts/config "${args[@]}" ) >/dev/null 2>&1; then
    ok "Pack cachy: ${#CACHY_MISC_SYMBOLS[@]} símbolo(s) introducido(s) por los parches misc habilitado(s) en la config."
  else
    warn "Pack cachy: no se pudieron habilitar los símbolos misc en la config; se continúa sin ellos."
  fi
  return 0
}

# apply_cachy_misc_single(): intenta descargar y aplicar un parche misc del pack
# de CachyOS para la rama del kernel objetivo. Cada candidato de nombre se prueba
# (0001-<item>.patch o <item>.patch según el repo) con download+validación
# patch --dry-run. Devuelve 0 si aplicó. Cuando aplica, recolecta los símbolos
# Kconfig que introduce para habilitarlos en la fase de config.
apply_cachy_misc_single() {
  local br="$1" item="$2" cand tmp url applied=0 __symdef
  command -v patch >/dev/null 2>&1 || return 1
  for cand in "0001-${item}.patch" "${item}.patch"; do
    tmp="$(mktemp "$KERNEL_BUILD_ROOT/cachy-${item}-${br}.XXXXXX.patch" 2>/dev/null || mktemp)"
    rm -f -- "$tmp"
    url="https://raw.githubusercontent.com/CachyOS/kernel-patches/master/${br}/misc/${cand}"
    if download_file "$url" "$tmp"; then
      if [ -s "$tmp" ] && grep -Fqi "diff --git" "$tmp" && patch -p1 --dry-run -d "$SRC" < "$tmp" >/dev/null 2>&1; then
        if patch -p1 -d "$SRC" < "$tmp" >/dev/null 2>&1; then
          ok "CachyOS misc: $item aplicado (rama $br, $cand)."
          applied=1
          while IFS= read -r __symdef; do
            [ -n "$__symdef" ] || continue
            CACHY_MISC_SYMBOLS+=("$__symdef")
          done < <(_misc_extract_kconfig_symbols "$tmp")
        fi
      fi
    fi
    rm -f -- "$tmp"
    [ "$applied" = 1 ] && return 0
  done
  return 1
}

# apply_cachy_misc_patchset(): orquesta el pack misc best-effort. Solo parches
# verificados como aplicables a un árbol vanilla (sin el árbol de CachyOS)
# están en el default set; el resto (aufs, hardened, handheld, rt-i915...) es
# opt-in vía CIZEN_CACHY_PATCH_SET y falla suave si no aplica. Cada fallo es un
# warn, nunca fatal. Los símbolos Kconfig que los parches introducen (p. ej.
# CONFIG_ACPI_CALL) se recolectan aquí y se habilitan después de perfil+frags en
# apply_cachy_misc_symbols, de modo que la opción 16 no solo aplica fuentes sino
# que hace que esas opciones se compilen de verdad (y sobrevivan a la lite).
apply_cachy_misc_patchset() {
  [ "$CIZEN_CACHY_PATCHES" = "1" ] || return 0
  command -v patch >/dev/null 2>&1 || { warn "pack cachy: sin 'patch' instalado; se omite."; return 0; }
  local br="$(bore_branch_from_version "$VERSION")" item applied=0 skipped=0
  local -a __cachy_items=()
  IFS=' ' read -r -a __cachy_items <<< "${CIZEN_CACHY_PATCH_SET:-acpi-call}"
  info "Pack misc CachyOS (best-effort) para la rama $br: ${CIZEN_CACHY_PATCH_SET:-acpi-call} ..."
  for item in "${__cachy_items[@]}"; do
    case "$item" in
      acpi-call|aufs|dkms-clang|handheld|hardened|nvidia|rt-i915)
        if apply_cachy_misc_single "$br" "$item"; then
          applied=$((applied + 1))
        else
          warn "pack cachy: '$item' no disponible/falla para la rama $br (fail-soft, se omite)."
          skipped=$((skipped + 1))
        fi
        ;;
      *) warn "pack cachy: entrada desconocida '$item' (se ignora; válidas: acpi-call aufs dkms-clang handheld hardened nvidia rt-i915)." ;;
    esac
  done
  [ "$applied" -gt 0 ] && ok "Pack misc CachyOS: $applied aplicado(s)${skipped:+ (${skipped} omitido(s))}."
  return 0
}

# ============================================================
# CONFIG BASE
# ============================================================
find_latest_cizen_config() {
  local f v best_f="" best_v=""
  shopt -s nullglob
  for f in "$CONFIG_DIR"/linux-*-cizen-v3.config; do
    [[ "$(basename -- "$f")" =~ ^linux-([0-9]+\.[0-9]+([.][0-9]+)?)-cizen-v3\.config$ ]] || continue
    v="${BASH_REMATCH[1]}"
    # Solo configuraciones de versiones <= a la objetivo: usar una base de
    # una versión MÁS nueva que la que se va a compilar arrastra símbolos de
    # una migración futura. Sin VERSION fijado, se elige la mayor disponible.
    if [ -n "$VERSION" ] && version_gt "$v" "$VERSION"; then
      continue
    fi
    if [ -z "$best_v" ] || version_gt "$v" "$best_v"; then
      best_v="$v"
      best_f="$f"
    fi
  done
  shopt -u nullglob
  printf '%s\n' "${best_f:-}"
}


choose_base_config() {
  local ref
  ref="$(find_latest_cizen_config)"
  if [ -n "$ref" ] && [ -f "$ref" ]; then
    cp "$ref" .config
    ok "Config base Cizen: $ref"
    return 0
  fi

  if zcat /proc/config.gz > .config 2>/dev/null; then
    warn "No se encontró configuración Cizen; se usa /proc/config.gz del kernel arrancado."
    return 0
  fi
  if [ -f "/boot/config-$(uname -r)" ]; then
    cp "/boot/config-$(uname -r)" .config
    warn "No se encontró configuración Cizen; se usa /boot/config-$(uname -r)."
    return 0
  fi

  fatal "No existe configuración base Cizen ni configuración del kernel arrancado."
}

# ============================================================
# MODO LITE (v27.25.2): ÚNICO modo de compilación de esta suite (v27.25.4)
# ============================================================
# make localmodconfig (herramienta oficial del kernel) reduce .config para que
# el build NO compile los miles de módulos que la poda posterior borraría del
# paquete. El input es /proc/modules + el allowlist del podador (--keep-list:
# CORE_KEEP + /etc/modules-load.d + CIZEN_KEEP_MODULES) + vendrá de la misma
# fuente que la poda. Los =y (built-in) ni se tocan: el arranque sin initramfs
# sigue garantizado. No requiere haber compilado nada; solo re-usa conf/olddefconfig.
# ------------------------------------------------------------
# lite_missing_check <log>: dado el stderr capturado de streamline_config.pl
# ("X config not found!", "module X did not have configs CONFIG_*...",
# "WARNING: CONFIG_X is required,..."), determina qué módulos CARGADOS no
# quedarían compilados en la config lite recién generada. Devuelve por stdout
# la lista de nombres perdidos (vacío = ningún módulo en riesgo). Un aviso NO
# es una pérdida: solo significa que streamline no validó el vínculo módulo↔
# CONFIG y el símbolo hereda la config base. Se silencian: módulos no cargados
# (allowlist conservador, ausencia = estado actual), símbolos que quedan =y/o=m,
# desactivados a propósito (OPTS_DISABLE/REBELS) y símbolos que ya no existen
# en este Kconfig (renombrados/legacy).
# ------------------------------------------------------------
lite_missing_check() {
  local _log="${1:-}" _line _m _tok _sym _n _in _gap="" _s
  local _pm="${CIZEN_PROC_MODULES:-/proc/modules}"
  [ -s "$_log" ] || return 0
  declare -A _ctx=()
  while IFS= read -r _line; do
    case "$_line" in
      *" config not found!")
        _m="${_line%% *}"
        _ctx["CONFIG_$(printf '%s' "$_m" | tr '[:lower:]' '[:upper:]')"]="$_m"
        ;;
      "module "*" did not have configs "*)
        _m="${_line#module }"; _m="${_m%% did not have configs*}"
        for _tok in ${_line#*configs }; do
          case "$_tok" in CONFIG_*) _ctx["${_tok%%=*}"]="$_m" ;; esac
        done
        ;;
      WARNING:*)
        _tok="${_line#WARNING: }"; _tok="${_tok%% *}"
        case "$_tok" in CONFIG_*) _ctx["${_tok%%=*}"]="${_ctx[${_tok%%=*}]:-}" ;; esac
        ;;
    esac
  done < "$_log"
  for _s in "${!_ctx[@]}"; do
    _m="${_ctx[$_s]}"
    # Módulo asociado no cargado → no es pérdida real (el allowlist conserva
    # módulos que el kernel funcionando nunca compiló; su ausencia es el estado
    # actual). Sin módulo asociado ("WARNING: CONFIG_X is required") se evalúa.
    if [ -n "$_m" ] && ! grep -qE "^${_m}( |$)" "$_pm" 2>/dev/null; then
      continue
    fi
    # Símbolo heredado =y/=m de la config base → se compila igual
    if grep -qE "^${_s}=(y|m)$" "$SRC/.config" 2>/dev/null; then
      continue
    fi
    _n="${_s#CONFIG_}"
    _in=0
    # Desactivado a propósito (OPTS_DISABLE / REBELS) → decisión del usuario
    for _e in "${EFF_DISABLE[@]}"; do [ "$_e" = "$_n" ] && _in=1 && break; done
    if [ "$_in" = 0 ] && [ -z "${EXPECTED_REBEL_SET[$_n]:-}" ]; then
      # Símbolo ausente de este Kconfig (renombrado/legacy) → no aplicable
      if ! grep -rq '^[[:space:]]*\(config\|menuconfig\) '"$_n"'$' --include='Kconfig*' "$SRC" 2>/dev/null; then
        _in=1
      fi
    fi
    [ "$_in" = 1 ] && continue
    _gap="$_gap ${_m:-$_n}"
  done
  printf '%s' "${_gap# }"
}

prepare_lite_config() {
  command -v make >/dev/null || fatal "--lite requiere make (make localmodconfig)."
  if [ ! -d "$SRC/scripts/kconfig" ]; then
    fatal "--lite requiere el árbol del kernel (scripts/kconfig) en $SRC."
  fi
  [ -x "$PRUNER_SCRIPT" ] || fatal "--lite no puede generar la lista de conservación: podador no ejecutable ($PRUNER_SCRIPT)."

  local keepfile keep_lines=0 _k
  keepfile="$HOME/.cache/kernel-kbuild/.lite-keep-${TS:-$$}.$$"
  mkdir -p "${keepfile%/*}"
  {
    cat /proc/modules 2>/dev/null || true
    while IFS= read -r _k; do
      [ -n "$_k" ] || continue
      keep_lines=$((keep_lines + 1))
      # Solo importa la primera columna (nombre del módulo).
      printf '%s 0 0 0 - 0\n' "$_k"
    done < <("$PRUNER_SCRIPT" --keep-list "${CIZEN_KEEP_MODULES:-}" || true)
    # v27.30.0: historial persistente de modprobed-db (CIZEN_MODPROBED_DB).
    # La bbdd es texto plano con un nombre de módulo por línea; se añade al
    # LSMOD igual que hace linux-tkg (LSMOD=$db), de modo que modules que ya se
    # cargaron alguna vez se conserven en la build lite aunque el hardware
    # remoto/hotplug aún no los haya activado hoy.
    if [ "${CIZEN_MODPROBED_DB}" != "0" ]; then
      local _dbp="" _moddb
      if [ "${CIZEN_MODPROBED_DB}" = "1" ]; then
        for _moddb in "$HOME/.local/share/modprobed-db/modprobed.db" "$HOME/.config/modprobed.db"; do
          [ -s "$_moddb" ] && { _dbp="$_moddb"; break; }
        done
      elif [ -s "$CIZEN_MODPROBED_DB" ]; then
        _dbp="$CIZEN_MODPROBED_DB"
      fi
      if [ -n "$_dbp" ]; then
        while IFS= read -r _k; do
          [ -n "$_k" ] || continue
          keep_lines=$((keep_lines + 1))
          printf '%s 0 0 0 - 0\n' "$_k"
        done < <(sed -e 's/[[:space:]].*$//' -e '/^#/d' -e '/^$/d' "$_dbp" 2>/dev/null || true)
        log "--lite: historial modprobed-db sumado al keep-list ($_dbp)."
      else
        warn "--lite con modprobed-db pedido (CIZEN_MODPROBED_DB) pero sin base de datos local; se continúa solo con /proc/modules+allowlist."
      fi
      unset _dbp _moddb
    fi
  } > "$keepfile"

  log "--lite: localmodconfig (módulos cargados + $keep_lines del allowlist)..."
  # Replicamos la receta de scripts/kconfig/Makefile (streamline_config.pl +
  # conf) pero reemplazando el `--oldconfig` final —que es INTERACTIVO y con
  # símbolos nuevos (p. ej. SCHED_BORE del parche BORE) pide respuestas— por
  # `make olddefconfig` (no interactivo: los símbolos (NEW) toman su default y
  # el perfil/auditoría los re-fuerzan después).
  local rc karch ksrcarch lite_log lite_gap=
  lite_log="$SRC/.config.cizen-lite.err"
  # make inyecta ARCH/SRCARCH por defecto; ejecutado a mano, streamline_config.pl
  # los necesita en el entorno para resolver "arch/$(SRCARCH)/Kconfig".
  case "$(uname -m)" in
    x86_64|amd64)  karch=x86_64 ksrcarch=x86 ;;
    i?86)          karch=i386    ksrcarch=i386 ;;
    aarch64)       karch=arm64   ksrcarch=arm64 ;;
    armv7l|armv6l) karch=arm     ksrcarch=arm ;;
    ppc64le)       karch=powerpc ksrcarch=powerpc ;;
    *)             karch="$(uname -m)" ksrcarch="$karch" ;;
  esac
  export ARCH="$karch" SRCARCH="$ksrcarch"
  # El stderr de streamline_config.pl (módulos cargados sin vínculo módulo↔
  # CONFIG validado: "config not found!", "WARNING ... did not have configs /
  # is required") y el banner de conf ("configuration written to .config") son
  # ruido técnico del modo lite, no errores: el símbolo hereda la config base.
  # Se capturan a un log: en éxito se verifica que ningún módulo citado quede
  # FUERA de la build (lite_missing_check) y en fallo se vuelcan para diagnóstico.
  if ( cd "$SRC" \
      && LSMOD="$keepfile" perl scripts/kconfig/streamline_config.pl --localmodconfig "$SRC" Kconfig > .config.cizen-lite 2> "$lite_log" \
      && mv -f .config .config.cizen-lite.old \
      && mv -f .config.cizen-lite .config \
      && make "${KCONFIG_CC_OPTS[@]}" ARCH="$karch" olddefconfig >> "$lite_log" 2>&1 \
      && rm -f .config.cizen-lite.old ); then
    ok "Config lite generada: solo se compilarán los módulos en uso ($keep_lines en allowlist)."
    lite_gap="$(lite_missing_check "$lite_log" 2>/dev/null || true)"
    if [ -n "$lite_gap" ]; then
      warn "El modo lite NO compilaría estos módulos (cargados o en allowlist) y su símbolo no está en OPTS_ENABLE: $lite_gap."
    fi
    rm -f -- "$lite_log"
  else
    rc=$?
    if [ -s "${lite_log:-}" ]; then
      err "Detalle de localmodconfig (motivo del fallo):"
      sed 's/^/    /' "$lite_log" | tail -40 >&2 || true
    fi
    rm -f -- "$SRC/.config.cizen-lite" "$lite_log"
    fatal "make localmodconfig falló (rc=$rc). El modo lite es el ÚNICO modo de compilación: se aborta en lugar de compilar la config completa."
  fi
  unset rc karch ksrcarch lite_gap lite_log ARCH SRCARCH
  rm -f -- "$keepfile"
  unset _k keep_lines
}

# Comparador semántico de versiones de kernel: X.Y.Z >= W.V.U (sort -V sobre la
# parte de versión pura, sin sufijos -cizen...). Devuelve 0 si $1 >= $2.
kernel_version_ge() {
  local a="${1%%-*}" b="${2%%-*}"
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" = "$b" ]
}

# ntsync se pide solo para kernels SIN soporte nativo (< 6.10). Con $VERSION
# vacío (kcheck --check-update) no se decide nada y el usuario puede pedir
# --patch ntsync a mano. Se llama desde el flujo principal, no en el arranque
# del script, para no invocar kernel_version_ge antes de existir.
auto_add_ntsync_patch() {
  [ "$CIZEN_PATCH_NTSYNC" != "0" ] || return 0
  [ -n "${VERSION:-}" ] || return 0
  kernel_version_ge "$VERSION" "6.10" && return 0
  case " ${PATCH_NAMES[*]:-} " in
    *" ntsync "*) ;;
    *) PATCH_NAMES+=(ntsync) ;;
  esac
}

# ============================================================
# SCRIPTS/CONFIG + KCONFIG
# ============================================================
declare -A CONFIG_STATE=()

load_config_state() {
  local line sym val
  CONFIG_STATE=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)=(.*)$ ]]; then
      sym="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      CONFIG_STATE["$sym"]="$val"
    elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
      sym="${BASH_REMATCH[1]}"
      CONFIG_STATE["$sym"]="n"
    fi
  done < .config
}

config_symbol_state() {
  local sym="$1"
  if [ -n "${CONFIG_STATE[$sym]+x}" ]; then
    printf '%s\n' "${CONFIG_STATE[$sym]}"
  else
    printf '%s\n' "missing"
  fi
}

# Existencia real en el Kconfig de la versión objetivo. No depende de que el
# símbolo aparezca previamente en .config; Kconfig puede materializarlo después
# de olddefconfig. El resultado se cachea durante la ejecución.
declare -A KCONFIG_SYMBOL_KNOWN=()
declare -A KCONFIG_SYMBOL_TYPE=()
KCONFIG_TYPE_INDEX_BUILT=false
KCONFIG_SYMBOL_INDEX_BUILT=false

build_kconfig_symbol_index() {
  [ "$KCONFIG_SYMBOL_INDEX_BUILT" = true ] && return 0

  local sym
  # El pipeline interno puede devolver rc!=0 legítimamente: xargs parte la lista
  # en varios lotes y un lote cuyo grep no encuentre ningún `config`/`menuconfig`
  # sale con status 1. Con `set -Eeuo pipefail` (heredado por el subshell del
  # process-substitution), el `find | xargs | grep | awk | sort` del pipeline entero
  # reportaría error y el trap ERR del subshell dispararía `on_err` falsamente
  # (salida "Error ... sort -u", índice ya construido pero abortado en apariencia).
  # El índice se construye leyendo el stream: `|| true` absorbe ese rc legítimo sin
  # enmascarar un fallo de ESCALADO (Kconfig no encontrado sigue dejando el índice vacío).
  while IFS= read -r sym; do
    [ -n "$sym" ] || continue
    KCONFIG_SYMBOL_KNOWN["$sym"]=1
  done < <(
    find "$SRC" \( -name 'Kconfig' -o -name 'Kconfig.*' \) -print0 2>/dev/null |
      xargs -0 -r grep -hoE '^[[:space:]]*(menuconfig|config)[[:space:]]+[A-Za-z0-9_]+' 2>/dev/null |
      awk '{print $2}' |
      sort -u || true
  )

  KCONFIG_SYMBOL_INDEX_BUILT=true
}

kconfig_symbol_known() {
  local sym="$1"
  build_kconfig_symbol_index
  [ -n "${KCONFIG_SYMBOL_KNOWN[$sym]:-}" ]
}

# v27.31.28: el índice se cachea una sola vez por proceso, así que un parche que
# añade símbolos Kconfig (BORE mete config SCHED_BORE en init/Kconfig y config
# MIN_BASE_SLICE_NS en kernel/Kconfig.hz) llegaba al validador con el índice del
# árbol SIN parchear. Resultado: "ENABLE: CONFIG_SCHED_BORE no existe en esta
# versión" para un símbolo que existe, y un "--rename" que no arreglaba nada.
# Cualquier cambio en el árbol tiene que tirar el índice.
kconfig_index_invalidate() {
  KCONFIG_SYMBOL_KNOWN=()
  KCONFIG_TYPE_INDEX_BUILT=false
  KCONFIG_SYMBOL_INDEX_BUILT=false
}

# Tipo Kconfig de un símbolo: bool | tristate | int | hex | string (vacío = bool,
# que es el tipo por defecto de Kconfig si el bloque no lo declara).
# v27.31.28: hace falta porque PATCH_SYMBOLS asumía que todo era booleano y
# forzaba a "=y" símbolos que no lo son. MIN_BASE_SLICE_NS es `int` (lo declara
# el parche BORE en kernel/Kconfig.hz): scripts/config le ponía CONFIG_...=y,
# olddefconfig lo devolvía a su default y la validación se quedaba en 37/38
# para siempre, sin decir de qué símbolo se trataba.
build_kconfig_type_index() {
  [ "$KCONFIG_TYPE_INDEX_BUILT" = true ] && return 0
  local pair sym tipo
  # v27.31.29: separador TAB y IFS explícito. El motor trabaja con IFS=$'\n\t',
  # así que un "read -r sym tipo" NO parte por el espacio: las claves acababan
  # siendo "MIN_BASE_SLICE_NS int" enteras, ninguna búsqueda por nombre encontraba
  # nada y TODOS los símbolos parecían booleanos (que es justo el bug que esto
  # iba a arreglar: el int de BORE volvía a la rama de forzar a "=y").
  while IFS=$'\t' read -r sym tipo; do
    [ -n "$sym" ] || continue
    KCONFIG_SYMBOL_TYPE["$sym"]="$tipo"
  done < <(
    find "$SRC" \( -name 'Kconfig' -o -name 'Kconfig.*' \) -print0 2>/dev/null |
      xargs -0 -r cat 2>/dev/null |
      awk '
        /^[[:space:]]*(menuconfig|config)[[:space:]]+[A-Za-z0-9_]+/ {
          if (sym != "") printf "%s\t%s\n", sym, tipo
          sym = $2; tipo = ""; next
        }
        sym != "" && tipo == "" &&
          match($0, /^[[:space:]]*(bool|tristate|int|hex|string|def_bool|def_tristate|def_int|def_hex|def_string)([[:space:]]|$)/) {
          tipo = substr($0, RSTART, RLENGTH); gsub(/[[:space:]]/, "", tipo); sub(/^def_/, "", tipo)
        }
        END { if (sym != "") printf "%s\t%s\n", sym, tipo }
      ' 2>/dev/null | sort -u || true
  )
  KCONFIG_TYPE_INDEX_BUILT=true
}

kconfig_symbol_type() { # vacío = bool (el tipo por defecto de Kconfig)
  build_kconfig_type_index
  printf '%s' "${KCONFIG_SYMBOL_TYPE[$1]:-}"
}

# v27.31.28: renombrado automático. Busca el símbolo más parecido entre los que
# SÍ existen en el Kconfig de esta versión y lo devuelve SOLO si hay un
# candidato único y claramente mejor que el segundo. Con dos candidatos
#empatados no se inventa nada: es mejor pedir confirmación que activar el
#símbolo equivocado en un kernel que se está a punto de arrancar.
kconfig_auto_candidate() { # $1 = símbolo desconocido
  local sym="$1" best="" second=0 best_score=0 tie=0
  local s c i n cp score suffix best_cp=0
  build_kconfig_symbol_index
  [ "${#KCONFIG_SYMBOL_KNOWN[@]}" -gt 0 ] || return 0
  s="${sym#CONFIG_}"
  n=${#s}
  for c in "${!KCONFIG_SYMBOL_KNOWN[@]}"; do
    c="${c#CONFIG_}"
    # Filtro barato: un renombrado conserva el principio o el final.
    if [ "${c:0:3}" != "${s:0:3}" ] && [ "${c: -4}" != "${s: -4}" ]; then
      continue
    fi
    cp=0
    i=0
    while [ "$i" -lt "$n" ] && [ "$i" -lt "${#c}" ] && [ "${s:$i:1}" = "${c:$i:1}" ]; do
      cp=$((cp + 1)); i=$((i + 1))
    done
    suffix=0
    while [ "$suffix" -lt "$n" ] && [ "$suffix" -lt "${#c}" ] \
       && [ "${s:$((n - suffix - 1)):1}" = "${c:$(( ${#c} - suffix - 1 )):1}" ]; do
      suffix=$((suffix + 1))
    done
    # Un parecido solo cuenta si comparten un trozo reconocible: 5 al principio
    # o 6 al final (p. ej. FOO_BAR -> FOO_BAR_NEW / FOO -> NEW_FOO).
    if [ "$cp" -lt 5 ] && [ "$suffix" -lt 6 ]; then
      continue
    fi
    score=$((cp + suffix))
    if [ "$score" -gt "$best_score" ]; then
      second=$best_score; best_score=$score; best="$c"; best_cp=$cp; tie=0
    elif [ "$score" -eq "$best_score" ] && [ -n "$best" ]; then
      tie=1
    elif [ "$score" -gt "$second" ]; then
      second=$score
    fi
  done
  # Que sea el mejor no basta: tiene que ser *el mismo nombre*. Se exige un
  # prefijo común largo (>= 6), que ninguno sea prefijo del otro y que la
  # diferencia sea corta (4 caracteres o menos: el final cambiado, un renombrado
  # de verdad). Se rechazan a propósito los dos casos que parecen renombres y no
  # lo son, porque activar el símbolo equivocado en un kernel que se va a
  # arrancar es peor que no renombrar nada:
  #   - división de feature: PREEMPT_DYNAMIC_KSYMS -> PREEMPT_DYNAMIC (una es
  #     parte de la otra; encender la padre no es encender la hija)
  #   - opción nueva: SCHED_BORE -> SCHED_BORE_MITIGATION (apareció algo, no se
  #     renombró nada)
  # Con la regla laxa, PERF_GUEST_EVENTS se "renombraba" a PERF_EVENTS y
  # activaba un símbolo que el perfil no pidió nunca.
  if [ -z "$best" ] || [ "$tie" = 1 ] || [ "$best_score" -le "$second" ]; then
    return 0
  fi
  if [ "$best_cp" -lt 6 ]; then
    return 0
  fi
  case "$s" in "$best"|"$best"_*|"$best"-*) return 0 ;; esac
  case "$best" in "$s"|"$s"_*|"$s"-*) return 0 ;; esac
  if [ $(( ${#s} > ${#best} ? ${#s} - ${#best} : ${#best} - ${#s} )) -gt 4 ]; then
    return 0
  fi
  printf '%s' "$best"
  return 0
}

# Resuelve automáticamente los símbolos de las listas efectivas que no existen en
# el Kconfig de esta versión. Se aplica a todas (ENABLE/DISABLE/CRITICAL/SETVAL/
# SETSTR) porque un renombrado no distingue: si el perfil pide FOO y aquí se llama
# BAR, hay que renombrarlo en todas partes. Lo que se resuelve queda anotado en
# APPLIED_RENAMES y se informa; con --save-auto-renames se persiste en el mapa.
auto_resolve_effective_symbols() {
  local o cand
  local -a nn=()
  local any=false
  [ -d "$SRC" ] || return 0
  build_kconfig_symbol_index
  for o in "${EFF_ENABLE[@]}" "${EFF_DISABLE[@]}" "${EFF_CRITICAL[@]}" \
           "${!EFF_SETVAL[@]}" "${!EFF_SETSTR[@]}"; do
    [ -n "$o" ] || continue
    if kconfig_symbol_known "$o"; then
      nn+=("$o"); continue
    fi
    cand="$(kconfig_auto_candidate "$o")"
    if [ -n "$cand" ]; then
      nn+=("$cand")
      APPLIED_RENAMES["$o"]="$cand"
      AUTO_RENAMES["$o"]="$cand"
      any=true
    else
      nn+=("$o")
    fi
  done
  # Se reconstruyen las listas limpias, sin duplicados y con el orden original.
  if [ "$any" = true ]; then
    local -A seen=()
    local -a e=() d=() c=()
    for o in "${EFF_ENABLE[@]}"; do
      cand="${APPLIED_RENAMES[$o]:-$o}"; [ -n "${seen[e$cand]:-}" ] || { seen[e$cand]=1; e+=("$cand"); }
    done
    for o in "${EFF_DISABLE[@]}"; do
      cand="${APPLIED_RENAMES[$o]:-$o}"; [ -n "${seen[d$cand]:-}" ] || { seen[d$cand]=1; d+=("$cand"); }
    done
    for o in "${EFF_CRITICAL[@]}"; do
      cand="${APPLIED_RENAMES[$o]:-$o}"; [ -n "${seen[c$cand]:-}" ] || { seen[c$cand]=1; c+=("$cand"); }
    done
    # v27.31.29: SETVAL/SETSTR se reconstruyen con arrays asociativos nuevos, NO
    # con un string "SYM=$>valor". Ese round-trip estaba roto desde v27.31.28:
    # el patrón "=*>" exige un '>' al FINAL del match, pero el valor va detrás del
    # separador "$>", así que ${x%%=*>} y ${x#*=>} devolvían el string entero.
    # Resultado: la clave pasaba a ser "HZ=$>1000", kconfig_symbol_known decía
    # que no existía y el validador contaba 28 SETVAL + 1 SETSTR como "missing"
    # con una .config perfectamente correcta.
    local -A seen2=() nsv=() nss=()
    for o in "${!EFF_SETVAL[@]}"; do
      cand="${APPLIED_RENAMES[$o]:-$o}"; [ -n "${seen2[$cand]:-}" ] || { seen2[$cand]=1; nsv["$cand"]="${EFF_SETVAL[$o]}"; }
    done
    seen2=()
    for o in "${!EFF_SETSTR[@]}"; do
      cand="${APPLIED_RENAMES[$o]:-$o}"; [ -n "${seen2[$cand]:-}" ] || { seen2[$cand]=1; nss["$cand"]="${EFF_SETSTR[$o]}"; }
    done
    EFF_ENABLE=("${e[@]}"); EFF_DISABLE=("${d[@]}"); EFF_CRITICAL=("${c[@]}")
    EFF_SETVAL=(); EFF_SETSTR=()
    local k
    for k in "${!nsv[@]}"; do EFF_SETVAL["$k"]="${nsv[$k]}"; done
    for k in "${!nss[@]}"; do EFF_SETSTR["$k"]="${nss[$k]}"; done
  fi
}

# ============================================================
# V27.30.0 — OVERLAY DE COMPILACIÓN SOBRE EL PERFIL
# Las opciones de compilación (OLEVEL, HZ, LTO, ntsync, firma de módulos) NO
# van al perfil: mutan los arrays efectivos justo antes de apply_config_requests
# para que viajen en la misma pasada de scripts/config, se re-normalicen en la
# auditoría (olddefconfig) y la validación los acepte como esperados.
# ============================================================
# Borra un símbolo de un array EFF_*0 por su valor exacto (recompacta índices).
eff_remove() {
  local arr="$1" val="$2" i
  case "$arr" in
    EFF_ENABLE)
      for i in "${!EFF_ENABLE[@]}"; do
        [ "${EFF_ENABLE[$i]}" = "$val" ] && unset 'EFF_ENABLE[$i]'
      done
      EFF_ENABLE=("${EFF_ENABLE[@]}")
      ;;
    EFF_DISABLE)
      for i in "${!EFF_DISABLE[@]}"; do
        [ "${EFF_DISABLE[$i]}" = "$val" ] && unset 'EFF_DISABLE[$i]'
      done
      EFF_DISABLE=("${EFF_DISABLE[@]}")
      ;;
  esac
}

inject_build_overlay() {
  local o

  # Frecuencia del timer: override del pin del perfil (EFF_SETVAL[HZ]).
  if [ "$CIZEN_TIMER_FREQ" != "inherit" ]; then
    EFF_SETVAL["HZ"]="$CIZEN_TIMER_FREQ"
    EXPECTED_REBEL_SET["HZ"]=1
    info "Overlay: CONFIG_HZ=$CIZEN_TIMER_FREQ (override del perfil)."
  fi

  # Nivel de optimización (choice): 3 activa CC_OPTIMIZE_FOR_PERFORMANCE_O3 y
  # suelta CC_OPTIMIZE_FOR_PERFORMANCE; 2 lo inverso.
  case "$CIZEN_CFLAGS_OLEVEL" in
    3)
      eff_remove EFF_ENABLE CC_OPTIMIZE_FOR_PERFORMANCE
      eff_remove EFF_ENABLE CC_OPTIMIZE_FOR_SIZE
      add_unique enable "CC_OPTIMIZE_FOR_PERFORMANCE_O3"
      add_unique disable "CC_OPTIMIZE_FOR_PERFORMANCE"
      add_unique disable "CC_OPTIMIZE_FOR_SIZE"
      EXPECTED_REBEL_SET[CC_OPTIMIZE_FOR_PERFORMANCE_O3]=1
      EXPECTED_REBEL_SET[CC_OPTIMIZE_FOR_PERFORMANCE]=1
      EXPECTED_REBEL_SET[CC_OPTIMIZE_FOR_SIZE]=1
      PATCH_KCONFIG_FILTER[CC_OPTIMIZE_FOR_PERFORMANCE_O3]=1
      info "Overlay: compilación de rendimiento -O3."
      ;;
    2)
      eff_remove EFF_ENABLE CC_OPTIMIZE_FOR_PERFORMANCE_O3
      add_unique enable "CC_OPTIMIZE_FOR_PERFORMANCE"
      add_unique disable "CC_OPTIMIZE_FOR_PERFORMANCE_O3"
      EXPECTED_REBEL_SET[CC_OPTIMIZE_FOR_PERFORMANCE]=1
      EXPECTED_REBEL_SET[CC_OPTIMIZE_FOR_PERFORMANCE_O3]=1
      PATCH_KCONFIG_FILTER[CC_OPTIMIZE_FOR_PERFORMANCE]=1
      info "Overlay: compilación de rendimiento -O2."
      ;;
  esac

  # LTO (clang): enlazar módulo-con-módulo al armar el kernel. Solo inyecta si
  # la sanidad temprana (parser de args) dejó CIZEN_LLVM_LTO!=0 con clang real.
  case "$CIZEN_LLVM_LTO" in
    thin|full)
      o="LTO_CLANG_${CIZEN_LLVM_LTO^^}"
      add_unique enable "$o"
      add_unique disable "LTO_CLANG_FULL"
      add_unique disable "LTO_CLANG_THIN"
      add_unique disable "LTO_NONE"
      EXPECTED_REBEL_SET["$o"]=1
      EXPECTED_REBEL_SET[LTO_CLANG_FULL]=1
      EXPECTED_REBEL_SET[LTO_CLANG_THIN]=1
      EXPECTED_REBEL_SET[LTO_NONE]=1
      PATCH_KCONFIG_FILTER["$o"]=1
      info "Overlay: LTO de Clang ${CIZEN_LLVM_LTO^^}."
      ;;
    0)
      add_unique enable "LTO_NONE"
      add_unique disable "LTO_CLANG_THIN"
      add_unique disable "LTO_CLANG_FULL"
      EXPECTED_REBEL_SET[LTO_NONE]=1
      EXPECTED_REBEL_SET[LTO_CLANG_THIN]=1
      EXPECTED_REBEL_SET[LTO_CLANG_FULL]=1
      ;;
  esac

  # NTSYNC: en mainline >= 6.10 es un CONFIG nativo (drivers/misc/ntsync.c).
  # Para kernels más viejos se pide el parche (patch_desc_ntsync) y aquí no se
  # fuerza símbolo alguno (el parche lo aporta).
  if [ "$CIZEN_PATCH_NTSYNC" != "0" ] && kernel_version_ge "$VERSION" "6.10"; then
    add_unique enable "NTSYNC"
    EXPECTED_REBEL_SET[NTSYNC]=1
    PATCH_KCONFIG_FILTER[NTSYNC]=1
  fi

  # Firma persistente de módulos (MODULE_SIG=y; las claves MOK se instalan tras
  # el build y se firman los módulos en el árbol de módulos instalado).
  if [ "$CIZEN_MODULE_SIGN" = "yes" ]; then
    add_unique enable "MODULE_SIG"
    EXPECTED_REBEL_SET[MODULE_SIG]=1
    PATCH_KCONFIG_FILTER[MODULE_SIG]=1
    info "Overlay: firma de módulos del kernel (MODULE_SIG=yes)."
  fi

  unset o
}

# ============================================================
# V27.30.0 — FRAGS DE CONFIGURACIÓN REUTILIZABLES (.frag)
# Un frag es un mini-perfil portable con líneas CONFIG_X=y|m|n, valores y
# cadenas, o "# CONFIG_X is not set". Soporta "#include otro.frag" (relativo al
# directorio). Se aplican DESPUÉS del perfil (y del overlay), así que permiten
# afinar sin tocar el perfil; no pueden contradecir símbolos que el perfil
# exige (la validación lo detecta igualmente).
# ============================================================
process_frag_file() {
  local f="$1" line inc
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*#include[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
      inc="$CIZEN_FRAGS_DIR/${BASH_REMATCH[1]}"
      if [ -f "$inc" ] && process_frag_file "$inc"; then
        :
      else
        warn "frag: include no encontrado: ${BASH_REMATCH[1]}"
      fi
      continue
    fi
    printf '%s\n' "$line"
  done < "$f"
}

apply_config_fragments() {
  [ -d "$CIZEN_FRAGS_DIR" ] || return 0

  local -a __frags=() __args=()
  local f line k v parsed got=0
  shopt -s nullglob
  while IFS= read -r -d '' f; do __frags+=("$f"); done \
    < <(find "$CIZEN_FRAGS_DIR" -maxdepth 1 -type f -name '*.frag' -print0 2>/dev/null || true)
  shopt -u nullglob
  [ "${#__frags[@]}" -gt 0 ] || return 0

  while IFS= read -r f; do
    __args=()
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '') continue ;;
        '# CONFIG_'*' is not set')
          k="${line#\# }"; k="${k%% is not set*}"
          __args+=(--disable "${k#CONFIG_}") ;;
        '#'*) continue ;;
        CONFIG_*=*)
          k="${line%%=*}"; v="${line#*=}"
          case "$v" in
            y) __args+=(--enable "${k#CONFIG_}") ;;
            m) __args+=(--module "${k#CONFIG_}") ;;
            n) __args+=(--disable "${k#CONFIG_}") ;;
            *)
              if [[ "$v" =~ ^\"(.*)\"$ ]]; then
                __args+=(--set-str "${k#CONFIG_}" "${BASH_REMATCH[1]}")
              else
                __args+=(--set-val "${k#CONFIG_}" "$v")
              fi
              ;;
          esac
          ;;
        *)
          warn "frag ${f##*/}: línea ignorada: $line" ;;
      esac
    done < <(process_frag_file "$f")

    [ "${#__args[@]}" -gt 0 ] || continue
    if ( cd "$SRC" && scripts/config "${__args[@]}" ) >/dev/null 2>&1; then
      got=$((got + 1))
      info "Frag aplicado: ${f##*/} ($(( ${#__args[@]} / 2 )) directivas)"
    else
      warn "El frag ${f##*/} no se pudo aplicar; build continúa sin él."
    fi
  done < <(printf '%s\n' "${__frags[@]}" | sort -V)

  if [ "$got" -gt 0 ]; then
    ok "Frags de configuración: $got aplicado(s) desde $CIZEN_FRAGS_DIR (se re-normalizan en la auditoría)."
  fi
  return 0
}

apply_config_requests() {
  local o rc=0
  local -a args=()

  # Antes de tocar nada: si el perfil pide un símbolo que esta versión llama de
  # otra forma, se resuelve solo (cuando el candidato es único) y se avisa de lo
  # que se renombró, en vez de saltar el símbolo y dejar la validación cojea.
  auto_resolve_effective_symbols

  if [ "${PROFILE_CHANGED:-false}" = true ]; then
    log "Preparando ${#EFF_ENABLE[@]} activaciones, ${#EFF_DISABLE[@]} desactivaciones, ${#EFF_SETVAL[@]} valores numéricos y ${#EFF_SETSTR[@]} valores de texto..."
  else
    log "Preparando configuración Cizen..."
  fi

  for o in "${EFF_ENABLE[@]}"; do
    if kconfig_symbol_known "$o"; then
      args+=(--enable "$o")
    else
      warn "ENABLE: CONFIG_$o no existe en esta versión ni tiene un renombrado inequívoco en su Kconfig; se omite."
      warn "       (si ya sabes cómo se llama aquí: $0 --rename $o=OTRO_NOMBRE)"
    fi
  done

  for o in "${EFF_DISABLE[@]}"; do
    if kconfig_symbol_known "$o"; then
      args+=(--disable "$o")
    fi
  done

  for o in "${!EFF_SETVAL[@]}"; do
    if kconfig_symbol_known "$o"; then
      args+=(--set-val "$o" "${EFF_SETVAL[$o]}")
    else
      warn "SETVAL: CONFIG_$o no existe en el Kconfig de esta versión."
    fi
  done

  for o in "${!EFF_SETSTR[@]}"; do
    if kconfig_symbol_known "$o"; then
      args+=(--set-str "$o" "${EFF_SETSTR[$o]}")
    else
      warn "SETSTR: CONFIG_$o no existe en el Kconfig de esta versión."
    fi
  done

  if [ "${#args[@]}" -gt 0 ]; then
    if ! scripts/config "${args[@]}"; then
      err "scripts/config falló al aplicar el perfil en una única pasada."
      rc=1
    fi
  fi

  return "$rc"
}

run_kconfig_audit() {
  export KCONFIG_WARN_UNKNOWN_SYMBOLS=1
  export KCONFIG_WARN_CHANGED_INPUT=1

  log "Detectando símbolos nuevos antes de olddefconfig..."
  NEWCONFIG_OUTPUT="$(make "${KCONFIG_CC_OPTS[@]}" listnewconfig 2>&1 || true)"
  if printf '%s\n' "$NEWCONFIG_OUTPUT" | grep -qE '^CONFIG_|^# CONFIG_'; then
    # Con parches/BTF activos, sus símbolos aparecerán aquí como nuevos (los
    # introduce el parche). Son esperados; se auditán en la validación vía
    # EXPECTED_REBEL_SET. Aquí solo se informa si hay OTROS.
    if [ "${#PATCH_KCONFIG_FILTER[@]}" -gt 0 ]; then
      local __fs __name_regex=""
      for __fs in "${!PATCH_KCONFIG_FILTER[@]}"; do
        [ -n "$__name_regex" ] && __name_regex="$__name_regex|"
        __name_regex="$__name_regex$__fs"
      done
      unset __fs
      if printf '%s\n' "$NEWCONFIG_OUTPUT" | grep -vE "CONFIG_($__name_regex)" | grep -qE '^CONFIG_|^# CONFIG_'; then
        warn "Se detectaron símbolos nuevos/pendientes (además de los de parches/BTF)."
      fi
      unset __name_regex
    else
      warn "Se detectaron símbolos nuevos/pendientes."
    fi
  fi

  log "Normalizando con olddefconfig..."
  OLDCONFIG_OUTPUT="$(make "${KCONFIG_CC_OPTS[@]}" olddefconfig 2>&1)" || {
    err "olddefconfig falló."
    printf '%s\n' "$OLDCONFIG_OUTPUT" | tail -80 >&2 || true
    return 1
  }
  load_config_state

  # Diffconfig omitido: el flujo de migración Cizen solo necesita
  # detectar símbolos nuevos con listnewconfig y normalizar con olddefconfig.
}

# ============================================================
# VALIDACIÓN INTELIGENTE
# ============================================================
declare -a ENABLE_FAIL=() CRIT_FAIL=() REBEL_NEW=() RETIRED_DISABLE=() DISABLE_WARN=() HARD_DISABLE_FAIL=() NEW_OPTS=()
validate_config() {
  local opt state x
  local enable_ok=0 critical_ok=0 disable_ok=0 expected_rebels=0
  local setval_ok=0 setstr_ok=0
  local fatal_count=0 warning_count=0

  ENABLE_FAIL=(); CRIT_FAIL=(); REBEL_NEW=(); RETIRED_DISABLE=(); DISABLE_WARN=(); HARD_DISABLE_FAIL=(); NEW_OPTS=()

  log "──── VALIDACIÓN ────"

  # 1) Activaciones normales
  for opt in "${EFF_ENABLE[@]}"; do
    state="$(config_symbol_state "$opt")"
    if [ "$state" = y ] || [ "$state" = m ]; then
      enable_ok=$((enable_ok + 1))
    elif [ "$state" = n ]; then
      ENABLE_FAIL+=("CONFIG_$opt quedó n")
      fatal_count=$((fatal_count + 1))
    else
      ENABLE_FAIL+=("CONFIG_$opt no existe")
      warning_count=$((warning_count + 1))
    fi
  done

  # 2) Críticos: únicos y nunca ignorables con --force
  for opt in "${EFF_CRITICAL[@]}"; do
    state="$(config_symbol_state "$opt")"
    if [ "$state" = y ] || [ "$state" = m ]; then
      critical_ok=$((critical_ok + 1))
    else
      CRIT_FAIL+=("CONFIG_$opt=$state")
      fatal_count=$((fatal_count + 1))
    fi
  done

  # 3) Desactivaciones
  # IMPORTANTE: una desactivación que Kconfig conserva NO es fatal por sí sola.
  # Puede deberse a depends on, select, defaults o símbolos generados por la
  # propia arquitectura. Se informa como WARNING y nunca bloquea la build.
  # Los requisitos funcionales se validan exclusivamente mediante CRITICAL_OPTS.
  for opt in "${EFF_DISABLE[@]}"; do
    state="$(config_symbol_state "$opt")"
    case "$state" in
      n|missing)
        disable_ok=$((disable_ok + 1))
        if [ "$state" = missing ]; then
          RETIRED_DISABLE+=("CONFIG_$opt ya no existe en esta versión")
        fi
        ;;
      y|m)
        if [ -n "${EXPECTED_REBEL_SET[$opt]:-}" ]; then
          expected_rebels=$((expected_rebels + 1))
          REBEL_NEW+=("CONFIG_$opt=$state (dependencia esperada)")
        else
          DISABLE_WARN+=("CONFIG_$opt=$state (Kconfig la conserva; revisar dependencia/default/select)")
          warning_count=$((warning_count + 1))
        fi
        ;;
      *)
        DISABLE_WARN+=("CONFIG_$opt=$state (estado no estándar)")
        warning_count=$((warning_count + 1))
        ;;
    esac
  done

  # 4) SETVAL
  for opt in "${!EFF_SETVAL[@]}"; do
    state="$(config_symbol_state "$opt")"
    if [ "$state" = "${EFF_SETVAL[$opt]}" ]; then
      setval_ok=$((setval_ok + 1))
    else
      HARD_DISABLE_FAIL+=("SETVAL CONFIG_$opt esperado=${EFF_SETVAL[$opt]} real=$state")
      fatal_count=$((fatal_count + 1))
    fi
  done

  # 5) SETSTR (compara la línea exacta para conservar comillas)
  for opt in "${!EFF_SETSTR[@]}"; do
    local expected_line="CONFIG_${opt}=\"${EFF_SETSTR[$opt]}\""
    if grep -Fxq "$expected_line" .config; then
      setstr_ok=$((setstr_ok + 1))
    else
      HARD_DISABLE_FAIL+=("SETSTR CONFIG_$opt esperado=\"${EFF_SETSTR[$opt]}\"")
      fatal_count=$((fatal_count + 1))
    fi
  done

  # 6) Nuevos símbolos: listnewconfig es la referencia oficial de migración.
  if printf '%s\n' "$NEWCONFIG_OUTPUT" | grep -qE '^CONFIG_|^# CONFIG_'; then
    while IFS= read -r line; do
      [[ "$line" =~ ^CONFIG_[A-Z0-9_]+= ]] || [[ "$line" =~ ^#\ CONFIG_[A-Z0-9_]+\ is\ not\ set ]] || continue
      local new_sym=""
      if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)= ]]; then
        new_sym="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
        new_sym="${BASH_REMATCH[1]}"
      else
        continue
      fi
      if [ -n "${EXPECTED_REBEL_SET[$new_sym]:-}" ]; then
        continue
      fi
      NEW_OPTS+=("$line")
    done <<< "$NEWCONFIG_OUTPUT"
    if [ "${#NEW_OPTS[@]}" -gt 0 ]; then
      warning_count=$((warning_count + ${#NEW_OPTS[@]}))
    fi
  fi

  # 7) No se genera reporte persistente: la salida relevante se muestra en consola.
  # Consola
  if [ "$fatal_count" -eq 0 ]; then
    ok "[ENABLE]   $enable_ok/${#EFF_ENABLE[@]} activaciones satisfechas"
    ok "[CRITICAL] $critical_ok/${#EFF_CRITICAL[@]} críticos presentes"
    ok "[DISABLE]  $disable_ok/${#EFF_DISABLE[@]} desactivaciones resueltas ($expected_rebels rebeldes esperados)"
    ok "[SETVAL]   $setval_ok/${#EFF_SETVAL[@]} valores numéricos"
    ok "[SETSTR]   $setstr_ok/${#EFF_SETSTR[@]} valores de texto"
    # v27.31.28: "37/38 activaciones satisfechas" sin decir cuál era una de las
    # cosas que más costó depurar: ahora los que faltan se nombran uno a uno.
    if [ "${#ENABLE_FAIL[@]}" -gt 0 ]; then
      warn "[ENABLE]   ${#ENABLE_FAIL[@]} activación(es) sin satisfacer:"
      for x in "${ENABLE_FAIL[@]}"; do warn "              $x"; done
    fi
    if [ "${#PATCH_VALUE_SYMBOLS[@]}" -gt 0 ]; then
      info "Símbolos de valor que aportan los parches (no booleanos: se deja su default, no se fuerzan a =y): ${PATCH_VALUE_SYMBOLS[*]}"
    fi
  else
    err "Se detectaron $fatal_count fallos FATALES en la configuración."
    for x in "${CRIT_FAIL[@]}"; do err "  [CRÍTICO] $x"; done
    for x in "${ENABLE_FAIL[@]}"; do err "  [ENABLE] $x"; done
  fi

  # Las retenciones ESPERADAS de Kconfig (rebeldes conocidos) son solo
  # informativas. Todo lo demás recopilado abajo es un WARNING real y se
  # imprime con su detalle completo, no solo como conteo, para que --strict
  # (y una lectura humana del log) puedan actuar sobre la causa exacta.

  if [ "${#NEW_OPTS[@]}" -gt 0 ]; then
    warn "Hay ${#NEW_OPTS[@]} símbolos nuevos/pendientes:"
    for x in "${NEW_OPTS[@]}"; do warn "    $x"; done
  fi
  if [ "${#DISABLE_WARN[@]}" -gt 0 ]; then
    warn "Hay ${#DISABLE_WARN[@]} desactivaciones que Kconfig NO resolvió como se esperaba:"
    for x in "${DISABLE_WARN[@]}"; do warn "    $x"; done
  fi

  if [ "${#PATCH_RETIRED_ALL[@]}" -gt 0 ]; then
    info "Símbolos retirados por el scheduler alternativo activo (dependen de !SCHED_ALT; los pidió el perfil pero este kernel no puede habilitarlos):"
    for x in "${PATCH_RETIRED_ALL[@]:-}"; do info "    $x"; done
  fi

  if [ "${#AUTO_RENAMES[@]}" -gt 0 ]; then
    ok "Renombres detectados y aplicados por similarities en el Kconfig de $VERSION:"
    while IFS= read -r opt; do
      printf '    %s → %s\n' "$opt" "${AUTO_RENAMES[$opt]}"
    done < <(printf '%s\n' "${!AUTO_RENAMES[@]}" | sort)
    if [ "$SAVE_AUTO_RENAMES" = true ]; then
      for opt in "${!AUTO_RENAMES[@]}"; do
        do_rename "$opt=${AUTO_RENAMES[$opt]}" >/dev/null
      done
      ok "Renombres guardados en $RENAME_MAP_FILE (--save-auto-renames)."
    else
      info "Solo duran esta ejecución: pasa --save-auto-renames (o añade $0 --rename VIEJO=NUEVO) si quieres recordarlos."
    fi
  fi

  if [ "${#APPLIED_RENAMES[@]}" -gt 0 ]; then
    warn "Renombres aplicados:"
    while IFS= read -r opt; do
      printf '    %s → %s\n' "$opt" "${APPLIED_RENAMES[$opt]}"
    done < <(printf '%s\n' "${!APPLIED_RENAMES[@]}" | sort)
  fi

  # Los fallos críticos y los requisitos explícitos no satisfechos bloquean siempre.
  if [ "${#HARD_DISABLE_FAIL[@]}" -gt 0 ]; then
    for x in "${HARD_DISABLE_FAIL[@]}"; do err "  [CONFIG-FATAL] $x"; done
  fi
  if [ "$fatal_count" -gt 0 ]; then
    err "VALIDACIÓN FATAL: no se permite continuar con --force."
    return 2
  fi

  # --strict convierte warnings de auditoría en error, pero --force NO debe
  # saltarse nunca los fallos críticos. La lógica de críticos está separada.
  if [ "$STRICT" = true ] && [ "$warning_count" -gt 0 ]; then
    err "--strict: warnings presentes; se aborta."
    return 3
  fi

  return 0
}

# ============================================================
# DIFF DE CONFIG vs KERNEL EN EJECUCIÓN  (feature 1)
# ============================================================
# Compara la .config efectiva ya normalizada (CONFIG_STATE) contra la del kernel
# que está arrancado (/proc/config.gz), aplicando los renames del perfil
# (APPLIED_RENAMES) para no marcar como cambio un símbolo renombrado. Solo
# informa; nunca bloquear. Cambiados = presentes en ambos con valor distinto;
# nuevos/retirados = solo en uno de los dos (típicamente por el bump de versión).
report_config_diff() {
  if ! zcat /proc/config.gz >/dev/null 2>&1; then
    warn "No se puede leer la config del kernel en ejecución (/proc/config.gz); se omite el diff."
    return 0
  fi

  local -A inst=()
  local line sym val
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)=(.*)$ ]]; then
      inst["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
      inst["${BASH_REMATCH[1]}"]="n"
    fi
  done < <(zcat /proc/config.gz 2>/dev/null)

  local -a changed=() added=() removed=()
  local oldsym newsym runstate newstate newname

  # Cambiados: el símbolo existe en el kernel en ejecución y el perfil lo cambió.
  # Si el perfil renombró el símbolo (APPLIED_RENAMES[old]=new), se compara el
  # valor de inst[old] contra CONFIG_STATE[new] y no se reporta si coinciden.
  for oldsym in "${!inst[@]}"; do
    runstate="${inst[$oldsym]}"
    [ -n "${CONFIG_STATE[$oldsym]+x}" ] || continue
    newname="${APPLIED_RENAMES[$oldsym]:-}"
    if [ -n "$newname" ] && [ -n "${CONFIG_STATE[$newname]+x}" ]; then
      [ "${CONFIG_STATE[$newname]}" = "$runstate" ] && continue
    fi
    if [ "${CONFIG_STATE[$oldsym]}" != "$runstate" ]; then
      changed+=("CONFIG_$oldsym $runstate → ${CONFIG_STATE[$oldsym]}")
    fi
  done

  # "nuevos": en la config nueva pero ausentes en el kernel en ejecución.
  for sym in "${!CONFIG_STATE[@]}"; do
    [ -n "${inst[$sym]+x}" ] || added+=("CONFIG_$sym")
  done
  # "retirados": presentes en el kernel en ejecución pero ausentes en la nueva.
  for sym in "${!inst[@]}"; do
    [ -n "${CONFIG_STATE[$sym]+x}" ] || removed+=("CONFIG_$sym")
  done

  ok "Diff vs kernel en ejecución: ${#changed[@]} cambiados / ${#added[@]} nuevos / ${#removed[@]} retirados"
  if [ "${#changed[@]}" -gt 0 ]; then
    info "Cambios de config (máx. 15):"
    local i=0 c
    for c in "${changed[@]}"; do
      if [ "$i" -ge 15 ]; then
        info "  … y $(( ${#changed[@]} - 15 )) más"
        break
      fi
      printf '    %s\n' "$c"
      i=$((i + 1))
    done
  fi
  return 0
}

# ============================================================
# ABSORCIÓN DE REBELDES EN EL PERFIL  (--absorb-rebels)
# ============================================================
# Cuando una desactivación de OPTS_DISABLE es conservada por Kconfig a =y/=m
# por dependencias internas (depends on/select/defaults), la revalidación la
# reporta una y otra vez como WARNING. --absorb-rebels mueve esos símbolos de
# OPTS_DISABLE a EXPECTED_REBELS en el archivo de perfil (con backup), de modo
# que en futuras ejecuciones cuenten como rebeldes esperados y el chequeo quede
# limpio. La decisión de conservar el símbolo es de Kconfig, no nuestra: solo
# se absorbe lo que la validación ya demostró que no se puede desactivar.
absorb_rebels_to_profile() {
  local symline sym
  local -a absorb=()

  # DISABLE_WARN son líneas "CONFIG_X=estado (Kconfig la conserva...)".
  # Extraemos el nombre integro del símbolo (la parte antes del primer '=').
  for symline in "${DISABLE_WARN[@]}"; do
    sym="${symline%%=*}"
    sym="${sym#CONFIG_}"
    [ -n "$sym" ] && absorb+=("$sym")
  done

  if [ "${#absorb[@]}" -eq 0 ]; then
    info "--absorb-rebels: no hay desactivaciones conservadas que mover."
    return 0
  fi

  log "Absorbiendo ${#absorb[@]} símbolos conservados por Kconfig a EXPECTED_REBELS..."
  for symline in "${absorb[@]}"; do
    info "  → $symline"
  done

  # Los símbolos absorbidos deben borrarse de OPTS_DISABLE en el array de
  # UNO en UNO porque pueden compartir línea literal con otros símbolos
  # (p.ej. `"A" "B" "C"`); borrar la línea entera eliminaría vecinos legítimos.
  # Estructura del perfil: declare -a OPTS_DISABLE=( ... ) y
  # declare -a EXPECTED_REBELS=( ... ). Este awk edita ambas secciones.
  local awk_prog='
    BEGIN {
      n = split(AWS, S, " ")
      for (i = 1; i <= n; i++) q[i] = "\"" S[i] "\""
      for (i = 1; i <= n; i++) still_absent[i] = 1
      in_disable = 0
      in_rebels = 0
    }
    /^declare -a OPTS_DISABLE=\(/ { in_disable = 1; print; next }
    in_disable && /^\)/ { in_disable = 0; print; next }
    /^declare -a EXPECTED_REBELS=\(/ { in_rebels = 1; print; next }
    in_rebels && /^\)/ {
      to_add = 0
      for (i = 1; i <= n; i++)
        if (still_absent[i]) to_add = 1
      if (to_add) print "# Absorbidos por --absorb-rebels: Kconfig los conserva por dependencia."
      for (i = 1; i <= n; i++)
        if (still_absent[i]) print q[i]
      if (to_add) print "# ---"
      print
      in_rebels = 0
      next
    }
    in_disable {
      line = $0
      if (line ~ /^[[:space:]]*#/) { print line; next }
      for (i = 1; i <= n; i++) {
        while (line ~ ("^[[:space:]]*" q[i]))
          sub("^[[:space:]]*" q[i], "", line)
        while (line ~ (q[i] "[[:space:]]*"))
          sub(q[i] "[[:space:]]*", "", line)
      }
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      if (line != "") print line
      next
    }
    in_rebels {
      for (i = 1; i <= n; i++)
        if (index($0, q[i]) > 0) still_absent[i] = 0
      print
      next
    }
    { print }
  '
  local syms tmpfile backup
  syms="${absorb[*]}"
  tmpfile="$(mktemp "${PROFILE_FILE}.XXXXXX")" || return 1

  if ! awk -v AWS="$syms" "$awk_prog" "$PROFILE_FILE" > "$tmpfile"; then
    rm -f "$tmpfile"
    err "Fallo al reescribir el perfil (awk)."
    return 1
  fi

  if ! bash -n "$tmpfile"; then
    rm -f "$tmpfile"
    err "El perfil reescrito no es Bash válido; se conserva el original."
    return 1
  fi

  touch "$tmpfile"
  # Backup con timestamp antes de sustituir.
  backup="${PROFILE_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
  if ! cp -a -- "$PROFILE_FILE" "$backup"; then
    rm -f "$tmpfile"
    err "No se pudo crear backup del perfil en $backup"
    return 1
  fi

  if ! mv -f -- "$tmpfile" "$PROFILE_FILE"; then
    rm -f "$tmpfile" "$backup"
    err "No se pudo sustituir el perfil (mv)."
    return 1
  fi

  ok "Perfil actualizado: ${#absorb[@]} símbolos movidos de OPTS_DISABLE a EXPECTED_REBELS."
  info "Backup del perfil previo: $backup"
  info "Revísalo si el cambio te resulta inesperado (los símbolos son los que Kconfig conserva de forma efectiva)."
  return 0
}

# ============================================================
# REPRODUCIBILIDAD / PACKAGE DISCOVERY
# ============================================================
# El nombre del kernel uname -r sigue siendo VERSION-cizen-v3. El nombre de
# paquete Arch es linux-cizen-v3 y es deliberadamente distinto: mkinitcpio
# toma pkgbase del paquete para usar linux-cizen-v3.preset.

verify_build_tree() {
  [ -f .config ] || fatal "No existe .config antes de compilar."
  [ "$(make -s kernelversion)" = "$VERSION" ] || fatal "La versión del árbol no coincide con $VERSION."

  # Estos cuatro símbolos deben quedar compilados DIRECTAMENTE en el kernel
  # (=y, nunca módulo) porque el arranque de este equipo depende de una UKI
  # sin initramfs: no hay forma de cargar un módulo antes de tener KMS
  # temprano ni de montar la raíz Btrfs. Se resuelven con resolve_symbol()
  # igual que el resto del perfil, para que un renombre futuro de Kconfig
  # (registrado con --rename) se aplique aquí también en vez de producir un
  # fatal sin explicación.
  local -a boot_critical=(X86_NATIVE_CPU BTRFS_FS DRM_I915 KVM_SMM)
  local sym resolved state
  for sym in "${boot_critical[@]}"; do
    resolved="$(resolve_symbol "$sym")"
    state="$(config_symbol_state "$resolved")"
    if [ "$state" != y ]; then
      fatal "Falta CONFIG_${resolved}=y (crítico para el arranque sin initramfs de este equipo; estado actual: $state)"
    fi
  done
}

prepare_package_identity_override() {
  local pkgbuilder="$SRC/scripts/package/PKGBUILD"
  local backup="${pkgbuilder}.cizen-orig"

  [ -f "$pkgbuilder" ] || fatal "No existe $pkgbuilder; no se puede fijar el pkgbase Cizen."

  # El PKGBUILD oficial usa PACMAN_PKGBASE cuando está disponible. Lo forzamos
  # al nombre Cizen para que el paquete generado se llame linux-cizen-v3 y,
  # sobre todo, para que el archivo /usr/lib/modules/<release>/pkgbase contenga
  # linux-cizen-v3; mkinitcpio utiliza ese valor para resolver el preset.
  # Si una ejecución anterior murió sin alcanzar EXIT (por ejemplo, corte
  # de energía o SIGKILL), recuperamos primero la receta original conservada.
  if [ -f "$backup" ]; then
    mv -f -- "$backup" "$pkgbuilder"
  fi
  cp -f -- "$pkgbuilder" "$backup"

  if ! grep -Fq 'PACMAN_PKGBASE' "$pkgbuilder"; then
    fatal "El PKGBUILD no expone el selector PACMAN_PKGBASE esperado; se aborta para no parchear una receta incompatible."
  fi
  if ! grep -Fq 'eval "package_' "$pkgbuilder" && ! grep -Fq 'package_${pkgbase}' "$pkgbuilder"; then
    fatal "El PKGBUILD no genera dinámicamente las funciones package_*; no se puede cambiar pkgbase con seguridad en este árbol."
  fi

  # Añadimos metadata temporal de transición SOLO dentro de la función
  # _package() del paquete principal. El PKGBUILD oficial genera luego las
  # funciones package_${pkgname}() dinámicamente: así conflicts/replaces/provides
  # se aplican a linux-cizen-v3, pero NO se heredan a -headers/-api-headers/-debug.
  # No se modifica permanentemente el árbol de fuentes: restore_* lo revierte.
  if ! grep -Fq "conflicts=(\"$LEGACY_PKGBASE\")" "$pkgbuilder"; then
    local pkgtmp
    pkgtmp="${pkgbuilder}.cizen-meta-${TS}"
    awk -v legacy="$LEGACY_PKGBASE" '
      BEGIN { inserted=0 }
      /^_package[[:space:]]*\(\)[[:space:]]*\{/ && !inserted {
        print
        printf "\tconflicts=(\"%s\")\n", legacy
        printf "\treplaces=(\"%s\")\n", legacy
        printf "\tprovides=(\"%s\")\n", legacy
        inserted=1
        next
      }
      { print }
    ' "$pkgbuilder" > "$pkgtmp" || { rm -f -- "$pkgtmp"; fatal "No se pudo preparar el PKGBUILD Cizen para la transición de paquete."; }
    chmod --reference="$pkgbuilder" "$pkgtmp" 2>/dev/null || true
    mv -f -- "$pkgtmp" "$pkgbuilder" || { rm -f -- "$pkgtmp"; fatal "No se pudo activar el PKGBUILD Cizen temporal."; }
  fi

  # El selector de pkgbase debe existir y la función principal donde se inyecta
  # la metadata debe seguir presente; si no, no aceptamos una receta incompatible.
  grep -Eq '^_package[[:space:]]*\(\)[[:space:]]*\{' "$pkgbuilder" || \
    fatal "El PKGBUILD no contiene la función _package() esperada; no se puede fijar metadata de transición de forma segura."

  ok "pkgbase Cizen configurado: $CIZEN_PKGBASE (reemplaza $LEGACY_PKGBASE si está instalado)"
}

restore_package_identity_override() {
  local pkgbuilder="$SRC/scripts/package/PKGBUILD"
  local backup="${pkgbuilder}.cizen-orig"

  if [ -f "$backup" ]; then
    mv -f -- "$backup" "$pkgbuilder"
  fi
}

prepare_package_revision_override() {
  local makefile="$SRC/scripts/Makefile.package"
  local backup="${makefile}.cizen-orig"

  [ -f "$makefile" ] || fatal "No existe $makefile; no se puede fijar el pkgrel."

  # scripts/Makefile.package fuerza actualmente KBUILD_REVISION a la salida
  # de scripts/build-version dentro de la receta pacman-pkg. Eso sobrescribe
  # el valor que pasamos desde el shell. Para que el pkgrel calculado por
  # este script sea realmente el que usa makepkg, sustituimos únicamente esa
  # asignación por la variable Kbuild ya calculada.
  if grep -Fq 'KBUILD_REVISION="$(shell $(srctree)/scripts/build-version)"' "$makefile"; then
    cp -f -- "$makefile" "$backup"
    sed -i \
      's@KBUILD_REVISION="$(shell $(srctree)/scripts/build-version)"@KBUILD_REVISION="$(KBUILD_REVISION)"@' \
      "$makefile"
  fi

  if ! grep -Fq 'KBUILD_REVISION="$(KBUILD_REVISION)"' "$makefile"; then
    fatal "No se pudo aplicar el override de KBUILD_REVISION en Makefile.package."
  fi

  ok "Override de pkgrel activo: KBUILD_REVISION=$PKGREL"
}

restore_package_revision_override() {
  local makefile="$SRC/scripts/Makefile.package"
  local backup="${makefile}.cizen-orig"

  if [ -f "$backup" ]; then
    mv -f -- "$backup" "$makefile"
    ok "Makefile.package original restaurado"
  fi
}

prepare_package_pruning_override() {
  local pkgbuilder="$SRC/scripts/package/PKGBUILD"

  [ -f "$pkgbuilder" ] || fatal "No existe $pkgbuilder; no se puede activar la poda de módulos."

  # La poda es opt-in robusta: sin podador ejecutable no se falla, se omite.
  if [ ! -x "$PRUNER_SCRIPT" ]; then
    if [ "$PRUNE_MODULES" = "1" ]; then
      warn "Podador de módulos no encontrado/ejecutable ($PRUNER_SCRIPT); se compila SIN poda."
      PRUNE_MODULES=0
    fi
    return 0
  fi
  [ "$PRUNE_MODULES" = "1" ] || return 0

  # Añadimos la invocación SOLO dentro de _package(): tras el modules_install
  # (que deja el árbol completo en ${modulesdir}). Depende de variables de
  # entorno exportadas por este motor antes de `make pacman-pkg`; makepkg las
  # hereda al fakeroot que ejecuta package(). Guardas: si el podador falla o
  # no está, `|| true` conserva el conjunto completo (nunca rompe la build).
  # restore_package_identity_override() revierte esta modificación con el
  # respaldo .cizen-orig; no necesita backup propio.
  if ! grep -Fq 'modules_install' "$pkgbuilder"; then
    fatal "El PKGBUILD no contiene modules_install; no se puede inyectar la poda de módulos."
  fi
  if ! grep -Fq 'CIZEN_PRUNE_MODULES' "$pkgbuilder"; then
    local pkgtmp
    pkgtmp="${pkgbuilder}.cizen-prune-${TS}"
    awk '
      BEGIN { inserted=0 }
      /modules_install/ && !inserted {
        print
        printf "\tif [ \"${CIZEN_PRUNE_MODULES:-0}\" = \"1\" ] && [ -n \"${CIZEN_PRUNE_SCRIPT:-}\" ] && [ -x \"${CIZEN_PRUNE_SCRIPT}\" ]; then\n"
        printf "\t\t\"${CIZEN_PRUNE_SCRIPT}\" \"${modulesdir}\" \"${CIZEN_KEEP_MODULES:-}\" || true\n"
        printf "\tfi\n"
        inserted=1
        next
      }
      { print }
    ' "$pkgbuilder" > "$pkgtmp" || { rm -f -- "$pkgtmp"; fatal "No se pudo inyectar la poda de módulos en el PKGBUILD."; }
    chmod --reference="$pkgbuilder" "$pkgtmp" 2>/dev/null || true
    mv -f -- "$pkgtmp" "$pkgbuilder" || { rm -f -- "$pkgtmp"; fatal "No se pudo activar el PKGBUILD con poda de módulos."; }
  fi

  ok "Poda de módulos activa: $PRUNER_SCRIPT (CIZEN_KEEP_MODULES=${CIZEN_KEEP_MODULES:--})"
}

restore_package_pruning_override() {
  # La poda vive dentro del PKGBUILD parcheado por prepare_package_identity_override;
  # restaurarlo también la elimina. Sin embargo, si una ejecución previa dejó el
  # backup sin alcanzar EXIT (SIGKILL/catástrofe), el flujo normal de
  # restore_package_identity_override lo recupera igual; nada que hacer aquí.
  :
}

determine_pkgrel() {
  local pattern file base rel max_rel=0 installed_ver installed_rel

  PKGVER_BASE="${VERSION}${LOCALVERSION_SUFFIX}"
  PKGVER_BASE="${PKGVER_BASE//-/_}"
  pattern="${CIZEN_PKGBASE}-${PKGVER_BASE}-*-x86_64.pkg.tar.zst"

  # El pkgrel del paquete Arch debe crecer en cada recompilación de la misma
  # versión del kernel. Los paquetes de builds anteriores permanecen dentro
  # del único árbol de fuentes conservado en el tmpfs y también sirven como
  # referencia para incrementar el pkgrel.
  shopt -s nullglob
  for file in "$SRC"/$pattern; do
    base="$(basename "$file")"
    if [[ "$base" =~ ^${CIZEN_PKGBASE}-${PKGVER_BASE}-([0-9]+)-x86_64\.pkg\.tar\.zst$ ]]; then
      rel="${BASH_REMATCH[1]}"
      if (( rel > max_rel )); then
        max_rel="$rel"
      fi
    fi
  done
  shopt -u nullglob

  if pacman -Q "$CIZEN_PKGBASE" >/dev/null 2>&1; then
    installed_ver="$(pacman -Q "$CIZEN_PKGBASE" | awk 'NR==1 {print $2}')"
    if [[ "$installed_ver" =~ ^${PKGVER_BASE}-([0-9]+)$ ]]; then
      installed_rel="${BASH_REMATCH[1]}"
      if (( installed_rel > max_rel )); then
        max_rel="$installed_rel"
      fi
    fi
  fi

  PKGREL=$((max_rel + 1))
  [ "$PKGREL" -ge 1 ] || fatal "pkgrel calculado inválido: $PKGREL"

  log "pkgver objetivo: $PKGVER_BASE"
  log "pkgrel siguiente: $PKGREL"
}

copy_packages_from_build() {
  local -a generated=() pkgs=() pkg
  local main_pkg="" pkg_meta

  # No confiamos en el orden de `ls` ni en el espaciado de `pacman -Qip`.
  # El paquete se identifica primero por el nombre de archivo generado por
  # kbuild, igual que el script original, y después se valida con pacman.
  mapfile -t generated < <(find "$SRC" -maxdepth 1 -type f -name '*.pkg.tar.zst' -newer "$BUILD_MARKER" \
    -print | sort -V)

  for pkg in "${generated[@]}"; do
    case "$(basename "$pkg")" in
      *debug*|*headers*) continue ;;
    esac
    case "$(basename "$pkg")" in
      ${CIZEN_PKGBASE}-*[cC]izen_v3-*.pkg.tar.zst|${CIZEN_PKGBASE}-[0-9]*.pkg.tar.zst) pkgs+=("$pkg") ;;
    esac
  done

  if [ "${#pkgs[@]}" -eq 0 ]; then
    err "No se encontró el paquete principal ${CIZEN_PKGBASE} *cizen_v3 generado por esta build."
    if [ "${#generated[@]}" -gt 0 ]; then
      warn "Artefactos pkg.tar.zst encontrados en la build:"
      for pkg in "${generated[@]}"; do printf '    %s\n' "$(basename "$pkg")"; done
    fi
    return 1
  fi

  log "Paquete(s) kernel elegibles generados en esta build:"
  for pkg in "${pkgs[@]}"; do
    printf '    %s\n' "$(basename "$pkg")"
  done

  if [ "${#pkgs[@]}" -gt 1 ]; then
    warn "Se generaron ${#pkgs[@]} paquetes principales; se selecciona el último por versión."
  fi
  main_pkg="$(printf '%s\n' "${pkgs[@]}" | sort -V | tail -n1)"

  [ -s "$main_pkg" ] || { err "El paquete seleccionado está vacío: $main_pkg"; return 1; }

  # El paquete se instala directamente desde el mismo árbol tmpfs de la build.
  # No se mantiene una segunda copia persistente en $HOME.
  PKG="$main_pkg"
  [ -s "$PKG" ] || { err "El paquete generado no existe o está vacío: $PKG"; return 1; }

  # Validamos la metadata interna del archivo .pkg.tar.zst directamente.
  # Esto evita depender del formato/semántica de salida de `pacman -Qp`.
  # .PKGINFO es parte del formato del paquete Arch y contiene pkgname/pkgver.
  pkg_meta="$(tar -xOf "$PKG" .PKGINFO 2>/dev/null || true)"
  PKG_NAME="$(printf '%s\n' "$pkg_meta" | sed -n 's/^pkgname = //p' | head -n1)"
  PKG_VERSION="$(printf '%s\n' "$pkg_meta" | sed -n 's/^pkgver = //p' | head -n1)"

  if [ -z "$PKG_NAME" ] || [ -z "$PKG_VERSION" ]; then
    err "No se pudo leer pkgname/pkgver desde .PKGINFO de $(basename "$PKG")."
    return 1
  fi

  if [[ "$PKG_NAME" != "$CIZEN_PKGBASE" ]]; then
    err "Paquete inesperado según .PKGINFO: $PKG_NAME (se esperaba $CIZEN_PKGBASE)."
    return 1
  fi

  # PKG_VERSION del .PKGINFO trae el pkgver real con su pkgrel (p. ej. 7.2.7-1,
  # NO "7.2.7_cizen_v3": esa derivación está en PKGVER_BASE pero la plantilla
  # genera el pkgver desde KERNELRELEASE sin el sufijo). Se valida contra la
  # metadata interna (fuente de verdad), no contra el nombre derivado por el motor.
  if [[ "$(basename "$PKG")" != "${CIZEN_PKGBASE}-${PKG_VERSION}-x86_64.pkg.tar.zst" ]]; then
    err "El nombre del paquete ($(basename "$PKG")) no coincide con pkgname+pkgver del .PKGINFO."
    return 1
  fi
  if [[ "${PKG_VERSION##*-}" != "$PKGREL" ]]; then
    err "El pkgrel interno del paquete ($PKG_VERSION) no coincide con el esperado ($PKGREL)."
    return 1
  fi

  ok "Paquete verificado: $(basename "$PKG") ($PKG_NAME $PKG_VERSION)"
}

# v27.30.0: detecta el artefacto generado segun el backend. Para arch fija
# PKG/PKG_NAME/PKG_VERSION con copy_packages_from_build (metadatos .PKGINFO);
# para el resto localiza el artefacto nativo (o deja PKG vacío en los
# backends sin paquete, que instalan directo desde el árbol).
collect_build_artifact() {
  local newest f
  case "$CIZEN_PKG_BACKEND" in
    arch)
      copy_packages_from_build || return 1
      ;;
    deb)
      newest=""
      while IFS= read -r -d '' f; do newest="$f"; done < <(
        find "$TMPFS_ROOT" -maxdepth 2 -type f \( -name 'linux-image-*.deb' -o -name 'linux-*.deb' \) -print0 2>/dev/null || true)
      if [ -z "$newest" ]; then
        err "No se encontró ningún .deb tras make deb-pkg en $TMPFS_ROOT."
        return 1
      fi
      PKG="$newest"; PKG_NAME="linux-image-cizen"; PKG_VERSION="$VERSION-cizen-v3"
      ok "Artefacto .deb detectado: $(basename "$PKG")"
      ;;
    rpm)
      newest=""
      while IFS= read -r -d '' f; do newest="$f"; done < <(
        find "$TMPFS_ROOT" -maxdepth 2 -type f -name 'linux-*.rpm' -print0 2>/dev/null || true)
      if [ -z "$newest" ]; then
        err "No se encontró ningún .rpm tras make rpm-pkg en $TMPFS_ROOT."
        return 1
      fi
      PKG="$newest"; PKG_NAME="linux-cizen"; PKG_VERSION="$VERSION-cizen-v3"
      ok "Artefacto .rpm detectado: $(basename "$PKG")"
      ;;
    generic|gentoo)
      PKG=""
      PKG_NAME="linux-cizen-v3"
      PKG_VERSION="$VERSION-cizen-v3"
      ok "Backend $CIZEN_PKG_BACKEND: sin paquete; se instala desde el árbol (modules_install + vmlinuz)."
      ;;
  esac
  [ -n "$PKG" ] || [ "$CIZEN_PKG_BACKEND" = "generic" ] || [ "$CIZEN_PKG_BACKEND" = "gentoo" ]
}

validate_split_package_transition_metadata() {
  local item base meta field value
  [ -d "$SRC" ] || return 0
  shopt -s nullglob
  for item in "$SRC"/*.pkg.tar.zst; do
    [ -f "$item" ] || continue
    [ -n "${BUILD_MARKER:-}" ] && [ -f "$BUILD_MARKER" ] && [ "$item" -nt "$BUILD_MARKER" ] || continue
    base="$(basename -- "$item")"
    case "$base" in
      *-headers-*.pkg.tar.zst|*-api-headers-*.pkg.tar.zst|*-debug-*.pkg.tar.zst) ;;
      *) continue ;;
    esac

    meta="$(tar -xOf "$item" .PKGINFO 2>/dev/null || true)"
    for field in conflict replace provides; do
      value="$(printf '%s\n' "$meta" | sed -n "s/^${field} = //p" || true)"
      if printf '%s\n' "$value" | grep -Fxq "$LEGACY_PKGBASE"; then
        shopt -u nullglob
        fatal "Metadata de transición filtrada al subpaquete $(basename -- "$item"): ${field}=$LEGACY_PKGBASE. La metadata debe pertenecer únicamente al paquete principal $CIZEN_PKGBASE."
      fi
    done
  done
  shopt -u nullglob
}

# El árbol de fuentes se conserva a propósito entre ejecuciones (ver
# unmount_tmpfs_build), pero eso significa que cada recompilación de la
# MISMA versión (probando el perfil, ajustando pkgrel, etc.) dejaba atrás
# los .pkg.tar.zst de builds anteriores sin que nada los limpiara jamás,
# compitiendo por el espacio de un tmpfs de tamaño fijo. Tras una
# instalación exitosa, pacman ya es la fuente de verdad para el pkgrel
# instalado (determine_pkgrel también consulta `pacman -Q`), así que es
# seguro podar aquí los pkgrel anteriores de esta misma versión.
prune_stale_packages() {
  local item base
  [ -d "$SRC" ] || return 0
  shopt -s nullglob
  for item in "$SRC"/"${CIZEN_PKGBASE}"*-"${PKGVER_BASE}"-*-x86_64.pkg.tar.zst; do
    base="$(basename -- "$item")"
    case "$base" in
      *"-${PKGVER_BASE}-${PKGREL}-x86_64.pkg.tar.zst") continue ;;
    esac
    rm -f -- "$item"
    log "Paquete de un pkgrel anterior eliminado del tmpfs: $base"
  done
  shopt -u nullglob
}

# ============================================================
# ROLLBACK DUAL-KERNEL  (feature 3)
# ============================================================
# Antes de instalar una versión nueva se archiva el kernel EN EJECUCIÓN
# (sus módulos + /boot/vmlinuz-linux-cizen-v3 + cmdline) en $ROLLBACK_DIR.
# kernel-update-rollback.sh (krollback) lo restaura y regenera la UKI.
# Solo se conserva el ÚLTIMO archive (el kernel previo al actual); los más
# antiguos se podan para mantener "actual + previo".
SNAPSHOT_DESC=""

# --- manifiesto del rollback ---------------------------------------------
# Un archive de rollback sin saber QUÉ kernel contiene no sirve: bore y bmq
# comparten release (`7.2.7-cizen-v3`), así que la release no identifica al
# build. El manifiesto ata cada artefacto a su pkgbase+pkgver+scheduler.
installed_pkgver() {
  pacman -Q "$CIZEN_PKGBASE" 2>/dev/null | awk '{print $2}' | head -n1
}

rollback_manifest_field() {
  local key="$1" line
  [ -f "$ROLLBACK_MANIFEST" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done < <(sudo cat -- "$ROLLBACK_MANIFEST" 2>/dev/null || cat -- "$ROLLBACK_MANIFEST" 2>/dev/null)
  return 0
}

rollback_manifest_set() {
  local key="$1" value="$2" tmp line
  [ -n "$value" ] || return 0
  sudo mkdir -p -- "$ROLLBACK_DIR" 2>/dev/null || return 0
  tmp="$ROLLBACK_DIR/.rollback.info.$$.tmp"
  {
    if [ -f "$ROLLBACK_MANIFEST" ]; then
      sudo cat -- "$ROLLBACK_MANIFEST" 2>/dev/null |
        while IFS= read -r line; do
          case "$line" in
            "$key="*) printf '%s=%s\n' "$key" "$value" ;;
            *) printf '%s\n' "$line" ;;
          esac
        done
    fi
    # Si la clave no estaba (o no había manifiesto), se añade al final.
    if ! { [ -f "$ROLLBACK_MANIFEST" ] &&
        sudo cat -- "$ROLLBACK_MANIFEST" 2>/dev/null | grep -q "^${key}="; }; then
      printf '%s=%s\n' "$key" "$value"
    fi
  } | sudo tee "$tmp" >/dev/null 2>&1 || { sudo rm -f -- "$tmp" 2>/dev/null; return 1; }
  sudo mv -f -- "$tmp" "$ROLLBACK_MANIFEST" 2>/dev/null || {
    sudo rm -f -- "$tmp" 2>/dev/null; return 1; }
  return 0
}

# ¿El archive de esta release es realmente el del kernel INSTALADO ahora?
# Sin esta comprobación, un archive de la misma release pero de otro pkgrel (otro
# scheduler) se daba por bueno: era un "rollback" a un kernel que ya no era el
# anterior, y se descubría al usarlo.
rollback_manifest_matches() {
  local rel="$1" recorded installed
  recorded="$(rollback_manifest_field pkgver)"
  [ -n "$recorded" ] || return 1     # manifiesto legado o ausente: se rehace
  installed="$(installed_pkgver)"
  [ -n "$installed" ] || return 1
  [ "$recorded" = "$installed" ]
}

# --- paquete de rollback: el que se puede REINSTALAR -----------------------
# Un archive de ficheros no es un rollback de verdad: pacman sigue diciendo que
# está instalado el kernel nuevo, y la próxima actualización vuelve a perder el
# anterior. Con `CleanMethod=KeepCurrent`, además, pacman borra de su caché el
# paquete anterior al instalar el nuevo, así que el .pkg.tar.zst solo existe
# mientras dura la build (y la build vive en un tmpfs que se desmonta al
# terminar). Por eso el motor guarda SU PROPIA copia del paquete que acaba de
# instalar: es el único "anterior" que queda en el host.
preserve_rollback_package() {
  local pkgver tmp name size keep item
  [ "$ROLLBACK_PKG_ENABLED" = "1" ] || { info "Preservación del paquete de rollback desactivada (CIZEN_ROLLBACK_PKG=0)."; return 0; }
  [ -n "$PKG" ] && [ -s "$PKG" ] || { warn "No hay paquete que preservar para rollback ($PKG)."; return 0; }
  [ -d "$ROLLBACK_DIR" ] || sudo mkdir -p -- "$ROLLBACK_DIR" 2>/dev/null || {
    warn "No se pudo crear $ROLLBACK_DIR; el paquete NO queda preservado para rollback."; return 0; }

  name="$(basename -- "$PKG")"
  pkgver="$PKG_VERSION"
  [ -n "$pkgver" ] || pkgver="$(installed_pkgver)"
  [ -n "$pkgver" ] || { warn "No se pudo leer la versión del paquete; no se preserva para rollback."; return 0; }

  # Se copia a un temporal en el MISMO directorio y se renombra: si se interrumpe
  # a mitad, no queda un .pkg.tar.zst truncado que pacman instalaría unhappy.
  tmp="$ROLLBACK_DIR/.pkg-$$.tmp"
  sudo rm -f -- "$tmp" 2>/dev/null
  if ! sudo cp -f -- "$PKG" "$tmp" 2>/dev/null; then
    sudo rm -f -- "$tmp" 2>/dev/null
    warn "No se pudo copiar el paquete a $ROLLBACK_DIR; el kernel anterior NO quedará disponible para rollback."
    return 0
  fi
  sudo mv -f -- "$tmp" "$ROLLBACK_DIR/$name" 2>/dev/null || {
    sudo rm -f -- "$tmp" 2>/dev/null
    warn "No se pudo dejar el paquete preservado en $ROLLBACK_DIR/$name."; return 0; }

  rollback_manifest_set pkgbase "$CIZEN_PKGBASE"
  rollback_manifest_set pkgver "$pkgver"
  rollback_manifest_set release "${VERSION}${LOCALVERSION_SUFFIX}"
  rollback_manifest_set sched "$(effective_scheduler)"
  rollback_manifest_set pkgfile "$name"
  rollback_manifest_set ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # El archive (si lo hay) describes OTRO momento del mismo kernel en marcha; se
  # desvincula para que el manifiesto no lo presente como parte de este paquete.
  [ -f "$ROLLBACK_DIR/${VERSION}${LOCALVERSION_SUFFIX}.tar.xz" ] ||
    rollback_manifest_set archive ""

  # Solo se conserva el ÚLTIMO paquete: "actual + previo". Los anteriores se van
  # (cada uno son ~100 MB y volver a ellos casi nunca es lo que se quiere). La
  # firma .sig se va con su paquete: una firma sin paquete no sirve para nada y
  # ocupa lo mismo.
  shopt -s nullglob
  for item in "$ROLLBACK_DIR"/*.pkg.tar.zst "$ROLLBACK_DIR"/*.pkg.tar.zst.sig; do
    keep="$(basename -- "$item")"
    case "$keep" in
      "$name"|"$name.sig") continue ;;
    esac
    log "Pruning paquete de rollback antiguo: $keep"
    sudo rm -f -- "$item" 2>/dev/null || true
  done
  shopt -u nullglob

  size="$(sudo du -h -- "$ROLLBACK_DIR/$name" 2>/dev/null | cut -f1)"
  ROLLBACK_PKG_FILE="$ROLLBACK_DIR/$name"
  ok "Paquete de rollback preservado: $name${size:+ ($size)}, $CIZEN_PKGBASE-$pkgver [$(effective_scheduler)]"
  info "Si este kernel no arranca, se reinstala el anterior con:"
  info "  sudo $KROLLBACK_SCRIPT --list   # ver cuál es"
  info "  sudo $KROLLBACK_SCRIPT          # reinstalarlo y regenerar el UKI"
  return 0
}
prepare_rollback_archive() {
  local rel modules vmlinuz tmp
  rel="$(uname -r 2>/dev/null || true)"
  [ -n "$rel" ] || { warn "No se puede leer uname -r; no se guarda archive de rollback."; return 0; }
  # El archive se nombra por release, pero el release NO identifica al build:
  # bore y bmq comparten `7.2.7-cizen-v3` (solo cambia el pkgrel), así que un
  # archive de la misma release puede ser de OTRO scheduler. Se conserva solo si
  # el manifiesto dice que es el mismo paquete; si no, se rehace.
  if [ -f "$ROLLBACK_DIR/$rel.tar.xz" ] && rollback_manifest_matches "$rel"; then
    info "Rollback ya existe para $rel ($(rollback_manifest_field pkgver)); se conserva."
    prune_rollback_archives
    return 0
  fi

  modules="/usr/lib/modules/$rel"
  vmlinuz="/boot/vmlinuz-linux-cizen-v3"
  [ -d "$modules" ] && [ -s "$modules/vmlinuz" ] && vmlinuz="$modules/vmlinuz"
  [ -d "$modules" ] || { warn "No hay módulos para $rel ($modules); rollback omitido."; return 0; }

  if ! sudo mkdir -p -- "$ROLLBACK_DIR" 2>/dev/null; then
    warn "No se pudo crear $ROLLBACK_DIR; rollback omitido."
    return 0
  fi

  tmp="$ROLLBACK_DIR/.archive-$$.tmp"
  sudo rm -f -- "$tmp" 2>/dev/null
  local -a uki_paths=()
  while IFS= read -r f; do
    [ -n "$f" ] && uki_paths+=("${f#/}")
  done < <(sudo find /efi /boot/efi /boot -maxdepth 5 -type f -name 'arch-linux-cizen-v3*.efi' 2>/dev/null || true)
  if sudo tar --xz -cf "$tmp" -C / \
       "usr/lib/modules/$rel" \
       "boot/vmlinuz-linux-cizen-v3" \
       "${uki_paths[@]}" 2>/dev/null; then
    if [ -s "$tmp" ]; then
      sudo mv -f -- "$tmp" "$ROLLBACK_DIR/$rel.tar.xz" 2>/dev/null || {
        sudo rm -f -- "$tmp" 2>/dev/null
        warn "No se pudo mover el archive de rollback a $ROLLBACK_DIR/$rel.tar.xz."
        return 0
      }
      printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | sudo tee "$ROLLBACK_DIR/$rel.timestamp" >/dev/null 2>&1 || true
      VERIFY_ROLLBACK_FILE="$ROLLBACK_DIR/$rel.tar.xz"
      # El manifiesto ata el archive al paquete del que salió. Sin esto no se
      # puede distinguir "el kernel anterior" de "otro build de la misma
      # release" (bore vs bmq), que es justo lo que un rollback necesita saber.
      rollback_manifest_set archive "$rel.tar.xz"
      rollback_manifest_set archive_rel "$rel"
      ok "Rollback preparado: $ROLLBACK_DIR/$rel.tar.xz (kernel en ejecución $rel)"
    else
      sudo rm -f -- "$tmp" 2>/dev/null
      warn "Archive de rollback vacío; omitido."
    fi
  else
    sudo rm -f -- "$tmp" 2>/dev/null
    warn "No se pudo crear el archive de rollback de $rel."
  fi

  prune_rollback_archives
  return 0
}

# Conserva SOLO un archive de rollback: el del kernel PREVIO al actual.
# Prioridad al de mayor versión que NO sea la release en ejecución (el
# "anterior"); si todos coincidieran con el actual, se conserva el de mayor
# versión. Nunca acumula más de uno.
prune_rollback_archives() {
  local running="" keep="" base="" candidate=""
  local -a archives=() keep_list=()
  shopt -s nullglob
  archives=("$ROLLBACK_DIR"/*.tar.xz)
  shopt -u nullglob
  [ "${#archives[@]}" -le 1 ] && return 0

  running="$(uname -r 2>/dev/null || true)"
  for keep in "${archives[@]}"; do
    base="$(basename -- "$keep")"
    case "$base" in
      "$running.tar.xz") continue ;;
    esac
    keep_list+=("$keep")
  done

  if [ "${#keep_list[@]}" -eq 0 ]; then
    candidate="$(printf '%s\n' "${archives[@]}" | sort -V | tail -n1)"
  else
    candidate="$(printf '%s\n' "${keep_list[@]}" | sort -V | tail -n1)"
  fi
  [ -n "$candidate" ] || return 0

  for keep in "${archives[@]}"; do
    [ "$keep" = "$candidate" ] && continue
    base="$(basename -- "$keep")"
    log "Pruning archive de rollback antiguo: $base"
    sudo rm -f -- "$keep" "${keep%.tar.xz}.timestamp" 2>/dev/null || true
  done
}

# ============================================================
# SNAPSHOT BTRFS READONLY DEL ROOT PRE-INSTALACIÓN  (feature 4)
# ============================================================
# Si / es btrfs y CIZEN_SNAPSHOT != 0, se monta el filesystem sin subvol en un
# punto temporal y se crea un snapshot readonly del subvol raíz en
# .snapshots/@kernel-<versión>-<ts>. Fallo blando (warn): es una red de
# seguridad, no un requisito del flujo.
create_btrfs_snapshot() {
  [ "${CIZEN_SNAPSHOT:-1}" = "1" ] || { info "Snapshot btrfs desactivado (CIZEN_SNAPSHOT=0)."; return 0; }
  command -v btrfs >/dev/null 2>&1 || { info "btrfs-progs no instalado; snapshot omitido."; return 0; }
  local fstype
  fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  [ "$fstype" = "btrfs" ] || { info "La raíz no es btrfs ($fstype); snapshot omitido."; return 0; }

  local topdev tmp snapname dst
  topdev="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [ -n "$topdev" ] || { warn "No se pudo resolver el dispositivo btrfs de /; snapshot omitido."; return 0; }
  tmp="$(mktemp -d /tmp/cizen-snap.XXXXXX 2>/dev/null)" || { warn "No se pudo crear temporal; snapshot omitido."; return 0; }

  if ! sudo mount -o subvol=/ "$topdev" "$tmp" >/dev/null 2>&1; then
    rmdir -- "$tmp" 2>/dev/null || true
    warn "No se pudo montar el btrfs top-level; snapshot omitido."
    return 0
  fi

  sudo mkdir -p -- "$tmp/$SNAPSHOT_SUBVOL" 2>/dev/null
  snapname="kernel-$VERSION-$(date +%Y%m%d-%H%M%S)"
  dst="$tmp/$SNAPSHOT_SUBVOL/@$snapname"
  if sudo btrfs subvolume snapshot -r / "$dst" >/dev/null 2>&1; then
    ok "Snapshot btrfs readonly de la raíz: subvol=/$SNAPSHOT_SUBVOL/@$snapname (kernel $VERSION)"
    SNAPSHOT_DESC="$SNAPSHOT_SUBVOL/@$snapname"
  else
    warn "No se pudo crear el snapshot btrfs readonly; se continúa sin él."
  fi

  sudo umount "$tmp" >/dev/null 2>&1 || true
  rmdir -- "$tmp" 2>/dev/null || true
  return 0
}

# ============================================================
# FIRMA DEL BUILD PARA EL VERIFICADOR POST-BOOT  (feature 2)
# ============================================================
# El servicio kernel-update-verify.sh lee este fichero tras el reboot para
# comprobar que el kernel que arrancó cumple lo que este build prometió
# (incluido el scheduler BORE).
# Scheduler efectivo de este build (v27.31.19). Es lo que se graba en la firma
# para que el verificador post-boot pueda compararlo con los símbolos del kernel
# arrancado. No devuelve "inherit": se deduce de lo que realmente se aplicó, que
# es lo comprobable. bore tiene prioridad porque es el símbolo que el fork
# activa por defecto; un kernel con SCHED_BORE=y y SCHED_BMQ=y se reporta bore,
# igual que hace running_sched() en kernel-update-verify.sh.
effective_scheduler() {
  local p
  if [ "$BORE_ENABLED" = true ]; then
    printf 'bore\n'
    return 0
  fi
  for p in "${PATCHES_APPLIED[@]:-}"; do
    case "$p" in
      bore)  printf 'bore\n';  return 0 ;;
      pds)   printf 'pds\n';   return 0 ;;
      bmq)   printf 'bmq\n';   return 0 ;;
      lfbmq) printf 'lfbmq\n'; return 0 ;;
      muqss) printf 'muqss\n'; return 0 ;;
    esac
  done
  printf 'eevdf\n'
}

write_verify_signature() {
  local profile_hash="" rel
  mkdir -p -- "$VERIFY_STATE_DIR" 2>/dev/null || true
  [ -f "$PROFILE_FILE" ] && profile_hash="$(sha256sum "$PROFILE_FILE" | cut -d' ' -f1 2>/dev/null || true)"
  rel="${VERSION}${LOCALVERSION_SUFFIX}"
  {
    printf 'version=%s\n' "$rel"
    printf 'bore=%s\n' "$([ "$BORE_ENABLED" = true ] && echo yes || echo no)"
    # v27.31.19: scheduler EFECTIVO (no el pedido): el verificador post-boot lo
    # compara con los símbolos del kernel arrancado para todos los que el motor
    # ofrece (bore/pds/bmq/lfbmq/muqss, o eevdf si no hay ninguno). Con
    # "inherit" queda el que acabó aplicándose, que es lo comprobable.
    printf 'sched=%s\n' "$(effective_scheduler)"
    # v27.31.22: símbolos que el scheduler aplicado RETIRA del kernel (dependen
    # de !SCHED_ALT, así que son imposibles de habilitar por diseño del parche).
    # build_effective_arrays ya los saca de ENABLE/CRITICAL/SETVAL/SETSTR para
    # que la validación no los haga FATAL; aquí se firman para que el verificador
    # post-boot sepa que su ausencia en el kernel arrancado es correcta y no la
    # cuente como incidencia. Sin esto, un build con bmq/pds/lfbmq que tenga
    # SCHED_AUTOGROUP en CRITICAL_OPTS notificaba "Perfil: FALLO" en cada
    # arranque, y se queda así para siempre.
    if [ "${#PATCH_RETIRED_ALL[@]}" -gt 0 ]; then
      printf 'retired=%s\n' "${PATCH_RETIRED_ALL[*]}"
    fi
    if [ "${#PATCHES_APPLIED[@]}" -gt 0 ]; then
      # bore permanece aparte por compatibilidad; el resto de parches van en patches=.
      printf 'patches=%s\n' "${PATCHES_APPLIED[*]}"
    fi
    printf 'btf=%s\n' "$([ "$BTF_REQUESTED" = true ] && echo yes || echo no)"
    printf 'clang=%s\n' "$([ "$CLANG_BUILD" = true ] && echo yes || echo no)"
    printf 'sb=%s\n' "$([ "${DO_SIGN_UKI:-false}" = true ] && echo yes || echo no)"
    printf 'pkgrel=%s\n' "$PKGREL"
    printf 'profile_sha=%s\n' "${profile_hash:-}"
    printf 'ts=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$VERIFY_STATE_DIR/last-build" 2>/dev/null || true
  return 0
}

# ============================================================
# SINCRONIZACIÓN EXPLÍCITA DEL .EFI / UKI CIZEN
# ============================================================
CIZEN_UKI_NAME="${CIZEN_UKI_NAME:-arch-${CIZEN_PKGBASE}.efi}"
CIZEN_UKI_REQUIRED="${CIZEN_UKI_REQUIRED:-0}"
CIZEN_UKI_FORCE_DIRECT="${CIZEN_UKI_FORCE_DIRECT:-0}"
CIZEN_UKI_ALLOW_RAW_KERNEL_FALLBACK="${CIZEN_UKI_ALLOW_RAW_KERNEL_FALLBACK:-0}"
# Boot counting de systemd-boot: si CIZEN_BOOT_TRIES>0 la UKI se escribe con un
# contador de intentos (arch-linux-cizen-v3+N.efi). Cada boot SIN completar
# boot-complete.target resta 1; al llegar a 0 la entrada pasa a "bad" y
# systemd-boot arranca otra (p.ej. el LTS). Cuando el arranque completa,
# systemd-bless-boot renombra la UKI a nombre plano (sin contador). 0 desactiva.
CIZEN_BOOT_TRIES="${CIZEN_BOOT_TRIES:-3}"

cizen_uki_fail() {
    if [ "${CIZEN_UKI_REQUIRED}" = 1 ]; then
        fatal "$*"
    else
        warn "$*"
        return 0
    fi
}

# Nombre EFI real de la UKI: con contador si CIZEN_BOOT_TRIES>0, si no plano.
cizen_uki_efi_name() {
    local base="${CIZEN_UKI_NAME%.efi}"
    if [ "${CIZEN_BOOT_TRIES:-0}" -gt 0 ]; then
        printf '%s+%s.efi\n' "$base" "${CIZEN_BOOT_TRIES}"
    else
        printf '%s\n' "$CIZEN_UKI_NAME"
    fi
}

# Limpia variantes antiguas de la UKI (nombre plano bendecido por
# systemd-bless-boot y contadores pendientes de boots previos) para que tras
# cada build solo quede la del kernel actual.
cizen_uki_cleanup_variants() {
    local base current r f
    base="${CIZEN_UKI_NAME%.efi}"
    current="$(cizen_uki_efi_name)"
    for r in /efi /boot/efi /boot; do
        [ -d "$r" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            [ "$(basename -- "$f")" = "$current" ] && continue
            sudo rm -f -- "$f" 2>/dev/null || true
        done < <(sudo find "$r" -maxdepth 5 -type f \( -name "${base}.efi" -o -name "${base}+*.efi" \) 2>/dev/null || true)
    done
}

find_cizen_installed_kernel() {
    local rel="${VERSION}${LOCALVERSION_SUFFIX}"
    local c
    local -a candidates=(
        "/boot/vmlinuz-${CIZEN_PKGBASE}"
        "/boot/vmlinuz-${rel}"
        "/boot/vmlinuz-linux-cizen-v3"
        "/usr/lib/modules/${rel}/vmlinuz"
    )

    for c in "${candidates[@]}"; do
        if [ -s "$c" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done

    find /boot -maxdepth 1 -type f -name 'vmlinuz-*' \
        \( -name "*${CIZEN_PKGBASE}*" -o -name "*${rel}*" \) \
        -printf '%T@ %p\n' 2>/dev/null |
        sort -nr | head -n1 | cut -d' ' -f2-
}

prepare_cizen_cmdline_file() {
    local tmp
    tmp="$(mktemp /tmp/cizen-cmdline.XXXXXX)" || return 1

    if [ -s /etc/kernel/cmdline ]; then
        tr '\n' ' ' < /etc/kernel/cmdline |
            sed -E -e 's/[[:space:]]+/ /g' -e 's/^ //' -e 's/[[:space:]]$//' > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        sed -E \
            -e 's/(^|[[:space:]])BOOT_IMAGE=[^[:space:]]*//g' \
            -e 's/(^|[[:space:]])initrd=[^[:space:]]*//g' \
            -e 's/[[:space:]]+/ /g' \
            -e 's/^ //' \
            -e 's/[[:space:]]$//' \
            /proc/cmdline > "$tmp" || { rm -f "$tmp"; return 1; }
    fi

    printf '%s\n' "$tmp"
}

detect_cizen_esp_root() {
    local r fstype
    for r in /efi /boot/efi /boot; do
        [ -d "$r" ] || continue
        fstype="$(findmnt -n -M "$r" -o FSTYPE 2>/dev/null || true)"
        if [[ "$fstype" =~ ^(vfat|msdos|fuseblk)$ ]]; then
            printf '%s\n' "$r"
            return 0
        fi
    done
    return 1
}

find_cizen_uki_targets() {
    local name="$1" r f
    local -a found=()

    for r in /efi /boot/efi /boot; do
        [ -d "$r" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] && found+=("$f")
        done < <(sudo find "$r" -maxdepth 5 -type f -iname "$name" 2>/dev/null || true)
    done

    if [ "${#found[@]}" -gt 0 ]; then
        printf '%s\n' "${found[@]}" | sort -u
        return 0
    fi

    return 1
}

cizen_uki_targets_are_current() {
# Margen de 2 s: vfat (ESP) trunca el mtime a segundos pares; así se evitan
# falsos negativos cuando la escritura ocurre en el mismo segundo del corte.
local base="${PACMAN_INSTALL_START_EPOCH:-$(date +%s)}"
local cutoff=$((base - 2))
local f mtime any=false
while IFS= read -r f; do
# Con sudo: /boot/EFI/Linux suele ser root 0700; sin privilegios, stat y
# test -f fallan por permiso y producirían un falso "no actualizado".
mtime="$(sudo stat -c '%Y' "$f" 2>/dev/null || echo 0)"
[ "$mtime" -gt 0 ] || continue
any=true
if [ "$mtime" -lt "$cutoff" ]; then
return 1
fi
done < <(find_cizen_uki_targets "$(cizen_uki_efi_name)" || true)
[ "$any" = true ]
}

build_cizen_uki() {
    local kernel="$1" cmdline_file="$2" out="$3"
    local cmdline_text ukify_bin="" stub s osrel_file rel

    cmdline_text="$(<"$cmdline_file")"

    # os-release propio embebido en la UKI (.osrel) para que systemd-boot
    # muestre "Linux 7.2.7-cizen-v3" en el menú. Sin --os-release, ukify
    # incrusta /etc/os-release por defecto y el menú mostraría el nombre del
    # sistema ("Arch Linux (rolling)").
    rel="${VERSION}${LOCALVERSION_SUFFIX}"
    osrel_file="$(mktemp /tmp/cizen-osrel.XXXXXX)" || {
        err "No pude crear el os-release temporal."
        return 1
    }
    {
        printf 'NAME="Linux"\n'
        printf 'ID=linux\n'
        printf 'VERSION="%s"\n' "$rel"
        printf 'VERSION_ID="%s"\n' "$rel"
        printf 'PRETTY_NAME="Linux %s"\n' "$rel"
    } > "$osrel_file"

    ukify_bin="$(command -v ukify 2>/dev/null || true)"
    if [ -z "$ukify_bin" ] && [ -x /usr/lib/systemd/ukify ]; then
        ukify_bin="/usr/lib/systemd/ukify"
    fi

    if [ -n "$ukify_bin" ]; then
        local -a args=(
            "$ukify_bin" build
            --linux="$kernel"
            --cmdline="$cmdline_text"
            --os-release=@"$osrel_file"
            --output="$out"
        )
        # Si el kernel Cizen usa initramfs (preset mkinitcpio) se integra en la
        # UKI; si no existe el archivo, la UKI queda sin initrd (kernel
        # autosuficiente). Mismo comportamiento que cizen-uki-sync/build_uki.
        local initrd="/boot/initramfs-${CIZEN_PKGBASE}.img"
        if [ -s "$initrd" ]; then
            args+=(--initrd="$initrd")
            ok "Incluyendo initramfs: $initrd"
        fi
        if "${args[@]}"; then
            rm -f "$osrel_file"
            return 0
        fi
        warn "ukify falló; intento fallback con objcopy."
    fi

    stub=""
    for s in /usr/lib/systemd/boot/efi/linuxx64.efi.stub /usr/lib/gummiboot/linuxx64.efi.stub; do
        if [ -s "$s" ]; then
            stub="$s"
            break
        fi
    done

    if [ -n "$stub" ] && command -v objcopy >/dev/null 2>&1; then
        local -a objargs=(
            --add-section .cmdline="$cmdline_file"
            --set-section-flags .cmdline=noload,readonly
            --add-section .osrel="$osrel_file"
            --set-section-flags .osrel=noload,readonly
            --add-section .linux="$kernel"
            --set-section-flags .linux=noload,readonly
        )
        if objcopy "${objargs[@]}" "$stub" "$out"; then
            rm -f "$osrel_file"
            return 0
        fi
    fi
    [ -n "$osrel_file" ] && rm -f "$osrel_file"

    if [ "${CIZEN_UKI_ALLOW_RAW_KERNEL_FALLBACK}" = 1 ]; then
        cp -f "$kernel" "$out"
        return 0
    fi

    return 1
}

sync_cizen_efi() {
    local kernel cmdline_file tmp out
    kernel="$(find_cizen_installed_kernel)"

    if [ -z "$kernel" ] || [ ! -s "$kernel" ]; then
        cizen_uki_fail "No encontré el kernel instalado de Cizen para actualizar ${CIZEN_UKI_NAME}."
        return 0
    fi

    cmdline_file="$(prepare_cizen_cmdline_file)" || {
        cizen_uki_fail "No pude preparar la línea de comandos para la UKI."
        return 0
    }

    local -a targets=()
    while IFS= read -r out; do
        [ -n "$out" ] && targets+=("$out")
    done < <(find_cizen_uki_targets "$(cizen_uki_efi_name)" || true)

    if [ "${#targets[@]}" -eq 0 ]; then
        local esp
        esp="$(detect_cizen_esp_root)" || true
        if [ -z "$esp" ]; then
            rm -f "$cmdline_file"
            cizen_uki_fail "No encontré una partición EFI montada ni $(cizen_uki_efi_name); no actualizo el .efi."
            return 0
        fi
        targets=("$esp/EFI/Linux/$(cizen_uki_efi_name)")
    fi

    tmp="$(mktemp /tmp/cizen-uki.XXXXXX)" || {
        rm -f "$cmdline_file"
        cizen_uki_fail "No pude crear temporal para la UKI."
        return 0
    }

    if ! build_cizen_uki "$kernel" "$cmdline_file" "$tmp"; then
        rm -f "$tmp" "$cmdline_file"
        cizen_uki_fail "No pude generar la UKI ($(cizen_uki_efi_name)). Instala ukify (systemd) o binutils y verifica /usr/lib/systemd/boot/efi/linuxx64.efi.stub."
        return 0
    fi

    cizen_uki_cleanup_variants

    for out in "${targets[@]}"; do
        log "Actualizando .efi: $out"
        if ! sudo mkdir -p "$(dirname "$out")"; then
            warn "No pude crear $(dirname "$out"); continúo con el siguiente."
            continue
        fi

        if sudo cp -f "$tmp" "${out}.cizen-tmp" && sudo mv -f "${out}.cizen-tmp" "$out"; then
            ok "UKI escrita: $out"
        elif sudo cp -f "$tmp" "$out"; then
            ok "UKI escrita (directa): $out"
        else
            warn "No se pudo actualizar $out"
        fi
    done

    rm -f "$tmp" "$cmdline_file"
    sudo sync

    if ! cizen_uki_targets_are_current; then
        cizen_uki_fail "La UKI no quedó actualizada después de escribir en el objetivo."
    fi

    # Firma de la UKI (ruta directa del motor, sin cizen-uki-sync).
    if [ "$DO_SIGN_UKI" = true ]; then
        if ! cizen_uki_sign_targets "${targets[@]}"; then
            cizen_uki_fail "No se pudo firmar la UKI con sbctl."
        fi
    fi
}

ensure_cizen_efi_updated() {
    if [ "${CIZEN_UKI_FORCE_DIRECT}" != 1 ] && cizen_uki_targets_are_current; then
        ok "UKI ya actualizada por cizen-uki-sync."
        return 0
    fi

    sync_cizen_efi
}

# ============================================================
# FIRMA DE LA UKI CON SBCTL (SECURE BOOT, v27.29.3)
# ============================================================
# Secure Boot habilitado en el firmware: la variable UEFI SecureBoot (efivar)
# lleva en el byte 4 el valor (01 = activo). Los sysfs efivar son legibles por
# el usuario; si no, se reintenta con sudo (ticket ya calentado).
secure_boot_active() {
    local val
    val="$(od -An -j4 -N1 -tu1 \
        "/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c" \
        2>/dev/null | tr -d '[:space:]' || true)"
    if [ -z "$val" ] && sudo -n true 2>/dev/null; then
        val="$(sudo od -An -j4 -N1 -tu1 \
            "/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c" \
            2>/dev/null | tr -d '[:space:]' || true)"
    fi
    [ "$val" = "1" ]
}

# Firma cada objetivo con sbctl y verifica. Uso: cizen_uki_sign_targets "archivo"...
cizen_uki_sign_targets() {
    local t fail=0
    [ -n "$SBCTL_BIN" ] || { warn "sbctl no está instalado; no se puede firmar la UKI."; return 1; }
    # --save: desde sbctl 0.18 firmar NO registra la firma en la BD sin -s;
  # sin --save el hook de pacman (sbctl sign-all) no re-firma systemd-boot/UKI
  # en actualizaciones y sbctl verify deja de reconocer el fichero.
  for t in "$@"; do
        if sudo sbctl sign --save "$t" >/dev/null 2>&1; then
            ok "Firmada con sbctl: $t"
        else
            warn "sbctl sign falló: $t"
            fail=1
        fi
    done
    [ "$fail" -eq 0 ] || return 1
    for t in "$@"; do
        if sudo sbctl verify "$t" >/dev/null 2>&1; then
            ok "Firma verificada: $t"
        else
            warn "La verificación de la firma falló: $t"
            fail=1
        fi
    done
    return "$fail"
}

# Verifica que TODOS los objetivos estén firmados (sbctl verify). 0 = sí.
cizen_uki_sign_targets_verify() {
    [ -n "$SBCTL_BIN" ] && [ "$#" -gt 0 ] || return 1
    local t
    for t in "$@"; do
        sudo sbctl verify "$t" >/dev/null 2>&1 || return 1
    done
    return 0
}

# ── Preferencia recordada de firma (v27.29.3) ────────────────────────────────
# La última decisión explícita tomada en modo auto (sí/no en el prompt
# interactivo) se guarda en $SIGN_UKI_STATE_FILE y se reutiliza en builds
# siguientes: el script no vuelve a preguntar y no decide en silencio. Secure
# Boot activo en el firmware fuerza SIEMPRE la firma, recuerde o no el estado;
# --sign/--no-sign y CIZEN_SIGN_UKI=yes|no tienen prioridad sobre lo recordado.
sign_uki_state_get() {
    local v
    v="$(cat "$SIGN_UKI_STATE_FILE" 2>/dev/null || true)"
    case "$v" in
        yes|no) printf '%s\n' "$v" ;;
        *) printf '%s\n' "unknown" ;;
    esac
}

sign_uki_state_set() {
    local val="${1:-yes}"
    case "$val" in
        yes|no) ;;
        *) return 1 ;;
    esac
    mkdir -p -- "$SIGN_UKI_STATE_DIR" 2>/dev/null || return 1
    printf '%s\n' "$val" > "$SIGN_UKI_STATE_FILE" 2>/dev/null
}

# Decide DO_SIGN_UKI. "auto" (default): con Secure Boot activo se firma siempre,
# sin pregunta. Si no, la última decisión explícita (guardada en sign-uki.state)
# se reutiliza; en la primera vez se sugiere firmar (S/n) y la respuesta se
# recuerda para los siguientes builds. Cuando la firma queda activada, se ofrece
# además el setup guiado de Secure Boot (claves, systemd-boot y enroll de
# claves) para dejar toda la cadena lista.
resolve_sign_uki() {
    local answer state
    case "$SIGN_UKI" in
        yes)
            DO_SIGN_UKI=true
            SIGN_UKI_REASON="--sign / CIZEN_SIGN_UKI=yes"
            info "Firma de la UKI con sbctl forzada ($SIGN_UKI_REASON)."
            ;;
        no)
            if secure_boot_active; then
                fatal "Se pidió NO firmar la UKI (--no-sign) pero Secure Boot está ACTIVO: el arranque fallaría. Usa --sign, CIZEN_SIGN_UKI=yes o desactiva Secure Boot."
            fi
            DO_SIGN_UKI=false
            SIGN_UKI_REASON="--no-sign / CIZEN_SIGN_UKI=no"
            info "Firma de la UKI desactivada ($SIGN_UKI_REASON)."
            ;;
        *)
            if [ -z "$SBCTL_BIN" ]; then
                DO_SIGN_UKI=false
                SIGN_UKI_REASON="sbctl no instalado (sudo pacman -S sbctl)"
                info "No se detecta sbctl: la UKI no se firmará."
            elif secure_boot_active; then
                DO_SIGN_UKI=true
                SIGN_UKI_REASON="Secure Boot activo (imprescindible)"
                ok "Secure Boot ACTIVO: la UKI se firmará con sbctl."
            else
                state="$(sign_uki_state_get)"
                if [ "$state" = "yes" ]; then
                    DO_SIGN_UKI=true
                    SIGN_UKI_REASON="firma recordada de un build anterior"
                    ok "Preferencia recordada: la UKI se firmará con sbctl."
                elif [ "$state" = "no" ]; then
                    DO_SIGN_UKI=false
                    SIGN_UKI_REASON="no-firma recordada de un build anterior"
                    info "Preferencia recordada: se continuará SIN firmar la UKI (reversa: --sign o CIZEN_SIGN_UKI=yes)."
                elif ! [ -t 0 ] && ! [ -t 1 ]; then
                    DO_SIGN_UKI=false
                    SIGN_UKI_REASON="sin terminal interactiva"
                    info "Secure Boot desactivado y sin terminal interactiva: la UKI no se firmará."
                else
                    printf '\n'
                    printf '  Se ha detectado sbctl (Secure Boot). La UKI %s puede firmarse\n' "$(cizen_uki_efi_name)"
                    printf '  para arrancar con Secure Boot habilitado (sbctl sign). La\n'
                    printf '  decisión quedará recordada para los siguientes builds.\n'
                    read -r -p "  ¿Firmar la UKI del kernel con sbctl? [S/n] " answer < /dev/tty || answer="n"
                    case "${answer:-s}" in
                        s|S|si|SI|Sí|sí|y|Y|yes|YES)
                            DO_SIGN_UKI=true
                            SIGN_UKI_REASON="sugerido y confirmado"
                            sign_uki_state_set yes
                            ok "La UKI se firmará con sbctl (decisión recordada)."
                            ;;
                        *)
                            DO_SIGN_UKI=false
                            SIGN_UKI_REASON="rechazado por el usuario"
                            sign_uki_state_set no
                            info "Se continuará SIN firmar la UKI (decisión recordada; revertir: --sign)."
                            ;;
                    esac
                fi
            fi
            ;;
    esac
    if [ "$DO_SIGN_UKI" = true ]; then
        secure_boot_guided_setup
    fi
    return 0
}

# ── Setup guiado de Secure Boot (v27.29.3) ──────────────────────────────────
# Al aceptar la firma de la UKI se revisa el estado real de la cadena por la
# BIOS (claves = /var/lib/sbctl/keys, SetupMode efivar, systemd-boot firmado)
# y se ofrece punto a punto, de forma interactiva, ejecutar lo que falte:
#   1. sbctl create-keys         3. sbctl sign systemd-boot
#   2. sbctl enroll-keys --microsoft (reintento auto si falta TPM Eventlog)
#   4. habilita Secure Boot en la BIOS (manual)
# La UKI del build se firma después, en cizen-uki-sync. Idempotente: solo
# pregunta por lo que queda pendiente.
sbctl_keys_present() {
    sudo test -s /var/lib/sbctl/keys/db/db.key 2>/dev/null && \
    sudo test -s /var/lib/sbctl/keys/PK/PK.key 2>/dev/null && \
    sudo test -s /var/lib/sbctl/keys/KEK/KEK.key 2>/dev/null
}

# 1 = firmware en Setup Mode (sin claves). 0 = User Mode (con claves ya en la
# BIOS, aunque sean las de fábrica: Dell/Microsoft). En User Mode sbctl
# enroll-keys NO puede ejecutarse.
sbctl_setup_mode() {
    local v
    v="$(od -An -j4 -N1 -tu1 \
        "/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c" \
        2>/dev/null | tr -d '[:space:]' || true)"
    if [ -z "$v" ] && sudo -n true 2>/dev/null; then
        v="$(sudo od -An -j4 -N1 -tu1 \
            "/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c" \
            2>/dev/null | tr -d '[:space:]' || true)"
    fi
    [ "$v" = "1" ]
}

# sbctl 0.18+ se niega a matricular por defecto cuando no encuentra TPM
# Eventlog (TPM deshabilitado en BIOS o ausente del hardware):
# "Could not find any TPM Eventlog in the system... we do not know if there is
# any OptionROM present" → exige un flag explícito. El reintento con
# --microsoft es la opción estándar: matricula además los certificados OEM de
# Microsoft en db, lo que mantiene el arranque de OptionROM/multiboot MS junto
# a las claves propias. Solo se reintenta si el fallo es exactamente ese.
sbctl_enroll_keys() {
    local out
    if out="$(sudo sbctl enroll-keys 2>&1)"; then
        return 0
    fi
    if printf '%s' "$out" | grep -qE "TPM Eventlog|might-brick"; then
        info "sbctl no encuentra TPM Eventlog (TPM deshabilitado o ausente) y exige flag explícito; reintentando 'sbctl enroll-keys --microsoft' (matricula también los certificados OEM de Microsoft en db)…"
        if out="$(sudo sbctl enroll-keys --microsoft 2>&1)"; then
            ok "Claves matriculadas con certificados de Microsoft (--microsoft)."
            return 0
        fi
        err "sbctl enroll-keys --microsoft falló:"
        printf '%s\n' "$out"
        return 1
    fi
    err "sbctl enroll-keys falló (requisito: firmware en Setup Mode; revisa la salida):"
    printf '%s\n' "$out"
    return 1
}

# ¿La PK matriculada en el firmware es NUESTRA clave sbctl? Mira el certificado
# real de la variable UEFI PK (efivar: cabecera de 4 bytes + EFI_SIGNATURE_LIST
# de 44 bytes, el X.509 DER arranca en el byte 48) y lo compara por huella SHA256
# con /var/lib/sbctl/keys/PK/PK.pem. Robustez: con cualquier fallo devuelve "no".
sbctl_pk_enrolled() {
    local pkvar="/sys/firmware/efi/efivars/PK-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    local pem="/var/lib/sbctl/keys/PK/PK.pem"
    local ours fw tmp
    if ! sudo test -s "$pem" 2>/dev/null || [ ! -e "$pkvar" ]; then
        return 1
    fi
    ours="$(sudo openssl x509 -in "$pem" -noout -fingerprint -sha256 2>/dev/null \
        | awk -F= 'NR==1{print toupper($2)}' | tr -d ':')"
    [ -n "$ours" ] || return 1
    tmp="$(mktemp 2>/dev/null || printf '/tmp/sbctl-pk.der.%s' "$$")"
    if [ -r "$pkvar" ]; then
        dd if="$pkvar" of="$tmp" bs=1 skip=48 status=none 2>/dev/null
    else
        sudo dd if="$pkvar" of="$tmp" bs=1 skip=48 status=none 2>/dev/null
    fi
    fw="$(openssl x509 -inform DER -in "$tmp" -noout -fingerprint -sha256 2>/dev/null \
        | awk -F= 'NR==1{print toupper($2)}' | tr -d ':')"
    rm -f "$tmp"
    [ -n "$fw" ] && [ "$fw" = "$ours" ]
}

# Copias del gestor a firmar: la fuente del paquete (la re-firma el hook de sbctl
# al actualizar systemd) y las copias reales de arranque en el ESP.
collect_systemd_boot_targets() {
    local s r f
    [ -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi ] && \
        printf '%s\n' /usr/lib/systemd/boot/efi/systemd-bootx64.efi
    for r in /efi /boot/efi /boot; do
        [ -d "$r" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] && printf '%s\n' "$f"
        done < <(sudo find "$r" -maxdepth 5 -type f \
            \( -iname 'systemd-bootx64.efi' -o -iname 'BOOTX64.EFI' \) \
            2>/dev/null || true)
    done
}

# Guía genérica de BIOS para los pasos que el script NO puede automatizar:
# devolver el firmware a SETUP MODE (para poder enrollar las claves) o
# habilitar Secure Boot. Se imprime cuando el estado real del firmware lo
# requiere; el usuario ejecuta el detour (reiniciar → BIOS → guardar → volver)
# y re-ejecuta el script, que detectará el nuevo estado y continuará.
# Uso: secure_boot_bios_guide [setup|enable]  (default: setup)
secure_boot_bios_guide() {
    local mode="${1:-setup}"
    printf '%s\n' \
        "  ────────────── Guía de BIOS (manual) ──────────────"
    case "$mode" in
        enable)
            printf '  1. Guarda tu trabajo y reinicia.\n'
            printf '  2. Pulsa repetidamente la tecla de la BIOS/UEFI durante el logo del\n'
            printf '     fabricante (habitual: Supr/Del en sobremesas, F2 en portátiles; el\n'
            printf '     arranque suele mostrar la tecla en pantalla).\n'
            printf '  3. Localiza el apartado "Secure Boot" (suele estar en "Boot" o en\n'
            printf '     "Security"; la ruta exacta depende del fabricante).\n'
            printf '  4. Pon Secure Boot en "Enabled". NO toques las claves ya matriculadas.\n'
            printf '  5. Guarda y sal (habitual: F10).\n'
            printf '  6. Arranca Arch y confirma el estado en el resumen siguiente o con:\n'
            printf '     sudo sbctl status\n'
            ;;
        *)
            printf '  1. Guarda tu trabajo y reinicia.\n'
            printf '  2. Pulsa repetidamente la tecla de la BIOS/UEFI durante el logo del\n'
            printf '     fabricante (habitual: Supr/Del en sobremesas, F2 en portátiles; el\n'
            printf '     arranque suele mostrar la tecla en pantalla).\n'
            printf '  3. Localiza el apartado "Secure Boot" (suele estar en "Boot" o en\n'
            printf '     "Security"; en portátiles a veces bajo "Security" o "Startup").\n'
            printf '  4. Devuelve el firmware a SETUP MODE. Cada fabricante lo llama distinto:\n'
            printf '     "Reset to Setup Mode", "Custom", borrar/"Clear" las claves OEM\n'
            printf '     (PK/KEK/db), modo "Enrollment"... El requisito es dejar la BIOS SIN\n'
            printf '     claves matriculadas (Setup Mode = PK vacía).\n'
            printf '  5. Guarda y sal (habitual: F10).\n'
            printf '  6. Re-ejecuta este script: detectará el Setup Mode y te ofrecerá\n'
            printf '     matricular tus claves con sbctl enroll-keys --microsoft.\n'
            ;;
    esac
    printf '%s\n' \
        "  ─────────────────────────────────────────────────"
}

# Al aceptar la firma de la UKI se revisa el estado real de la cadena por la
# BIOS (claves en /var/lib/sbctl/keys, matrícula REAL de la PK por huella del
# certificado del efivar PK, systemd-boot firmado) y se ofrece punto a punto,
# de forma interactiva, ejecutar lo que falte:
#   1. sbctl create-keys         3. sbctl sign systemd-boot
#   2. sbctl enroll-keys --microsoft (reintento auto si falta TPM Eventlog)
#   4. habilita Secure Boot en la BIOS (manual)
# La UKI del build se firma después, en cizen-uki-sync. Idempotente: solo
# pregunta por lo que queda pendiente. Con claves de fábrica (Dell/MS) en User
# Mode no puede hacer enroll desde el sistema: lo detecta y lo explica (BIOS →
# setup mode), sin dar una matrícula falsa por hecha.
secure_boot_guided_setup() {
    local -a boot_targets=() f
    local pending=false keyt="n/d" enrollp="n/d" bootp="n/d"

    printf '%s\n' \
        "  ──────── Setup guiado de Secure Boot (sbctl) ────────"

    if ! sbctl_keys_present; then
        pending=true
        keyt="no"
        printf '  Las claves Secure Boot NO están generadas (sbctl create-keys).\n'
        if ask_user_yes "¿Generarlas ahora ('sudo sbctl create-keys')? [S/n]"; then
            if sudo sbctl create-keys && sbctl_keys_present; then
                keyt="sí"
                pending=false
                ok "Claves Secure Boot generadas (/var/lib/sbctl/keys)."
            else
                err "sbctl create-keys falló."
            fi
        else
            warn "Claves no generadas: la UKI del build no podrá firmarse y Secure Boot quedaría inutilizable."
            return 1
        fi
    else
        keyt="sí"
        ok "Claves Secure Boot presentes (/var/lib/sbctl/keys)."
    fi

    if sbctl_setup_mode; then
        pending=true
        enrollp="no"
        printf '  El firmware está en SETUP MODE (sin claves matriculadas).\n'
        if ask_user_yes "¿Matricular las claves en la BIOS ('sudo sbctl enroll-keys --microsoft')? [S/n]"; then
            if sbctl_enroll_keys && sbctl_pk_enrolled; then
                enrollp="sí"
                pending=false
                ok "Claves matriculadas en el firmware (User Mode)."
            else
                enrollp="no"
                err "sbctl enroll-keys no completó la matrícula (requisito: firmware en Setup Mode; revisa la salida)."
            fi
        else
            warn "Claves sin matricular: habilitar Secure Boot sin esto NO arrancaría."
        fi
    elif sbctl_pk_enrolled; then
        enrollp="sí"
        ok "Claves del usuario ya matriculadas en el firmware (User Mode)."
    else
        pending=true
        enrollp="no"
        printf '  El firmware está en USER MODE con claves de fábrica (Dell/Microsoft):\n'
        printf '  sbctl enroll-keys NO puede ejecutarse en este estado. Para matricular\n'
        printf '  tus claves, devuelve el firmware a SETUP MODE desde la BIOS\n'
        printf '  (Dell: Secure Boot → Expert Key Management / borrar las claves OEM) y\n'
        printf '  vuelve a ejecutar este setup guiado. Sin matricular tus claves, la BIOS\n'
        printf '  solo aceptaría binarios firmados por Dell/Microsoft, no tu kernel.\n'
        secure_boot_bios_guide setup
    fi

    boot_targets=()
    while IFS= read -r f; do
        [ -n "$f" ] && boot_targets+=("$f")
    done < <(collect_systemd_boot_targets | sort -u || true)

    if [ "${#boot_targets[@]}" -gt 0 ]; then
        if cizen_uki_sign_targets_verify "${boot_targets[@]}"; then
            bootp="sí"
            ok "systemd-boot ya firmado con sbctl."
        else
            pending=true
            bootp="no"
            printf '  systemd-boot no está firmado (imprescindible para arrancar con SB).\n'
            if ask_user_yes "¿Firmar systemd-boot (${#boot_targets[@]} fichero(s)) con sbctl? [S/n]"; then
                if cizen_uki_sign_targets "${boot_targets[@]}"; then
                    bootp="sí"
                    pending=false
                    ok "systemd-boot firmado."
                else
                    err "Fallo al firmar systemd-boot."
                fi
            else
                warn "systemd-boot sin firmar: con Secure Boot activo no arrancaría nada."
            fi
        fi
    else
        warn "No localicé systemd-boot en el ESP; fírmalo antes de activar Secure Boot (sbctl sign /usr/lib/systemd/boot/efi/systemd-bootx64.efi)."
    fi

    printf '%s\n' \
        "  ──────────────────────────────────────────────────────"
    printf '  Claves           : %s\n' "$keyt"
    printf '  Firmware (enroll): %s\n' "$enrollp"
    printf '  systemd-boot     : %s\n' "$bootp"
    if [ "$enrollp" = "sí" ] && ! secure_boot_active; then
        warn "Secure Boot sigue desactivado en la BIOS: falta el último paso manual."
        secure_boot_bios_guide enable
    fi
    if [ "$pending" = true ]; then
        err "Cadena Secure Boot con pasos pendientes: resuélvelos y vuelve a ejecutar."
        return 1
    fi
    return 0
}

# ============================================================
# MENUCONFIG / PAHOLE / SELFTEST / REPO / CHANGELOG  (v27.24.0)
# ============================================================

# BTF (obligatorio por defecto): pahole genera el .BTF en la compilación. Solo
# se requiere cuando no hay opt-out (--no-btf / CIZEN_NO_BTF); si no se puede,
# BTF_REQUESTED=false (fatal suave).
ensure_optional_pahole() {
  [ "$BTF_REQUESTED" = true ] || return 0
  command -v pahole >/dev/null 2>&1 && { ok "pahole disponible (BTF habilitado)."; return 0; }
  if [ "${CIZEN_NO_AUTOINSTALL:-0}" != "1" ] && ask_user_yes "BTF necesita 'pahole' para generar el .BTF. ¿Instalarlo ('sudo pacman -S --needed pahole')? [S/n]"; then
    if sudo pacman -S --needed pahole && command -v pahole >/dev/null 2>&1; then
      ok "pahole instalado (BTF habilitado)."
      return 0
    fi
  fi
  warn "pahole no disponible; BTF se desactiva para esta ejecución (sudo pacman -S pahole)."
  BTF_REQUESTED=false
  return 1
}

# kcfg / --menuconfig: edición visual de la config Cizen ya validada. Guarda un
# diff frente a la config previa (con sugerencias de entrada OPTS_* por cambio),
# re-normaliza con olddefconfig y revalida para no dejar pasar un cambio roto.
report_menuconfig_diff() {
  local base="$1" line sym b c a
  declare -A base_state=()
  local -a changed=() added=() removed=()

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)=(.*)$ ]]; then
      base_state["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
      base_state["${BASH_REMATCH[1]}"]="n"
    fi
  done < "$base"

  while IFS= read -r sym; do
    [ -n "$sym" ] || continue
    b=""; c=""
    [ -n "${base_state[$sym]+x}" ] && b="${base_state[$sym]}"
    [ -n "${CONFIG_STATE[$sym]+x}" ] && c="${CONFIG_STATE[$sym]}"
    if [ -z "$b" ] && [ -n "$c" ] && [ "$c" != "n" ]; then
      added+=("$sym=$c")
    elif [ -n "$b" ] && [ -z "$c" ]; then
      removed+=("$sym")
    elif [ -n "$b" ] && [ -n "$c" ] && [ "$b" != "$c" ]; then
      # y<->m es solo un cambio de modo (ENABLE/DISABLE del perfil ya admite
      # cualquiera); no se reporta como cambio de valor real.
      if { [ "$b" = "y" ] && [ "$c" = "m" ]; } || { [ "$b" = "m" ] && [ "$c" = "y" ]; }; then
        :
      else
        changed+=("$sym: $b -> $c")
      fi
    fi
  done < <( { for a in "${!base_state[@]}"; do printf '%s\n' "$a"; done
             for a in "${!CONFIG_STATE[@]}"; do printf '%s\n' "$a"; done; } | sort -u )
  unset line sym b c a base_state

  local out="$KERNEL_BUILD_ROOT/menuconfig-diff-${TS}.txt"
  {
    printf '# menuconfig diff vs la config Cizen ya validada (%s)\n' "$(date +%F\ %T)"
    printf '# Para que un cambio sobreviva a la PRÓXIMA versión, añádelo al perfil\n'
    printf '# %s en el array que corresponde (la config base se promueve igualmente).\n' "$PROFILE"
    printf '\n== NUEVOS (=y/m)  -> añadir a OPTS_ENABLE ==\n'
    for line in "${added[@]}"; do printf 'CONFIG_%s\n' "$line"; done
    printf '\n== RETIRADOS (=n) -> añadir a OPTS_DISABLE ==\n'
    for line in "${removed[@]}"; do printf 'CONFIG_%s\n' "$line"; done
    printf '\n== CAMBIADOS      -> actualizar OPTS_SETVAL/OPTS_SETSTR ==\n'
    for line in "${changed[@]}"; do printf '%s\n' "$line"; done
  } > "$out" 2>/dev/null || true

  [ "${#added[@]}" -gt 0 ] && info "menuconfig: nuevos ${#added[@]} (ver OPTS_ENABLE en el diff)."
  [ "${#removed[@]}" -gt 0 ] && info "menuconfig: retirados ${#removed[@]} (ver OPTS_DISABLE en el diff)."
  [ "${#changed[@]}" -gt 0 ] && info "menuconfig: cambiados ${#changed[@]} (ver OPTS_SETVAL/SETSTR en el diff)."
  [ "$(( ${#added[@]} + ${#removed[@]} + ${#changed[@]} ))" -eq 0 ] && info "menuconfig: sin cambios reales respecto a la config Cizen."
}

menuconfig_edit() {
  [ "$MENUCONFIG_REQUESTED" = true ] || return 0
  if ! [ -t 0 ] && ! [ -t 1 ]; then
    warn "--menuconfig requiere una terminal interactiva; se omite."
    return 0
  fi
  if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists ncurses >/dev/null 2>&1; then
    warn "menuconfig necesita ncurses (paquete 'ncurses'). Se omite; usa scripts/config o edita el perfil."
    return 0
  fi

  local base="$KERNEL_BUILD_ROOT/config-pre-menuconfig-${TS}"
  cp -f .config "$base" 2>/dev/null || { warn "No se pudo guardar la config previa; se omite menuconfig."; return 0; }
  info "Abriendo menuconfig sobre la config Cizen validada de $VERSION (edita, guarda y sal)..."
  if ! make menuconfig >/dev/null 2>&1; then
    warn "make menuconfig falló; se restaura la configuración previa."
    cp -f "$base" .config 2>/dev/null || true
    return 0
  fi
  load_config_state
  report_menuconfig_diff "$base"
  log "Re-normalizando la configuración editada (olddefconfig + validación)..."
  run_kconfig_audit || fatal "Auditoría Kconfig tras menuconfig fallida."
  validate_config || fatal "La configuración editada con menuconfig no supera la validación del perfil."
  ok "Configuración editada con menuconfig validada."
  return 0
}

# --hardened: auditoría de endurecimiento del kernel EN EJECUCIÓN. Lee /proc/config.gz
# (postura real de la configuración: stack protección, fortify, usercopy, ASLR, ...)
# y los knobs sysctl vivos (randomize_va_space, dmesg_restrict, kptr_restrict...).
# Sin efectos laterales: imprime tabla con ✓/✗ y resumen, y sale sin modificar nada.
run_hardened_audit() {
  local line sym exp desc kw val nok=0 nbad=0
  local -a cfg_lines=()
  mapfile -t cfg_lines < <(zcat /proc/config.gz 2>/dev/null || true)
  if [ "${#cfg_lines[@]}" -eq 0 ]; then
    warn "No se pudo leer /proc/config.gz (CONFIG_IKCONFIG_PROC necesario)."
    return 1
  fi
  declare -A CFG=()
  local ln re='^CONFIG_([A-Za-z0-9_]+)=("[^"]*"|[ym])$'
  for ln in "${cfg_lines[@]}"; do
    if [[ "$ln" =~ $re ]]; then
      CFG["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    elif [[ "$ln" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
      CFG["${BASH_REMATCH[1]}"]="n"
    fi
  done

  local -a CHECKS=(
    "STACKPROTECTOR_STRONG:y:Stack fortalecido (canarios en todas las cajas)"
    "FORTIFY_SOURCE:y:Memcpy/memset fortificados (límites en tiempo de compilación y exec)"
    "HARDENED_USERCOPY:y:Usercopy validada (mitigan overflows copy_from/to_user)"
    "SLAB_FREELIST_RANDOM:y:Freelist de slab aleatorizada"
    "SLAB_FREELIST_HARDENED:y:Freelist de slab endurecida (obliteración de metadatos)"
    "REFCOUNT_FULL:y:Contadores de ref con wrap protegido a 32 bits"
    "VMAP_STACK:y:Pilas de kernel en mem. vmalloc (metadatos anónimos)"
    "STRICT_KERNEL_RWX:y:Regiones de kernel RO+X (no writable+executable)"
    "STRICT_MODULE_RWX:y:Regiones de módulos RO+X"
    "RANDOMIZE_BASE:y:ASLR del kernel (KASLR)"
    "MODULE_SIG_FORCE:y:Solo se cargan módulos firmados"
    "BPF_UNPRIV_DEFAULT_OFF:y:bpf sin privilegios desactivado por defecto"
  )

  echo
  info "Auditoría hardening — kernel en ejecución $(uname -r)"
  for line in "${CHECKS[@]}"; do
    IFS=: read -r sym exp desc <<< "$line"
    val="${CFG[$sym]:-}"
    [ -n "$val" ] || val="no configurado"
    case "$val" in
      "$exp") ok "  $sym  ($desc) → $val" ; nok=$((nok + 1)) ;;
      "n")    warn "$sym = n  (esperado $exp): $desc" ; nbad=$((nbad + 1)) ;;
      "m")    warn "$sym = m  (esperado $exp): $desc" ; nbad=$((nbad + 1)) ;;
      *)      warn "$sym = $val (esperado $exp): $desc" ; nbad=$((nbad + 1)) ;;
    esac
  done

  local -a KNOBS=(
    "kernel.randomize_va_space:2:ASLR del espacio de usuario (2 = completo)"
    "kernel.dmesg_restrict:1:Acceso a dmesg restringido"
    "kernel.kptr_restrict:1:Ocultar punteros de /proc"
    "kernel.unprivileged_bpf_disabled:2:bpf sin privilegios desactivado"
    "fs.protected_hardlinks:1:Links duros restringidos"
    "fs.protected_symlinks:1:Enlaces simbólicos restringidos"
    "fs.suid_dumpable:0:Resumen de proceso con suid sin core dump"
  )
  echo "  ----- knobs sysctl vivos -----"
  for knobs in "${KNOBS[@]}"; do
    IFS=: read -r kw exp desc <<< "$knobs"
    val="$(sysctl -n "$kw" 2>/dev/null || true)"
    if [ -z "$val" ]; then
      info "  $kw: no disponible"
    elif [ "$val" = "$exp" ]; then
      ok "  $kw = $val ($desc)"
      nok=$((nok + 1))
    else
      warn "  $kw = $val (esperado $exp): $desc"
      nbad=$((nbad + 1))
    fi
  done

  echo
  if [ "$nbad" -gt 0 ]; then
    warn "Hardening: $nok OK, $nbad recomendaciones pendientes."
  else
    ok "Hardening: $nok OK, sin recomendaciones pendientes."
  fi
  [ "$nbad" -eq 0 ]
}

# --selftest: autoevaluación del motor (sintaxis, perfil, herramientas) + el
# harness funcional de la suite cuando existe.
run_selftest() {
  local rc=0 t
  echo
  info "Autoevaluación del motor kernel-update.sh v$SCRIPT_VERSION ..."
  if bash -n -- "$0" 2>/dev/null; then
    ok "Sintaxis del motor: bash -n OK"
  else
    err "Sintaxis del motor: bash -n falló"
    rc=1
  fi

  if load_profile 2>/dev/null; then
    ok "Perfil cargado: $PROFILE_FILE"
    build_effective_arrays
    if check_profile_contradictions 2>/dev/null; then
      ok "Perfil sin contradicciones ENABLE/DISABLE/SETVAL/SETSTR"
    else
      err "Perfil con contradicciones ENABLE/DISABLE/SETVAL/SETSTR"
      rc=1
    fi
  else
    err "El perfil no se puede cargar ($PROFILE_FILE)"
    rc=1
  fi

  for t in patch aria2c xz gpg tar ccache clang ld.lld pahole sbctl; do
    if command -v "$t" >/dev/null 2>&1; then
      ok "herramienta '$t' disponible"
    else
      info "herramienta '$t' ausente (opcional)"
    fi
  done

  local harness="$SCRIPT_DIR/tests/selftest.sh"
  # Si aún no está instalado en la suite (crear tests/ exige sudo), se cae a
  # los espejos del repo git local (no compromete la suite de producción).
  [ -f "$harness" ] || harness="$HOME/cizen-linux-kernel-update/kernel-update/tests/selftest.sh"
  [ -f "$harness" ] || harness="$HOME/Proyectos/cizen-linux-kernel-update/kernel-update/tests/selftest.sh"
  if [ -f "$harness" ]; then
    info "Ejecutando harness funcional: $harness"
    if bash "$harness" "$0"; then
      ok "Harness de tests: TODO CORRECTO"
    else
      err "Harness de tests: fallo(s)"
      rc=1
    fi
  else
    warn "No existe el harness funcional (tests/selftest.sh); se omiten los tests funcionales."
  fi

  [ "$rc" -eq 0 ] && ok "Autoevaluación completada sin fallos." || err "Autoevaluación completada con $rc fallo(s)."
  return "$rc"
}

# --publish-repo: tras instalar, copia el paquete a un repositorio local pacman
# y refresca su base de datos con repo-add (para las VMs libvirt / otros hosts).
publish_repo_package() {
  [ "$PUBLISH_REPO" = true ] || return 0
  [ -s "${PKG:-}" ] || { warn "No hay paquete que publicar; se omite el repo local."; return 0; }
  if ! command -v repo-add >/dev/null 2>&1; then
    warn "repo-add no está instalado (paquete pacman-contrib). Se omite la publicación: sudo pacman -S pacman-contrib"
    return 0
  fi
  if ! sudo -n true 2>/dev/null; then
    warn "Sin ticket sudo vigente; se omite la publicación en $PUBLISH_REPO_DIR."
    return 0
  fi

  local pkgfile="$(basename -- "$PKG")"
  sudo mkdir -p -- "$PUBLISH_REPO_DIR" || { warn "No se pudo crear $PUBLISH_REPO_DIR"; return 0; }
  sudo cp -f -- "$PKG" "$PUBLISH_REPO_DIR/$pkgfile" || { warn "No se pudo copiar el paquete al repo local."; return 0; }
  if sudo repo-add -q -- "$PUBLISH_REPO_DIR/cizen-linux.db.tar.gz" "$PUBLISH_REPO_DIR/$pkgfile"; then
    ok "Publicado en repo local: $PUBLISH_REPO_DIR (db 'cizen-linux')"
    PUBLISH_REPO_MSG="Repo local  : $PUBLISH_REPO_DIR (cizen-linux)
   Para usarlo en VMs/compañeros añade a /etc/pacman.conf:
     [cizen-linux]
     Server = file://$PUBLISH_REPO_DIR
     SigLevel = Optional
   (o sirve el directorio por HTTP/NFS y cambia Server.)"
  else
    warn "repo-add falló al publicar $pkgfile."
  fi
  return 0
}

# --changelog: mantenimiento. Bumpea banner + SCRIPT_VERSION del motor a
# X.Y.(Z+1) y añade al top de CHANGELOG.md (override CIZEN_CHANGELOG_FILE;
# por defecto ../CHANGELOG.md respecto del motor, sino junto a él) un
# borrador con el diff --stat del espejo git (si existe). Desde v27.26.0 el
# historial ya no vive en la cabecera del motor. NO hace commit ni push; el
# texto del borrador lo completa el mantenedor.
changelog_bump() {
  local cur new patch ts mirror repo stat_info tmp clfile cltmp
  cur="$SCRIPT_VERSION"
  patch="${cur##*.}"
  [[ "$patch" =~ ^[0-9]+$ ]] || { err "SCRIPT_VERSION inválido: $cur"; return 1; }
  new="${cur%.*}.$((patch + 1))"
  ts="$(date +%Y-%m-%d)"
  mirror="${CIZEN_KERNEL_MIRROR:-$HOME/cizen-linux-kernel-update/kernel-update}"
  repo="$(dirname -- "$mirror")"
  stat_info=""
  if [ -f "$mirror/kernel-update.sh" ] && git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    stat_info="$(git -C "$repo" diff --stat HEAD -- kernel-update/ CHANGELOG.md 2>/dev/null || true)"
  fi
  if [ -n "$stat_info" ]; then
    info "Resumen git del espejo (referencia para el changelog):"
    printf '%s\n' "$stat_info"
  fi

  # CHANGELOG.md objetivo: override | ../ respecto del motor (raíz del repo) | junto al motor.
  clfile="${CIZEN_CHANGELOG_FILE:-}"
  if [ -z "$clfile" ]; then
    if [ -f "$SCRIPT_DIR/../CHANGELOG.md" ]; then
      clfile="$SCRIPT_DIR/../CHANGELOG.md"
    else
      clfile="$SCRIPT_DIR/CHANGELOG.md"
    fi
  fi
  if [ ! -f "$clfile" ]; then
    mkdir -p -- "$(dirname -- "$clfile")" 2>/dev/null || { err "No se pudo localizar/crear $clfile; usa CIZEN_CHANGELOG_FILE."; return 1; }
    : > "$clfile"
  fi

  log "Preparando bump v$cur -> v$new con borrador de changelog ($ts) en $clfile..."
  tmp="$(mktemp "${SCRIPT_DIR}/.kernel-update-XXXXXX")" || return 1
  awk -v new="$new" '
    NR<=3 && $0 ~ /^# kernel-update\.sh — Cizen v/ {
      sub(/Cizen v[0-9]+[.][0-9]+[.][0-9]+/, "Cizen v" new)
      print; next
    }
    $0 ~ /^SCRIPT_VERSION="[0-9]+[.][0-9]+[.][0-9]+"$/ {
      sub(/SCRIPT_VERSION="[0-9]+[.][0-9]+[.][0-9]+"/, "SCRIPT_VERSION=\"" new "\"")
      print; next
    }
    { print }
  ' "$0" > "$tmp" || { rm -f -- "$tmp"; err "Fallo al generar el borrador del motor."; return 1; }
  if ! bash -n -- "$tmp" 2>/dev/null; then
    err "El borrador del motor no pasa bash -n; no se aplica."
    rm -f -- "$tmp"
    return 1
  fi
  chmod --reference="$0" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$0" || { rm -f -- "$tmp"; err "No se pudo reemplazar el motor."; return 1; }

  cltmp="$(mktemp "${SCRIPT_DIR}/.changelog-XXXXXX")" || return 1
  {
    printf '## [%s] - %s\n\n' "$new" "$ts"
    printf 'En desarrollo — RELLENAR: describe qué cambia frente a la v%s.\n\n' "$cur"
    if [ -n "$stat_info" ]; then
      printf 'Referencia del espejo git (diff --stat):\n\n```\n%s\n```\n\n' "$stat_info"
    fi
    cat -- "$clfile"
  } > "$cltmp"
  if ! mv -f -- "$cltmp" "$clfile"; then
    rm -f -- "$cltmp"
    err "No se pudo escribir el borrador en $clfile."
    return 1
  fi
  ok "Bumpeado a v$new: banner+SCRIPT_VERSION en $0 y borrador al top de $clfile."
  ok "Completa el texto del changelog y sincroniza el espejo: cp \"$0\" \"$mirror/kernel-update.sh\""
  return 0
}

# ============================================================
# DECISIÓN SOBRE RELEASE MÁS NUEVA
# ============================================================
confirm_newer_release() {
  local requested="$1" latest="$2" answer saved_tagrel="${CACHYOS_TAGREL:-}"

  # v27.31.18: no ofrezcas una versión que este build no puede compilar. Con
  # pds/bmq/lfbmq/muqss (o --tree cachyos) el árbol de fuentes es el fork, y el
  # fork va con retraso respecto a kernel.org: el menú acababa de ofrecer su
  # release (7.2.7) y acto seguido el motor preguntaba otra vez por la stable
  # (7.2.8). Aceptar solo servía para morir más tarde en resolve_cachyos_release,
  # ya descargada la config y montado el preámbulo. Ahora se consulta al fork y,
  # si no tiene esa versión, se explica y se conserva la solicitada.
  if [ "${KERNEL_TREE:-}" = "cachyos" ]; then
    if cachyos_release_tagrel "$latest"; then
      info "El fork CachyOS/linux sí publica $latest (cachyos-${latest}-${CACHYOS_TAGREL}): se puede compilar."
      CACHYOS_TAGREL="$saved_tagrel"
    elif [ "$CACHYOS_API_OK" = 1 ]; then
      # Respuesta real del fork ("no lo tiene") + ningún .asc candidato: aquí
      # sí se puede afirmar la ausencia, que es lo que hace útil el aviso.
      warn "El fork CachyOS/linux aún no publica $latest y este build compila contra su árbol (${TREE_FORCE_NOTE:---tree cachyos}); no se ofrece porque la compilación abortaría."
      if [ -n "$CACHYOS_LATEST_MINOR" ] && [ "$CACHYOS_LATEST_MINOR" != "$requested" ]; then
        info "Su última ${latest%.*}.x publicada es $CACHYOS_LATEST_MINOR: pide esa con este scheduler, o usa eevdf para compilar $latest vanilla desde kernel.org."
      fi
      CACHYOS_TAGREL="$saved_tagrel"
      return 1
    else
      # Check inconcluso (red/rate-limit): no se puede afirmar la ausencia, así
      # que no se esconde la opción; si el fork no la tiene, lo dirá después
      # resolve_cachyos_release con su diagnóstico.
      info "No se pudo comprobar en el fork CachyOS/linux si publica $latest; se ofrece igualmente."
      CACHYOS_TAGREL="$saved_tagrel"
    fi
  fi

  if ! [ -t 0 ] && ! [ -t 1 ]; then
    warn "Hay una release estable más nueva: $requested → $latest, pero no hay terminal interactiva; se conserva la versión solicitada."
    return 1
  fi

  printf '\n'
  printf '  Hay una release estable más nueva de kernel.org: %s → %s\n' "$requested" "$latest"
  read -r -p "  ¿Deseas compilar la versión más nueva ($latest)? [S/n] " answer < /dev/tty || answer="n"
  case "${answer:-s}" in
    s|S|si|SI|Sí|sí|y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Confirma antes de recompilar la versión ya instalada cuando no hay una release
# estable nueva. Devolver 0 -> continuar con la recompilación; 1 -> no hacer nada.
confirm_recompile_current() {
  local version="$1" answer

  if ! [ -t 0 ] && ! [ -t 1 ]; then
    warn "No hay una release estable nueva y no hay terminal interactiva; se cancela (no se recompila $version)."
    return 1
  fi

  printf '\n'
  printf '  No hay una release estable nueva para compilar.\n'
  read -r -p "  ¿Quieres continuar con la recompilación del kernel $version? [S/n] " answer < /dev/tty || answer="n"
  case "${answer:-s}" in
    s|S|si|SI|Sí|sí|y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# ============================================================
# INICIO PRINCIPAL
# ============================================================
T_ALL="$(date +%s)"
PKG=""
PKG_NAME=""
PKG_VERSION=""

# Modos de mantenimiento sin sudo/red/descarga: se ejecutan pronto y salen.
if [ "$HARDENED_AUDIT" = true ]; then
  run_hardened_audit || exit 1
  exit 0
fi
if [ "$SELFTEST" = true ]; then
  run_selftest || exit 1
  exit 0
fi
if [ "$DO_CHANGELOG" = true ]; then
  changelog_bump || exit 1
  exit 0
fi

prepare_dirs
ensure_config_dir_writable
check_prerequisites

# BTF (por defecto activo): necesita pahole para el .BTF. Si no se consigue se
# degrada a sin-BTF; se reconstruyen los arrays efectivos por si el BTF se
# desactivó.
if [ "$BTF_REQUESTED" = true ]; then
  ensure_optional_pahole
  build_effective_arrays
fi

# v27.31.18: el árbol se decide ANTES de preguntar por la release más nueva,
# porque de él depende si esa versión se puede compilar: con pds/bmq/lfbmq/muqss
# (o --tree cachyos) solo vale lo que el fork haya publicado, y ofrecer la stable
# de kernel.org cuando el fork va con retraso terminaba en fatal. La función es
# pura (CIZEN_KERNEL_TREE + PATCH_NAMES) e idempotente: aquí y más abajo.
resolve_kernel_tree

# Con una versión explícita, kernel.org se consulta antes de descargar.
# Si existe una stable posterior, se pregunta una sola vez y la respuesta
# determina VERSION. A partir de ese punto todo el flujo usa esa versión.
if [ -n "$VERSION" ]; then
  resolve_latest_release
  if version_gt "$REMOTE_STABLE_VERSION" "$VERSION"; then
    REQUESTED_VERSION="$VERSION"
    if confirm_newer_release "$REQUESTED_VERSION" "$REMOTE_STABLE_VERSION"; then
      VERSION="$REMOTE_STABLE_VERSION"
      ok "Versión seleccionada: $VERSION"
    else
      info "Se conserva la versión solicitada: $VERSION"
    fi
  fi
fi

if [ "$CHECK_UPDATE" = true ]; then
  [ -z "$VERSION" ] || fatal "--check-update no acepta una versión explícita."
  resolve_latest_release
  if [ -n "$LOCAL_KERNEL_VERSION" ] && version_gt "$REMOTE_STABLE_VERSION" "$LOCAL_KERNEL_VERSION"; then
    ok "Actualización disponible: $LOCAL_KERNEL_VERSION → $REMOTE_STABLE_VERSION"
  elif [ -n "$LOCAL_KERNEL_VERSION" ]; then
    ok "No hay actualización: Cizen=$LOCAL_KERNEL_VERSION kernel.org=$REMOTE_STABLE_VERSION"
  else
    info "Stable actual de kernel.org: $REMOTE_STABLE_VERSION (sin referencia Cizen local)"
  fi
  exit 0
fi

if [ -z "$VERSION" ]; then
    resolve_latest_release
    VERSION="$REMOTE_STABLE_VERSION"
    # kcheck sin versión siempre trabaja contra la stable actual; la regla
    # "no compilar si no hay actualización" aplica solo al flujo de build.
    if [ "$CHECK_ONLY" = false ] && [ -n "$LOCAL_KERNEL_VERSION" ] && ! version_gt "$VERSION" "$LOCAL_KERNEL_VERSION"; then
      if confirm_recompile_current "$LOCAL_KERNEL_VERSION"; then
        VERSION="$LOCAL_KERNEL_VERSION"
        ok "Se continúa con la recompilación de la versión instalada"
      else
        ok "Recompilación cancelada: no hay una release estable nueva para compilar."
        exit 0
      fi
    fi
  fi

# La versión ya está resuelta: a partir de aquí todas las rutas son deterministas.
# Primero se decide el árbol de fuentes: los schedulers PRJC/MuQSS (pds, bmq,
# lfbmq, muqss) solo existen como parches -cachy y exigen el fork CachyOS/linux.
# Antes, con todo PATCH_NAMES ya conocido: ntsync se añade solo si el kernel no
# tiene soporte nativo (v27.31.17; antes se decidiría antes de que existiría la
# función que compara versiones).
auto_add_ntsync_patch
# v27.31.18: el árbol ya se decidió antes de preguntar por la release más nueva
# (resolve_kernel_tree es idempotente) y aquí toca resolver el tag del fork para
# la versión definitiva.
if [ "$KERNEL_TREE" = "cachyos" ]; then
  resolve_cachyos_release "$VERSION"
fi
log "Árbol de fuentes: $KERNEL_TREE${TREE_FORCE_NOTE:+ ($TREE_FORCE_NOTE)}"

MAJOR="${VERSION%%.*}"
if [ "$KERNEL_TREE" = "cachyos" ]; then
  TARBALL="$KERNEL_BUILD_ROOT/cachyos-$VERSION-$CACHYOS_TAGREL.tar.gz"
  SIG_FILE="${TARBALL}.asc"
  SIG_URL="https://github.com/CachyOS/linux/releases/download/cachyos-$VERSION-$CACHYOS_TAGREL/cachyos-$VERSION-$CACHYOS_TAGREL.tar.gz.asc"
  SRC="$TMPFS_ROOT/linux-$VERSION"
  URL="https://github.com/CachyOS/linux/releases/download/cachyos-$VERSION-$CACHYOS_TAGREL/cachyos-$VERSION-$CACHYOS_TAGREL.tar.gz"
else
  TARBALL="$KERNEL_BUILD_ROOT/linux-$VERSION.tar.xz"
  SIG_FILE="${TARBALL}.sign"
  SIG_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-$VERSION.tar.sign"
  SRC="$TMPFS_ROOT/linux-$VERSION"
  URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-$VERSION.tar.xz"
fi

# Lock exclusivo. Mantemos una única operación para evitar carreras sobre el árbol persistente.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  fatal "Ya existe otra ejecución de kernel-update.sh en curso: $LOCK_FILE"
fi

log "Kernel Cizen v$SCRIPT_VERSION — perfil $PROFILE"
log "Objetivo  : $VERSION (check=$CHECK_ONLY force=$FORCE strict=$STRICT jobs=$JOBS prio=$BUILD_PRIORITY_LABEL sign=$SIGN_UKI)"
log "Cache/build: $KERNEL_BUILD_ROOT | $TMPFS_ROOT (${TMPFS_SIZE}, mín. ${TMPFS_MIN_FREE_MB} MB)"

if [ "$KEEP_SRC" = true ]; then
  info "--keep-src: las fuentes ya se conservan siempre en el tmpfs entre ejecuciones; esta bandera no cambia el comportamiento."
fi

# v27.31.27: preflight en vez de `sudo -v` a pelo. Antes, una contraseña mal
# tecleada abortaba con "Error 1 en línea 8614: sudo -v" sin explicación, y sin
# ticket no se puede ni montar el tmpfs ni instalar. Ahora o hay ticket, o se
# explica qué falta y se sigue solo si el allowlist NOPASSWD lo cubre todo.
preflight_sudo

# Verificación temprana de que las operaciones privilegiadas (mount/umount,
# pacman, escritura en el ESP, etc.) están permitidas por sudo, antes de
# gastar minutos en descarga/compilación.
check_sudo_capabilities

# v27.31.17: reconciliar el tmpfs con este build ANTES de mirar memoria/espacio.
# (a) los árboles de otra versión o de otro tipo (vanilla<->cachyos, decided
# por el parche/scheduler) no se reutilizan nunca, y (b) si no queda nada
# aprovechable se desmonta el tmpfs para devolver la RAM. El chequeo de espacio
# de check_build_memory y de prepare_tmpfs_build ya solo considera reutilizable
# un árbol cuya identidad coincide con la de este build.
reconcile_tmpfs_trees
check_build_memory

# Solo se valida el punto de montaje dedicado de compilación. El /tmp global
# no participa en la lógica de validación ni se modifica.
#
# IMPORTANTE: cleanup_old_source_trees() corre ANTES de prepare_tmpfs_build(),
# porque este último comprueba el espacio libre del tmpfs (TMPFS_MIN_FREE_MB).
# Si quedó un árbol de una versión distinta de una ejecución anterior, hay
# que liberarlo primero para no abortar por falta de espacio que esta misma
# limpieza iba a resolver segundos después.
cleanup_kernel_cache
check_disk_space
cleanup_old_source_trees
prepare_tmpfs_build

# Verificación final del punto de montaje dedicado.
# IMPORTANTE: findmnt normalmente NO imprime "exec" cuando exec es la opción
# por defecto; por eso no debe interpretarse la ausencia de "exec" como noexec.
# Comprobamos además la ejecución real de un binario pequeño dentro del tmpfs.
if ! tmpfs_is_mounted; then
  fatal "El tmpfs dedicado de compilación no quedó montado correctamente: $TMPFS_ROOT"
fi
TMPFS_FINAL_FS="$(findmnt -n -M "$TMPFS_ROOT" -o FSTYPE 2>/dev/null | head -n1 || true)"
TMPFS_FINAL_OPTS="$(findmnt -n -M "$TMPFS_ROOT" -o OPTIONS 2>/dev/null | head -n1 || true)"
[ "$TMPFS_FINAL_FS" = "tmpfs" ] || fatal "El punto de compilación no es tmpfs: $TMPFS_ROOT"

case ",${TMPFS_FINAL_OPTS}," in
  *,noexec,*)
    fatal "El tmpfs de compilación está montado con noexec; se aborta antes del chequeo/build."
    ;;
esac

TMPFS_EXEC_TEST="$TMPFS_ROOT/.cizen-exec-test-$TS"
if ! cp /bin/true "$TMPFS_EXEC_TEST" 2>/dev/null; then
  fatal "No se pudo copiar el binario de prueba al tmpfs de compilación."
fi
chmod 0755 "$TMPFS_EXEC_TEST" 2>/dev/null || { rm -f "$TMPFS_EXEC_TEST"; fatal "No se pudo preparar el binario de prueba en el tmpfs."; }
if ! "$TMPFS_EXEC_TEST" >/dev/null 2>&1; then
  rm -f "$TMPFS_EXEC_TEST"
  fatal "El tmpfs de compilación no permite ejecutar binarios; se aborta antes del chequeo/build."
fi
rm -f "$TMPFS_EXEC_TEST"
ok "tmpfs de compilación verificado (montaje + exec efectivo)"

# SRC y BUILD_MARKER ya apuntan al tmpfs objetivo; no es necesario reasignarlos.

# Tarball/extracción
get_tarball "$TARBALL" "$URL" || fatal "No se pudo obtener un tarball válido."
extract_tarball || fatal "No se pudo preparar el árbol de fuentes."

cd "$SRC"
ok "Fuentes listas: $SRC"
T_DL="$(date +%s)"

# Parches de terceros (v27.24.0): --patch / --bore / CIZEN_PATCHES. Se aplican
# antes de elegir la config base porque introducen símbolos Kconfig nuevos que
# deben existir para que olddefconfig/validación los vean.
if [ "${#PATCH_NAMES[@]}" -gt 0 ]; then
  for __patch in "${PATCH_NAMES[@]}"; do
    if apply_patch_plugin "$__patch"; then
      # Reconstruir arrays efectivos para que build_effective_arrays active los
      # símbolos del parche y los marque como esperados (no ensucia kcheck ni
      # bloquea con --strict).
      build_effective_arrays
    else
      warn "Parche $__patch no aplicado; la build continúa vanilla."
    fi
  done
  unset __patch
fi

# Parches propios del usuario (v27.30.0): .patch/.diff propios sobre el árbol
# vanilla. Fallo = fatal: es el usuario quien los firmó.
apply_user_patches

# Pack misc de CachyOS (v27.30.0): island patches best-effort (fail-soft por
# parche). No rompen nunca la build: si no aplican, se avisa y se sigue.
apply_cachy_misc_patchset

# Config Cizen primero; /proc/config.gz o /boot/config como fallback.
choose_base_config

# Modo lite (único modo de compilación): adelgazar la config para NO compilar
# los módulos que la poda descartaría. Se hace ANTES de aplicar el perfil: los
# requests de ENABLE/CRITICAL/DISABLE se re-fuerzan después y la auditoría
# valida el resultado.
prepare_lite_config

# Crear marcador justo antes de aplicar/configurar/compilar.
touch "$BUILD_MARKER"

# Aplicar perfil (con overlay de compilación inyectado en los arrays efectivos).
inject_build_overlay
apply_config_requests || fatal "Falló scripts/config al aplicar el perfil."
apply_config_fragments || fatal "Falló scripts/config al aplicar los frags."
apply_cachy_misc_symbols

# Auditoría oficial Kconfig.
run_kconfig_audit || fatal "Auditoría Kconfig fallida."

# La configuración de HOME se promociona SOLO después de superar toda la
# validación. Así un --check fallido jamás sustituye la base estable.
validate_config || {
  rc=$?
  fatal "Validación de configuración fallida (rc=$rc). No se compila."
}

# --absorb-rebels: si Kconfig conservó desactivaciones que aún no estaban en
# EXPECTED_REBELS, muévelas al perfil (con backup) y revalida con los arrays
# recargados para que este mismo chequeo termine limpio y la próxima ejecución
# no reproduzca los warnings.
if [ "$ABSORB_REBELS" = true ] && [ "${#DISABLE_WARN[@]}" -gt 0 ]; then
  if absorb_rebels_to_profile; then
    source "$PROFILE_FILE"
    load_profile
    build_effective_arrays
    check_profile_contradictions
    log "Re-validando con el perfil actualizado (símbolos absorbidos)..."
    validate_config || {
      rc=$?
      fatal "Re-validación tras --absorb-rebels fallida (rc=$rc)."
    }
  else
    warn "--absorb-rebels no pudo completarse; se continúa con la validación previa."
  fi
fi

# Absorción interactiva de rebeldes (v27.25.1): si la auditoría reportó
# desactivaciones que Kconfig conserva y el run no es --strict (que aborta) ni
# venimos de --absorb-rebels explícito, se ofrece absorberlas a EXPECTED_REBELS
# antes de decidir compilar. Es una mutación persistente del perfil: requiere
# confirmación explícita en terminal y jamás se aplica sin ella.
confirm_absorb_rebels() {
  local cnt="$1" answer

  if ! [ -t 0 ] && ! [ -t 1 ]; then
    warn "Sin terminal interactiva; no se absorben rebeldes automáticamente (usa --absorb-rebels)."
    return 1
  fi

  echo
  while true; do
    read -r -t 300 -p "  Kconfig conserva $cnt desactivaciones del perfil. ¿Absorberlas a EXPECTED_REBELS (auditoría limpia)? [S/n] " answer < /dev/tty || answer="n"
    case "${answer:-s}" in
      s|S|si|SI|sí|Sí|Si|y|Y|yes|YES)
        return 0
        ;;
      n|N|no|NO)
        return 1
        ;;
      *)
        warn "Respuesta no válida. Responda S, N o simplemente presione Enter."
        ;;
    esac
  done
}

if [ "$ABSORB_REBELS" = false ] && [ "$STRICT" = false ] && [ "${#DISABLE_WARN[@]}" -gt 0 ]; then
  if confirm_absorb_rebels "${#DISABLE_WARN[@]}"; then
    if absorb_rebels_to_profile; then
      source "$PROFILE_FILE"
      load_profile
      build_effective_arrays
      check_profile_contradictions
      log "Re-validando con el perfil actualizado (símbolos absorbidos)..."
      validate_config || {
        rc=$?
        fatal "Re-validación tras absorción interactiva fallida (rc=$rc)."
      }
    else
      warn "No se pudieron absorber los rebeldes; se continúa con la validación previa."
    fi
  fi
fi

verify_build_tree
report_config_diff
T_CFG="$(date +%s)"

# kcfg / --menuconfig (opcional): edición visual de la config ya validada.
# Se hace tras la absorción de rebeldes y ANTES de promover la config base.
menuconfig_edit

promote_base_config() {
  local src="$1" dst="$2" tmp
  [ -f "$src" ] || fatal "No existe la configuración efectiva a promover: $src"
  tmp="${dst}.tmp-${TS}"
  rm -f -- "$tmp"
  cp -f -- "$src" "$tmp"
  chmod 0644 "$tmp"
  # La promoción es atómica: el archivo estable solo aparece cuando la copia
  # completa ya existe. Si mv falla, el archivo anterior no se toca.
  mv -f -- "$tmp" "$dst"
}

confirm_build_after_check() {
  local answer

  if ! [ -t 0 ] && ! [ -t 1 ]; then
    warn "Validación completada sin terminal interactiva; no se inicia la compilación automáticamente."
    return 1
  fi

  echo
  while true; do
    read -r -t 300 -p "  ¿Desea continuar con la compilación del kernel $VERSION? [S/n] " answer < /dev/tty || answer="n"
    case "${answer:-s}" in
      s|S|si|SI|sí|Sí|Si|y|Y|yes|YES)
        return 0
        ;;
      n|N|no|NO)
        return 1
        ;;
      *)
        warn "Respuesta no válida. Responda S, N o simplemente presione Enter."
        ;;
    esac
  done
}

# Variante de compilación en modo check (v27.28.0): tras confirmar que se desea
# compilar, si no se pidió ningún parche explícito (--patch bore, --bore,
# CIZEN_PATCHES, CIZEN_ENABLE_BORE) se ofrece elegir entre Vanilla (scheduler
# EEVDF estándar) y BORE (Burst-Oriented Response Enhancer). Elegir BORE aplica
# el parche en este punto y re-valida la config (olddefconfig + perfil +
# auditoría + validación) para que la compilación arranque con una configuración
# coherente; la base promovida tras el check queda alineada con la variante.
# Aplica un parche concreto y re-corre la cadena completa olddefconfig +
# perfil (overlay) + frags + auditoría + validación, tras materializar los
# símbolos del parche en los arrays efectivos. V27.30.0: generaliza la cadena
# que antes solo sabía de BORE para soportar PDS/BMQ/LFBMQ/MUQSS.
apply_patch_and_recheck() {
  local __pn="$1"
  if ! apply_patch_plugin "$__pn"; then
    return 1
  fi
  build_effective_arrays
  check_profile_contradictions
  log "Reconfigurando con ${PATCH_DISP_NAME:-$__pn} aplicado (olddefconfig + perfil + auditoría + validación)..."
  if ! make "${KCONFIG_CC_OPTS[@]}" olddefconfig; then
    err "olddefconfig falló tras aplicar ${PATCH_DISP_NAME:-$__pn}."
    return 1
  fi
  inject_build_overlay
  apply_config_requests || { err "scripts/config falló al re-aplicar el perfil con ${PATCH_DISP_NAME:-$__pn}."; return 1; }
  apply_config_fragments || { err "frags fallaron tras ${PATCH_DISP_NAME:-$__pn}."; return 1; }
  run_kconfig_audit || { err "Auditoría Kconfig tras aplicar ${PATCH_DISP_NAME:-$__pn} fallida."; return 1; }
  validate_config || {
    local rc=$?
    err "Re-validación tras aplicar ${PATCH_DISP_NAME:-$__pn} fallida (rc=$rc)."
    return 1
  }
  ok "${PATCH_DISP_NAME:-$__pn} aplicado y configuración re-validada."
  return 0
}

choose_build_variant_after_check() {
  local choice __pn=""

  if [ "${#PATCH_NAMES[@]}" -gt 0 ]; then
    log "Variante ya solicitada explícitamente (${PATCH_NAMES[*]}); se omite la pregunta."
    return 0
  fi

  if [ "$NO_ASK_VARIANT" = true ]; then
    log "Variante ya elegida por quien invoca el motor (--no-ask-variant); se omite la pregunta."
    return 0
  fi

  if ! [ -t 0 ] && ! [ -t 1 ]; then
    warn "Sin terminal interactiva; se continúa con la variante Vanilla."
    return 0
  fi

  echo
  printf '  1) Vanilla (EEVDF)\n  2) BORE\n  3) PDS (prjc)\n  4) BMQ (prjc)\n  5) LFBMQ (prjc)\n  6) MuQSS\n'
  while true; do
    read -r -t 300 -p "  Elija la variante de compilación [1] > " choice < /dev/tty || choice=""
    case "${choice:-1}" in
      1|vanilla|Vanilla|v|V|eevdf|EEVDF)
        ok "Variante Vanilla (scheduler EEVDF estándar)."
        return 0
        ;;
      2|bore|Bore|b|B)              __pn="bore";   break ;;
      3|pds|PDS|p|P)                __pn="pds";    break ;;
      4|bmq|BMQ|q|Q)                __pn="bmq";    break ;;
      5|lfbmq|LFBMQ|l|L)            __pn="lfbmq";  break ;;
      6|muqss|Muqss|MUQSS|m|M)      __pn="muqss";  break ;;
      *)
        warn "Respuesta no válida. Responda 1-6, un nombre (b/p/q/l/m) o Enter para Vanilla."
        ;;
    esac
  done

  if [ -n "$__pn" ]; then
    PATCH_NAMES+=("$__pn")
    if apply_patch_and_recheck "$__pn"; then
      ok "Se compilará con el scheduler ${PATCH_DISP_NAME:-$__pn}."
    else
      warn "No se pudo aplicar '$__pn'; se continúa compilando Vanilla (EEVDF)."
    fi
  fi
  return 0
}

if [ "$CHECK_ONLY" = true ]; then
  if confirm_build_after_check; then
    choose_build_variant_after_check
    ok "Perfecto. La configuración está validada; continuamos con la compilación de $VERSION."
    CHECK_ONLY=false
  else
    FINAL_CONFIG="$CONFIG_DIR/linux-$VERSION-cizen-v3.config"
    promote_base_config .config "$FINAL_CONFIG"
    ok "CHECK EXITOSO: configuración promovida a $FINAL_CONFIG"
    echo
    ok "Todo listo para compilar cuando lo desees; la configuración quedó validada y las fuentes esperan en su sitio."
    cleanup_success
    exit 0
  fi
fi

# Firma de la UKI (Secure Boot): nueva opción sugerida en la solicitud de
# compilación (build directo o transformado desde --check). En auto se pregunta
# si hay sbctl y Secure Boot desactivado; con SB activo se firma siempre.
resolve_sign_uki

# Auditoría de disco cifrado (opción --luks-audit): se ejecuta tras la
# instalación; la definición está más adelante en el flujo principal.

# ============================================================
# COMPILACIÓN
# ============================================================
declare -a MAKE_CC_OPTS=()
# El compilador elegido (--cc) es vinculante: LLVM=1 solo para la familia clang;
# en GCC genérico se deja que Kbuild resuelva CC por PATH, y con un binario
# concreto (gcc-14 / clang-17 / ruta) se fuerza siempre CC/HOSTCC a ese binario.
if [ "$CC_FAMILY" = "clang" ]; then
  MAKE_CC_OPTS+=('LLVM=1')
  export LLVM=1
fi
if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
  # Tuning (no destructivo, silencioso):
  #  - base_dir=$HOME: los hits no dependen del cwd donde se compila
  #  - max_size: límite opcional vía CCACHE_MAX_SIZE (cosa por defecto)
  #  - compiler_check=content: hash del binario del compilador, no del path
  ccache -o base_dir="$HOME" >/dev/null 2>&1 || true
  ccache -o compiler_check=content >/dev/null 2>&1 || true
  if [ -n "${CCACHE_MAX_SIZE:-}" ]; then
    ccache -o max_size="$CCACHE_MAX_SIZE" >/dev/null 2>&1 || true
  fi
  MAKE_CC_OPTS+=(
    "CC=ccache $CC_LAUNCHER"
    "HOSTCC=ccache $CC_LAUNCHER"
  )
  # No fijamos KBUILD_BUILD_TIMESTAMP. Kbuild utilizará la fecha/hora real
  # de compilación, evitando que uname -a muestre una fecha artificial.
  # La reproducibilidad temporal puede activarse explícitamente desde el
  # entorno si el usuario exporta KBUILD_BUILD_TIMESTAMP antes de ejecutar.
  ok "ccache activo: $CCACHE_DIR (CC/HOSTCC=$CC_LAUNCHER; timestamp de build real)"
else
  warn "ccache no instalado; compilación normal."
  case "$CC_LAUNCHER" in
    gcc|clang) ;;   # Kbuild resuelve el genérico por PATH
    *) MAKE_CC_OPTS+=("CC=$CC_LAUNCHER" "HOSTCC=$CC_LAUNCHER") ;;
  esac
fi

export KCFLAGS="${KCFLAGS:--pipe}"

# Perfil de compilación extendido: arquitectura objetivo en KCFLAGS
# (processor_opt). generic = baseline x86-64; native = -march=native; cualquier
# otro valor válido (znver4, skylake, x86-64-v3, ...) se pasa tal cual. Solo
# afecta a código C del kernel: -O3/HZ/LTO se gestionan vía CONFIG.
case "$CIZEN_CPU_OPT" in
  inherit)
    :
    ;;
  generic)
    export KCFLAGS="${KCFLAGS:--pipe} -march=x86-64"
    ok "Optimización de CPU: baseline x86-64 (generic)."
    ;;
  native)
    export KCFLAGS="${KCFLAGS:--pipe} -march=native"
    ok "Optimización de CPU: -march=native (el build solo será portable en ESTA máquina)."
    ;;
  *)
    export KCFLAGS="${KCFLAGS:--pipe} -march=$CIZEN_CPU_OPT"
    ok "Optimización de CPU: -march=$CIZEN_CPU_OPT"
    ;;
esac

# Build con LLVM/Clang (LLVM=1): CC=clang, ld.lld, llvm-ar/nm, etc. La toolchain
# ya se exigió e instaló como dependencia obligatoria en check_prerequisites por
# el compilador de preferencia (--clang / --cc familia clang / LTO → jamás se
# degrada a gcc); esta sanidad solo es una red de seguridad.
CLANG_BUILD=false
if [ "$CLANG_REQUESTED" = true ]; then
  if command -v "$CC_LAUNCHER" >/dev/null 2>&1; then
    CLANG_BUILD=true
    ok "Compilación con LLVM/Clang (LLVM=1; $CC_LAUNCHER)."
  else
    fatal "clang/ld.lld no están disponibles pese a exigirse como dependencia (sudo pacman -S clang lld)."
  fi
fi

# Límite máximo configurable para la compilación. 1 h cubre con margen
# una build completa en una máquina seca (cold ~19 min, warm ~4 min),
# pero permite abortar una build realmente colgada. Configurable vía
# BUILD_TIMEOUT si un build legítimo necesitara más tiempo.
BUILD_TIMEOUT="${BUILD_TIMEOUT:-3600}"
[[ "$BUILD_TIMEOUT" =~ ^[0-9]+$ ]] || fatal "BUILD_TIMEOUT inválido: $BUILD_TIMEOUT (use segundos enteros)."
(( BUILD_TIMEOUT > 0 )) || fatal "BUILD_TIMEOUT debe ser > 0 segundos."

# v27.30.0: empaquetado multi-backend. El flujo pacman/makepkg (pkgrel,
# overrides del PKGBUILD, poda, identity) es específico de Arch; los demás
# backends generan el artefacto nativo de su formato.
case "$CIZEN_PKG_BACKEND" in
  arch)
    determine_pkgrel
    prepare_package_identity_override
    prepare_package_revision_override
    prepare_package_pruning_override
    ;;
  *)
    PKGVER_BASE="${VERSION}-cizen-v3"
    PKGREL=1
    info "Backend $CIZEN_PKG_BACKEND: pkgrel fijado a 1 (el contador de pkgrel es específico de pacman)."
    ;;
esac
case "$CIZEN_PKG_BACKEND" in
  arch) PKG_MAKE_TARGET="pacman-pkg" ;;
  deb)  PKG_MAKE_TARGET="deb-pkg"    ;;
  rpm)  PKG_MAKE_TARGET="rpm-pkg"    ;;
  generic|gentoo) PKG_MAKE_TARGET="targz-pkg" ;;
esac

log "Compilando con $JOBS hilos (pkgrel=$PKGREL)..."
START="$(date +%s)"

export KBUILD_REVISION="$PKGREL"
# Fuerza el pkgbase Cizen en makepkg sin depender del entorno heredado del usuario.
# El PKGBUILD oficial de kbuild soporta PACMAN_PKGBASE y lo utiliza para formar
# pkgname/pkgbase y el identificador que termina en /usr/lib/modules/<release>/pkgbase.
export PACMAN_PKGBASE="$CIZEN_PKGBASE"
# Poda de módulos: estas variables llegan a package() bajo fakeroot vía makepkg.
export CIZEN_PRUNE_MODULES="${CIZEN_PRUNE_MODULES:-$PRUNE_MODULES}"
export CIZEN_PRUNE_SCRIPT="${CIZEN_PRUNE_SCRIPT:-$PRUNER_SCRIPT}"
export CIZEN_KEEP_MODULES="${CIZEN_KEEP_MODULES:-}"
# v27.25.5: makepkg aborta con "El grupo de paquetes ya se ha compilado" si en el
# árbol quedan .pkg.tar.zst del mismo pkgver/pkgrel de una build previa. Se
# retiran los obsoletos antes de empaquetar; esta ejecución los regenera.
while IFS= read -r -d '' __oldpkg; do
  rm -f -- "$__oldpkg"
done < <(find "$SRC" -maxdepth 1 -type f -name "$CIZEN_PKGBASE-*.pkg.tar.zst" -print0)
unset __oldpkg
sudo_keepalive_start
build_rc=0
# Cgroup dedicado para la compilación: systemd-run --scope coloca make en un
# scope propio con CPUWeight/IOWeight según la prioridad configurada (normal =
# peso 100/100; low = 30/1, dando la CPU a ~todo el sistema). Si systemd-run
# no existe o el probe de delegación cgroup falla, se degrada a nice/ionice.
SCOPE_RUNNER=()
if command -v systemd-run >/dev/null 2>&1 && [ -d /sys/fs/cgroup ]; then
  case "$BUILD_PRIORITY" in
    normal) cpu_w=100; io_w=100 ;;
    *)      cpu_w=30;  io_w=1 ;;
  esac
  if systemd-run --scope --quiet --unit="cizen-probe-$$.scope" \
       --property="CPUWeight=$cpu_w" --property="IOWeight=$io_w" true 2>/dev/null; then
    SCOPE_RUNNER=(systemd-run --scope --quiet --unit="k-update-${TS}-build.scope" \
      --property="CPUWeight=$cpu_w" --property="IOWeight=$io_w")
    info "Compilación en scope cgroup dedicado (CPUWeight=$cpu_w, IOWeight=$io_w)."
  else
    warn "systemd-run --scope no puede delegar el cgroup; se intentan los nice/ionice clásicos."
  fi
fi
# Sin scope cgroup (systemd-run ausente, sin delegación o probe fallido): en
# prioridad baja se enganchan aquí los nice/ionice ya preparados en
# BUILD_PRIORITY_WRAP, que AHORA SÍ entran en la línea de make (antes solo se
# anunciaban en un warn). Con BUILD_PRIORITY=normal el array queda vacío y la
# build corre sin acotación, como es la intención.
if [ "${#SCOPE_RUNNER[@]}" -eq 0 ] && [ "${#BUILD_PRIORITY_WRAP[@]}" -gt 0 ]; then
  SCOPE_RUNNER=("${BUILD_PRIORITY_WRAP[@]}")
  warn "Compilación con nice/ionice clásicos (${BUILD_PRIORITY_WRAP[*]})."
fi
# Notificación de escritorio al terminar (build ok / build rota). Obvia si el
# binario no existe o si CIZEN_NOTIFY=0.
notify_desktop() {
  [ "${CIZEN_NOTIFY:-1}" = "1" ] || return 0
  command -v "${CIZEN_NOTIFY_BIN:-notify-send}" >/dev/null 2>&1 || return 0
  DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
    "${CIZEN_NOTIFY_BIN:-notify-send}" -a 'Kernel Updater' -u normal -t 15000 "$1" "$2" >/dev/null 2>&1 || true
}
# --foreground: hace que make corra en el MISMO grupo de procesos de la
# terminal. Sin él, timeout(1) crea un grupo propio para make, aislado del
# foreground de la terminal, de modo que Ctrl+C (SIGINT al grupo foreground)
# solo llegaba al script y NO cancelaba la compilación. Con --foreground,
# Ctrl+C llega directo a make (que ya tiene traps INT/TERM y remata sus .o y
# sub-makes), permitiendo cancelar la build en cualquier momento.
# NOTA: se usa "${SCOPE_RUNNER[@]}" (no "${SCOPE_RUNNER[@]:-}"): con el array
# vacío la variante :- expande a UN argumento vacío y el make abortaría con
# "command not found"; la forma sin :- expande a CERO palabras y timeout recibe
# solo sus argumentos. SCOPE_RUNNER siempre está declarado (arriba), así que
# set -u no dispara.
if time "${SCOPE_RUNNER[@]}" timeout --foreground --signal=TERM --kill-after=60s "$BUILD_TIMEOUT" \
    make -j"$JOBS" "${MAKE_CC_OPTS[@]}" KBUILD_REVISION="$PKGREL" "$PKG_MAKE_TARGET"; then
  :
else
  build_rc=$?
  restore_package_revision_override || true
  restore_package_identity_override || true
  sudo_keepalive_stop
  if [ "$build_rc" -eq 124 ]; then
    err "Compilación agotó el tiempo máximo (${BUILD_TIMEOUT}s)."
  else
    err "Compilación falló (rc=$build_rc)."
  fi
  err "Fuentes conservadas en: $SRC"
  notify_desktop "Kernel Cizen: compilación FALLÓ" "$VERSION-cizen-v3 (rc=$build_rc); fuentes en $SRC"
  exit 1
fi

END="$(date +%s)"
DUR=$((END - START))
ok "Compilación completada en $((DUR/60))m $((DUR%60))s"
notify_desktop "Kernel Cizen: compilación terminada" "$VERSION-cizen-v3 ($((DUR/60))m $((DUR%60))s, $JOBS hilos; ahora instala/Uki)"
restore_package_revision_override
restore_package_identity_override

# Obtener sudo antes de modificar el sistema. Tras 20+ minutos de compilación el
# ticket ha caducado (sudo: 5 min por defecto), así que esta pregunta es
# legítima; lo que no vale es abortar con un "Error N en línea" y que parezca
# que se perdió el build: el paquete está en el tmpfs y se puede instalar a mano.
preflight_sudo "tras compilar"

# Snapshot btrfs readonly del root (feature 4). Red de seguridad opcional.
create_btrfs_snapshot

collect_build_artifact || fatal "No se pudo identificar/verificar el artefacto generado."
if [ "$CIZEN_PKG_BACKEND" = "arch" ]; then
  validate_split_package_transition_metadata
fi

# Evitar reinstalar exactamente el mismo paquete si ya está instalado.
if [ "$CIZEN_PKG_BACKEND" = "arch" ]; then
  if pacman -Q "$PKG_NAME" >/dev/null 2>&1; then
    INSTALLED_VERSION="$(pacman -Q "$PKG_NAME" | awk 'NR==1 {print $2}')"
  else
    INSTALLED_VERSION=""
  fi

  installed_rel=0
  if [ -n "$INSTALLED_VERSION" ] && [[ "$INSTALLED_VERSION" == "$PKGVER_BASE-"* ]]; then
    if [[ "$INSTALLED_VERSION" =~ ^${PKGVER_BASE}-([0-9]+)$ ]]; then
      installed_rel="${BASH_REMATCH[1]:-0}"
      if (( PKGREL <= installed_rel )); then
        # Único efecto real de --force en todo el script: permitir reinstalar
        # un pkgrel igual o menor al ya instalado. No afecta ninguna
        # validación crítica de Kconfig ni de auditoría (esas nunca se pueden
        # saltar, con o sin --force).
        if [ "$FORCE" = true ]; then
          warn "El pkgrel generado ($PKGREL) no es superior al instalado ($installed_rel) para $PKGVER_BASE; se continúa por --force."
        else
          fatal "El pkgrel generado ($PKGREL) no es superior al instalado ($installed_rel) para $PKGVER_BASE. Se aborta para no instalar un paquete más viejo (usa --force para omitir esta comprobación)."
        fi
      fi
    fi
  fi
else
  check_installed_release_generic
fi

log "Instalando $PKG_NAME-$PKG_VERSION ..."

# Archivar el kernel en ejecución antes de que pacman lo sustituya (feature 3).
prepare_rollback_archive

# --------------------------------------------------------------------
# Reparación segura de /var/lib/pacman/db.lck
#
# pacman no guarda de forma fiable un PID utilizable dentro de db.lck,
# por lo que la decisión correcta es comprobar primero si existe realmente
# una transacción/gestor de paquetes activo. Nunca se borra el lock si hay
# un pacman/ayudante ejecutándose: en ese caso esperamos y reintentamos.
# Si el lock existe pero no hay ningún gestor activo, se considera huérfano
# y se elimina automáticamente antes de reintentar la instalación.
# --------------------------------------------------------------------
PACMAN_LOCK="/var/lib/pacman/db.lck"
PACMAN_LOCK_WAIT_SEC="180"
PACMAN_RETRY_INTERVAL_SEC="2"
PACMAN_LOCK_SUSPECT_CURRENT=false
PACMAN_INSTALL_START_EPOCH=0
PACMAN_PREINSTALL_LOCK_MTIME=0

package_manager_pids() {
  # fuser consulta directamente al kernel quién mantiene abierto db.lck.
  # Esto cubre pacman, pamac-daemon, PackageKit y futuros frontends sin
  # depender de una lista fija de nombres de proceso.
  sudo fuser "$PACMAN_LOCK" 2>/dev/null || true
}

pacman_transaction_state() {
  local pids
  [ -e "$PACMAN_LOCK" ] || { echo "absent"; return 0; }
  pids="$(package_manager_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [ -n "$pids" ]; then
    echo "active:$pids"
  else
    echo "stale"
  fi
}

pacman_lock_mtime() {
  stat -c '%Y' "$PACMAN_LOCK" 2>/dev/null || echo 0
}

recover_pacman_lock() {
  local state elapsed pids lock_mtime
  elapsed=0

  while [ -e "$PACMAN_LOCK" ]; do
    state="$(pacman_transaction_state)"
    case "$state" in
      absent)
        return 0
        ;;
      stale)
        # Revalidación inmediata para reducir la ventana TOCTOU entre fuser
        # y rm. Si aparece un proceso, nunca eliminamos el lock.
        pids="$(package_manager_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        if [ -n "$pids" ]; then
          warn "El lock dejó de parecer huérfano durante la revalidación (PID: $pids); se espera."
          sleep "$PACMAN_RETRY_INTERVAL_SEC"
          elapsed=$((elapsed + PACMAN_RETRY_INTERVAL_SEC))
          continue
        fi

        lock_mtime="$(pacman_lock_mtime)"

        if [ "${PACMAN_INSTALL_START_EPOCH:-0}" -gt 0 ]; then
          if [ "$lock_mtime" -gt "${PACMAN_PREINSTALL_LOCK_MTIME:-0}" ] || \
             { [ "${PACMAN_PREINSTALL_LOCK_MTIME:-0}" -eq 0 ] && [ "$lock_mtime" -ge "${PACMAN_INSTALL_START_EPOCH}" ]; }; then
            warn "db.lck fue creado/modificado durante el intento de instalación actual; no se asume que sea un lock huérfano."
            warn "Se hará como máximo una reparación cautelosa; si pacman falló por otra causa, revisa su error antes de reintentar."
            PACMAN_LOCK_SUSPECT_CURRENT=true
          fi
        fi

        warn "Se detectó lock de pacman sin proceso que lo mantenga abierto: $PACMAN_LOCK"
        if [ "$PACMAN_LOCK_SUSPECT_CURRENT" = true ]; then
          warn "El lock coincide temporalmente con la instalación actual; se permite una única eliminación cautelosa."
        fi

        # Última comprobación justo antes del rm.
        pids="$(package_manager_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        [ -z "$pids" ] || {
          warn "Apareció un gestor justo antes de eliminar db.lck (PID: $pids); no se elimina."
          sleep "$PACMAN_RETRY_INTERVAL_SEC"
          elapsed=$((elapsed + PACMAN_RETRY_INTERVAL_SEC))
          continue
        }

        sudo rm -f -- "$PACMAN_LOCK" || fatal "No se pudo eliminar el lock de pacman: $PACMAN_LOCK"
        [ ! -e "$PACMAN_LOCK" ] || fatal "El lock de pacman sigue presente después de intentar repararlo: $PACMAN_LOCK"
        ok "Lock de pacman eliminado tras doble comprobación de actividad"
        return 0
        ;;
      active:*)
        pids="${state#active:}"
        if (( elapsed >= PACMAN_LOCK_WAIT_SEC )); then
          fatal "gestor de paquetes sigue activo (${pids}) y el lock no se libera después de ${PACMAN_LOCK_WAIT_SEC}s. No se elimina por seguridad: $PACMAN_LOCK"
        fi
        warn "Base de datos de pacman ocupada por gestor activo (PID: ${pids}); esperando..."
        sleep "$PACMAN_RETRY_INTERVAL_SEC"
        elapsed=$((elapsed + PACMAN_RETRY_INTERVAL_SEC))
        ;;
    esac
  done
}

install_kernel_package() {
  local rc
  local attempt=1
  local max_attempts=$((PACMAN_LOCK_WAIT_SEC / PACMAN_RETRY_INTERVAL_SEC + 1))

  # La versión de pacman disponible en este sistema no soporta
  # --resolve-conflicts=all. Como el paquete Cizen declara explícitamente
  # conflicts=("linux-upstream"), la migración debe retirar el paquete legado
  # de forma separada antes de la primera transacción -U. Se hace aquí, y no
  # antes, para que toda la preparación/build/verificación ya haya terminado.
  if pacman -Q "$LEGACY_PKGBASE" >/dev/null 2>&1; then
    log "Migración de paquete: retirando $LEGACY_PKGBASE antes de instalar $CIZEN_PKGBASE ..."
    local remove_out
    if remove_out="$(sudo pacman -R --noconfirm "$LEGACY_PKGBASE" 2>&1)"; then
      ok "Paquete legado retirado: $LEGACY_PKGBASE"
    elif printf '%s\n' "$remove_out" | grep -Fq "target not found: $LEGACY_PKGBASE"; then
      # pacman -Q lo vio instalado un instante antes, pero para cuando se
      # intentó retirar ya no estaba (otra transacción concurrente, o una
      # migración parcial de una ejecución previa que ya lo había quitado).
      # El estado deseado -$LEGACY_PKGBASE fuera del sistema- ya se cumple,
      # así que esto no es un fallo real: se continúa con la instalación.
      warn "$LEGACY_PKGBASE ya no estaba instalado al intentar retirarlo; se continúa sin tratarlo como error."
      printf '%s\n' "$remove_out" >&2
    else
      err "No se pudo retirar $LEGACY_PKGBASE; se cancela la instalación de $CIZEN_PKGBASE."
      printf '%s\n' "$remove_out" >&2
      return 1
    fi
  fi

  while (( attempt <= max_attempts )); do
    if sudo pacman -U "$PKG" --noconfirm; then
      return 0
    else
      rc=$?
    fi
    if [ ! -e "$PACMAN_LOCK" ]; then
      return "$rc"
    fi

    # Solo entrar aquí cuando el fallo coincide con un lock aún presente.
    recover_pacman_lock
    if [ "$PACMAN_LOCK_SUSPECT_CURRENT" = true ] && (( attempt >= 2 )); then
      err "No se repite automáticamente la instalación: el db.lck apareció durante el intento actual."
      return "$rc"
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

# Comprueba que el release generado no esté ya instalado con un pkgrel igual o
# mayor que el del build actual (analogo al control pacman, para backends sin
# pacman mediante ras tronco de /usr/lib/modules).
check_installed_release_generic() {
  local rel
  rel="$(make -C "$SRC" -s kernelrelease 2>/dev/null || echo "$VERSION-cizen-v3")"
  if [ -d "/usr/lib/modules/$rel" ]; then
    warn "El release $rel ya está instalado en /usr/lib/modules."
    if [ "$FORCE" = true ]; then
      warn "Se continúa por --force (reinstalando sobre el release existente)."
    else
      fatal "Ya existe /usr/lib/modules/$rel; se aborta (usa --force para reinstalar igual)."
    fi
  fi
  return 0
}

# v27.30.0 (feature LinuxLocker): respalda el UKI previo a sobrescribirlo.
uki_backup_prev() {
  [ "$CIZEN_UKI_BACKUP" = "1" ] || return 0
  local tgt dst rel n
  rel="$VERSION-cizen-v3"
  if [ ! -d "$CIZEN_UKI_BACKUP_DIR" ]; then
    sudo mkdir -p "$CIZEN_UKI_BACKUP_DIR" || { warn "No se pudo crear $CIZEN_UKI_BACKUP_DIR; se omite el backup del UKI."; return 0; }
  fi
  while IFS= read -r tgt; do
    [ -s "$tgt" ] || continue
    dst="$CIZEN_UKI_BACKUP_DIR/$(basename "$tgt").before-$rel-$(date +%Y%m%d-%H%M%S)"
    if sudo cp -f "$tgt" "$dst" 2>/dev/null; then
      ok "UKI previo respaldado en $dst"
    fi
  done < <(find_cizen_uki_targets 2>/dev/null || true)
  # Poda defensiva: conservar solo las 8 copias mas recientes por nombre.
  for f in $(sudo find "$CIZEN_UKI_BACKUP_DIR" -type f -name '*.efi.before-*' 2>/dev/null || true); do
    n=1
    for older in $(sudo find "$CIZEN_UKI_BACKUP_DIR" -maxdepth 1 -type f -name "$(basename "$f")*" 2>/dev/null | sort | head -n -8); do
      [ "$older" = "$f" ] && n=0 && break
    done
    [ "$n" = 0 ] || sudo rm -f -- "$f" 2>/dev/null || true
  done
  return 0
}

# v27.30.0 (feature Arch-SKM): firma persistente de los módulos instalados con
# una MOK propia (claves en CIZEN_MODULE_SIGN_DIR), lista para enrollar con
# mokutil. Requiere CONFIG_MODULE_SIG (inyectada por el overlay del build).
module_sign_installed() {
  [ "$CIZEN_MODULE_SIGN" = "yes" ] || return 0
  command -v openssl >/dev/null 2>&1 || { warn "module-sign: falta openssl; se omite la firma."; return 0; }
  [ -x "$SRC/scripts/sign-file" ] || { warn "module-sign: no hay scripts/sign-file en $SRC; se omite."; return 0; }
  local rel key crt der n f
  rel="$(make -C "$SRC" -s kernelrelease 2>/dev/null || echo "$VERSION-cizen-v3")"
  key="$CIZEN_MODULE_SIGN_DIR/kernel-signing.key"
  crt="$CIZEN_MODULE_SIGN_DIR/kernel-signing.crt"
  der="$CIZEN_MODULE_SIGN_DIR/kernel-signing.der"
  if [ ! -s "$crt" ]; then
    log "module-sign: generando claves persistentes en $CIZEN_MODULE_SIGN_DIR (estilo MOK)..."
    sudo mkdir -p "$CIZEN_MODULE_SIGN_DIR"
    sudo openssl req -new -x509 -newkey rsa:4096 -keyout "$key" -out "$crt" -days 10000 -nodes \
        -subj "/CN=Cizen kernel module signing" >/dev/null 2>&1 \
      || { warn "module-sign: falló generar las claves; se omite la firma."; return 0; }
    sudo openssl x509 -inform PEM -outform DER -in "$crt" -out "$der" 2>/dev/null || true
    if [ "$SECURE_BOOT" = true ] && command -v mokutil >/dev/null 2>&1; then
      warn "module-sign: enrolla la MOK en el firmware (y reinicia) con:"
      warn "  sudo mokutil --import $der"
    fi
  fi
  n=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    sudo "$SRC/scripts/sign-file" sha256 "$key" "$crt" "$f" >/dev/null 2>&1 && n=$((n + 1))
  done < <(find "/usr/lib/modules/$rel" -type f -name '*.ko' 2>/dev/null || true)
  ok "module-sign: $n módulos firmados en /usr/lib/modules/$rel (MOK: $CIZEN_MODULE_SIGN_DIR)."
  return 0
}

# v27.30.0: auditoría de disco cifrado (LUKS2) para advertir de cmdline sin
# parámetros de desbloqueo antes de regenerar el UKI.
luks_fde_audit() {
  [ "$CIZEN_LUKS_AUDIT" = "1" ] || return 0
  command -v lsblk >/dev/null 2>&1 || return 0
  local fs
  fs="$(lsblk -rio FSTYPE,MOUNTPOINT 2>/dev/null | awk '$2=="/"{print $1; exit}')"
  case "$fs" in
    crypto_LUKS)
      if ! grep -Eq 'cryptdevice=|rd\.luks\.uuid=|rd\.luks=' /proc/cmdline 2>/dev/null; then
        warn "LUKS/FDE: la raíz está cifrada pero /proc/cmdline no trae cryptdevice/rd.luks. "
        warn "El UKI heredará ese cmdline; si no arranca tras reiniciar, añade los parámetros de desbloqueo al kernel y regenera el UKI."
      else
        ok "LUKS/FDE: raíz cifrada con parámetros de desbloqueo presentes en el cmdline."
      fi
      ;;
    *)
      info "LUKS/FDE: la raíz no es LUKS; sin requisitos especiales."
      ;;
  esac
  return 0
}

PACMAN_INSTALL_START_EPOCH="$(date +%s)"
PACMAN_PREINSTALL_LOCK_MTIME="$(pacman_lock_mtime)"

case "$CIZEN_PKG_BACKEND" in
  arch)
    recover_pacman_lock
    install_kernel_package || fatal "No se pudo instalar $PKG_NAME-$PKG_VERSION con pacman."
    ok "Paquete instalado: $PKG_NAME-$PKG_VERSION"
    # El paquete vive en el tmpfs de la build y pacman borra el anterior de su
    # caché (CleanMethod=KeepCurrent): si no se copia aquí, el kernel anterior
    # desaparece del host y no hay rollback posible. Se hace justo tras instalar,
    # que es el último momento en que el fichero existe.
    preserve_rollback_package
    ;;
  deb)
    if command -v dpkg >/dev/null 2>&1; then
      sudo dpkg -i "$PKG" || fatal "No se pudo instalar $PKG_NAME con dpkg."
      ok "Paquete instalado: $(basename "$PKG") (dpkg)"
    else
      warn "dpkg no disponible en este sistema; el .deb queda en $(dirname "$PKG") para instalación manual."
    fi
    ;;
  rpm)
    if command -v rpm >/dev/null 2>&1; then
      sudo rpm -Uvh "$PKG" || fatal "No se pudo instalar $PKG_NAME con rpm."
      ok "Paquete instalado: $(basename "$PKG") (rpm)"
    else
      warn "rpm no disponible en este sistema; el .rpm queda en $(dirname "$PKG") para instalación manual."
    fi
    ;;
  generic|gentoo)
    log "Backend $CIZEN_PKG_BACKEND: -- make modules_install + vmlinuz a /usr/lib/modules"
    if ! sudo make -C "$SRC" modules_install; then
      fatal "modules_install falló (backend $CIZEN_PKG_BACKEND)."
    fi
    rel__cgeb="$(make -C "$SRC" -s kernelrelease 2>/dev/null || echo "$VERSION-cizen-v3")"
    uname_m="$(uname -m | sed 's/x86_64/x86/;s/aarch64/arm64/;s/i686/x86/')"
    uname_arch="$(uname -m)"
    if [ "$uname_arch" = "x86_64" ] || [ "$uname_arch" = "i686" ]; then bzfile="arch/x86/boot/bzImage"; else bzfile="arch/$uname_m/boot/Image"; fi
    bzpath="$SRC/$bzfile"
    [ -f "$bzpath" ] || fatal "No se encontró la imagen del kernel ($bzfile) en $SRC para instalar."
    sudo install -Dm644 "$bzpath" "/usr/lib/modules/$rel__cgeb/vmlinuz" || fatal "No se pudo instalar vmlinuz en /usr/lib/modules/$rel__cgeb."
    ok "Kernel instalado desde el árbol: /usr/lib/modules/$rel__cgeb/vmlinuz"
    ;;
esac

# Firma persistente de módulos con MOK propia (feature Arch-SKM).
module_sign_installed

log "Sincronizando UKI..."
declare -a UKI_SYNC_ARGS=()
if [ "$DO_SIGN_UKI" = true ]; then
  UKI_SYNC_ARGS+=(--sign)
else
  UKI_SYNC_ARGS+=(--no-sign)
fi
# Respaldo del UKI previo antes de sobrescribirlo (feature LinuxLocker).
uki_backup_prev
# Auditoría de disco cifrado (opción --luks-audit): avisa antes de regenerar el
# UKI si la raíz LUKS no tiene parámetros de desbloqueo en el cmdline.
luks_fde_audit
sudo cizen-uki-sync "${UKI_SYNC_ARGS[@]}"
ensure_cizen_efi_updated
ok "UKI sincronizado"
if [ "$DO_SIGN_UKI" = true ]; then
  if sudo sbctl verify >/dev/null 2>&1; then
    ok "Firmas sbctl verificadas (sbctl verify)."
  else
    warn "sbctl verify detecta ficheros sin firmar; repásalos antes de habilitar Secure Boot: sudo sbctl verify"
  fi
fi
FULL_PIPELINE_OK=true

if [ "$CIZEN_PKG_BACKEND" = "arch" ]; then
  prune_stale_packages
fi

# Firma del build para el verificador post-boot (feature 2).
write_verify_signature

# Promover la configuración final en CONFIG_DIR SOLO después de instalación + UKI.
FINAL_CONFIG="$CONFIG_DIR/linux-$VERSION-cizen-v3.config"
promote_base_config .config "$FINAL_CONFIG"
ok "Configuración final guardada: $FINAL_CONFIG"

# Repo local pacman (--publish-repo): copia el paquete instalado a un repositorio
# de archivos servible a las VMs libvirt / otros hosts. Solo tiene sentido con
# el backend arch/pacman.
if [ "$CIZEN_PKG_BACKEND" = "arch" ]; then
  publish_repo_package
fi

T_END="$(date +%s)"

# Desglose de tiempos (feature 7). t_* en segundos; cada fase se muestra solo
# si tiene timestamps válidos (path completo de build siempre los tiene).
P_DL=""; P_CFG=""; P_BUILD=""; P_INST=""
if [ "${T_DL:-0}" -ge "${T_ALL:-0}" ] && [ "${T_ALL:-0}" -gt 0 ]; then
  P_DL="$((T_DL - T_ALL))"
fi
if [ "${T_CFG:-0}" -ge "${T_DL:-0}" ] && [ "${T_DL:-0}" -gt 0 ]; then
  P_CFG="$((T_CFG - T_DL))"
fi
if [ "${T_CFG:-0}" -gt 0 ] && [ "$DUR" -gt 0 ]; then
  P_BUILD="$DUR"
fi
if [ "${T_END:-0}" -gt 0 ] && [ "$DUR" -gt 0 ] && [ "${T_CFG:-0}" -gt 0 ]; then
  P_INST="$((T_END - T_CFG - DUR))"
fi

# fmt_time se define aquí (tras T_* y antes del cat del resumen).
fmt_time() { # segundos -> "Xm Ys" (o solo "Ys" si <60)
  local s="$1" m=0
  [ "${s:-0}" -le 0 ] 2>/dev/null && s=0
  if [ "$s" -ge 60 ] 2>/dev/null; then m=$((s / 60)); s=$((s % 60)); fi
  if [ "$m" -gt 0 ]; then printf '%dm %ds' "$m" "$s"; else printf '%ds' "$s"; fi
}

CCACHE_STATS=""
if [ -n "${CCACHE_DIR:-}" ] && command -v ccache >/dev/null 2>&1; then
  CCACHE_STATS="$(ccache -s 2>/dev/null | grep -E '^(Hits|Direct hits|Preprocessed cache hits|Misses|cache size|Files in cache|Uncacheable)' | sed 's/^ */  /' || true)"
fi

sudo_keepalive_stop
cleanup_success

# v27.31.19: el informe dice la verdad sobre el verificador y sobre el tmpfs.
VERIFY_SCRIPT_PATH="/usr/local/bin/kernel-update/kernel-update-verify.sh"
VERIFY_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
verify_service_state() {
  if [ ! -f "$VERIFY_SCRIPT_PATH" ]; then
    printf 'no instalado (%s no existe)\n' "$VERIFY_SCRIPT_PATH"
  elif [ ! -f "$VERIFY_UNIT_DIR/kernel-update-verify.service" ]; then
    printf 'script instalado, unidad ausente en %s\n' "$VERIFY_UNIT_DIR"
  elif systemctl --user is-enabled kernel-update-verify.service >/dev/null 2>&1; then
    printf 'activo (se ejecutará tras el próximo arranque)\n'
  else
    printf 'instalado pero NO habilitado: systemctl --user enable kernel-update-verify.service\n'
  fi
}

VERIFY_STATE_MSG="$(verify_service_state)"

case "$TMPFS_UMOUNT_STATUS" in
  unmounted)
    if [ "${TMPFS_UMOUNT_NOTE:-0}" -ge 1024 ]; then
      TMPFS_LINE="desmontado tras el éxito (~$(( ${TMPFS_UMOUNT_NOTE:-0} / 1024 )) GB devueltos a la RAM)"
    else
      TMPFS_LINE="desmontado tras el éxito (~${TMPFS_UMOUNT_NOTE:-0} MB devueltos a la RAM)"
    fi
    ;;
  failed)
    TMPFS_LINE="NO desmontado: $TMPFS_UMOUNT_NOTE — sudo umount $TMPFS_ROOT"
    ;;
  kept)
    TMPFS_LINE="montado a propósito ($TMPFS_UMOUNT_NOTE); se conserva el árbol para reutilizarlo"
    ;;
  not-mounted|*)
    TMPFS_LINE="sin montaje pendiente"
    ;;
esac

cat <<SUMMARY

===============================================================
ACTUALIZACIÓN COMPLETADA — CIZEN v$SCRIPT_VERSION
===============================================================
 Versión     : $VERSION-cizen-v3
 pkgrel      : $PKGREL
Perfil      : $PROFILE
  Parches     : ${PATCHES_APPLIED[*]:---}
  BTF         : $([ "$BTF_REQUESTED" = true ] && echo 'sí' || echo 'no')
  CC          : $([ "$CLANG_BUILD" = true ] && echo 'LLVM/Clang' || echo 'GCC')
${PUBLISH_REPO_MSG:+  ${PUBLISH_REPO_MSG}}
  Hilos       : $JOBS
Build prio  : $BUILD_PRIORITY_LABEL (CIZEN_BUILD_PRIORITY=normal para máxima velocidad)
  Backend     : $CIZEN_PKG_BACKEND
  Paquete     : ${PKG:+$(basename "$PKG")}${PKG:---sin paquete (modules_install)}
  Mod-firma   : $([ "$CIZEN_MODULE_SIGN" = "yes" ] && echo 'sí (MOK persistente)' || echo 'no')
 Config base : $FINAL_CONFIG
 Build tmpfs : $TMPFS_ROOT (size=$TMPFS_SIZE) → $TMPFS_LINE
 Podar       : $([ "${CIZEN_PRUNE_MODULES:-$PRUNE_MODULES}" = "1" ] && echo 'sí (solo módulos de este hardware)' || echo 'no')
 Lite        : sí (único modo: solo se compilan los módulos en uso; localmodconfig)
 Firma UKI   : $([ "$DO_SIGN_UKI" = true ] && printf '%s' 'sí (sbctl)' || printf '%s' 'no')${SIGN_UKI_REASON:+ — $SIGN_UKI_REASON}
${SNAPSHOT_DESC:+ Snapshot   : $SNAPSHOT_DESC}
${VERIFY_ROLLBACK_FILE:+ Rollback  : $VERIFY_ROLLBACK_FILE}

 Tiempos:
   Descarga+extracción : $( [ -n "$P_DL" ] && fmt_time "$P_DL" || echo '—')
   Config+validación   : $( [ -n "$P_CFG" ] && fmt_time "$P_CFG" || echo '—')
   Compilación         : $( [ -n "$P_BUILD" ] && fmt_time "$P_BUILD" || echo '—')
   Instalación+UKI     : $( [ -n "$P_INST" ] && fmt_time "$P_INST" || echo '—')

 Ccache      : ${CCACHE_DIR:-$HOME/.cache/ccache}${CCACHE_STATS:+ }$CCACHE_STATS

IMPORTANTE:
 El kernel nuevo queda instalado y el UKI ha sido sincronizado.
 tmpfs de compilación: $TMPFS_LINE
 Para arrancarlo (no se reinicia solo):

   sudo reboot

  Verificador: $VERIFY_STATE_MSG
  Si está activo, tras el reboot comprueba que el kernel cumple el perfil
  (incluido el scheduler que kronizó este build), el tiempo de arranque y
  busca regresiones en el journal.
  Rollback: el paquete de este kernel queda preservado en $ROLLBACK_DIR
  (${ROLLBACK_PKG_FILE:-sin paquete: solo el archive de ficheros}).
  Si el kernel nuevo no arranca, se reinstala el anterior con su scheduler:
    sudo $KROLLBACK_SCRIPT --list   # ver cuál es
    sudo $KROLLBACK_SCRIPT          # reinstalarlo y regenerar el UKI
===============================================================
SUMMARY

exit 0
