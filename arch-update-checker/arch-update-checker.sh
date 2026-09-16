#!/usr/bin/env bash
set -uo pipefail

STATE_DIR="/var/cache/arch-update-checker"
PENDING_FILE="${STATE_DIR}/pending"
HASH_FILE="${STATE_DIR}/hash"
NEWS_CACHE="${STATE_DIR}/news-cache"
AUR_RPC="https://aur.archlinux.org/rpc/v5/info"
NEWS_URL="https://archlinux.org/feeds/news/"
NEWS_SEEN="${STATE_DIR}/news-seen"
REPOS_REGEX='^(core|extra|multilib|core[-_]x86[-_]64[-_]v3|extra[-_]x86[-_]64[-_]v3|multilib[-_]x86[-_]64[-_]v3)$'
AUR_CHUNK_SIZE=130

# Parseo de argumentos
SKIP_NEWS=0
QUICK_REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --skip-news)   SKIP_NEWS=1 ;;
    --quick-refresh) QUICK_REFRESH=1; SKIP_NEWS=1 ;;
  esac
done

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

if [[ ${EUID:-0} -ne 0 ]]; then
  log "Este script debe ejecutarse como root."
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 755 "$STATE_DIR"

PACMAN_DB="$(pacman-conf DBPath 2>/dev/null || echo /var/lib/pacman)"
PACMAN_DB="${PACMAN_DB%/}"
LOCK_FILE="${PACMAN_DB}/db.lck"

notify_users() {
  local hash="$1"
  command -v runuser >/dev/null 2>&1 || return 0
  [[ -x /usr/local/bin/arch-update-notify-agent.sh ]] || return 0
  local uid user bus home sid leader line dpy wdisp desk
  while read -r uid user; do
    [[ "$uid" =~ ^[0-9]+$ && -n "$user" ]] || continue
    (( uid >= 1000 && uid < 65000 )) || continue
    bus="/run/user/${uid}/bus"
    [[ -S "$bus" ]] || continue
    home="$(getent passwd "$user" | cut -d: -f6)"
    [[ -n "$home" ]] || continue

    dpy=""; wdisp=""; desk=""
    sid="$(loginctl show-user "$user" --property=Display --value 2>/dev/null)"
    if [[ -n "$sid" ]]; then
      leader="$(loginctl show-session "$sid" --property=Leader --value 2>/dev/null)"
      if [[ -n "$leader" && -r "/proc/$leader/environ" ]]; then
        while IFS= read -r line; do
          case "$line" in
            DISPLAY=*) dpy="${line#DISPLAY=}" ;;
            WAYLAND_DISPLAY=*) wdisp="${line#WAYLAND_DISPLAY=}" ;;
            XDG_CURRENT_DESKTOP=*) desk="${line#XDG_CURRENT_DESKTOP=}" ;;
          esac
        done < <(tr '\0' '\n' < "/proc/$leader/environ" 2>/dev/null)
      fi
    fi

    local -a extra=()
    [[ -n "$dpy" ]] && extra+=(DISPLAY="$dpy")
    [[ -n "$wdisp" ]] && extra+=(WAYLAND_DISPLAY="$wdisp")
    [[ -n "$desk" ]] && extra+=(XDG_CURRENT_DESKTOP="$desk")

    runuser -u "$user" -- env \
      HOME="$home" \
      XDG_RUNTIME_DIR="/run/user/${uid}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" \
      "${extra[@]}" \
      setsid nohup /usr/local/bin/arch-update-notify-agent.sh >/dev/null 2>&1 &
  done < <(loginctl list-users --no-legend 2>/dev/null | awk '{print $1, $2}')
}

decode_entities() {
  local s="$1"
  s="${s//&lt;/<}"; s="${s//&gt;/>}"; s="${s//&quot;/\"}"
  s="${s//&#39;/'}"; s="${s//&apos;/'}"; s="${s//&nbsp;/ }"
  s="${s//&mdash;/—}"; s="${s//&ndash;/–}"; s="${s//&amp;/&}"
  local ent cp esc ch
  while [[ "$s" =~ \&#(x[0-9a-fA-F]+|[0-9]+)\; ]]; do
    ent="${BASH_REMATCH[0]}"
    cp="${BASH_REMATCH[1]}"
    [[ "$cp" =~ ^x ]] && cp=$(( 16#${cp#x} ))
    if (( cp >= 32 && cp < 0x110000 )); then
      printf -v esc '\\U%08x' "$cp"
      printf -v ch '%b' "$esc"
      s="${s//"$ent"/$ch}"
    else
      s="${s//"$ent"/}"
    fi
  done
  printf '%s' "$s"
}

is_pacman_busy() {
  if command -v fuser >/dev/null 2>&1; then
    fuser -s "$LOCK_FILE" 2>/dev/null && return 0
  fi
  return 1
}

if (( QUICK_REFRESH == 0 )) && is_pacman_busy; then
  log "Pacman está ocupado; se omite esta comprobación."
  exit 0
fi

TMP_DB=""
cleanup() { [[ -n "${TMP_DB:-}" ]] && rm -rf "${TMP_DB}"; }
trap cleanup EXIT INT TERM

### REPOS OFICIALES ###
official_updates=""; official_count=0; official_checked=0

if (( QUICK_REFRESH == 1 )); then
  # Modo rápido: la BD local ya está sincronizada tras el pacman -Syu previo
  official_updates=$(pacman -Qu --print-format '%r %n %v' 2>/dev/null |
    awk -v re="$REPOS_REGEX" '$1 ~ re {print $1"/"$2" -> "$3}' | sort -u)
  [[ -n "$official_updates" ]] && official_count=$(printf '%s\n' "$official_updates" | wc -l)
  official_checked=1
else
  # Modo completo: sincronizar en BD temporal para evitar partial upgrades
  TMP_DB="$(mktemp -d /tmp/arch-update-checker.XXXXXX)" || {
    log "No se pudo crear el directorio temporal."
    exit 1
  }
  chmod 755 "$TMP_DB"
  mkdir -p "$TMP_DB/local" "$TMP_DB/sync"
  chmod 755 "$TMP_DB/local" "$TMP_DB/sync"
  if [[ -d "$PACMAN_DB/local" ]]; then
    cp -a "$PACMAN_DB/local/." "$TMP_DB/local/" >/dev/null 2>&1 || true
  fi
  
  sync_ok=0
  for attempt in 1 2 3; do
    if pacman --dbpath "$TMP_DB" -Sy --logfile /dev/null >/dev/null 2>&1; then
      sync_ok=1; break
    fi
    log "No se pudo sincronizar la BD temporal de pacman (intento ${attempt}/3); esperando 15 s."
    sleep 15
  done
  if [[ $sync_ok -eq 1 ]]; then
    official_checked=1
    official_updates=$(pacman --dbpath "$TMP_DB" -Sup --print-format '%r %n %v' 2>/dev/null |
      awk -v re="$REPOS_REGEX" '$1 ~ re {print $1"/"$2" -> "$3}' | sort -u)
    [[ -n "$official_updates" ]] && official_count=$(printf '%s\n' "$official_updates" | wc -l)
  else
    log "No se pudo comprobar repos oficiales."
  fi
fi

### AUR ###
aur_updates=""; aur_count=0; aur_checked=0

if (( QUICK_REFRESH == 1 )); then
  # Modo rápido: asumir 0 (el AUR helper ya actualizó exitosamente)
  aur_checked=1
  aur_count=0
else
  # Modo completo: consultar AUR RPC
  declare -A inst_ver=()
  while read -r pkg ver; do
    [[ -n "$pkg" ]] && inst_ver["$pkg"]="$ver"
  done < <(pacman -Qm 2>/dev/null)
  if (( ${#inst_ver[@]} == 0 )); then
    aur_checked=1
  elif command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v vercmp >/dev/null 2>&1; then
    foreign_pkgs=("${!inst_ver[@]}")
    aur_failed=0
    for ((i = 0; i < ${#foreign_pkgs[@]}; i += AUR_CHUNK_SIZE)); do
      chunk=("${foreign_pkgs[@]:i:AUR_CHUNK_SIZE}")
      args=()
      for p in "${chunk[@]}"; do args+=(--data-urlencode "arg[]=$p"); done
      if response=$(curl -sG --fail --max-time 30 "$AUR_RPC" "${args[@]}"); then
        while IFS=$'\t' read -r name aur_ver; do
          [[ -n "$name" && -n "$aur_ver" ]] || continue
          inst="${inst_ver[$name]:-}"
          [[ -n "$inst" ]] || continue
          if [[ $(vercmp "$aur_ver" "$inst") -gt 0 ]]; then
            aur_updates+="aur/${name} -> ${aur_ver}"$'\n'
          fi
        done < <(jq -r '(.results // [])[] | select(.Name != null and .Version != null) | [.Name, .Version] | @tsv' <<<"$response" 2>/dev/null)
        sleep 1
      else
        aur_failed=1
        log "Fallo consultando AUR RPC para un lote de paquetes."
      fi
    done
    (( aur_failed == 0 )) && aur_checked=1
  else
    log "Faltan curl/jq/vercmp; AUR no comprobado."
  fi
  aur_updates="${aur_updates%$'\n'}"
  if [[ -n "$aur_updates" ]]; then
    aur_updates="$(printf '%s\n' "$aur_updates" | sort -u)"
    aur_count=$(printf '%s\n' "$aur_updates" | wc -l)
  fi
fi

### FLATPAK ###
flatpak_updates=""; flatpak_count=0; flatpak_checked=1

if (( QUICK_REFRESH == 1 )); then
  # Modo rápido: asumir 0 (flatpak update ya actualizó exitosamente)
  flatpak_count=0
else
  # Modo completo: consultar remotos
  flatpak_list_updates() {
    local out=""
    if out=$("$@" --updates --columns=application 2>/dev/null); then :; else out=""; fi
    if [[ -z "$out" ]]; then out=$("$@" --updates 2>/dev/null | awk '{print $1}'); fi
    printf '%s\n' "$out" | sed '/^[[:space:]]*$/d'
  }
  if command -v flatpak >/dev/null 2>&1; then
    if [[ -d /var/lib/flatpak ]]; then
      while read -r app; do
        [[ -n "$app" ]] && flatpak_updates+="flatpak/system: ${app}"$'\n'
      done < <(flatpak_list_updates flatpak remote-ls --system)
    fi
    while IFS=: read -r user _ uid _ _ home _; do
      [[ "$uid" =~ ^[0-9]+$ ]] || continue
      (( uid >= 1000 && uid < 65000 )) || continue
      [[ -n "$home" && -d "$home" && -d "$home/.local/share/flatpak" ]] || continue
      while read -r app; do
        [[ -n "$app" ]] && flatpak_updates+="flatpak/user(${user}): ${app}"$'\n'
      done < <(flatpak_list_updates runuser -u "$user" -- env HOME="$home" XDG_RUNTIME_DIR="/run/user/${uid}" flatpak remote-ls --user)
    done < <(getent passwd)
    flatpak_updates="${flatpak_updates%$'\n'}"
    if [[ -n "$flatpak_updates" ]]; then
      flatpak_updates="$(printf '%s\n' "$flatpak_updates" | sort -u)"
      flatpak_count=$(printf '%s\n' "$flatpak_updates" | wc -l)
    fi
  else
    log "flatpak no está instalado; se omite Flatpak."
  fi
fi

### NOTICIAS DE ARCH LINUX ###
news_updates=""; news_count=0; news_checked=0

if (( SKIP_NEWS == 1 )); then
  # Leer del caché si existe
  if [[ -s "$NEWS_CACHE" ]]; then
    news_updates="$(cat "$NEWS_CACHE")"
    news_count=$(printf '%s' "$news_updates" | grep -c '^• ' 2>/dev/null || echo 0)
    news_checked=1
    log "Noticias cargadas desde caché (${news_count} entradas)."
  fi
else
  # Consulta completa al feed
  if command -v curl >/dev/null 2>&1; then
    if feed="$(curl -s --fail --max-time 30 "$NEWS_URL")"; then
      news_checked=1
      baseline=0; [[ -f "$NEWS_SEEN" ]] || baseline=1
      now_epoch="$(date +%s)"
      baseline_days="${NEWS_BASELINE_DAYS:-3}"
      cutoff_epoch=$(( now_epoch - baseline_days * 86400 ))
      seen_add=""
      while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        n_link="$(grep -oP '(?<=<link>)[^<]*(?=</link>)' <<<"$item" | head -n 1)"
        n_title="$(grep -oP '(?<=<title>)[^<]*(?=</title>)' <<<"$item" | head -n 1)"
        n_pub="$(grep -oP '(?<=<pubDate>)[^<]*(?=</pubDate>)' <<<"$item" | head -n 1)"
        [[ -n "$n_link" ]] || continue
        n_title="$(decode_entities "${n_title:-Sin título}")"
        if [[ -f "$NEWS_SEEN" ]] && grep -Fxq "$n_link" "$NEWS_SEEN"; then continue; fi
        if (( baseline == 1 )); then
          n_epoch="$(date -d "$n_pub" +%s 2>/dev/null || echo 0)"
          if (( n_epoch < cutoff_epoch )); then seen_add+="${n_link}"$'\n'; continue; fi
        fi
        n_date="$(date -d "$n_pub" '+%Y-%m-%d' 2>/dev/null || echo "")"
        news_updates+="• ${n_title} (${n_date})"$'\n'"  ${n_link}"$'\n'
        news_count=$(( news_count + 1 ))
        seen_add+="${n_link}"$'\n'
      done < <(printf '%s' "$feed" | tr -d '\n\r' | grep -oP '<item>.*?</item>')
      if [[ -n "$seen_add" ]]; then
        printf '%s' "$seen_add" >> "$NEWS_SEEN"
        tail -n 200 "$NEWS_SEEN" > "$NEWS_SEEN.tmp" && mv "$NEWS_SEEN.tmp" "$NEWS_SEEN"
      fi
      touch "$NEWS_SEEN"; chmod 644 "$NEWS_SEEN"
    else
      log "No se pudo descargar el feed de noticias de Arch Linux."
    fi
  else
    log "curl no disponible; noticias omitidas."
  fi

  # Guardar en caché
  if [[ -n "$news_updates" ]]; then
    printf '%s' "$news_updates" > "$NEWS_CACHE"
  else
    rm -f "$NEWS_CACHE"
  fi
fi

### RESUMEN Y NOTIFICACIÓN ###
total=$((official_count + aur_count + flatpak_count))
log "Resultado: oficiales=${official_count}, AUR=${aur_count}, Flatpak=${flatpak_count}, noticias=${news_count}."

details=""
if [[ -n "$official_updates" ]]; then
  details+="Repositorios oficiales (${official_count}):"$'\n'"${official_updates}"$'\n\n'
fi
if [[ -n "$aur_updates" ]]; then
  details+="AUR (${aur_count}):"$'\n'"${aur_updates}"$'\n\n'
fi
if [[ -n "$flatpak_updates" ]]; then
  details+="Flatpak (${flatpak_count}):"$'\n'"${flatpak_updates}"$'\n\n'
fi
if [[ -n "$news_updates" ]]; then
  details+="Noticias nuevas de Arch Linux (${news_count}):"$'\n'"${news_updates}"$'\n\n'
fi

if (( total > 0 || news_count > 0 )); then
  parts=()
  (( total > 0 )) && parts+=("actualizaciones (${total})")
  (( news_count > 0 )) && parts+=("noticias (${news_count})")
  title=""
  if (( ${#parts[@]} > 0 )); then
    title=$(printf '%s' "${parts[0]}"; for p in "${parts[@]:1}"; do printf ', %s' "$p"; done)
    title="${title^}"
  fi
  [[ -z "$title" ]] && title="Novedades del sistema"

  new_hash="$(printf '%s' "$details" | sha256sum | cut -d' ' -f1)"
  old_hash=""; [[ -f "$HASH_FILE" ]] && old_hash="$(cat "$HASH_FILE" 2>/dev/null || true)"

  tmp_file="$(mktemp)"
  cat > "$tmp_file" <<EOF
${title}
Repositorios oficiales: ${official_count} | AUR: ${aur_count} | Flatpak: ${flatpak_count} | Noticias: ${news_count}
Generado: $(date '+%Y-%m-%d %H:%M:%S %Z')

${details}
EOF
  install -m 644 "$tmp_file" "$PENDING_FILE"
  rm -f "$tmp_file"

  if [[ "$new_hash" != "$old_hash" ]]; then
    notify_users "$new_hash"
  else
    log "Sin cambios desde la última comprobación; no se vuelve a notificar."
  fi
  printf '%s\n' "$new_hash" > "$HASH_FILE"
  chmod 644 "$HASH_FILE"
else
  if (( official_checked == 1 && aur_checked == 1 && flatpak_checked == 1 && news_checked == 1 )); then
    rm -f "$PENDING_FILE" "$HASH_FILE"
    log "No hay actualizaciones ni noticias nuevas."
  else
    log "Comprobación incompleta; se conserva el estado anterior si existía."
  fi
fi

exit 0