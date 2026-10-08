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

if [[ ! -f "$MANIFEST" ]]; then
  echo "Generando manifest desde repo..."
  (cd "$REPO_DIR" && bash -c '
    : > MANIFEST.sha256
    while IFS= read -r -d "" f; do
      case "$f" in *MANIFEST.sha256*) continue;; esac
      if [[ -x "$f" ]]; then m=755; else m=644; fi
      sha256sum "$f" | awk "{print \$1\"  \"substr(\"$f\", ${#PWD}+2)}" >> MANIFEST.sha256
    done < <(find . -type f -print0 | sort -z)
    sed -i "s/  */  /g" MANIFEST.sha256
  ')
fi

if [[ ! -d "$SUITE_DEST" || ! -f "$UKI_SYNC_DEST" ]]; then
  echo "ERROR: Instalación incompleta (falta $SUITE_DEST o $UKI_SYNC_DEST)" >&2
  exit 1
fi

tmpm="$(mktemp)"
if (cd "$REPO_DIR" && sha256sum --check "$MANIFEST" >/dev/null 2>"$tmpm"); then
  n="$(wc -l < "$MANIFEST" | tr -d ' ')"
  rm -f "$tmpm"
  echo "Paridad OK (${n} ficheros). Repo==${SUITE_DEST}, ${UKI_SYNC_DEST}"
  exit 0
else
  echo "ERROR: Discrepancia de paridad:" >&2
  cat "$tmpm" >&2
  rm -f "$tmpm"
  exit 2
fi
