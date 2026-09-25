## [27.31.2] - 2026-09-24

El compilador de compilación es ahora **de tu preferencia**: puedes elegir una
versión concreta o un binario/ruta propio, no solo la familia genérica gcc/clang.

- `--cc` / `CIZEN_CC` acepta `auto | gcc | clang` (como siempre), versiones de
  Arch (`gcc-14`, `gcc14`, `clang-17`, `clang17`) o una ruta/binario propio
  (`/opt/.../clang-custom`, `afl-gcc-fast`; la familia se infiere del basename).
- Nueva `_resolve_cc_compiler()`: deduce la familia (gcc|clang) y el binario
  efectivo `CC_LAUNCHER` que se usa de verdad en make. La elección explícita
  (`--cc gcc` / `--cc gcc-14`) gana sobre la bandera `--clang` previa: se
  compila con lo que pediste.
- Kbuild: familia clang → `LLVM=1`; con ccache → `CC=ccache $CC_LAUNCHER` /
  `HOSTCC=...`; binario concreto sin ccache → `CC=$CC_LAUNCHER`. Eliminado el
  hardcode `CC=ccache gcc`.
- Dependencia obligatoria igual que el resto: si el compilador elegido no está,
  `check_prerequisites` lo exige y ofrece instalarlo — package Arch homónimo
  para versionados (`gcc-14` → `gcc14`, `clang-17` → `clang17`), fatal con
  ruta/instalación manual si es un binario personal. Familia clang exige
  `ld.lld`; genérico clang exige también `clang`.
- LTO saneness por familia: con GCC elegido (+LTO) se ignora el LTO (aviso);
  con `auto` + LTO se selecciona clang y se exige la toolchain.
- Menú (opción 14): añadida la entrada para teclear tu compilador (auto/gcc/
  clang u otro: versión o ruta); lo que escribas se pasa a `--cc`.
- Selftest 86→100 checks (tabla de `_resolve_cc_compiler`, prereqs por familia,
  emisión de make); `bash -n`; repo==instalado.

## [27.31.1] - 2026-09-24

clang y lld pasan a ser dependencias **obligatorias** (con el mismo flujo de
instalación que el resto) cuando el usuario elige la toolchain LLVM, en vez de
degradar a GCC en silencio.

- Elegir `--clang`, `--cc clang` o `--llvm-lto thin|full` (que solo se compila
  con clang/lld) y no tener clang/ld.lld instalados ya **no degrada a gcc**:
  `check_prerequisites` incluye `clang` y `ld.lld` (paquete `lld`) entre las
  dependencias requeridas, se ofrecen con `sudo pacman -S --needed clang lld`
  (mismo prompt Sí/No que las demás) y, si se rechazan o la instalación falla,
  se aborta con el comando sugerido.
- El LTO ya no se ignora por faltar la toolchain: se retiene la petición y se
  exigen las dependencias antes de la fase de configuración.
- Comportamiento intacto para `auto` (usa clang solo si ya está presente) y
  `gcc`.
- Selftest 81→86 checks (regresión sobre el flujo de exigencia); `bash -n`;
  repo==instalado (motor `69da0789`, selftest `b17f62bf`).

## [27.30.1] - 2026-09-24

Correcciones de robustez detectadas al probar la opción 16 del menú (pack misc
CachyOS) sobre el propio release v27.30.0, más saneamiento del pack.

- **Guarda Secure Boot corregida** (`secure_boot_guided_setup`): el test final
  `[ "$pending" = true ]` estaba invertido y abortaba la cadena con `errexit`
  aun con todos los pasos resueltos. Ahora `pending=false` al resolver claves,
  enroll y firma del gestor, y el cierre verifica `pending` en falso.
- **Splitting de `CIZEN_CACHY_PATCH_SET`**: con el `IFS` global (`\n`, tab)
  del motor, el set default no se separaba y la opción 16 intentaba un solo
  nombre («entrada desconocida»). Se lee con `read -a` bajo `IFS=' '`.
- **Orden de definición de `luks_fde_audit`**: se llamaba antes de su
  definición (error 127); se movió la llamada justo antes de `cizen-uki-sync`.
- **Pack misc CachyOS saneado**: los governors `nap-governor`/`reflex-governor`
  fueron **retirados** del stack CachyOS (ausentes en `CachyOS/kernel-patches`
  de todas las ramas y en los PKGBUILD de `linux-cachyos`); el default ahora es
  `acpi-call` (verificado que aplica limpio sobre el árbol vanilla 7.2) y la
  lista de válidas es `acpi-call aufs dkms-clang handheld hardened nvidia rt-i915`.
- **Auto-enable de símbolos del pack**: al aplicar un parche misc se extraen los
  símbolos Kconfig que introduce y se re-habilitan tras perfil+frags y antes de
  la auditoría (`apply_cachy_misc_symbols`), de modo que p. ej.
  `CONFIG_ACPI_CALL=m` sobrevive a la config lite y el módulo se compila.
  Sustituye a la nota anterior de «la opción 16 solo aplica fuentes».
- **Selftest**: 50 → 66 checks (guardas SB, splitting, orden de definición,
  extracción/tipado de símbolos, auto-enable y recolección end-to-end).

## [27.31.0] - 2026-09-24

Soporte del **árbol de fuentes del fork CachyOS/linux** para que los schedulers
PRJC y MuQSS apliquen de verdad. Los parches `-cachy` de `CachyOS/kernel-patches`
(pds/bmq/lfbmq/muqss) solo aplican sobre el árbol del fork, no sobre la release
vanilla de kernel.org: los archivos vanilla (`0001-prjc.patch`) dejaron de
publicarse para ramas recientes, y sobre vanilla 7.2 el forward-port no encajaba
(contexto Kconfig distinto) y el build caía a vanilla silenciosamente.

- **`CIZEN_KERNEL_TREE` / `--tree auto|vanilla|cachyos`**: decisión del árbol de
  fuentes tras resolver la versión. En `auto` (defecto) los schedulers
  `pds`/`bmq`/`lfbmq`/`muqss` fuerzan el árbol `cachyos`; `bore` y el resto de
  parches siguen sobre `vanilla`. `resolve_kernel_tree` decide antes de fijar
  TARBALL/SRC/URL.
- **`resolve_cachyos_release`**: calcula el tagrel del release del fork
  (`cachyos-<VERSION>-N`, p. ej. `cachyos-7.2.7-1`) consultando la API de
  releases de `CachyOS/linux` (mayor tagrel de la versión) con fallback por
  sondeo directo de los `.asc` (`cachyos-$V-1..8`, sin depender de rate limits
  ni paginación). Validado en vivo contra el API real.
- **Descarga y verificación por árbol**: el fork usa `.tar.gz` + `.asc` (firma
  del tarball directo), verificación PGP `gpg --verify sig file` y `gzip -t`;
  kernel.org sigue con `.tar.xz` + `.tar.sign` (`xz -cd | gpg`, `xz -t`).
- **Firmantes CachyOS atados por huella** (`CACHYOS_TRUSTED_SIGNERS`):
  `dnaim@cachyos.org` (`E18447AC…B8B63C4`) y `admin@ptr1337.dev`
  (`E8B9AA39…7F654FE`), obtenidos por WKD y keyserver (openpgp.org →
  keys.cachyos.org). Verificado end-to-end con el tarball real `cachyos-7.2.7-1`
  (firma de Peter Jung).
- **Extracción**: el tarball del fork extrae `cachyos-X.Y.Z-N`; se reubica a
  `$SRC` (`linux-$VERSION`) y el chequeo `kernelversion` tolera el sufijo
  `-cachyos`.
- **`cleanup_kernel_cache` y traps** parametrizados por árbol (conservan SOLO el
  tarball/firma de la versión objetivo de cualquiera de los dos árboles).
- **Guardia fail-soft**: un descriptor con `PATCH_TREE_REQUIRED=cachyos` que se
  pide sobre un build `--tree vanilla` se omite con WARN (sin descargar, sin
  registrar), nunca rompe.
- **Selftest**: 68 → 81 checks (selección de árbol, parseo del JSON de releases,
  sondeo directo de `.asc` y guardia de árbol).

# Changelog

Historial de versiones de la suite `cizen-linux-kernel-update`. El
changelog vive en este archivo (no en la cabecera del motor);
`kernel-update.sh --changelog` añade aquí el borrador del siguiente
release. Formato inspirado en [Keep a Changelog](https://keepachangelog.com/es/1.1.0/).

## [27.30.0] - 2026-09-24

funciones nuevas de los proyectos referentes (linux-tkg, CachyOS, Arch-SKM,
ukibak, LinuxLocker): schedulers alternativos, Clang/LLVM+LTO, modprobed-db,
frags, parches de usuario/CachyOS, NTSync/fsync, empaquetado multi-backend,
gestor multi-kernel, firma persistente de módulos y UKI backup

- **Perfil de compilación extendido**: bloque de opciones
  `--cc (gcc|clang|auto)`, `--lto-thin/--lto-full/--no-lto`, `--o3/--o2`,
  `--native/--march=<env>`, `--timer-freq`, `--sched (eevdf|bore|pds|bmq|
  lfbmq|muqss)`, `--ntsync/--no-ntsync`, `--fsync/--no-fsync`,
  `--cachy/--no-cachy`, `--frag-dir`, `--modprobed-db/--no-modprobed-db`,
  `--pkg-backend (arch|deb|rpm|generic|gentoo)`,
  `--module-sign/--no-module-sign`, `--uki-backup/--no-uki-backup`,
  `--luks-audit`; todas con variable `CIZEN_*` equivalente y validación de
  entorno.
- **Schedulers alternativos**: soporte de PDS, BMQ, LFBMQ y MuQSS (parches
  PRJC/CachyOS con fallback upstream), nuevas entradas en el menú interactivo
  de `choose_build_variant_after_check` y descriptor por scheduler con
  `PATCH_CHOICE_DISABLE` (choice Kconfig) y `PATCH_DISABLE_ALL`.
- **Wine sync**: NTSync nativo (≥6.10, `CONFIG_NTSYNC` forzado) o backport
  CachyOS (<6.10); fsync legacy (futex_waitv) solo <6.14.
- **Clang/LLVM + LTO**: `CC=clang`, `LLVM=1`, `LD=lld` (requiere clang+lld);
  LTO thin/full con `LTO_NONE`/`CLANG_THIN`/`CLANG_FULL` y validación temprana.
- **-O3 / CONFIG_HZ / -march / timer**: overlay de compilación
  (`inject_build_overlay`) aplicado en ambas cadenas de config; `-mtune`
  heredado del perfil.
- **modprobed-db**: feed automático de `prepare_lite_config` desde
  `~/.local/share/modprobed-db/modprobed.db` o `~/.config/modprobed.db`.
- **Frags de configuración**: mini-perfiles `.frag` en `CIZEN_FRAGS_DIR`
  (con `#include`), aplicados tras el overlay, con directivas
  enable/module/disable/set-val/set-str.
- **Parches de usuario + misc CachyOS**: `apply_user_patches` (fatal si un
  `.patch/.diff` de `CIZEN_USER_PATCHES_DIR` falla) y
  `apply_cachy_misc_patchset` (fail-soft; default `acpi-call`, set válido:
  acpi-call aufs dkms-clang handheld hardened nvidia rt-i915). Los símbolos
  Kconfig que introducen los parches misc se auto-habilitan en la config
  (`apply_cachy_misc_symbols`, tras perfil+frags y antes de la auditoría), de
  modo que `CONFIG_ACPI_CALL=m` sobrevive a la config lite y el módulo se
  compila.
- **Empaquetado multi-backend**: `--pkg-backend` con `arch/pacman-pkg`,
  `deb/deb-pkg`(+dpkg), `rpm/rpm-pkg`(+rpm), `generic|gentoo`/targz-pkg con
  `modules_install`+vmlinuz directo; pkgrel y guards pacman solo en arch.
- **`kernel-update-manager.sh`**: list/info/flip/backup/remove + guía SCX;
  integrado en el menú (opción 17).
- **Firma persistente de módulos (MOK)**: claves kernel-signing en
  `CIZEN_MODULE_SIGN_DIR` e `sign-file` sobre los `.ko` instalados
  (`--module-sign`).
- **UKI backup**: respaldo del UKI previo a sobrescribirlo en
  `CIZEN_UKI_BACKUP_DIR` con poda del más antiguo (`--uki-backup`).
- **Auditoría LUKS/FDE**: `--luks-audit` avisa si la raíz cifrada no lleva
  parámetros de desbloqueo en el cmdline antes de regenerar el UKI.
- **Harness ampliado**: tests de `kernel_version_ge`, descriptores de
  schedulers, skip por versión (ntsync/fsync), frags y PATCH_DISABLE_ALL
  (50 checks, 0 fallos).

## [27.29.3] - 2026-09-24

memoria de la decisión de firma + guía de BIOS para los pasos manuales

- **La firma se recuerda entre builds**: en modo `auto`, la última decisión
  explícita (sí/no en el prompt "¿Firmar la UKI?") se guarda en
  `~/.local/state/kernel-update/sign-uki.state` y se reutiliza en los
  siguientes builds: ya no vuelve a preguntar, funciona en compilaciones no
  interactivas (cron/scripts) y no decide en silencio. Secure Boot activo en el
  firmware sigue forzando la firma SIEMPRE; `--sign`/`--no-sign` y
  `CIZEN_SIGN_UKI=yes|no` tienen prioridad sobre lo recordado.
- **Guía de BIOS integrada en el setup guiado**: para los pasos que el script
  no puede automatizar se imprime un paso-a-paso genérico — cómo devolver el
  firmware a **SETUP MODE** cuando está en User Mode con claves de fábrica
  (teclas de acceso, apartados "Secure Boot"/"Security", nombres según
  fabricante: "Reset to Setup Mode"/"Custom"/borrar claves OEM) y cómo
  **habilitar Secure Boot** cuando la matrícula ya está hecha pero SB queda off
  en la BIOS.

## [27.29.2] - 2026-09-24

fix: sbctl sign sin `--save` no registraba las firmas en la BD (sbctl 0.18)

- **Firma registrada en la BD de sbctl**: `sbctl sign` (sbctl ≥0.18) solo
  "pega" la firma y NO la guarda en la base a menos que se pase `-s/--save`.
  Sin `--save` el hook de pacman `zz-sbctl.hook` (`sbctl sign-all -g`) no
  vuelve a firmar systemd-boot/UKI tras las actualizaciones de paquetes, y
  `sbctl verify` deja de reconocer los ficheros. Se añade `--save` en
  `cizen-uki-sync`, en la ruta directa del motor (`sync_cizen_efi`) y se
  documenta el requisito en las cabeceras. (Causa raíz diagnosticada tras
  fallo de arranque con Secure Boot: firmware Dell solo con claves de fábrica
  Microsoft — las claves sbctl estaban generadas pero nunca matriculadas.)

## [27.29.1] - 2026-09-23

setup guiado de Secure Boot al firmar la UKI (create-keys / systemd-boot / enroll)

- **Setup guiado de Secure Boot**: al aceptar la firma de la UKI el motor abre
  un asistente interactivo que revisa el estado real de la cadena y ofrece,
  pregunta a pregunta (S/n), únicamente lo que quede pendiente:
  `sbctl create-keys` (generar las claves de firma), `sbctl sign` sobre
  systemd-boot (fuente del paquete + copias reales del ESP) y
  `sbctl enroll-keys` (matricular las claves en el firmware, obligatorio para
  que la BIOS confíe en ellas). Termina con un resumen del estado
  (claves / enroll / systemd-boot) y recuerda habilitar Secure Boot en la BIOS
  y comprobar con `sbctl status`. Idempotente: solo pregunta lo pendiente.
- **Matrícula real detectada por huella**: la variable UEFI `PK` se lee y se
  compara por huella SHA256 con la PK propia de sbctl; si el firmware está en
  User Mode con claves de fábrica (Dell/Microsoft) no se da la matrícula por
  hecha: se explica que `sbctl enroll-keys` exige Setup Mode y se guía al
  usuario a la BIOS (Dell: Secure Boot → Expert Key Management).
- **Fail-safe ante claves ausentes**: `cizen-uki-sync` detecta si no hay claves
  sbctl generadas (`/var/lib/sbctl/keys`). Con Secure Boot activo aborta (no
  sería posible producir una UKI firmada); con SB desactivado avisa y deja la
  UKI sin firmar sin cancelar la instalación.
- **Verificación post-build**: tras sincronizar la UKI el motor ejecuta
  `sbctl verify` y muestra el resultado (aviso si quedan ficheros sin firmar).

## [27.29.0] - 2026-09-23

firma de la UKI con sbctl (Secure Boot): sugerida al confirmar la compilación

- **Firma de la UKI (Secure Boot)**: `sbctl` pasa a ser **dependencia
  obligatoria** de la suite (`check_prerequisites`: si falta, se ofrece
  autoinstalarlo) y, al solicitar un build/recompilación, se sugiere firmar la
  UKI al confirmar la compilación ("¿Firmar la UKI del kernel con sbctl?
  [S/n]", default S). Con Secure Boot
  activo en el firmware la firma es SIEMPRE obligatoria (una UKI sin firmar no
  arrancaría) y se aplica sin pregunta. Flags `--sign`/`--no-sign` y env
  `CIZEN_SIGN_UKI=yes|no|auto`. `cizen-uki-sync` firma y verifica cada objetivo
  con `sbctl sign`/`sbctl verify` tras escribir la UKI, y aborta con fail-safe
  si el resultado queda sin firmar con Secure Boot activo; el camino directo
  del motor (`sync_cizen_efi`) replica la firma. La decisión queda en
  `last-build` (`sb=yes|no`) y en el resumen final (`Firma UKI`).
- **Verificación post-boot**: `kernel-update-verify.sh` añade el check
  **SECURE BOOT** — cruza la firma del último build (`sb=` en `last-build`) con
  el estado real (bootctl status, salida fija con `LC_ALL=C`) y avisa si la UKI
  se firmó pero Secure Boot está desactivado (la firma no tiene efecto), o si
  Secure Boot está activo con la UKI sin firmar (no arrancaría).

## [27.28.0] - 2026-09-23

resiliencia y diagnóstico: recuperación de arranque, verificación post-boot, anclaje SHA256 y auditoría hardening

- **Boot counting para systemd-boot**: la UKI se escribe con contador de
  intentos (`arch-linux-cizen-v3+3.efi`; `CIZEN_BOOT_TRIES`, 0 = UKI plana).
  Cada boot sin completar `boot-complete.target` resta 1; al agotarse la
  entrada pasa a `bad` y sd-boot arranca un kernel previo en lugar de dejar el
  sistema sin arranque. `systemd-bless-boot.service` (activación automática)
  renombra la UKI a nombre plano al completar el arranque. Se limpian las
  variantes antiguas al escribir, y el tar de rollback recoge tanto la UKI
  plana como las `+N`. El verificador suma el check **GUARD**: avisa si el
  kernel arrancado no es el último Cizen instalado (fallback detectado).
- **Verificación post-boot**: `kernel-update-verify.sh` añade el check
  **FIRMWARE** — por cada módulo cargado, `modinfo -F firmware` se contrasta
  con `/usr/lib/firmware` (acepta binarios `.zst`; `CIZEN_FIRMWARE_DIR`) y se
  escanean los fallos de carga del journal del boot actual
  ("Direct firmware load failed"). La notificación incluye `FW: N`.
- **Anclaje SHA256 de los parches BORE**: los ficheros principal (CachyOS) y
  de respaldo upstream se verifican por SHA256 contra hashes fijos en el
  descriptor del motor antes de aplicarse; si no casan, el parche se descarta
  y el build se degrada a vanilla (nunca se aplica algo no anclado). Overrides:
  `CIZEN_PATCH_SHA256_MAIN` / `CIZEN_PATCH_SHA256_FALLBACK` /
  `CIZEN_PATCH_SHA256_VERIFY=0`.
- **Guarda OOM pre-build**: `check_build_memory()` aborta antes de descargar
  si MemAvailable+SwapFree (o el espacio libre del tmpfs de build) no llegan
  al mínimo, con umbrales distintos para BTF (el enlace es lo más hambriento):
  `CIZEN_BUILD_MIN_MEM_MB=8192`, `CIZEN_BUILD_MIN_TMPFS_MB=6144`,
  `CIZEN_BUILD_MIN_MEM_BTF_MB=12288`, `CIZEN_BUILD_MIN_TMPFS_BTF_MB=8192`.
- **Auditoría `--hardened`**: sin efectos laterales, lee `/proc/config.gz` y
  los knobs sysctl vivos y reporta la postura de endurecimiento (stack,
  fortify, usercopy, freelist slab, REFCOUNT_FULL, VMAP_STACK, RWX estricto,
  KASLR, módulos firmados, sysctl runtime). Menú opción **13**. En el kernel
  7.2.7 resultaron pendientes: `REFCOUNT_FULL` no configurado, `kptr_restrict=0`,
  `unprivileged_bpf_disabled=0` y `suid_dumpable=2`.
- **Cgroups para la compilación**: con `systemd-run --scope` (probe de
  delegación previo; fallback a nice/ionice) la build corre en un scope propio
  con `CPUWeight/IOWeight` según prioridad (normal 100/100, low 30/1). Al
  terminar (éxito o fallo) se envía notificación de escritorio por
  `notify-send` (`CIZEN_NOTIFY=0` desactiva).
- Harness ampliado: pin SHA256 al hash real de los parches sintéticos de
  prueba + caso de rechazo con hash no anclado → selftest 23 ok / 0 fail.

## [27.27.2] - 2026-09-22

poda: nombres canónicos de módulo (corrige el kernel sin sonido HDMI/analógico)

- `podar-modulos.sh` v1.1.1: el inventario, el cierre de dependencias y la
  poda física comparan ahora SIEMPRE el nombre canónico de módulo (el de
  modprobe/depmod, con guiones bajos). Hasta v1.1.0 la poda física comparaba
  el basename del `.ko` (que en ALSA lleva guiones: `snd-hda-intel.ko`
  ⇔ canónico `snd_hda_intel`), por lo que se retiraban los módulos de audio
  HDA/HDMI aunque el allowlist los conservara. El kernel se compilaba con
  `CONFIG_SND_HDA_INTEL=m` (visible en `/proc/config.gz`) pero el árbol
  instalado acababa sin `snd-hda-intel.ko` ni códecs → PipeWire solo veía
  "Dummy Output" y no había sonido por HDMI ni de 3,5 mm.
- Se revisa que `CORE_KEEP` y el perfil ya traen el audio HDA (`snd_hda_intel`,
  `snd_hda_codec_*`, códecs HDMI/ALC269); con el fix la poda ya no los borra.

## [27.27.1] - 2026-09-22

kernel: sufijo `-cizen-v3` de verdad + título correcto en systemd-boot

- El perfil `linux-7.2.7-cizen-v3.config` tenía `CONFIG_LOCALVERSION=""`, así
  que `uname -r` daba `7.2.7` en lugar de `7.2.7-cizen-v3` (el motor ya asume
  ese sufijo en `LOCALVERSION_SUFFIX`, `PKGVER_BASE`, firmas y
  `find_cizen_installed_kernel`). Se fija `CONFIG_LOCALVERSION="-cizen-v3"`.
- `build_cizen_uki` ahora embebe un os-release propio (`.osrel`) en la UKI via
  `ukify --os-release=@<tmp>` (y `objcopy --add-section .osrel` como fallback)
  con `PRETTY_NAME="Linux 7.2.7-cizen-v3"`. Sin esto, ukify incrusta
  `/etc/os-release` y sd-boot 261.3 mostraba `Arch Linux (rolling)` en el menú;
  con `PRETTY_NAME` el título correcto es "Linux 7.2.7-cizen-v3".
- `cizen-uki-sync` aplica el mismo os-release; `release_from_kernel()` deriva el
  release desde la ruta del kernel, el marker `pkgbase` de
  `/usr/lib/modules/<rel>` o `strings` del binario.

## [27.27.0] - 2026-09-22

poda: la poda física de módulos pasa a ser efectiva + recorte del allowlist

- `podar-modulos.sh` v1.1.0: si el árbol aún no tiene `modules.dep`/
  `modules.alias` (p.ej. dentro de `package()` del PKGBUILD, justo tras
  `modules_install` y antes del `depmod` de la receta), el podador los genera
  con `depmod` antes de podar. Antes el guard abortaba y `|| true` conservaba
  el conjunto compilado completo: la poda física era un no-op. Ahora el
  paquete se adelgaza también en ficheros (verificable en el árbol instalado).
- Allowlist (`CORE_KEEP`) recortada tras auditoría del árbol instalado:
  fuera térmica Intel no cargada (`processor_thermal_*`,
  `int340x_thermal_zone`, `acpi_thermal_rel`), `md_mod` + `lz4hc_compress`
  `btmtk`/`btrtl`/`btbcm`/`rfcomm` (el BT real es de Intel y entra vía
  `btusb`+`btintel`) e `i2c_hid`/`i2c_mux` (sin HID I2C en este desktop; el
  bus sigue con `i2c_i801`/`i2c_smbus`/`i2c_dev`/`i2c_algo_bit`). `btintel`
  se mantiene explícito en `CORE_KEEP` para no perder BT si arrancas sin él
  cargado.
- Poda aplicada en caliente sobre el kernel 7.2.7 instalado: 1 módulo
  retirado (`failover.ko.zst`, ~5 KB), 68 conservados, árbol final de 20 MB;
  `depmod` regenerado. Se conserva lo cargado + hardware presente + allowlist
  + dependencias (BT, audio, red, nftables intactos).

## [27.26.0] - 2026-09-22

reestructuración: el changelog pasa a un archivo dedicado

- El historial completo sale de la cabecera de `kernel-update.sh` a
  `CHANGELOG.md` (raíz del repo); la cabecera conserva banner, OBJETIVOS y USO
  y apunta a este archivo.
- `--changelog` (`changelog_bump`) sigue bumpeando banner + `SCRIPT_VERSION`
  del motor y ahora escribe el borrador en `CHANGELOG.md`.

## [27.25.9] - 2026-09-22

mantenimiento: prereq perl + fail-fast de CONFIG_DIR

- check_prerequisites: perl (lo exige streamline_config.pl del modo lite, el
  ÚNICO modo de compilación) entra al array tools y a TOOL_PKG ([perl]=perl)
  con auto-instalación igual que ccache/pahole.
- Chequeo temprano ensure_config_dir_writable(): si CONFIG_DIR no existe y
  no puede crearse, o no es escribible, se aborta con mensaje claro ANTES de
  descargar/compilar. La promoción de la config base (promote_base_config) lo
  exige por diseño (CHANGELOG v27.21.17); sin este chequeo el fallo solo
  aparecía al final del check/build.
- kernel-update-verify.sh: verifica que el perfil validado coincide con el que
  firmó el último build (profile_sha de last-build); si cambió, avisa y suma
  una incidencia (reconstrucción recomendada). Se elimina además una línea
  muerta del total de boot (regex que nunca matcheaba; el fallback la cubre).

## [27.25.8] - 2026-09-22

tmpfs desmontado tras éxito

- Tras el flujo completo exitoso (compilación + instalación + UKI
  sincronizada) ya no hay motivo para conservar el tmpfs de compilación:
  ahora se desmonta (sudo umount $TMPFS_ROOT) en cleanup_success.
- Override: CIZEN_KEEP_TMPFS=1 conserva el comportamiento anterior
  (reutilización del árbol/ccache entre ejecuciones y diagnóstico).
- Los flujos parciales (solo check) NO desmontan: kcheck prepara el
  entorno y kbuild lo reutiliza. En error/interrupción tampoco (diagnóstico).

## [27.25.7] - 2026-09-22

cizen-uki-sync: sin initramfs residuo

- Tras integrar /boot/initramfs-<pkgbase>.img como sección .initrd de la UKI
  (ukify) y verificar la escritura en el ESP, el archivo suelto se elimina:
  systemd-boot solo necesita el .efi (lo carga systemd-stub). Override
  CIZEN_UKI_KEEP_INITRAMFS=1 para conservarlo (arranque directo del vmlinuz).
- Guardas: solo se borra si el initrd quedó realmente embebido (nunca con el
  fallback objcopy), no en --dry-run y no si la verificación final falla.

## [27.25.6] - 2026-09-21

fix verificación del paquete generado + cizen-uki-sync

- La validación exigía que el nombre coincidiera con PKGVER_BASE (con
  sufijo _cizen_v3), pero la plantilla genera el pkgver desde KERNELRELEASE
  (7.2.7, sin sufijo): el build (25 min) terminaba con la identificación
  fallida y sin instalar. Ahora se valida contra la metadata interna real
  (.PKGINFO: pkgname + pkgver 7.2.7-1) y su pkgrel, y se instala.
- cizen-uki-sync usaba `local -a targets=()` en el cuerpo principal (fuera de
  cualquier función): bash aborta con "local: can only be used in a function"
  y, con set -e, el flujo de instalación moría dejando el tmpfs montado. Ahora
  targets es variable global del cuerpo principal; la UKI se genera y escribe
  de forma atómica en el ESP.

## [27.25.5] - 2026-09-21

purga automática del enlace + BTF off por defecto

- Al reutilizar el árbol en tmpfs, si el espacio libre queda por debajo del
  mínimo se purgan automáticamente los artefactos re-generables del enlace
  final (vmlinux, vmlinux.o, vmlinux.unstripped, System.map, .tmp_vmlinux*)
  antes de abortar, conservando .o/.a y paquetes generados.
- Por defecto se desactiva DEBUG_INFO_BTF (los picos de RAM del enlace final
  causaron OOM y tmpfs lleno): paquete más pequeño y enlace más ligero.
  Sigue disponible con --btf / CIZEN_BTF=1 (los fuerza a =y de nuevo).
- Antes de `make pacman-pkg` se retiran los .pkg.tar.zst obsoletos del árbol:
  makepkg aborta si ya existe el mismo pkgver/pkgrel compilado
  ("El grupo de paquetes ya se ha compilado").

## [27.25.4] - 2026-09-21

modo lite = ÚNICO modo de compilación

- Fix identificación de paquete: copy_packages_from_build exigía *cizen_v3*
  en el nombre, pero la plantilla genera pkgver sin sufijo (7.2.7-1). Se
  acepta ahora la nomenclatura actual (v27.25.4b, no publicado).
- Esta suite solo compila de una forma: con make localmodconfig (los módulos
  cargados + allowlist de podar-modulos.sh), siempre, sin excepción. Se
  eliminan --lite, --no-lite y CIZEN_LITE: no existe el build "completo".
  El 100% de los builds son del kernel mínimo; la poda del paquete sigue
  activa y el arranque sin initramfs sigue garantizado (=y intactos).
- Fix no-interactivo: la receta oficial terminaba con `conf --oldconfig`
  (interactivo), que con símbolos nuevos (p. ej. SCHED_BORE del parche BORE)
  pedía respuestas en medio del flujo "automático". Ahora se replica la
  receta (streamline_config.pl + conf) reemplazando ese paso por
  `make olddefconfig` (no interactivo; los símbolos (NEW) toman su default
  y el perfil los re-fuerza después). Requiere exportar ARCH/SRCARCH al
  invocar streamline_config.pl fuera de make.

## [27.25.3] - 2026-09-21

modo --lite ACTIVADO POR DEFECTO

- El objetivo de este host es un kernel mínimo y builds cortos: desde esta
  versión --lite es el comportamiento por defecto (CIZEN_LITE=1). Un build
  "completo" (todos los módulos) se pide explícitamente con --no-lite o
  CIZEN_LITE=0. Igual que antes, la poda del paquete sigue activa siempre.

## [27.25.2] - 2026-09-21

modo --lite: compilar solo los módulos en uso

- Nuevo flag --lite (o CIZEN_LITE=1): ejecuta `make localmodconfig` sobre la
  config base con el input "/proc/modules + allowlist de podar-modulos.sh"
  (--keep-list: CORE_KEEP + /etc/modules-load.d + CIZEN_KEEP_MODULES). El
  resultado es no compilar los miles de módulos =m que la poda del paquete
  habría descartado: la compilación baja de ~19 min (frío) a una fracción.
  En el árbol 7.2.7 real la prueba pasó de 5472 a 172 módulos =m.
- El perfil se aplica DESPUÉS (apply_config_requests): ENABLE/CRITICAL =y,
  DISABLE y la auditoría/validación continúan igual; los =y (built-in) no
  se tocan, el arranque sin initramfs queda garantizado.
- podar-modulos.sh v1.0.1: nuevo modo --keep-list (imprime el allowlist
  estático un nombre por línea, sin necesidad de un árbol objetivo), usado
  por --lite para alimentar localmodconfig.
- Resumen final: línea "Lite: sí/no".

## [27.25.1] - 2026-09-21

el check ofrece absorber rebeldes automáticamente

- Auto-absorción interactiva: cuando la auditoría reporta desactivaciones
  que Kconfig conserva (DISABLE_WARN, p. ej. BT_BCM/INTEL_SCU/MPLS...), en
  un run sin --strict se pregunta ANTES de confirmar la compilación si
  absorberlas a EXPECTED_REBELS (deja la auditoría limpia). Equivale a un
  --absorb-rebels confirmado en el momento; sin terminal interactiva no se
  aplica y el check sigue con los warnings como hasta ahora. Reutiliza la
  misma revalidación posterior de --absorb-rebels (backup del perfil).

## [27.25.0] - 2026-09-21

poda de módulos: solo los necesarios para este hardware

- Poda automática de módulos del paquete linux-cizen-v3: tras empaquetar,
  podar-modulos.sh conserva únicamente los módulos que este equipo usa.
  Criterio: (1) módulos cargados ahora (/proc/modules), (2) módulos cuyo
  modalias del software presente de /sys casa con modules.alias del árbol,
  (3) allowlist CORE_KEEP del perfil (red, audio HDA, USB/HID/BT, FS,
  KVM/vfio/virtio/bridge, plataforma Dell/WMI, térmica/RAPL, input/gaming,
  netfilter nft, diagnóstico), (4) /etc/modules-load.d y la lista extra
  CIZEN_KEEP_MODULES, y (5) cierre transitivo de dependencias
  por modules.dep. Regenera los índices con depmod. Los módulos =y (built-in:
  X86_NATIVE_CPU, BTRFS_FS, DRM_I915, KVM_SMM, ...) no tienen .ko y la
  poda nunca los toca, por lo que el arranque sin initramfs sigue garantizado.
- La inyección ocurre en $SRC/scripts/package/PKGBUILD tras el
  "DEPMOD=true modules_install" de _package(), protegida por el respaldo
  .cizen-orig de prepare_package_identity_override() (restore_* la revierte
  igual). Guardas: [ -x pruner ], CIZEN_PRUNE_MODULES=1 y || true (una
  falla de la poda conserva el conjunto completo, nunca rompe el build).
- Nuevo flag --no-prune (o CIZEN_PRUNE_MODULES=0) para desactivar la poda;
  CIZEN_KEEP_MODULES="mod_a,mod_b" permite añadir módulos a conservar.
- Nuevo script kernel-update/podar-modulos.sh (v1.0.0, se instala en
  /usr/local/bin/kernel-update/) y línea "Podar:" en el resumen final.

## [27.24.4] - 2026-09-21

deps requeridas auto-instalables + perfil 7050 v5.11.1

- ccache y pahole pasan a dependencias REQUERIDAS del preflight: se añaden
  al array tools y a TOOL_PKG ([ccache]=ccache, [pahole]=pahole) para que
  check_prerequisites() las pida/instale interactivamente como el resto.
  ccache se usa en el build (CC/HOSTCC="ccache gcc"); pahole la exige el
  propio makepkg para generar el BTF del paquete (sin ella el build muere en
  "==> Dependencias que faltan: pahole").
- Perfil cizen-optiplex7050 v5.11.1: BTRFS_FS y DRM_I915 pasan de
  solo-CRITICAL a OPTS_ENABLE (el boot sin initramfs exige =y estricto en
  boot_critical: X86_NATIVE_CPU BTRFS_FS DRM_I915 KVM_SMM; una base ajena,
  p. ej. /proc/config.gz LTS en bootstrap, los deja en =m). v5.11.0 ya había
  añadido X86_NATIVE_CPU/NET_SCH_DEFAULT y los rivales de CHOICE.
- Nuevo script cizen-uki-sync: genera/aplica la UKI Cizen (arch-linux-cizen-v3.efi)
  desde el último kernel instalado; kernel-update.sh lo invoca vía sudo tras
  instalar el paquete (flujo UKI automático, antes script perdido).

## [27.24.3] - 2026-09-20

rollback: solo se conserva el kernel PREVIO

- Se refuerza la política de "no acumular kernels": prune_rollback_archives()
  conserva UNA SOLA copia de rollback (la del kernel anterior al actual).
  Antes: (a) si el archive de la release actual ya existía,
  prepare_rollback_archive() salía antes de podar, dejando potencialmente
  archives viejos de sesiones previstas sin limpiar; (b) se guardaba el de
  "mayor versión" sin excluir el kernel EN EJECUCIÓN. Ahora:
  - el early-return "rollback ya existe" también poda;
  - la prioridad es el de mayor versión que NO sea la release en ejecución
    (el "anterior" real); si todos coinciden con el actual, el de mayor
    versión. Nunca más de un archive (+ su .timestamp).
- Test: /var/tmp/opencode/test-rollback-prune.sh (stubs de sudo/uname/log):
  poda con varios kernels deja 1 = el previo; excluye el en ejecución.

## [27.24.2] - 2026-09-20

Ctrl+C ya no se reporta como error

- Al cancelar la build/descarga con Ctrl+C (SIGINT) o SIGTERM el motor
  seguía mostrando "⚠ La ejecución terminó con error (130)" (mensaje del
  trap EXIT cuando rc≠0). Ahora `cleanup_interrupt()` marca INTERRUPT_CAUGHT
  antes de `exit 130` y `cleanup_tmpfs_on_exit()` distingue: si rc==130 con
  INTERRUPT_CAUGHT=true imprime con `info` "La compilación fue cancelada por
  el usuario; no es un error..." (mismo tmpfs conservado para diagnóstico).
  Un fallo REAL sigue reportándose como error (rc≠130 o sin señal capturada).
  El código de salida sigue siendo 130 (terminación por SIGINT, convención
  de Bash 128+2): solo cambia la redacción, no el status.

## [27.24.1] - 2026-09-20

confirmación de recompilación sin release nueva

- Cuando se elige una opción de compilación (build/buildfast/force/BORE) sin
  versión explícita y NO hay una release estable nueva (instalada == stable),
  en lugar de abortar con "No hay una release estable nueva..." el motor ahora
  Pregunta (confirm_recompile_current, /dev/tty): "¿Quieres continuar con la
  recompilación del kernel <versión>? [S/n]". S/sí -> VERSION se fija a la
  versión instalada y la recompilación continúa (p. ej. para aplicar el perfil
  v5.10.0 pendiente o BORE); N/no (o sin terminal) -> "Recompilación
  cancelada" y salida sin hacer nada, igual que antes. kcheck (validación)
  sigue sin prompt; la consulta de release nueva previa (confirm_newer_release)
  no cambia.

## [27.24.0] - 2026-09-20

framework de parches, kcfg, btf, clang, selftest, repo, changelog

- 1) FRAMEWORK DE PARCHES GENÉRICO: apply_bore_patch() se generaliza a un
  motor declarativo de parches de terceros. Cada parche es un descriptor
  (URL por rama X.Y, subdir, fichero principal + respaldo upstream, símbolos
  Kconfig, marcadores de árbol ya parcheado, cadena mágica de validación).
  BORE es el primer plugin (`--bore` = `--patch bore`). El motor descarga
  SIEMPRE en fresco (rm previo + auto-file-renaming=false), valida el parche,
  hace dry-run, degrada al respaldo del autor si CachyOS no aplica sobre la
  release final, y registra los símbolos (ENABLE + rebeldes esperados) sin
  ensuciar la validación. Fallo → advertencia y build vanilla (nunca rompe).
  Nuevo: `--patch <n>` (repetible) / CIZEN_PATCHES="a,b". ``--bore`` sigue
  funcionando (alias). El árbol conservado ya-parcheado se detecta por
  marcadores (no re-descargan ni re-aplican).
- 2) kcfg / --menuconfig: abre `make menuconfig` sobre la config Cizen ya
  validada, re-audita y revalida al salir, y genera un diff del perfil
  (cambiados/añadidos/retirados) con la sugerencia de entrada OPTS_*
  correspondiente. La config editada se promueve a base y queda lista para
  compilar (--menuconfig con build) o para un --check posterior.
- 3) --selftest: batería interna (bash -n del propio motor, carga del perfil
  y de contradicciones, herramientas imprescindibles) + harness funcional
  de la suite ($SCRIPT_DIR/tests/selftest.sh) cuando existe.
- 4) --publish-repo / CIZEN_PUBLISH_REPO: tras instalar con éxito, copia el
  .pkg.tar.zst a un repo local pacman (default /var/lib/kernel-update/repo,
  db "cizen-linux") vía repo-add, para que las VMs libvirt puedan instalarlo
  con pacman (file:// o por red). Fallo suave; requiere pacman-contrib.
- 5) --btf / CIZEN_BTF=1: fuerza CONFIG_DEBUG_INFO+DEBUG_INFO_BTF (+ los
  marca como esperados en la auditoría). Pide instalar pahole si falta
  (opcional); degrade a sin-BTF si no se puede.
- 6) --clang / CIZEN_CLANG=1: build LLVM/clang (LLVM=1, ld.lld). Si falta
  clang o lld → warning y build GCC. Combinable con ccache.
- 7) --changelog: mantenimiento — bumpea cabecera+SCRIPT_VERSION y añade un
  borrador de changelog al top con el diff --stat del espejo git (si existe).
  NO commit: el texto lo completa el mantenedor.
- El resumen final muestra ahora también Parches/BTF/Toolchain y el repo
  local publicado; write_verify_signature graba patches/btf/clang para que
  kernel-update-verify.sh los compruebe post-boot.

## [27.23.0] - 2026-09-20

operativa: diff de config, post-boot, rollback, snapshots

- 1) Config-diff: tras validar, se compara la config efectiva nueva vs la del
  kernel EN EJECUCIÓN (/proc/config.gz) teniendo en cuenta los renames del
  perfil (APPLIED_RENAMES) y se resumen cambiados/nuevos/retirados (máx 15
  detalles). Primera señal de que el perfil realmente cambió algo.
- 2/6/8) Verificación post-boot NUEVA: script kernel-update-verify.sh +
  unit de usuario (ver abajo) que tras cada arranque comprueba que el kernel
  en ejecución cumple el perfil (OPTS_ENABLE/CRITICAL_OPTS/SETVAL/SETSTR +
  estado BORE vs firma de build), compara el tiempo de arranque
  (systemd-analyze) con el boot previo y escanea el journal del kernel del
  boot actual buscando patrones de regresión (oops/panic/GPU hang/hung task)
  frente al boot anterior. Notifica discrepancias (~/.local/state/kernel-update/).
- 3) Rollback dual-kernel: antes de instalar, kernel-update.sh archiva el
  kernel en ejecución (módulos + vmlinuz) en $ROLLBACK_DIR
  (/var/lib/kernel-update/rollback, 1 copia). Nuevo
  kernel-update-rollback.sh / comando krollback lo restaura y regenera la UKI.
- 4) Snapshot btrfs readonly de la raíz antes de instalar (subvol
  .snapshots/@kernel-<versión>-<ts>). Auto si / es btrfs; desactivar con
  CIZEN_SNAPSHOT=0. Fallo NO bloquea (warn).
- 5) Rama de seguimiento configurable: CIZEN_KERNEL_TRACK=stable (default)
  | longterm (LTS mayor de releases.json; requiere jq; sin jq degrada a stable
  con warning). Aplica a build/check-update y al notificador.
- 7) Informe final ampliado: desglose de tiempos (descarga+extracción,
  config+validación, compilación, instalación+UKI) y estadísticas ccache
  (hits/tamaño/ficheros) cuando hay ccache.
- No rompe el flujo anterior: todas las partes nuevas son aditivas, fallan
  blando (warn) o son configurables con variables de entorno.

## [27.22.4] - 2026-09-19

fix BORE en árbol reutilizado

- Bug: tras cancelar una build BORE (Ctrl+C) el árbol tmpfs se conserva CON
  el parche ya aplicado (kernel/sched/bore.c + fair.c toquetado). Al relanzar
  `--bore`, apply_bore_patch() volvía a descargar el parche bueno y patch(1)
  respondía "Reversed (or previously applied) patch detected" en el dry-run
  (rc=1) → el motor degradaba a EEVDF vanilla pese a que el árbol SÍ lo lleva.
- Fix: detección de parche ya aplicado al inicio de apply_bore_patch() —
  si `kernel/sched/bore.c` existe y `fair.c` contiene SCHED_BORE/burst, se
  marca BORE_ENABLED=true y se continúa sin re-descargar ni re-aplicar.
- Verificado contra el árbol real conservado (bore.c=SI, fair.c marcado=SI).
  `bash -n` OK.

## [27.22.3] - 2026-09-19

fix falso error en índice de Kconfig

- Bug: build_kconfig_symbol_index() construye su índice vía un
  process-substitution `done < <(find | xargs grep | awk | sort -u)` que
  hereda `set -Eeuo pipefail`. xargs parte la lista de Kconfig en lotes y un
  lote cuyo grep no encuentra ningún `config`/`menuconfig` sale con status 1:
  con pipefail el pipeline completo reporta error, el trap ERR del subshell
  dispara `on_err` ("Error 1 ... sort -u") y aunque el `exit` del subshell no
  aborta el script, queda un falso fallo + índice supuestamente truncado.
  Reproducido: `xargs -n 1` + pipefail → rc=123 sin `|| true`; rc=0 con él.
- Fix: `sort -u || true` al final del pipeline interno. El índice se construye
  leyendo el stream (input) del process-substitution, no por su exit status:
  el rc legítimo de grep/xargs no debe disparar set -e, y un fallo REAL de
  escalado (Kconfig ausente) sigue dejando el índice vacío sin enmascararse.
- Verificación: test con set -Eeuo pipefail + trap ERR → sin on_err, built=true,
  índice 21717 símbolos, SCHED_BORE presente. `bash -n` OK.

## [27.22.2] - 2026-09-19

fix descarga parche BORE huérfana

- Bug: el intento 2 del parche BORE (upstream) volvía a usar el mismo
  `--out` (bore-$br.patch) que el intento 1 (CachyOS). aria2c (--continue
  + --allow-overwrite=false) no re-descarga un fichero existente: con el
  tamaño coincidente lo daba por completo (contenido CachyOS) o lo
  renombraba a bore-$br.1.patch (auto-file-renaming), dejando el parche
  upstream bueno huérfano y validando siempre el CachyOS que no aplica.
- Fix doble: (a) `--auto-file-renaming=false` en download_file() (aria2c)
  para que el nombre de salida sea SIEMPRE el `--out` pedido; (b) cada
  intento BORE hace `rm -f` del destino antes de descargar, garantizando
  contenido fresco y evitando el falso "completo" por tamaño coincidente.
- Verificado en vivo 2026-09-19 19:36: cachy 7.2-rc5 no aplica sobre
  7.2.6 → degrade upstream correcto (40229 B, firelzrd) descargado pero
  ignorado por el bug; con el fix aplica limpio y SCHED_BORE=y.

## [27.22.1] - 2026-09-19

cancelar la build con Ctrl+C

- timeout(1) sin --foreground creaba un grupo de procesos PROPIO para make,
  aislado del grupo foreground de la terminal: Ctrl+C (SIGINT al grupo
  foreground) llegaba solo al script y NO cancelaba la compilación.
- Fix: la invocación make ahora usa `timeout --foreground --signal=TERM
  --kill-after=60s`, de modo que make (y sus sub-makes/gcc) heredan el
  grupo de la terminal y puede cancelarse desde el teclado en cualquier
  momento. make hace la limpieza de .o vía sus traps INT/TERM.

## [27.22.0] - 2026-09-19

BORE scheduler opcional

- Nuevo flag `--bore` / env CIZEN_ENABLE_BORE=1: aplica el parche BORE
  (Burst-Oriented Response Enhancer) de CachyOS sobre el scheduler EEVDF,
  priorizando por "burstiness" para mejorar la responsividad interactiva
  (input/audio/gaming) con coste de equidad. Es OPCIONAL: sin el flag la
  build es 100% vanilla como antes.
- El parche se descarga por rama X.Y del kernel objetivo desde
  https://raw.githubusercontent.com/CachyOS/kernel-patches/master/
  <rama>/sched/0001-bore-cachy.patch (p. ej. 7.2 → 7.2/sched/...). Si el
  forward-port de CachyOS no aplica limpio sobre la release final X.Y.Z
  (se regenera contra una RC), se degrada automáticamente al parche del
  autor upstream 0001-bore.patch de la misma rama, que se mantiene por
  release y aplica sobre la versión estable.
- Si la descarga falla, el parche no aplica limpio o sha/forma inválida →
  warn y CONTINÚA con EEVDF vanilla (nunca rompe la build).
- Al aplicar, SCHED_BORE se fuerza a =y y se marca junto a MIN_BASE_SLICE_NS
  como símbolos esperados en la auditoría (no ensucia kcheck ni aborta en
  modo --strict). build_effective_arrays() se re-ejecuta tras el parche.
- Mantenimiento: CachyOS publica el parche por rama mayor; las bilds con
  --bore quedan ligadas a la rama X.Y del objetivo (7.2.6 → 7.2). Si una
  rama nueva no tiene parche, el motor degrada a vanilla con warning.
- Compatibilidad: el perfil v5.10.0 es compatible con BORE (HZ_1000 + IRQ_TIME_ACCOUNTING).

## [27.21.17]

config base persistente dentro de la suite

- Los linux-<versión>-cizen-v3.config (config base que find_latest_cizen_config
  usa y que se promueve tras un build/check) dejan de leerse/escribirse en
  $HOME: viven junto a los perfiles, en $SCRIPT_DIR/profiles (override
  CIZEN_CONFIG_DIR). El directorio debe ser escribible por el usuario que
  compila para poder promover la configuración.
- get_local_kernel_version(), find_latest_cizen_config() y las dos
  promociones de FINAL_CONFIG usan CONFIG_DIR. promote_home_config pasa a
  llamarse promote_base_config.

## [27.21.15]

--absorb-rebels: rebeldes al perfil automáticamente

- Nuevo flag --absorb-rebels: cuando la validación detecta símbolos de
  OPTS_DISABLE que Kconfig conserva a =y/=m por dependencias internas
  (depends on/select/defaults) y que aún no están en EXPECTED_REBELS,
  los mueve de OPTS_DISABLE a EXPECTED_REBELS en el archivo de perfil
  (con backup .bak-<ts> y validación bash -n previa a sustituir). Tras
  editar, recarga el perfil, reconstruye los arrays efectivos y revalida
  para que el mismo chequeo termine limpio y futuras ejecuciones no
  reproduzcan los warnings.
- Extrae la construcción de EFF_* a build_effective_arrays() para poder
  reconstruir los arrays efectivos tras un --absorb-rebels sin duplicar
  lógica.

## [27.21.14]

optimización de velocidad de compilación

- MAKEFLAGS="-j$JOBS" global: los sub-makes (menú, headers, modules,
  pacman-pkg) heredan la misma paralelidad que el make principal.
- CIZEN_BUILD_PRIORITY=normal: salta nice/ionice y compila a plena
  prioridad (~20-40% más rápido en máquina seca; CPU-bound). Por
  defecto sigue low (write tool usable durante el build).
- ccache tuning: base_dir=$HOME (hits independientes del cwd) y
  compiler_check=content (hash del compilador, no del path); límite
  de tamaño opcional vía CCACHE_MAX_SIZE.
- tmpfs de compilación montado con huge=advise (hugepages para los
  temporales grandes de Kbuild).
- BUILD_TIMEOUT por defecto 3600s (antes 14400s); cubre una build
  completa (~19 min cold / ~4 min warm) y aborta builds colgadas antes.

## [27.21.13]

autoinstalación interactiva de dependencias

- check_prerequisites() ya no solo aborta con "Falta dependencia": detecta
  qué herramientas faltan, traduce cada comando a su paquete Arch (mapa
  TOOL_PKG) y pregunta interactivamente antes de ejecutar
  'sudo pacman -S --needed ...'. Si se acepta, reinstala y reverifica que
  cada comando quede en PATH; si se rechaza o no hay terminal, aborta con
  el comando exacto sugerido. Nunca se instala sin confirmación explícita.
- sudo, pacman y cizen-uki-sync no tienen paquete asociado (no se pueden
  autoinstalar de forma sensata): siguen abortando con instrucciones.
- aria2c se sugiere activamente antes de la primera descarga, solo cuando
  va a usarse (no con CIZEN_DOWNLOADER=wget ni con caché ya válida).
  Declinarlo NO bloquea: se continúa con el wget de un hilo.
- CIZEN_NO_AUTOINSTALL=1 desactiva todo prompt y restaura el
  comportamiento estricto previo (abortar si falta una requerida).
- jq sigue siendo opcional (fallback sed); no se exige ni se instala.

## [27.21.16]

progreso de descarga silencioso

- download_file() ya no imprime el "Download Progress Summary" de aria2c
  cada segundo en TTY (spam). Intervalo nuevo vía CIZEN_DOWNLOAD_SUMMARY_INTERVAL:
    0 (default)  = sin summary de progreso (--summary-interval=0)
    N>0          = summary cada N segundos (solo si hay TTY)
  Si no hay TTY sigue --quiet como antes. Convención idéntica a descargar.sh.

## [27.21.12]

descarga paralela opcional con aria2c

- Nuevo download_file(): usa aria2c (conexiones paralelas configurables vía
  CIZEN_DOWNLOAD_PARALLEL, por defecto 4) cuando está instalado, y cae a
  wget exacto si no lo está o si se fuerza CIZEN_DOWNLOADER=wget. Conserva
  la semántica previa de reintentos/continuación, la detección de TTY para
  el progreso y la limpieza de temporales .download-* al inicio y en EXIT.
- Un CDN que limita cada conexión por hilo (se observaron ~30 MB/s por
  conexión en cdn.kernel.org frente a ~54 MB/s agregados con 4 hilos) ya no
  acota la descarga del tarball a una única conexión. Si falta aria2c, el
  flujo es idéntico al de v27.21.11 (wget clásico, un hilo).
- La firma PGP se obtiene con el mismo downloader: al ser un fichero
  pequeño, aria2c no activa el paralelismo (queda por debajo de
  --min-split-size) y el comportamiento es equivalente.

## [27.21.11]

endurecimiento de limpieza y selección de base

- cleanup_old_source_trees() ya no elimina árboles de fuentes bajo un
  directorio que NO esté montado como el tmpfs dedicado de compilación:
  se evita un rm -rf destructivo si KERNEL_TMPFS_ROOT apunta (por error
  o falta de revisión) a un directorio persistente con árboles linux-*.
  En el flujo normal el tmpfs reutilizado sigue montado y la limpieza de
  versiones antiguas actúa exactamente igual que antes.
- find_latest_cizen_config() selecciona la configuración Cizen de mayor
  versión <= objetivo en vez de la más reciente por mtime: evita usar
  como base una configuración de una versión MÁS nueva ya compilada
  antes (que arrastra símbolos de una migración futura). Sin versión
  explícita conserva el comportamiento de elegir la mayor disponible.
- get_kernel_org_latest_stable() usa jq cuando está disponible para
  parsear releases.json, con el parsing sed existente como fallback:
  robustez frente a cambios de formato del índice de kernel.org.
- Añade un preflight opcional de privilegios sudo (no bloqueante) que
  comprueba mount/umount/find/stat/mkdir/cp/mv/rm/fuser/sync/pacman
  antes de la compilación, para detectar sudoers restrictivos de forma
  temprana en vez de fallar tras minutos de build en la instalación.

## [27.21.10]

retirada de linux-upstream idempotente

- install_kernel_package() ya no aborta la instalación cuando
  `pacman -R linux-upstream` responde "target not found": pacman -Q lo
  había visto instalado un instante antes, pero si para cuando se intenta
  retirar ya no está, el objetivo de la migración (linux-upstream fuera
  del sistema) ya se cumple. Solo se sigue tratando como fatal cualquier
  otro motivo real de fallo en la retirada (permisos, dependencias, lock
  de la base de datos). Evita cancelar la instalación de un paquete ya
  compilado y verificado por una discrepancia de estado que no era un
  fallo real.

## [27.21.9]

verificación de tarball sin descompresión duplicada

- Quita el xz -t redundante en la ruta de "tarball ya en caché": la
  verificación de firma (xz -cd | gpg --verify, con pipefail activo) ya
  cubre la misma garantía de integridad, así que ya no se descomprime el
  tarball dos veces por ejecución. El chequeo xz -t tras una descarga
  fresca se conserva igual, porque ahí sí sirve para fallar rápido antes
  de bajar la firma.
- Añade una huella tamaño+mtime (linux-<versión>.tar.xz.verified-ok) para
  no repetir la verificación criptográfica completa entre ejecuciones
  distintas cuando el tarball y la firma no cambiaron desde la última vez
  que se verificaron con éxito. Cualquier cambio real en cualquiera de
  los dos archivos invalida la huella y fuerza verificación completa de
  nuevo. cleanup_kernel_cache() conserva esta huella solo para la versión
  objetivo, igual que ya hacía con el tarball y la firma.

## [27.21.8]

sudo keep-alive interrumpible + sincronía de versión

- Corrige sudo_keepalive_start(): el sleep de refresco ahora corre en
  segundo plano y se espera con `wait`, para que el trap TERM/INT lo
  interrumpa de inmediato. Antes, un sleep 60 en primer plano difería
  el trap hasta que el propio sleep terminaba por sí solo (comportamiento
  documentado de Bash), dejando una pausa de hasta 60s entre
  "Configuración final guardada" y el resumen final de cada ejecución.
- Sincroniza la cabecera (banner) con SCRIPT_VERSION; quedaban desfasadas.

## [27.21.6]

migración pacman + flujo kcheck/kbuild

- Corrige la migración linux-upstream -> linux-cizen-v3 para pacman reales
  que no soportan --resolve-conflicts=all: si el paquete legado está instalado,
  se retira explícitamente justo antes de instalar el paquete Cizen ya validado.
- No toca /boot, presets ni pkgbase manualmente durante la migración.
- Añade timeout de 300 s al prompt de continuidad de kcheck para no retener
  indefinidamente el lock global mientras una terminal queda abandonada.
- Unifica la política de terminal interactiva de confirm_build_after_check()
  con confirm_newer_release().
- Evita promover $CONFIG_DIR/linux-<versión>-cizen-v3.config dos veces cuando kcheck
  continúa a compilación; solo se promueve al finalizar la rama CHECK o después
  de instalación + sincronización UKI.
  

## [27.21.7]

timestamp real de compilación

- Elimina el KBUILD_BUILD_TIMESTAMP fijo en 2001-01-01 que hacía que
  uname -a mostrara una fecha artificial cuando ccache estaba activo.
- Mantiene ccache habilitado sin alterar la fecha/hora real de compilación.
- KBUILD_BUILD_TIMESTAMP solo se respeta si el usuario lo exporta
  explícitamente antes de ejecutar el script.
- Genera paquetes Arch con pkgbase linux-cizen-v3 en lugar de linux-upstream.
- Mantiene KERNELRELEASE=VERSION-cizen-v3, separado del nombre de paquete.
- Hace que /usr/lib/modules/<release>/pkgbase contenga linux-cizen-v3 para que
  mkinitcpio utilice linux-cizen-v3.preset.
- Declara conflicts/replaces/provides con linux-upstream como metadata de transición.
- Mantiene linux-upstream como fallback temporal para detectar la versión local.

## [27.21.4]

kcheck con continuación opcional a compilación

- Después de una validación exitosa de kcheck/--check, ofrece continuar
  inmediatamente con la compilación del kernel validado.
- Enter y S/s continúan con la compilación; N/n finaliza limpiamente.
- Las respuestas inválidas se vuelven a solicitar para evitar decisiones
  accidentales.
- En terminales no interactivas se conserva el comportamiento seguro de
  detenerse después del chequeo, sin intentar compilar automáticamente.
- La configuración ya promovida y las fuentes preparadas se conservan
  exactamente igual que antes.

## [27.21.3]

limpieza de redundancias y consistencia

- Sincroniza la cabecera con SCRIPT_VERSION=27.21.3.
- Elimina validaciones duplicadas de PROFILE_FILE ya realizadas antes de source.
- Elimina la carga de CONFIG_STATE innecesaria antes de aplicar scripts/config.
- Elimina reasignaciones idénticas de SRC/BUILD_MARKER tras preparar el tmpfs.
- Evita un trap RETURN temporal en do_rename().
- Conserva intacta la reaplicación incondicional del perfil sobre cualquier base seleccionada.
  

## [27.21.1]

detección también con versión explícita

- Cuando se especifica una versión explícita, se conserva exactamente esa
  versión para mantener el comportamiento determinista, pero ahora se consulta
  kernel.org y se avisa si existe una stable posterior.
- --check-update sigue consultando únicamente disponibilidad y no modifica nada.

## [27.21.2]

selección interactiva de stable nueva

- Cuando se solicita una versión explícita y kernel.org ofrece una stable
  posterior, pregunta antes de descargar cuál versión compilar.
- Si se acepta, VERSION cambia a la release nueva y el flujo continúa de
  forma natural con sus rutas, fuentes, configuración, build e instalación.
- Si se rechaza, se conserva exactamente la versión solicitada.
- Se elimina la doble notificación de "release nueva detectada".
  

## [27.21.0]

agente de releases kernel.org

- Consulta https://www.kernel.org/releases.json para detectar la última
  release estable publicada, sin scrapear HTML ni depender de una rama fija.
- Sin versión explícita, compara la stable remota con el kernel Cizen instalado
  y solo inicia una compilación cuando existe una release nueva.
- Añade --check-update para consultar disponibilidad sin modificar ni compilar.
- Las versiones explícitas siguen siendo totalmente deterministas y no se
  solo sustituyen la versión solicitada tras confirmación interactiva.

## [27.20.8]

cierre limpio del sudo keep-alive

- Hace que el subshell de sudo keep-alive responda inmediatamente a TERM/INT,
  evitando dejar temporalmente un sleep reparentado durante la limpieza.

## [27.20.7]

ccache, integridad del perfil y trazabilidad

- Pasa CC/HOSTCC explícitamente a Kbuild cuando ccache está disponible,
  evitando depender de la precedencia de variables exportadas.
- Valida que el perfil externo pertenezca al usuario actual y no sea
  escribible por grupo u otros usuarios antes de hacer source.
- Restaura y separa explícitamente la entrada del changelog v27.20.5.

## [27.20.6]

robustez de resolución, preflight y consistencia de perfil

- Corrige cualquier advertencia emitida por resolve_symbol() para que no
  contamine su salida capturada por sustitución de comandos.
- Corrige SCRIPT_VERSION para que el banner/runtime identifique esta release.
- Añade validación temprana de contradicciones entre ENABLE/DISABLE y entre
  listas de estado y SETVAL/SETSTR, después de aplicar renombres.
- Añade bc, bison y flex al preflight porque forman parte de los requisitos
  de compilación documentados por Kbuild.
- Mantiene el timeout de build, el glob correcto y el progreso wget TTY-aware.

## [27.20.5]

limpieza de glob, wget TTY-aware y timeout de compilación

- Corrige la expansión de glob de residuos .download-* y .partial-* para
  que nullglob encuentre y elimine temporales interrumpidos correctamente.
- Usa --show-progress de wget solo cuando stderr es un TTY; los logs no
  interactivos quedan limpios y deterministas.
- Añade BUILD_TIMEOUT configurable (14400 s por defecto) con timeout(1),
  TERM y --kill-after para abortar builds colgadas sin dejar procesos hijos.

## [27.20.4]

SETSTR en resumen y preflight de cizen-uki-sync

- Separa warnings de DISABLE de fallos FATALES SETVAL/SETSTR.
- Imprime siempre las desactivaciones que Kconfig conserva y --strict las
  trata como warnings reales.
- Construye un índice único de símbolos Kconfig para evitar búsquedas
  grep -R repetidas por símbolo.
- Detecta transacciones de pacman mediante fuser, incluyendo backends como
  pamac-daemon y otros gestores que no estén en una lista fija.
- Revalida el lock justo antes de eliminarlo y distingue locks previos al
  intento de instalación de locks creados durante el propio intento.

## [27.20.0]

perfil v5.1 + resolución real de Kconfig

- La existencia de símbolos se consulta en los Kconfig reales del árbol
  objetivo, no en la presencia previa dentro de .config.
- SETVAL/SETSTR del perfil son requisitos estrictos: si Kconfig no puede
  materializarlos en el resultado final, la validación es FATAL.
- Se preservan los comportamientos de limpieza, tmpfs y cache definidos
  en las versiones anteriores.
