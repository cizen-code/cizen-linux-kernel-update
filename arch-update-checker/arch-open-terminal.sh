#!/usr/bin/env bash
set -u
cmd="${1:-bash}"
have() { command -v "$1" >/dev/null 2>&1; }
desk="${XDG_CURRENT_DESKTOP:-}"
logf="${XDG_CACHE_HOME:-$HOME/.cache}/arch-update-checker/open-terminal.log"
mkdir -p "$(dirname "$logf")" 2>/dev/null || true
if [[ -f "$logf" ]] && (( $(stat -c%s "$logf" 2>/dev/null || echo 0) > 524288 )); then
  mv "$logf" "${logf}.1" 2>/dev/null || true
fi
tlog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$logf" 2>/dev/null || true; }

wrap="AUC_AUTO_WINDOW=1 $cmd"

launch=()
if have foot; then
  launch=(foot -e bash -c "$wrap")
elif [[ "$desk" == *KDE* ]] && have konsole; then
  launch=(konsole -e bash -c "$wrap")
elif [[ "$desk" == *GNOME* ]] && have gnome-terminal; then
  launch=(gnome-terminal -- bash -c "$wrap")
elif [[ "$desk" == *XFCE* ]] && have xfce4-terminal; then
  launch=(xfce4-terminal -e "env $wrap")
elif have kitty; then
  launch=(kitty bash -c "$wrap")
elif have alacritty; then
  launch=(alacritty -e bash -c "$wrap")
elif have ghostty; then
  launch=(ghostty bash -c "$wrap")
elif have konsole; then
  launch=(konsole -e bash -c "$wrap")
elif have gnome-terminal; then
  launch=(gnome-terminal -- bash -c "$wrap")
elif have xfce4-terminal; then
  launch=(xfce4-terminal -e "env $wrap")
elif have xterm; then
  launch=(xterm -e env $wrap)
fi

if (( ${#launch[@]} > 0 )); then
  tlog "desk='${desk}' -> lanzando: ${launch[*]}"
  setsid "${launch[@]}" >/dev/null 2>&1 &
  exit 0
fi
tlog "desk='${desk}' -> ERROR: ninguna terminal disponible"
exit 1