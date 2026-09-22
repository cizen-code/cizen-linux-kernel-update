#!/usr/bin/env bash
# ============================================================
# podar-modulos.sh — Poda de módulos del kernel Cizen v1.1.0
#
# Elimina de un árbol de módulos (lib/modules/<release>) los módulos que este
# hardware no necesita, conservando únicamente:
#   1. Los módulos CARGADOS AHORA en el host (lsmod -> /proc/modules):
#      refleja el uso real (audio, red, GPU, KVM, almacenamiento, ...).
#   2. Los módulos cuyo modalias coincide con el HARDWARE PRESENTE
#      (se resuelven contra modules.alias del propio árbol objetivo).
#   3. Una allowlist explícita del perfil Cizen (infra VM, Dell, FS, input,
#      network, thermal, crypto) + CIZEN_KEEP_MODULES (2º argumento o env).
#   4. /etc/modules-load.d (módulos que el arranque pide por nombre).
#   Después cierra transitivamente las dependencias (modules.dep) de lo
#   conservado y regenera los índices con depmod. Los módulos =y (built-in)
#   no tienen archivo .ko: la poda nunca los afecta - el arranque sin UKI
#   initramfs depende de ellos y el perfil los fija como boot_critical.
#
# v1.1.0 (2026-09-22): si el árbol no tiene aún modules.dep/modules.alias
# (p.ej. dentro de package() del PKGBUILD, justo tras modules_install y antes
# del depmod de la receta), se generan aquí con depmod antes de podar — antes
# el guard abortaba y `|| true` conservaba el conjunto compilado completo
# (la poda física era inefectiva). Allowlist recortada (CORE_KEEP): fuera
# térmica Intel no cargada (processor_thermal_*, int340x_thermal_zone,
# acpi_thermal_rel), md_mod + lz4hc_compress (sin RAID ni uso), btmtk/rfcomm
# (solo BT CSR presente usa btusb) e i2c_hid/i2c_mux (sin HID I2C en este
# desktop y el I2C bus sigue con i2c_i801/smbus/dev/algo_bit).
#
# Uso:
#   podar-modulos.sh <lib/modules/<release>> [keep-extra,separado,por,comas]
#   CIZEN_KEEP_MODULES="kvm_intel,vfio_pci" podar-modulos.sh <moddir>
#   podar-modulos.sh --keep-list [keep-extra,...]   # imprime el allowlist estático
#       (CORE_KEEP + /etc/modules-load.d + extras) un nombre por línea, para
#       generar el conjunto de módulos que --lite (localmodconfig) debe compilar.
#       No necesita un árbol de módulos (devuelve 0).
#
# Fallos de seguridad: si depmod no está o el directorio no parece un árbol de
# módulos, NO toca nada y devuelve 1 (el PKGBUILD conserva el conjunto completo).
# Si la ruta o el árbol no existen, devuelve 2 (error de uso).
# ============================================================
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

KEEP_LIST_ONLY=false
if [ "${1:-}" = "--keep-list" ]; then
  KEEP_LIST_ONLY=true
  shift
fi

if [ "$KEEP_LIST_ONLY" = false ]; then
  MODDIR="${1:-}"
  if [ -z "$MODDIR" ] || [ ! -d "$MODDIR" ]; then
    echo "Uso: podar-modulos.sh <lib/modules/<release>> [lista-extra,separada,por,comas]" >&2
    exit 2
  fi
  MODDIR="$(cd -- "$MODDIR" && pwd -P)"
  RELEASE="${MODDIR##*/}"
  ROOT="${MODDIR%/lib/modules/*}"
  if [ "$ROOT" = "$MODDIR" ]; then
    echo "La ruta no parece ser <root>/lib/modules/<release>: $MODDIR" >&2
    exit 2
  fi

  # depmod es imprescindible para regenerar modules.dep/alias/symbols tras la
  # poda. Sin él no se toca nada (el conjunto completo es más seguro).
  if ! command -v depmod >/dev/null 2>&1; then
    echo "AVISO: depmod no está disponible; se omite la poda y se conserva el conjunto completo." >&2
    exit 1
  fi
  # v1.1.0: si el árbol aún no tiene índices (package() tras modules_install,
  # antes del depmod de la receta), generarlos aquí; la poda los refresca en el
  # paso final de todas formas.
  if [ ! -f "$MODDIR/modules.dep" ] || [ ! -f "$MODDIR/modules.alias" ]; then
    if depmod -b "$ROOT" "$RELEASE" >/dev/null 2>&1; then
      echo "Índices generados por depmod para $RELEASE (no existían)." >&2
    else
      echo "AVISO: depmod falló al generar los índices de $RELEASE; se omite la poda." >&2
      exit 1
    fi
  fi
  if [ ! -f "$MODDIR/modules.dep" ] || [ ! -f "$MODDIR/modules.alias" ]; then
    echo "AVISO: $MODDIR no contiene modules.dep/modules.alias; se omite la poda." >&2
    exit 1
  fi
fi

declare -A KEEP=()
keep_mod() { [ -n "$1" ] && KEEP["$1"]=1; }

# ------------------------------------------------------------
# 0) Inventario del árbol objetivo (nombres de módulo -> fichero .ko*)
#    (se omite en modo --keep-list: no hay árbol que inventariar)
# ------------------------------------------------------------
if [ "$KEEP_LIST_ONLY" = false ]; then
declare -A FILE_BY_NAME=()
declare -a ALL_FILES=()
shopt -s nullglob
while IFS= read -r _f; do
  [ -f "$_f" ] || continue
  ALL_FILES+=("$_f")
  _b="$(basename -- "$_f")"
  _n="${_b%.ko*}"
  if [ -n "$_n" ]; then
    FILE_BY_NAME["$_n"]="$_f"
  fi
done < <(find "$MODDIR" -type f \( -name '*.ko' -o -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) 2>/dev/null)
shopt -u nullglob

if [ "${#ALL_FILES[@]}" -eq 0 ]; then
  echo "AVISO: no hay módulos .ko en $MODDIR; se omite la poda." >&2
  exit 1
fi
fi

# ------------------------------------------------------------
# 1) Módulos cargados ahora mismo (uso real del host)
# ------------------------------------------------------------
if [ -r /proc/modules ]; then
  while IFS=' ' read -r _m _rest; do
    keep_mod "$_m"
  done < /proc/modules
fi

# /etc/modules-load.d (módulos que el arranque pide por nombre)
if [ -d /etc/modules-load.d ]; then
  while IFS= read -r _ml; do
    case "$_ml" in
      ''|\#*) continue ;;
      *) keep_mod "$_ml" ;;
    esac
  done < <(sed -E 's/[#].*$//' /etc/modules-load.d/* 2>/dev/null || true)
fi

# ------------------------------------------------------------
# 2) Hardware presente -> modalias -> modules.alias del árbol objetivo
#    (se omite en modo --keep-list: requiere el árbol objetivo)
# ------------------------------------------------------------
if [ "$KEEP_LIST_ONLY" = false ]; then
declare -a HW_ALIASES=()
while IFS= read -r _ma; do
  [ -n "$_ma" ] && HW_ALIASES+=("$_ma")
done < <(find /sys/devices /sys/class /sys/bus -name modalias -type f -exec cat {} + 2>/dev/null | sort -u)

if [ -f "$MODDIR/modules.alias" ] && [ "${#HW_ALIASES[@]}" -gt 0 ]; then
  while IFS= read -r _al || [ -n "$_al" ]; do
    case "$_al" in
      alias\ *)
        _rest="${_al#alias }"
        _mod="${_rest##* }"
        _pat="${_rest% *}"
        if [ -n "$_mod" ] && [ -n "$_pat" ]; then
          for _ma in "${HW_ALIASES[@]}"; do
            if [[ "$_ma" == $_pat ]]; then
              keep_mod "$_mod"
            fi
          done
        fi
        ;;
    esac
  done < "$MODDIR/modules.alias"
fi
fi

# ------------------------------------------------------------
# 3) Allowlist explícita del perfil Cizen (infra prevista aunque no cargada
#    en el instante del build: VMs, FS de respaldo, Dell, input/gaming...).
#    Los nombres que el kernel nuevo lleve como =y se ignoran (no hay .ko).
# ------------------------------------------------------------
CORE_KEEP=(
  # Red / túneles / bridges de libvirt
  e1000e bridge br_netfilter tun veth vhost_net vhost macvtap
  # GPU i915 + helpers DRM (aunque i915 es =y en el perfil)
  i915 drm_display_helper drm_kms_helper drm_buddy ttm intel_gtt video
  # Audio HDA + SoC (el perfil fija ALC269 y HDMI_INTEL)
  snd_hda_intel snd_hda_codec snd_hda_core snd_hda_codec_generic
  snd_hda_codec_realtek snd_hda_codec_realtek_lib snd_hda_codec_alc269
  snd_hda_codec_hdmi snd_hda_codec_intelhdmi snd_hda_scodec_component
  snd_hda_ext_core snd_intel_dspcfg snd_soc_core snd_soc_hda_codec
  snd_pcm snd_pcm_dmaengine snd_timer snd_hrtimer snd_seq snd_seq_device
  snd_hwdep snd_compress snd_ctl_led soundcore snd
  # USB / almacenamiento (Ventoy, HID, BT)
  xhci_pci xhci_hcd usbcore usb_common usb_storage uas usbhid hid hid_generic
  ehci_hcd ehci_pci ohci_hcd ohci_pci uhci_hcd
  bluetooth btusb btbcm btrtl btintel bnep rfkill
  # FS y bloques (btrfs es =y; los de USB/Particiones como módulo)
  btrfs isofs exfat vfat fat xfs zram zsmalloc loop
  # Integridad / crypto usados por los FS y el arranque
  crc32c_intel zstd_compress lz4_compress
  ghash_clmulni_intel aesni_intel polyval_clmulni polyval_generic
  # Virtualización KVM/QEMU (aunque KVM_SMM es =y, kvm/kvm_intel van como m)
  kvm kvm_intel irqbypass vfio vfio_iommu_type1 vfio_pci
  virtio virtio_pci virtio_balloon virtio_blk virtio_net virtio_console
  # Plataforma Dell / WMI
  dell_wmi dell_smbios dell_wmi_aio dell_wmi_descriptor dell_smm_hwmon
  dcdbas wmi wmi_bmof
  # Térmica / power / RAPL (se conservan las cargadas: RAPL, coretemp,
  # x86_pkg_temp_thermal; fuera la térmica int340x/processor_thermal no usada)
  intel_rapl_msr intel_rapl_common intel_rapl_uncore rapl
  intel_hid intel_vbtn x86_pkg_temp_thermal intel_tcc_cooling coretemp
  iTCO_wdt iTCO_vendor_support intel_pmc_core intel_pmc_bxt intel_vsec
  intel_uncore intel_cstate intel_oc_wdt intel_lpss_pci intel_lpss idma64
  acpi_pad
  # I2C / otros buses que lsmod pueda perder entre reinicios
  i2c_i801 i2c_smbus i2c_dev i2c_algo_bit
  # Input / gaming (perfil)
  joydev xpad hid_sony hid_playstation hid_nintendo hid_steam uhid hidp
  mac_hid mousedev pcspkr sparse_keymap
  # QoS de red del perfil (FQ)
  sch_fq sch_fq_codel tcp_bbr tcp_cubic
  # netfilter nftables (firewall del host + br_netfilter de VMs)
  nf_tables nfnetlink nf_conntrack nf_ct_proto_sctp nf_defrag_ipv4 nf_defrag_ipv6
  nft_ct nft_chain_route nft_chain_nat nft_compat nft_counter
  # Diagnóstico systemd
  tcp_diag udp_diag inet_diag ntsync
)
for _m in "${CORE_KEEP[@]}"; do keep_mod "$_m"; done

# ------------------------------------------------------------
# 3b) Extras del usuario: 2º argumento (o 1º en --keep-list) y/o CIZEN_KEEP_MODULES
# ------------------------------------------------------------
_EXTRA=""
if [ "$KEEP_LIST_ONLY" = true ]; then
  _EXTRA="${1:-}"
else
  _EXTRA="${2:-}"
fi
[ -n "${CIZEN_KEEP_MODULES:-}" ] && _EXTRA="${_EXTRA:+${_EXTRA},}${CIZEN_KEEP_MODULES}"
if [ -n "$_EXTRA" ]; then
  IFS=',' read -r -a _xextra <<< "$_EXTRA"
  for _x in "${_xextra[@]:-}"; do
    _x="$(printf '%s' "$_x" | tr -d '[:space:]')"
    [ -n "$_x" ] && keep_mod "$_x"
  done
  unset _x
fi

if [ "$KEEP_LIST_ONLY" = true ]; then
  # Un nombre por línea (todo lo que la poda conservaría sin depender de un
  # módulo cargado ni de un árbol objetivo): allowlist + modules-load.d + extras.
  for _k_ in "${!KEEP[@]}"; do
    printf '%s\n' "$_k_"
  done
  exit 0
fi

# ------------------------------------------------------------
# 4) Cierre transitivo de dependencias (modules.dep del árbol objetivo)
# ------------------------------------------------------------
declare -A DEPS=()
while IFS= read -r _l || [ -n "$_l" ]; do
  [ -n "$_l" ] || continue
  _f="${_l%%:*}"
  _rest="${_l#*: }"
  [ "$_rest" = "$_l" ] && _rest=""
  _n="${_f##*/}"; _n="${_n%.ko*}"
  [ -n "$_n" ] || continue
  _rl=""
  for _d in $_rest; do
    _dn="${_d##*/}"; _dn="${_dn%.ko*}"
    [ -n "$_dn" ] && _rl="$_rl $_dn"
  done
  DEPS["$_n"]="${_rl# }"
done < "$MODDIR/modules.dep"

declare -A DONE=()
declare -a STACK=()
_k=0
for _k in "${!KEEP[@]}"; do
  STACK+=("$_k")
done
while [ "${#STACK[@]}" -gt 0 ]; do
  _cur="${STACK[0]}"
  STACK=("${STACK[@]:1}")
  [ -n "${DONE[$_cur]:-}" ] && continue
  DONE["$_cur"]=1
  [ -z "${FILE_BY_NAME[$_cur]:-}" ] && continue
  KEEP["$_cur"]=1
  for _d in ${DEPS[$_cur]:-}; do
    if [ -z "${DONE[$_d]:-}" ] && [ -n "${FILE_BY_NAME[$_d]:-}" ]; then
      STACK+=("$_d")
    fi
  done
done
unset _k _cur

# ------------------------------------------------------------
# 5) Poda física
# ------------------------------------------------------------
_kept=0
_pruned=0
for _f in "${ALL_FILES[@]}"; do
  _b="$(basename -- "$_f")"
  _n="${_b%.ko*}"
  if [ -n "${KEEP[$_n]:-}" ]; then
    _kept=$((_kept + 1))
  else
    rm -f -- "$_f"
    _pruned=$((_pruned + 1))
  fi
done

# Directorios que quedaron vacíos (de abajo hacia arriba; se conserva kernel/).
find "$MODDIR/kernel" -mindepth 1 -type d -empty -delete 2>/dev/null || true

# ------------------------------------------------------------
# 6) Regenerar los índices (depmod) para reflejar el árbol podado
# ------------------------------------------------------------
if depmod -b "$ROOT" "$RELEASE" >/dev/null 2>&1; then
  echo "Poda Cizen ($RELEASE): ${_pruned} módulos retirados, ${_kept} conservados; índices depmod regenerados."
  exit 0
else
  echo "AVISO: depmod falló al regenerar los índices de $RELEASE; se conservan los módulos retirados fuera de los índices (revisa el sistema)." >&2
  exit 1
fi