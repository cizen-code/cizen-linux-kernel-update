#!/usr/bin/env bash
# ============================================================
# pgo-collect.sh — Recoge un perfil AutoFDO del kernel Cizen en
# ejecución y lo convierte para usarlo como CIZEN_PGO_PROFILE.
#
# Pipeline (docs.kernel.org/dev-tools/autofdo.html):
#   1. captura perf:      perf record -e <evento LBR>:k -a -N -b -c <periodo>
#      (radiografía de TODO el kernel durante N segundos de tu carga real).
#      El paso -b NO es opcional: llvm-profgen se alimenta de la pila de
#      ramas, no solo de las IPs muestreadas.
#   2. conversión:         llvm-profgen --kernel --binary vmlinux
#      --perfdata perf.data → fichero .afdo legible por clang
#      (-fprofile-sample-use), no por gcc. El flag --kernel también es
#      obligatorio: sin él, llvm-profgen busca binarios de espacio de usuario
#      en los mmap events y aborta con «No relevant mmap event is found».
#   3. rebuild:            CIZEN_PGO_PROFILE=<fichero> kernel-update.sh <build>
#      El motor (v27.31.45) fuerza CONFIG_AUTOFDO_CLANG y entrega el perfil
#      al make como CLANG_AUTOFDO_PROFILE. Requiere la familia clang (el
#      default actual es Thin-LTO → clang ya).
#
# Notas:
#   - Capturar con la carga REPRESENTATIVA (Arranca apps, compila, navega,
#     juega…): el perfil solo optimiza lo que ve el muestreador. 10-15 min es
#     una buena medida.
#   - El fichero sale en $HOME/kernel-pgo/<kver>.afdo. Puede reutilizarse en
#     rebuilds (consérvalo junto a los perf.data).
#
# Uso:
#   sudo kernel-update/pgo-collect.sh [--duration N] [--vmlinux RUTA] [--out FICH]
#
#   --duration N   segundos de muestreo (default 600)
#   --vmlinux RUTA vmlinux del kernel Cizen que quieres perfil-optimizar.
#                  Si se omite se busca, en orden: /lib/modules/<uname -r>/build/vmlinux,
#                  $CIZEN_VMLINUX_STORE/<uname -r>/vmlinux y .../vmlinux.unstripped.
#                  El kernel-update.sh actual guarda una copia persistente del vmlinux
#                  de cada build en ese store (default /var/cache/cizen-kernel/vmlinux),
#                  porque el árbol de compilación vive en un tmpfs que se desmonta.
#   --out FICH     fichero .afdo de salida (default <home del usuario que lo
#                  lanzó>/kernel-pgo/<kver>.afdo; con sudo, el home del usuario
#                  es $SUDO_USER, NO /root — si no, el perfil aterriza donde
#                  kernel-update.sh --pgo no lo ve).
#   --period N     periodo de muestreo en ciclos para el evento LBR (default
#                  500009, primo como recomienda la doc). Solo en modo LBR.
#   --keep-perfdata  conserva el perf.data aunque la conversión funcione.
#   --merge F1 F2 [F3...]  NO muestrea: fusiona N capturas .perf.data ya
#                  Existing en un único perfil, sin root ni evento LBR.
#                  Para qué: un perfil de 15 min de escritorio solo optimiza lo
#                  que el escritorio hizo (arrancar apps, compilar, navegar).
#                  Fusionando varias sesiones el advice deja de depender de una
#                  sola. Requiere 2 o más ficheros.
#
# Variables de entorno:
#   CIZEN_PGO_DURATION  igual que --duration
#   CIZEN_PGO_VMLINUX   igual que --vmlinux
#   CIZEN_PGO_OUT       igual que --out
#   CIZEN_PGO_PERIOD    igual que --period
#   CIZEN_PGO_KEEP_PERFDATA  1 = conservar siempre el perf.data
#   CIZEN_VMLINUX_STORE store de vmlinux persistentes que deja kernel-update.sh
#                       (default /var/cache/cizen-kernel/vmlinux)

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

# ── Colores ─────────────────────────────────────────────────
if [ -t 1 ]; then
  R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'; C=$'\033[0;36m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; C=""; N=""
fi

log(){  printf '%s[%s]%s %s\n' "$B" "$(date +%H:%M:%S)" "$N" "$*"; }
ok(){   printf '%s  ✓%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s  ⚠%s %s\n' "$Y" "$N" "$*"; }
err(){  printf '%s  ✗%s %s\n' "$R" "$N" "$*" >&2; }
info(){ printf '%s  •%s %s\n' "$C" "$N" "$*"; }
fatal(){ err "$*"; exit 1; }

# Privilegios: `perf record -a` necesita root (o perf_event_paranoid bajo).
# Si el usuario lanza el script sin sudo, se re-ejecuta con sudo.
DURATION="${CIZEN_PGO_DURATION:-600}"
VMLINUX="${CIZEN_PGO_VMLINUX:-}"
OUT="${CIZEN_PGO_OUT:-}"
PERIOD="${CIZEN_PGO_PERIOD:-500009}"
KEEP_PERFDATA="${CIZEN_PGO_KEEP_PERFDATA:-}"
MERGE=()
# v27.33.3: el parseo de argumentos se hace ANTES de elevar. Con el `exec sudo`
# delante, `pgo-collect.sh --help` pedía contraseña para imprimir un texto, y un
# argumento desconocido hacía lo mismo. Además las variables de entorno del
# usuario se perdían al re-ejecutar con sudo (env_reset de Arch sin env_keep): un
# CIZEN_PGO_DURATION=60 exportado se convertía en el 600 s por defecto en
# silencio. Ahora se leen aquí y se pasan explícitamente al proceso elevado.
while [ $# -gt 0 ]; do
  case "$1" in
    --duration) DURATION="${2:-}"; [ -n "$DURATION" ] || fatal "--duration requiere segundos"; shift 2 ;;
    --vmlinux)  VMLINUX="${2:-}"; [ -n "$VMLINUX" ] || fatal "--vmlinux requiere una ruta"; shift 2 ;;
    --out)      OUT="${2:-}"; [ -n "$OUT" ] || fatal "--out requiere una ruta"; shift 2 ;;
    --period)   PERIOD="${2:-}"; [ -n "$PERIOD" ] || fatal "--period requiere ciclos"; shift 2 ;;
    --keep-perfdata) KEEP_PERFDATA=1; shift ;;
    --merge)
      # Todo lo que sigue hasta el siguiente --algo son capturas. Se guardan tal
      # cual en el array (con IFS sin espacio, "${MERGE[@]}" los expande
      # elemento a elemento: mismo truco que PGO_PERF_ARGS).
      shift
      while [ $# -gt 0 ]; do
        case "$1" in --*) break ;; esac
        MERGE+=("$1"); shift
      done
      [ "${#MERGE[@]}" -ge 2 ] || fatal "--merge necesita 2 o más capturas .perf.data (las que dejó --keep-perfdata); recibidas ${#MERGE[@]}."
      ;;
    --help|-h)
      sed -n '2,40p' "$0"
      exit 0 ;;
    *) fatal "Argumento desconocido: $1 (usa --help)" ;;
  esac
done

SUDO=()
# La fusión NO se eleva: solo lee ficheros .perf.data y llama a llvm-profgen,
# y ninguno de los dos necesita privilegios. Elevar aquí pediría una contraseña
# para una operación que el usuario puede hacer sin ella, y además el exec
# re-montaría el array MERGE a través del entorno (con env_reset de Arch se
# perdería, y el perfil "fusionado" saldría de una sola captura sin avisar).
if [ "${#MERGE[@]}" -gt 0 ] && [ "$(id -u)" != 0 ]; then
  log "Fusión de ${#MERGE[@]} capturas: no hace falta root (no se muestrea nada)."
fi
if [ "${#MERGE[@]}" -eq 0 ] && [ "$(id -u)" != 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
    # v27.33.4: CIZEN_VMLINUX_STORE también se pasa de forma explícita. Con
    # env_reset de Arch (sudo no lo conserva), un store personalizado se
    # perdía al elevar y el proceso elevated buscaba en el /var/cache de
    # siempre: el fallo era "no encuentro el vmlinux" sin explicación, siendo el
    # fichero que el propio motor acababa de archivar.
    log "Elevando a root: ${SUDO[*]} $0 $*"
    exec "${SUDO[@]}" CIZEN_PGO_DURATION="$DURATION" CIZEN_PGO_VMLINUX="$VMLINUX" \
         CIZEN_PGO_OUT="$OUT" CIZEN_PGO_PERIOD="$PERIOD" CIZEN_PGO_KEEP_PERFDATA="$KEEP_PERFDATA" \
         CIZEN_VMLINUX_STORE="${CIZEN_VMLINUX_STORE:-}" "$0" "$@"
  else
    fatal "Se necesita root: ejecuta  sudo $0 $*  (perf record -a exige privilegios.)"
  fi
fi

command -v perf >/dev/null 2>&1 || fatal "No está 'perf' (sudo pacman -S perf) — herramienta de muestreo."

KVER="$(uname -r)"

# Búsqueda del vmlinux (ver pgo-collect: el kernel se compila en un tmpfs que se
# desmonta al terminar el pipeline, así que el vmlinux SOLO existe como copia
# persistente en $VMLINUX_STORE; el enlace /lib/modules/<kver>/build no se crea).
VMLINUX_STORE="${CIZEN_VMLINUX_STORE:-/var/cache/cizen-kernel/vmlinux}"

# ¿Vale este vmlinux del store? Solo si va acompañado de su testigo "$KVER.meta",
# que kernel-update.sh escribe DESPUÉS de copiar y con el tamaño real de lo
# copiado. Sin testigo el fichero puede ser una copia a medias (install no es un
# rename) y llvm-profgen produciría un perfil sin sentido o abortaría. Un
# --vmlinux explícito NO pasa por aquí: ahí el usuario señala el fichero a mano.
pgo_vmlinux_committed() { # $1 = ruta candidata; $KVER y VMLINUX_STORE de fuera
  local cand="$1" meta="$VMLINUX_STORE/$KVER.meta" want have
  [ -f "$meta" ] || {
    warn "Ignorado $cand: sin su testigo $meta (copia a medias, o de un build anterior a v27.33.4)."
    return 1
  }
  want="$(awk -v f="$(basename -- "$cand")" '$1=="size" && $3==f {print $2}' "$meta" 2>/dev/null | head -1)"
  have="$(stat -c %s -- "$cand" 2>/dev/null)"
  if [ -n "$want" ] && [ -n "$have" ] && [ "$want" != "$have" ]; then
    warn "Ignorado $cand: el testigo dice $want bytes y el fichero tiene $have."
    return 1
  fi
  return 0
}

# Deja el vmlinux encontrado en $VMLINUX (no imprime: con `set -e` y con warn()
# escribiendo a stdout, una sustitución de comandos se comería los avisos).
pgo_find_vmlinux() {
  local cand
  for cand in "/lib/modules/$KVER/build/vmlinux" \
              "$VMLINUX_STORE/$KVER/vmlinux" \
              "$VMLINUX_STORE/$KVER/vmlinux.unstripped"; do
    case "$cand" in
      "$VMLINUX_STORE"/*) pgo_vmlinux_committed "$cand" || continue ;;
    esac
    if [ -f "$cand" ]; then VMLINUX="$cand"; return 0; fi
  done
  return 1
}

if [ -z "$VMLINUX" ]; then
  pgo_find_vmlinux || true
fi
if [ -z "$VMLINUX" ]; then
  fatal "No encuentro el vmlinux de '$KVER'.
  El kernel se compila en un tmpfs que se desmonta tras el build, así que no queda
  vmlinux en disco salvo en la copia persistente que crea kernel-update.sh.
  Qué hacer:
    - ¿Ya hiciste un build con este motor? Reconstruye una vez (el archivado ocurre
      al final del pipeline) y vuelve a intentar:
          sudo /usr/local/bin/kernel-update/kernel-update.sh build
    - ¿El build fue anterior a este cambio? Pasa la ruta a mano si aún conservas el
      árbol de compilación (con CIZEN_KEEP_TMPFS=1 no se desmonta):
          sudo $0 --duration $DURATION --vmlinux /ruta/al/vmlinux
    - La búsqueda por defecto es: /lib/modules/$KVER/build/vmlinux y
      $VMLINUX_STORE/$KVER/vmlinux (configurable con CIZEN_VMLINUX_STORE)."
fi
[ -f "$VMLINUX" ] || fatal "vmlinux no existe: $VMLINUX"

# ── Evento de muestreo (v27.33.6) ──────────────────────────────────
# AutoFDO no se alimenta de "cuántas veces se ejecutó una línea" sino de las
# PREDICCIONES de cada basic block que sí se ejecutó, y eso solo sale de la pila
# de ramas (LBR/BR). La receta de docs.kernel.org/dev-tools/autofdo.html lo es
# explícito, y el propio --help de llvm-profgen avisa: «it should be profiled
# with -b». Con `perf record -F 999 -a -g` (lo que hacía v27.33.5) se grababa
# una radiografía sin una sola rama: llvm-profgen no tenía con qué ponderar los
# bloques.
#
# Se deja la lista de argumentos en PGO_PERF_ARGS y se devuelve 1 si no hay LBR
# utilizable: en ese caso el .afdo no serviría para nada y es mejor decirlo ahora
# que descubrirlo en el rebuild.
#
# Variante SIN subshell, y a propósito: este script declara `IFS=$'\n\t'`, sin
# espacio. Parsing `$PERF_LBR` sin comillas no lo parte en palabras, así que
# perf recibía `-e "br_inst_retired.near_taken:k -b"` como un único evento
# inexistente. Es el mismo tipo de trampa que el `read -r a b c` de la v27.33.5:
# el array se expande como "${arr[@]}" y el IFS deja de importar.
PGO_PERF_ARGS=()
pgo_perf_args() { # $1 = fichero cpuinfo alternativo (los tests)
  local cpuinfo="${1:-/proc/cpuinfo}" vendor flags
  PGO_PERF_ARGS=()
  vendor="$(awk -F: '/^vendor_id/ {gsub(/[ \t]/,"",$2); print $2; exit}' "$cpuinfo" 2>/dev/null)"
  case "$vendor" in
    GenuineIntel)
      # Kaby Lake y anteriores: LBR arquitectónico, evento near_taken.
      perf list br_inst_retired.near_taken 2>/dev/null | grep -q near_taken || return 1
      PGO_PERF_ARGS=( -e br_inst_retired.near_taken:k -b )
      ;;
    AuthenticAMD|AMD)
      # Zen3 con BRS o Zen4 con amd_lbr_v2. Sin uno de los dos, no hay LBR.
      flags="$(cat "$cpuinfo" 2>/dev/null)"
      grep -qw brs <<<"$flags" || grep -q amd_lbr_v2 <<<"$flags" || return 1
      PGO_PERF_ARGS=( --pfm-events RETIRED_TAKEN_BRANCH_INSTRUCTIONS:k -b )
      ;;
    *) return 1 ;;
  esac
  return 0
}

# Envoltorio legible (para los tests y para explicar en pantalla lo que se va a
# usar). Delega en la variante con array; no es la que llama a `perf record`.
# El join es por ESPACIO y no por "${arr[*]}": con el IFS del script ese join
# inserta saltos de línea y la receta se imprimía partida en tres renglones.
pgo_perf_event() {
  pgo_perf_args "${1:-}" || return 1
  (IFS=' '; printf '%s' "${PGO_PERF_ARGS[*]}")
}

# ¿El kernel en marcha se compiló con CONFIG_AUTOFDO_CLANG? La doc lo llama
# "advisable" (el perfil usa números de línea relativos y tolera diferencias),
# así que NO es motivo para parar: solo para que se sepa de dónde salió.
# $1 = fichero de config alternativo (los tests).
# shellcheck disable=SC2120  # los $1 son para los tests; en producción va sin argumentos
pgo_running_autofdo() {
  local cfg
  if [ -n "${1:-}" ]; then
    [ -r "$1" ] || return 1
    cfg="$(cat "$1" 2>/dev/null)"
  elif [ -r /proc/config.gz ] && cfg="$(zcat /proc/config.gz 2>/dev/null)"; then
    :
  elif [ -r "/boot/config-$KVER" ]; then
    cfg="$(cat "/boot/config-$KVER" 2>/dev/null)"
  else
    return 1
  fi
  grep -q '^CONFIG_AUTOFDO_CLANG=y' <<<"$cfg"
}

# ── Destino del .afdo (v27.33.6) ──────────────────────────────────
# Con sudo, $HOME es /root: el .afdo acababa en /root/kernel-pgo y el paso 3 del
# ciclo (`kernel-update.sh --pgo` a secas, que busca en $HOME/kernel-pgo) no lo
# encontraba. Se resuelve el home del usuario que lanzó el script.
pgo_target_home() {
  local u="${SUDO_USER:-}" home=""
  if [ -n "$u" ] && [ "$u" != root ]; then
    home="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
  fi
  printf '%s\n' "${home:-$HOME}"
}

TARGET_HOME="$(pgo_target_home)"
# Dueño del destino: lo escribe root, pero el fichero es del usuario que lo pidió.
TARGET_USER="${SUDO_USER:-}"
if [ "$TARGET_USER" = root ]; then TARGET_USER=""; fi

OUT="${OUT:-$TARGET_HOME/kernel-pgo/$KVER.afdo}"
OUT_DIR="$(dirname -- "$OUT")"
# Si el directorio hay que crearlo, nace del usuario que lo pidió, no de root:
# si no, el .afdo es suyo pero no puede borrarlo sin sudo (borrar necesita
# escritura en el directorio, no en el fichero).
OUT_DIR_NUEVO=""
[ -d "$OUT_DIR" ] || OUT_DIR_NUEVO="$OUT_DIR"
mkdir -p "$OUT_DIR"
pgo_chown() { # deja el fichero como el usuario que invocó, no como root
  [ -n "$TARGET_USER" ] || return 0
  id -u "$TARGET_USER" >/dev/null 2>&1 || return 0
  chown "$TARGET_USER" "$1" 2>/dev/null || warn "No pude hacer chown de $1 a $TARGET_USER."
}
if [ -n "$OUT_DIR_NUEVO" ]; then pgo_chown "$OUT_DIR_NUEVO"; fi

TMPD="$(mktemp -d)"
# El trap se queda con el perf.data solo si la conversión falla: 365 MB y 15
# minutos de carga real no se tiran por un flag mal puesto. Con --keep-perfdata
# (o CIZEN_PGO_KEEP_PERFDATA=1) se conserva siempre, junto al .afdo.
pgo_cleanup() {
  if [ -f "$TMPD/perf.data" ] && { [ -n "$KEEP_PERFDATA" ] || [ "$CONVERT_RC" -ne 0 ]; }; then
    pgo_keep_perfdata
  fi
  rm -rf "$TMPD"
}
pgo_keep_perfdata() {
  local dst="${OUT}.perf.data"
  mv -f "$TMPD/perf.data" "$dst" 2>/dev/null || return 1
  pgo_chown "$dst"
  info "Captura conservada en $dst (puedes reconvertir sin volver a muestrear)."
}
CONVERT_RC=0
trap pgo_cleanup EXIT

# ── Fusión de capturas (--merge) ─────────────────────────────────────────
# Por qué NO se fusionan los .perf.data en binario, y por qué esta ruta es la
# que funciona (v27.34.1):
#
#   * `llvm-profgen --perfdata A --perfdata B` NO fusiona: se queda con el
#     ÚLTIMO y descarta el resto sin decir nada. Comprobado en LLVM 23.1.1 con
#     un fichero inexistente en primera posición: si fuera fusión, se quejaría
#     de él; no dice nada, luego solo miró el segundo. Un script que pasara las
#     capturas así anunciaría un "perfil fusionado" hecho de la última sesión,
#     que es justo el sesgo que se quería quitar.
#   * `perf merge` no existe en perf 7.2.8 (no está en `perf --help` ni hay
#     perf-merge.1; `perf data convert` solo cambia de formato).
#   * `--perfscript` sí acepta un fichero, pero su parser (PerfReader.cpp,
#     checkPerfScriptType) no entiende el texto de `perf script`: aborta con
#     «Invalid perf script input!». El formato que espera es el suyo propio.
#
# La vía que sí funciona, y es la que se usa aquí, es la que el propio
# llvm-profgen ofrece para esto: descomponer cada captura a TEXTO sin
# simbolizar (--skip-symbolization), concatenar los textos y simbolizar una sola
# vez (--unsymbolized-profile). El formato intermedio es una lista plana, sin
# cabecera ni longitudes, así que concatenar es una suma de líneas exacta.
# Verificado de punta a punta en este host con un banco propio (programa con
# DWARF, dos capturas LBR): la densidad del perfil pasa de 1,7 a 5,8 y el
# aviso de muestras insuficentes de 29,4x a 8,6x.
#
# La concatenación no puede perder nada por construcción (son bytes), pero sí
# puede perder una sesión entera sin que se note, y eso es un fallo silencioso
# con forma de éxito: de ahí los dos abortos de abajo.
# --kernel es obligatorio en producción (sin él llvm-profgen busca binarios de
# espacio de usuario y aborta con "no kernel is found in mmap events", que es
# justo lo que pasa en §50). Pero para poder PROBAR la fusión de punta a punta
# hace falta un banco de espacio de usuario, y el banco de este repo es un
# programa normal con DWARF. CIZEN_PGO_KERNEL=0 quita el flag; es una costura
# de test, no una opción de uso: con perfiles de kernel el flag hace falta sí o sí.
# Array y no "$(...)": el archivo ya usa ese patrón para PGO_PERF_ARGS, y el
# join por sustitución de comando sufre SC2046 (splitting de palabras) justo donde no debe
# haberlo, en una línea que se lee como un argumento literal.
PGO_KERNEL_ARGS=()
pgo_kernel_args() {
  [ "${CIZEN_PGO_KERNEL:-1}" = 0 ] || PGO_KERNEL_ARGS=( --kernel )
  return 0
}

pgo_count_samples() { # $1 = perf.data → nº de eventos SAMPLE, o vacío
  [ -f "$1" ] || return 0
  perf report -i "$1" --stats 2>/dev/null \
    | grep -oE 'SAMPLE events:[[:space:]]+[0-9]+' | head -1 \
    | grep -oE '[0-9]+' || true
}

if [ "${#MERGE[@]}" -gt 0 ]; then
  command -v llvm-profgen >/dev/null 2>&1 \
    || fatal "La fusión la hace llvm-profgen, y no está instalado (sudo pacman -S llvm-profgen)."
  MERGED_OUT="${OUT:-$TARGET_HOME/kernel-pgo/$KVER-merged${#MERGE[@]}.afdo}"
  MERGED_DIR="$(dirname -- "$MERGED_OUT")"
  [ -d "$MERGED_DIR" ] || OUT_DIR_NUEVO="$MERGED_DIR"
  mkdir -p "$MERGED_DIR"
  if [ -n "$OUT_DIR_NUEVO" ]; then pgo_chown "$OUT_DIR_NUEVO"; fi

  pgo_kernel_args
  log "Fusionando ${#MERGE[@]} capturas de $KVER (vmlinux: $VMLINUX)"
  info "Perfil de kernel: ${PGO_KERNEL_ARGS[*]:-sin --kernel (modo bench)}."
  info "No se muestrea nada: esto solo recombina perf.data que ya tienes."
  MERGE_TOTAL=0
  MERGE_PARTS=()
  _mi=0
  for _mf in "${MERGE[@]}"; do
    [ -e "$_mf" ] || fatal "No existe la captura: $_mf
  Las capturas se conservan junto al .afdo con --keep-perfdata, y se llaman
  <salida>.perf.data. Si moviste el .afdo, el .perf.data va a su lado."
    [ -s "$_mf" ] || fatal "Captura vacía: $_mf
  Un perf.data de 0 bytes suele ser una captura abortada; sin muestras no hay
  nada que fusionar, y dar un perfil sin sesiones sería mentira."
    _mn="$(pgo_count_samples "$_mf")"
    if [ -z "$_mn" ] || [ "$_mn" -eq 0 ]; then
      fatal "La captura $_mf no tiene eventos SAMPLE.
  Fusionarla no aportaría nada y el perfil saldría de las otras sesiones
 y se presentaría como fusionado. Recaptura, o pásala fuera."
    fi
    # El nombre intermedio lleva el ÍNDICE, no solo el basename: dos capturas
    # homónimas en directorios distintos (o el mismo fichero pasado dos veces,
    # que es justo como se prueba el camino kernel con una captura real) se
    # pisarían y la suma de bytes seguiría cuadrando sobre el fichero
    # equivocado. El indice es lo que hace unicos los temporales.
    _mu="$TMPD/merge-$_mi.unsym"
    log "  $(basename -- "$_mf"): $_mn muestras → texto sin simbolizar"
    _rc=0
    llvm-profgen "${PGO_KERNEL_ARGS[@]}" --binary "$VMLINUX" --perfdata "$_mf" \
                 --skip-symbolization --output "$_mu" 2>"$TMPD/llvm.err" || _rc=$?
    if [ "$_rc" -ne 0 ]; then
      sed 's/^/      /' "$TMPD/llvm.err" >&2 2>/dev/null || true
      fatal "llvm-profgen no pudo descomponer $_mf (código $_rc). Aborto en vez de
  fusionar solo las que sí hayan salido: un perfil fusionado a medias no lo
  distingue nadie de uno completo."
    fi
    # llvm-profgen escribe "0\n0\n" (4 bytes) cuando no encuentra muestras: eso
    # es una sesión vacía disfrazada de fichero válido. grep de "algo que no sea
    # ni cero ni espacio" lo detecta sin depender del tamaño.
    if ! grep -q '[^0[:space:]]' "$_mu" 2>/dev/null; then
      fatal "La captura $_mf se descompone vacía (llvm-profgen no encontró muestras
  de LBR). Sin pila de ramas no hay advice, y fusionarla no mejoraría el perfil."
    fi
    MERGE_TOTAL=$(( MERGE_TOTAL + _mn ))
    MERGE_PARTS+=("$_mu")
    _mi=$(( _mi + 1 ))
  done

  MERGED_UNSYM="$TMPD/merged.unsym"
  cat -- "${MERGE_PARTS[@]}" > "$MERGED_UNSYM"
  # Suma exacta de bytes: si el concatenado no es la suma de las partes, algo se
  # perdió por el camino (y sería en silencio, que es lo que hay que evitar).
  MERGE_WANT=0
  for _p in "${MERGE_PARTS[@]}"; do MERGE_WANT=$(( MERGE_WANT + $(wc -c < "$_p") )); done
  MERGE_GOT="$(wc -c < "$MERGED_UNSYM")"
  [ "$MERGE_GOT" -eq "$MERGE_WANT" ] \
    || fatal "El texto fusionado mide $MERGE_GOT bytes y las partes suman $MERGE_WANT.
  Aborto: fusionar con una pieza perdida es peor que no fusionar."
  info "Texto fusionado: $MERGE_GOT bytes de ${#MERGE[@]} capturas ($MERGE_TOTAL muestras)."

  log "Simbolizando una sola vez contra $VMLINUX"
  CONVERT_RC=0
  llvm-profgen "${PGO_KERNEL_ARGS[@]}" --binary "$VMLINUX" --unsymbolized-profile "$MERGED_UNSYM" \
               --output "$MERGED_OUT" --show-density 2>"$TMPD/llvm.err" || CONVERT_RC=$?
  sed 's/^/  /' "$TMPD/llvm.err" 2>/dev/null | grep -v '^  warning: Sample PGO' || true
  if [ "$CONVERT_RC" -ne 0 ]; then
    fatal "llvm-profgen falló al simbolizar el perfil fusionado (código $CONVERT_RC)."
  fi
  [ -s "$MERGED_OUT" ] || fatal "llvm-profgen terminó bien pero no dejó $MERGED_OUT."
  ok "Perfil AutoFDO fusionado de ${#MERGE[@]} capturas: $MERGED_OUT"
  pgo_chown "$MERGED_OUT"

  info "Rebuild con PGO: CIZEN_PGO_PROFILE=$MERGED_OUT kernel-update.sh build"
  info "Ojo: si existe también un $KVER.afdo de una sola sesión, el motor elige el"
  info "de SU versión exacta; para usar este, pásalo con --pgo <fichero>."
  rm -rf "$TMPD"; trap - EXIT
  exit 0
fi

log "Perfil del kernel en ejecución: $KVER (vmlinux: $VMLINUX)"
if pgo_perf_args; then
  # join por espacio: con el IFS del script, "${arr[*]}" sale con \n y la receta
  # se leía partida en tres renglones.
  info "Muestreo de $DURATION s con LBR, periodo $PERIOD ciclos: perf record $(IFS=' '; printf '%s' "${PGO_PERF_ARGS[*]}") -a -N -c $PERIOD"
  info "Usa este tiempo para tu carga real, no lo cortes."
  # "${...[@]}": el IFS del script no incluye el espacio, pero el array sí se
  # expande elemento a elemento. Con "$PGO_PERF_ARGS" a secas, un solo argumento.
  if ! perf record -o "$TMPD/perf.data" "${PGO_PERF_ARGS[@]}" -a -N -c "$PERIOD" -- sleep "$DURATION"; then
    warn "perf record terminó con error; comprueba kernel.perf_event_paranoid y que el script corre como root."
    exit 1
  fi
else
  fatal "Esta máquina no ofrece pila de ramas (LBR/BR), y sin ella llvm-profgen
  no puede ponderar los bloques básicos: el .afdo que saldría no serviría para
  optimizar nada.
  - Intel: necesita Kaby Lake o anterior con el controlador LBR de Intel
    (evento br_inst_retired.near_taken). Comprueba con: perf list br_inst_retired.near_taken
  - AMD: Zen3 con BRS o Zen4 con amd_lbr_v2 (comprueba con: grep -w brs /proc/cpuinfo)
  - Alternativa: recoge el perfil en otro equipo con LBR y copia aquí el
    <kver>.afdo; el motor solo necesita el fichero."
fi
ok "Muestreo completado ($DURATION s)."
if ! pgo_running_autofdo; then
  warn "El kernel en marcha no se compiló con CONFIG_AUTOFDO_CLANG. El perfil
  sigue siendo válido (los números de línea son relativos), pero la doc de
  upstream recomienda colectar sobre un kernel ya AutoFDO. Afecta solo a la
  calidad del perfil, no a que se pueda aplicar."
fi

if command -v llvm-profgen >/dev/null 2>&1; then
  # --kernel es OBLIGATORIO: sin él, llvm-profgen busca binarios de espacio de
  # usuario en los mmap events, y como el perf.data es de kernel puro aborta con
  # «No relevant mmap event is found in perf data» (y el trap borraba los 365 MB
  # de la captura con él).
  CONVERT=(llvm-profgen --kernel --binary "$VMLINUX" --perfdata "$TMPD/perf.data" --output "$OUT")
elif command -v create_llvm_prof >/dev/null 2>&1; then
  # Variante antigua (tools/autofdo de la era pre-llvm-profgen).
  CONVERT=(create_llvm_prof --binary="$VMLINUX" --profile="$TMPD/perf.data" --out="$OUT")
  warn "Usando create_llvm_prof (legacy): prefiere llvm-profgen cuando esté disponible."
else
  fatal "No está 'llvm-profgen' (sudo pacman -S llvm-profgen) ni create_llvm_prof; la conversión del perfil es obligatoria."
fi
CONVERT_RC=0
"${CONVERT[@]}" || CONVERT_RC=$?
if [ "$CONVERT_RC" -ne 0 ]; then
  fatal "llvm-profgen falló (código $CONVERT_RC); la captura se conserva para reconvertir sin volver a muestrear."
fi
[ -f "$OUT" ] || fatal "llvm-profgen terminó bien pero no dejó $OUT; no me fío de un perfil inexistente."
ok "Perfil AutoFDO: $OUT"
pgo_chown "$OUT"

info "Rebuild con PGO (motor v27.31.45+): CIZEN_PGO_PROFILE=$OUT kernel-update.sh build"
info "Ojo: ese rebuild corre en TU sesión, sin sudo, y el motor busca en ~/kernel-pgo."
info "Para comparar sin PGO: kernel-update.sh build --no-lto  (y sin CIZEN_PGO_PROFILE)."