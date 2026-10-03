#!/usr/bin/env bash
# ============================================================
# kconfig-validate.sh — ¿este perfil sobrevivirá a `make olddefconfig`?
#
# Para qué existe: el motor canta los problemas de Kconfig, pero DESPUÉS de
# descargar, parchear y arrancar un build de media hora. Este banco contesta la
# misma pregunta en un minuto, y es lo que permite revisar un perfil con 319
# `OPTS_DISABLE` sin descubrir en el minuto 25 que faltaba una raíz.
#
# Replica `validate_config()` del motor (`kernel-update.sh`) contra el Kconfig
# REAL de la versión que se va a compilar, y por eso necesita el árbol de fuentes.
# No basta con leer el `.config` del repo: los símbolos que Kconfig poda y los que
# no existen se ven IGUALES ahí, y confundir "no existe" con "ya estaba apagado"
# es exactamente el error que hace que un perfil se llene de ruido.
#
# Reglas de estado, replicadas de `load_config_state()` del motor al pie de la
# letra, porque la primera versión de este banco se las saltó y dio por roto un
# `SETVAL` que estaba perfecto:
#   CONFIG_X=valor   -> el valor CRUDO (así HZ=1000 es "1000", no y/m/n/missing)
#   # CONFIG_X is not set -> "n"
#   ausente          -> "missing"
#
# ── Uso ──────────────────────────────────────────────────────────────────
#   ./kconfig-validate.sh [perfil] [.config base] [árbol de fuentes]
#
# El árbol de fuentes se puede dar por `KCONFIG_SRC_DIR`; si no está, se busca en
# `$CIZEN_STATE_DIR/kconfig-src/linux-<versión>` y, por último, se avisa de cómo
# traerlo con el sha256 comprobado. NO se descarga solo: son 1,8 GiB y no es una
# decisión que deba tomar un banco por su cuenta.
#
#   VERSION=7.2.9
#   KCONFIG_SHA=b4c5dfbe51a364a6c7f03869200f88c8e1f77403539005f14b7fc6bc91b8d8ba
#   mkdir -p ~/.local/state/kernel-update/kconfig-src && cd $_
#   curl -O https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$VERSION.tar.xz
#   curl -O https://cdn.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc
#   sha256sum -c --ignore-missing sha256sums.asc   # tiene que decir linux-$VERSION.tar.xz: OK
#   tar xf linux-$VERSION.tar.xz
# ============================================================
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROF="${1:-$HERE/profiles/cizen-optiplex7050.conf}"
BASE="${2:-$HERE/profiles/linux-7.2.8-cizen-v3.config}"
STATE_DIR="${CIZEN_VERIFY_STATE_DIR:-$HOME/.local/state/kernel-update}"
VER="${KCONFIG_VERSION:-7.2.9}"
SRC="${3:-${KCONFIG_SRC_DIR:-$STATE_DIR/kconfig-src/linux-$VER}}"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
mal()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
bien() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
aviso(){ printf '  \033[33m⚠\033[0m %s\n' "$*"; }

[ -f "$PROF" ] || { mal "no encuentro el perfil: $PROF"; exit 2; }
[ -f "$BASE" ] || { mal "no encuentro el .config base: $BASE"; exit 2; }
if [ ! -d "$SRC" ] || [ ! -x "$SRC/scripts/config" ]; then
  mal "no encuentro el árbol de fuentes en $SRC"
  info "Este banco necesita el Kconfig REAL: sin él solo se leería el .config"
  info "del repo, donde 'no existe' y 'Kconfig lo poda' se ven igual."
  info "Trae el árbol con el sha256 comprobado (ver la cabecera de este script)"
  info "o ponlo en \$KCONFIG_SRC_DIR."
  exit 2
fi

cd "$SRC"
# El perfil es un fichero bash de arrays declarados.
# shellcheck disable=SC1090
source "$PROF"
for _r in "${EXPECTED_REBELS[@]}"; do EXPECTED_REBEL_SET["$_r"]=1; done

st() { # $1=símbolo -> y | m | n | missing   (solo bool/tristate, sobre el .config)
  if   grep -qx "CONFIG_$1=y" .config; then echo y
  elif grep -qx "CONFIG_$1=m" .config; then echo m
  elif grep -qx "# CONFIG_$1 is not set" .config; then echo n
  else echo missing; fi
}
val() { # $1=símbolo -> valor crudo, con las dos reglas de load_config_state()
  local l
  l="$(grep -m1 -E "^CONFIG_$1=" .config || true)"
  if [ -n "$l" ]; then printf '%s' "${l#*=}"; return 0; fi
  if grep -qx "# CONFIG_$1 is not set" .config; then echo n; return 0; fi
  echo missing
}

cp -f "$BASE" .config
args=()
for s in "${OPTS_ENABLE[@]}"; do args+=( --enable "$s" ); done
for s in "${OPTS_DISABLE[@]}"; do args+=( --disable "$s" ); done
for s in "${!OPTS_SETVAL[@]}"; do args+=( --set-val "$s" "${OPTS_SETVAL[$s]}" ); done
for s in "${!OPTS_SETSTR[@]}"; do args+=( --set-str "$s" "${OPTS_SETSTR[$s]}" ); done
scripts/config "${args[@]}"
make olddefconfig >/dev/null 2>&1 || { mal "olddefconfig falló"; exit 2; }

fallos=0
declare -a efail=() cfail=() hfail=() dwarn=() ret=()
en=0; cri=0; dis=0; reb=0

for o in "${OPTS_ENABLE[@]}"; do
  s=$(st "$o")
  case "$s" in
    y|m) en=$((en+1)) ;;
    n)   efail+=("CONFIG_$o quedó en n"); fallos=$((fallos+1)) ;;
    *)   efail+=("CONFIG_$o no existe en el Kconfig") ;;
  esac
done
for o in "${CRITICAL_OPTS[@]}"; do
  s=$(st "$o")
  case "$s" in
    y|m) cri=$((cri+1)) ;;
    *)   cfail+=("CONFIG_$o=$s"); fallos=$((fallos+1)) ;;
  esac
done
for o in "${OPTS_DISABLE[@]}"; do
  s=$(st "$o")
  case "$s" in
    n)       dis=$((dis+1)) ;;
    missing) dis=$((dis+1)); ret+=("$o") ;;
    y|m)     if [ -n "${EXPECTED_REBEL_SET[$o]:-}" ]; then reb=$((reb+1))
             else dwarn+=("CONFIG_$o=$s"); fi ;;
  esac
done
for o in "${!OPTS_SETVAL[@]}"; do
  s=$(val "$o")
  [ "$s" = "${OPTS_SETVAL[$o]}" ] || { hfail+=("SETVAL $o: esperado ${OPTS_SETVAL[$o]}, real $s"); fallos=$((fallos+1)); }
done
for o in "${!OPTS_SETSTR[@]}"; do
  s=$(val "$o")
  [ "$s" = "\"${OPTS_SETSTR[$o]}\"" ] || { hfail+=("SETSTR $o: esperado \"${OPTS_SETSTR[$o]}\", real $s"); fallos=$((fallos+1)); }
done

say "Kconfig de $(basename -- "$SRC") · perfil ${PROF##*/}"
printf '  %-11s %d/%d\n' "[ENABLE]"   "$en"  "${#OPTS_ENABLE[@]}"
printf '  %-11s %d/%d\n' "[CRITICAL]" "$cri" "${#CRITICAL_OPTS[@]}"
printf '  %-11s %d/%d   (%d rebeldes esperados, %d ya inexistentes)\n' \
  "[DISABLE]" "$dis" "${#OPTS_DISABLE[@]}" "$reb" "${#ret[@]}"
printf '  %-11s %d\n' "[SETVAL]" "${#OPTS_SETVAL[@]}"
printf '  %-11s %d\n' "[SETSTR]" "${#OPTS_SETSTR[@]}"

for x in ${efail[@]+"${efail[@]}"}; do mal "$x"; done
for x in ${cfail[@]+"${cfail[@]}"}; do mal "CRÍTICO $x"; done
for x in ${hfail[@]+"${hfail[@]}"}; do mal "$x"; done
if [ ${#dwarn[@]} -gt 0 ]; then
  aviso "${#dwarn[@]} desactivaciones que Kconfig NO resolvió (raíz sin retirar, o símbolo mal):"
  for x in "${dwarn[@]}"; do info "$x"; done
fi
if [ ${#ret[@]} -gt 0 ]; then
  info "${#ret[@]} de los OPTS_DISABLE ya no existen en este Kconfig (ruido, no fallo):"
  info "${ret[*]}"
fi
if [ "$fallos" -eq 0 ]; then bien "sin FATALES: el motor no debería cantar ninguno"; exit 0; fi
mal "$fallos FATALES: el motor las cantaría en pleno build"; exit 1
