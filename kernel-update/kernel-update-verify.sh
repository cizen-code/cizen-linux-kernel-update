#!/usr/bin/env bash
# ============================================================
# kernel-update-verify.sh — verificación post-boot del kernel Cizen
#
# Corre tras cada arranque (unit de usuario kernel-update-verify.service,
# tras graphical-session.target; también manualmente) y comprueba:
#
#   a) SCHED    : que el scheduler EN EJECUCIÓN es el que promesses el
#                 último build. Se cubren TODOS los que el motor ofrece
#                 (inherit, eevdf, bore, pds, bmq, lfbmq, muqss) leyendo
#                 SCHED_BORE/PDS/BMQ/LFBMQ/MUQSS del config en ejecución;
#                 antes solo se miraba BORE y un build con bmq se reportaba
#                 como "EEVDF vanilla", es decir, se daba por bueno.
#   b) PERFIL   : que la configuración del kernel EN EJECUCIÓN cumple el
#                 perfil cizen (OPTS_ENABLE / CRITICAL_OPTS / SETVAL / SETSTR)
#                 aplicando el mapa de renames, y que el scheduler coincide
#                 con la firma del último build (BTF si se pidieron).
#                 v27.31.20: OPTS_ENABLE acepta =y y =m igual que la validación
#                 del motor (el modo lite degrada con localmodconfig) y un
#                 firmware presente en el árbol no cuenta como incidencia.
#                 v27.31.22: los símbolos que el parche del scheduler RETIRA
#                 (`depends on !SCHED_ALT`, p. ej. SCHED_AUTOGROUP con
#                 bmq/pds/lfbmq) se saltan: el motor ya los saca de las
#                 exigencias efectivas, así que su ausencia es correcta. Sin
#                 esto, un build con BMQ notificaba "Perfil: FALLO" en cada
#                 arranque por un símbolo imposible de habilitar.
#   c) BOOT     : compara systemd-analyze (kernel/userspace/total) del boot
#                 actual contra una REFERENCIA y avisa si el total la empeora
#                 más allá de un factor/umbral. La referencia es la mediana de
#                 los últimos N arranques del mismo kernel (v27.33.1); antes
#                 era el arranque inmediatamente anterior, que con la
#                 dispersión real de este host (11.8-22.8 s) disparaba por
#                 azar. Sin historial suficiente se cae al arranque previo.
#   d) JOURNAL  : cuenta patrones de regresión del kernel (oops/panic/GPU
#                 hang/hung task/... ) en el journal del boot actual y avisa
#                 si aparecen más que en el boot previo.
#   e) GUARD    : avisa si el kernel arrancado NO es el último Cizen instalado
#                 (fallback de sd-boot por boot counting, o selección manual).
#   f) FIRMWARE : por cada módulo cargado, modinfo -F firmware → se verifica que
#                 el fichero exista en /usr/lib/firmware; además se escanea el
#                 journal del kernel por "Direct firmware load failed". Avisa
#                 de cualquier firmware ausente/infallible del boot actual.
#   g) SECURE BOOT: cruza la firma del último build (sb= en last-build) con el
#                 estado real de Secure Boot (bootctl status, salida fija con
#                 LC_ALL=C). Avisa si la UKI se firmó pero SB está desactivado,
#                 o si SB está activo con la UKI sin firmar (no arrancaría).
#
# Estado/log en ~/.local/state/kernel-update/. Solo notifica discrepancias
# (o el primer arranque de un kernel nuevo). Uso: --dry-run para imprimir
# sin notificar, útil tras un reboot para auditar.
#
# Variables de entorno (override):
#   CIZEN_VERIFY_STATE_DIR   estado (default ~/.local/state/kernel-update)
#   CIZEN_KERNEL_TRACK       se respeta igual que kernel-update.sh
#   CIZEN_VERIFY_BOOT_FACTOR umbral de empeoramiento de boot (default 1.35)
#   CIZEN_VERIFY_BOOT_MIN_DELTA  delta mínimo en s (default 3)
#   CIZEN_VERIFY_BOOT_REF_N      arranques del mismo kernel que forman la
#                                mediana de referencia (default 7)
#   CIZEN_VERIFY_BOOT_REF_MIN    muestras mínimas para usar esa mediana en vez
#                                del arranque previo (default 3)
#   CIZEN_NOTIFY_BIN         binario de notificación (default notify-send)
#   CIZEN_FIRMWARE_DIR       raíz de firmware a auditar (default /usr/lib/firmware)
# ============================================================

set -uo pipefail
export LC_ALL=C

STATE_DIR="${CIZEN_VERIFY_STATE_DIR:-$HOME/.local/state/kernel-update}"
LOG="$STATE_DIR/verify.log"
LAST="$STATE_DIR/verify-last"
HIST="$STATE_DIR/verify-history"
# Firma del último estado notificado. La notificación solo sale cuando el estado
# CAMBIA: un estado recurrente (p. ej. «la UKI está firmada pero Secure Boot está
# desconocido», que no se arregla solo) no puede repetir una notificación
# crítica en cada arranque, que es justo lo que la vuelve ruido.
NOTIFY_STATE="$STATE_DIR/verify-notify-state"
BUILD_SIG="$STATE_DIR/last-build"
RENAME_MAP_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/kernel-update/rename-map.conf"
NOTIFY_BIN="${CIZEN_NOTIFY_BIN:-notify-send}"
FIRMWARE_DIR="${CIZEN_FIRMWARE_DIR:-/usr/lib/firmware}"
# Sufijo de localversion de los kernels Cizen. Debe coincidir con
# LOCALVERSION_SUFFIX del motor / CIZEN_UKI_SUFFIX de cizen-uki-sync.
CIZEN_VERIFY_SUFFIX="${CIZEN_VERIFY_SUFFIX:--cizen-v3}"

BOOT_FACTOR="${CIZEN_VERIFY_BOOT_FACTOR:-1.35}"
BOOT_MIN_DELTA="${CIZEN_VERIFY_BOOT_MIN_DELTA:-3}"
# Referencia de la comparación de arranque: mediana de los últimos BOOT_REF_N
# arranques del MISMO kernel (ver boot_ref). Sin ella el umbral se comparaba
# contra una única muestra.
BOOT_REF_N="${CIZEN_VERIFY_BOOT_REF_N:-7}"
BOOT_REF_MIN="${CIZEN_VERIFY_BOOT_REF_MIN:-3}"
JOURNAL_PATTERNS=(
  'Oops'
  'oops'
  'BUG:'
  'kernel panic'
  'Call Trace:'
  'hung_task'
  'hung task'
  'GPU HANG'
  'gpu_reset'
  'i915.*(fault|reset|timeout)'
  'Out of memory'
  'watchdog: BUG'
  'WARNING: CPU'
)

PROFILE_CANDIDATES=(
  "${CIZEN_PROFILE_FILE:-}"
  "/usr/local/bin/kernel-update/profiles/cizen-optiplex7050.conf"
  "/usr/local/bin/kernel-update/cizen-optiplex7050.conf"
  "$HOME/.config/kernel-update/profiles/cizen-optiplex7050.conf"
  "$HOME/.config/kernel-update/cizen-optiplex7050.conf"
)

mkdir -p "$STATE_DIR" 2>/dev/null || true
[ -f "$LAST" ] || : > "$LAST" 2>/dev/null || true
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 524288 ]; then
  mv -f -- "$LOG" "$LOG.1" 2>/dev/null || true
fi
alog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

DRY=false
QUIET=false
[ "${1:-}" = "--dry-run" ] && DRY=true
# --no-notify: verifica y actualiza el estado, pero sin lanzar notificación.
# Sirve para establecer la línea base del estado actual (que si no dispararía una
# notificación por "cambio") y para pasar la comprobación a mano sin que salte
# un aviso en el escritorio.
[ "${1:-}" = "--no-notify" ] && QUIET=true

if [ -t 1 ]; then
  G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; C=$'\033[0;36m'; N=$'\033[0m'
else
  G=""; Y=""; C=""; R=""; N=""
fi
ok(){  printf '%s  %s%s %s\n' "$G" "$N" "✓" "$*"; }
warn(){ printf '%s  %s%s %s\n' "$Y" "$N" "⚠" "$*"; }
err(){ printf '%s  %s%s %s\n' "$R" "$N" "✗" "$*" >&2; }
info(){ printf '%s  %s%s %s\n' "$C" "$N" "•" "$*"; }

pull_env_from_pid() {
  local pid="$1" line
  [ -r "/proc/$pid/environ" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      DISPLAY=*)        [ -n "${DISPLAY:-}" ] || export DISPLAY="${line#DISPLAY=}" ;;
      WAYLAND_DISPLAY=*) [ -n "${WAYLAND_DISPLAY:-}" ] || export WAYLAND_DISPLAY="${line#WAYLAND_DISPLAY=}" ;;
      XDG_CURRENT_DESKTOP=*) [ -n "${XDG_CURRENT_DESKTOP:-}" ] || export XDG_CURRENT_DESKTOP="${line#XDG_CURRENT_DESKTOP=}" ;;
      XDG_DATA_DIRS=*)  [ -n "${XDG_DATA_DIRS:-}" ] || export XDG_DATA_DIRS="${line#XDG_DATA_DIRS=}" ;;
    esac
  done < <(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null)
}

ensure_session_env() {
  local me sid stype leader name pid
  if [ -n "${XDG_CURRENT_DESKTOP:-}" ] && [ -n "${XDG_DATA_DIRS:-}" ] &&
     { [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; }; then
    return 0
  fi
  me="${USER:-$(id -un)}"
  sid="$(loginctl show-user "$me" --property=Display --value 2>/dev/null || true)"
  stype=""
  if [ -n "$sid" ]; then
    stype="$(loginctl show-session "$sid" --property=Type --value 2>/dev/null || true)"
    leader="$(loginctl show-session "$sid" --property=Leader --value 2>/dev/null || true)"
    [ -n "$leader" ] && pull_env_from_pid "$leader"
  fi
  if [ -z "${XDG_CURRENT_DESKTOP:-}" ] || [ -z "${XDG_DATA_DIRS:-}" ]; then
    for name in plasmashell kwin_wayland kwin_x11 gnome-shell xfce4-session cinnamon sway; do
      pid="$(pgrep -u "$me" -x "$name" 2>/dev/null | head -n1)"
      [ -n "$pid" ] && pull_env_from_pid "$pid"
      [ -n "${XDG_CURRENT_DESKTOP:-}" ] && [ -n "${XDG_DATA_DIRS:-}" ] && break
    done
  fi
  if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
    [ "$stype" = "wayland" ] && export WAYLAND_DISPLAY="wayland-0" || export DISPLAY=":0"
  fi
  [ -n "${XDG_DATA_DIRS:-}" ] || export XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"
  [ -n "${XDG_RUNTIME_DIR:-}" ] && export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
}

# ---------- 1) PERFIL ----------
declare -A RUN_CFG=()
CFG_LOADED=0
SCHED_RUNNING="unknown"
SCHED_EXPECTED=""
load_running_config() {
  RUN_CFG=()
  CFG_LOADED=0
  local line
  zcat /proc/config.gz >/dev/null 2>&1 || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)=(.*)$ ]]; then
      RUN_CFG["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
      RUN_CFG["${BASH_REMATCH[1]}"]="n"
    fi
  done < <(zcat /proc/config.gz 2>/dev/null)
  CFG_LOADED=1
  return 0
}

run_state() { # $1 = símbolo (ya resuelto a nombre actual); imprime y/m/n/missing
  if [ -n "${RUN_CFG[$1]+x}" ]; then printf '%s\n' "${RUN_CFG[$1]}"; else printf '%s\n' "missing"; fi
}

# ---------- 1b) SCHEDULER ----------
# Todos los schedulers que el motor ofrece como opción (--sched / CIZEN_SCHED):
# inherit | eevdf | bore | pds | bmq | lfbmq | muqss. Cada uno se reconoce en el
# kernel EN EJECUCIÓN por su símbolo de configuración; eevdf es el de mainline y
# no tiene símbolo propio (se deduce por ausencia de los demás).
# Antes solo se miraba SCHED_BORE, así que un build con bmq/pds/lfbmq/muqss se
# reportaba como "EEVDF vanilla en ejecución": el verificador daba por bueno un
# kernel con el scheduler equivocado.
sched_symbol_for() { # $1 = scheduler -> símbolo CONFIG_ esperado en y (o "-")
  case "$1" in
    bore)  printf 'SCHED_BORE\n' ;;
    pds)   printf 'SCHED_PDS\n' ;;
    bmq)   printf 'SCHED_BMQ\n' ;;
    lfbmq) printf 'SCHED_LFBMQ\n' ;;
    muqss) printf 'SCHED_MUQSS\n' ;;
    eevdf) printf -- '-\n' ;;
    *)     printf '\n' ;;
  esac
}

sched_label() { # $1 = scheduler -> texto legible
  case "$1" in
    bore)  printf 'BORE\n' ;;
    pds)   printf 'PDS (Project C)\n' ;;
    bmq)   printf 'BMQ\n' ;;
    lfbmq) printf 'LF-BMQ\n' ;;
    muqss) printf 'MuQSS\n' ;;
    eevdf) printf 'EEVDF (mainline)\n' ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

# Scheduler efectivo del último build. Las firmas escritas desde v27.31.19 traen
# sched=; las anteriores (solo bore=no y patches=) se deducen para no perder la
# comprobación: bore si bore=yes, si no el primer parche de la lista de
# schedulers del proyecto, si no eevdf.
expected_sched_from_signature() {
  local s="${1:-}" p
  case "$s" in
    inherit|"") ;;
    *) printf '%s\n' "$s"; return 0 ;;
  esac
  s="${2:-}"   # bore= yes|no
  if [ "$s" = "yes" ]; then printf 'bore\n'; return 0; fi
  for p in ${3:-}; do   # patches=
    case "$p" in
      bore|pds|bmq|lfbmq|muqss) printf '%s\n' "$p"; return 0 ;;
    esac
  done
  printf 'eevdf\n'
}

# Qué scheduler hay realmente en el kernel en ejecución: el símbolo propio en y,
# o, si no, cualquiera de los del proyecto (así un kernel con pds no se
# reporta como eevdf solo porque buscando SCHED_BMQ no aparece).
running_sched() {
  local sym s
  for sym in SCHED_BORE SCHED_PDS SCHED_BMQ SCHED_LFBMQ SCHED_MUQSS; do
    case "$(run_state "$sym")" in y) ;; *) continue ;; esac
    case "$sym" in
      SCHED_BORE)  s=bore ;;
      SCHED_PDS)   s=pds ;;
      SCHED_BMQ)   s=bmq ;;
      SCHED_LFBMQ) s=lfbmq ;;
      SCHED_MUQSS) s=muqss ;;
    esac
    printf '%s\n' "$s"
    return 0
  done
  printf 'eevdf\n'
}

declare -A RENAMES=()
load_renames() {
  local key val
  [ -f "$RENAME_MAP_FILE" ] || return 0
  while IFS='=' read -r key val; do
    [ -n "$key" ] && [[ "$key" =~ ^[A-Za-z0-9_]+$ ]] && [ -n "$val" ] && RENAMES["$key"]="$val"
  done < "$RENAME_MAP_FILE"
}

# ---------- 1c) SÍMBOLOS QUE EL PARCHE DEL SCHEDULER RETIRA ----------
# El parche PRJC (pds/bmq/lfbmq) mete `depends on !SCHED_ALT` en varios símbolos
# (SCHED_AUTOGROUP entre ellos), así que son imposibles de habilitar por diseño
# suyo. El motor lo sabe y los saca de ENABLE/CRITICAL/SETVAL/SETSTR antes de
# validar (build_effective_arrays + PATCH_RETIRED_ALL), de modo que el build
# sale correcto; el perfil los puede seguir pidiendo sin problema.
# El verificador leía el perfil en crudo y contaba su ausencia como incidencia:
#   CRITICAL: CONFIG_SCHED_AUTOGROUP no existe en el kernel en ejecución
# → "Perfil: FALLO" y notificación critical en cada arranque, sin que hubiera
# nada que arreglar. Ahora se saltan, igual que los =m del modo lite: se informa,
# no se cuenta.
#
# Fuente de verdad: retired= en la firma del build (v27.31.22). Para firmas
# anteriores se deduce del scheduler efectivo con la MISMA tabla que el motor
# (_patch_desc_scheduler_base), para no depender de un build nuevo. bore y muqss
# no retiran ninguno: su patch no toca SCHED_AUTOGROUP ni sus `depends on`.
declare -A RETIRED=()
RETIRED_SCHED=""
RETIRED_SRC=""
RETIRED_LIST=""
build_sig_field() { # $1 = clave -> valor de la firma del último build (o vacío)
  [ -f "$BUILD_SIG" ] || return 0
  sed -n "s/^$1=//p" "$BUILD_SIG" 2>/dev/null | head -n1
}
retired_symbols_for_sched() { # $1 = scheduler -> símbolos que ese parche retira (uno por línea)
  case "$1" in
    pds|bmq|lfbmq) printf '%s\n' PSI PSI_DEFAULT_DISABLED SCHED_AUTOGROUP NUMA_BALANCING SCHED_CACHE ;;
    *)             : ;;
  esac
}
load_retired_symbols() {
  RETIRED=(); RETIRED_SCHED=""; RETIRED_SRC=""; RETIRED_LIST=""
  local sig s
  sig="$(build_sig_field retired)"
  if [ -n "$sig" ]; then
    RETIRED_SRC="firma retired="
    for s in $sig; do RETIRED["$s"]=1; done
  else
    RETIRED_SCHED="$(expected_sched_from_signature "$(build_sig_field sched)" \
      "$(build_sig_field bore)" "$(build_sig_field patches)")"
    for s in $(retired_symbols_for_sched "$RETIRED_SCHED"); do RETIRED["$s"]=1; done
    [ "${#RETIRED[@]}" -gt 0 ] && RETIRED_SRC="scheduler de la firma (${RETIRED_SCHED})"
  fi
  [ "${#RETIRED[@]}" -gt 0 ] && [ -z "$RETIRED_SCHED" ] && RETIRED_SCHED="$(build_sig_field sched)"
  for s in "${!RETIRED[@]}"; do RETIRED_LIST="${RETIRED_LIST:+$RETIRED_LIST }$s"; done
  # Rastro en el log: de dónde salió la lista, para que un "omitida" del perfil
  # nunca vuelva a ser un misterio cuando se audite a mano.
  [ -n "$RETIRED_LIST" ] && alog "verify: ${#RETIRED[@]} símbolo(s) retirados por el parche del scheduler [origen: ${RETIRED_SRC:-desconocido}]: $RETIRED_LIST"
  return 0
}
sym_retired() { # $1 = símbolo -> 0 si el parche del scheduler lo retiró
  [ -n "${RETIRED[$1]+x}" ]
}
retired_reason() { # texto legible del origen de la lista
  if [ -n "${RETIRED_SCHED:-}" ]; then
    printf 'retiradas por el parche del scheduler (%s)' "$(sched_label "$RETIRED_SCHED")"
  else
    printf 'retiradas por el parche del scheduler'
  fi
}

resolve_sym() {
  local s="$1" guard=0
  while [ -n "${RENAMES[$s]:-}" ] && [ "$guard" -lt 20 ]; do
    s="${RENAMES[$s]}"
    guard=$((guard + 1))
  done
  printf '%s\n' "$s"
}

find_profile() {
  local c
  for c in "${PROFILE_CANDIDATES[@]}"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

profile_check() {
  # Devuelve por STDOUT SOLO el número entero de incidencias; toda la salida
  # legible (ok/warn/info) va a STDERR para no ensuciar la captura.
  local profile issues=0
  pc_out() { printf '%s\n' "$*" >&2; }
  pc_ok(){  pc_out "  ✓ $*"; }
  pc_warn(){ pc_out "  ⚠ $*"; }
  pc_info(){ pc_out "  • $*"; }
  profile="$(find_profile)" || { pc_warn "Perfil cizen no encontrado; se omite la comprobación de perfil."; printf '%s\n' "0"; return 0; }
  source "$profile" || { pc_warn "No se pudo cargar el perfil $profile; se omite perfil."; printf '%s\n' "0"; return 0; }
  load_renames
  load_retired_symbols

  # v27.33.2: el desfase del perfil se averigua ANTES de contar símbolos, porque
  # decide cómo se cuentan. "El kernel es anterior al perfil" es UN hecho, y se
  # estaba contando dos: una vez por cada símbolo que el perfil pide y este
  # kernel no tiene (bad[]), y otra por el sha distinto. Con un desfase real,
  # el aviso de sha es el que explica los símbolos, así que los símbolos pasan
  # a ser detalle de ese aviso y no incidencias aparte.
  #
  # Sin desfase (sha igual) NO cambia nada: cada símbolo incumplido sigue
  # contando uno, porque entonces el kernel se compiló con este mismo perfil y
  # no cumplirlo sí es un fallo real del build.
  #
  # El criterio es el SHA, no la fecha: una mtime distinta no significa nada
  # (un `cp`, un `touch`, un checkout de git tocan el fichero sin cambiar su
  # contenido), y avisar por eso era ruido puro. Por eso NO se usa mtime aquí.
  local cur_sha="" profile_sha_reg="" profile_drift=false
  if [ -f "$BUILD_SIG" ]; then
    # shellcheck disable=SC1090,SC1091
    # En subshell para no contaminar este ámbito con las variables del build
    # (version, btf, patches…), que se leen más abajo con otro propósito.
    profile_sha_reg="$( ( set +u; source "$BUILD_SIG" >/dev/null 2>&1; printf '%s' "${profile_sha:-}" ) )"
    if [ -n "$profile_sha_reg" ]; then
      cur_sha="$(sha256sum "$profile" 2>/dev/null | cut -d' ' -f1 || true)"
      if [ -n "$cur_sha" ] && [ "$cur_sha" != "$profile_sha_reg" ]; then
        profile_drift=true
      fi
    fi
  fi
  local opt r st exp line
  local -a bad=() demoted=() skipped=()

for opt in "${OPTS_ENABLE[@]:-}"; do
    [ -n "$opt" ] || continue
    r="$(resolve_sym "$opt")"
    if sym_retired "$r"; then
      skipped+=("ENABLE: CONFIG_$opt")
      continue
    fi
    st="$(run_state "$r")"
    case "$st" in
      y) : ;;
      # v27.31.20: =m NO es una incidencia. El motor acepta y|m en OPTS_ENABLE
      # (validate_config) porque el modo lite hace `make localmodconfig`, que
      # degrada a módulo todo lo que este hardware no tiene cargado. Cobrarlo
      # como fallo daba un "Perfil: FALLO" permanente en cada arranque sin que
      # hubiera nada que arreglar. Se informa, no se cuenta.
      m) demoted+=("CONFIG_$opt quedó en =m (localmodconfig del modo lite lo degradó; el perfil pide y)") ;;
      n) bad+=("ENABLE: CONFIG_$opt quedó en n") ;;
      *) bad+=("ENABLE: CONFIG_$opt no existe (missing en el kernel en ejecución)") ;;
    esac
  done
  if [ "${#demoted[@]}" -gt 0 ]; then
    pc_info "OPTS_ENABLE: ${#demoted[@]} símbolo(s) en =m por el modo lite (no es una incidencia):"
    for line in "${demoted[@]}"; do pc_out "      $line"; done
  fi
  for opt in "${CRITICAL_OPTS[@]:-}"; do
    [ -n "$opt" ] || continue
    r="$(resolve_sym "$opt")"
    # v27.31.22: retirado por el parche del scheduler = imposible de habilitar
    # (`depends on !SCHED_ALT`). El motor ya lo saca de las exigencias
    # efectivas, así que el build es correcto y su ausencia aquí también.
    if sym_retired "$r"; then
      skipped+=("CRITICAL: CONFIG_$opt")
      continue
    fi
    st="$(run_state "$r")"
    case "$st" in
      y|m) : ;;
      n) bad+=("CRITICAL: CONFIG_$opt está en n") ;;
      *) bad+=("CRITICAL: CONFIG_$opt no existe en el kernel en ejecución") ;;
    esac
  done
  if declare -p OPTS_SETVAL >/dev/null 2>&1; then
    for opt in "${!OPTS_SETVAL[@]}"; do
      [ -n "$opt" ] || continue
      r="$(resolve_sym "$opt")"
      sym_retired "$r" && { skipped+=("SETVAL: CONFIG_$opt"); continue; }
      st="$(run_state "$r")"
      if [ "$st" != "missing" ] && [ "$st" != "${OPTS_SETVAL[$opt]}" ]; then
        bad+=("SETVAL: CONFIG_$opt=$st (esperado ${OPTS_SETVAL[$opt]})")
      fi
    done
  fi
  if declare -p OPTS_SETSTR >/dev/null 2>&1; then
    for opt in "${!OPTS_SETSTR[@]}"; do
      [ -n "$opt" ] || continue
      r="$(resolve_sym "$opt")"
      sym_retired "$r" && { skipped+=("SETSTR: CONFIG_$opt"); continue; }
      st="$(run_state "$r")"
      exp="\"${OPTS_SETSTR[$opt]}\""
      if [ "$st" != "missing" ] && [ "$st" != "$exp" ]; then
        bad+=("SETSTR: CONFIG_$opt=$st (esperado $exp)")
      fi
    done
  fi

  if [ "${#skipped[@]}" -gt 0 ]; then
    pc_info "Perfil: ${#skipped[@]} exigencia(s) omitidas — $(retired_reason) (no es una incidencia):"
    for line in "${skipped[@]}"; do pc_out "      $line"; done
  fi

  issue=0
  if [ "${#bad[@]}" -gt 0 ]; then
    if [ "$profile_drift" = true ]; then
      # Un solo hecho, una sola incidencia: el kernel se compiló con un perfil
      # anterior al vigente. Los símbolos que faltan son la consecuencia de
      # eso, no N fallos independientes del build.
      issues=$((issues + 1))
      pc_warn "El kernel en ejecución se compiló con un perfil ANTERIOR al vigente: reconstruye para que lo refleje."
      pc_out "      perfil vigente ${cur_sha:0:12} ≠ perfil del build ${profile_sha_reg:0:12}"
      pc_out "      ${#bad[@]} símbolo(s) que el perfil pide y este kernel no cumple, por ese desfase:"
      for line in "${bad[@]}"; do pc_out "      $line"; done
    else
      issues=$((issues + ${#bad[@]}))
      pc_warn "El kernel en ejecución NO cumple el perfil (${#bad[@]}), y se compiló con este mismo perfil:"
      for line in "${bad[@]}"; do pc_out "      $line"; done
    fi
  else
    pc_ok "Perfil: el kernel en ejecución cumple OPTS/CRITICAL/SETVAL/SETSTR."
  fi

  # Firmado de módulos
  if [ -n "${RUN_CFG[MODULE_SIG_FORCE]+x}" ] && [ "${RUN_CFG[MODULE_SIG_FORCE]}" = "y" ]; then
    pc_ok "MODULE_SIG_FORCE activo en ejecución."
  fi

  if [ -f "$BUILD_SIG" ]; then
    local sig_btf="no" sig_ver="" sig_patches=""
    # shellcheck disable=SC1090,SC1091
    source "$BUILD_SIG"
    sig_btf="${btf:-no}"
    sig_ver="${version:-}"
    sig_patches="${patches:-}"
    if [ "$sig_btf" = "yes" ]; then
      local btf_run=""
      [ -n "${RUN_CFG[DEBUG_INFO_BTF]+x}" ] && btf_run="${RUN_CFG[DEBUG_INFO_BTF]}"
      if [ "${btf_run:-n}" != "y" ]; then
        pc_warn "El último build pedía BTF pero CONFIG_DEBUG_INFO_BTF=${btf_run:-n} en el kernel arrancado."
        issues=$((issues + 1))
      else
        pc_ok "BTF presente (DEBUG_INFO_BTF=y) según la firma del último build."
      fi
      unset btf_run
    fi
    # v27.33.2: el aviso de perfil desfasado se emite AQUÍ, pero NO se cuenta
    # como incidencia cuando ya se ha contado arriba como desfase con símbolos
    # incumplidos (era el mismo hecho contado dos veces). Solo se cuenta si el
    # desfase no produjo ningún síntoma: el kernel es anterior al perfil pero
    # cumple todo lo que el perfil vigente pide, así que no hay nada roto y solo
    # se informa. Compatible con firmas antiguas sin profile_sha (se omite).
    if [ "$profile_drift" = true ] && [ "${#bad[@]}" -eq 0 ]; then
      issues=$((issues + 0))
      pc_info "Perfil: el kernel es anterior al perfil vigente (${cur_sha:0:12} ≠ ${profile_sha_reg:0:12}) pero cumple todo lo que el perfil pide; reconstruye cuando quieras (no es una incidencia)."
    elif [ "$profile_drift" = true ]; then
      pc_info "Perfil: el desfase ya se ha contado arriba como una incidencia."
    fi
  fi
  printf '%s\n' "${issues:-0}"
  return 0
}

# Compara el scheduler EN EJECUCIÓN con el que kronizó el último build.
# Es un paso propio (no dentro de profile_check) porque profile_check corre en
# una sustitución de comandos: los globales que fija ahí no se verían fuera.
sched_check() {
  local run expect sym ok_sym=0 s
  SCHED_RUNNING="unknown"
  SCHED_EXPECTED=""

  if [ "${CFG_LOADED:-0}" != "1" ]; then
    info "Sin /proc/config.gz legible: el scheduler en ejecución no se puede comprobar."
    return 0
  fi

  run="$(running_sched)"
  SCHED_RUNNING="$run"

  if [ ! -f "$BUILD_SIG" ]; then
    ok "Scheduler en ejecución: $(sched_label "$run") (sin firma de build con qué compararlo)."
    return 0
  fi
  # shellcheck disable=SC1090,SC1091
  source "$BUILD_SIG"
  expect="$(expected_sched_from_signature "${sched:-}" "${bore:-no}" "${patches:-}")"
  SCHED_EXPECTED="$expect"

  # Tolerante a que un kernel tenga más de un símbolo del proyecto activo (BORE
  # y los alt conviven en el fork): lo que se exige es que el símbolo del
  # scheduler prometido esté activo, no que los demás estén apagados.
  if [ "$expect" = "eevdf" ]; then
    for s in SCHED_BORE SCHED_PDS SCHED_BMQ SCHED_LFBMQ SCHED_MUQSS; do
      [ "$(run_state "$s")" = "y" ] && ok_sym=1
    done
    if [ "$ok_sym" = "1" ]; then
      warn "El último build kronizó EEVDF (mainline) pero el kernel arrancado tiene un scheduler del proyecto activo (se detecta $(sched_label "$run"))."
      ISSUES=$((ISSUES + 1))
    else
      ok "Scheduler en ejecución: EEVDF (mainline), como kronizó el build (${version:-?})."
    fi
    return 0
  fi

  sym="$(sched_symbol_for "$expect")"
  case "$(run_state "$sym")" in
    y)
      ok "Scheduler en ejecución: $(sched_label "$expect"), como kronizó el build (${version:-?}); CONFIG_${sym}=y."
      ;;
    *)
      warn "El último build kronizó $(sched_label "$expect") (CONFIG_${sym}=y) pero el kernel arrancado no lo tiene: se detecta $(sched_label "$run") (${version:-?})."
      ISSUES=$((ISSUES + 1))
      ;;
  esac
  return 0
}

# ---------- 2) BOOT (systemd-analyze) ----------
boot_times() {
  # imprime: "fw loader kernel userspace total"
  local line fw load ke us tot
  line="$(systemd-analyze time 2>/dev/null | grep -m1 'Startup finished in' || true)"
  [ -n "$line" ] || { echo "0 0 0 0 0"; return 0; }
  fw=0; load=0; ke=0; us=0; tot=0
  [[ "$line" =~ ([0-9.]+)s\ \(firmware\) ]] && fw="${BASH_REMATCH[1]}"
  [[ "$line" =~ ([0-9.]+)s\ \(loader\) ]] && load="${BASH_REMATCH[1]}"
  [[ "$line" =~ ([0-9.]+)s\ \(kernel\) ]] && ke="${BASH_REMATCH[1]}"
  [[ "$line" =~ ([0-9.]+)s\ \(userspace\) ]] && us="${BASH_REMATCH[1]}"
  line="${line%"${line##*[![:space:]]}"}" # sin espacios finales (el formato trae 's ')
  [[ "$line" =~ ([0-9.]+)s$ ]] && tot="${BASH_REMATCH[1]}"
  printf '%s %s %s %s %s\n' "$fw" "$load" "$ke" "$us" "$tot"
}

float_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

# Referencia contra la que se juzga si este arranque se ha empeorado: la MEDIANA
# de los últimos BOOT_REF_N arranques del MISMO kernel, leída de verify-history.
#
# Antes se comparaba contra el arranque inmediatamente anterior, y eso es
# comparar ruido con ruido: en este host el total va de 11.8 a 22.8 s con una
# desviación de 2.9 s, así que un umbral de 1.35x/+3 s sobre UNA muestra
# dispara por azar — en el historial real, 3 de 44 pares (6 %), y el "peor"
# caso era 17.795 s, la mediana del propio kernel. Una mediana no se ve
# desplazada por un arranque lento suelto, que es justo lo que se quiere
# detectar como anomalía y no como nuevo nivel de referencia.
#
# Dos detalles que no son cosméticos:
#   - Solo cuenta si el kernel es el MISMO. Comparar contra un LTS o contra el
#     kernel anterior mezcla dos distribuciones: el 22.797 s del 27-sep era el
#     LTS, no una regresión del kernel Cizen.
#   - Una línea por ARRANQUE, no por verificación. Se deduplica por boot_id: una
#     unidad que corre dos veces en el mismo arranque, una verificación manual y
#     un --dry-run son el MISMO dato, no tres arranques. La primera versión
#     deduplicaba por "total igual al anterior" y eso rompía justo en el caso
#     que más importa: con un arranque determinista (5 arranques de 13.0 s
#     seguidos) colapsaba las cinco muestras en una, nunca se alcanzaba el
#     mínimo, y la mediana no se usaba nunca.
boot_ref() { # $1 = versión de kernel -> imprime la mediana, o nada
  local want="$1" n min v ke us tot j ts bid
  local -a vals=()
  local -A seen=()
  [ -f "$HIST" ] || return 0
  n="$BOOT_REF_N"; min="$BOOT_REF_MIN"
  [ "$n" -ge 1 ] 2>/dev/null || n=7
  [ "$min" -ge 1 ] 2>/dev/null || min=3
  # El nº de incidencias de la línea no forma parte de la referencia (aquí solo
  # cuenta el tiempo de arranque), pero hay que leer la línea entera para no
  # desplazar ts/bid: se desperdicia en `_`.
  while read -r v ke us tot j _ ts bid; do
    [ "$v" = "$want" ] || continue
    [[ "$tot" =~ ^[0-9]+(\.[0-9]+)?$ ]] || continue
    # Clave de arranque: el boot_id si la línea lo trae (formato actual), y si
    # no, el par (timestamp, total) de las líneas escritas antes de v27.33.1.
    local key="${bid:-${ts:-}/$tot}"
    [ -n "${seen[$key]:-}" ] && continue
    seen[$key]=1
    vals+=("$tot")
  done < "$HIST"
  [ "${#vals[@]}" -ge "$min" ] || return 0
  [ "${#vals[@]}" -gt "$n" ] && vals=( "${vals[@]: -n}" )
  printf '%s\n' "${vals[@]}" | sort -n | awk '
    { a[NR]=$1 }
    END { if (NR % 2) printf "%s\n", a[(NR+1)/2]; else printf "%.3f\n", (a[NR/2]+a[NR/2+1])/2 }'
  return 0
}

boot_check() {
  # args: fw load kernel userspace total (string)
  local tot="$5" us="$4" ke="$3"
  local p_tot p_ver p_ke p_us p_j p_issues p_ts p_thr min_d base base_txt=""
  # La referencia se busca primero en el historial del mismo kernel; si no hay
  # muestras suficientes se cae al arranque previo registrado, que es el
  # comportamiento de siempre y solo se usa con pocos datos.
  base="$(boot_ref "$CUR_VERSION")"
  if [ -n "$base" ]; then
    base_txt="mediana de los últimos $BOOT_REF_N arranques de $CUR_VERSION ($base s)"
  else
    read -r p_ver p_ke p_us p_tot p_j p_issues p_ts < "$LAST" 2>/dev/null || return 0
    if [ -z "${p_tot:-}" ] || ! [[ "$p_tot" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [ "$p_tot" = "0" ]; then
      return 0 # sin registro previo comparable
    fi
    base="$p_tot"
    base_txt="arranque previo ($p_tot s en ${p_ver:-—})"
  fi
  if float_ge "$tot" "$base"; then
    p_thr="$(awk -v b="$base" -v f="$BOOT_FACTOR" 'BEGIN{printf "%.1f", b*f}')"
    min_d="$(awk -v a="$base" -v d="$BOOT_MIN_DELTA" 'BEGIN{printf "%.1f", a+d}')"
    if float_ge "$tot" "$p_thr" && float_ge "$tot" "$min_d"; then
      warn "Boot más lento que la referencia ($base_txt): $tot s (umbral $p_thr s / $min_d s)."
      ISSUES=$((ISSUES + 1))
      return 0
    fi
  fi
  [ "${DRY:-false}" = true ] && info "Boot: total $tot s (kernel $ke s / userspace $us s); referencia $base_txt."
  return 0
}

# ---------- 3) JOURNAL ----------
journal_count() {
  local out n=0 p j
  out="$(journalctl -k -b 2>/dev/null || true)"
  [ -n "$out" ] || { echo 0; return 0; }
  for p in "${JOURNAL_PATTERNS[@]}"; do
    j="$(printf '%s\n' "$out" | grep -Ec -- "$p" 2>/dev/null || true)"
    n=$((n + j))
  done
  printf '%s\n' "$n"
}

journal_check() {
  local cur="$1" p_j p_ver
  read -r p_ver p_ke p_us p_tot p_j p_issues p_ts < "$LAST" 2>/dev/null || return 0
  if [ "${p_j:-0}" -gt 0 ] && [ "$cur" -gt "${p_j:-0}" ]; then
    warn "Patrones de regresión en journal del boot actual: $cur (previo $p_j en $p_ver)."
    ISSUES=$((ISSUES + 1))
  else
    [ "${DRY:-false}" = true ] && info "Journal: $cur patrones de regresión en el boot actual."
  fi
  return 0
}

# ---------- 4) GUARD (boot counting / fallback) ----------
guard_check() {
  local expected=""
  expected="$(ls -1d /usr/lib/modules/*"$CIZEN_VERIFY_SUFFIX" 2>/dev/null | sed -E 's#.*/##' | sort -V | tail -n1 || true)"
  if [ -z "$expected" ]; then
    [ "${DRY:-false}" = true ] && info "Guard: no hay kernel Cizen instalado."
    return 0
  fi
  if [ "$CUR_VERSION" = "$expected" ]; then
    [ "${DRY:-false}" = true ] && info "Guard: arrancó el kernel esperado ($expected)."
    return 0
  fi
  warn "Guard: arrancó $CUR_VERSION, pero el último Cizen instalado es $expected (¿boot counting agotado y sd-boot hizo fallback, o selección manual del LTS?)."
  ISSUES=$((ISSUES + 1))
}

# ---------- 5) FIRMWARE ----------
firmware_missing_for_module() {
  local mod="$1" out fw rel
  out="$(modinfo -F firmware "$mod" 2>/dev/null || true)"
  [ -n "$out" ] || return 0
  while IFS= read -r fw; do
    [ -n "$fw" ] || continue
    rel="${fw#firmware/}"
    # El árbol linux-firmware almacena los binarios comprimidos como .zst;
    # también puede traer .xz/.gz, igual que en la rama del journal (v27.31.20):
    # el fichero "falta" solo si no está de ninguna forma.
    if { [ ! -f "$FIRMWARE_DIR/$rel" ] \
         && [ ! -f "$FIRMWARE_DIR/$rel.zst" ] \
         && [ ! -f "$FIRMWARE_DIR/$rel.xz" ] \
         && [ ! -f "$FIRMWARE_DIR/$rel.gz" ]; }; then
      printf '%s (%s)\n' "$fw" "$mod"
    fi
  done <<< "$out"
}

firmware_check() {
  local mod f line
  local -a missing=() kfail=() kpresent=() all=()
  FW_COUNT=0
  while IFS= read -r mod; do
    [ -n "$mod" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] && missing+=("$f")
    done < <(firmware_missing_for_module "$mod")
  done < <(cut -d' ' -f1 /proc/modules 2>/dev/null || true)
  # v27.31.20: un "Direct firmware load ... failed" cuyo binario SÍ está en el
  # árbol (normalmente comprimido: i915/kbl_dmc_ver1_04.bin -> .bin.zst) no es
  # una incidencia: el driver pide el nombre sin extensión, el kernel tiene el
  # comprimido y sigue funcionando (en el i915 eso solo desactiva el runtime
  # power management). Contarlo como problema era un aviso permanente en cada
  # arranque. Sí cuenta si el fichero no está de ninguna forma: eso sí es
  # un paquete de firmware que falta de verdad.
  local fw_name fw_rel
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # La línea puede venir de varias formas ("Direct firmware load for X
    # failed", "firmware: failed to load X"); se saca el nombre sin exigir que
    # no lleve "/" (los firmwares de i915/ice son rutas con directorios).
    fw_name="$(printf '%s' "$line" \
      | sed -nE -e 's#^Direct firmware load for ([^ ]+) failed.*#\1#p' \
                   -e 's#.*\bfor ([^ ]+) failed.*#\1#p' \
                   -e 's#.*failed to load ([^ ]+).*#\1#p' \
      | head -n1)"
    fw_name="${fw_name%.}"
    fw_rel="${fw_name#firmware/}"
    if [ -n "$fw_name" ] && { [ -f "$FIRMWARE_DIR/$fw_rel" ] || [ -f "$FIRMWARE_DIR/$fw_rel.zst" ] \
       || [ -f "$FIRMWARE_DIR/$fw_rel.xz" ] || [ -f "$FIRMWARE_DIR/$fw_rel.gz" ]; }; then
      kpresent+=("$line  [el fichero SÍ está: $fw_rel.zst]")
    else
      kfail+=("$line")
    fi
  done < <(journalctl -k -b 2>/dev/null | grep -oiE 'Direct firmware load (for [^ ]+ )?failed|firmware: failed to load [^ ]+|request_firmware[^)]*failed' | sed -E 's/^[[:space:]]+//' | sort -u || true)

  if [ "${#missing[@]}" -eq 0 ] && [ "${#kfail[@]}" -eq 0 ] && [ "${#kpresent[@]}" -eq 0 ]; then
    [ "${DRY:-false}" = true ] && info "Firmware: presentes los requeridos por los módulos cargados."
    return 0
  fi
  while IFS= read -r f; do [ -n "$f" ] && all+=("$f"); done < <(printf '%s\n' "${missing[@]}" "${kfail[@]}" | sort -u || true)
  FW_COUNT="${#all[@]}"
  if [ "${#kpresent[@]}" -gt 0 ]; then
    info "Firmware: ${#kpresent[@]} carga(s) fallida(s) con el fichero presente en el árbol (no cuentan como incidencia):"
    for f in "${kpresent[@]}"; do printf '      %s\n' "$f"; done
  fi
  if [ "$FW_COUNT" -eq 0 ]; then
    [ "${DRY:-false}" = true ] && info "Firmware: ningún fichero ausente de verdad."
    return 0
  fi
  warn "Firmware del boot actual: $FW_COUNT problema(s) (fichero ausente del árbol):"
  for f in "${all[@]}"; do printf '      %s\n' "$f"; done
  ISSUES=$((ISSUES + FW_COUNT))
  return 0
}

# ---------- 6) SECURE BOOT (UKI firmada vs estado real) ----------
secureboot_check() {
  # La intención del último build está en last-build (sb=yes|no); el estado
  # efectivo en bootctl status (con LC_ALL=C la salida es fija).
  local sb_build="no" sboot="desconocido"
  if [ -f "$BUILD_SIG" ]; then
    # shellcheck disable=SC1090,SC1091
    source "$BUILD_SIG" 2>/dev/null || true
    sb_build="${sb:-no}"
  fi
  # OJO con el patrón: bootctl imprime "Secure Boot: enabled (user)", así que un
  # *'enabled' a secas NO casa (exigiría que la línea terminara en "enabled") y el
  # verificador daba "desconocido" con Secure Boot perfectamente activo. El
  # comodín final es imprescindible, y el patrón se ancla al campo para no
  # confundirlo con nada otro.
  case "$(bootctl status 2>/dev/null | grep -m1 'Secure Boot:' || true)" in
    *'Secure Boot: enabled'*)  sboot="HABILITADO" ;;
    *'Secure Boot: disabled'*) sboot="desactivado" ;;
  esac
  if [ "$sb_build" = "yes" ]; then
    if [ "$sboot" = "HABILITADO" ]; then
      SB_STATE="$sb_build (UKI firmada; SB $sboot)"
      [ "${DRY:-false}" = true ] && info "Secure Boot: $sboot — la UKI del último build se firmó con sbctl."
    else
      SB_STATE="$sb_build (UKI firmada pero SB $sboot)"
      warn "La UKI del último build se firmó con sbctl, pero Secure Boot está $sboot: la firma no tiene efecto. Activa Secure Boot (sbctl enroll-keys --microsoft + BIOS)."
      ISSUES=$((ISSUES + 1))
    fi
  elif [ "$sboot" = "HABILITADO" ]; then
    SB_STATE="no (UKI sin firmar)"
    warn "Secure Boot está HABILITADO pero el último build NO firmó la UKI (sb=no): ese kernel no arrancaría. Recompila con --sign o desactiva Secure Boot."
    ISSUES=$((ISSUES + 1))
  else
    SB_STATE="no (SB $sboot)"
    [ "${DRY:-false}" = true ] && info "Secure Boot: $sboot — UKI sin firmar (correcto con SB desactivado)."
  fi
  return 0
}

# ---------- notificación ----------
# Firma del estado verificable, SIN los tiempos de arranque: 15.8675 s frente a
# 15.8671 s no es un cambio de estado, y si estuviera en la firma no se callaría
# nunca. Refleja lo que el usuario tiene que reaccionar a: perfil, scheduler,
# patrones del journal, firmware y Secure Boot.
verify_state_fingerprint() {
  # 'ver=' NO es cosmético: sin él, arrancar un kernel NUEVO con el MISMO
  # número de incidencias que el anterior daba una firma idéntica y
  # notify_state_changed devolvía 1, así que el usuario no recibía aviso de las
  # incidencias de su kernel nuevo. Solo se notifica con kernel limpio hay
  # First_boot, que no depende de la firma — con incidencias no la había, y esa
  # es justo la clase de falso negativo que un verificador no puede permitirse.
  printf 'ver=%s|perfil=%s|sched=%s/%s|journal=%s|fw=%s|sb=%s|iss=%s' \
    "${CUR_VERSION:-?}" "${BASE_ISSUES:-0}" "${SCHED_EXPECTED:-?}" "${SCHED_RUNNING:-?}" \
    "${JCOUNT:-0}" "${FW_COUNT:-0}" "${SB_STATE:-?}" "${ISSUES:-0}"
}

# Devuelve 0 si el estado es NUEVO (o no hay previo): entonces toca notificar.
notify_state_changed() {
  local prev cur
  cur="$(verify_state_fingerprint)"
  [ -s "$NOTIFY_STATE" ] || return 0
  prev="$(head -n1 "$NOTIFY_STATE")"
  [ "$prev" != "$cur" ] && return 0
  return 1
}

# Valor de un componente dentro de una firma. Aísla el grep+sed que se
# repetía en el diff: la firma es "clave=valor|clave=valor" y ningún valor
# contiene "|", así que el corte es seguro.
fp_field() { # $1 = firma, $2 = clave -> valor (vacío si no está)
  [ -n "$1" ] || return 0
  printf '%s' "$1" | grep -oE "(^|\|)${2}=[^|]*" | head -n1 | sed -E "s#^(\||)${2}=##"
}

# Etiqueta legible de cada componente: "Perfil: 2 -> 0" se lee; la clave
# desnuda "perfil=2" es un volcado de la firma, no un mensaje para el usuario.
notify_field_label() {
  case "$1" in
    # El número del perfil cuenta incidencias de perfil, no un nivel ni un
    # contador de arranques. Con la etiqueta a secas, "Perfil: 2 -> 0" al lado
    # de un "Perfil: OK" se lee como dos cosas distintas y obliga a abrir el
    # informe para saber qué cuenta.
    # v27.33.2: ya no son SÍMBOLOS, porque el perfil desfasado cuenta 1 sola vez
    # (los símbolos pasan a ser su detalle). Decir "símbolos" sobre un 1 que en
    # realidad agrupa varios sería mentir sobre lo que cuenta el número.
    perfil)  printf 'Perfil' ;;
    sched)   printf 'Scheduler' ;;
    journal) printf 'Journal' ;;
    fw)      printf 'Firmware' ;;
    sb)      printf 'Secure Boot' ;;
    iss)     printf 'Incidencias' ;;
    *)       printf '%s' "$1" ;;
  esac
}

# Cómo se muestra un valor. "sched" viene como "esperado/enEjecución": si
# coinciden (lo normal) basta uno; si no, se dice cuál se esperaba, que es la
# parte accionable. "sb" traía el texto entero de secureboot_check
# ("yes (UKI firmada; SB HABILITADO)"), del que solo se usa el veredicto.
notify_field_value() { # $1 = clave, $2 = valor crudo
  case "$1" in
    sched)
      local e="${2%%/*}" r="${2##*/}"
      if [ -z "$e" ] || [ "$e" = "?" ] || [ "$e" = "$r" ]; then
        sched_label "$r"
      else
        printf '%s, esperado %s' "$(sched_label "$r")" "$(sched_label "$e")"
      fi
      ;;
    sb)
      case "$2" in
        yes*) printf 'sí' ;;
        no*)  printf 'no' ;;
        *)    printf '%s' "$2" ;;
      esac
      ;;
    *) printf '%s' "$2" ;;
  esac
}

# Segundos con un solo decimal, sin depender de awk/locale (LC_ALL=C está
# forzado en todo el script). Contexto para una notificación, no métrica: la
# comparación fina se hace en el informe de consola, que sí lleva TOT_TXT.
fmt_secs() { # $1 = segundos (entero o decimal)
  local s="${1:-0}" int frac
  case "$s" in ''|*[!0-9.]*) printf '%s' "$s"; return 0 ;; esac
  int="${s%%.*}"; frac="${s#*.}"; frac="${frac}0"
  printf '%s.%s' "${int:-0}" "${frac:0:1}"
}

# Texto "qué ha cambiado" para el cuerpo de la notificación: componente a
# componente contra la firma guardada (sin columna "antes" la primera vez).
# ASCII a propósito ("->", sin viñetas): este texto se lee de un vistazo y se
# copia de un log, y los glifos Unicode se pierden al transcribirlo.
notify_state_diff() {
  local prev cur key ov nv first=true
  local -a keys=(perfil sched journal fw sb iss) changed=() show=() lines=()
  prev="$( [ -s "$NOTIFY_STATE" ] && head -n1 "$NOTIFY_STATE" || true )"
  cur="$(verify_state_fingerprint)"
  # Sin firma previa no hay diff que mostrar: listar los seis componentes como
  # si fueran todos nuevos es un volcado de estado, no un "qué ha cambiado", y
  # ocupa más pantalla que la propia información de la notificación. El
  # primer arranque ya tiene su propia notificación (notify_first_boot).
  [ -n "$prev" ] || return 0

  for key in "${keys[@]}"; do
    ov="$(fp_field "$prev" "$key")"
    nv="$(fp_field "$cur" "$key")"
    [ "$ov" = "$nv" ] || changed+=("$key")
  done
  [ "${#changed[@]}" -eq 0 ] && return 0

  # El total (iss) se calla cuando no aporta nada sobre lo que ya dicen los
  # componentes: con una sola causa, "Incidencias: 2 -> 0" al lado de
  # "Perfil: 2 -> 0" repite el mismo número dos veces. Con varias causas, o
  # con un total que ningún componente explica por sí solo, sí se muestra.
  for key in "${changed[@]}"; do
    if [ "$key" = iss ]; then
      [ "${#changed[@]}" -gt 1 ] || continue
      local k2 dup=0
      for k2 in "${changed[@]}"; do
        [ "$k2" = iss ] && continue
        [ "$(fp_field "$cur" "$k2")" = "$(fp_field "$cur" iss)" ] && dup=1
      done
      [ "$dup" = 1 ] && continue
    fi
    show+=("$key")
  done

  for key in "${show[@]}"; do
    ov="$(fp_field "$prev" "$key")"
    nv="$(fp_field "$cur" "$key")"
    # Se compara lo que SE MUESTRA, no la firma cruda: el scheduler pasa de
    # "?/bore" a "bore/bore" (el build ya declara el esperado) y eso no es un
    # cambio de estado, solo se ha completado un dato que faltaba. Con la
    # firma cruda eso se notificaba como "Scheduler: BORE -> BORE".
    local ovv nvv
    ovv="$(notify_field_value "$key" "$ov")"
    nvv="$(notify_field_value "$key" "$nv")"
    [ "$ovv" = "$nvv" ] && continue
    if [ -z "$prev" ] || [ -z "$ov" ]; then
      lines+=("  $(notify_field_label "$key"): $nvv")
    else
      lines+=("  $(notify_field_label "$key"): $ovv -> $nvv")
    fi
  done
  [ "${#lines[@]}" -eq 0 ] && return 0

  # Tope de líneas: el cuerpo de una notificación no es un informe, y una
  # lista larga de componentes no cabe en pantalla ni aporta más.
  if [ "${#lines[@]}" -gt 4 ]; then
    lines=( "${lines[@]:0:3}" "  ... y $(( ${#lines[@]} - 3 )) más" )
  fi

  for nv in "${lines[@]}"; do
    [ "$first" = true ] || printf '\n'
    first=false
    printf '%s' "$nv"
  done
  printf '\n'
  return 0
}

notify_issues() {
  local title body prof_txt sev icon
  if [ "$PROFILE_OK" = 1 ]; then prof_txt="OK"; else prof_txt="FALLO"; fi
  local diff
  diff="$(notify_state_diff)"
  # El nombre de la app ya es "Kernel Updater": repetir "Kernel Cizen:" en el
  # título solo consume ancho. El número de incidencias sí va en el título,
  # que es lo único que se lee sin desplegar el cuerpo.
  if [ "$ISSUES" -gt 0 ]; then
    title="$CUR_VERSION: ${ISSUES} incidencia(s)"
    sev=critical; icon=dialog-warning
  else
    title="$CUR_VERSION: sin incidencias"
    sev=normal; icon=emblem-ok
  fi
  # Solo los datos que informan. Un "Journal: 0 patrones | FW: 0" en un
  # estado limpio no dice nada: el 0 ya es el resultado. El tiempo de boot se
  # redondea a un decimal porque es contexto, no una métrica a comparar.
  body="Perfil: $prof_txt | boot $(fmt_secs "${BT_TOT:-0}")s"
  [ "${JCOUNT:-0}" -gt 0 ] && body="$body | journal $JCOUNT"
  [ "${FW_COUNT:-0}" -gt 0 ] && body="$body | firmware $FW_COUNT"
  [ -n "$diff" ] && body="$body
$diff"
  if [ "$DRY" = true ]; then
    echo "  (dry-run) Notificarías: $title — $body"
    return 0
  fi
  if [ "$QUIET" = true ]; then
    alog "Notificación suprimida (--no-notify): $title — $body"
    return 0
  fi
  command -v "$NOTIFY_BIN" >/dev/null 2>&1 || { alog "notify-send no disponible; no se notifica."; return 1; }
  ensure_session_env
  "$NOTIFY_BIN" -a 'Kernel Updater' -u "$sev" -t 10000 -i "$icon" "$title" "$body" >/dev/null 2>&1 || true
  alog "Notificación de verificación: $title — $body"
}

notify_first_boot() {
  local title body iss_txt
  if [ "$ISSUES" -gt 0 ]; then
    iss_txt="$ISSUES incidencia(s)"; title="$CUR_VERSION arrancado: $iss_txt"
  else
    iss_txt="sin incidencias"; title="$CUR_VERSION arrancado"
  fi
  body="$iss_txt | boot $(fmt_secs "${BT_TOT:-0}")s"
  if [ "$DRY" = true ]; then
    echo "  (dry-run) Notificarías (primer arranque): $title — $body"
    return 0
  fi
  if [ "$QUIET" = true ]; then
    alog "Notificación suprimida (--no-notify): $title — $body"
    return 0
  fi
  command -v "$NOTIFY_BIN" >/dev/null 2>&1 || { alog "notify-send no disponible."; return 1; }
  ensure_session_env
  "$NOTIFY_BIN" -a 'Kernel Updater' -u normal -t 8000 -i system-software-update "$title" "$body" >/dev/null 2>&1 || true
  alog "Primer arranque: $CUR_VERSION — $body"
}

# ============================================================
CUR_VERSION="$(uname -r 2>/dev/null || echo 'desconocido')"
ISSUES=0
PROFILE_OK=0
SB_STATE="?"

if ! load_running_config; then
  warn "No se pudo leer /proc/config.gz; se omite la comprobación de perfil."
  BASE_ISSUES="-"
else
  PROFILE_OK="$(profile_check)"
  # profile_check devuelve el número de issues; si trata "0" como OK
  BASE_ISSUES="${PROFILE_OK:-0}"
  [ "${BASE_ISSUES:-0}" -eq 0 ] && PROFILE_OK=1 || PROFILE_OK=0
  ISSUES=$((ISSUES + ${BASE_ISSUES:-0}))
fi

sched_check

BT="$(boot_times)"
read -r BT_FW BT_LD BT_KE BT_US BT_TOT <<< "$BT"
TOT_N="${BT_TOT:-0}"; TOT_TXT="${BT_TOT:-0}s"; KE_N="${BT_KE:-0}"; US_N="${BT_US:-0}"
boot_check "$BT_FW" "$BT_LD" "$BT_KE" "$BT_US" "$BT_TOT"

JCOUNT="$(journal_count)"
journal_check "$JCOUNT"

guard_check "$CUR_VERSION"

FW_COUNT=0
firmware_check

secureboot_check
SB_STATE="${SB_STATE:-—}"

read -r P_VER P_KE P_US P_TOT P_J P_ISS P_TS < "$LAST"
FIRST_BOOT=false
if [ "${P_VER:-}" != "$CUR_VERSION" ]; then FIRST_BOOT=true; fi

# Persistir registro. Con --dry-run NO se escribe: una simulación no puede
# cambiar la línea base de la verificación real siguiente. Antes sí lo hacía, y
# las consecuencias eran dos: (1) `verify-last` quedaba con los tiempos del
# ARRANQUE EN CURSO, así que el "previo" que lee boot_check/journal_check
# acababa siendo el propio arranque y la comparación no comprobaba nada;
# (2) el --dry-run documentado como auditoría tras un reboot ("imprime sin
# notificar, útil tras un reboot para auditar") metía líneas falsas en
# verify-history, que es de donde se saca la referencia de boot.
# El boot_id (v27.33.1) es lo que permite saber si dos líneas son el MISMO
# arranque: sin él, varias verificaciones dentro de un mismo arranque (la unit,
# una manual, un --dry-run) cuentan como arranques independientes y sesgan la
# mediana de la referencia. Va al final de la línea, así que las lecturas
# antiguas (read -r v ke us tot j iss ts) siguen funcionando: se quedan con el
# resto de la línea en la última variable.
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
if [ "$DRY" != true ]; then
  printf '%s %s %s %s %s %s %s %s\n' "$CUR_VERSION" "$KE_N" "$US_N" "$TOT_N" "$JCOUNT" "$ISSUES" "$NOW" "$BOOT_ID" > "$LAST"
  printf '%s\n' "$CUR_VERSION $KE_N $US_N $TOT_N $JCOUNT $ISSUES $NOW $BOOT_ID" >> "$HIST" 2>/dev/null || true
fi

# ----------------- salida -----------------
PROFILE_OUT_TXT="?"
if [ "$PROFILE_OK" = 1 ]; then
  PROFILE_OUT_TXT="OK"
else
  PROFILE_OUT_TXT="${BASE_ISSUES:-?} incidencias"
fi
echo
echo "${C}========================================================${N}"
echo "${C} Verificación post-boot — kernel $CUR_VERSION${N}"
echo "${C}========================================================${N}"
echo " Kernel en ejecución : $CUR_VERSION"
echo " Perfil              : $PROFILE_OUT_TXT"
# Sin ${VAR:+ $(...)} anidado: dentro de una expansión "${...}" las comillas
# del comando sustituto confunden al parser de bash.
_sched_run_lbl="$(sched_label "$SCHED_RUNNING")"
_sched_exp_lbl=""
[ -n "$SCHED_EXPECTED" ] && _sched_exp_lbl=" [build: $(sched_label "$SCHED_EXPECTED")]"
echo " Scheduler           : ${_sched_run_lbl}${_sched_exp_lbl}"
echo " Boot (systemd)      : total $TOT_TXT (previo: ${P_TOT:-—}s, ${P_VER:-—})"
echo " Journal (boot atual): $JCOUNT patrones (previo: ${P_J:-—})"
echo " Firmware            : $FW_COUNT problema(s)"
 echo " Secure Boot         : $SB_STATE"
 echo " Incidencias         : $ISSUES"
 logger_line="${CUR_VERSION} perf=$PROFILE_OK boot=$TOT_N j=$JCOUNT fw=$FW_COUNT sb=${SB_STATE:-?} iss=$ISSUES prev=${P_TOT:-0} prevver=${P_VER:-none}"
alog "verify done: $logger_line"

# v27.31.21: solo se notifica si el estado cambió. Con --dry-run no se guarda
# el estado (una simulación no debe callar la notificación real siguiente).
if [ "$ISSUES" -gt 0 ]; then
  if notify_state_changed; then
    notify_issues
    [ "$DRY" = true ] && echo "  RESULTADO: $ISSUES incidencia(s) detectadas (estado nuevo: se notifica)."
  else
    [ "$DRY" = true ] && echo "  RESULTADO: $ISSUES incidencia(s) ya notificadas; sin cambios desde la última verificación (no se repite la notificación)."
  fi
elif [ "$FIRST_BOOT" = true ]; then
  # Arrancar un kernel nuevo siempre es novedad: se avisa aunque esté limpio.
  notify_first_boot
  [ "$DRY" = true ] && echo "  RESULTADO: sin incidencias (primer arranque de $CUR_VERSION)."
else
  if notify_state_changed; then
    notify_issues
    [ "$DRY" = true ] && echo "  RESULTADO: sin incidencias (estado nuevo: se notifica la resolución)."
  else
    [ "$DRY" = true ] && echo "  RESULTADO: sin incidencias, sin cambios."
  fi
fi

# Guardar la firma del estado actual: a partir de aquí, repetirlo no notifica.
if [ "$DRY" != true ]; then
  # \n final a propósito: sin él, `while read` se salta la última línea, que es
  # justo la que dice qué estado se guardó.
  { verify_state_fingerprint; printf '\n'; } > "$NOTIFY_STATE" 2>/dev/null || true
fi

exit 0