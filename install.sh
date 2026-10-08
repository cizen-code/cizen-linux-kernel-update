#!/usr/bin/env bash
set -Eeuo pipefail
LC_ALL=C

usage() {
  cat <<'USAGE'
Uso: install.sh [--prefix=/usr/local] [--bindir=/usr/local/bin] [--uninstall]
USAGE
  exit "${1:-0}"
}

UNINSTALL=0
PREFIX=/usr/local
BINDIR=/usr/local/bin

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) UNINSTALL=1; shift ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    --bindir=*) BINDIR="${1#*=}"; shift ;;
    -h|--help) usage 0 ;;
    *) usage 1 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SUITE="${REPO_DIR}/kernel-update"
MANIFEST="${REPO_DIR}/MANIFEST.sha256"
SUITE_DEST="${BINDIR}/kernel-update"
UKI_SYNC_SRC="${SRC_SUITE}/cizen-uki-sync"
UKI_SYNC_DEST="${BINDIR}/cizen-uki-sync"

run_priv() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
    return $?
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
    return $?
  fi
  sudo "$@"
}

generate_manifest() {
  local out="$1"
  : > "$out"
  local f m d rel
  while IFS= read -r -d '' f; do
    rel="${f#${REPO_DIR}/}"
    # .git y los .bak locales no se despliegan ni se comparan: incluirlos
    # rompía la paridad (949 objetos git en el manifest y .bak que el motor
    # regenera al editar un perfil).
    case "$rel" in
      MANIFEST.sha256|.git|.git/*|*.bak|*.bak-*) continue ;;
    esac
    if [[ -x "$f" ]]; then
      m=755
    else
      m=644
    fi
    d="$(dirname "${f#${REPO_DIR}/}")"
    if [[ "$d" == "." ]]; then
      printf '%s  %s\n' "$(sha256sum "$f" | awk '{print $1}')" "${f#${REPO_DIR}/}" >> "$out"
    else
      printf '%s  %s\n' "$(sha256sum "$f" | awk '{print $1}')" "${f#${REPO_DIR}/}" >> "$out"
    fi
  done < <(find "$REPO_DIR" -type f -print0 | sort -z)
  # normalizar a formato sha256sum estándar (2 espacios)
  sed -i 's/  */  /g' "$out"
}

install_suite_dir() {
  local src="$SRC_SUITE" dest="$SUITE_DEST" tmp
  tmp="${BINDIR}/.kernel-update.new.$$"
  run_priv rm -rf "$tmp"
  run_priv mkdir -p "$tmp"
  while IFS= read -r -d '' f; do
    rel="${f#${src}/}"
    drel="$(dirname "$rel")"
    tdir="${tmp}/${drel}"
    if [[ "$drel" == "." ]]; then
      tdir="$tmp"
    fi
    run_priv mkdir -p "$tdir"
    if [[ -x "$f" ]]; then
      run_priv install -m 755 -o root -g root "$f" "${tdir}/$(basename "$f")"
    else
      run_priv install -m 644 -o root -g root "$f" "${tdir}/$(basename "$f")"
    fi
  done < <(find "$src" -type f -print0 | sort -z)
  run_priv chown -R root:root "$tmp"
  run_priv rm -rf "${BINDIR}/.kernel-update.new"
  run_priv mv "$tmp" "${BINDIR}/.kernel-update.new"
  run_priv rm -rf "$dest"
  run_priv mv "${BINDIR}/.kernel-update.new" "$dest"
}

install_uki_sync() {
  local src="$UKI_SYNC_SRC" dest="$UKI_SYNC_DEST" tmp
  [[ -f "$src" ]] || return 0
  tmp="${dest}.new.$$"
  run_priv install -m 755 -o root -g root "$src" "$tmp"
  run_priv chown root:root "$tmp"
  run_priv mv -f "$tmp" "$dest"
}

install_units() {
  local sysd_user="${REPO_DIR}/systemd/user"
  local sysd_sys="${REPO_DIR}/systemd/system"
  if [[ -d "$sysd_user" ]]; then
    while IFS= read -r -d '' f; do
      run_priv install -m 644 -o root -g root "$f" "/etc/systemd/user/$(basename "$f")"
    done < <(find "$sysd_user" -name '*.service' -o -name '*.timer' -print0 2>/dev/null | sort -z)
  fi
  if [[ -d "$sysd_sys" ]]; then
    while IFS= read -r -d '' f; do
      run_priv install -m 644 -o root -g root "$f" "/etc/systemd/system/$(basename "$f")"
    done < <(find "$sysd_sys" -name '*.service' -o -name '*.timer' -print0 2>/dev/null | sort -z)
  fi
  if [[ $EUID -eq 0 ]] || sudo -n true >/dev/null 2>&1; then
    run_priv systemctl daemon-reload 2>/dev/null || true
  fi
}

verify_parity() {
  local manifest="$MANIFEST"
  if [[ ! -f "$manifest" ]]; then
    echo "WARN: No existe MANIFEST.sha256 en repo (se genera ahora)" >&2
    generate_manifest "$manifest"
  fi
  if [[ ! -d "$SUITE_DEST" ]]; then
    echo "ERROR: Suite no instalada en $SUITE_DEST" >&2
    return 1
  fi
  if [[ ! -f "$UKI_SYNC_DEST" ]]; then
    echo "ERROR: cizen-uki-sync no instalado en $UKI_SYNC_DEST" >&2
    return 1
  fi
  local tmpm
  tmpm="$(mktemp)"
  (cd "$REPO_DIR" && sha256sum --check "$manifest" >/dev/null 2>"$tmpm") && {
    rm -f "$tmpm"
    local n
    n="$(wc -l < "$manifest" | tr -d ' ')"
    echo "Verificación de paridad: OK (${n} ficheros)"
    return 0
  } || {
    echo "ERROR: Discrepancia de paridad entre repo e instalado:" >&2
    cat "$tmpm" >&2
    rm -f "$tmpm"
    return 1
  }
}

bash_n_installed() {
  if [[ -d "$SUITE_DEST" ]]; then
    (cd "$SUITE_DEST" && bash -n *.sh cizen-uki-sync >/dev/null 2>&1) || return 1
  fi
  return 0
}

uninstall_all() {
  run_priv rm -rf "$SUITE_DEST"
  run_priv rm -f "$UKI_SYNC_DEST"
  echo "Desinstalado: $SUITE_DEST, $UKI_SYNC_DEST"
}

main() {
  if [[ $UNINSTALL -eq 1 ]]; then
    uninstall_all
    exit 0
  fi
  generate_manifest "$MANIFEST"
  install_suite_dir
  install_uki_sync
  install_units
  verify_parity
  bash_n_installed
}

main "$@"
