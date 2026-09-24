#!/usr/bin/env bash
# ============================================================
# kernel-update-verify.sh — verificación post-boot del kernel Cizen
#
# Corre tras cada arranque (unit de usuario kernel-update-verify.service,
# tras graphical-session.target; también manualmente) y comprueba:
#
#   a) PERFIL   : que la configuración del kernel EN EJECUCIÓN cumple el
#                 perfil cizen (OPTS_ENABLE / CRITICAL_OPTS / SETVAL / SETSTR)
#                 aplicando el mapa de renames, y que el scheduler coincide
#                 con la firma del último build (BORE, BTF si se pidieron).
#   b) BOOT     : compara systemd-analyze (kernel/userspace/total) del boot
#                 actual con el del boot previo registrado y avisa si el total
#                 empeora más allá de un factor/umbral.
#   c) JOURNAL  : cuenta patrones de regresión del kernel (oops/panic/GPU
#                 hang/hung task/... ) en el journal del boot actual y avisa
#                 si aparecen más que en el boot previo.
#   d) GUARD    : avisa si el kernel arrancado NO es el último Cizen instalado
#                 (fallback de sd-boot por boot counting, o selección manual).
#   e) FIRMWARE : por cada módulo cargado, modinfo -F firmware → se verifica que
#                 el fichero exista en /usr/lib/firmware; además se escanea el
#                 journal del kernel por "Direct firmware load failed". Avisa
#                 de cualquier firmware ausente/infallible del boot actual.
#   f) SECURE BOOT: cruza la firma del último build (sb= en last-build) con el
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
#   CIZEN_NOTIFY_BIN         binario de notificación (default notify-send)
#   CIZEN_FIRMWARE_DIR       raíz de firmware a auditar (default /usr/lib/firmware)
# ============================================================

set -uo pipefail
export LC_ALL=C

STATE_DIR="${CIZEN_VERIFY_STATE_DIR:-$HOME/.local/state/kernel-update}"
LOG="$STATE_DIR/verify.log"
LAST="$STATE_DIR/verify-last"
HIST="$STATE_DIR/verify-history"
BUILD_SIG="$STATE_DIR/last-build"
RENAME_MAP_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/kernel-update/rename-map.conf"
NOTIFY_BIN="${CIZEN_NOTIFY_BIN:-notify-send}"
FIRMWARE_DIR="${CIZEN_FIRMWARE_DIR:-/usr/lib/firmware}"
# Sufijo de localversion de los kernels Cizen. Debe coincidir con
# LOCALVERSION_SUFFIX del motor / CIZEN_UKI_SUFFIX de cizen-uki-sync.
CIZEN_VERIFY_SUFFIX="${CIZEN_VERIFY_SUFFIX:--cizen-v3}"

BOOT_FACTOR="${CIZEN_VERIFY_BOOT_FACTOR:-1.35}"
BOOT_MIN_DELTA="${CIZEN_VERIFY_BOOT_MIN_DELTA:-3}"
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
[ "${1:-}" = "--dry-run" ] && DRY=true

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
load_running_config() {
  RUN_CFG=()
  local line
  zcat /proc/config.gz >/dev/null 2>&1 || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)=(.*)$ ]]; then
      RUN_CFG["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
      RUN_CFG["${BASH_REMATCH[1]}"]="n"
    fi
  done < <(zcat /proc/config.gz 2>/dev/null)
  return 0
}

run_state() { # $1 = símbolo (ya resuelto a nombre actual); imprime y/m/n/missing
  if [ -n "${RUN_CFG[$1]+x}" ]; then printf '%s\n' "${RUN_CFG[$1]}"; else printf '%s\n' "missing"; fi
}

declare -A RENAMES=()
load_renames() {
  local key val
  [ -f "$RENAME_MAP_FILE" ] || return 0
  while IFS='=' read -r key val; do
    [ -n "$key" ] && [[ "$key" =~ ^[A-Za-z0-9_]+$ ]] && [ -n "$val" ] && RENAMES["$key"]="$val"
  done < "$RENAME_MAP_FILE"
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
  local opt r st exp line
  local -a bad=()

for opt in "${OPTS_ENABLE[@]:-}"; do
    [ -n "$opt" ] || continue
    r="$(resolve_sym "$opt")"
    st="$(run_state "$r")"
    case "$st" in
      y) : ;; # OPTS_ENABLE exige =y
      m) bad+=("ENABLE: CONFIG_$opt quedó en =m (perfil pide y)") ;;
      n) bad+=("ENABLE: CONFIG_$opt quedó en n") ;;
      *) bad+=("ENABLE: CONFIG_$opt no existe (missing en el kernel en ejecución)") ;;
    esac
  done
  for opt in "${CRITICAL_OPTS[@]:-}"; do
    [ -n "$opt" ] || continue
    r="$(resolve_sym "$opt")"
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
      st="$(run_state "$r")"
      exp="\"${OPTS_SETSTR[$opt]}\""
      if [ "$st" != "missing" ] && [ "$st" != "$exp" ]; then
        bad+=("SETSTR: CONFIG_$opt=$st (esperado $exp)")
      fi
    done
  fi

  issue=0
  if [ "${#bad[@]}" -gt 0 ]; then
    issues=$((issues + ${#bad[@]}))
    pc_warn "El kernel en ejecución NO cumple el perfil (${#bad[@]}):"
    for line in "${bad[@]}"; do pc_out "      $line"; done
  else
    pc_ok "Perfil: el kernel en ejecución cumple OPTS/CRITICAL/SETVAL/SETSTR."
  fi

  # BORE vs firma de build
  local bore_run=""
  if [ -n "${RUN_CFG[SCHED_BORE]+x}" ]; then bore_run="${RUN_CFG[SCHED_BORE]}"; fi
  if [ "${bore_run:-}" = "y" ]; then
    pc_ok "Scheduler BORE presente (SCHED_BORE=y) en ejecución."
  else
    pc_info "Scheduler EEVDF vanilla en ejecución (SCHED_BORE no activo)."
  fi

  # Firmado de módulos
  if [ -n "${RUN_CFG[MODULE_SIG_FORCE]+x}" ] && [ "${RUN_CFG[MODULE_SIG_FORCE]}" = "y" ]; then
    pc_ok "MODULE_SIG_FORCE activo en ejecución."
  fi

  if [ -f "$BUILD_SIG" ]; then
    local sig_bore="no" sig_btf="no" sig_ver="" sig_patches=""
    # shellcheck disable=SC1090,SC1091
    source "$BUILD_SIG"
    sig_bore="${bore:-no}"
    sig_btf="${btf:-no}"
    sig_ver="${version:-}"
    sig_patches="${patches:-}"
    if [ "$sig_bore" = "yes" ] && [ "${bore_run:-}" != "y" ]; then
      pc_warn "El último build pedía BORE pero el kernel arrancado NO lo tiene (SCHED_BORE=${bore_run:-no})."
      issues=$((issues + 1))
    elif [ "$sig_bore" != "yes" ] && [ "${bore_run:-}" = "y" ]; then
      pc_warn "El kernel arrancado tiene BORE pero el último build era vanilla (¿paquete foráneo o rollback?)."
      issues=$((issues + 1))
    fi
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
    # El perfil con el que se firmó el último build (last-build: profile_sha) debe
    # coincidir con el que se valida ahora; si cambió, el build no refleja el
    # perfil vigente y conviene reconstruir. Compatible con firmas antiguas que
    # no traen profile_sha (campo vacío → se omite).
    if [ -n "${profile_sha:-}" ]; then
      local cur_sha=""
      cur_sha="$(sha256sum "$profile" | cut -d' ' -f1 2>/dev/null || true)"
      if [ -n "$cur_sha" ] && [ "$cur_sha" != "$profile_sha" ]; then
        pc_warn "El perfil ($profile) cambió desde el último build (sha actual $cur_sha ≠ registrado $profile_sha): reconstruye el kernel para que refleje el perfil vigente."
        issues=$((issues + 1))
      fi
      unset cur_sha
    fi
  fi
  printf '%s\n' "${issues:-0}"
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

boot_check() {
  # args: fw load kernel userspace total (string)
  local tot="$5" us="$4" ke="$3"
  local p_tot p_ke p_us p_ver p_thr
  read -r p_ver p_ke p_us p_tot p_j p_issues p_ts < "$LAST" 2>/dev/null || return 0
  if [ -z "${p_tot:-}" ] || ! [[ "$p_tot" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [ "$p_tot" = "0" ]; then
    return 0 # sin registro previo comparable
  fi
  if float_ge "$tot" "$p_tot"; then
    p_thr="$(awk -v b="$p_tot" -v f="$BOOT_FACTOR" 'BEGIN{printf "%.1f", b*f}')"
    min_d="$(awk -v a="$p_tot" -v d="$BOOT_MIN_DELTA" 'BEGIN{printf "%.1f", a+d}')"
    if float_ge "$tot" "$p_thr" && float_ge "$tot" "$min_d"; then
      warn "Boot más lento que el previo: $tot s (previo $p_tot s en $p_ver)."
      ISSUES=$((ISSUES + 1))
      return 0
    fi
  fi
  [ "${DRY:-false}" = true ] && info "Boot: total $tot s (kernel $ke s / userspace $us s); previo ${p_tot:-—} s."
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
    # El árbol linux-firmware almacena los binarios comprimidos como .zst
    if [ ! -f "$FIRMWARE_DIR/$rel" ] && [ ! -f "$FIRMWARE_DIR/$rel.zst" ]; then
      printf '%s (%s)\n' "$fw" "$mod"
    fi
  done <<< "$out"
}

firmware_check() {
  local mod f line
  local -a missing=() kfail=() all=()
  FW_COUNT=0
  while IFS= read -r mod; do
    [ -n "$mod" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] && missing+=("$f")
    done < <(firmware_missing_for_module "$mod")
  done < <(cut -d' ' -f1 /proc/modules 2>/dev/null || true)
  while IFS= read -r line; do
    [ -n "$line" ] && kfail+=("$line")
  done < <(journalctl -k -b 2>/dev/null | grep -oiE 'Direct firmware load (for [^ ]+ )?failed|firmware: failed to load [^ ]+|request_firmware[^)]*failed' | sed -E 's/^[[:space:]]+//' | sort -u || true)

  if [ "${#missing[@]}" -eq 0 ] && [ "${#kfail[@]}" -eq 0 ]; then
    [ "${DRY:-false}" = true ] && info "Firmware: presentes los requeridos por los módulos cargados."
    return 0
  fi
  while IFS= read -r f; do [ -n "$f" ] && all+=("$f"); done < <(printf '%s\n' "${missing[@]}" "${kfail[@]}" | sort -u || true)
  FW_COUNT="${#all[@]}"
  warn "Firmware del boot actual: $FW_COUNT problema(s) (ausentes del árbol o fallos de carga):"
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
  case "$(bootctl status 2>/dev/null | grep -m1 'Secure Boot:' || true)" in
    *'enabled')  sboot="HABILITADO" ;;
    *'disabled') sboot="desactivado" ;;
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
notify_issues() {
  local title body prof_txt
  if [ "$PROFILE_OK" = 1 ]; then prof_txt="OK"; else prof_txt="FALLO"; fi
  title="Kernel Cizen: $CUR_VERSION verificado con ${ISSUES} incidencias"
  body="Perfil: $prof_txt | Boot: $TOT_TXT | Journal: $JCOUNT patrones | FW: $FW_COUNT"
  if [ "$DRY" = true ]; then
    echo "  (dry-run) Notificarías: $title — $body"
    return 0
  fi
  command -v "$NOTIFY_BIN" >/dev/null 2>&1 || { alog "notify-send no disponible; no se notifica."; return 1; }
  ensure_session_env
  "$NOTIFY_BIN" -a 'Kernel Updater' -u critical -t 10000 -i dialog-warning "$title" "$body" >/dev/null 2>&1 || true
  alog "Notificación de verificación: $title — $body"
}

notify_first_boot() {
  local title body iss_txt
  if [ "$ISSUES" -gt 0 ]; then iss_txt="$ISSUES incidencias"; else iss_txt="sin incidencias"; fi
  title="Kernel Cizen $CUR_VERSION arrancado"
  body="Verificación post-boot: $iss_txt | boot total $TOT_TXT"
  if [ "$DRY" = true ]; then
    echo "  (dry-run) Notificarías (primer arranque): $title — $body"
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

# Persistir registro
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s %s %s %s %s %s %s\n' "$CUR_VERSION" "$KE_N" "$US_N" "$TOT_N" "$JCOUNT" "$ISSUES" "$NOW" > "$LAST"
printf '%s\n' "$CUR_VERSION $KE_N $US_N $TOT_N $JCOUNT $ISSUES $NOW" >> "$HIST" 2>/dev/null || true

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
echo " Boot (systemd)      : total $TOT_TXT (previo: ${P_TOT:-—}s, ${P_VER:-—})"
echo " Journal (boot atual): $JCOUNT patrones (previo: ${P_J:-—})"
echo " Firmware            : $FW_COUNT problema(s)"
 echo " Secure Boot         : $SB_STATE"
 echo " Incidencias         : $ISSUES"
 logger_line="${CUR_VERSION} perf=$PROFILE_OK boot=$TOT_N j=$JCOUNT fw=$FW_COUNT sb=${SB_STATE:-?} iss=$ISSUES prev=${P_TOT:-0} prevver=${P_VER:-none}"
alog "verify done: $logger_line"

if [ "$ISSUES" -gt 0 ]; then
  notify_issues
  [ "$DRY" = true ] && echo "  RESULTADO: $ISSUES incidencia(s) detectadas."
elif [ "$FIRST_BOOT" = true ]; then
  notify_first_boot
  [ "$DRY" = true ] && echo "  RESULTADO: sin incidencias (primer arranque de $CUR_VERSION)."
else
  [ "$DRY" = true ] && echo "  RESULTADO: sin incidencias."
fi

exit 0