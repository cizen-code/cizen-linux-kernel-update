#!/usr/bin/env bash
set -u

STATE_DIR="/var/cache/arch-update-checker"
PENDING="${STATE_DIR}/pending"
HASH_FILE="${STATE_DIR}/hash"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/arch-update-checker"
MARKER="${CACHE_DIR}/last-notified-hash"
LOG="${CACHE_DIR}/agent.log"
NEWS_URL="https://archlinux.org/news/"

mkdir -p "$CACHE_DIR" 2>/dev/null || true
if [[ -f "$LOG" ]] && (( $(stat -c%s "$LOG" 2>/dev/null || echo 0) > 524288 )); then
  mv "$LOG" "${LOG}.1" 2>/dev/null || true
fi
alog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

[[ -s "$PENDING" ]] || exit 0
command -v notify-send >/dev/null 2>&1 || exit 0

pull_env_from_pid() {
  local pid="$1" line
  [[ -r "/proc/$pid/environ" ]] || return 0
  while IFS= read -r line; do
    case "$line" in
      DISPLAY=*) [[ -n "${DISPLAY:-}" ]] || export DISPLAY="${line#DISPLAY=}" ;;
      WAYLAND_DISPLAY=*) [[ -n "${WAYLAND_DISPLAY:-}" ]] || export WAYLAND_DISPLAY="${line#WAYLAND_DISPLAY=}" ;;
      XDG_CURRENT_DESKTOP=*) [[ -n "${XDG_CURRENT_DESKTOP:-}" ]] || export XDG_CURRENT_DESKTOP="${line#XDG_CURRENT_DESKTOP=}" ;;
      XDG_DATA_DIRS=*) [[ -n "${XDG_DATA_DIRS:-}" ]] || export XDG_DATA_DIRS="${line#XDG_DATA_DIRS=}" ;;
    esac
  done < <(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null)
}

me="${USER:-$(id -un)}"
if [[ -z "${XDG_CURRENT_DESKTOP:-}" || -z "${XDG_DATA_DIRS:-}" || ( -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ) ]]; then
  sid="$(loginctl show-user "$me" --property=Display --value 2>/dev/null)"
  stype=""
  if [[ -n "$sid" ]]; then
    stype="$(loginctl show-session "$sid" --property=Type --value 2>/dev/null)"
    leader="$(loginctl show-session "$sid" --property=Leader --value 2>/dev/null)"
    [[ -n "$leader" ]] && pull_env_from_pid "$leader"
  fi
  if [[ -z "${XDG_CURRENT_DESKTOP:-}" || -z "${XDG_DATA_DIRS:-}" ]]; then
    for name in plasmashell kwin_wayland kwin_x11 gnome-shell xfce4-session cinnamon sway; do
      pid="$(pgrep -u "$me" -x "$name" 2>/dev/null | head -n 1)"
      [[ -n "$pid" ]] && pull_env_from_pid "$pid"
      [[ -n "${XDG_CURRENT_DESKTOP:-}" && -n "${XDG_DATA_DIRS:-}" ]] && break
    done
  fi
  if [[ -z "${XDG_CURRENT_DESKTOP:-}" || -z "${XDG_DATA_DIRS:-}" ]]; then
    for pid in $(pgrep -u "$me" 2>/dev/null); do
      pull_env_from_pid "$pid"
      [[ -n "${XDG_CURRENT_DESKTOP:-}" && -n "${XDG_DATA_DIRS:-}" ]] && break
    done
  fi
  if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
    if [[ "$stype" == "wayland" ]]; then
      export WAYLAND_DISPLAY="wayland-0"
    else
      export DISPLAY=":0"
    fi
  fi
  [[ -n "${XDG_DATA_DIRS:-}" ]] || export XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"
  alog "Entorno: tipo=${stype:-?} DESKTOP=${XDG_CURRENT_DESKTOP:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-} DISPLAY=${DISPLAY:-} DATA_DIRS=${XDG_DATA_DIRS:-}"
fi

open_url() {
  local url="$1"
  if { [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]] || [[ -n "${KDE_FULL_SESSION:-}" ]]; } && command -v kde-open >/dev/null 2>&1; then
    alog "Abriendo URL con kde-open"
    setsid kde-open "$url" >/dev/null 2>&1 &
    return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    alog "Abriendo URL con xdg-open"
    setsid xdg-open "$url" >/dev/null 2>&1 &
    return 0
  fi
  if command -v gio >/dev/null 2>&1; then
    alog "Abriendo URL con gio"
    setsid gio open "$url" >/dev/null 2>&1 &
    return 0
  fi
  alog "ERROR: ningún abridor de URLs disponible"
  return 1
}

current_hash=""
[[ -f "$HASH_FILE" ]] && current_hash="$(cat "$HASH_FILE" 2>/dev/null || true)"

if [[ -n "$current_hash" && -f "$MARKER" && "$(cat "$MARKER" 2>/dev/null || true)" == "$current_hash" ]]; then
  alog "Ya notificado para este hash; se omite."
  exit 0
fi

TITLE="$(head -n 1 "$PENDING")"
SUMMARY="$(sed -n '2p' "$PENDING")"
BODY="${SUMMARY}"$'\n'"Usa los botones para actualizar o ver el informe completo."

actions=()
if notify-send --help 2>&1 | grep -q -- '--action'; then
  actions+=(--action=update="🔄 Actualizar ahora" --action=details="📋 Ver detalles")
  if grep -q "Noticias nuevas" "$PENDING"; then
    actions+=(--action=news="📰 Ver noticias")
  fi
fi

resp=""
if (( ${#actions[@]} > 0 )); then
  resp="$(notify-send -a 'Arch Update Checker' -u critical -t 0 -i system-software-update \
    "${actions[@]}" "$TITLE" "$BODY" 2>/dev/null || true)"
else
  notify-send -a 'Arch Update Checker' -u critical -t 0 -i system-software-update \
    "$TITLE" "$BODY" >/dev/null 2>&1 || true
fi
alog "Respuesta de la notificación: '${resp:-（ninguna）}'"

if [[ -n "$current_hash" ]]; then
  printf '%s\n' "$current_hash" >"$MARKER" 2>/dev/null || true
fi

case "$resp" in
  update)
    alog "Acción: Actualizar ahora"
    /usr/local/bin/arch-open-terminal.sh /usr/local/bin/arch-apply-updates.sh
    ;;
  details|default)
    alog "Acción: Ver detalles"
    /usr/local/bin/arch-open-terminal.sh /usr/local/bin/arch-show-pending.sh
    ;;
  news)
    alog "Acción: Ver noticias"
    open_url "$NEWS_URL"
    ;;
esac

exit 0