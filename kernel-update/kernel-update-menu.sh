#!/usr/bin/env bash
# ============================================================
# kernel-update-menu.sh — Menú interactivo para kernel-update.sh
# Abre un menú con los modos del script: validación, compilación,
# consulta. Llamado por kernel-update-notify.sh vía arch-open-terminal.sh,
# o directamente desde una terminal.
#
# Uso: ./kernel-update-menu.sh [remote]
#   remote = versión estable de kernel.org a mostrar en el encabezado
# ============================================================
set -uo pipefail

SCRIPT="${CIZEN_KERNEL_SCRIPT:-$HOME/kernel-update.sh}"
REMOTE="${1:-}"

if [ ! -x "$SCRIPT" ]; then
  echo "Error: $SCRIPT no encontrado o no ejecutable." >&2
  exit 1
fi

# Colores (solo en terminal interactiva)
if [ -t 1 ]; then
  G=$'\033[0;32m'; Y=$'\033[1;33m'; C=$'\033[0;36m'; R=$'\033[0;31m'; N=$'\033[0m'
else
  G=""; Y=""; C=""; R=""; N=""
fi

LOCAL="$(uname -r)"

echo "${C}═══════════════════════════════════════════════════${N}"
echo "${C}  kernel-update.sh — Menú de compilación${N}"
echo "${C}═══════════════════════════════════════════════════${N}"
echo
printf "  Instalado:  %b%s%b\n" "$G" "$LOCAL" "$N"
if [ -n "$REMOTE" ]; then
  printf "  Stable:     %b%s%b\n" "$Y" "$REMOTE" "$N"
else
  echo "  Stable:     (desconocida — opción 6 para consultar)"
fi
echo
echo "  ${C}Validación:${N}"
echo "    ${G}1${N}) check       validar config, ofrecer compilar después (prioridad baja)"
echo "    ${G}2${N}) checkfast   validar config a plena prioridad (sin nice/ionice)"
echo
echo "  ${C}Compilación:${N}"
echo "    ${G}3${N}) build       compilar e instalar directamente (prioridad baja)"
echo "    ${G}4${N}) buildfast   compilar e instalar a plena prioridad"
echo "    ${G}5${N}) force       recompilar forzado (--force)"
echo
echo "  ${C}Consulta:${N}"
echo "    ${G}6${N}) check-update consultar última release estable (sin modificar nada)"
echo
echo "    ${G}0${N}) salir"
echo

while true; do
  read -r -p "  Selección [0-6]: " choice
  case "$choice" in
    1) exec "$SCRIPT" --check ;;
    2) CIZEN_BUILD_PRIORITY=normal exec "$SCRIPT" --check ;;
    3) exec "$SCRIPT" ;;
    4) CIZEN_BUILD_PRIORITY=normal exec "$SCRIPT" ;;
    5) exec "$SCRIPT" --force ;;
    6) exec "$SCRIPT" --check-update ;;
    0) echo "  Saliendo."; exit 0 ;;
    *) printf "  %bOpción no válida.%b\n" "$R" "$N" ;;
  esac
done
