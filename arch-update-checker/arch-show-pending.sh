#!/usr/bin/env bash
PENDING="/var/cache/arch-update-checker/pending"

pause_final() {
  if [[ -n "${AUC_AUTO_WINDOW:-}" ]]; then
    read -r -p "Pulsa Enter para cerrar… " _
  else
    echo "✔ Visor finalizado. (Ejecución manual: tu terminal permanece abierta.)"
    read -r -p "Pulsa Enter para continuar… " _
  fi
}

clear
echo "──────────────────────────────────────────"
echo " Arch Update Checker · Informe completo"
echo "──────────────────────────────────────────"
echo
if [[ -s "$PENDING" ]]; then
  cat "$PENDING"
  echo
  read -r -p "¿Desea realizar la actualización ahora? [S/n] " r
  if [[ ! "$r" =~ ^[Nn] ]]; then
    exec env AUC_ALREADY_SHOWN=1 AUC_AUTO_WINDOW="${AUC_AUTO_WINDOW:-}" /usr/local/bin/arch-update/arch-apply-updates.sh
  fi
  pause_final
else
  echo "Sin datos pendientes."
  pause_final
fi
