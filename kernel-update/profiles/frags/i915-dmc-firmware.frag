# Frag: Firmware DMC para i915 (Intel HD 630 Kaby Lake)
# El kernel arranca sin initramfs (UKI directa) y CONFIG_DRM_I915=y es obligatorio,
# así que el firmware DMC debe incluirse DIRECTAMENTE en el kernel usando
# CONFIG_EXTRA_FIRMWARE. Esto soluciona los warnings:
#   i915/kbl_dmc_ver1_04.bin failed with error -2
# y habilita el Runtime Power Management (RC6/C-states) de la GPU integrada.
CONFIG_EXTRA_FIRMWARE="i915/kbl_dmc_ver1_04.bin"
CONFIG_EXTRA_FIRMWARE_FILE="i915/kbl_dmc_ver1_04.bin"
