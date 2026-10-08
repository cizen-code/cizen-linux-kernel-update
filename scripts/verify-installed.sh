#!/usr/bin/env bash
set -Eeuo pipefail
LC_ALL=C

PREFIX=/usr/local
BINDIR=/usr/local/bin

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    --bindir=*) BINDIR="${1#*=}"; shift ;;
    -h|--help) echo "Uso: verify-installed.sh [--prefix=/usr/local] [--bindir=/usr/local/bin]"; exit 0 ;;
    *) exit 1 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE_DEST="${BINDIR}/kernel-update"
UKI_SYNC_DEST="${BINDIR}/cizen-uki-sync"
MANIFEST="${REPO_DIR}/MANIFEST.sha256"

# Rel paths reales (el generator anterior hacía substr("$f") dentro de awk: la
# variable $f se expandía como campo de awk, no como shell, y salían paths
# vacíos o colas de .git/objects). Excluye .git y los .bak locales, que se
# regeneran solos en cada edición de perfil y romperían la paridad.
generate_manifest() {
  local out="$1" f rel
  : > "$out"
  while IFS= read -r -d '' f; do
    rel="${f#"${REPO_DIR}"/}"
    case "$rel" in
      MANIFEST.sha256|.git|.git/*|*.bak|*.bak-*) continue ;;
    esac
    printf '%s  %s\n' "$(sha256sum "$f" | awk '{print $1}')" "$rel" >> "$out"
  done < <(find "$REPO_DIR" -type f -print0 | sort -z)
}

if [[ ! -f "$MANIFEST" ]]; then
  echo "Generando manifest desde repo..."
  generate_manifest "$MANIFEST"
fi

if [[ ! -d "$SUITE_DEST" || ! -f "$UKI_SYNC_DEST" ]]; then
  echo "ERROR: Instalación incompleta (falta $SUITE_DEST o $UKI_SYNC_DEST)" >&2
  exit 1
fi

tmpm="$(mktemp)"
if ! (cd "$REPO_DIR" && sha256sum --check "$MANIFEST" >/dev/null 2>"$tmpm"); then
  # El manifest es dato derivado y gitignorado: se regenera y se sigue.
  echo "Aviso: MANIFEST.sha256 desfasado respecto al repo; se regenera..."
  generate_manifest "$MANIFEST"
  if ! (cd "$REPO_DIR" && sha256sum --check "$MANIFEST" >/dev/null 2>"$tmpm"); then
    echo "ERROR: repo y manifest no cuadran tras regenerar:" >&2
    cat "$tmpm" >&2
    rm -f "$tmpm"
    exit 2
  fi
fi
rm -f "$tmpm"

n=0
fails=0
uki_hash=""
while read -r hash path; do
  [[ -n "${path:-}" ]] || continue
  case "$path" in
    kernel-update/*) ;;
    *) continue ;;
  esac
  n=$((n + 1))
  dest="${SUITE_DEST}/${path#kernel-update/}"
  if [[ ! -f "$dest" ]]; then
    echo "FALTA en instalado: $path" >&2
    fails=1
    continue
  fi
  if [[ "$(sha256sum "$dest" | awk '{print $1}')" != "$hash" ]]; then
    echo "DIFIERE: $path" >&2
    fails=1
  fi
  if [[ "$path" == "kernel-update/cizen-uki-sync" ]]; then
    uki_hash="$hash"
  fi
done < "$MANIFEST"

if [[ -n "$uki_hash" ]]; then
  if [[ "$(sha256sum "$UKI_SYNC_DEST" | awk '{print $1}')" != "$uki_hash" ]]; then
    echo "DIFIERE: $UKI_SYNC_DEST (≠ kernel-update/cizen-uki-sync)" >&2
    fails=1
  fi
fi

if [[ "$fails" -ne 0 ]]; then
  echo "ERROR: Discrepancia de paridad entre repo e instalado (arriba)." >&2
  exit 2
fi

echo "Paridad OK ($n ficheros de la suite + ${UKI_SYNC_DEST}). Repo == instalado"
