#!/usr/bin/env bash
# ============================================================
# kconfig-bench.sh — qué(symbolos) del documento siguen siendo necesarios
#
# Para qué existe: un documento de "optimización" puede pedir 65 símbolos y solo
# 14 ser necesarios. Los otros 51 se Reparten en tres categorías MUY distintas, y
# confundirlas es lo que llena un perfil de ruido que nadie mantiene:
#
#   1. NO EXISTE        el símbolo ya no está en el Kconfig de esta versión.
#                       Listarlo no hace nada, solo avisa.
#   2. YA ESTÁ APAGADO  existe, pero ya venía apagado en la base.
#   3. SE APAGA EN CASCADA  existe y está activo, pero al quitar la RAÍZ se
#                       apaga solo, porque lo selecciona otro.
#
# Y dos más que solo aparecen al ejecutar:
#   4. RECHAZA          existe, se pide apagar y Kconfig lo deja encendido
#                       (→ EXPECTED_REBELS, con su porqué documentado).
#   5. LISTARLO SÍ HACE FALTA aunque "no haga nada" a simple vista: en un perfil
#       grande `olddefconfig` CONSERVA el =y viejo de un símbolo que se pide
#       desactivar, y eso no se ve hasta ejecutarlo.
#
# El método es el del perfil v5.16.1: `scripts/config` sobre el `.config` base,
# `make olddefconfig`, y se relee el resultado. Se comparan dos puntos —perfil
# solo, y perfil + bloques del documento— y así se ve el efecto de cada bloque.
#
# Para distinguir (1) de (2)/(3) hace falta el conjunto de símbolos REALMENTE
# DECLARADOS por el Kconfig, que se genera aquí una vez y se cachea; no está
# versionado (son 350 KB que se regeneran en segundos).
#
# ── Uso ──────────────────────────────────────────────────────────────────
#   ./kconfig-bench.sh [árbol de fuentes]
#
# Ver la cabecera de `kconfig-validate.sh` para cómo traer el árbol con su
# sha256 comprobado. Los bloques (A-D) están transcritos del documento maestro
# v5.19.0; si el documento cambia, se editan las cuatro listas de aquí y ya.
# ============================================================
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VER="${KCONFIG_VERSION:-7.2.9}"
STATE_DIR="${CIZEN_VERIFY_STATE_DIR:-$HOME/.local/state/kernel-update}"
SRC="${1:-${KCONFIG_SRC_DIR:-$STATE_DIR/kconfig-src/linux-$VER}}"
BASE="${KCONFIG_BASE:-$HERE/profiles/linux-7.2.8-cizen-v3.config}"
PROF="${KCONFIG_PROFILE:-$HERE/profiles/cizen-optiplex7050.conf}"
SIMBOLOS="${KCONFIG_SIMBOLOS:-$STATE_DIR/kconfig-src/simbolos-kconfig-$VER.txt}"

# ── Los bloques del documento maestro v5.19.0 ─────────────────────────────
DOCA=( SUSPEND HIBERNATION PM_SLEEP PM_SLEEP_SMP PM_WAKELOCKS )
DOCB=( SECURITY_SELINUX SECURITY_APPARMOR SECURITY_SMACK SECURITY_TOMOYO SECURITY_LOADPIN
       SECURITY_LOCKDOWN_LSM SECURITY_SAFESETID INTEGRITY IMA EVM )
DOCC=( QUOTA QFMT_V1 QFMT_V2 QUOTACTL AUTOFS_FS NFS_FS NFSD NFS_V4 CIFS SMB_SERVER
       CEPH_FS AFS_FS CODA_FS OCFS2_FS GFS2_FS JFFS2_FS UBIFS_FS CRAMFS ROMFS_FS
       MINIX_FS OMFS_FS HPFS_FS SYSV_FS UFS_FS JFS_FS REISERFS_FS XFS_FS F2FS_FS
       BFS_FS EFS_FS EROFS_FS ZONEFS_FS )
DOCD=( IP_SCTP IP_DCCP RDS TIPC BATMAN_ADV 6LOWPAN IEEE802154 PHONET CAIF NFC
       AF_RXRPC AF_KCM FIREWIRE PARPORT PARPORT_PC ISDN HAMRADIO IRDA )
declare -A DOCS=( [A]="${DOCA[*]}" [B]="${DOCB[*]}" [C]="${DOCC[*]}" [D]="${DOCD[*]}" )

[ -d "$SRC" ] && [ -x "$SRC/scripts/config" ] || {
  printf '  \033[31m✗\033[0m no encuentro el árbol de fuentes en %s\n' "$SRC"
  printf '    Ver la cabecera de kconfig-validate.sh: hace falta el Kconfig REAL,\n'
  printf '    con su sha256 comprobado. Sin él, "no existe" y "Kconfig lo poda"\n'
  printf '    se ven igual y el banco no puede distinguir los tres casos.\n'
  exit 2
}
[ -f "$BASE" ] || { printf '  \033[31m✗\033[0m no encuentro el .config base: %s\n' "$BASE"; exit 2; }

cd "$SRC"

# ── Símbolos declarados por el Kconfig, cacheados ─────────────────────────
# Se leen los `config X` de TODO el árbol (include/ y los_arch/ incluidos): un
# símbolo no puede declararse fuera de esas rutas, así que `find` sobre ellas es
# completo sin peinar los ficheros de drivers.
if [ ! -s "$SIMBOLOS" ]; then
  mkdir -p "$(dirname -- "$SIMBOLOS")"
  find . \( -path ./Documentation -o -path ./tools -o -path ./scripts \) -prune -o \
       -type f \( -name 'Kconfig*' -o -path './*/Kconfig*' \) -print0 \
    | xargs -0 grep -hE '^[[:space:]]*(menu)?config[[:space:]]+[A-Za-z0-9_]+' \
    | sed -E 's/^[[:space:]]*(menu)?config[[:space:]]+([A-Za-z0-9_]+).*/\2/' \
    | sort -u > "$SIMBOLOS"
  printf '  símbolos declarados por el Kconfig de %s: %s (cacheado en %s)\n' \
    "$VER" "$(wc -l < "$SIMBOLOS")" "$SIMBOLOS"
fi
declare -A KDECL=()
while read -r s; do [ -n "$s" ] && KDECL["$s"]=1; done < "$SIMBOLOS"

state_in() { # $1=fichero .config  $2=símbolo -> y | m | n | missing
  local f="$1" s="$2"
  if   grep -qx "CONFIG_$s=y" "$f"; then echo y
  elif grep -qx "CONFIG_$s=m" "$f"; then echo m
  elif grep -qx "# CONFIG_$s is not set" "$f"; then echo n
  else echo missing; fi
}
apagar_todos() { # $1..n = símbolos
  local -a a=()
  for s in "$@"; do a+=( --disable "$s" ); done
  [ ${#a[@]} -gt 0 ] && scripts/config "${a[@]}"
}
aplicar_perfil() { # igual que el motor
  local -a a=()
  for s in "${OPTS_ENABLE[@]}";  do a+=( --enable  "$s" ); done
  for s in "${OPTS_DISABLE[@]}"; do a+=( --disable "$s" ); done
  for s in "${!OPTS_SETVAL[@]}"; do a+=( --set-val "$s" "${OPTS_SETVAL[$s]}" ); done
  for s in "${!OPTS_SETSTR[@]}"; do a+=( --set-str "$s" "${OPTS_SETSTR[$s]}" ); done
  scripts/config "${a[@]}"
}

# shellcheck disable=SC1090
source "$PROF"

# ── Punto 1: perfil solo ──────────────────────────────────────────────────
cp -f "$BASE" .config
aplicar_perfil
make olddefconfig >/dev/null 2>&1
cp -f .config .config.P

# ── Punto 2: perfil + los cuatro bloques del documento ────────────────────
cp -f .config.P .config
for b in A B C D; do
  # shellcheck disable=SC2086
  apagar_todos ${DOCS[$b]}
done
make olddefconfig >/dev/null 2>&1
cp -f .config .config.PB

# ── Lectura ───────────────────────────────────────────────────────────────
# AVISO sobre lo que este banco PUEDE y NO PUEDE decir. La columna PERFIL es el
# estado tras el perfil ACTUAL, que ya incluye lo que el documento pedía. Con el
# perfil ya actualizado, SUSPEND o SECURITY_APPARMOR salen "ya apagada": no es que
# el documento no sirviera de nada, es que el perfil ya lo hizo. Para responder a
# "¿qué AÑADE el documento?" hay que apuntar KCONFIG_PROFILE al perfil de antes:
#
#   KCONFIG_PROFILE=profiles/cizen-optiplex7050.conf.bak-XXXXXXXX ./kconfig-bench.sh
#
# Y el efecto en cascada NO se lee en la tabla de símbolos, porque el banco solo
# toca los que están en las listas: si un símbolo de la lista pasa de y a n, es
# porque se pidió apagar, no porque lo arrastrara otro. La cascada de verdad es el
# diff completo de abajo.
off() { [ "$1" = n ] || [ "$1" = missing ]; }

# Volcado comparable: "SIMBOLO<TAB>ESTADO", con y/m/n y un estado "v" para los
# valores (ints y strings), que aquí no interesan.
dump() { # $1=fichero .config
  awk -F= '
    /^CONFIG_[A-Za-z0-9_]+=/ {
      s = substr($1, 8); v = $2
      print s "\t" ((v == "y" || v == "m") ? v : "v"); next
    }
    /^# CONFIG_[A-Za-z0-9_]+ is not set$/ {
      s = $2; sub(/^CONFIG_/, "", s); print s "\tn"
    }
  ' "$1" | sort -u
}
_P="$(mktemp)"; _PB="$(mktemp)"
trap 'rm -f "$_P" "$_PB"' EXIT
dump .config.P  > "$_P"
dump .config.PB > "$_PB"

# Todos los símbolos que el documento pedía, para no contarlos como cascada.
declare -A EN_LISTA=()
for b in A B C D; do for s in ${DOCS[$b]}; do EN_LISTA["$s"]=1; done; done

declare -a cascada=()
while IFS=$'\t' read -r sym a b; do
  [ -n "$sym" ] || continue
  a="${a:-missing}"; b="${b:-missing}"
  [ "$a" = "$b" ] && continue
  case "$b" in n|missing) ;; *) continue ;; esac
  off "$a" && continue              # ya estaba apagado antes: no es efecto
  [ -n "${EN_LISTA[$sym]:-}" ] && continue   # se pidió apagar: no es cascada
  cascada+=("$sym:$a->$b")
done < <(join -t$'\t' -a1 -a2 -e missing -o "0,1.2,2.2" "$_P" "$_PB")

printf '\n%-24s %-8s %-9s %s\n' "SIMBOLO" "PERFIL" "+BLOQUES" "LECTURA"
printf '%s\n' "----------------------------------------------------------------------------------------"
declare -A cuenta=()
for b in A B C D; do
  printf '### BLOQUE %s\n' "$b"
  for s in ${DOCS[$b]}; do
    st_p=$(state_in .config.P  "$s")
    st_pb=$(state_in .config.PB "$s")
    if [ -z "${KDECL[$s]:-}" ]; then
      lect="NO EXISTE en $VER -> no listar"; cuenta[NO_EXISTE]="${cuenta[NO_EXISTE]-}${s} "
    elif [ -z "${EN_LISTA[$s]:-}" ]; then
      lect="no estaba en la lista (revisar)"; cuenta[FUERA]="${cuenta[FUERA]-}${s} "
    elif off "$st_p"; then
      if off "$st_pb"; then lect="ya estaba apagada antes de este bloque"
      else lect="Kconfig la ENCIENDE al pedirla apagar -> REBELDA"; cuenta[REBELDE]="${cuenta[REBELDE]-}${s} "
      fi
    elif off "$st_pb"; then
      lect="apagada (la pedía el bloque)"; cuenta[DIRECTA]="${cuenta[DIRECTA]-}${s} "
    else
      lect="Kconfig RECHAZA apagarla (sigue $st_pb) -> REBELDA"; cuenta[RECHAZA]="${cuenta[RECHAZA]-}${s} "
    fi
    printf '%-24s %-8s %-9s %s\n' "$s" "$st_p" "$st_pb" "$lect"
  done
done

printf '\n\033[1mEfecto cascada real\033[0m (estos NO estaban en las listas y se han apagado solos)\n'
if [ ${#cascada[@]} -eq 0 ]; then
  printf '  (ninguno)\n'
else
  for x in "${cascada[@]}"; do printf '  %s\n' "$x"; done
fi

printf '\n\033[1mRecuento por categoría\033[0m\n'
for k in DIRECTA NO_EXISTE REBELDE RECHAZA FUERA; do
  v="${cuenta[$k]-}"
  [ -z "${v// /}" ] && continue
  printf '  %-10s %2d  %s\n' "$k" "$(wc -w <<< "$v")" "$v"
done
printf '\n  NO_EXISTE: no listarlos, solo ruido. REBELDE/RECHAZA: necesitan su línea en\n'
printf '  EXPECTED_REBELS con el porqué. La cascada de arriba NO se lista: se apaga\n'
printf '  sola cuando se retira la raíz, y listarla es justo lo que ensucia un perfil.\n'
printf '\n  DIRECTA significa "el documento lo listaba y se apagó", NO "hay que\n'
printf '  listarlo": si otra raíz listada ya lo apaga, listarlo es redundante (PM_SLEEP\n'
printf '  y PM_SLEEP_SMP son ese caso, y no están en la receta final). Lo que resuelve\n'
printf '  esa pregunta es kconfig-validate.sh sobre el perfil final, no esta tabla.\n'
