# Frag: Firmware DMC para i915 (Intel HD 630 Kaby Lake)
# El kernel arranca sin initramfs (UKI directa) y CONFIG_DRM_I915=y es obligatorio,
# así que el firmware DMC debe incluirse DIRECTAMENTE en el kernel usando
# CONFIG_EXTRA_FIRMWARE. Esto soluciona los warnings:
#   i915/kbl_dmc_ver1_04.bin failed with error -2
# y habilita el Runtime Power Management (RC6/C-states) de la GPU integrada.
#
# v5.16.1: se retira CONFIG_EXTRA_FIRMWARE_FILE. Ese símbolo NO existe en
# Kconfig (verificado sobre linux-7.2.8: EXTRA_FIRMWARE_FILE no aparece en
# ningún Kconfig*), así que scripts/config lo escribía y la pasada de
# olddefconfig lo eliminaba: era una línea muerta que además producía una
# advertencia de "símbolo no solicitado" en cada build. La inclusín del blob
# la hace CONFIG_EXTRA_FIRMWARE, que sí es un símbolo real.
CONFIG_EXTRA_FIRMWARE="i915/kbl_dmc_ver1_04.bin"
