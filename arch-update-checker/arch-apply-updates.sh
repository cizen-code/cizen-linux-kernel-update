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

# Offset del log de pacman para detectar SOLO lo realmente actualizado en esta sesión
PACMAN_LOG="/var/log/pacman.log"
PACMAN_LOG_OFF=0
[[ -r "$PACMAN_LOG" ]] && PACMAN_LOG_OFF="$(stat -c%s "$PACMAN_LOG" 2>/dev/null || echo 0)"

### REPOS OFICIALES ###
if [[ -z "$n_off" ]] || (( n_off > 0 )); then
  read -r -p "¿Actualizar repositorios oficiales con pacman? [S/n] " r
  if [[ ! "$r" =~ ^[Nn] ]]; then
    sudo pacman -Sy
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
# updated_pkgs = SOLO lo realmente actualizado en esta sesión (vía pacman.log)
if [[ -n "$PACMAN_LOG_OFF" ]] && (( PACMAN_LOG_OFF > 0 )); then
  updated_pkgs="$(tail -c +$((PACMAN_LOG_OFF+1)) "$PACMAN_LOG" 2>/dev/null | sed -n 's/.*\[ALPM\] upgraded \([^ ]*\) .*/\1/p' | sort -u)"
fi
if [[ -n "$updated_pkgs" ]]; then
  # Unidades que JAMÁS se reinician en caliente (rompen sesión gráfica, red o servicios críticos)
  never_restart() {
    case "$1" in
      # D-Bus: reiniciar el bus tumba las conexiones de la sesión gráfica y de los servicios
      dbus.service|dbus.socket|dbus-broker.service) return 0 ;;
      # Gestores de display / sesión gráfica
      display-manager.service|sddm.service|gdm.service|lightdm.service|lxdm.service|plasmalogin.service) return 0 ;;
      # Sesión gráfica de usuario (plasma-login / kwin)
      plasma-login.service|plasma-login-kwin_wayland.service) return 0 ;;
      # Consolas virtuales
      getty@*.service) return 0 ;;
      # Red crítica (caída momentánea de red/DNS)
      NetworkManager.service|systemd-networkd.service|systemd-resolved.service|nftables.service) return 0 ;;
      # Subsistemas del núcleo de systemd (logind/udev/journald/…)
      systemd-logind.service|systemd-user-sessions.service|systemd-udevd.service|systemd-journald.service|systemd-timesyncd.service) return 0 ;;
    esac
    return 1
  }
  declare -A sys_units=() usr_units=()
  for pkg in $updated_pkgs; do
    # El paquete systemd no se trata aquí: su update se aplica con daemon-reexec + reboot
    [[ "$pkg" == "systemd" ]] && continue
    while read -r u; do
      [[ -n "$u" ]] && sys_units["$u"]=1
    done < <(pacman -Ql "$pkg" 2>/dev/null | awk '{print $2}' | grep -E '/usr/lib/systemd/system/[^/]+\.(service|socket|timer)$' | xargs -rn1 basename 2>/dev/null)
    while read -r u; do
      [[ -n "$u" ]] && usr_units["$u"]=1
    done < <(pacman -Ql "$pkg" 2>/dev/null | awk '{print $2}' | grep -E '/usr/lib/systemd/user/[^/]+\.(service|socket|timer)$' | xargs -rn1 basename 2>/dev/null)
  done
  sys_skipped=""; usr_skipped=""; sys_active=""; usr_active=""
  for u in "${!sys_units[@]}"; do
    systemctl is-active --quiet "$u" 2>/dev/null || continue
    if never_restart "$u"; then sys_skipped+="$u "; else sys_active+="$u "; fi
  done
  for u in "${!usr_units[@]}"; do
    systemctl --user is-active --quiet "$u" 2>/dev/null || continue
    if never_restart "$u"; then usr_skipped+="$u "; else usr_active+="$u "; fi
  done
  if [[ -z "$sys_active" && -z "$usr_active" ]]; then
    echo "· Ningún servicio activo seguro requiere reinicio ahora."
  else
    echo "⚙ Servicios activos cuyos paquetes se actualizaron (seguros de reiniciar en caliente):"
    [[ -n "$sys_active" ]] && printf '   • [sistema] %s\n' $sys_active
    [[ -n "$usr_active" ]] && printf '   • [usuario] %s\n' $usr_active
    read -r -p "¿Reiniciarlos ahora? [S/n] " rs
    if [[ ! "$rs" =~ ^[Nn] ]]; then
      err=0
      for u in $sys_active; do
        sudo systemctl restart "$u" && echo "   ✔ $u reiniciado" || { err=1; echo "   ✗ fallo al reiniciar $u (systemctl status $u)"; }
      done
      for u in $usr_active; do
        systemctl --user restart "$u" && echo "   ✔ $u reiniciado (usuario)" || { err=1; echo "   ✗ fallo al reiniciar $u (usuario)"; }
      done
      [[ "$err" -eq 0 ]] && echo "✔ Servicios reiniciados."
    fi
  fi
  if [[ -n "$sys_skipped" || -n "$usr_skipped" ]]; then
    echo "⚠ NO reiniciados en caliente (romperían sesión/red; se aplican con un reinicio del sistema):"
    [[ -n "$sys_skipped" ]] && printf '   • %s\n' $sys_skipped
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
  setsid nohup sudo /usr/local/bin/arch-update/arch-update-checker.sh --quick-refresh >/dev/null 2>&1 &
  disown
  echo "✔ Refresco lanzado en segundo plano (se completará en unos segundos)."
else
  echo "No se aplicaron cambios; el estado se refrescará solo cada 6 h."
fi

pause_final