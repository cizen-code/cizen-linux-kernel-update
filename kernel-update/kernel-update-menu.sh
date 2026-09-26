#!/usr/bin/env bash
# ============================================================
# kernel-update-menu.sh — Menú interactivo para kernel-update.sh
# Validación, compilación (vanilla/BORE/PDS/BMQ/LFBMQ/MuQSS, Clang/LTO,
# NTSync, parches misc CachyOS), consulta y mantenimiento del motor.
#
# Uso: ./kernel-update-menu.sh [remote]
#   remote = versión estable a mostrar (p. ej. la que pasa
#            kernel-update-notify.sh). Sin argumento y con terminal
#            interactiva, el menú consulta kernel.org (máx. 6 s) y
#            muestra la stable; sin conexión indica la opción 6.
# Opciones: 1-4 validación/build, 5 force, 6 check-update, 7/8 BORE,
# 14 buildvariant (scheduler/tuning), 15 ntsync, 16 cachy, 17 manager,
# 9 rollback (reinstala el PAQUETE del kernel anterior), 10 kcfg, 11 selftest,
# 12 changelog, 13 hardened, 0 salir.
# ============================================================
set -uo pipefail

SCRIPT="${CIZEN_KERNEL_SCRIPT:-/usr/local/bin/kernel-update/kernel-update.sh}"
URL="${KERNEL_RELEASES_JSON_URL:-https://www.kernel.org/releases.json}"

if [ ! -x "$SCRIPT" ]; then
  echo "Error: $SCRIPT no encontrado o no ejecutable." >&2
  exit 1
fi

# ── Colores (solo terminal interactiva) ───────────────────────
if [ -t 1 ]; then
  C=$'\033[1;36m'   # números
  G=$'\033[0;32m'   # instalado / motor
  Y=$'\033[1;33m'   # stable
  H=$'\033[1m'      # negrita
  W=$'\033[1;37m'   # blanco + negrita (títulos y prompt)
  N=$'\033[0m'
else
  C=""; G=""; Y=""; H=""; W=""; N=""
fi
R=$'\033[0;31m'     # error (se muestra tras una opción inválida)
Y2=$'\033[1;31m'    # avisos deavailability (rojo)

# ── Auto-descubrimiento de la última stable ───────────────────
discover_remote() {
  local latest=""
  if command -v curl >/dev/null 2>&1; then
    latest="$(curl -fsS --max-time 6 "$URL" 2>/dev/null | tr '\n' ' ' | sed -n 's/.*"latest_stable"[[:space:]]*:[[:space:]]*{[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^" ]*\)"[[:space:]]*}.*/\1/p')"
  fi
  if [ -z "$latest" ] && command -v wget >/dev/null 2>&1; then
    latest="$(wget -qO- --timeout=6 --tries=1 "$URL" 2>/dev/null | tr '\n' ' ' | sed -n 's/.*"latest_stable"[[:space:]]*:[[:space:]]*{[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^" ]*\)"[[:space:]]*}.*/\1/p')"
  fi
  [ -n "$latest" ] || return 1
  [[ "$latest" =~ ^[0-9]+\.[0-9]+ ]] || return 1
  printf '%s\n' "$latest"
}

# ── Estado del fork CachyOS ─────────────────────────────────────
# v27.31.16: la stable que anuncia kernel.org va por delante de los releases del
# fork CachyOS/linux (los schedulers pds/bmq/lfbmq/muqss SOLO existen ahí, así
# que pedir la recién salida con uno de ellos aborta). El menú avisa antes, en
# lugar de dejar que el build reviente a mitad.
# Reglas: fail-open (sin red o API caída => no se avisa de nada y el menú sigue
# igual), con caché para no pagar el sondeo en cada apertura, y nunca más de
# unos segundos de espera.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kernel-update"
FORK_TAGS_CACHE="${CIZEN_FORK_TAGS_CACHE:-$STATE_DIR/cachyos-fork-tags.cache}"
FORK_TTL="${CIZEN_FORK_TAGS_TTL:-21600}"   # 6 h
FORK_API="${CIZEN_FORK_RELEASES_API:-https://api.github.com/repos/CachyOS/linux/releases?per_page=20}"
FORK_TAGS=""        # tags del fork conocidos (cachyos-<ver>-<tagrel>)

load_fork_tags() {
  [ "${CIZEN_MENU_SKIP_FORK_CHECK:-0}" = "1" ] && return 1
  local now ts json tags
  now="$(date +%s)"
  if [ -r "$FORK_TAGS_CACHE" ]; then
    ts="$(head -n1 "$FORK_TAGS_CACHE" 2>/dev/null || echo 0)"
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    if [ "$ts" -gt 0 ] && [ "$(( now - ts ))" -lt "$FORK_TTL" ]; then
      FORK_TAGS="$(tail -n +2 "$FORK_TAGS_CACHE" 2>/dev/null)"
      if [ -n "$FORK_TAGS" ]; then return 0; fi
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    json="$(curl -fsS --max-time 5 "$FORK_API" 2>/dev/null || true)"
  elif command -v wget >/dev/null 2>&1; then
    json="$(wget -qO- --timeout=5 --tries=1 "$FORK_API" 2>/dev/null || true)"
  else
    return 1
  fi
  tags="$(printf '%s' "$json" \
    | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"cachyos-[^"]+"' \
    | sed -E 's/.*"(cachyos-[^"]+)"/\1/' | sort -u)"
  [ -n "$tags" ] || return 1        # sin red / API caída: no se avisa (fail-open)
  FORK_TAGS="$tags"
  if mkdir -p -- "$STATE_DIR" 2>/dev/null; then
    { printf '%s\n' "$now"; printf '%s\n' "$tags"; } > "$FORK_TAGS_CACHE" 2>/dev/null || true
  fi
  return 0
}

fork_tagrel() { # $1=versión -> tagrel mayor de cachyos-$1-N (vacío si no existe)
  printf '%s\n' "$FORK_TAGS" | sed -n "s/^cachyos-$1-\([0-9][0-9]*\)$/\1/p" | sort -n | tail -n1
}

fork_latest_minor() { # $1=7.2.8 -> última X.Y.Z del fork de esa línea X.Y
  local minor="${1%.*}"
  printf '%s\n' "$FORK_TAGS" | sed -n "s/^cachyos-\($minor\.[0-9][0-9]*\)-[0-9][0-9]*$/\1/p" \
    | sort -V | tail -n1
}

REMOTE="${1:-}"
if [ -z "$REMOTE" ] && [ -t 0 ]; then
  REMOTE="$(discover_remote 2>/dev/null || true)"
fi

# ── Estado del rollback (opción 9) ──────────────────────────────
# v27.31.24: el rollback reinstala el PAQUOTE del kernel anterior, no solo
# extrae ficheros, y ese paquete es de un build concreto (con su scheduler).
# Decirlo en la propia opción evita el viaje a la terminal para descubrir que no
# hay nada que deshacer — o, peor, que hay algo distinto de lo que uno creería.
ROLLBACK_SCRIPT="${CIZEN_KROLLBACK_SCRIPT:-/usr/local/bin/kernel-update/kernel-update-rollback.sh}"
ROLLBACK_DIR="${CIZEN_ROLLBACK_DIR:-/var/lib/kernel-update/rollback}"

rollback_resumen() { # una línea para la etiqueta de la opción 9
  local mf="$ROLLBACK_DIR/rollback.info" pkgbase pkgver sched pkgfile
  if [ ! -r "$mf" ]; then
    # Sin manifiesto legible: puede no haber nada, o estar en un dir con otro
    # permiso. No se inventa: se dice lo que se sabe.
    if [ -d "$ROLLBACK_DIR" ]; then printf 'no hay kernel anterior preservado'; else printf 'nunca se ha hecho rollback'; fi
    return 0
  fi
  pkgbase="$(sed -n 's/^pkgbase=//p' "$mf" 2>/dev/null | head -n1)"
  pkgver="$(sed -n 's/^pkgver=//p' "$mf" 2>/dev/null | head -n1)"
  sched="$(sed -n 's/^sched=//p' "$mf" 2>/dev/null | head -n1)"
  pkgfile="$(sed -n 's/^pkgfile=//p' "$mf" 2>/dev/null | head -n1)"
  if [ -z "$pkgver" ]; then
    printf 'sin kernel anterior preservado'
  elif [ -n "$pkgfile" ] && [ -r "$ROLLBACK_DIR/$pkgfile" ]; then
    printf '%s-%s%s' "${pkgbase:-linux-cizen-v3}" "$pkgver" "${sched:+ ($sched)}"
  else
    printf '%s-%s%s ⚠ sin paquete' "${pkgbase:-linux-cizen-v3}" "$pkgver" "${sched:+ ($sched)}"
  fi
}

LOCAL="$(uname -r)"
MOTOR_VER="$(awk -F'"' '/^SCRIPT_VERSION=/{print $2; exit}' "$SCRIPT" 2>/dev/null || true)"
[ -n "$MOTOR_VER" ] && MOTOR_VER="v$MOTOR_VER"

# ¿La stable que anuncia kernel.org existe ya en el fork CachyOS? Solo se
# consulta con una versión con forma de versión (nada de redirigir el sondeo a
# otra cosa) y nunca se bloquea el menú por ello.
FORK_MISSING=0
FORK_FALLBACK=""
FORK_MINOR=""
if [ -n "$REMOTE" ] && [[ "$REMOTE" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] && load_fork_tags; then
  if [ -z "$(fork_tagrel "$REMOTE")" ]; then
    FORK_MISSING=1
    FORK_FALLBACK="$(fork_latest_minor "$REMOTE")"
    FORK_MINOR="${REMOTE%.*}.x"
  fi
fi

# ── Regla separadora (ASCII) y fila de columnas del encabezado ─
RULE="$(printf '%*s' 55 '' | tr ' ' '-')"
rule() { printf '%s\n' "$RULE"; }
hrow() { # $1=columna izquierda (coloreada), $2=derecha (coloreada)
  local left_vis pad
  left_vis="$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g')"
  pad=$(( 24 - ${#left_vis} )); [ "$pad" -lt 0 ] && pad=0
  printf '    %s%b%*s%b   |   %s\n' "$1" "$N" "$pad" '' "$N" "$2"
}

rule
hrow "${W}●  Kernel Update · Cizen${N}" "${G}Motor${N} ${MOTOR_VER}"
rule
if [ -n "$REMOTE" ]; then
  hrow "${G}Instalado${N}  $LOCAL" "${Y}Stable${N}   $REMOTE"
else
  hrow "${G}Instalado${N}  $LOCAL" "${Y}Stable${N}   desconocida"
fi
rule
rule

# Aviso preventivo: la stable de kernel.org todavía no está en el fork.
if [ "$FORK_MISSING" = 1 ]; then
  if [ -n "$FORK_FALLBACK" ]; then
    printf '  %b⚠  La stable %s aún NO está en el fork CachyOS (su última %s es %s).%b\n' \
      "$Y2" "$REMOTE" "$FORK_MINOR" "$FORK_FALLBACK" "$N"
    printf '     pds/bmq/lfbmq/muqss solo existen en el fork: con %s abortarán (opción 14).\n' "$REMOTE"
    printf '     Opción 14: se te ofrecerá %s al elegir uno de ellos, o usa eevdf para %s vanilla.\n' \
      "$FORK_FALLBACK" "$REMOTE"
  else
    printf '  %b⚠  La stable %s aún NO está en el fork CachyOS.%b\n' "$Y2" "$REMOTE" "$N"
    printf '     pds/bmq/lfbmq/muqss solo existen en el fork: con %s abortarán (opción 14).\n' "$REMOTE"
    printf '     Para %s vanilla usa el scheduler eevdf; volverán cuando el fork la publique.\n' "$REMOTE"
  fi
  rule
fi

opt() { # $1=número $2=nombre $3=descripción
  printf '%b%5s%b)  %-13s %s\n' "$C" "$1" "$N" "$2" "$3"
}

echo "  ${W}Validación${N}"
opt 1 "check"       "validar config · baja"
opt 2 "checkfast"   "validar config · alta"
rule
echo "  ${W}Compilación${N}"
opt 3 "build"       "compilar + instalar · baja"
opt 4 "buildfast"   "compilar + instalar · alta"
opt 5 "force"       "recompilar con (--force)"
opt 7 "buildbore"   "compilar con BORE · baja"
opt 8 "buildborefast" "compilar con BORE · alta"
if [ "$FORK_MISSING" = 1 ]; then
  opt 14 "variant"    "scheduler/tuning (interactivo) ⚠"
else
  opt 14 "variant"    "scheduler/tuning (interactivo)"
fi
opt 15 "ntsync"     "compilar con NTSync"
opt 16 "cachy"      "compilar con misc CachyOS"
rule
echo "  ${W}Mantenimiento${N}"
opt 10 "kcfg"       "editar config con menuconfig"
opt 11 "selftest"   "autoevaluación del motor"
opt 12 "changelog"  "bump + borrador → CHANGELOG.md"
opt 13 "hardened"   "auditoría hardening del kernel en ejecución"
opt 17 "manager"    "gestor de kernels instalados"
rule
echo "  ${W}Consulta y sistema${N}"
opt 6 "check-update" "última stable de kernel.org"
opt 9 "rollback"    "volver al kernel anterior · $(rollback_resumen)"
rule

while true; do
  read -r -p "${W}  [0-17] > ${N}" choice
  case "$choice" in
    1) exec "$SCRIPT" --absorb-rebels --check ;;
    2) CIZEN_BUILD_PRIORITY=normal exec "$SCRIPT" --absorb-rebels --check ;;
    3) exec "$SCRIPT" --absorb-rebels ;;
    4) CIZEN_BUILD_PRIORITY=normal exec "$SCRIPT" --absorb-rebels ;;
    5) exec "$SCRIPT" --force ;;
    6) exec "$SCRIPT" --check-update ;;
    7) exec "$SCRIPT" --absorb-rebels --patch bore ;;
    8) CIZEN_BUILD_PRIORITY=normal exec "$SCRIPT" --absorb-rebels --patch bore ;;
    9) if [ -x "$ROLLBACK_SCRIPT" ]; then
         exec "$ROLLBACK_SCRIPT"
       else
         # exec de un path inexistente solo da un error de bash que no explica
         # nada: el script de rollback vive aparte del motor y se puede instalar
         # (o desinstalar) por su cuenta.
         printf '  %b✗%b No está %s\n' "$R" "$N" "$ROLLBACK_SCRIPT"
         printf '    Instálalo con:  sudo install -Dm755 kernel-update/kernel-update-rollback.sh %s\n' "$ROLLBACK_SCRIPT"
         printf '    (o usa CIZEN_KROLLBACK_SCRIPT si vive en otra ruta)\n'
       fi ;;
    10) exec "$SCRIPT" --absorb-rebels --menuconfig ;;
    11) exec "$SCRIPT" --selftest ;;
    12) exec "$SCRIPT" --changelog ;;
    13) exec "$SCRIPT" --hardened ;;
    14)
       if [ "$FORK_MISSING" = 1 ]; then
         printf '\n  %bAviso:%b la stable %s no está en el fork CachyOS' "$Y2" "$N" "$REMOTE"
         [ -n "$FORK_FALLBACK" ] && printf ' (su última %s es %s)' "$FORK_MINOR" "$FORK_FALLBACK"
         printf '.\n'
       fi
       printf '\n  %bScheduler%b (Enter usa el default; los valores de tercera parte avisan si no aplican a la rama):\n' "$W" "$N"
       printf '    %binherit%b mantener el del perfil/último build (default → EEVDF salvo perfil)\n' "$W" "$N"
       printf '    %beevdf%b   scheduler vanilla de mainline\n' "$W" "$N"
       printf '    %bbore%b    BORE (el que usa este sistema; burst + interactividad)\n' "$W" "$N"
       printf '    %bpds%b     Project C (PDS) · tercero\n' "$W" "$N"
       printf '    %bbmq%b     BMQ · tercero\n' "$W" "$N"
       printf '    %blfbmq%b   LF-BMQ · tercero\n' "$W" "$N"
       printf '    %bmuqss%b   MuQSS · tercero\n' "$W" "$N"
       printf '  %bScheduler%b [Enter=%blinherit%b]: ' "$W" "$N" "$Y" "$N"
       read -r sched
       printf '\n  %bCC%b (Enter usa el default):\n' "$W" "$N"
       printf '    %bauto%b  elige según el sistema (clang si LTO/toolchain LLVM viable; si no gcc) (default)\n' "$W" "$N"
       printf '    %bgcc%b   compilador GCC\n' "$W" "$N"
       printf '    %bclang%b Clang/LLVM (necesario para el LTO)\n' "$W" "$N"
       printf '    %botro%b  teclea TU compilador (p. ej. gcc-14, clang-17 o una ruta). Se exigirá como dependencia si falta.\n' "$W" "$N"
       printf '  %bCC%b [Enter=%blauto%b]: ' "$W" "$N" "$Y" "$N"
       read -r cc
       # v27.31.16: si el scheduler elegido solo existe en el fork y la versión
       # no está publicada allí, se ofrece la última del fork de esa línea en
       # lugar de dejar que el build aborte. Sin TTY (o sin fallback) se sigue
       # con la versión pedida: el motor explica la causa con claridad.
       use_version=""
       case "$sched" in
         pds|bmq|lfbmq|muqss)
           if [ "$FORK_MISSING" = 1 ] && [ -n "$FORK_FALLBACK" ] \
              && [ "$FORK_FALLBACK" != "$REMOTE" ] && [ -t 0 ]; then
             printf '\n  %bEl fork CachyOS no tiene %s; su última release es %s.%b\n' \
               "$Y" "$REMOTE" "$FORK_FALLBACK" "$N"
             printf '  ¿Compilar %s en su lugar? [S/n]: ' "$FORK_FALLBACK"
             read -r _ans
             case "${_ans:-S}" in
               [SsYy]*) use_version="$FORK_FALLBACK" ;;
             esac
             [ -n "$use_version" ] \
               && printf '  %bOK: %s + %s.%b\n' "$W" "$use_version" "$sched" "$N"
           fi
           ;;
       esac
       args="--absorb-rebels"
       [ -n "$use_version" ] && args="$use_version $args"
       [ -n "$sched" ] && args="$args --sched $sched"
       [ -n "$cc" ] && args="$args --cc $cc"
       # shellcheck disable=SC2086
       exec "$SCRIPT" $args ;;
    15) exec "$SCRIPT" --absorb-rebels --ntsync ;;
    16) exec "$SCRIPT" --absorb-rebels --cachy ;;
    17) exec /usr/local/bin/kernel-update/kernel-update-manager.sh ;;
    0) echo "  Saliendo."; exit 0 ;;
    *) printf '  %bOpción no válida: %s%b\n' "$R" "$choice" "$N" ;;
  esac
done