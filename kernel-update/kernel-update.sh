#!/usr/bin/env bash
# ============================================================
# kernel-update.sh — Cizen v27.30.1 (PRODUCCIÓN)
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
#   ./kernel-update.sh <versión> --patch bore                 # framework de parches
#   ./kernel-update.sh <versión> --bore                       # alias de --patch bore
#   CIZEN_PATCHES="bore" ./kernel-update.sh <versión>         # parches por env
#   ./kernel-update.sh <versión> --no-btf                     # sin CONFIG_DEBUG_INFO_BTF (opt-out; default: BTF=y)
#   ./kernel-update.sh <versión> --clang                      # build LLVM/clang (opt-in)
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

SCRIPT_VERSION="27.30.1"
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
# Símbolos que un parche obliga a DESACTIVAR para fijar una "choice" Kconfig
# (p. ej. elegir SCHED_PDS exige CONFIG_SCHED_BMQ=n). Selectores de scheduler.
declare -a PATCH_DISABLE_ALL=()
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
# Compilador: auto (clang si está, si no gcc) | gcc | clang. --clang == clang.
CIZEN_CC="${CIZEN_CC:-auto}"
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
# Modprobed-db: 0=off (default), 1=auto-descubrimiento, o ruta a la bbdd.
# Alimenta make localmodconfig con el historial persistente de módulos.
CIZEN_MODPROBED_DB="${CIZEN_MODPROBED_DB:-0}"
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
      if [ -d "$SRC" ]; then
        min_tmp_used="$TMPFS_EXISTING_SRC_MIN_FREE_MB"
      else
        min_tmp_used="$min_tmp"
      fi
      if [ -z "$free_mb" ] || [ "$free_mb" -lt "$min_tmp_used" ]; then
        fatal "Espacio libre insuficiente en el tmpfs de build ($TMPFS_ROOT): ${free_mb:-?} MB < ${min_tmp_used} MB (árbol reutilizable=$([ -d "$SRC" ] && echo sí || echo no)). Tras purgar los artefactos regenerables sigue lleno: remonta el tmpfs (sudo umount $TMPFS_ROOT) o ajusta CIZEN_BUILD_MIN_TMPFS_MB (o _BTF_MB)."
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
  if [ -d "$SRC" ]; then
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
    --rename=*)
      DO_RENAME=true
      RENAME_PAIR="${1#--rename=}"
      shift ;;
    --cc)
      CIZEN_CC="${2:-}"; [ -n "$CIZEN_CC" ] || { err "--cc requiere gcc|clang|auto"; exit 1; }
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
case "$CIZEN_CC" in auto|gcc|clang) ;; *) fatal "CIZEN_CC inválido: $CIZEN_CC (use auto, gcc o clang)." ;; esac
case "$CIZEN_LLVM_LTO" in 0|1|thin|full) ;; *) fatal "CIZEN_LLVM_LTO inválido: $CIZEN_LLVM_LTO (use 0, 1, thin o full)." ;; esac
# LTO solo es viable con clang+lld presentes de verdad: se decide AHORA, antes de
# la fase de config, para no inyectar CONFIG_LTO_CLANG_* en un build que luego
# degrade a gcc (olddefconfig los descartaría y la validación ENABLE fallaría).
if [ "$CIZEN_LLVM_LTO" != "0" ]; then
  if [ "$CIZEN_CC" = "gcc" ] && ! command -v clang >/dev/null 2>&1; then
    warn "LTO (${CIZEN_LLVM_LTO}) exige clang; CIZEN_CC=gcc → se ignora el LTO."
    CIZEN_LLVM_LTO=0
  elif ! command -v clang >/dev/null 2>&1 || ! command -v ld.lld >/dev/null 2>&1; then
    warn "LTO (${CIZEN_LLVM_LTO}) sin clang/lld instalados; se ignora el LTO (sudo pacman -S clang lld)."
    CIZEN_LLVM_LTO=0
  else
    [ "$CIZEN_CC" = "auto" ] && CIZEN_CC=clang
    CLANG_REQUESTED=true
  fi
fi
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
if [ -n "$CIZEN_USER_PATCHES_DIR" ] && [ ! -d "$CIZEN_USER_PATCHES_DIR" ]; then
  fatal "CIZEN_USER_PATCHES_DIR no existe o no es un directorio: $CIZEN_USER_PATCHES_DIR"
fi
# Compilador explícito por env sobre la auto-detección.
[ "$CIZEN_CC" = "clang" ] && CLANG_REQUESTED=true
[ "$CIZEN_CC" = "gcc" ] && CLANG_REQUESTED=false
# CIZEN_SCHED como alias de --patch (evita que dedupe lo pierda).
case "$CIZEN_SCHED" in
  inherit|eevdf) ;;
  bore|pds|bmq|lfbmq|muqss) PATCH_NAMES+=("$CIZEN_SCHED") ;;
  *) fatal "CIZEN_SCHED inválido: $CIZEN_SCHED (use inherit, eevdf, bore, pds, bmq, lfbmq o muqss)." ;;
esac
# ntsync para kernels SIN soporte nativo (< 6.10): se pide el parche CachyOS.
# (con $VERSION aún vacío en kcheck --check-update este atajo no se dispara y
# el usuario puede pedir --patch ntsync a mano).
if [ "$CIZEN_PATCH_NTSYNC" != "0" ] && [ -n "${VERSION:-}" ] && ! kernel_version_ge "$VERSION" "6.10"; then
  case " ${PATCH_NAMES[*]:-} " in
    *" ntsync "*) ;;
    *) PATCH_NAMES+=(ntsync) ;;
  esac
fi

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

# ============================================================
# RUTAS / ESTADO
# ============================================================
MAJOR=""
# TARBALL/SRC/URL se calculan después de resolver VERSION.
TARBALL=""
SRC=""
URL=""

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
# del usuario actual y no ser escribible por grupo u otros usuarios.
_pf_uid="$(stat -c '%u' "$PROFILE_FILE" 2>/dev/null || echo -1)"
_pf_mode="$(stat -c '%a' "$PROFILE_FILE" 2>/dev/null || echo 000)"
[ "$_pf_uid" = "$(id -u)" ] || fatal "El perfil '$PROFILE_FILE' no pertenece al usuario actual (uid=$_pf_uid)."
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
  local cmd pkg rc
  local -a tools=(awk bash bc bison cat ccache cmp cp date df du find findmnt flex flock fuser grep gcc gpg head id ls make mktemp mount nproc pacman pahole perl rm sbctl sed sleep sort stat tar tr umount wget xargs xz timeout cizen-uki-sync)
  local -a missing_cmds=() missing_pkgs=()

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
# ESPACIO / TMPFS / LOCK / DIRECTORIOS
# ============================================================
get_avail_mb() {
  local dir="$1" kb
  kb="$(df -Pk "$dir" | awk 'NR==2 {print $4}')"
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
  [ "$(findmnt -n -M "$TMPFS_ROOT" -o FSTYPE 2>/dev/null || true)" = "tmpfs" ]
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

  fstype="$(findmnt -n -M "$TMPFS_ROOT" -o FSTYPE 2>/dev/null || true)"
  mount_target="$(findmnt -n -M "$TMPFS_ROOT" -o TARGET 2>/dev/null || true)"

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
    sudo -v
    if ! sudo mount -t tmpfs -o "size=$TMPFS_SIZE,mode=0755,uid=$owner_uid,gid=$owner_gid,exec,nosuid,nodev,huge=advise" tmpfs "$TMPFS_ROOT"; then
      fatal "No se pudo montar el tmpfs de compilación en $TMPFS_ROOT."
    fi
    TMPFS_MOUNTED=true
    TMPFS_CREATED_BY_SCRIPT=true
    verify_tmpfs_ownership
  fi

  avail_mb="$(get_avail_mb "$TMPFS_ROOT")"
  min_required="$TMPFS_MIN_FREE_MB"
  if [ -d "$SRC" ]; then
    min_required="$TMPFS_EXISTING_SRC_MIN_FREE_MB"
  fi
  if [ "$avail_mb" -lt "$min_required" ]; then
    # v27.25.5: al reutilizar el árbol, los artefactos re-generables del enlace
    # final (vmlinux*, .tmp_vmlinux*, System.map) suelen llenar el tmpfs tras un
    # build reciente. Se purgan ANTES de declarar falta de espacio: se vuelven a
    # enlazar en minutos, y se conservan .o/.a (la inversión grande) y paquetes.
    if [ -d "$SRC" ]; then
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

  # Tras un flujo completo exitoso el tmpfs ya no hace falta: se desmonta.
  # CIZEN_KEEP_TMPFS=1 lo conserva (reutilización del árbol, diagnóstico).
  # Los flujos parciales (p. ej. solo check) nunca desmontan, para que un
  # kcheck prepare el entorno y el kbuild siguiente lo reutilice.
  if [ "$FULL_PIPELINE_OK" = true ] && [ "$CIZEN_KEEP_TMPFS" != "1" ]; then
    if tmpfs_is_mounted; then
      log "Desmontando tmpfs de compilación (flujo completo exitoso): $TMPFS_ROOT"
      if sudo umount "$TMPFS_ROOT"; then
        ok "tmpfs desmontado: $TMPFS_ROOT"
        TMPFS_MOUNTED=false
        TMPFS_CREATED_BY_SCRIPT=false
        return 0
      else
        warn "No se pudo desmontar $TMPFS_ROOT (¿proceso usándolo?); queda conservado. Para desmontarlo: sudo umount $TMPFS_ROOT"
      fi
    fi
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
  local current_tarball="linux-$VERSION.tar.xz"
  local current_sig="linux-$VERSION.tar.xz.sign"
  local current_verified="linux-$VERSION.tar.xz.verified-ok"
  local item base keep

  mkdir -p "$KERNEL_BUILD_ROOT"

  # Solo se conservan el tarball, su firma y su huella de verificación de la
  # versión solicitada. No se tocan gnupg/, kernel-update.lock ni otros
  # elementos ajenos a artefactos.
  shopt -s nullglob
  # Limpia todos los artefactos de tarball/firma antiguos, incluidos temporales
  # de descargas interrumpidas. La versión objetivo se conserva solo bajo sus
  # nombres definitivos, nunca con sufijos .download/.bad/.partial.
  for item in "$KERNEL_BUILD_ROOT"/linux-*.tar.xz*; do
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

  # El árbol de la versión más nueva se conserva en el tmpfs para reutilizarlo
  # en la próxima ejecución. No se elimina al terminar correctamente.
  if [ -d "$SRC" ]; then
    log "Fuentes conservadas para reutilización: $SRC"
  fi

  # El tmpfs y el árbol de fuentes se mantienen montados/conservados siempre
  # para reutilizar la build en la próxima ejecución.
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
    rm -f -- "${TARBALL}.sign.download-"* "${TARBALL}.sign.partial-"* 2>/dev/null || true
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

verify_tarball() {
  local file="$1"
  [ -f "$file" ] || return 1
  [ -s "$file" ] || return 1
  log "Verificando integridad del tarball ($(du -h "$file" | cut -f1))..."
  xz -t "$file" >/dev/null 2>&1
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
ensure_kernel_signing_keys() {
  local email fp expected pinned=0
  prepare_gpg_home

  for email in "${!KERNEL_TRUSTED_SIGNERS[@]}"; do
    expected="${KERNEL_TRUSTED_SIGNERS[$email]}"
    fp="$(gpg --homedir "$KERNEL_GPG_HOME" --batch --with-colons --fingerprint "$email" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"

    if [ "$fp" != "$expected" ]; then
      log "Clave de $email no disponible en el keyring dedicado; se obtiene mediante WKD de kernel.org."
      gpg --homedir "$KERNEL_GPG_HOME" --batch --yes --locate-keys "$email" >/dev/null 2>&1 || true
      fp="$(gpg --homedir "$KERNEL_GPG_HOME" --batch --with-colons --fingerprint "$email" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
    fi

    if [ "$fp" = "$expected" ]; then
      ok "Clave PGP confiable disponible: $email ($fp)"
      pinned=$((pinned + 1))
    else
      warn "No se pudo confirmar la clave PGP de $email (obtenida: '${fp:-ninguna}'); no se usará para verificar firmas."
      if [ -n "$fp" ]; then
        # Nunca dejamos en el keyring dedicado una clave cuya huella no
        # coincide con la esperada, aunque WKD haya devuelto algo.
        gpg --homedir "$KERNEL_GPG_HOME" --batch --yes --delete-keys "$fp" >/dev/null 2>&1 || true
      fi
    fi
  done

  [ "$pinned" -gt 0 ] || fatal "No se pudo confirmar ninguna clave PGP oficial de kernel.org (${!KERNEL_TRUSTED_SIGNERS[*]})."
}

verify_tarball_signature() {
  local tarball="$1" sig="$2" gpg_out signer=""
  [ -s "$tarball" ] || return 1
  [ -s "$sig" ] || return 1
  ensure_kernel_signing_keys
  log "Verificando firma PGP oficial del tarball..."
  # kernel.org firma el archivo .tar sin comprimir, mientras el archivo
  # descargado para la build es .tar.xz. La verificación correcta es
  # descomprimir por streaming y pasar el .tar a gpg mediante stdin.
  # El keyring dedicado solo contiene claves ya fijadas por huella en
  # ensure_kernel_signing_keys(), así que un "Good signature" de gpg aquí
  # implica necesariamente que la firma es de uno de los firmantes
  # confiables (LC_ALL=C está exportado al inicio del script, así que el
  # texto de salida de gpg es estable para este grep).
  if gpg_out="$(xz -cd -- "$tarball" | gpg --homedir "$KERNEL_GPG_HOME" --batch --verify "$sig" - 2>&1)"; then
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
  local tarball="$1" url="$2" tmp_download tmp_sign sig bad_name
  sig="${tarball}.sign"
  local verified_marker="${tarball}.verified-ok"

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

  log "Descargando firma PGP: ${url%.tar.xz}.tar.sign"
  if ! download_file "${url%.tar.xz}.tar.sign" "$tmp_sign"; then
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
  ok "Tarball descargado, íntegro y firmado por kernel.org"
}

# ============================================================
# EXTRACCIÓN / FUENTES
# ============================================================
source_tree_valid() {
  [ -d "$SRC" ] && [ -f "$SRC/Makefile" ]
}

extract_tarball() {
  cleanup_old_source_trees

  if source_tree_valid; then
    if [ "$(make -C "$SRC" -s kernelversion 2>/dev/null || true)" = "$VERSION" ]; then
      return 0
    fi
    warn "El árbol existente no coincide con $VERSION; se elimina y se vuelve a extraer."
    rm -rf "$SRC"
  fi

  log "Extrayendo fuentes en $(dirname "$SRC") ..."
  tar -xf "$TARBALL" -C "$(dirname "$SRC")"

  if ! source_tree_valid; then
    err "Extracción incompleta: falta $SRC/Makefile"
    rm -rf "$SRC"
    return 1
  fi

  if [ "$(make -C "$SRC" -s kernelversion 2>/dev/null || true)" != "$VERSION" ]; then
    err "La versión del árbol extraído no coincide con $VERSION"
    rm -rf "$SRC"
    return 1
  fi
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
  case "$kind" in
    pds)
      PATCH_DESC="PRJC/PDS scheduler (Piotr Gorski)"
      PATCH_DISP_NAME="PDS"
      PATCH_MAIN_FILE="0001-prjc-cachy.patch"
      PATCH_FALLBACK_FILE="0001-prjc.patch"
      PATCH_CACHE_NAME="prjc-pds"
      PATCH_SYMBOLS=(SCHED_ALT SCHED_PDS)
      PATCH_CHOICE_DISABLE=(SCHED_BMQ)
      PATCH_MAGIC="config SCHED_PDS"
      PATCH_MARKERS=( "kernel/sched/alt_core.c:" "kernel/sched/pds.h:" "kernel/sched/sched.h:SCHED_PDS" )
      ;;
    bmq)
      PATCH_DESC="PRJC/BMQ scheduler (Piotr Gorski)"
      PATCH_DISP_NAME="BMQ"
      PATCH_MAIN_FILE="0001-prjc-cachy.patch"
      PATCH_FALLBACK_FILE="0001-prjc.patch"
      PATCH_CACHE_NAME="prjc-bmq"
      PATCH_SYMBOLS=(SCHED_ALT SCHED_BMQ)
      PATCH_CHOICE_DISABLE=(SCHED_PDS)
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

# Registra un parche como aplicado: añade a la lista de aplicados y acumula sus
# símbolos Kconfig para que build_effective_arrays los fuerce a =y y los marque
# como rebeldes esperados. BORE mantiene además BORE_ENABLED (resumen y firma).
apply_patch_register() {
  local p="$1" s
  PATCHES_APPLIED+=("$p")
  for s in "${PATCH_SYMBOLS[@]:-}"; do
    PATCH_ENABLE_ALL+=("$s")
    PATCH_REBEL_ALL+=("$s")
  done
  # Elección de variante dentro de la "choice" Kconfig del scheduler.
  for s in "${PATCH_CHOICE_DISABLE[@]:-}"; do
    [ -n "$s" ] && PATCH_DISABLE_ALL+=("$s")
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
"patch_desc_$name"

  # Un descriptor puede decidir que el parche NO aplica a esta versión (p. ej.
  # ntsync en mainline, fsync en 6.14+): declara PATCH_SKIP_REASON y se corta
  # aquí con aviso, sin tocar el árbol.
  if [ -n "${PATCH_SKIP_REASON:-}" ]; then
    warn "${PATCH_SKIP_REASON}"
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
    apply_patch_register "$name"
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
  unset _mreason main_tmp _pin_reason

  if ! patch -p1 -d "$SRC" < "$patch_file" >/dev/null 2>&1; then
    warn "Aplicación real del parche ${PATCH_DISP_NAME:-$name} falló inesperadamente; se continúa vanilla."
    return 1
  fi

  apply_patch_register "$name"
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
      && make ARCH="$karch" olddefconfig >> "$lite_log" 2>&1 \
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

  if [ "${PROFILE_CHANGED:-false}" = true ]; then
    log "Preparando ${#EFF_ENABLE[@]} activaciones, ${#EFF_DISABLE[@]} desactivaciones, ${#EFF_SETVAL[@]} valores numéricos y ${#EFF_SETSTR[@]} valores de texto..."
  else
    log "Preparando configuración Cizen..."
  fi

  for o in "${EFF_ENABLE[@]}"; do
    if kconfig_symbol_known "$o"; then
      args+=(--enable "$o")
    else
      warn "ENABLE: CONFIG_$o no existe en esta versión; si Kconfig lo renombró, regístralo con: $0 --rename $o=NUEVO_NOMBRE"
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
  NEWCONFIG_OUTPUT="$(make listnewconfig 2>&1 || true)"
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
  OLDCONFIG_OUTPUT="$(make olddefconfig 2>&1)" || {
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

prepare_rollback_archive() {
  local rel modules vmlinuz tmp
  rel="$(uname -r 2>/dev/null || true)"
  [ -n "$rel" ] || { warn "No se puede leer uname -r; no se guarda archive de rollback."; return 0; }
  # Nunca volver a archivar la versión que acabamos de dejar de arrancar si ya
  # existe un archive de la misma release: no vale la pena overwrite. Aún así se
  # poda por si quedaran archives antiguos de sesiones previas.
  [ -f "$ROLLBACK_DIR/$rel.tar.xz" ] && { info "Rollback ya existe para $rel; se conserva."; prune_rollback_archives; return 0; }

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
write_verify_signature() {
  local profile_hash="" rel
  mkdir -p -- "$VERIFY_STATE_DIR" 2>/dev/null || true
  [ -f "$PROFILE_FILE" ] && profile_hash="$(sha256sum "$PROFILE_FILE" | cut -d' ' -f1 2>/dev/null || true)"
  rel="${VERSION}${LOCALVERSION_SUFFIX}"
  {
    printf 'version=%s\n' "$rel"
    printf 'bore=%s\n' "$([ "$BORE_ENABLED" = true ] && echo yes || echo no)"
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
  local requested="$1" latest="$2" answer

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
MAJOR="${VERSION%%.*}"
TARBALL="$KERNEL_BUILD_ROOT/linux-$VERSION.tar.xz"
SRC="$TMPFS_ROOT/linux-$VERSION"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-$VERSION.tar.xz"

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

sudo -v

# Verificación temprana de que las operaciones privilegiadas (mount/umount,
# pacman, escritura en el ESP, etc.) están permitidas por sudo, antes de
# gastar minutos en descarga/compilación.
check_sudo_capabilities

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
TMPFS_FINAL_FS="$(findmnt -n -M "$TMPFS_ROOT" -o FSTYPE 2>/dev/null || true)"
TMPFS_FINAL_OPTS="$(findmnt -n -M "$TMPFS_ROOT" -o OPTIONS 2>/dev/null || true)"
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
  if ! make olddefconfig; then
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
    'CC=ccache gcc'
    'HOSTCC=ccache gcc'
  )
  # No fijamos KBUILD_BUILD_TIMESTAMP. Kbuild utilizará la fecha/hora real
  # de compilación, evitando que uname -a muestre una fecha artificial.
  # La reproducibilidad temporal puede activarse explícitamente desde el
  # entorno si el usuario exporta KBUILD_BUILD_TIMESTAMP antes de ejecutar.
  ok "ccache activo: $CCACHE_DIR (CC/HOSTCC forzados; timestamp de build real)"
else
  warn "ccache no instalado; compilación normal."
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

# Build con LLVM/Clang (--clang): Kbuild aplica LLVM=1 (CC=clang, ld.lld,
# llvm-ar/nm, etc.). Si clang o ld.lld no están, se degrada a GCC (fatal suave).
CLANG_BUILD=false
if [ "$CLANG_REQUESTED" = true ]; then
  if command -v clang >/dev/null 2>&1 && command -v ld.lld >/dev/null 2>&1; then
    if command -v ccache >/dev/null 2>&1; then
      MAKE_CC_OPTS+=(
        'LLVM=1'
        'CC=ccache clang'
        'HOSTCC=ccache clang'
      )
    else
      MAKE_CC_OPTS+=('LLVM=1')
    fi
    export LLVM=1
    CLANG_BUILD=true
    ok "Compilación con LLVM/Clang (LLVM=1)."
  else
    warn "clang/ld.lld no están instalados; --clang se degrada a GCC (sudo pacman -S clang lld)."
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

# Obtener sudo antes de modificar el sistema.
sudo -v

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
 Build tmpfs : $TMPFS_ROOT (size=$TMPFS_SIZE)
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
 Para arrancarlo:

   sudo reboot

 Después del reboot, kernel-update-verify.service comprueba que el kernel
 cumple el perfil (y BORE si se pidió), el tiempo de arranque y busca
 regresiones en el journal.
 El kernel previo quedó archivado para rollback: krollback --list
===============================================================
SUMMARY

exit 0
