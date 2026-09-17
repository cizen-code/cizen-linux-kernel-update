#!/usr/bin/env bash
# ============================================================
# kernel-update-notify.sh — Notificador de releases kernel.org
# Mallado de kernel-update.sh: consulta exactamente la misma
# fuente (releases.json) y la misma release (latest_stable,
# línea X.Y.Z) que el script de compilación usa por defecto.
#
# Cuando kernel.org publica una release estable posterior a la
# versión Cizen instalada, notifica una ÚNICA vez por release
# (estado persistente en ~/.local/state/kernel-update/) y ofrece
# una acción que abre una terminal con el menú:
#     /usr/local/bin/kernel-update/kernel-update-menu.sh <remote>
# que presenta las opciones check/checkfast/build/buildfast/force/
# check-update, cada una ejecutando kernel-update.sh con los flags
# adecuados.
#
# Uso:
#   ./kernel-update-notify.sh            # ejecución normal (timer/oneshot)
#   ./kernel-update-notify.sh --dry-run  # imprime la decisión sin notificar
#
# Variables de entorno (override):
#   KERNEL_RELEASES_JSON_URL  misma fuente que kernel-update.sh
#   CIZEN_KERNEL_LOCAL_VERSION  fuerza la versión local (tests, --dry-run)
#   CIZEN_NOTIFY_BIN           binario de notificación (default notify-send)
#   CIZEN_KERNEL_SCRIPT        ruta de kernel-update.sh (default /usr/local/bin/kernel-update/kernel-update.sh)
#   CIZEN_KERNEL_MENU_SCRIPT   ruta del menú interactivo (default /usr/local/bin/kernel-update/kernel-update-menu.sh)
#   CIZEN_CONFIG_DIR           dir de configs linux-*-cizen-v3.config (default <dir de KERNEL_SCRIPT>/profiles)
# ============================================================

set -uo pipefail
IFS=$'\n\t'
export LC_ALL=C

KERNEL_RELEASES_JSON_URL="${KERNEL_RELEASES_JSON_URL:-https://www.kernel.org/releases.json}"
KERNEL_SCRIPT="${CIZEN_KERNEL_SCRIPT:-/usr/local/bin/kernel-update/kernel-update.sh}"
MENU_SCRIPT="${CIZEN_KERNEL_MENU_SCRIPT:-/usr/local/bin/kernel-update/kernel-update-menu.sh}"
CONFIG_DIR="${CIZEN_CONFIG_DIR:-$(dirname -- "$KERNEL_SCRIPT")/profiles}"
NOTIFY_BIN="${CIZEN_NOTIFY_BIN:-notify-send}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kernel-update"
LAST_FILE="$STATE_DIR/notify-last-version"
LOG="$STATE_DIR/notify.log"

mkdir -p "$STATE_DIR" 2>/dev/null || true
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 524288 ]; then
  mv -f -- "$LOG" "$LOG.1" 2>/dev/null || true
fi
alog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

version_is_valid() { [[ "$1" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; }

version_gt() {
  local a="$1" b="$2" first
  first="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)"
  [ "$first" = "$b" ] && [ "$a" != "$b" ]
}

# Misma lógica que kernel-update.sh: primero el paquete Cizen actual,
# depois linux-upstream durante la migración y, como último recurso,
# la configuración estable más reciente en CONFIG_DIR.
get_local_kernel_version() {
  local pkgbase installed candidate best_local_version=""
  for pkgbase in linux-cizen-v3 linux-upstream; do
    if pacman -Q "$pkgbase" >/dev/null 2>&1; then
      installed="$(pacman -Q "$pkgbase" | awk 'NR==1 {print $2}')"
      if [[ "$installed" =~ ^([0-9]+\.[0-9]+([.][0-9]+)?)_cizen_v3-[0-9]+$ ]] ||
         [[ "$installed" =~ ^([0-9]+\.[0-9]+([.][0-9]+)?)-[0-9]+$ ]]; then
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

# jq como vía preferida, el mismo fallback sed que kernel-update.sh.
get_remote_latest_stable() {
  local json latest
  json="$(wget -qO- --timeout=30 --tries=2 "$KERNEL_RELEASES_JSON_URL" 2>/dev/null)" || return 1
  if command -v jq >/dev/null 2>&1; then
    latest="$(printf '%s\n' "$json" | jq -r '.latest_stable.version // empty' 2>/dev/null || true)"
  fi
  if [ -z "${latest:-}" ]; then
    latest="$(printf '%s\n' "$json" | tr '\n' ' ' | sed -n 's/.*"latest_stable"[[:space:]]*:[[:space:]]*{[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^" ]*\)"[[:space:]]*}.*/\1/p')"
  fi
  version_is_valid "${latest:-}" || return 1
  printf '%s\n' "$latest"
}

# Variables de sesión gráfica para notify-send bajo systemd --user,
# copy del patrón local arch-update-notify-agent.sh.
pull_env_from_pid() {
  local pid="$1" line
  [ -r "/proc/$pid/environ" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      DISPLAY=*)          [ -n "${DISPLAY:-}" ] || export DISPLAY="${line#DISPLAY=}" ;;
      WAYLAND_DISPLAY=*)  [ -n "${WAYLAND_DISPLAY:-}" ] || export WAYLAND_DISPLAY="${line#WAYLAND_DISPLAY=}" ;;
      XDG_CURRENT_DESKTOP=*) [ -n "${XDG_CURRENT_DESKTOP:-}" ] || export XDG_CURRENT_DESKTOP="${line#XDG_CURRENT_DESKTOP=}" ;;
      XDG_DATA_DIRS=*)    [ -n "${XDG_DATA_DIRS:-}" ] || export XDG_DATA_DIRS="${line#XDG_DATA_DIRS=}" ;;
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
    if [ "$stype" = "wayland" ]; then
      export WAYLAND_DISPLAY="wayland-0"
    else
      export DISPLAY=":0"
    fi
  fi
  [ -n "${XDG_DATA_DIRS:-}" ] || export XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"

  # notify-send necesita XDG_RUNTIME_DIR para el socket del daemon de
  # notificaciones; systemd --user normalmente lo exporta.
  [ -n "${XDG_RUNTIME_DIR:-}" ] && export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
}

notify_update() {
  local local_ver="$1" remote_ver="$2"
  local title body actions=()
  title="Kernel Linux: actualización disponible"
  body="Nueva release estable de kernel.org: ${local_ver} → ${remote_ver}"$'\n'"Haz clic para abrir el menú de kernel-update en la terminal."
  if ! command -v "$NOTIFY_BIN" >/dev/null 2>&1; then
    alog "notify-send no disponible; se registra sin notificar ($local_ver -> $remote_ver)"
    return 1
  fi
  ensure_session_env
  if "$NOTIFY_BIN" --help 2>&1 | grep -q -- '--action'; then
    actions+=(--action=check="Validar y compilar")
    actions+=(--action=dismiss="Descartar")
  fi
  local resp=""
  if [ "${#actions[@]}" -gt 0 ]; then
    resp="$("$NOTIFY_BIN" -a 'Kernel Updater' -u normal -t 0 -i system-software-update \
      "${actions[@]}" "$title" "$body" 2>/dev/null || true)"
  else
    "$NOTIFY_BIN" -a 'Kernel Updater' -u normal -t 0 -i system-software-update \
      "$title" "$body" >/dev/null 2>&1 || true
  fi
  case "$resp" in
    check)
      alog "Acción: abrir menú kernel-update para $remote_ver (script: $MENU_SCRIPT)"
      if [ -x "$MENU_SCRIPT" ] && command -v /usr/local/bin/arch-open-terminal.sh >/dev/null 2>&1; then
        setsid /usr/local/bin/arch-open-terminal.sh "$MENU_SCRIPT $remote_ver" >/dev/null 2>&1 &
      elif [ -x "$KERNEL_SCRIPT" ] && command -v /usr/local/bin/arch-open-terminal.sh >/dev/null 2>&1; then
        alog "Menú no encontrado; fallback a $KERNEL_SCRIPT --check"
        setsid /usr/local/bin/arch-open-terminal.sh "$KERNEL_SCRIPT --check" >/dev/null 2>&1 &
      else
        alog "Acción check solicitada pero no hay terminal/script para abrirla ($MENU_SCRIPT)"
        command -v notify-send >/dev/null 2>&1 && \
          "$NOTIFY_BIN" -a 'Kernel Updater' -u critical -t 10000 \
            "Ejecuta manualmente" "$MENU_SCRIPT $remote_ver" >/dev/null 2>&1 || true
      fi
      ;;
    dismiss) alog "Acción: descartada por el usuario" ;;
    *) alog "Notificación enviada (sin acción; resp='${resp:-ninguna}')" ;;
  esac
}

main() {
  local dry_run=false
  [ "${1:-}" = "--dry-run" ] && dry_run=true

  local remote local last_notified=""
  remote="$(get_remote_latest_stable)" || {
    alog "No se pudo consultar kernel.org ($KERNEL_RELEASES_JSON_URL); se omite."
    return 0
  }
  [ -f "$LAST_FILE" ] && last_notified="$(cat -- "$LAST_FILE" 2>/dev/null || true)"

  local="${CIZEN_KERNEL_LOCAL_VERSION:-$(get_local_kernel_version)}"

  if [ -z "$local" ]; then
    alog "Sin kernel Cizen instalado como referencia; stable remota: $remote. Nada que notificar."
    if [ "$dry_run" = true ]; then
      echo "Sin kernel Cizen identificado como referencia remota local."
      echo "Stable remota de kernel.org: $remote"
    fi
    return 0
  fi

  if [ "$dry_run" = true ]; then
    if version_gt "$remote" "$local"; then
      echo "ACTUALIZACIÓN DISPONIBLE: $local → $remote (ya notificada: ${last_notified:-ninguna})"
    else
      echo "Sin actualización: Cizen=$local  kernel.org=$remote"
    fi
    return 0
  fi

  if version_gt "$remote" "$local"; then
    if [ "$last_notified" = "$remote" ]; then
      alog "Release $remote ya notificada previamente; se omite."
      return 0
    fi
    ok=0
    notify_update "$local" "$remote"; ok=$?
    if [ "$ok" = 0 ] || command -v "$NOTIFY_BIN" >/dev/null 2>&1; then
      printf '%s\n' "$remote" >"$LAST_FILE" 2>/dev/null || true
      alog "Registrada como notificada: $local -> $remote"
    fi
    return 0
  fi

  # Sin actualización y con estado pendiente de una anterior: se limpia la
  # marca para que la PRÓXIMA release nueva (cualquiera) vuelva a notificar
  # una única vez. Ejemplo: se avisó de 7.2.7, el usuario no compila, llega
  # 7.2.8 → debe notificarse de nuevo.
  if [ -n "$last_notified" ]; then
    local note
    if version_gt "$local" "$last_notified"; then
      note="(el kernel local $local ya supera lo notificado $last_notified)"
    else
      note="(kernel local $local; lo notificado $last_notified quedó obsoleto en la rama)"
    fi
    rm -f -- "$LAST_FILE" 2>/dev/null || true
    alog "Marca de notificación limpiada $note"
  fi
  alog "Sin actualización: Cizen=$local  kernel.org=$remote"
  return 0
}

main "$@"
exit 0