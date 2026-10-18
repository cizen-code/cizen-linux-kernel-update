#!/usr/bin/env bash
set -u

PENDING="/var/cache/arch-update-checker/pending"
# Unidades y binarios de la suite; se comprueba su existencia antes de usarlos.
CHECKER_SERVICE="arch-update-checker.service"
UKI_SYNC_BIN="/usr/local/bin/cizen-uki-sync"
KERNEL_NOTIFY_BIN="/usr/local/bin/kernel-update/kernel-update-notify.sh"

pause_final() {
  if [[ -n "${AUC_AUTO_WINDOW:-}" ]]; then
    read -r -p "Pulsa Enter para cerrar… " _
  else
    echo "✔ Asistente finalizado. (Ejecución manual: tu terminal permanece abierta.)"
    read -r -p "Pulsa Enter para continuar… " _
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Diagnóstico y arreglo de conflictos de archivos (pacman).
#
# pacman aborta con «archivos en conflicto» / «conflicting files» cuando un
# paquete a actualizar instala un fichero que ya posee otro paquete instalado
# (o que existe sin dueño). Causa habitual: el paquete propietario va retrasado
# en un repo (p. ej. ALHP x86-64-v3 tarda en recompilar) mientras el paquete
# nuevo ya llegó a otro repo. Aquí se detecta el conflicto, se busca una
# versión más nueva del propietario en cualquier repo y se ofrece corregir y
# reintentar; si no la hay, se ofrece `--overwrite`; y en último término se
# sugieren los comandos manuales.
# ─────────────────────────────────────────────────────────────────────────────

# Extrae los conflictos del log de pacman: líneas "<fichero>|<pkg>|<dueño>".
parse_file_conflicts() {
  local log="$1" line pkg rest file owner
  grep -aE '^[^:[:space:]]+: .+ (ya existe en el sistema de archivos|exists in filesystem)' "$log" 2>/dev/null |
  while IFS= read -r line; do
    pkg="${line%%:*}"
    rest="${line#*: }"
    file="$(sed -E 's/ (ya existe en el sistema de archivos|exists in filesystem)( \(.*\))?$//' <<<"$rest")"
    owner="$(sed -nE 's/.*\((es parte de|owned by) ([^)]+)\)$/\2/p' <<<"$rest")"
    [[ -n "$owner" ]] || owner="$(pacman -Qoq "$file" 2>/dev/null | head -n1 || true)"
    [[ -n "$file" ]] || continue
    printf '%s|%s|%s\n' "$file" "$pkg" "$owner"
  done
}

# Mejor candidato disponible de un paquete: "<repo> <versión>" (vacío si no está).
pkg_best_repo() {
  local pkg="$1" repo v best_repo="" best_ver=""
  while read -r repo; do
    [[ -n "$repo" ]] || continue
    # `-Si repo/pkg` interroga SOLO ese paquete en ese repo. `pacman -Sl repo`
    # vuelca el índice completo (decenas de miles de líneas) por cada conflicto.
    v="$(LC_ALL=C pacman -Si "$repo/$pkg" 2>/dev/null |
      awk -F' *: *' '/^Version/ {print $2; exit}')"
    [[ -n "$v" ]] || continue
    if [[ -z "$best_ver" ]] || (( $(vercmp "$v" "$best_ver") > 0 )); then
      best_ver="$v"; best_repo="$repo"
    fi
  done < <(pacman-conf --repo-list 2>/dev/null)
  [[ -n "$best_ver" ]] && printf '%s %s\n' "$best_repo" "$best_ver"
}

# Snapshot Btrfs previo. Se pide y se crea ANTES de cualquier operación de red
# de pacman. Un snapshot tomado tras `pacman -Sy` fija las bases de datos nuevas
# con los binarios viejos: restaurarlo devuelve el sistema a un estado de
# upgrade parcial (partial upgrade), que es exactamente lo que pacman impide.
maybe_create_snapshot() {
  command -v snapper >/dev/null 2>&1 || return 0
  read -r -p "¿Crear snapshot Btrfs previo con snapper? [S/n] " s
  [[ "$s" =~ ^[Nn] ]] && return 0
  if sudo snapper create --description "Pre-actualización $(date '+%F %T')" \
       --cleanup-algorithm timeline; then
    echo "✔ Snapshot Btrfs creado."
  else
    echo "⚠ No se pudo crear el snapshot (revisa snapper); continuando…"
  fi
}

# Pistas para errores que no son conflictos de archivos.
print_error_hints() {
  local log="$1"
  grep -aqE 'could not satisfy dependencies|no se pudo satisfactor|no se pudieron satisfacer' "$log" &&
    { echo "   ↳ Dependencias no resolubles: suele indicar upgrade parcial (algún repo,";
      echo "     p. ej. ALHP x86-64-v3, va retrasado). Prueba 'sudo pacman -Syu' de nuevo."; }
  grep -aqiE 'invalid|corrupt|no válido|dañado|signature|firma|clave|keyring' "$log" &&
    echo "   ↳ Posible paquete/firma inválida: 'sudo pacman -Sy archlinux-keyring' o limpia la caché."
  grep -aqiE 'unable to lock|no se puede bloquear|db\.lck' "$log" &&
    echo "   ↳ Base de datos bloqueada: ¿hay otra instancia de pacman en ejecución?"
  return 0
}

# Actualiza repos oficiales con detección y arreglo automático de conflictos.
run_official_upgrade() {
  local log rc attempt=0 r file owner inst best_repo best_ver
  local -a pacman_extra=()
  local -a new_targets=()
  local -a manual=()
  local -a overwrite_files=()
  local -A seen_owner=() fix_repo=() fix_ver=() fix_inst=()
  local max_attempts=3

  while (( attempt < max_attempts )); do
    attempt=$(( attempt + 1 ))
    log="$(mktemp /tmp/arch-update-pacman.XXXXXX)"
    if (( ${#pacman_extra[@]} )); then
      sudo pacman -Syu "${pacman_extra[@]}" 2>&1 | tee "$log"
    else
      sudo pacman -Syu 2>&1 | tee "$log"
    fi
    rc=${PIPESTATUS[0]}
    if (( rc == 0 )); then
      rm -f "$log"
      return 0
    fi

    local conflicts
    conflicts="$(parse_file_conflicts "$log")"
    if [[ -z "$conflicts" ]]; then
      echo
      echo "⚠ pacman terminó con errores (código $rc)."
      grep -aE '^(error|warning|aviso)' "$log" | tail -n 5 | sed 's/^/   /'
      print_error_hints "$log"
      echo "   Log completo: $log"
      return 1
    fi

    echo
    echo "⚙ Conflictos de archivos detectados:"
    overwrite_files=(); seen_owner=(); fix_repo=(); fix_ver=(); fix_inst=()
    while IFS='|' read -r file pkg owner; do
      [[ -n "$file" ]] || continue
      inst=""
      [[ -n "$owner" ]] && inst="$(pacman -Q "$owner" 2>/dev/null | awk '{print $2}' | head -n1)"
      printf '   • %s\n' "$file"
      if [[ -n "$owner" ]]; then
        printf '       lo instala también: %s | propietario actual: %s %s\n' "$pkg" "$owner" "${inst:+($inst)}"
      else
        printf '       lo instala también: %s | propietario actual: (ninguno, fichero sin dueño)\n' "$pkg"
      fi
      overwrite_files+=("$file")
      if [[ -n "$owner" && -n "$inst" && -z "${seen_owner[$owner]:-}" ]]; then
        seen_owner["$owner"]=1
        read -r best_repo best_ver < <(pkg_best_repo "$owner")
        if [[ -n "${best_ver:-}" ]] && (( $(vercmp "$best_ver" "$inst") > 0 )); then
          fix_repo["$owner"]="$best_repo"; fix_ver["$owner"]="$best_ver"; fix_inst["$owner"]="$inst"
        fi
      fi
    done <<<"$conflicts"

    r=""
    if (( ${#fix_repo[@]} )); then
      echo
      new_targets=()
      for owner in "${!fix_repo[@]}"; do
        echo "   Diagnóstico: '$owner' va retrasado (${fix_inst[$owner]}); '${fix_repo[$owner]}' ya ofrece"
        echo "   ${fix_ver[$owner]}, cuya versión no incluye el fichero en conflicto."
        new_targets+=("${fix_repo[$owner]}/$owner")
      done
      echo "   Corrección propuesta:  sudo pacman -Syu ${new_targets[*]}"
      read -r -p "¿Aplicarla y reintentar? [S/n] " r
      if [[ ! "$r" =~ ^[Nn] ]]; then
        local t
        for t in "${new_targets[@]}"; do
          [[ " ${pacman_extra[*]:-} " == *" $t "* ]] || pacman_extra+=("$t")
        done
        rm -f "$log"
        continue
      fi
    else
      echo
      echo "   No hay versiones más nuevas del propietario en ningún repo. El patrón habitual"
      echo "   para desbloquear es sobreescribir el fichero (equivalente al aviso de pacman)."
      echo "   ⚠ --overwrite sustituirá el fichero en conflicto por el que trae el paquete nuevo."
      read -r -p "¿Reintentar con --overwrite para esos ficheros? [S/n] " r
      if [[ ! "$r" =~ ^[Nn] ]]; then
        for file in "${overwrite_files[@]}"; do
          pacman_extra+=(--overwrite "$file")
        done
        rm -f "$log"
        continue
      fi
    fi

    echo
    echo "Sugerencias manuales:"
    if (( ${#fix_repo[@]} )); then
      manual=()
      for owner in "${!fix_repo[@]}"; do manual+=("${fix_repo[$owner]}/$owner"); done
      echo "   sudo pacman -Syu ${manual[*]}"
    fi
    for file in "${overwrite_files[@]}"; do
      echo "   sudo pacman -Syu --overwrite '$file'"
      echo "   pacman -Qo '$file'      # propietario del fichero"
    done
    echo "   Log completo: $log"
    return 1
  done

  echo "⚠ Se agotaron los reintentos automáticos; revisa el log: ${log:-?}"
  return 1
}

# Actualiza AUR con el helper disponible; en caso de conflicto, solo sugiere.
run_aur_upgrade() {
  local helper="$1" log rc conflicts file pkg owner
  log="$(mktemp /tmp/arch-update-aur.XXXXXX)"
  "$helper" -Syu 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if (( rc == 0 )); then
    rm -f "$log"
    return 0
  fi
  echo
  echo "⚠ $helper terminó con errores (código $rc)."
  conflicts="$(parse_file_conflicts "$log")"
  if [[ -n "$conflicts" ]]; then
    echo "   Conflictos de archivos detectados:"
    while IFS='|' read -r file pkg owner; do
      [[ -n "$file" ]] || continue
      printf '   • %s (lo instala también: %s%s)\n' "$file" "$pkg" "${owner:+ | propietario: $owner}"
    done <<<"$conflicts"
    echo "   Sugerencia: actualiza primero el propietario con 'sudo pacman -Syu <propietario>'"
    echo "   o reintenta con '$helper -Syu --overwrite <fichero>'."
  fi
  grep -aE '^(error|warning|aviso)' "$log" | tail -n 5 | sed 's/^/   /'
  print_error_hints "$log"
  echo "   Log completo: $log"
  return 1
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
    # El snapshot va ANTES de tocar la red: `run_official_upgrade` ejecuta
    # `pacman -Syu`, que sincroniza y actualiza en una sola transacción. Un
    # `pacman -Sy` suelto antes del snapshot dejaría el restaurado en partial
    # upgrade, y era redundante con el -Syu.
    maybe_create_snapshot
    if run_official_upgrade; then actualizado=1; fi
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
      if run_aur_upgrade "$helper"; then actualizado=1; fi
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
    # La instalación de sistema (/var/lib/flatpak) exige root. Con `sudo -n`
    # NUNCA se queda pidiendo contraseña: si el allowlist NOPASSWD
    # (/etc/sudoers.d/99-cizen-build) cubre flatpak, actualiza en silencio; si
    # no, cae a polkit (flatpak como usuario) avisando de cómo evitarlo.
    if sudo -n flatpak --version >/dev/null 2>&1; then
      if sudo -n flatpak update; then actualizado=1; fi
    else
      echo "⚠ flatpak no está en el allowlist NOPASSWD; se usará autenticación polkit."
      echo "  Añade /usr/bin/flatpak a /etc/sudoers.d/99-cizen-build para no preguntar"
      echo "  (plantilla: arch-update-checker/99-cizen-build.sudoers del repo)."
      if flatpak update; then actualizado=1; fi
    fi
    # Flatpak de usuario (~/.local/share/flatpak): corre como usuario, sin
    # sudo. `-y` es obligatorio porque la salida va a un tubo no interactivo:
    # sin él, si hay que resolver dependencias o confirmar, se quedaría
    # esperando entrada en un canal cerrado (o abortaría en silencio).
    if [[ -d "$HOME/.local/share/flatpak" ]]; then
      fp_user_out=""
      if fp_user_out="$(flatpak update -y --user 2>&1)"; then
        printf '%s\n' "$fp_user_out"
        grep -qiE 'nothing to do|no hay nada que hacer' <<<"$fp_user_out" || actualizado=1
      else
        printf '%s\n' "$fp_user_out"
        echo "⚠ 'flatpak update --user' terminó con errores (revisa la salida)."
      fi
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
    # `sudo -E` preserva DIFFPROG/DIFFARCH y demás variables del usuario;
    # `sudo pacdiff` perdía el difuminador configurado.
    [[ "$p" =~ ^[Nn] ]] || sudo -E pacdiff
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
    # readarray en vez de `orphan_list=( $orphans )`: el splitting sin comillas
    # (SC2206) rompería con nombres con caracteres especiales y metía globs.
    readarray -t orphan_list <<<"$orphans"
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
    [[ -n "$sys_active" ]] && printf '   • [sistema] %s\n' "$sys_active"
    [[ -n "$usr_active" ]] && printf '   • [usuario] %s\n' $usr_active
    read -r -p "¿Reiniciarlos ahora? [S/n] " rs
    if [[ ! "$rs" =~ ^[Nn] ]]; then
      # if/else explícito (no `A && B || C`, SC2015): con el encadenamiento, un
      # fallo de `echo` por pipe roto hacía entrar en la rama de error aunque
      # `systemctl restart` hubiera tenido éxito.
      err=0
      for u in $sys_active; do
        if sudo systemctl restart "$u"; then
          echo "   ✔ $u reiniciado"
        else
          err=1
          echo "   ✗ fallo al reiniciar $u (systemctl status $u)"
        fi
      done
      for u in $usr_active; do
        if systemctl --user restart "$u"; then
          echo "   ✔ $u reiniciado (usuario)"
        else
          err=1
          echo "   ✗ fallo al reiniciar $u (usuario)"
        fi
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
  # Coincidencia por PATRÓN, no por lista fija de nombres: la lista anterior
  # (linux, linux-lts, …) ignoraba el kernel personalizado linux-cizen-v3 y
  # cualquier módulo DKMS (nvidia-open-dkms y cía.), que pasaban sin avisar.
  # Cubre kernels estándar y propios, microcódigo, DKMS y los componentes que
  # solo se aplican en el arranque.
  reboot_hits=""
  cizen_kernel_updated=""
  for p in $updated_pkgs; do
    case "$p" in
      linux*|*-ucode|systemd|systemd-boot|glibc|mesa*|nvidia*|*-dkms)
        reboot_hits+="$p "
        case "$p" in linux*cizen*) cizen_kernel_updated="$p" ;; esac
        ;;
    esac
  done
  if [[ -n "$reboot_hits" ]]; then
    echo
    echo "⚠ Se actualizaron paquetes críticos: $reboot_hits"
    [[ -n "$cizen_kernel_updated" ]] &&
      echo "  (incluye tu kernel Cizen $cizen_kernel_updated: el UKI del arranque debe reflejarlo)"
    echo "  Se RECOMIENDA REINICIAR el sistema para aplicar los cambios."
    read -r -p "¿Reiniciar ahora? [s/N] " rb
    [[ "$rb" =~ ^[Ss] ]] && sudo systemctl reboot
  fi

  ### 5) UKI del arranque (suite Cizen) ###
  # La UKI que arranca el equipo embebe el microcódigo, la cmdline y el initrd.
  # Si cambian systemd, systemd-boot, linux-firmware, el microcódigo, el paquete
  # base o el propio kernel Cizen, hay que regenerarla (y firmarla) para que el
  # arranque no siga usando la imagen anterior.
  uki_hits=""
  for p in $updated_pkgs; do
    case "$p" in
      systemd|systemd-boot|linux-firmware|*-ucode|base|linux*cizen*) uki_hits+="$p " ;;
    esac
  done
  if [[ -n "$uki_hits" ]]; then
    echo
    echo "⚙ Paquetes que afectan al arranque/UKI: $uki_hits"
    if [[ -x "$UKI_SYNC_BIN" ]]; then
      read -r -p "¿Regenerar la UKI con cizen-uki-sync? [S/n] " uk
      if [[ ! "$uk" =~ ^[Nn] ]]; then
        if "$UKI_SYNC_BIN"; then
          echo "✔ UKI sincronizada."
        else
          echo "⚠ cizen-uki-sync terminó con errores (revisa la salida)."
        fi
      fi
    else
      echo "  (no se encuentra $UKI_SYNC_BIN; regenera la UKI a mano con el menú de kernel-update)"
    fi
  fi
else
  echo "· No se registraron paquetes actualizados en esta sesión."
fi

### 6) Kernel Cizen: ¿hay release de kernel.org pendiente de compilar? ###
# Consolida ambas suites: tras el mantenimiento se comprueba si el notificador
# de kernel.org ve una release más nueva que la instalada. `--check` imprime una
# línea y devuelve 10 si hay release pendiente; el timeout evita que el
# asistente se quede colgado si kernel.org no responde.
if [[ -x "$KERNEL_NOTIFY_BIN" ]]; then
  krc=0
  kout="$(timeout 25 "$KERNEL_NOTIFY_BIN" --check 2>/dev/null)" || krc=$?
  if (( krc == 10 )); then
    echo
    echo "⚙ Kernel: hay una release de kernel.org pendiente de compilar ($kout)."
    echo "  Menú de compilación: /usr/local/bin/kernel-update/kernel-update-menu.sh"
  fi
fi

### REFRESCO (background, no bloqueante) ###
echo
if (( actualizado == 1 )); then
  # El refresco se lanza vía systemd, no con `setsid nohup sudo …`:
  #  - ese proceso moría sin TTY si las credenciales de sudo habían caducado
  #    (>15 min, habitual con builds del AUR), y
  #  - la redirección a /dev/null ocultaba el fallo, dejando el fichero
  #    `pending` (y la notificación de escritorio) con datos obsoletos.
  # `--no-block` devuelve el control al instante; el chequeo completo que hace
  # el servicio además vuelve a mirar AUR y Flatpak, que este asistente pudo
  # omitir. Si el arranque falla, se avisa (nada silencioso) y el timer de 6 h
  # sigue siendo la red de seguridad.
  if command -v systemctl >/dev/null 2>&1 &&
     sudo -n systemctl start --no-block "$CHECKER_SERVICE" 2>/dev/null; then
    echo "✔ Refresco lanzado en segundo plano (systemd $CHECKER_SERVICE)."
  else
    echo "⚠ No pude lanzar el refresco en segundo plano sin contraseña."
    echo "  El timer de 6 h lo hará igualmente; para refrescar ahora:"
    echo "      sudo systemctl start $CHECKER_SERVICE"
  fi
else
  echo "No se aplicaron cambios; el estado se refrescará solo cada 6 h."
fi

pause_final