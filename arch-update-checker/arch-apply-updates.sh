#!/usr/bin/env bash
set -u
PENDING="/var/cache/arch-update-checker/pending"

pause_final() {
  if [[ -n "${AUC_AUTO_WINDOW:-}" ]]; then
    read -r -p "Pulsa Enter para cerrar… " _
  else
    echo "✔ Asistente finalizado. (Ejecución manual: tu terminal permanece abierta.)"
    read -r -p "Pulsa Enter para continuar… " _
  fi
}

echo "──────────────────────────────────────────"
echo " Arch Update Checker · Asistente de actualización"
echo "──────────────────────────────────────────"

n_off=""; n_aur=""; n_fp=""
if [[ -s "$PENDING" ]]; then
  linea="$(sed -n '2p' "$PENDING")"
  [[ "$linea" =~ Repositorios\ oficiales:\ ([0-9]+) ]] && n_off="${BASH_REMATCH[1]}"
  [[ "$linea" =~ AUR:\ ([0-9]+) ]] && n_aur="${BASH_REMATCH[1]}"
  [[ "$linea" =~ Flatpak:\ ([0-9]+) ]] && n_fp="${BASH_REMATCH[1]}"
fi

if [[ -z "${AUC_ALREADY_SHOWN:-}" && -s "$PENDING" ]]; then
  echo
  head -n 30 "$PENDING"
  echo
fi

actualizado=0
updated_pkgs=""

### REPOS OFICIALES ###
if [[ -z "$n_off" ]] || (( n_off > 0 )); then
  read -r -p "¿Actualizar repositorios oficiales con pacman? [S/n] " r
  if [[ ! "$r" =~ ^[Nn] ]]; then
    sudo pacman -Sy
    updated_pkgs="$(pacman -Quq 2>/dev/null)"
    if command -v snapper >/dev/null 2>&1; then
      read -r -p "¿Crear snapshot Btrfs previo con snapper? [S/n] " s
      if [[ ! "$s" =~ ^[Nn] ]]; then
        if sudo snapper create --description "Pre-actualización $(date '+%F %T')" --cleanup-algorithm timeline >/dev/null 2>&1; then
          echo "✔ Snapshot Btrfs creado."
        else
          echo "⚠ No se pudo crear el snapshot (revisa snapper); continuando…"
        fi
      fi
    fi
    if sudo pacman -Syu; then actualizado=1; fi
  else
    echo "Omitido."
  fi
else
  echo "· Repositorios oficiales: sin actualizaciones pendientes."
fi

### AUR ###
helper=""
command -v yay >/dev/null 2>&1 && helper=yay
[[ -z "$helper" ]] && command -v paru >/dev/null 2>&1 && helper=paru
if [[ -z "$n_aur" ]] || (( n_aur > 0 )); then
  if [[ -n "$helper" ]]; then
    read -r -p "¿Actualizar AUR con $helper? [S/n] " a
    if [[ ! "$a" =~ ^[Nn] ]]; then
      if "$helper" -Syu; then actualizado=1; fi
    else
      echo "Omitido."
    fi
  else
    echo "· Hay actualizaciones de AUR, pero no hay yay/paru instalado."
  fi
else
  echo "· AUR: sin actualizaciones pendientes."
fi

### FLATPAK ###
if command -v flatpak >/dev/null 2>&1 && { [[ -z "$n_fp" ]] || (( n_fp > 0 )); }; then
  read -r -p "¿Actualizar paquetes Flatpak? [S/n] " f
  if [[ ! "$f" =~ ^[Nn] ]]; then
    if sudo flatpak update; then actualizado=1; fi
    if [[ -d "$HOME/.local/share/flatpak" ]]; then
      flatpak update --user >/dev/null 2>&1 || true
    fi
  else
    echo "Omitido."
  fi
else
  echo "· Flatpak: sin actualizaciones pendientes."
fi

echo
echo "──────────────────────────────────────────"
echo " Mantenimiento del sistema"
echo "──────────────────────────────────────────"

### 1) .pacnew / .pacsave / .pacorig ###
pacnew_list="$(sudo find /etc /opt -type f \( -name '*.pacnew' -o -name '*.pacorig' -o -name '*.pacsave' \) 2>/dev/null || true)"
if [[ -n "$pacnew_list" ]]; then
  echo "⚙ Archivos de configuración pendientes de revisión ($(wc -l <<<"$pacnew_list")):"
  printf '%s\n' "$pacnew_list" | sed 's/^/   • /'
  if command -v pacdiff >/dev/null 2>&1; then
    read -r -p "¿Revisarlos ahora con pacdiff? [S/n] " p
    [[ "$p" =~ ^[Nn] ]] || sudo pacdiff
  else
    echo "  (instala pacman-contrib para usar pacdiff)"
  fi
else
  echo "· Sin archivos .pacnew/.pacsave pendientes."
fi

### 2) Huérfanos ###
orphans="$(pacman -Qdtq 2>/dev/null || true)"
if [[ -n "$orphans" ]]; then
  echo "⚙ Paquetes huérfanos detectados:"
  printf '%s\n' "$orphans" | sed 's/^/   • /'
  read -r -p "¿Eliminarlos con 'pacman -Rns'? [S/n] " o
  if [[ ! "$o" =~ ^[Nn] ]]; then
    orphan_list=( $orphans )
    sudo pacman -Rns "${orphan_list[@]}" && echo "✔ Huérfanos eliminados."
  fi
else
  echo "· Sin paquetes huérfanos."
fi

### 3) Servicios que requieren reinicio ###
if [[ -n "$updated_pkgs" ]]; then
  declare -A sys_units=() usr_units=()
  for pkg in $updated_pkgs; do
    while read -r u; do
      [[ -n "$u" ]] && sys_units["$u"]=1
    done < <(pacman -Ql "$pkg" 2>/dev/null | awk '{print $2}' | grep -E '/usr/lib/systemd/system/[^/]+\.(service|socket|timer)$' | xargs -rn1 basename 2>/dev/null)
    while read -r u; do
      [[ -n "$u" ]] && usr_units["$u"]=1
    done < <(pacman -Ql "$pkg" 2>/dev/null | awk '{print $2}' | grep -E '/usr/lib/systemd/user/[^/]+\.(service|socket|timer)$' | xargs -rn1 basename 2>/dev/null)
  done
  sys_active=""
  for u in "${!sys_units[@]}"; do
    systemctl is-active --quiet "$u" 2>/dev/null && sys_active+="$u "
  done
  usr_active=""
  for u in "${!usr_units[@]}"; do
    systemctl --user is-active --quiet "$u" 2>/dev/null && usr_active+="$u "
  done
  if [[ -n "$sys_active" || -n "$usr_active" ]]; then
    echo "⚙ Servicios activos cuyos paquetes se actualizaron:"
    [[ -n "$sys_active" ]] && printf '   • [sistema] %s\n' $sys_active
    [[ -n "$usr_active" ]] && printf '   • [usuario] %s\n' $usr_active
    read -r -p "¿Reiniciarlos ahora? [S/n] " rs
    if [[ ! "$rs" =~ ^[Nn] ]]; then
      [[ -n "$sys_active" ]] && sudo systemctl restart $sys_active
      [[ -n "$usr_active" ]] && systemctl --user restart $usr_active
      echo "✔ Servicios reiniciados."
    fi
  else
    echo "· Ningún servicio activo requiere reinicio."
  fi
  if grep -qx systemd <<<"$updated_pkgs"; then
    echo "⚙ systemd actualizado: ejecutando daemon-reexec…"
    sudo systemctl daemon-reexec
  fi
  ### 4) Reinicio recomendado (paquetes críticos) ###
  reboot_hits=""
  for p in linux linux-lts linux-zen linux-hardened linux-rt linux-firmware intel-ucode amd-ucode systemd glibc mesa mesa-utils nvidia nvidia-utils; do
    grep -qx "$p" <<<"$updated_pkgs" && reboot_hits+="$p "
  done
  if [[ -n "$reboot_hits" ]]; then
    echo
    echo "⚠ Se actualizaron paquetes críticos: $reboot_hits"
    echo "  Se RECOMIENDA REINICIAR el sistema para aplicar los cambios."
    read -r -p "¿Reiniciar ahora? [s/N] " rb
    [[ "$rb" =~ ^[Ss] ]] && sudo systemctl reboot
  fi
else
  echo "· No se registraron paquetes actualizados en esta sesión."
fi

### REFRESCO (background, no bloqueante) ###
echo
if (( actualizado == 1 )); then
  setsid nohup sudo /usr/local/bin/arch-update-checker.sh --quick-refresh >/dev/null 2>&1 &
  disown
  echo "✔ Refresco lanzado en segundo plano (se completará en unos segundos)."
else
  echo "No se aplicaron cambios; el estado se refrescará solo cada 6 h."
fi

pause_final