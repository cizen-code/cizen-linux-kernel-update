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
# 9 rollback, 10 kcfg, 11 selftest, 12 changelog, 13 hardened, 0 salir.
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

REMOTE="${1:-}"
if [ -z "$REMOTE" ] && [ -t 0 ]; then
  REMOTE="$(discover_remote 2>/dev/null || true)"
fi

LOCAL="$(uname -r)"
MOTOR_VER="$(awk -F'"' '/^SCRIPT_VERSION=/{print $2; exit}' "$SCRIPT" 2>/dev/null || true)"
[ -n "$MOTOR_VER" ] && MOTOR_VER="v$MOTOR_VER"

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
opt 14 "variant"    "scheduler/tuning (interactivo)"
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
opt 9 "rollback"    "restaurar kernel previo"
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
    9) exec /usr/local/bin/kernel-update/kernel-update-rollback.sh ;;
    10) exec "$SCRIPT" --absorb-rebels --menuconfig ;;
    11) exec "$SCRIPT" --selftest ;;
    12) exec "$SCRIPT" --changelog ;;
    13) exec "$SCRIPT" --hardened ;;
    14)
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
       args="--absorb-rebels"
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