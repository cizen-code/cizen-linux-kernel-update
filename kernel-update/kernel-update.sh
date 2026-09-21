#!/usr/bin/env bash
# ============================================================
# kernel-update.sh — Cizen v27.25.0 (PRODUCCIÓN)
# Dell OptiPlex 7050 / Intel Core i5-7500 / HD 630 / Q270
# 12 GiB DDR4 / Btrfs / systemd / KVM-libvirt / QEMU-OVMF
#
# CHANGELOG v27.25.0 (poda de módulos: solo los necesarios para este hardware — 2026-09-21)
#   - Poda automática de módulos del paquete linux-cizen-v3: tras empaquetar,
#     podar-modulos.sh conserva únicamente los módulos que este equipo usa.
#     Criterio: (1) módulos cargados ahora (/proc/modules), (2) módulos cuyo
#     modalias del software presente de /sys casa con modules.alias del árbol,
#     (3) allowlist CORE_KEEP del perfil (red, audio HDA, USB/HID/BT, FS,
#     KVM/vfio/virtio/bridge, plataforma Dell/WMI, térmica/RAPL, input/gaming,
#     netfilter nft, diagnóstico), (4) /etc/modules-load.d y la lista extra
#     CIZEN_KEEP_MODULES, y (5) cierre transitivo de dependencias
#     por modules.dep. Regenera los índices con depmod. Los módulos =y (built-in:
#     X86_NATIVE_CPU, BTRFS_FS, DRM_I915, KVM_SMM, ...) no tienen .ko y la
#     poda nunca los toca, por lo que el arranque sin initramfs sigue garantizado.
#   - La inyección ocurre en $SRC/scripts/package/PKGBUILD tras el
#     "DEPMOD=true modules_install" de _package(), protegida por el respaldo
#     .cizen-orig de prepare_package_identity_override() (restore_* la revierte
#     igual). Guardas: [ -x pruner ], CIZEN_PRUNE_MODULES=1 y || true (una
#     falla de la poda conserva el conjunto completo, nunca rompe el build).
#   - Nuevo flag --no-prune (o CIZEN_PRUNE_MODULES=0) para desactivar la poda;
#     CIZEN_KEEP_MODULES="mod_a,mod_b" permite añadir módulos a conservar.
#   - Nuevo script kernel-update/podar-modulos.sh (v1.0.0, se instala en
#     /usr/local/bin/kernel-update/) y línea "Podar:" en el resumen final.
#
# CHANGELOG v27.24.4 (deps requeridas auto-instalables + perfil 7050 v5.11.1 — 2026-09-21)
#   - ccache y pahole pasan a dependencias REQUERIDAS del preflight: se añaden
#     al array tools y a TOOL_PKG ([ccache]=ccache, [pahole]=pahole) para que
#     check_prerequisites() las pida/instale interactivamente como el resto.
#     ccache se usa en el build (CC/HOSTCC="ccache gcc"); pahole la exige el
#     propio makepkg para generar el BTF del paquete (sin ella el build muere en
#     "==> Dependencias que faltan: pahole").
#   - Perfil cizen-optiplex7050 v5.11.1: BTRFS_FS y DRM_I915 pasan de
#     solo-CRITICAL a OPTS_ENABLE (el boot sin initramfs exige =y estricto en
#     boot_critical: X86_NATIVE_CPU BTRFS_FS DRM_I915 KVM_SMM; una base ajena,
#     p. ej. /proc/config.gz LTS en bootstrap, los deja en =m). v5.11.0 ya había
#     añadido X86_NATIVE_CPU/NET_SCH_DEFAULT y los rivales de CHOICE.
#   - Nuevo script cizen-uki-sync: genera/aplica la UKI Cizen (arch-linux-cizen-v3.efi)
#     desde el último kernel instalado; kernel-update.sh lo invoca vía sudo tras
#     instalar el paquete (flujo UKI automático, antes script perdido).
#
# CHANGELOG v27.24.3 (rollback: solo se conserva el kernel PREVIO — 2026-09-20)
#   - Se refuerza la política de "no acumular kernels": prune_rollback_archives()
#     conserva UNA SOLA copia de rollback (la del kernel anterior al actual).
#     Antes: (a) si el archive de la release actual ya existía,
#     prepare_rollback_archive() salía antes de podar, dejando potencialmente
#     archives viejos de sesiones previstas sin limpiar; (b) se guardaba el de
#     "mayor versión" sin excluir el kernel EN EJECUCIÓN. Ahora:
#     - el early-return "rollback ya existe" también poda;
#     - la prioridad es el de mayor versión que NO sea la release en ejecución
#       (el "anterior" real); si todos coinciden con el actual, el de mayor
#       versión. Nunca más de un archive (+ su .timestamp).
#   - Test: /var/tmp/opencode/test-rollback-prune.sh (stubs de sudo/uname/log):
#     poda con varios kernels deja 1 = el previo; excluye el en ejecución.
#
# CHANGELOG v27.24.2 (Ctrl+C ya no se reporta como error — 2026-09-20)
#   - Al cancelar la build/descarga con Ctrl+C (SIGINT) o SIGTERM el motor
#     seguía mostrando "⚠ La ejecución terminó con error (130)" (mensaje del
#     trap EXIT cuando rc≠0). Ahora `cleanup_interrupt()` marca INTERRUPT_CAUGHT
#     antes de `exit 130` y `cleanup_tmpfs_on_exit()` distingue: si rc==130 con
#     INTERRUPT_CAUGHT=true imprime con `info` "La compilación fue cancelada por
#     el usuario; no es un error..." (mismo tmpfs conservado para diagnóstico).
#     Un fallo REAL sigue reportándose como error (rc≠130 o sin señal capturada).
#     El código de salida sigue siendo 130 (terminación por SIGINT, convención
#     de Bash 128+2): solo cambia la redacción, no el status.
#
# CHANGELOG v27.24.1 (confirmación de recompilación sin release nueva — 2026-09-20)
#   - Cuando se elige una opción de compilación (build/buildfast/force/BORE) sin
#     versión explícita y NO hay una release estable nueva (instalada == stable),
#     en lugar de abortar con "No hay una release estable nueva..." el motor ahora
#     Pregunta (confirm_recompile_current, /dev/tty): "¿Quieres continuar con la
#     recompilación del kernel <versión>? [S/n]". S/sí -> VERSION se fija a la
#     versión instalada y la recompilación continúa (p. ej. para aplicar el perfil
#     v5.10.0 pendiente o BORE); N/no (o sin terminal) -> "Recompilación
#     cancelada" y salida sin hacer nada, igual que antes. kcheck (validación)
#     sigue sin prompt; la consulta de release nueva previa (confirm_newer_release)
#     no cambia.
#
# CHANGELOG v27.24.0 (framework de parches, kcfg, btf, clang, selftest, repo, changelog — 2026-09-20)
#   - 1) FRAMEWORK DE PARCHES GENÉRICO: apply_bore_patch() se generaliza a un
#     motor declarativo de parches de terceros. Cada parche es un descriptor
#     (URL por rama X.Y, subdir, fichero principal + respaldo upstream, símbolos
#     Kconfig, marcadores de árbol ya parcheado, cadena mágica de validación).
#     BORE es el primer plugin (`--bore` = `--patch bore`). El motor descarga
#     SIEMPRE en fresco (rm previo + auto-file-renaming=false), valida el parche,
#     hace dry-run, degrada al respaldo del autor si CachyOS no aplica sobre la
#     release final, y registra los símbolos (ENABLE + rebeldes esperados) sin
#     ensuciar la validación. Fallo → advertencia y build vanilla (nunca rompe).
#     Nuevo: `--patch <n>` (repetible) / CIZEN_PATCHES="a,b". ``--bore`` sigue
#     funcionando (alias). El árbol conservado ya-parcheado se detecta por
#     marcadores (no re-descargan ni re-aplican).
#   - 2) kcfg / --menuconfig: abre `make menuconfig` sobre la config Cizen ya
#     validada, re-audita y revalida al salir, y genera un diff del perfil
#     (cambiados/añadidos/retirados) con la sugerencia de entrada OPTS_*
#     correspondiente. La config editada se promueve a base y queda lista para
#     compilar (--menuconfig con build) o para un --check posterior.
#   - 3) --selftest: batería interna (bash -n del propio motor, carga del perfil
#     y de contradicciones, herramientas imprescindibles) + harness funcional
#     de la suite ($SCRIPT_DIR/tests/selftest.sh) cuando existe.
#   - 4) --publish-repo / CIZEN_PUBLISH_REPO: tras instalar con éxito, copia el
#     .pkg.tar.zst a un repo local pacman (default /var/lib/kernel-update/repo,
#     db "cizen-linux") vía repo-add, para que las VMs libvirt puedan instalarlo
#     con pacman (file:// o por red). Fallo suave; requiere pacman-contrib.
#   - 5) --btf / CIZEN_BTF=1: fuerza CONFIG_DEBUG_INFO+DEBUG_INFO_BTF (+ los
#     marca como esperados en la auditoría). Pide instalar pahole si falta
#     (opcional); degrade a sin-BTF si no se puede.
#   - 6) --clang / CIZEN_CLANG=1: build LLVM/clang (LLVM=1, ld.lld). Si falta
#     clang o lld → warning y build GCC. Combinable con ccache.
#   - 7) --changelog: mantenimiento — bumpea cabecera+SCRIPT_VERSION y añade un
#     borrador de changelog al top con el diff --stat del espejo git (si existe).
#     NO commit: el texto lo completa el mantenedor.
#   - El resumen final muestra ahora también Parches/BTF/Toolchain y el repo
#     local publicado; write_verify_signature graba patches/btf/clang para que
#     kernel-update-verify.sh los compruebe post-boot.
#
# CHANGELOG v27.23.0 (operativa: diff de config, post-boot, rollback, snapshots — 2026-09-20)
#   - 1) Config-diff: tras validar, se compara la config efectiva nueva vs la del
#     kernel EN EJECUCIÓN (/proc/config.gz) teniendo en cuenta los renames del
#     perfil (APPLIED_RENAMES) y se resumen cambiados/nuevos/retirados (máx 15
#     detalles). Primera señal de que el perfil realmente cambió algo.
#   - 2/6/8) Verificación post-boot NUEVA: script kernel-update-verify.sh +
#     unit de usuario (ver abajo) que tras cada arranque comprueba que el kernel
#     en ejecución cumple el perfil (OPTS_ENABLE/CRITICAL_OPTS/SETVAL/SETSTR +
#     estado BORE vs firma de build), compara el tiempo de arranque
#     (systemd-analyze) con el boot previo y escanea el journal del kernel del
#     boot actual buscando patrones de regresión (oops/panic/GPU hang/hung task)
#     frente al boot anterior. Notifica discrepancias (~/.local/state/kernel-update/).
#   - 3) Rollback dual-kernel: antes de instalar, kernel-update.sh archiva el
#     kernel en ejecución (módulos + vmlinuz) en $ROLLBACK_DIR
#     (/var/lib/kernel-update/rollback, 1 copia). Nuevo
#     kernel-update-rollback.sh / comando krollback lo restaura y regenera la UKI.
#   - 4) Snapshot btrfs readonly de la raíz antes de instalar (subvol
#     .snapshots/@kernel-<versión>-<ts>). Auto si / es btrfs; desactivar con
#     CIZEN_SNAPSHOT=0. Fallo NO bloquea (warn).
#   - 5) Rama de seguimiento configurable: CIZEN_KERNEL_TRACK=stable (default)
#     | longterm (LTS mayor de releases.json; requiere jq; sin jq degrada a stable
#     con warning). Aplica a build/check-update y al notificador.
#   - 7) Informe final ampliado: desglose de tiempos (descarga+extracción,
#     config+validación, compilación, instalación+UKI) y estadísticas ccache
#     (hits/tamaño/ficheros) cuando hay ccache.
#   - No rompe el flujo anterior: todas las partes nuevas son aditivas, fallan
#     blando (warn) o son configurables con variables de entorno.
#
# CHANGELOG v27.22.4 (fix BORE en árbol reutilizado — 2026-09-19)
#   - Bug: tras cancelar una build BORE (Ctrl+C) el árbol tmpfs se conserva CON
#     el parche ya aplicado (kernel/sched/bore.c + fair.c toquetado). Al relanzar
#     `--bore`, apply_bore_patch() volvía a descargar el parche bueno y patch(1)
#     respondía "Reversed (or previously applied) patch detected" en el dry-run
#     (rc=1) → el motor degradaba a EEVDF vanilla pese a que el árbol SÍ lo lleva.
#   - Fix: detección de parche ya aplicado al inicio de apply_bore_patch() —
#     si `kernel/sched/bore.c` existe y `fair.c` contiene SCHED_BORE/burst, se
#     marca BORE_ENABLED=true y se continúa sin re-descargar ni re-aplicar.
#   - Verificado contra el árbol real conservado (bore.c=SI, fair.c marcado=SI).
#     `bash -n` OK.
#
# CHANGELOG v27.22.3 (fix falso error en índice de Kconfig — 2026-09-19)
#   - Bug: build_kconfig_symbol_index() construye su índice vía un
#     process-substitution `done < <(find | xargs grep | awk | sort -u)` que
#     hereda `set -Eeuo pipefail`. xargs parte la lista de Kconfig en lotes y un
#     lote cuyo grep no encuentra ningún `config`/`menuconfig` sale con status 1:
#     con pipefail el pipeline completo reporta error, el trap ERR del subshell
#     dispara `on_err` ("Error 1 ... sort -u") y aunque el `exit` del subshell no
#     aborta el script, queda un falso fallo + índice supuestamente truncado.
#     Reproducido: `xargs -n 1` + pipefail → rc=123 sin `|| true`; rc=0 con él.
#   - Fix: `sort -u || true` al final del pipeline interno. El índice se construye
#     leyendo el stream (input) del process-substitution, no por su exit status:
#     el rc legítimo de grep/xargs no debe disparar set -e, y un fallo REAL de
#     escalado (Kconfig ausente) sigue dejando el índice vacío sin enmascararse.
#   - Verificación: test con set -Eeuo pipefail + trap ERR → sin on_err, built=true,
#     índice 21717 símbolos, SCHED_BORE presente. `bash -n` OK.
#
# CHANGELOG v27.22.2 (fix descarga parche BORE huérfana — 2026-09-19)
#   - Bug: el intento 2 del parche BORE (upstream) volvía a usar el mismo
#     `--out` (bore-$br.patch) que el intento 1 (CachyOS). aria2c (--continue
#     + --allow-overwrite=false) no re-descarga un fichero existente: con el
#     tamaño coincidente lo daba por completo (contenido CachyOS) o lo
#     renombraba a bore-$br.1.patch (auto-file-renaming), dejando el parche
#     upstream bueno huérfano y validando siempre el CachyOS que no aplica.
#   - Fix doble: (a) `--auto-file-renaming=false` en download_file() (aria2c)
#     para que el nombre de salida sea SIEMPRE el `--out` pedido; (b) cada
#     intento BORE hace `rm -f` del destino antes de descargar, garantizando
#     contenido fresco y evitando el falso "completo" por tamaño coincidente.
#   - Verificado en vivo 2026-09-19 19:36: cachy 7.2-rc5 no aplica sobre
#     7.2.6 → degrade upstream correcto (40229 B, firelzrd) descargado pero
#     ignorado por el bug; con el fix aplica limpio y SCHED_BORE=y.
#
# CHANGELOG v27.22.1 (cancelar la build con Ctrl+C — 2026-09-19)
#   - timeout(1) sin --foreground creaba un grupo de procesos PROPIO para make,
#     aislado del grupo foreground de la terminal: Ctrl+C (SIGINT al grupo
#     foreground) llegaba solo al script y NO cancelaba la compilación.
#   - Fix: la invocación make ahora usa `timeout --foreground --signal=TERM
#     --kill-after=60s`, de modo que make (y sus sub-makes/gcc) heredan el
#     grupo de la terminal y puede cancelarse desde el teclado en cualquier
#     momento. make hace la limpieza de .o vía sus traps INT/TERM.
#
# CHANGELOG v27.22.0 (BORE scheduler opcional — 2026-09-19)
#   - Nuevo flag `--bore` / env CIZEN_ENABLE_BORE=1: aplica el parche BORE
#     (Burst-Oriented Response Enhancer) de CachyOS sobre el scheduler EEVDF,
#     priorizando por "burstiness" para mejorar la responsividad interactiva
#     (input/audio/gaming) con coste de equidad. Es OPCIONAL: sin el flag la
#     build es 100% vanilla como antes.
#   - El parche se descarga por rama X.Y del kernel objetivo desde
#     https://raw.githubusercontent.com/CachyOS/kernel-patches/master/
#     <rama>/sched/0001-bore-cachy.patch (p. ej. 7.2 → 7.2/sched/...). Si el
#     forward-port de CachyOS no aplica limpio sobre la release final X.Y.Z
#     (se regenera contra una RC), se degrada automáticamente al parche del
#     autor upstream 0001-bore.patch de la misma rama, que se mantiene por
#     release y aplica sobre la versión estable.
#   - Si la descarga falla, el parche no aplica limpio o sha/forma inválida →
#     warn y CONTINÚA con EEVDF vanilla (nunca rompe la build).
#   - Al aplicar, SCHED_BORE se fuerza a =y y se marca junto a MIN_BASE_SLICE_NS
#     como símbolos esperados en la auditoría (no ensucia kcheck ni aborta en
#     modo --strict). build_effective_arrays() se re-ejecuta tras el parche.
#   - Mantenimiento: CachyOS publica el parche por rama mayor; las bilds con
#     --bore quedan ligadas a la rama X.Y del objetivo (7.2.6 → 7.2). Si una
#     rama nueva no tiene parche, el motor degrada a vanilla con warning.
#   - Compatibilidad: el perfil v5.10.0 es compatible con BORE (HZ_1000 + IRQ_TIME_ACCOUNTING).
#
# CHANGELOG v27.21.17 (config base persistente dentro de la suite)
#   - Los linux-<versión>-cizen-v3.config (config base que find_latest_cizen_config
#     usa y que se promueve tras un build/check) dejan de leerse/escribirse en
#     $HOME: viven junto a los perfiles, en $SCRIPT_DIR/profiles (override
#     CIZEN_CONFIG_DIR). El directorio debe ser escribible por el usuario que
#     compila para poder promover la configuración.
#   - get_local_kernel_version(), find_latest_cizen_config() y las dos
#     promociones de FINAL_CONFIG usan CONFIG_DIR. promote_home_config pasa a
#     llamarse promote_base_config.
#
# CHANGELOG v27.21.15 (--absorb-rebels: rebeldes al perfil automáticamente)
#   - Nuevo flag --absorb-rebels: cuando la validación detecta símbolos de
#     OPTS_DISABLE que Kconfig conserva a =y/=m por dependencias internas
#     (depends on/select/defaults) y que aún no están en EXPECTED_REBELS,
#     los mueve de OPTS_DISABLE a EXPECTED_REBELS en el archivo de perfil
#     (con backup .bak-<ts> y validación bash -n previa a sustituir). Tras
#     editar, recarga el perfil, reconstruye los arrays efectivos y revalida
#     para que el mismo chequeo termine limpio y futuras ejecuciones no
#     reproduzcan los warnings.
#   - Extrae la construcción de EFF_* a build_effective_arrays() para poder
#     reconstruir los arrays efectivos tras un --absorb-rebels sin duplicar
#     lógica.
#
# CHANGELOG v27.21.14 (optimización de velocidad de compilación)
#   - MAKEFLAGS="-j$JOBS" global: los sub-makes (menú, headers, modules,
#     pacman-pkg) heredan la misma paralelidad que el make principal.
#   - CIZEN_BUILD_PRIORITY=normal: salta nice/ionice y compila a plena
#     prioridad (~20-40% más rápido en máquina seca; CPU-bound). Por
#     defecto sigue low (write tool usable durante el build).
#   - ccache tuning: base_dir=$HOME (hits independientes del cwd) y
#     compiler_check=content (hash del compilador, no del path); límite
#     de tamaño opcional vía CCACHE_MAX_SIZE.
#   - tmpfs de compilación montado con huge=advise (hugepages para los
#     temporales grandes de Kbuild).
#   - BUILD_TIMEOUT por defecto 3600s (antes 14400s); cubre una build
#     completa (~19 min cold / ~4 min warm) y aborta builds colgadas antes.
#
# CHANGELOG v27.21.13 (autoinstalación interactiva de dependencias)
#   - check_prerequisites() ya no solo aborta con "Falta dependencia": detecta
#     qué herramientas faltan, traduce cada comando a su paquete Arch (mapa
#     TOOL_PKG) y pregunta interactivamente antes de ejecutar
#     'sudo pacman -S --needed ...'. Si se acepta, reinstala y reverifica que
#     cada comando quede en PATH; si se rechaza o no hay terminal, aborta con
#     el comando exacto sugerido. Nunca se instala sin confirmación explícita.
#   - sudo, pacman y cizen-uki-sync no tienen paquete asociado (no se pueden
#     autoinstalar de forma sensata): siguen abortando con instrucciones.
#   - aria2c se sugiere activamente antes de la primera descarga, solo cuando
#     va a usarse (no con CIZEN_DOWNLOADER=wget ni con caché ya válida).
#     Declinarlo NO bloquea: se continúa con el wget de un hilo.
#   - CIZEN_NO_AUTOINSTALL=1 desactiva todo prompt y restaura el
#     comportamiento estricto previo (abortar si falta una requerida).
#   - jq sigue siendo opcional (fallback sed); no se exige ni se instala.
#
# CHANGELOG v27.21.16 (progreso de descarga silencioso)
#   - download_file() ya no imprime el "Download Progress Summary" de aria2c
#     cada segundo en TTY (spam). Intervalo nuevo vía CIZEN_DOWNLOAD_SUMMARY_INTERVAL:
#       0 (default)  = sin summary de progreso (--summary-interval=0)
#       N>0          = summary cada N segundos (solo si hay TTY)
#     Si no hay TTY sigue --quiet como antes. Convención idéntica a descargar.sh.
#
# CHANGELOG v27.21.12 (descarga paralela opcional con aria2c)
#   - Nuevo download_file(): usa aria2c (conexiones paralelas configurables vía
#     CIZEN_DOWNLOAD_PARALLEL, por defecto 4) cuando está instalado, y cae a
#     wget exacto si no lo está o si se fuerza CIZEN_DOWNLOADER=wget. Conserva
#     la semántica previa de reintentos/continuación, la detección de TTY para
#     el progreso y la limpieza de temporales .download-* al inicio y en EXIT.
#   - Un CDN que limita cada conexión por hilo (se observaron ~30 MB/s por
#     conexión en cdn.kernel.org frente a ~54 MB/s agregados con 4 hilos) ya no
#     acota la descarga del tarball a una única conexión. Si falta aria2c, el
#     flujo es idéntico al de v27.21.11 (wget clásico, un hilo).
#   - La firma PGP se obtiene con el mismo downloader: al ser un fichero
#     pequeño, aria2c no activa el paralelismo (queda por debajo de
#     --min-split-size) y el comportamiento es equivalente.
#
# CHANGELOG v27.21.11 (endurecimiento de limpieza y selección de base)
#   - cleanup_old_source_trees() ya no elimina árboles de fuentes bajo un
#     directorio que NO esté montado como el tmpfs dedicado de compilación:
#     se evita un rm -rf destructivo si KERNEL_TMPFS_ROOT apunta (por error
#     o falta de revisión) a un directorio persistente con árboles linux-*.
#     En el flujo normal el tmpfs reutilizado sigue montado y la limpieza de
#     versiones antiguas actúa exactamente igual que antes.
#   - find_latest_cizen_config() selecciona la configuración Cizen de mayor
#     versión <= objetivo en vez de la más reciente por mtime: evita usar
#     como base una configuración de una versión MÁS nueva ya compilada
#     antes (que arrastra símbolos de una migración futura). Sin versión
#     explícita conserva el comportamiento de elegir la mayor disponible.
#   - get_kernel_org_latest_stable() usa jq cuando está disponible para
#     parsear releases.json, con el parsing sed existente como fallback:
#     robustez frente a cambios de formato del índice de kernel.org.
#   - Añade un preflight opcional de privilegios sudo (no bloqueante) que
#     comprueba mount/umount/find/stat/mkdir/cp/mv/rm/fuser/sync/pacman
#     antes de la compilación, para detectar sudoers restrictivos de forma
#     temprana en vez de fallar tras minutos de build en la instalación.
#
# CHANGELOG v27.21.10 (retirada de linux-upstream idempotente)
#   - install_kernel_package() ya no aborta la instalación cuando
#     `pacman -R linux-upstream` responde "target not found": pacman -Q lo
#     había visto instalado un instante antes, pero si para cuando se intenta
#     retirar ya no está, el objetivo de la migración (linux-upstream fuera
#     del sistema) ya se cumple. Solo se sigue tratando como fatal cualquier
#     otro motivo real de fallo en la retirada (permisos, dependencias, lock
#     de la base de datos). Evita cancelar la instalación de un paquete ya
#     compilado y verificado por una discrepancia de estado que no era un
#     fallo real.
#
# CHANGELOG v27.21.9 (verificación de tarball sin descompresión duplicada)
#   - Quita el xz -t redundante en la ruta de "tarball ya en caché": la
#     verificación de firma (xz -cd | gpg --verify, con pipefail activo) ya
#     cubre la misma garantía de integridad, así que ya no se descomprime el
#     tarball dos veces por ejecución. El chequeo xz -t tras una descarga
#     fresca se conserva igual, porque ahí sí sirve para fallar rápido antes
#     de bajar la firma.
#   - Añade una huella tamaño+mtime (linux-<versión>.tar.xz.verified-ok) para
#     no repetir la verificación criptográfica completa entre ejecuciones
#     distintas cuando el tarball y la firma no cambiaron desde la última vez
#     que se verificaron con éxito. Cualquier cambio real en cualquiera de
#     los dos archivos invalida la huella y fuerza verificación completa de
#     nuevo. cleanup_kernel_cache() conserva esta huella solo para la versión
#     objetivo, igual que ya hacía con el tarball y la firma.
#
# CHANGELOG v27.21.8 (sudo keep-alive interrumpible + sincronía de versión)
#   - Corrige sudo_keepalive_start(): el sleep de refresco ahora corre en
#     segundo plano y se espera con `wait`, para que el trap TERM/INT lo
#     interrumpa de inmediato. Antes, un sleep 60 en primer plano difería
#     el trap hasta que el propio sleep terminaba por sí solo (comportamiento
#     documentado de Bash), dejando una pausa de hasta 60s entre
#     "Configuración final guardada" y el resumen final de cada ejecución.
#   - Sincroniza la cabecera (banner) con SCRIPT_VERSION; quedaban desfasadas.
#
# CHANGELOG v27.21.6 (migración pacman + flujo kcheck/kbuild)
#   - Corrige la migración linux-upstream -> linux-cizen-v3 para pacman reales
#     que no soportan --resolve-conflicts=all: si el paquete legado está instalado,
#     se retira explícitamente justo antes de instalar el paquete Cizen ya validado.
#   - No toca /boot, presets ni pkgbase manualmente durante la migración.
#   - Añade timeout de 300 s al prompt de continuidad de kcheck para no retener
#     indefinidamente el lock global mientras una terminal queda abandonada.
#   - Unifica la política de terminal interactiva de confirm_build_after_check()
#     con confirm_newer_release().
#   - Evita promover $CONFIG_DIR/linux-<versión>-cizen-v3.config dos veces cuando kcheck
#     continúa a compilación; solo se promueve al finalizar la rama CHECK o después
#     de instalación + sincronización UKI.

#
#
# CHANGELOG v27.21.7 (timestamp real de compilación)
#   - Elimina el KBUILD_BUILD_TIMESTAMP fijo en 2001-01-01 que hacía que
#     uname -a mostrara una fecha artificial cuando ccache estaba activo.
#   - Mantiene ccache habilitado sin alterar la fecha/hora real de compilación.
#   - KBUILD_BUILD_TIMESTAMP solo se respeta si el usuario lo exporta
#     explícitamente antes de ejecutar el script.
#   - Genera paquetes Arch con pkgbase linux-cizen-v3 en lugar de linux-upstream.
#   - Mantiene KERNELRELEASE=VERSION-cizen-v3, separado del nombre de paquete.
#   - Hace que /usr/lib/modules/<release>/pkgbase contenga linux-cizen-v3 para que
#     mkinitcpio utilice linux-cizen-v3.preset.
#   - Declara conflicts/replaces/provides con linux-upstream como metadata de transición.
#   - Mantiene linux-upstream como fallback temporal para detectar la versión local.
#
#
# CHANGELOG v27.21.4 (kcheck con continuación opcional a compilación)
#   - Después de una validación exitosa de kcheck/--check, ofrece continuar
#     inmediatamente con la compilación del kernel validado.
#   - Enter y S/s continúan con la compilación; N/n finaliza limpiamente.
#   - Las respuestas inválidas se vuelven a solicitar para evitar decisiones
#     accidentales.
#   - En terminales no interactivas se conserva el comportamiento seguro de
#     detenerse después del chequeo, sin intentar compilar automáticamente.
#   - La configuración ya promovida y las fuentes preparadas se conservan
#     exactamente igual que antes.
#
#
# CHANGELOG v27.21.3 (limpieza de redundancias y consistencia)
#   - Sincroniza la cabecera con SCRIPT_VERSION=27.21.3.
#   - Elimina validaciones duplicadas de PROFILE_FILE ya realizadas antes de source.
#   - Elimina la carga de CONFIG_STATE innecesaria antes de aplicar scripts/config.
#   - Elimina reasignaciones idénticas de SRC/BUILD_MARKER tras preparar el tmpfs.
#   - Evita un trap RETURN temporal en do_rename().
#   - Conserva intacta la reaplicación incondicional del perfil sobre cualquier base seleccionada.
#
#

# CHANGELOG v27.21.1 (detección también con versión explícita)
#   - Cuando se especifica una versión explícita, se conserva exactamente esa
#     versión para mantener el comportamiento determinista, pero ahora se consulta
#     kernel.org y se avisa si existe una stable posterior.
#   - --check-update sigue consultando únicamente disponibilidad y no modifica nada.
#
# CHANGELOG v27.21.2 (selección interactiva de stable nueva)
#   - Cuando se solicita una versión explícita y kernel.org ofrece una stable
#     posterior, pregunta antes de descargar cuál versión compilar.
#   - Si se acepta, VERSION cambia a la release nueva y el flujo continúa de
#     forma natural con sus rutas, fuentes, configuración, build e instalación.
#   - Si se rechaza, se conserva exactamente la versión solicitada.
#   - Se elimina la doble notificación de "release nueva detectada".

# CHANGELOG v27.21.0 (agente de releases kernel.org)
#   - Consulta https://www.kernel.org/releases.json para detectar la última
#     release estable publicada, sin scrapear HTML ni depender de una rama fija.
#   - Sin versión explícita, compara la stable remota con el kernel Cizen instalado
#     y solo inicia una compilación cuando existe una release nueva.
#   - Añade --check-update para consultar disponibilidad sin modificar ni compilar.
#   - Las versiones explícitas siguen siendo totalmente deterministas y no se
#     solo sustituyen la versión solicitada tras confirmación interactiva.
#
# CHANGELOG v27.20.8 (cierre limpio del sudo keep-alive)
#   - Hace que el subshell de sudo keep-alive responda inmediatamente a TERM/INT,
#     evitando dejar temporalmente un sleep reparentado durante la limpieza.
#
# CHANGELOG v27.20.7 (ccache, integridad del perfil y trazabilidad)
#   - Pasa CC/HOSTCC explícitamente a Kbuild cuando ccache está disponible,
#     evitando depender de la precedencia de variables exportadas.
#   - Valida que el perfil externo pertenezca al usuario actual y no sea
#     escribible por grupo u otros usuarios antes de hacer source.
#   - Restaura y separa explícitamente la entrada del changelog v27.20.5.
#
# CHANGELOG v27.20.6 (robustez de resolución, preflight y consistencia de perfil)
#   - Corrige cualquier advertencia emitida por resolve_symbol() para que no
#     contamine su salida capturada por sustitución de comandos.
#   - Corrige SCRIPT_VERSION para que el banner/runtime identifique esta release.
#   - Añade validación temprana de contradicciones entre ENABLE/DISABLE y entre
#     listas de estado y SETVAL/SETSTR, después de aplicar renombres.
#   - Añade bc, bison y flex al preflight porque forman parte de los requisitos
#     de compilación documentados por Kbuild.
#   - Mantiene el timeout de build, el glob correcto y el progreso wget TTY-aware.
#
# CHANGELOG v27.20.5 (limpieza de glob, wget TTY-aware y timeout de compilación)
#   - Corrige la expansión de glob de residuos .download-* y .partial-* para
#     que nullglob encuentre y elimine temporales interrumpidos correctamente.
#   - Usa --show-progress de wget solo cuando stderr es un TTY; los logs no
#     interactivos quedan limpios y deterministas.
#   - Añade BUILD_TIMEOUT configurable (14400 s por defecto) con timeout(1),
#     TERM y --kill-after para abortar builds colgadas sin dejar procesos hijos.
#
# CHANGELOG v27.20.4 (SETSTR en resumen y preflight de cizen-uki-sync)
#   - Separa warnings de DISABLE de fallos FATALES SETVAL/SETSTR.
#   - Imprime siempre las desactivaciones que Kconfig conserva y --strict las
#     trata como warnings reales.
#   - Construye un índice único de símbolos Kconfig para evitar búsquedas
#     grep -R repetidas por símbolo.
#   - Detecta transacciones de pacman mediante fuser, incluyendo backends como
#     pamac-daemon y otros gestores que no estén en una lista fija.
#   - Revalida el lock justo antes de eliminarlo y distingue locks previos al
#     intento de instalación de locks creados durante el propio intento.
#
# CHANGELOG v27.20.0 (perfil v5.1 + resolución real de Kconfig)
#   - La existencia de símbolos se consulta en los Kconfig reales del árbol
#     objetivo, no en la presencia previa dentro de .config.
#   - SETVAL/SETSTR del perfil son requisitos estrictos: si Kconfig no puede
#     materializarlos en el resultado final, la validación es FATAL.
#   - Se preservan los comportamientos de limpieza, tmpfs y cache definidos
#     en las versiones anteriores.
#
# OBJETIVOS
#   - Mantener la lógica Cizen existente.
#   - Ser idempotente: repetir el mismo comando no debe degradar el estado.
#   - Usar Cizen como base y /proc/config.gz como fallback.
#   - Aplicar solo poda razonablemente segura para este hardware.
#   - Dejar que Kconfig resuelva dependencias.
#   - Auditar listnewconfig + olddefconfig.
#   - Distinguir FATAL / WARNING / REBELDE ESPERADO.
#   - No permitir --force para saltarse errores críticos.
#   - Evitar instalar un paquete viejo por error.
#   - Conservar el tarball y el estado de trabajo útil si la compilación falla; no generar logs/reportes persistentes fuera del árbol de trabajo.
#   - No crear backups persistentes de .config; la única configuración estable
#     persistente es $CONFIG_DIR/linux-<versión>-cizen-v3.config, promovida atómicamente.
#   - Cargar y validar siempre el perfil externo, pero no repetir su resumen si no cambió.
#   - Limpiar el cache persistente de kernel para conservar únicamente el tarball y su firma de la versión objetivo, eliminando artefactos antiguos y residuos de descarga.
#   - Mantener en el tmpfs de compilación únicamente el árbol de fuentes de la versión objetivo más reciente.
#   - Mantener en el cache persistente solo el tarball/firma de la versión más nueva y eliminar residuos .bad/.download/.partial.
#   - Mantener en el tmpfs de compilación solo el árbol de fuentes de la versión más nueva.
#   - No crear archivos auxiliares .base.config/.newconfig/.olddefconfig/.diffconfig.
#     Las salidas de Kconfig se mantienen en memoria; no se generan reportes auxiliares.
#   - Mostrar únicamente cambios reales del perfil desde la última ejecución registrada.
#   - Tampoco repetir los conteos del perfil en la fase "Preparando" si no hubo cambios.
#
# USO
#   ./kernel-update.sh [versión]
#   kcheck [versión]              # alias/enlace al mismo script; sin versión usa stable actual
#   kbuild [versión]              # alias/enlace al mismo script; sin versión usa autodetección
#   ./kernel-update.sh --check-update
#   ./kernel-update.sh [versión] --check
#   ./kernel-update.sh <versión> --strict
#   ./kernel-update.sh <versión> --absorb-rebels
#   ./kernel-update.sh <versión> --force
#   ./kernel-update.sh <versión> --keep-src
#   ./kernel-update.sh <versión> --no-prune                  # sin poda de módulos
#   CIZEN_KEEP_MODULES="kvm_intel,vfio_pci" ./kernel-update.sh <versión>  # módulos extra a conservar en la poda
#   ./kernel-update.sh <versión> --patch bore                 # framework de parches
#   ./kernel-update.sh <versión> --bore                       # alias de --patch bore
#   CIZEN_PATCHES="bore" ./kernel-update.sh <versión>         # parches por env
#   ./kernel-update.sh <versión> --btf                        # CONFIG_DEBUG_INFO_BTF=y
#   ./kernel-update.sh <versión> --clang                      # build LLVM/clang (opt-in)
#   ./kernel-update.sh <versión> --menuconfig                 # editar config con menuconfig
#   ./kernel-update.sh [versión] --publish-repo               # publicar pkg a repo pacman local
#   CIZEN_PUBLISH_REPO=/srv/repo ./kernel-update.sh <versión> # dónde publicar (default /var/lib/kernel-update/repo)
#   ./kernel-update.sh --selftest                             # autoevaluación interna
#   ./kernel-update.sh --changelog                            # bump versión + borrador de changelog
#   JOBS=3 ./kernel-update.sh <versión>
#   CIZEN_DOWNLOAD_PARALLEL=8 ./kernel-update.sh <versión>   # conexiones paralelas (aria2c)
#   CIZEN_DOWNLOADER=wget ./kernel-update.sh <versión>       # fuerza el wget clásico
#   CIZEN_NO_AUTOINSTALL=1 ./kernel-update.sh <versión>      # sin prompts de instalación
#   KERNEL_BUILD_ROOT=/tmp/kbuild ./kernel-update.sh <versión>
#   ./kernel-update.sh --rename VIEJO=NUEVO
#   ./kernel-update.sh --list-renames
#   CIZEN_KERNEL_TRACK=longterm ./kernel-update.sh   # seguir LTS mayor en vez de stable
#   CIZEN_SNAPSHOT=0 ./kernel-update.sh              # sin snapshot btrfs previo
#   CIZEN_ROLLBACK_DIR=/ruta ./kernel-update.sh      # dónde guardar el archivo de rollback
#   CIZEN_VERIFY_STATE_DIR=/ruta                     # estado del verificador post-boot
#
# NOTAS DE PRODUCCIÓN
#   - --force NO ignora fallos críticos ni de auditoría Kconfig. Su único
#     efecto es permitir reinstalar un pkgrel igual o menor al ya instalado
#     (ver el chequeo de INSTALLED_VERSION más abajo).
#   - --keep-src no tiene efecto: las fuentes siempre se conservan en el
#     tmpfs entre ejecuciones para reutilizarse. Se mantiene por
#     compatibilidad con invocaciones existentes.
#   - Usa un tmpfs anidado de 10 GiB bajo /tmp para el árbol de compilación; el montaje /tmp existente se respeta.
#   - Si el árbol objetivo ya existe, usa KERNEL_TMPFS_EXISTING_SRC_MIN_FREE_MB
#     (2048 MB por defecto) como margen incremental para reutilización.
#   - Mantiene el timestamp sudo durante builds largas sin pedir contraseña en
#     segundo plano; si el ticket caduca, el keep-alive se detiene de forma segura.
#   - El tmpfs de build usa exec (necesario para generar/ejecutar herramientas host); /tmp del sistema sigue noexec.
#   - Kconfig es la autoridad final sobre dependencias.
#   - KVM_SMM es crítico para el uso QEMU/OVMF del equipo.
#   - LOCK_FILE es deliberadamente global y NO se deriva de KERNEL_BUILD_ROOT:
#     solo puede instalarse un kernel a la vez en este sistema, sin importar
#     con qué KERNEL_BUILD_ROOT se haya lanzado cada ejecución.
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Salida de herramientas predecible para validaciones y logs.
export LC_ALL=C

SCRIPT_VERSION="27.24.4"
PROFILE="cizen-optiplex7050"
LOCALVERSION_SUFFIX="-cizen-v3"
# Nombre del paquete Arch y pkgbase Cizen. El KERNELRELEASE seguirá siendo
# VERSION-cizen-v3; este pkgbase es el que mkinitcpio usa para nombrar el preset.
CIZEN_PKGBASE="linux-cizen-v3"
LEGACY_PKGBASE="linux-upstream"

RENAME_MAP_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/kernel-update/rename-map.conf"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# Config base persistente (linux-<versión>-cizen-v3.config): por defecto junto
# a los perfiles, dentro de la propia suite. Debe ser escribible por el usuario
# que compila (se promueve tras un build/check exitoso).
CONFIG_DIR="${CIZEN_CONFIG_DIR:-$SCRIPT_DIR/profiles}"
PROFILE_FILE=""

# El perfil es externo al motor. Buscamos primero la ubicación explícita y
# después las ubicaciones estándar de una instalación manual o empaquetada.
PROFILE_CANDIDATES=(
  "${CIZEN_PROFILE_FILE:-}"
  "$SCRIPT_DIR/profiles/cizen-optiplex7050.conf"
  "$SCRIPT_DIR/cizen-optiplex7050.conf"
  "$HOME/.config/kernel-update/profiles/cizen-optiplex7050.conf"
  "$HOME/.config/kernel-update/cizen-optiplex7050.conf"
)
for _candidate in "${PROFILE_CANDIDATES[@]}"; do
  if [ -n "$_candidate" ] && [ -f "$_candidate" ]; then
    PROFILE_FILE="$_candidate"
    break
  fi
done
unset _candidate
# KERNEL_BUILD_ROOT sigue siendo la raíz persistente para el tarball/cache.
# El árbol de compilación se coloca durante la ejecución en un tmpfs dedicado.
KERNEL_BUILD_ROOT="${KERNEL_BUILD_ROOT:-$HOME/.cache/kernel-kbuild}"
# /tmp ya es tmpfs en este sistema, pero está montado noexec. Creamos un
# tmpfs hijo con exec exclusivamente para el árbol de compilación.
TMPFS_SIZE="${KERNEL_TMPFS_SIZE:-10G}"
TMPFS_MIN_FREE_MB="${KERNEL_TMPFS_MIN_FREE_MB:-4096}"
TMPFS_EXISTING_SRC_MIN_FREE_MB="${KERNEL_TMPFS_EXISTING_SRC_MIN_FREE_MB:-2048}"
TMPFS_ROOT="${KERNEL_TMPFS_ROOT:-/tmp/cizen-kernel-build}"
TMPFS_MOUNTED=false
TMPFS_CREATED_BY_SCRIPT=false
# Deliberadamente NO derivado de $KERNEL_BUILD_ROOT: el lock es global a
# propósito, porque solo puede instalarse un kernel a la vez en este
# sistema sin importar con qué KERNEL_BUILD_ROOT se lance cada ejecución.
LOCK_FILE="${KERNEL_UPDATE_LOCK:-$HOME/.cache/kernel-kbuild/kernel-update.lock}"

VERSION=""
PKGREL=""
PKGVER_BASE=""
CHECK_ONLY=false
FORCE=false
STRICT=false
ABSORB_REBELS=false
KEEP_SRC=false
BORE_ENABLED=false
DO_RENAME=false
RENAME_PAIR=""
DO_LIST=false
CHECK_UPDATE=false

# Poda de módulos (v27.25.0): tras empaquetar, se conservan únicamente los
# módulos que este hardware usa (ver podar-modulos.sh). 1=activada (default),
# 0=desactivada. La env CIZEN_PRUNE_MODULES también la controla; el flag
# --no-prune/--prune tiene prioridad (se procesan después de esta lectura).
PRUNE_MODULES="${CIZEN_PRUNE_MODULES:-1}"

# ── Framework de parches, BTF, clang y utilidades (v27.24.0) ──
# PATCH_NAMES: lista de parches de terceros solicitados (--patch / CIZEN_PATCHES
# / --bore). PATCHES_APPLIED: los que realmente se aplicaron en este run.
PATCH_REQUESTED=false
declare -a PATCH_NAMES=()
declare -a PATCHES_APPLIED=()
# Símbolos Kconfig que aportan los parches aplicados y BTF: entran en ENABLE y
# se reconocen como rebeldes esperados (no ensucian la auditoría ni --strict).
declare -a PATCH_ENABLE_ALL=() PATCH_REBEL_ALL=()
declare -A PATCH_KCONFIG_FILTER=()   # símbolos nuevos esperados de parches/BTF
BTF_REQUESTED=false
CLANG_REQUESTED=false
MENUCONFIG_REQUESTED=false
SELFTEST=false
DO_CHANGELOG=false
PUBLISH_REPO=false
PUBLISH_REPO_DIR=""
PUBLISH_REPO_MSG=""

# Rama de kernel.org a seguir: stable (default) o longterm/LTS mayor.
CIZEN_KERNEL_TRACK="${CIZEN_KERNEL_TRACK:-stable}"
[ "$CIZEN_KERNEL_TRACK" = "longterm" ] || [ "$CIZEN_KERNEL_TRACK" = "lts" ] || [ "$CIZEN_KERNEL_TRACK" = "stable" ] \
  || fatal "CIZEN_KERNEL_TRACK inválido: $CIZEN_KERNEL_TRACK (use stable, longterm o lts)."

# Rollback dual-kernel: directorio (root) donde se archiva el kernel previo al instalar.
ROLLBACK_DIR="${CIZEN_ROLLBACK_DIR:-/var/lib/kernel-update/rollback}"
# Snapshot btrfs readonly de la raíz antes de instalar: 1=auto (si / es btrfs), 0=off.
CIZEN_SNAPSHOT="${CIZEN_SNAPSHOT:-1}"
SNAPSHOT_SUBVOL=".snapshots"
# Estado del verificador post-boot (firma del build, tiempos).
VERIFY_STATE_DIR="${CIZEN_VERIFY_STATE_DIR:-$HOME/.local/state/kernel-update}"

# Marcas de tiempo de las fases para el informe final (feature 7).
T_ALL=0; T_DL=0; T_CFG=0; T_END=0

# Modo invocado por nombre: permite que kcheck/kbuild sean simples enlaces
# al mismo motor, sin wrappers que obliguen a pasar una versión.
COMMAND_NAME="$(basename -- "$0")"
case "$COMMAND_NAME" in
  kcheck) CHECK_ONLY=true ;;
  kbuild) CHECK_ONLY=false ;;
esac

calc_default_jobs() {
  local cpus ram_kb ram_gb ram_jobs
  cpus="$(nproc)"
  ram_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  ram_gb=$((ram_kb / 1024 / 1024))
  ram_jobs=$((ram_gb / 2))
  [ "$ram_jobs" -ge 1 ] || ram_jobs=1
  [ "$ram_jobs" -lt "$cpus" ] && echo "$ram_jobs" || echo "$cpus"
}
JOBS="${JOBS:-$(calc_default_jobs)}"

# MAKEFLAGS global: todos los sub-makes (menú, headers, modules, pkg)
# heredan la misma paralelidad que el make principal.
export MAKEFLAGS="-j$JOBS"

# ── Colores ─────────────────────────────────────────────────
if [ -t 1 ]; then
  R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'; C=$'\033[0;36m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; C=""; N=""
fi

log(){  printf '%s[%s]%s %s\n' "$B" "$(date +%H:%M:%S)" "$N" "$*"; }
ok(){   printf '%s  ✓%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s  ⚠%s %s\n' "$Y" "$N" "$*"; }
err(){  printf '%s  ✗%s %s\n' "$R" "$N" "$*" >&2; }
info(){ printf '%s  •%s %s\n' "$C" "$N" "$*"; }

fatal(){ err "$*"; exit 1; }

# Reducir la prioridad de CPU/I/O del build para mantener el escritorio usable.
# CIZEN_BUILD_PRIORITY=normal salta nice/ionice y compila a plena prioridad:
# la compilación del kernel es CPU-bound, por lo que nice/ionice solo
# alargan el build (~20-40%) sin beneficio si la máquina está seca.
# CIZEN_BUILD_PRIORITY lo define el usuario ANTES de ejecutar (export).
BUILD_PRIORITY="${CIZEN_BUILD_PRIORITY:-low}"
if [ "$BUILD_PRIORITY" = "normal" ]; then
  declare -a BUILD_PRIORITY_WRAP=()
  info "Compilación a plena prioridad (sin nice/ionice)"
else
  declare -a BUILD_PRIORITY_WRAP=()
  if command -v nice >/dev/null 2>&1; then
    BUILD_PRIORITY_WRAP+=(nice -n 10)
  fi
  if command -v ionice >/dev/null 2>&1; then
    BUILD_PRIORITY_WRAP+=(ionice -c 3)
  fi
fi

on_err() {
  local rc=$?
  err "Error $rc en línea ${BASH_LINENO[0]}: ${BASH_COMMAND}"
  err "La operación fue abortada; el árbol tmpfs se conserva para diagnóstico."
  exit "$rc"
}
trap on_err ERR

# ============================================================
# ARGUMENTOS
# ============================================================
while [ $# -gt 0 ]; do
  case "$1" in
    --check-update)
      CHECK_UPDATE=true; shift ;;
    --check)
      CHECK_ONLY=true; shift ;;
    --force)
      FORCE=true; shift ;;
    --strict)
      STRICT=true; shift ;;
    --absorb-rebels)
      ABSORB_REBELS=true; shift ;;
    --patch)
      PATCH_REQUESTED=true
      if [ -n "${2:-}" ] && [[ ! "$2" =~ ^-- ]]; then
        IFS=',' read -r -a __patchs <<< "$2"
        for __patchn in "${__patchs[@]:-}"; do [ -n "$__patchn" ] && PATCH_NAMES+=("$__patchn"); done
        unset __patchs __patchn
        shift 2
      else
        err "--patch requiere un nombre de parche (p. ej. bore). Todos: --patch <nombre>"
        exit 1
      fi ;;
    --patch=*)
      PATCH_REQUESTED=true
      IFS=',' read -r -a __patchs <<< "${1#--patch=}"
      for __patchn in "${__patchs[@]:-}"; do [ -n "$__patchn" ] && PATCH_NAMES+=("$__patchn"); done
      unset __patchs __patchn
      shift ;;
    --bore)
      PATCH_REQUESTED=true
      PATCH_NAMES+=(bore)
      shift ;;
    --btf)
      BTF_REQUESTED=true; shift ;;
    --clang)
      CLANG_REQUESTED=true; shift ;;
    --menuconfig)
      MENUCONFIG_REQUESTED=true; shift ;;
    --selftest)
      SELFTEST=true; shift ;;
    --publish-repo)
      PUBLISH_REPO=true; shift ;;
    --changelog)
      DO_CHANGELOG=true; shift ;;
    --keep-src)
      KEEP_SRC=true; shift ;;
    --no-prune)
      PRUNE_MODULES=0; shift ;;
    --prune)
      PRUNE_MODULES=1; shift ;;
    --list-renames)
      DO_LIST=true; shift ;;
    --rename)
      DO_RENAME=true
      if [ -n "${2:-}" ] && [[ ! "$2" =~ ^-- ]]; then
        RENAME_PAIR="$2"; shift 2
      else
        err "--rename requiere VIEJO=NUEVO"; exit 1
      fi ;;
    --rename=*)
      DO_RENAME=true
      RENAME_PAIR="${1#--rename=}"
      shift ;;
    --*)
      err "Opción desconocida: $1"
      exit 1 ;;
    *)
      if [ -n "$VERSION" ]; then
        err "Solo se puede especificar una versión. Ya existe: $VERSION"
        exit 1
      fi
      VERSION="$1"
      shift ;;
  esac
done

# Entorno para parches/BTF/clang (se suma a los flags; CIZEN_ENABLE_BORE
# sigue funcionando igual que antes como forma de pedir BORE).
if [ "${CIZEN_ENABLE_BORE:-0}" = "1" ]; then
  PATCH_NAMES+=(bore)
  PATCH_REQUESTED=true
fi
if [ -n "${CIZEN_PATCHES:-}" ]; then
  PATCH_REQUESTED=true
  IFS=',' read -r -a __patchs <<< "$CIZEN_PATCHES"
  for __patchn in "${__patchs[@]:-}"; do [ -n "$__patchn" ] && PATCH_NAMES+=("$__patchn"); done
  unset __patchs __patchn
fi
[ "${CIZEN_BTF:-0}" = "1" ] && BTF_REQUESTED=true
[ "${CIZEN_CLANG:-0}" = "1" ] && CLANG_REQUESTED=true
case "$PRUNE_MODULES" in
  0|1) ;;
  *) fatal "CIZEN_PRUNE_MODULES inválido: $PRUNE_MODULES (use 0 o 1)." ;;
esac
# Ruta al podador: en la suite instalada o junto al motor (preferencia a la env).
if [ -n "${CIZEN_PRUNE_SCRIPT:-}" ]; then
  PRUNER_SCRIPT="$CIZEN_PRUNE_SCRIPT"
else
  PRUNER_SCRIPT="$SCRIPT_DIR/podar-modulos.sh"
fi
[ -n "${CIZEN_PUBLISH_REPO:-}" ] && PUBLISH_REPO=true
PUBLISH_REPO_DIR="${CIZEN_PUBLISH_REPO:-/var/lib/kernel-update/repo}"

# Deduplicar PATCH_NAMES conservando el orden.
if [ "${#PATCH_NAMES[@]}" -gt 0 ]; then
  declare -A __seen=()
  declare -a __uniq=()
  for __patchn in "${PATCH_NAMES[@]}"; do
    [ -n "${__seen[$__patchn]:-}" ] && continue
    __seen["$__patchn"]=1
    __uniq+=("$__patchn")
  done
  unset __seen
  PATCH_NAMES=("${__uniq[@]}")
  unset __uniq __patchn
  if [ "${#PATCH_NAMES[@]}" -eq 0 ]; then
    PATCH_REQUESTED=false
  fi
fi

# ============================================================
# RENAME MAP
# ============================================================
declare -A RENAME_MAP=()

do_rename() {
  local pair="$1" old new tmp line found=false
  if [[ ! "$pair" =~ ^([A-Za-z0-9_]+)=([A-Za-z0-9_]+)$ ]]; then
    err "Formato inválido. Use: VIEJO=NUEVO"
    exit 1
  fi
  old="${BASH_REMATCH[1]}"
  new="${BASH_REMATCH[2]}"

  mkdir -p "$(dirname "$RENAME_MAP_FILE")"
  touch "$RENAME_MAP_FILE"
  tmp=$(mktemp "${RENAME_MAP_FILE}.XXXXXX")

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^${old}[[:space:]]*= ]]; then
      printf '%s=%s\n' "$old" "$new" >> "$tmp"
      found=true
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$RENAME_MAP_FILE"

  if [ "$found" = false ]; then
    printf '%s=%s\n' "$old" "$new" >> "$tmp"
  fi

  if ! mv -- "$tmp" "$RENAME_MAP_FILE"; then
    rm -f -- "$tmp"
    fatal "No se pudo actualizar el mapa de renombres: $RENAME_MAP_FILE"
  fi

  if [ "$found" = true ]; then
    ok "Mapa actualizado: $old → $new"
  else
    ok "Mapa añadido: $old → $new"
  fi
  cat "$RENAME_MAP_FILE"
}

load_rename_map() {
  RENAME_MAP=()
  [ -f "$RENAME_MAP_FILE" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*([A-Za-z0-9_]+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      RENAME_MAP["$key"]="$val"
    fi
  done < "$RENAME_MAP_FILE"
}

resolve_symbol() {
  local sym="$1" next
  local -A seen=()
  while [ -n "${RENAME_MAP[$sym]:-}" ]; do
    if [ -n "${seen[$sym]:-}" ]; then
      warn "Ciclo detectado en RENAME_MAP para '$sym'; se detiene la resolución." >&2
      break
    fi
    seen["$sym"]=1
    next="${RENAME_MAP[$sym]}"
    sym="$next"
  done
  printf '%s\n' "$sym"
}

if [ "$DO_LIST" = true ]; then
  load_rename_map
  if [ "${#RENAME_MAP[@]}" -eq 0 ]; then
    echo "El mapa de renombres está vacío o no existe: $RENAME_MAP_FILE"
  else
    echo "── Mapa de renombres (${#RENAME_MAP[@]} entradas) ──"
    while IFS= read -r key; do
      printf '  %s → %s\n' "$key" "${RENAME_MAP[$key]}"
    done < <(printf '%s\n' "${!RENAME_MAP[@]}" | sort)
  fi
  exit 0
fi

if [ "$DO_RENAME" = true ]; then
  do_rename "$RENAME_PAIR"
  exit 0
fi

if [ -n "$VERSION" ] && [ "$CHECK_UPDATE" = true ]; then
  err "--check-update no acepta una versión explícita."
  exit 1
fi

if [ -n "$VERSION" ]; then
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
    err "Versión inválida: $VERSION"
    err "Use una release oficial de kernel.org en formato X.Y o X.Y.Z; ejemplo: 7.2.2"
    exit 1
  fi

  # kernel.org publica la release base X.Y sin '.0'. Canonicalizamos X.Y.0 -> X.Y.
  if [[ "$VERSION" =~ ^([0-9]+\.[0-9]+)\.0$ ]]; then
    warn "Normalizando release X.Y.0 de kernel.org: $VERSION -> ${BASH_REMATCH[1]}"
    VERSION="${BASH_REMATCH[1]}"
  fi
fi

if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  err "JOBS debe ser un entero positivo: JOBS=3"
  exit 1
fi

# ============================================================
# AGENTE DE RELEASES KERNEL.ORG
# ============================================================
KERNEL_RELEASES_JSON_URL="${KERNEL_RELEASES_JSON_URL:-https://www.kernel.org/releases.json}"

version_is_valid() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]]
}

version_gt() {
  local a="$1" b="$2" first second
  first="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)"
  [ "$first" = "$b" ] && [ "$a" != "$b" ]
}

get_local_kernel_version() {
  local installed path base candidate="" best_local_version=""

  # Primero consultamos el paquete Cizen actual. Durante la migración también
  # aceptamos linux-upstream como referencia local para no perder la detección
  # de la versión instalada antes del primer paquete linux-cizen-v3.
  local pkgbase installed_pkg
  for pkgbase in "$CIZEN_PKGBASE" "$LEGACY_PKGBASE"; do
    if pacman -Q "$pkgbase" >/dev/null 2>&1; then
      installed_pkg="$pkgbase"
      installed="$(pacman -Q "$installed_pkg" | awk 'NR==1 {print $2}')"
      if [[ "$installed" =~ ^([0-9]+\.[0-9]+([.][0-9]+)?)_cizen_v3-[0-9]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
      elif [[ "$installed" =~ ^([0-9]+\.[0-9]+([.][0-9]+)?)-[0-9]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
      fi
    fi
  done

  shopt -s nullglob
  for path in "$CONFIG_DIR"/linux-*-cizen-v3.config; do
    base="$(basename -- "$path")"
    if [[ "$base" =~ ^linux-([0-9]+\.[0-9]+([.][0-9]+)?)-cizen-v3\.config$ ]]; then
      candidate="${BASH_REMATCH[1]}"
      if [ -z "$best_local_version" ] || version_gt "$candidate" "$best_local_version"; then
        best_local_version="$candidate"
      fi
    fi
  done
  shopt -u nullglob
  printf '%s\n' "${best_local_version:-}"
}

get_kernel_org_latest_stable() {
  local json latest="" track
  json="$(wget -qO- --timeout=30 --tries=2 "$KERNEL_RELEASES_JSON_URL")" || return 1
  track="${CIZEN_KERNEL_TRACK:-stable}"

  case "$track" in
    longterm|lts)
      # releases.json: cada release estable lleva su moniker. La mayor con
      # moniker longterm/lts es la que se sigue. Requiere jq; sin jq se degrada
      # a latest_stable con warning (documentado en cabecera).
      if command -v jq >/dev/null 2>&1; then
        latest="$(printf '%s\n' "$json" | jq -r '[.releases[] | select((.moniker // "" | ascii_downcase | test("longterm|lts"))) | .version] | sort_by(. | split(".") | map(tonumber)) | last // empty' 2>/dev/null || true)"
      fi
      if [ -z "$latest" ]; then
        warn "CIZEN_KERNEL_TRACK=longterm requiere jq (o no hay release LTS en releases.json); se usa latest_stable."
      fi
      ;;
    *)
      # jq es la vía preferida cuando está disponible; el parsing sed se conserva
      # como fallback para sistemas sin jq y cubre el esquema actual de kernel.org.
      if command -v jq >/dev/null 2>&1; then
        latest="$(printf '%s\n' "$json" | jq -r '.latest_stable.version // empty' 2>/dev/null || true)"
      fi
      ;;
  esac

  if [ -z "$latest" ]; then
    latest="$(printf '%s\n' "$json" | tr '\n' ' ' | sed -n 's/.*"latest_stable"[[:space:]]*:[[:space:]]*{[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^" ]*\)"[[:space:]]*}.*/\1/p')"
  fi
  version_is_valid "$latest" || return 1
  printf '%s\n' "$latest"
}

resolve_latest_release() {
  local latest local_version track_txt
  latest="$(get_kernel_org_latest_stable)" || fatal "No se pudo consultar la release estable de kernel.org: $KERNEL_RELEASES_JSON_URL"
  REMOTE_STABLE_VERSION="$latest"

  local_version="$(get_local_kernel_version)"
  LOCAL_KERNEL_VERSION="$local_version"

  case "${CIZEN_KERNEL_TRACK:-stable}" in
    longterm|lts) track_txt="(longterm LTS)" ;;
    *) track_txt="(stable)" ;;
  esac

  if [ -n "$local_version" ]; then
    if version_gt "$latest" "$local_version"; then
      ok "Nueva release $track_txt detectada: $local_version → $latest"
    else
      ok "Kernel Cizen ya está en $local_version; kernel.org $track_txt: $latest"
    fi
  else
    info "kernel.org $track_txt detectado: $latest (sin versión Cizen instalada como referencia)"
  fi
}

# ============================================================
# RUTAS / ESTADO
# ============================================================
MAJOR=""
# TARBALL/SRC/URL se calculan después de resolver VERSION.
TARBALL=""
SRC=""
URL=""

TS="$(date +%Y%m%d-%H%M%S)"
BUILD_MARKER="$TMPFS_ROOT/.build-marker-$TS"
NEWCONFIG_OUTPUT=""
OLDCONFIG_OUTPUT=""

REMOTE_STABLE_VERSION=""
LOCAL_KERNEL_VERSION=""

# ============================================================
# PERFIL EXTERNO
# ============================================================
declare -A EXPECTED_REBEL_SET=()

# IMPORTANTE: el perfil debe ser sourceado en el ámbito global.
# Si se hace `source` dentro de una función, un `declare -a/-A` del perfil
# puede quedar local a esa función y desaparecer al retornar, produciendo
# falsos 0/0 en la preparación y validación.
load_profile() {
  local _name _decl _r
  for _name in OPTS_ENABLE OPTS_DISABLE OPTS_SETVAL OPTS_SETSTR CRITICAL_OPTS EXPECTED_REBELS; do
    if ! declare -p "$_name" >/dev/null 2>&1; then
      fatal "Perfil inválido: falta $_name en '$PROFILE_FILE'"
    fi
  done

  for _name in OPTS_ENABLE OPTS_DISABLE CRITICAL_OPTS EXPECTED_REBELS; do
    _decl="$(declare -p "$_name")"
    [[ "$_decl" == "declare -a "* ]] || fatal "Perfil inválido: $_name debe ser un array indexado en '$PROFILE_FILE'"
  done

  for _name in OPTS_SETVAL OPTS_SETSTR; do
    _decl="$(declare -p "$_name")"
    [[ "$_decl" == "declare -A "* ]] || fatal "Perfil inválido: $_name debe ser un array asociativo (declare -A) en '$PROFILE_FILE'"
  done

  EXPECTED_REBEL_SET=()
  for _r in "${EXPECTED_REBELS[@]}"; do EXPECTED_REBEL_SET["$_r"]=1; done

  local _enable_n _disable_n _setval_n _setstr_n _critical_n _rebels_n
  _enable_n="${#OPTS_ENABLE[@]}"
  _disable_n="${#OPTS_DISABLE[@]}"
  _setval_n="${#OPTS_SETVAL[@]}"
  _setstr_n="${#OPTS_SETSTR[@]}"
  _critical_n="${#CRITICAL_OPTS[@]}"
  _rebels_n="${#EXPECTED_REBELS[@]}"

  # Validación fuerte: este perfil de producción nunca debe aceptarse vacío.
  [ "$_enable_n" -gt 0 ] || fatal "Perfil inválido: OPTS_ENABLE está vacío en '$PROFILE_FILE'"
  [ "$_disable_n" -gt 0 ] || fatal "Perfil inválido: OPTS_DISABLE está vacío en '$PROFILE_FILE'"
  [ "$_setval_n" -gt 0 ] || fatal "Perfil inválido: OPTS_SETVAL está vacío en '$PROFILE_FILE'"
  [ "$_setstr_n" -gt 0 ] || fatal "Perfil inválido: OPTS_SETSTR está vacío en '$PROFILE_FILE'"
  [ "$_critical_n" -gt 0 ] || fatal "Perfil inválido: CRITICAL_OPTS está vacío en '$PROFILE_FILE'"

  # La validación y la carga siempre ocurren, pero el resumen no se repite en
  # cada ejecución. Guardamos únicamente un estado canónico del perfil (no es
  # un backup de .config) para poder detectar altas, bajas y cambios reales.
  PROFILE_STATE_DIR="${CIZEN_PROFILE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/kernel-update}"
  PROFILE_STATE_FILE="$PROFILE_STATE_DIR/profile-${PROFILE}.state"

  profile_state_dump() {
    local _k
    {
      printf '%s\n' '[ENABLE]'
      printf '%s\n' "${OPTS_ENABLE[@]}" | sed '/^$/d' | sort
      printf '%s\n' '[DISABLE]'
      printf '%s\n' "${OPTS_DISABLE[@]}" | sed '/^$/d' | sort
      printf '%s\n' '[SETVAL]'
      for _k in "${!OPTS_SETVAL[@]}"; do printf '%s=%s\n' "$_k" "${OPTS_SETVAL[$_k]}"; done | sort
      printf '%s\n' '[SETSTR]'
      for _k in "${!OPTS_SETSTR[@]}"; do printf '%s=%q\n' "$_k" "${OPTS_SETSTR[$_k]}"; done | sort
      printf '%s\n' '[CRITICAL]'
      printf '%s\n' "${CRITICAL_OPTS[@]}" | sed '/^$/d' | sort
      printf '%s\n' '[REBELS]'
      printf '%s\n' "${EXPECTED_REBELS[@]}" | sed '/^$/d' | sort
    }
  }

  report_profile_changes() {
    local current_file="$1" previous_file="$2"
    local current_section="" line key value
    local -A old_lines=() new_lines=()

    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^\[(.*)\]$ ]]; then
        current_section="${BASH_REMATCH[1]}"
        continue
      fi
      [ -n "$current_section" ] || continue
      [ -n "$line" ] || continue
      old_lines["$current_section|$line"]=1
    done < "$previous_file"

    current_section=""
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^\[(.*)\]$ ]]; then
        current_section="${BASH_REMATCH[1]}"
        continue
      fi
      [ -n "$current_section" ] || continue
      [ -n "$line" ] || continue
      new_lines["$current_section|$line"]=1
    done < "$current_file"

    local changed=false section
    for section in ENABLE DISABLE CRITICAL REBELS; do
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ -z "${old_lines["$section|$line"]:-}" ]; then
          printf '  + [%s] %s\n' "$section" "$line"
          changed=true
        fi
      done < <(awk -v s="[$section]" '$0==s{f=1;next} /^\[[^]]+\]$/{f=0} f && NF{print}' "$current_file")

      while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ -z "${new_lines["$section|$line"]:-}" ]; then
          printf '  - [%s] %s\n' "$section" "$line"
          changed=true
        fi
      done < <(awk -v s="[$section]" '$0==s{f=1;next} /^\[[^]]+\]$/{f=0} f && NF{print}' "$previous_file")
    done

    # SETVAL / SETSTR se muestran como cambios de valor y no como una baja+alta.
    for section in SETVAL SETSTR; do
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        key="${line%%=*}"
        value="${line#*=}"
        if [ -z "${old_lines["$section|$line"]:-}" ]; then
          local found_old="" old_line
          while IFS= read -r old_line; do
            [ -n "$old_line" ] || continue
            if [[ "$old_line" == "$key="* ]]; then found_old="${old_line#*=}"; break; fi
          done < <(awk -v s="[$section]" '$0==s{f=1;next} /^\[[^]]+\]$/{f=0} f && NF{print}' "$previous_file")
          if [ -n "$found_old" ]; then
            printf '  ~ [%s] %s: %s → %s\n' "$section" "$key" "$found_old" "$value"
          else
            printf '  + [%s] %s=%s\n' "$section" "$key" "$value"
          fi
          changed=true
        fi
      done < <(awk -v s="[$section]" '$0==s{f=1;next} /^\[[^]]+\]$/{f=0} f && NF{print}' "$current_file")

      while IFS= read -r line; do
        [ -n "$line" ] || continue
        key="${line%%=*}"
        if [ -z "${new_lines["$section|$line"]:-}" ]; then
          # Si la clave no existe en el perfil nuevo, informar la eliminación.
          local still_present=false current_line
          while IFS= read -r current_line; do
            [ -n "$current_line" ] || continue
            if [[ "$current_line" == "$key="* ]]; then still_present=true; break; fi
          done < <(awk -v s="[$section]" '$0==s{f=1;next} /^\[[^]]+\]$/{f=0} f && NF{print}' "$current_file")
          if [ "$still_present" = false ]; then
            printf '  - [%s] %s\n' "$section" "$line"
            changed=true
          fi
        fi
      done < <(awk -v s="[$section]" '$0==s{f=1;next} /^\[[^]]+\]$/{f=0} f && NF{print}' "$previous_file")
    done

    [ "$changed" = true ]
  }

  show_profile_status() {
    local current_file tmp_new changed=false
    mkdir -p "$PROFILE_STATE_DIR"
    tmp_new="$(mktemp "$PROFILE_STATE_DIR/.profile.XXXXXX")"
    profile_state_dump > "$tmp_new"

    if [ ! -f "$PROFILE_STATE_FILE" ]; then
      echo
      PROFILE_CHANGED=true
      ok "Perfil registrado por primera vez: $PROFILE_FILE"
      info "Perfil: ENABLE=$_enable_n DISABLE=$_disable_n SETVAL=$_setval_n SETSTR=$_setstr_n CRITICAL=$_critical_n REBELS=$_rebels_n"
      mv -f -- "$tmp_new" "$PROFILE_STATE_FILE"
      return 0
    fi

    if cmp -s "$PROFILE_STATE_FILE" "$tmp_new"; then
      rm -f -- "$tmp_new"
      return 0
    fi

    PROFILE_CHANGED=true
    echo
    log "Perfil actualizado: $PROFILE_FILE"
    if ! report_profile_changes "$tmp_new" "$PROFILE_STATE_FILE"; then
      warn "El perfil cambió, pero no se pudieron calcular diferencias legibles; se conserva el nuevo estado."
    fi
    info "Nuevo total: ENABLE=$_enable_n DISABLE=$_disable_n SETVAL=$_setval_n SETSTR=$_setstr_n CRITICAL=$_critical_n REBELS=$_rebels_n"
    mv -f -- "$tmp_new" "$PROFILE_STATE_FILE"
  }

  PROFILE_CHANGED=false
  show_profile_status
}

# Cargar el perfil FUERA de una función para conservar el alcance global de
# los arrays declarados mediante `declare -a` y `declare -A`.
[ -n "$PROFILE_FILE" ] || fatal "No se encontró el perfil Cizen. Use CIZEN_PROFILE_FILE=/ruta/cizen-optiplex7050.conf o instale el perfil junto al script en profiles/."
[ -f "$PROFILE_FILE" ] || fatal "No existe el perfil Cizen: $PROFILE_FILE"

# El perfil externo se ejecuta con `source`, así que debe estar bajo control
# del usuario actual y no ser escribible por grupo u otros usuarios.
_pf_uid="$(stat -c '%u' "$PROFILE_FILE" 2>/dev/null || echo -1)"
_pf_mode="$(stat -c '%a' "$PROFILE_FILE" 2>/dev/null || echo 000)"
[ "$_pf_uid" = "$(id -u)" ] || fatal "El perfil '$PROFILE_FILE' no pertenece al usuario actual (uid=$_pf_uid)."
case "${_pf_mode: -2}" in
  *[2367]*) fatal "El perfil '$PROFILE_FILE' es escribible por grupo u otros usuarios (mode=$_pf_mode)." ;;
esac
unset _pf_uid _pf_mode

# shellcheck source=/dev/null
source "$PROFILE_FILE"

load_profile

# ============================================================
# PREPARACIÓN EFECTIVA DE SÍMBOLOS
# ============================================================
load_rename_map

declare -a EFF_ENABLE=() EFF_DISABLE=() EFF_CRITICAL=()
declare -A EFF_SETVAL=() EFF_SETSTR=()
declare -A APPLIED_RENAMES=()

declare -A SEEN_ENABLE=() SEEN_DISABLE=() SEEN_CRITICAL=()

add_unique() {
  local arr_name="$1" sym="$2"
  case "$arr_name" in
    enable)
      if [ -z "${SEEN_ENABLE[$sym]:-}" ]; then EFF_ENABLE+=("$sym"); SEEN_ENABLE[$sym]=1; fi ;;
    disable)
      if [ -z "${SEEN_DISABLE[$sym]:-}" ]; then EFF_DISABLE+=("$sym"); SEEN_DISABLE[$sym]=1; fi ;;
    critical)
      if [ -z "${SEEN_CRITICAL[$sym]:-}" ]; then EFF_CRITICAL+=("$sym"); SEEN_CRITICAL[$sym]=1; fi ;;
    *) fatal "add_unique: array desconocido '$arr_name'" ;;
  esac
}

# Reconstruye los arrays efectivos EFF_* a partir de los OPTS_* del perfil.
# Se usa tanto en el arranque como tras --absorb-rebels (que re-sourcea el
# perfil ya editado). Las asignaciones sin `declare` caen sobre los arrays
# globales ya declarados arriba, por lo que es segura llamarla desde aquí.
build_effective_arrays() {
  local o r
  EFF_ENABLE=(); EFF_DISABLE=(); EFF_CRITICAL=()
  EFF_SETVAL=(); EFF_SETSTR=()
  APPLIED_RENAMES=()
  SEEN_ENABLE=(); SEEN_DISABLE=(); SEEN_CRITICAL=()

  for o in "${OPTS_ENABLE[@]}"; do
    r="$(resolve_symbol "$o")"
    [ "$r" != "$o" ] && APPLIED_RENAMES["$o"]="$r"
    add_unique enable "$r"
  done
  for o in "${OPTS_DISABLE[@]}"; do
    r="$(resolve_symbol "$o")"
    [ "$r" != "$o" ] && APPLIED_RENAMES["$o"]="$r"
    add_unique disable "$r"
  done
  for o in "${CRITICAL_OPTS[@]}"; do
    r="$(resolve_symbol "$o")"
    [ "$r" != "$o" ] && APPLIED_RENAMES["$o"]="$r"
    add_unique critical "$r"
  done
  for o in "${!OPTS_SETVAL[@]}"; do
    r="$(resolve_symbol "$o")"
    [ "$r" != "$o" ] && APPLIED_RENAMES["$o"]="$r"
    EFF_SETVAL["$r"]="${OPTS_SETVAL[$o]}"
  done
  for o in "${!OPTS_SETSTR[@]}"; do
    r="$(resolve_symbol "$o")"
    [ "$r" != "$o" ] && APPLIED_RENAMES["$o"]="$r"
    EFF_SETSTR["$r"]="${OPTS_SETSTR[$o]}"
  done

  # Parches de terceros (v27.24.0): cada parche aplicado aporta símbolos Kconfig
  # nuevos que deben entrar en ENABLE (apply_config_requests los fuerza a =y) y
  # registrarse como rebeldes esperados para que la auditoría/validación no
  # ensucie (ni el --strict bloquee por ellos).
  local __ps
  for __ps in "${PATCH_ENABLE_ALL[@]}"; do
    add_unique enable "$__ps"
    EXPECTED_REBEL_SET["$__ps"]=1
    PATCH_KCONFIG_FILTER[$__ps]=1
  done
  unset __ps
  for __ps in "${PATCH_REBEL_ALL[@]}"; do
    EXPECTED_REBEL_SET["$__ps"]=1
    PATCH_KCONFIG_FILTER[$__ps]=1
  done
  unset __ps

  # BTF (opcional): DEBUG_INFO + DEBUG_INFO_BTF =y, marcados como esperados.
  if [ "$BTF_REQUESTED" = true ]; then
    add_unique enable "DEBUG_INFO"
    add_unique enable "DEBUG_INFO_BTF"
    EXPECTED_REBEL_SET["DEBUG_INFO"]=1
    EXPECTED_REBEL_SET["DEBUG_INFO_BTF"]=1
    PATCH_KCONFIG_FILTER[DEBUG_INFO]=1
    PATCH_KCONFIG_FILTER[DEBUG_INFO_BTF]=1
  fi
}

build_effective_arrays

check_profile_contradictions() {
  local opt

  for opt in "${EFF_ENABLE[@]}"; do
    if [ -n "${SEEN_DISABLE[$opt]:-}" ]; then
      fatal "Contradicción en el perfil: '$opt' aparece tanto en ENABLE como en DISABLE."
    fi
    if [ -n "${EFF_SETVAL[$opt]:-}" ] || [ -n "${EFF_SETSTR[$opt]:-}" ]; then
      fatal "Contradicción en el perfil: '$opt' aparece en ENABLE y también en SETVAL/SETSTR."
    fi
  done

  for opt in "${EFF_DISABLE[@]}"; do
    if [ -n "${EFF_SETVAL[$opt]:-}" ] || [ -n "${EFF_SETSTR[$opt]:-}" ]; then
      fatal "Contradicción en el perfil: '$opt' aparece en DISABLE y también en SETVAL/SETSTR."
    fi
  done

  for opt in "${!EFF_SETVAL[@]}"; do
    if [ -n "${EFF_SETSTR[$opt]:-}" ]; then
      fatal "Contradicción en el perfil: '$opt' aparece simultáneamente en SETVAL y SETSTR."
    fi
  done
}

check_profile_contradictions

# ============================================================
# DEPENDENCIAS / PREREQUISITOS
# ============================================================
# Mapa comando -> paquete Arch para la instalación interactiva automática.
# Un comando exigido SIN entrada aquí (sudo, pacman, cizen-uki-sync...) no se
# puede autoinstalar de forma sensata y, si falta, aborta con instrucciones
# (igual que antes de esta versión).
declare -A TOOL_PKG=(
  [awk]=gawk          [bash]=bash          [bc]=bc
  [bison]=bison       [cat]=coreutils      [ccache]=ccache
  [cmp]=diffutils
  [cp]=coreutils      [date]=coreutils     [df]=coreutils
  [du]=coreutils      [find]=findutils     [findmnt]=util-linux
  [flex]=flex         [flock]=util-linux   [fuser]=psmisc
  [gcc]=gcc           [gpg]=gnupg          [grep]=grep
  [head]=coreutils    [id]=coreutils       [ls]=coreutils
  [make]=make         [mktemp]=coreutils   [mount]=util-linux
  [nproc]=coreutils   [pahole]=pahole     [rm]=coreutils
  [sed]=sed
  [sleep]=coreutils   [sort]=coreutils     [stat]=coreutils
  [tar]=tar           [timeout]=coreutils  [tr]=coreutils
  [umount]=util-linux [wget]=wget          [xargs]=findutils
  [xz]=xz
)

# Prompt sí/no interactivo siguiendo el patrón del script (leer de /dev/tty;
# sin terminal, la respuesta se declina al default "n"). Devuelve 0 = sí.
ask_user_yes() {
  local msg="$1" answer
  if [ "${CIZEN_NO_AUTOINSTALL:-0}" = "1" ]; then
    return 1
  fi
  if ! [ -t 0 ] && ! [ -t 1 ]; then
    warn "No hay terminal interactiva; se responde NO a: $msg"
    return 1
  fi
  read -r -p "$msg " answer < /dev/tty || answer="n"
  case "${answer:-s}" in
    s|S|si|SI|Sí|sí|y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Instala interactivamente los paquetes que faltan. Devuelve 0 si todo quedó
# instalado, 1 si la ejecución de pacman falló, 2 si fue rechazado/declinado.
install_dependency_packages() {
  local purpose="$1"; shift
  local -a pkgs=("$@")
  printf '\n'
  printf '  Faltan herramientas para %s: %s\n' "$purpose" "${pkgs[*]}"
  if ! ask_user_yes "¿Instalarlas con 'sudo pacman -S --needed ${pkgs[*]}'? [S/n]"; then
    warn "No se instalarán dependencias automáticamente."
    return 2
  fi
  if sudo pacman -S --needed "${pkgs[@]}"; then
    return 0
  fi
  err "Falló la instalación de dependencias: ${pkgs[*]}"
  return 1
}

check_prerequisites() {
  local cmd pkg rc
  local -a tools=(awk bash bc bison cat ccache cmp cp date df du find findmnt flex flock fuser grep gcc gpg head id ls make mktemp mount nproc pacman pahole rm sed sleep sort stat tar tr umount wget xargs xz timeout cizen-uki-sync)
  local -a missing_cmds=() missing_pkgs=()

  for cmd in "${tools[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      continue
    fi
    if [ -n "${TOOL_PKG[$cmd]:-}" ]; then
      missing_cmds+=("$cmd")
      missing_pkgs+=("${TOOL_PKG[$cmd]}")
    else
      fatal "Falta dependencia sin paquete Arch asociado: $cmd (instálala manualmente y reintenta)."
    fi
  done

  # sudo no puede autoinstalarse (ni funcionaría sin él): si falta, se aborta
  # con instrucciones, igual que siempre.
  if [ ! -x "$(command -v sudo 2>/dev/null || true)" ]; then
    fatal "Falta sudo en PATH (instálalo como root: pacman -S sudo)."
  fi

  # Deduplicar paquetes: varios comandos comparten coreutils/util-linux/etc.
  local -a pkgs=()
  for pkg in "${missing_pkgs[@]}"; do
    case " ${pkgs[*]} " in
      *" $pkg "*) ;;
      *) pkgs+=("$pkg") ;;
    esac
  done

  [ "${#pkgs[@]}" -eq 0 ] && return 0

  install_dependency_packages "el flujo del kernel" "${pkgs[@]}"
  rc=$?
  if [ "$rc" = 0 ]; then
    for cmd in "${missing_cmds[@]}"; do
      command -v "$cmd" >/dev/null 2>&1 || fatal "La instalación no dejó '$cmd' disponible en PATH (paquete ${TOOL_PKG[$cmd]})."
    done
    ok "Dependencias requeridas instaladas: ${pkgs[*]}"
  elif [ "$rc" = 1 ]; then
    fatal "No se pudieron instalar las dependencias requeridas. Comando sugerido: sudo pacman -S ${pkgs[*]}"
  else
    fatal "Faltan dependencias requeridas: ${missing_cmds[*]}. Instálalas manualmente con: sudo pacman -S ${pkgs[*]}"
  fi
}

# aria2c es OPCIONAL (descarga paralela). Solo se sugiere cuando va a usarse:
# justo antes de una descarga real y a menos que se fuerce wget o el
# autoinstalado esté desactivado. Declinar nunca bloquea (se sigue con wget).
ensure_optional_aria2c() {
  [ "${CIZEN_DOWNLOADER:-}" != "wget" ] || return 0
  command -v aria2c >/dev/null 2>&1 && return 0

  if [ "${CIZEN_NO_AUTOINSTALL:-0}" != "1" ] && ask_user_yes "aria2c mejora la descarga (conexiones paralelas). ¿Instalarlo ('sudo pacman -S --needed aria2')? [S/n]"; then
    if sudo pacman -S --needed aria2 && command -v aria2c >/dev/null 2>&1; then
      ok "aria2c instalado; la descarga usará conexiones paralelas."
    else
      warn "No quedó aria2c disponible tras la instalación; se usará wget (un hilo)."
    fi
  else
    warn "Descarga con wget (un hilo). Para paralelismo: sudo pacman -S aria2"
  fi
  return 0
}

# Preflight opcional de privilegios: comprueba temprano, sin modificar nada,
# que las operaciones privilegiadas que el script usará más adelante están
# permitidas por el sudoers del sistema. La ausencia de alguna no aborta
# (la instalación puede fallar por otras razones), pero avisa ANTES de gastar
# minutos compilando si el sudoers es restrictivo y la fase final fallará.
# Requiere ticket sudo vigente (se invoca después de sudo -v); si no hay
# ticket, simplemente se omite la verificación.
check_sudo_capabilities() {
  local cmd
  local -a required=(mount umount find stat mkdir cp mv rm fuser sync pacman)
  local -a missing=()

  sudo -n true 2>/dev/null || {
    log "sudo sin ticket vigente; no se verifica la lista de comandos privilegiados."
    return 0
  }

  for cmd in "${required[@]}"; do
    if ! sudo -n "$cmd" --version >/dev/null 2>&1 &&
       ! sudo -n "$cmd" -V >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    warn "Verificación de privilegios sudo incompleta para: ${missing[*]}."
    warn "Si tu sudoers es restrictivo, estas operaciones fallarán en la instalación/sincronización de la UKI. Revisa la salida de: sudo -l"
  fi
}

# ============================================================
# ESPACIO / TMPFS / LOCK / DIRECTORIOS
# ============================================================
get_avail_mb() {
  local dir="$1" kb
  kb="$(df -Pk "$dir" | awk 'NR==2 {print $4}')"
  echo $(( ${kb:-0} / 1024 ))
}

prepare_dirs() {
  mkdir -p "$KERNEL_BUILD_ROOT" "$TMPFS_ROOT" "$(dirname "$LOCK_FILE")"
}

tmpfs_is_mounted() {
  [ "$(findmnt -n -M "$TMPFS_ROOT" -o FSTYPE 2>/dev/null || true)" = "tmpfs" ]
}

verify_tmpfs_ownership() {
  local expected_uid expected_gid actual_uid actual_gid
  expected_uid="$(id -u)"
  expected_gid="$(id -g)"
  actual_uid="$(stat -c '%u' "$TMPFS_ROOT" 2>/dev/null || echo -1)"
  actual_gid="$(stat -c '%g' "$TMPFS_ROOT" 2>/dev/null || echo -1)"

  if [ "$actual_uid" != "$expected_uid" ] || [ "$actual_gid" != "$expected_gid" ]; then
    warn "El remount no dejó el propietario esperado en el tmpfs; se corrige explícitamente con chown."
    sudo chown "$expected_uid:$expected_gid" "$TMPFS_ROOT"
    actual_uid="$(stat -c '%u' "$TMPFS_ROOT" 2>/dev/null || echo -1)"
    actual_gid="$(stat -c '%g' "$TMPFS_ROOT" 2>/dev/null || echo -1)"
  fi

  [ "$actual_uid" = "$expected_uid" ] && [ "$actual_gid" = "$expected_gid" ] || fatal "No se pudo establecer el propietario correcto del tmpfs: uid=$actual_uid gid=$actual_gid"
}

prepare_tmpfs_build() {
  local owner_uid owner_gid fstype mount_target avail_mb min_required

  mkdir -p "$TMPFS_ROOT"

  fstype="$(findmnt -n -M "$TMPFS_ROOT" -o FSTYPE 2>/dev/null || true)"
  mount_target="$(findmnt -n -M "$TMPFS_ROOT" -o TARGET 2>/dev/null || true)"

  if [ -n "$fstype" ]; then
    if [ "$fstype" != "tmpfs" ] || [ "$mount_target" != "$TMPFS_ROOT" ]; then
      fatal "KERNEL_TMPFS_ROOT ya está ocupado por '$fstype' en '$mount_target'; no se modifica."
    fi

    TMPFS_MOUNTED=true
    TMPFS_CREATED_BY_SCRIPT=false
    log "tmpfs de compilación ya montado; se reutiliza"
  else
    if find "$TMPFS_ROOT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      fatal "El punto de montaje $TMPFS_ROOT no está vacío; no se monta encima para proteger datos existentes."
    fi

    owner_uid="$(id -u)"
    owner_gid="$(id -g)"
    log "Montando tmpfs de $TMPFS_SIZE para la compilación: $TMPFS_ROOT"
    sudo -v
    if ! sudo mount -t tmpfs -o "size=$TMPFS_SIZE,mode=0755,uid=$owner_uid,gid=$owner_gid,exec,nosuid,nodev,huge=advise" tmpfs "$TMPFS_ROOT"; then
      fatal "No se pudo montar el tmpfs de compilación en $TMPFS_ROOT."
    fi
    TMPFS_MOUNTED=true
    TMPFS_CREATED_BY_SCRIPT=true
    verify_tmpfs_ownership
  fi

  avail_mb="$(get_avail_mb "$TMPFS_ROOT")"
  min_required="$TMPFS_MIN_FREE_MB"
  if [ -d "$SRC" ]; then
    min_required="$TMPFS_EXISTING_SRC_MIN_FREE_MB"
  fi
  if [ "$avail_mb" -lt "$min_required" ]; then
    fatal "El tmpfs deja solo ${avail_mb} MB libres; mínimo operativo requerido: ${min_required} MB. Ajusta KERNEL_TMPFS_MIN_FREE_MB/KERNEL_TMPFS_EXISTING_SRC_MIN_FREE_MB o reduce JOBS."
  fi
}

unmount_tmpfs_build() {
  [ "$TMPFS_MOUNTED" = true ] || return 0

  # El tmpfs dedicado se conserva montado deliberadamente entre ejecuciones.
  # Esto permite que un `kcheck` prepare el entorno y que el `kbuild` siguiente
  # lo reutilice sin desmontar/recrear el filesystem temporal.
  if ! tmpfs_is_mounted; then
    TMPFS_MOUNTED=false
    TMPFS_CREATED_BY_SCRIPT=false
fi
}

cleanup_kernel_cache() {
  local current_tarball="linux-$VERSION.tar.xz"
  local current_sig="linux-$VERSION.tar.xz.sign"
  local current_verified="linux-$VERSION.tar.xz.verified-ok"
  local item base keep

  mkdir -p "$KERNEL_BUILD_ROOT"

  # Solo se conservan el tarball, su firma y su huella de verificación de la
  # versión solicitada. No se tocan gnupg/, kernel-update.lock ni otros
  # elementos ajenos a artefactos.
  shopt -s nullglob
  # Limpia todos los artefactos de tarball/firma antiguos, incluidos temporales
  # de descargas interrumpidas. La versión objetivo se conserva solo bajo sus
  # nombres definitivos, nunca con sufijos .download/.bad/.partial.
  for item in "$KERNEL_BUILD_ROOT"/linux-*.tar.xz*; do
    base="$(basename -- "$item")"
    keep=false
    case "$base" in
      "$current_tarball"|"$current_sig"|"$current_verified") keep=true ;;
    esac
    if [ "$keep" = false ]; then
      rm -f -- "$item"
      log "Cache limpiado: $(basename -- "$item")"
    fi
  done
  shopt -u nullglob
}

cleanup_old_source_trees() {
  local dir name version_num
  [ -d "$TMPFS_ROOT" ] || return 0

  shopt -s nullglob
  local -a trees=("$TMPFS_ROOT"/linux-*)
  shopt -u nullglob
  [ "${#trees[@]}" -eq 0 ] && return 0

  # GUARDA: nunca borrar árboles bajo un directorio que NO sea el tmpfs de
  # compilación dedicado. Si TMPFS_ROOT no está montado como tmpfs (p. ej.
  # KERNEL_TMPFS_ROOT mal configurado apuntando a un directorio persistente
  # con árboles linux-*), no se puede distinguir fuentes de esta herramienta
  # de datos ajenos: no se elimina nada y prepare_tmpfs_build() abortará
  # después porque solo monta sobre un punto de montaje vacío. En el flujo
  # normal el tmpfs de la ejecución anterior sigue montado y esta limpieza
  # actúa exactamente igual que siempre.
  if ! tmpfs_is_mounted; then
    warn "TMPFS_ROOT no está montado como tmpfs ($TMPFS_ROOT); no se elimina ningún árbol de fuentes antiguo."
    return 0
  fi

  for dir in "${trees[@]}"; do
    [ -d "$dir" ] || continue
    name="$(basename -- "$dir")"
    version_num="${name#linux-}"
    [ "$version_num" = "$VERSION" ] && continue

    if [ -f "$dir/Makefile" ]; then
      log "Eliminando árbol de fuentes antiguo del tmpfs: $dir"
      rm -rf -- "$dir"
    fi
  done
}

check_disk_space() {
  local min_mb=8192 avail_mb

  # El tarball se almacena en persistencia.
  avail_mb="$(get_avail_mb "$KERNEL_BUILD_ROOT")"
  if [ "$avail_mb" -lt "$min_mb" ]; then
    fatal "Espacio insuficiente en el cache persistente ($KERNEL_BUILD_ROOT: ${avail_mb} MB disponibles, se requieren ${min_mb} MB). Libera espacio o establece KERNEL_BUILD_ROOT en otro filesystem."
  fi
}

# ============================================================
# SUDO KEEP-ALIVE PARA BUILDS LARGAS
# ============================================================
SUDO_KEEP_PID=""
sudo_keepalive_start() {
  [ -n "${SUDO_KEEP_PID:-}" ] && return 0
  (
    trap 'exit 0' TERM INT
    while kill -0 "$$" 2>/dev/null; do
      sudo -n -v 2>/dev/null || exit 0
      # El sleep se lanza en segundo plano y se espera con `wait` a propósito:
      # un `sleep` en primer plano difiere el trap TERM/INT hasta que el propio
      # sleep termina por sí solo (comportamiento documentado de Bash), lo que
      # dejaba a sudo_keepalive_stop() esperando hasta 60s tras cada build.
      # `wait` sobre un job en segundo plano sí es interrumpible de inmediato.
      sleep 60 &
      wait "$!"
    done
  ) &
  SUDO_KEEP_PID=$!
}

sudo_keepalive_stop() {
  if [ -n "${SUDO_KEEP_PID:-}" ]; then
    kill "$SUDO_KEEP_PID" 2>/dev/null || true
    wait "$SUDO_KEEP_PID" 2>/dev/null || true
    SUDO_KEEP_PID=""
  fi
}

# ============================================================
# TRAPS / LIMPIEZA
# ============================================================
CLEANUP_DONE=false
INTERRUPT_CAUGHT=false

cleanup_success() {
  [ "$CLEANUP_DONE" = true ] && return 0
  CLEANUP_DONE=true

  # Nunca intentar desmontar el tmpfs mientras el shell tenga su cwd dentro
  # del punto de montaje. El flujo principal hace `cd "$SRC"` durante la build.
  # Volver a un directorio persistente libera la referencia al mountpoint.
  cd "$HOME" || cd /

  rm -f "$BUILD_MARKER" 2>/dev/null || true

  # El árbol de la versión más nueva se conserva en el tmpfs para reutilizarlo
  # en la próxima ejecución. No se elimina al terminar correctamente.
  if [ -d "$SRC" ]; then
    log "Fuentes conservadas para reutilización: $SRC"
  fi

  # El tmpfs y el árbol de fuentes se mantienen montados/conservados siempre
  # para reutilizar la build en la próxima ejecución.
  unmount_tmpfs_build
}


cleanup_interrupt() {
  local sig="$1"
  INTERRUPT_CAUGHT=true
  echo
  warn "Interrupción recibida ($sig)."
  if [ -d "$SRC" ]; then
    warn "Se conserva el árbol de fuentes para poder reanudar/depurar: $SRC"
  fi
  if [ -f "$TARBALL" ]; then
    log "Tarball conservado: $TARBALL"
  fi
  if [ "$TMPFS_MOUNTED" = true ]; then
    if [ "$TMPFS_CREATED_BY_SCRIPT" = true ]; then
      warn "El tmpfs montado por este script se mantiene disponible para diagnóstico: $TMPFS_ROOT"
      warn "Cuando termines el diagnóstico: sudo umount ${TMPFS_ROOT}"
    else
      warn "El tmpfs ya existente se mantiene montado: $TMPFS_ROOT"
    fi
  fi
  err "Operación cancelada."
  exit 130
}

trap 'cleanup_interrupt INT' INT
trap 'cleanup_interrupt TERM' TERM

cleanup_tmpfs_on_exit() {
  local rc=$?

  sudo_keepalive_stop

  # Nunca dejar temporales de descarga tras éxito, error o interrupción.
  if [ -n "${TARBALL:-}" ]; then
    rm -f -- "${TARBALL}.download-"* "${TARBALL}.partial-"* 2>/dev/null || true
    rm -f -- "${TARBALL}.sign.download-"* "${TARBALL}.sign.partial-"* 2>/dev/null || true
  fi

  # Retirar cualquier copia temporal de configuración que haya quedado por una
  # interrupción antes del rename atómico. Nunca tocar la configuración estable.
  [ -n "${CHECK_CONFIG_TMP:-}" ] && rm -f -- "$CHECK_CONFIG_TMP" 2>/dev/null || true

  # Si una señal o un fallo inesperado interrumpe la build, no dejamos una
  # modificación permanente en el árbol de fuentes conservado.
  if [ -n "${SRC:-}" ] && [ -f "$SRC/scripts/Makefile.package.cizen-orig" ]; then
    mv -f -- "$SRC/scripts/Makefile.package.cizen-orig" "$SRC/scripts/Makefile.package" 2>/dev/null || true
  fi
  if [ -n "${SRC:-}" ] && [ -f "$SRC/scripts/package/PKGBUILD.cizen-orig" ]; then
    mv -f -- "$SRC/scripts/package/PKGBUILD.cizen-orig" "$SRC/scripts/package/PKGBUILD" 2>/dev/null || true
  fi

  # Las rutas normales llaman cleanup_success explícitamente.
  # Si algo falla inesperadamente, dejamos el tmpfs montado para diagnóstico.
  if [ "$TMPFS_MOUNTED" = true ] && [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 130 ] && [ "$INTERRUPT_CAUGHT" = true ]; then
      info "La compilación fue cancelada por el usuario; no es un error. Se conserva el tmpfs montado: $TMPFS_ROOT"
      info "Para desmontarlo después: sudo umount ${TMPFS_ROOT}"
    else
      warn "La ejecución terminó con error ($rc); se conserva el tmpfs montado para diagnóstico: $TMPFS_ROOT"
      warn "Para desmontarlo después: sudo umount ${TMPFS_ROOT}"
    fi
  fi
}
trap cleanup_tmpfs_on_exit EXIT

# ============================================================
# TAR / DESCARGA
# ============================================================
KERNEL_GPG_HOME="${KERNEL_GPG_HOME:-$KERNEL_BUILD_ROOT/gnupg}"

# Firmantes oficiales de kernel.org reconocidos por este script.
# Los releases "mainline" (X.Y) los firma Linus Torvalds; los releases
# estables (X.Y.Z) normalmente los firma Greg Kroah-Hartman. Como este
# script admite y normaliza explícitamente ambas formas de versión
# (ver la normalización X.Y.0 -> X.Y más abajo), debía reconocer a ambos
# firmantes: antes solo confiaba en Greg, así que cualquier release
# mainline fallaba la verificación de firma SIEMPRE, fuera válido o no.
# Huellas oficiales publicadas en https://www.kernel.org/signature.html;
# conviene revisarlas si kernel.org las actualiza.
declare -A KERNEL_TRUSTED_SIGNERS=(
  [gregkh@kernel.org]="647F28654894E3BD457199BE38DBBDC86092693E"
  [torvalds@kernel.org]="ABAF11C65A2970B130ABE3C479BE3E4300411886"
)

verify_tarball() {
  local file="$1"
  [ -f "$file" ] || return 1
  [ -s "$file" ] || return 1
  log "Verificando integridad del tarball ($(du -h "$file" | cut -f1))..."
  xz -t "$file" >/dev/null 2>&1
}

prepare_gpg_home() {
  mkdir -p "$KERNEL_GPG_HOME"
  chmod 0700 "$KERNEL_GPG_HOME"
}

# Obtiene y fija (pinning) en el keyring dedicado cada firmante confiable
# cuya huella coincida con la oficial. Un firmante que no se pueda obtener,
# o cuya huella no coincida, se descarta (y se elimina del keyring si llegó
# a importarse) en vez de bloquear la ejecución: basta con que AL MENOS UNO
# de los firmantes reconocidos quede disponible para poder verificar.
ensure_kernel_signing_keys() {
  local email fp expected pinned=0
  prepare_gpg_home

  for email in "${!KERNEL_TRUSTED_SIGNERS[@]}"; do
    expected="${KERNEL_TRUSTED_SIGNERS[$email]}"
    fp="$(gpg --homedir "$KERNEL_GPG_HOME" --batch --with-colons --fingerprint "$email" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"

    if [ "$fp" != "$expected" ]; then
      log "Clave de $email no disponible en el keyring dedicado; se obtiene mediante WKD de kernel.org."
      gpg --homedir "$KERNEL_GPG_HOME" --batch --yes --locate-keys "$email" >/dev/null 2>&1 || true
      fp="$(gpg --homedir "$KERNEL_GPG_HOME" --batch --with-colons --fingerprint "$email" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
    fi

    if [ "$fp" = "$expected" ]; then
      ok "Clave PGP confiable disponible: $email ($fp)"
      pinned=$((pinned + 1))
    else
      warn "No se pudo confirmar la clave PGP de $email (obtenida: '${fp:-ninguna}'); no se usará para verificar firmas."
      if [ -n "$fp" ]; then
        # Nunca dejamos en el keyring dedicado una clave cuya huella no
        # coincide con la esperada, aunque WKD haya devuelto algo.
        gpg --homedir "$KERNEL_GPG_HOME" --batch --yes --delete-keys "$fp" >/dev/null 2>&1 || true
      fi
    fi
  done

  [ "$pinned" -gt 0 ] || fatal "No se pudo confirmar ninguna clave PGP oficial de kernel.org (${!KERNEL_TRUSTED_SIGNERS[*]})."
}

verify_tarball_signature() {
  local tarball="$1" sig="$2" gpg_out signer=""
  [ -s "$tarball" ] || return 1
  [ -s "$sig" ] || return 1
  ensure_kernel_signing_keys
  log "Verificando firma PGP oficial del tarball..."
  # kernel.org firma el archivo .tar sin comprimir, mientras el archivo
  # descargado para la build es .tar.xz. La verificación correcta es
  # descomprimir por streaming y pasar el .tar a gpg mediante stdin.
  # El keyring dedicado solo contiene claves ya fijadas por huella en
  # ensure_kernel_signing_keys(), así que un "Good signature" de gpg aquí
  # implica necesariamente que la firma es de uno de los firmantes
  # confiables (LC_ALL=C está exportado al inicio del script, así que el
  # texto de salida de gpg es estable para este grep).
  if gpg_out="$(xz -cd -- "$tarball" | gpg --homedir "$KERNEL_GPG_HOME" --batch --verify "$sig" - 2>&1)"; then
    signer="$(printf '%s\n' "$gpg_out" | sed -n 's/.*Good signature from "\([^"]*\)".*/\1/p' | head -n1)"
    ok "Firma PGP del kernel verificada correctamente${signer:+ (firmante: $signer)}"
    return 0
  fi
  err "La firma PGP del tarball NO es válida."
  printf '%s\n' "$gpg_out" | tail -20 >&2 || true
  return 1
}

# Huella tamaño+mtime del tarball+firma. Solo se usa para saber si ya se
# verificaron criptográficamente en una ejecución anterior sin que nada los
# haya tocado desde entonces; nunca sustituye la verificación en sí. Si
# cualquiera de los dos archivos cambia (tamaño o mtime), la huella deja de
# coincidir y se vuelve a verificar todo desde cero.
# NOTA: esta huella es una optimización, no una frontera de seguridad. Está
# sujeta a colisiones teóricas (un sustituto del mismo tamaño con mtime
# ajustado) si alguien con escritura en el caché persistente reemplaza el
# tarball tras la verificación; se considera aceptable porque el tarball ya
# se verificó criptográficamente al menos una vez y esta caché vive bajo el
# control del propio usuario.
tarball_fingerprint() {
  local tarball="$1" sig="$2"
  printf '%s:%s' "$(stat -c '%s:%Y' "$tarball" 2>/dev/null)" "$(stat -c '%s:%Y' "$sig" 2>/dev/null)"
}

# Descarga con un hilo (wget clásico) o con conexiones paralelas (aria2c) si
# está instalado y no se fuerza CIZEN_DOWNLOADER=wget. Múltiples CDN limitan
# el throughput POR conexión (se midió ~30 MB/s por hilo en cdn.kernel.org
# frente a ~54 MB/s agregados con 4 hilos), así que aria2c aprovecha mejor el
# enlace. parámetros de reintentos/continuación equivalentes a los del wget
# previo: --continue, 5 intentos, timeout 30s, espera 2s.
download_file() {
  local url="$1" out="$2"
  local parallel="${CIZEN_DOWNLOAD_PARALLEL:-4}"
  [[ "$parallel" =~ ^[1-9][0-9]?$ ]] || parallel=4
  if [ "${CIZEN_DOWNLOADER:-}" != "wget" ] && command -v aria2c >/dev/null 2>&1; then
    local summary_interval="${CIZEN_DOWNLOAD_SUMMARY_INTERVAL:-0}"
    local -a dl_progress=()
    if [ -t 2 ]; then
      if [[ "$summary_interval" =~ ^[0-9]+$ ]] && [ "$summary_interval" -gt 0 ]; then
        dl_progress=(--summary-interval="$summary_interval")
      else
        dl_progress=(--summary-interval=0)
      fi
    else
      dl_progress=(--quiet)
    fi
    aria2c --continue=true --max-tries=5 --timeout=30 --connect-timeout=30 \
      --retry-wait=2 --max-connection-per-server="$parallel" \
      --split="$parallel" --min-split-size=1M --file-allocation=none \
      --allow-overwrite=false --auto-file-renaming=false --console-log-level=warn "${dl_progress[@]}" \
      --dir="$(dirname -- "$out")" --out="$(basename -- "$out")" "$url"
  else
    local -a wget_progress=()
    if [ -t 2 ]; then
      wget_progress=(--show-progress)
    fi
    wget --continue --tries=5 --timeout=30 --waitretry=2 "${wget_progress[@]}" "$url" -O "$out"
  fi
}

get_tarball() {
  local tarball="$1" url="$2" tmp_download tmp_sign sig bad_name
  sig="${tarball}.sign"
  local verified_marker="${tarball}.verified-ok"

  # Limpia residuos temporales previos de esta misma versión antes de reutilizar
  # el caché. Nunca se considera válido un .download/.bad/.partial.
  shopt -s nullglob
  for item in "${tarball}.download-"* "${sig}.download-"* "${tarball}.partial-"* "${sig}.partial-"*; do
    [ -e "$item" ] || continue
    rm -f -- "$item"
    log "Residuo temporal eliminado: $(basename -- "$item")"
  done
  shopt -u nullglob

  # Si el tarball y la firma conservan exactamente el tamaño+mtime que tenían
  # la última vez que superaron la verificación criptográfica completa en
  # esta misma caché persistente, no repetimos la descompresión + gpg en cada
  # invocación. Cualquier cambio real en cualquiera de los dos archivos
  # invalida la huella y fuerza una verificación completa de nuevo: esto no
  # relaja el resultado final, solo evita repetirlo sobre un archivo que ya
  # demostramos íntegro y que no ha cambiado desde entonces.
  if [ -s "$tarball" ] && [ -s "$sig" ] && [ -f "$verified_marker" ] && \
     [ "$(cat -- "$verified_marker" 2>/dev/null)" = "$(tarball_fingerprint "$tarball" "$sig")" ]; then
    ok "Tarball y firma PGP ya verificados en una ejecución anterior (sin cambios); se omite la reverificación"
    return 0
  fi

  # verify_tarball_signature ya descomprime el tarball completo para pasarlo a
  # gpg (xz -cd | gpg --verify) con pipefail activo: si xz falla, la tubería
  # entera falla igual que con xz -t por separado. Una segunda descompresión
  # completa aquí no aporta ninguna garantía adicional, así que se omite en
  # esta ruta (el chequeo xz -t tras una descarga fresca, más abajo, sí se
  # mantiene: ahí sirve para fallar rápido antes de gastar tiempo bajando la
  # firma por separado).
  if [ -s "$tarball" ] && [ -s "$sig" ] && verify_tarball_signature "$tarball" "$sig"; then
    ok "Tarball y firma PGP válidos; no se descarga de nuevo"
    tarball_fingerprint "$tarball" "$sig" > "$verified_marker" 2>/dev/null || true
    return 0
  fi
  rm -f -- "$verified_marker"

  # Un tarball o firma existente que no pasa la verificación se elimina.
  # No se crean archivos .bad persistentes.
  if [ -e "$tarball" ]; then
    rm -f -- "$tarball"
    warn "Tarball existente no verificable eliminado: $(basename -- "$tarball")"
  fi
  if [ -e "$sig" ]; then
    rm -f -- "$sig"
    warn "Firma existente no verificable eliminada: $(basename -- "$sig")"
  fi

  tmp_download="${tarball}.download-${TS}"
  tmp_sign="${sig}.download-${TS}"
  rm -f -- "$tmp_download" "$tmp_sign"
  ensure_optional_aria2c
  log "Descargando: $url"

  # Todo temporal se elimina si cualquier paso falla. Además, el trap EXIT
  # global vuelve a limpiar estos nombres en caso de interrupción inesperada.
  if ! download_file "$url" "$tmp_download"; then
    rm -f -- "$tmp_download" "$tmp_sign"
    err "No se pudo descargar el tarball."
    return 1
  fi

  if ! verify_tarball "$tmp_download"; then
    err "El tarball descargado no supera xz -t."
    rm -f -- "$tmp_download" "$tmp_sign"
    return 1
  fi

  log "Descargando firma PGP: ${url%.tar.xz}.tar.sign"
  if ! download_file "${url%.tar.xz}.tar.sign" "$tmp_sign"; then
    rm -f -- "$tmp_download" "$tmp_sign"
    err "No se pudo descargar la firma PGP del kernel."
    return 1
  fi

  if ! verify_tarball_signature "$tmp_download" "$tmp_sign"; then
    err "El tarball descargado no supera la verificación criptográfica oficial."
    rm -f -- "$tmp_download" "$tmp_sign"
    return 1
  fi

  # Promoción atómica desde temporales verificados a nombres definitivos.
  mv -f -- "$tmp_download" "$tarball"
  mv -f -- "$tmp_sign" "$sig"
  tarball_fingerprint "$tarball" "$sig" > "$verified_marker" 2>/dev/null || true
  ok "Tarball descargado, íntegro y firmado por kernel.org"
}

# ============================================================
# EXTRACCIÓN / FUENTES
# ============================================================
source_tree_valid() {
  [ -d "$SRC" ] && [ -f "$SRC/Makefile" ]
}

extract_tarball() {
  cleanup_old_source_trees

  if source_tree_valid; then
    if [ "$(make -C "$SRC" -s kernelversion 2>/dev/null || true)" = "$VERSION" ]; then
      return 0
    fi
    warn "El árbol existente no coincide con $VERSION; se elimina y se vuelve a extraer."
    rm -rf "$SRC"
  fi

  log "Extrayendo fuentes en $(dirname "$SRC") ..."
  tar -xf "$TARBALL" -C "$(dirname "$SRC")"

  if ! source_tree_valid; then
    err "Extracción incompleta: falta $SRC/Makefile"
    rm -rf "$SRC"
    return 1
  fi

  if [ "$(make -C "$SRC" -s kernelversion 2>/dev/null || true)" != "$VERSION" ]; then
    err "La versión del árbol extraído no coincide con $VERSION"
    rm -rf "$SRC"
    return 1
  fi
}

# ============================================================
# FRAMEWORK DE PARCHES DE TERCEROS (OPCIONAL)  — v27.24.0
# ============================================================
# Mecanismo DECLARATIVO para aplicar parches de terceros sobre las fuentes
# vanilla. Cada parche es un descriptor (función `patch_desc_<nombre>`) que
# define TODOS los parámetros; la lógica de aplicación es genérica y común.
#
# Descriptor (variables que debe fijar patch_desc_<n>):
#   PATCH_DESC           descripción humana
#   PATCH_DISP_NAME      nombre corto para logs
#   PATCH_BRANCH         rama X.Y del kernel objetivo (7.2.6 -> 7.2)
#   PATCH_URL_PREFIX     base del repo donde se publica (incluye "master")
#   PATCH_CDN_SUBDIR     subdirectorio bajo la rama (sched/)
#   PATCH_MAIN_FILE      fichero principal (forward-port del mantenedor del repo)
#   PATCH_FALLBACK_FILE  respaldo del autor upstream (se sincroniza por release)
#   PATCH_CACHE_NAME     prefijo del fichero en KERNEL_BUILD_ROOT (-> name-$br.patch)
#   PATCH_SYMBOLS        símbolos Kconfig que el parche introduce (=y + rebelde)
#   PATCH_MAGIC          cadena que debe aparecer en un parche válido
#   PATCH_MARKERS        array "ruta:patrón" para detectar un árbol ya parcheado
#
# La lógica común (v27.22.2 y v27.22.4 heredadas de BORE):
#   - Detección de árbol conservado ya-parcheado por marcadores: no se vuelve a
#     descargar ni a aplicar (evita el "Reversed patch detected" del dry-run).
#   - Cada intento de descarga BORRA el destino antes (download_file usa aria2c
#     con --allow-overwrite=false + --continue; sin borrar un fichero existente
#     se daría por completo o se renombraría a .1, dejando huérfano el bueno).
#   - Degrade automático principal -> upstream si no aplica limpio sobre X.Y.Z.
#   - Cualquier fallo es fatal suave: warning y build vanilla (nunca rompe).
#   - Al aplicar, los símbolos se registran (apply_patch_register) para que
#     build_effective_arrays los fuerce a =y y los marque como esperados.
bore_branch_from_version() {
  # 7.2.6 -> 7.2 ; 7.2 -> 7.2 ; 6.1.77 -> 6.1
  if [[ "$1" =~ ^([0-9]+\.[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "${1%%.*}"
  fi
}

# Descriptor del plugin BORE (firelzrd, reenviado por CachyOS).
patch_desc_bore() {
  PATCH_DESC="BORE scheduler (Burst-Oriented Response Enhancer)"
  PATCH_DISP_NAME="BORE"
  PATCH_BRANCH="$(bore_branch_from_version "$VERSION")"
  PATCH_URL_PREFIX="https://raw.githubusercontent.com/CachyOS/kernel-patches/master"
  PATCH_CDN_SUBDIR="sched"
  PATCH_MAIN_FILE="0001-bore-cachy.patch"
  PATCH_FALLBACK_FILE="0001-bore.patch"
  PATCH_CACHE_NAME="bore"
  PATCH_SYMBOLS=(SCHED_BORE MIN_BASE_SLICE_NS)
  PATCH_MAGIC="config SCHED_BORE"
  PATCH_MARKERS=( "kernel/sched/bore.c:" "kernel/sched/fair.c:SCHED_BORE|burst" )
}

# Comprueba los marcadores de "árbol ya parcheado" del descriptor actual.
# PATCH_MARKERS es "ruta:patrón" relativa a $SRC; patrón vacío = basta con que
# el fichero exista.
patch_markers_hit() {
  local m path pat
  for m in "${PATCH_MARKERS[@]:-}"; do
    path="${m%%:*}"
    pat="${m#*:}"
    [ -f "$SRC/$path" ] || return 1
    [ -z "$pat" ] || grep -Eq -- "$pat" "$SRC/$path" 2>/dev/null || return 1
  done
  return 0
}

# Registra un parche como aplicado: añade a la lista de aplicados y acumula sus
# símbolos Kconfig para que build_effective_arrays los fuerce a =y y los marque
# como rebeldes esperados. BORE mantiene además BORE_ENABLED (resumen y firma).
apply_patch_register() {
  local p="$1" s
  PATCHES_APPLIED+=("$p")
  for s in "${PATCH_SYMBOLS[@]:-}"; do
    PATCH_ENABLE_ALL+=("$s")
    PATCH_REBEL_ALL+=("$s")
  done
  unset s
  if [ "$p" = "bore" ]; then
    BORE_ENABLED=true
  fi
}

# Descarga y aplica el parche <nombre>. Devuelve 0 = aplicado, 1 = no
# (fatal suave: la build continúa vanilla tras un warning).
apply_patch_plugin() {
  local name="$1"
  local patch_file main_url fallback_url

  # Carga el descriptor del parche (función patch_desc_<nombre> global).
  if ! declare -F "patch_desc_$name" >/dev/null 2>&1; then
    warn "Parche '$name' desconocido o sin descriptor en el motor; se omite."
    return 1
  fi
  "patch_desc_$name"

  log "Parche ${PATCH_DISP_NAME:-$name} habilitado: descargando para la rama ${PATCH_BRANCH:-?} ..."

  # Árbol conservado de una ejecución previa (p. ej. cancelada tras aplicar):
  # los marcadores del descriptor son la firma de que el parche YA está
  # aplicado. Volver a hacer `patch --dry-run` sobre un árbol ya parcheado
  # respondería "Reversed (or previously applied) patch detected" (rc=1) y se
  # degradaría a vanilla pese a que el árbol SÍ lo lleva.
  if patch_markers_hit; then
    ok "${PATCH_DISP_NAME:-$name} ya estaba aplicado en el árbol conservado."
    apply_patch_register "$name"
    return 0
  fi

  if ! command -v patch >/dev/null 2>&1; then
    warn "patch no está instalado; no se puede aplicar $name. Instale con: sudo pacman -S patch"
    return 1
  fi

  patch_file="$KERNEL_BUILD_ROOT/${PATCH_CACHE_NAME}-${PATCH_BRANCH}.patch"

  # Intento 1: fichero principal (forward-port del repo; p. ej. CachyOS lo
  # regenera contra una RC y a veces no aplica sobre la release final X.Y.Z).
  main_url="${PATCH_URL_PREFIX}/${PATCH_BRANCH}/${PATCH_CDN_SUBDIR}/${PATCH_MAIN_FILE}"
  rm -f -- "$patch_file"
  if download_file "$main_url" "$patch_file" \
     && [ -s "$patch_file" ] \
     && grep -Fq "$PATCH_MAGIC" "$patch_file" \
     && patch -p1 --dry-run -d "$SRC" < "$patch_file" >/dev/null 2>&1; then
    :
  else
    warn "${PATCH_DISP_NAME:-$name}: ${PATCH_MAIN_FILE} no disponible/no aplica sobre $VERSION; probando upstream (${PATCH_FALLBACK_FILE}) ..."
    rm -f -- "$patch_file"
    fallback_url="${PATCH_URL_PREFIX}/${PATCH_BRANCH}/${PATCH_CDN_SUBDIR}/${PATCH_FALLBACK_FILE}"
    if ! download_file "$fallback_url" "$patch_file" \
       || [ ! -s "$patch_file" ] \
       || ! grep -Fq "$PATCH_MAGIC" "$patch_file" \
       || ! patch -p1 --dry-run -d "$SRC" < "$patch_file" >/dev/null 2>&1; then
      warn "Ningún parche ${PATCH_DISP_NAME:-$name} disponible para la rama ${PATCH_BRANCH:-?} / $VERSION; se continúa vanilla."
      return 1
    fi
  fi

  if ! patch -p1 -d "$SRC" < "$patch_file" >/dev/null 2>&1; then
    warn "Aplicación real del parche ${PATCH_DISP_NAME:-$name} falló inesperadamente; se continúa vanilla."
    return 1
  fi

  apply_patch_register "$name"
  ok "${PATCH_DESC:-${PATCH_DISP_NAME:-$name}} aplicado (${PATCH_SYMBOLS[0]:-símbolos nuevos}) sobre fuentes $VERSION."
  return 0
}

# ============================================================
# CONFIG BASE
# ============================================================
find_latest_cizen_config() {
  local f v best_f="" best_v=""
  shopt -s nullglob
  for f in "$CONFIG_DIR"/linux-*-cizen-v3.config; do
    [[ "$(basename -- "$f")" =~ ^linux-([0-9]+\.[0-9]+([.][0-9]+)?)-cizen-v3\.config$ ]] || continue
    v="${BASH_REMATCH[1]}"
    # Solo configuraciones de versiones <= a la objetivo: usar una base de
    # una versión MÁS nueva que la que se va a compilar arrastra símbolos de
    # una migración futura. Sin VERSION fijado, se elige la mayor disponible.
    if [ -n "$VERSION" ] && version_gt "$v" "$VERSION"; then
      continue
    fi
    if [ -z "$best_v" ] || version_gt "$v" "$best_v"; then
      best_v="$v"
      best_f="$f"
    fi
  done
  shopt -u nullglob
  printf '%s\n' "${best_f:-}"
}


choose_base_config() {
  local ref
  ref="$(find_latest_cizen_config)"
  if [ -n "$ref" ] && [ -f "$ref" ]; then
    cp "$ref" .config
    ok "Config base Cizen: $ref"
    return 0
  fi

  if zcat /proc/config.gz > .config 2>/dev/null; then
    warn "No se encontró configuración Cizen; se usa /proc/config.gz del kernel arrancado."
    return 0
  fi
  if [ -f "/boot/config-$(uname -r)" ]; then
    cp "/boot/config-$(uname -r)" .config
    warn "No se encontró configuración Cizen; se usa /boot/config-$(uname -r)."
    return 0
  fi

  fatal "No existe configuración base Cizen ni configuración del kernel arrancado."
}

# ============================================================
# SCRIPTS/CONFIG + KCONFIG
# ============================================================
declare -A CONFIG_STATE=()

load_config_state() {
  local line sym val
  CONFIG_STATE=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)=(.*)$ ]]; then
      sym="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      CONFIG_STATE["$sym"]="$val"
    elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
      sym="${BASH_REMATCH[1]}"
      CONFIG_STATE["$sym"]="n"
    fi
  done < .config
}

config_symbol_state() {
  local sym="$1"
  if [ -n "${CONFIG_STATE[$sym]+x}" ]; then
    printf '%s\n' "${CONFIG_STATE[$sym]}"
  else
    printf '%s\n' "missing"
  fi
}

# Existencia real en el Kconfig de la versión objetivo. No depende de que el
# símbolo aparezca previamente en .config; Kconfig puede materializarlo después
# de olddefconfig. El resultado se cachea durante la ejecución.
declare -A KCONFIG_SYMBOL_KNOWN=()
KCONFIG_SYMBOL_INDEX_BUILT=false

build_kconfig_symbol_index() {
  [ "$KCONFIG_SYMBOL_INDEX_BUILT" = true ] && return 0

  local sym
  # El pipeline interno puede devolver rc!=0 legítimamente: xargs parte la lista
  # en varios lotes y un lote cuyo grep no encuentre ningún `config`/`menuconfig`
  # sale con status 1. Con `set -Eeuo pipefail` (heredado por el subshell del
  # process-substitution), el `find | xargs | grep | awk | sort` del pipeline entero
  # reportaría error y el trap ERR del subshell dispararía `on_err` falsamente
  # (salida "Error ... sort -u", índice ya construido pero abortado en apariencia).
  # El índice se construye leyendo el stream: `|| true` absorbe ese rc legítimo sin
  # enmascarar un fallo de ESCALADO (Kconfig no encontrado sigue dejando el índice vacío).
  while IFS= read -r sym; do
    [ -n "$sym" ] || continue
    KCONFIG_SYMBOL_KNOWN["$sym"]=1
  done < <(
    find "$SRC" \( -name 'Kconfig' -o -name 'Kconfig.*' \) -print0 2>/dev/null |
      xargs -0 -r grep -hoE '^[[:space:]]*(menuconfig|config)[[:space:]]+[A-Za-z0-9_]+' 2>/dev/null |
      awk '{print $2}' |
      sort -u || true
  )

  KCONFIG_SYMBOL_INDEX_BUILT=true
}

kconfig_symbol_known() {
  local sym="$1"
  build_kconfig_symbol_index
  [ -n "${KCONFIG_SYMBOL_KNOWN[$sym]:-}" ]
}

apply_config_requests() {
  local o rc=0
  local -a args=()

  if [ "${PROFILE_CHANGED:-false}" = true ]; then
    log "Preparando ${#EFF_ENABLE[@]} activaciones, ${#EFF_DISABLE[@]} desactivaciones, ${#EFF_SETVAL[@]} valores numéricos y ${#EFF_SETSTR[@]} valores de texto..."
  else
    log "Preparando configuración Cizen..."
  fi

  for o in "${EFF_ENABLE[@]}"; do
    if kconfig_symbol_known "$o"; then
      args+=(--enable "$o")
    else
      warn "ENABLE: CONFIG_$o no existe en esta versión; si Kconfig lo renombró, regístralo con: $0 --rename $o=NUEVO_NOMBRE"
    fi
  done

  for o in "${EFF_DISABLE[@]}"; do
    if kconfig_symbol_known "$o"; then
      args+=(--disable "$o")
    fi
  done

  for o in "${!EFF_SETVAL[@]}"; do
    if kconfig_symbol_known "$o"; then
      args+=(--set-val "$o" "${EFF_SETVAL[$o]}")
    else
      warn "SETVAL: CONFIG_$o no existe en el Kconfig de esta versión."
    fi
  done

  for o in "${!EFF_SETSTR[@]}"; do
    if kconfig_symbol_known "$o"; then
      args+=(--set-str "$o" "${EFF_SETSTR[$o]}")
    else
      warn "SETSTR: CONFIG_$o no existe en el Kconfig de esta versión."
    fi
  done

  if [ "${#args[@]}" -gt 0 ]; then
    if ! scripts/config "${args[@]}"; then
      err "scripts/config falló al aplicar el perfil en una única pasada."
      rc=1
    fi
  fi

  return "$rc"
}

run_kconfig_audit() {
  export KCONFIG_WARN_UNKNOWN_SYMBOLS=1
  export KCONFIG_WARN_CHANGED_INPUT=1

  log "Detectando símbolos nuevos antes de olddefconfig..."
  NEWCONFIG_OUTPUT="$(make listnewconfig 2>&1 || true)"
  if printf '%s\n' "$NEWCONFIG_OUTPUT" | grep -qE '^CONFIG_|^# CONFIG_'; then
    # Con parches/BTF activos, sus símbolos aparecerán aquí como nuevos (los
    # introduce el parche). Son esperados; se auditán en la validación vía
    # EXPECTED_REBEL_SET. Aquí solo se informa si hay OTROS.
    if [ "${#PATCH_KCONFIG_FILTER[@]}" -gt 0 ]; then
      local __fs __name_regex=""
      for __fs in "${!PATCH_KCONFIG_FILTER[@]}"; do
        [ -n "$__name_regex" ] && __name_regex="$__name_regex|"
        __name_regex="$__name_regex$__fs"
      done
      unset __fs
      if printf '%s\n' "$NEWCONFIG_OUTPUT" | grep -vE "CONFIG_($__name_regex)" | grep -qE '^CONFIG_|^# CONFIG_'; then
        warn "Se detectaron símbolos nuevos/pendientes (además de los de parches/BTF)."
      fi
      unset __name_regex
    else
      warn "Se detectaron símbolos nuevos/pendientes."
    fi
  fi

  log "Normalizando con olddefconfig..."
  OLDCONFIG_OUTPUT="$(make olddefconfig 2>&1)" || {
    err "olddefconfig falló."
    printf '%s\n' "$OLDCONFIG_OUTPUT" | tail -80 >&2 || true
    return 1
  }
  load_config_state

  # Diffconfig omitido: el flujo de migración Cizen solo necesita
  # detectar símbolos nuevos con listnewconfig y normalizar con olddefconfig.
}

# ============================================================
# VALIDACIÓN INTELIGENTE
# ============================================================
declare -a ENABLE_FAIL=() CRIT_FAIL=() REBEL_NEW=() RETIRED_DISABLE=() DISABLE_WARN=() HARD_DISABLE_FAIL=() NEW_OPTS=()
validate_config() {
  local opt state x
  local enable_ok=0 critical_ok=0 disable_ok=0 expected_rebels=0
  local setval_ok=0 setstr_ok=0
  local fatal_count=0 warning_count=0

  ENABLE_FAIL=(); CRIT_FAIL=(); REBEL_NEW=(); RETIRED_DISABLE=(); DISABLE_WARN=(); HARD_DISABLE_FAIL=(); NEW_OPTS=()

  log "──── VALIDACIÓN ────"

  # 1) Activaciones normales
  for opt in "${EFF_ENABLE[@]}"; do
    state="$(config_symbol_state "$opt")"
    if [ "$state" = y ] || [ "$state" = m ]; then
      enable_ok=$((enable_ok + 1))
    elif [ "$state" = n ]; then
      ENABLE_FAIL+=("CONFIG_$opt quedó n")
      fatal_count=$((fatal_count + 1))
    else
      ENABLE_FAIL+=("CONFIG_$opt no existe")
      warning_count=$((warning_count + 1))
    fi
  done

  # 2) Críticos: únicos y nunca ignorables con --force
  for opt in "${EFF_CRITICAL[@]}"; do
    state="$(config_symbol_state "$opt")"
    if [ "$state" = y ] || [ "$state" = m ]; then
      critical_ok=$((critical_ok + 1))
    else
      CRIT_FAIL+=("CONFIG_$opt=$state")
      fatal_count=$((fatal_count + 1))
    fi
  done

  # 3) Desactivaciones
  # IMPORTANTE: una desactivación que Kconfig conserva NO es fatal por sí sola.
  # Puede deberse a depends on, select, defaults o símbolos generados por la
  # propia arquitectura. Se informa como WARNING y nunca bloquea la build.
  # Los requisitos funcionales se validan exclusivamente mediante CRITICAL_OPTS.
  for opt in "${EFF_DISABLE[@]}"; do
    state="$(config_symbol_state "$opt")"
    case "$state" in
      n|missing)
        disable_ok=$((disable_ok + 1))
        if [ "$state" = missing ]; then
          RETIRED_DISABLE+=("CONFIG_$opt ya no existe en esta versión")
        fi
        ;;
      y|m)
        if [ -n "${EXPECTED_REBEL_SET[$opt]:-}" ]; then
          expected_rebels=$((expected_rebels + 1))
          REBEL_NEW+=("CONFIG_$opt=$state (dependencia esperada)")
        else
          DISABLE_WARN+=("CONFIG_$opt=$state (Kconfig la conserva; revisar dependencia/default/select)")
          warning_count=$((warning_count + 1))
        fi
        ;;
      *)
        DISABLE_WARN+=("CONFIG_$opt=$state (estado no estándar)")
        warning_count=$((warning_count + 1))
        ;;
    esac
  done

  # 4) SETVAL
  for opt in "${!EFF_SETVAL[@]}"; do
    state="$(config_symbol_state "$opt")"
    if [ "$state" = "${EFF_SETVAL[$opt]}" ]; then
      setval_ok=$((setval_ok + 1))
    else
      HARD_DISABLE_FAIL+=("SETVAL CONFIG_$opt esperado=${EFF_SETVAL[$opt]} real=$state")
      fatal_count=$((fatal_count + 1))
    fi
  done

  # 5) SETSTR (compara la línea exacta para conservar comillas)
  for opt in "${!EFF_SETSTR[@]}"; do
    local expected_line="CONFIG_${opt}=\"${EFF_SETSTR[$opt]}\""
    if grep -Fxq "$expected_line" .config; then
      setstr_ok=$((setstr_ok + 1))
    else
      HARD_DISABLE_FAIL+=("SETSTR CONFIG_$opt esperado=\"${EFF_SETSTR[$opt]}\"")
      fatal_count=$((fatal_count + 1))
    fi
  done

  # 6) Nuevos símbolos: listnewconfig es la referencia oficial de migración.
  if printf '%s\n' "$NEWCONFIG_OUTPUT" | grep -qE '^CONFIG_|^# CONFIG_'; then
    while IFS= read -r line; do
      [[ "$line" =~ ^CONFIG_[A-Z0-9_]+= ]] || [[ "$line" =~ ^#\ CONFIG_[A-Z0-9_]+\ is\ not\ set ]] || continue
      local new_sym=""
      if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)= ]]; then
        new_sym="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
        new_sym="${BASH_REMATCH[1]}"
      else
        continue
      fi
      if [ -n "${EXPECTED_REBEL_SET[$new_sym]:-}" ]; then
        continue
      fi
      NEW_OPTS+=("$line")
    done <<< "$NEWCONFIG_OUTPUT"
    if [ "${#NEW_OPTS[@]}" -gt 0 ]; then
      warning_count=$((warning_count + ${#NEW_OPTS[@]}))
    fi
  fi

  # 7) No se genera reporte persistente: la salida relevante se muestra en consola.
  # Consola
  if [ "$fatal_count" -eq 0 ]; then
    ok "[ENABLE]   $enable_ok/${#EFF_ENABLE[@]} activaciones satisfechas"
    ok "[CRITICAL] $critical_ok/${#EFF_CRITICAL[@]} críticos presentes"
    ok "[DISABLE]  $disable_ok/${#EFF_DISABLE[@]} desactivaciones resueltas ($expected_rebels rebeldes esperados)"
    ok "[SETVAL]   $setval_ok/${#EFF_SETVAL[@]} valores numéricos"
    ok "[SETSTR]   $setstr_ok/${#EFF_SETSTR[@]} valores de texto"
  else
    err "Se detectaron $fatal_count fallos FATALES en la configuración."
    for x in "${CRIT_FAIL[@]}"; do err "  [CRÍTICO] $x"; done
    for x in "${ENABLE_FAIL[@]}"; do err "  [ENABLE] $x"; done
  fi

  # Las retenciones ESPERADAS de Kconfig (rebeldes conocidos) son solo
  # informativas. Todo lo demás recopilado abajo es un WARNING real y se
  # imprime con su detalle completo, no solo como conteo, para que --strict
  # (y una lectura humana del log) puedan actuar sobre la causa exacta.

  if [ "${#NEW_OPTS[@]}" -gt 0 ]; then
    warn "Hay ${#NEW_OPTS[@]} símbolos nuevos/pendientes:"
    for x in "${NEW_OPTS[@]}"; do warn "    $x"; done
  fi
  if [ "${#DISABLE_WARN[@]}" -gt 0 ]; then
    warn "Hay ${#DISABLE_WARN[@]} desactivaciones que Kconfig NO resolvió como se esperaba:"
    for x in "${DISABLE_WARN[@]}"; do warn "    $x"; done
  fi

  if [ "${#APPLIED_RENAMES[@]}" -gt 0 ]; then
    warn "Renombres aplicados:"
    while IFS= read -r opt; do
      printf '    %s → %s\n' "$opt" "${APPLIED_RENAMES[$opt]}"
    done < <(printf '%s\n' "${!APPLIED_RENAMES[@]}" | sort)
  fi

  # Los fallos críticos y los requisitos explícitos no satisfechos bloquean siempre.
  if [ "${#HARD_DISABLE_FAIL[@]}" -gt 0 ]; then
    for x in "${HARD_DISABLE_FAIL[@]}"; do err "  [CONFIG-FATAL] $x"; done
  fi
  if [ "$fatal_count" -gt 0 ]; then
    err "VALIDACIÓN FATAL: no se permite continuar con --force."
    return 2
  fi

  # --strict convierte warnings de auditoría en error, pero --force NO debe
  # saltarse nunca los fallos críticos. La lógica de críticos está separada.
  if [ "$STRICT" = true ] && [ "$warning_count" -gt 0 ]; then
    err "--strict: warnings presentes; se aborta."
    return 3
  fi

  return 0
}

# ============================================================
# DIFF DE CONFIG vs KERNEL EN EJECUCIÓN  (feature 1)
# ============================================================
# Compara la .config efectiva ya normalizada (CONFIG_STATE) contra la del kernel
# que está arrancado (/proc/config.gz), aplicando los renames del perfil
# (APPLIED_RENAMES) para no marcar como cambio un símbolo renombrado. Solo
# informa; nunca bloquear. Cambiados = presentes en ambos con valor distinto;
# nuevos/retirados = solo en uno de los dos (típicamente por el bump de versión).
report_config_diff() {
  if ! zcat /proc/config.gz >/dev/null 2>&1; then
    warn "No se puede leer la config del kernel en ejecución (/proc/config.gz); se omite el diff."
    return 0
  fi

  local -A inst=()
  local line sym val
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)=(.*)$ ]]; then
      inst["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
      inst["${BASH_REMATCH[1]}"]="n"
    fi
  done < <(zcat /proc/config.gz 2>/dev/null)

  local -a changed=() added=() removed=()
  local oldsym newsym runstate newstate newname

  # Cambiados: el símbolo existe en el kernel en ejecución y el perfil lo cambió.
  # Si el perfil renombró el símbolo (APPLIED_RENAMES[old]=new), se compara el
  # valor de inst[old] contra CONFIG_STATE[new] y no se reporta si coinciden.
  for oldsym in "${!inst[@]}"; do
    runstate="${inst[$oldsym]}"
    [ -n "${CONFIG_STATE[$oldsym]+x}" ] || continue
    newname="${APPLIED_RENAMES[$oldsym]:-}"
    if [ -n "$newname" ] && [ -n "${CONFIG_STATE[$newname]+x}" ]; then
      [ "${CONFIG_STATE[$newname]}" = "$runstate" ] && continue
    fi
    if [ "${CONFIG_STATE[$oldsym]}" != "$runstate" ]; then
      changed+=("CONFIG_$oldsym $runstate → ${CONFIG_STATE[$oldsym]}")
    fi
  done

  # "nuevos": en la config nueva pero ausentes en el kernel en ejecución.
  for sym in "${!CONFIG_STATE[@]}"; do
    [ -n "${inst[$sym]+x}" ] || added+=("CONFIG_$sym")
  done
  # "retirados": presentes en el kernel en ejecución pero ausentes en la nueva.
  for sym in "${!inst[@]}"; do
    [ -n "${CONFIG_STATE[$sym]+x}" ] || removed+=("CONFIG_$sym")
  done

  ok "Diff vs kernel en ejecución: ${#changed[@]} cambiados / ${#added[@]} nuevos / ${#removed[@]} retirados"
  if [ "${#changed[@]}" -gt 0 ]; then
    info "Cambios de config (máx. 15):"
    local i=0 c
    for c in "${changed[@]}"; do
      if [ "$i" -ge 15 ]; then
        info "  … y $(( ${#changed[@]} - 15 )) más"
        break
      fi
      printf '    %s\n' "$c"
      i=$((i + 1))
    done
  fi
  return 0
}

# ============================================================
# ABSORCIÓN DE REBELDES EN EL PERFIL  (--absorb-rebels)
# ============================================================
# Cuando una desactivación de OPTS_DISABLE es conservada por Kconfig a =y/=m
# por dependencias internas (depends on/select/defaults), la revalidación la
# reporta una y otra vez como WARNING. --absorb-rebels mueve esos símbolos de
# OPTS_DISABLE a EXPECTED_REBELS en el archivo de perfil (con backup), de modo
# que en futuras ejecuciones cuenten como rebeldes esperados y el chequeo quede
# limpio. La decisión de conservar el símbolo es de Kconfig, no nuestra: solo
# se absorbe lo que la validación ya demostró que no se puede desactivar.
absorb_rebels_to_profile() {
  local symline sym
  local -a absorb=()

  # DISABLE_WARN son líneas "CONFIG_X=estado (Kconfig la conserva...)".
  # Extraemos el nombre integro del símbolo (la parte antes del primer '=').
  for symline in "${DISABLE_WARN[@]}"; do
    sym="${symline%%=*}"
    sym="${sym#CONFIG_}"
    [ -n "$sym" ] && absorb+=("$sym")
  done

  if [ "${#absorb[@]}" -eq 0 ]; then
    info "--absorb-rebels: no hay desactivaciones conservadas que mover."
    return 0
  fi

  log "Absorbiendo ${#absorb[@]} símbolos conservados por Kconfig a EXPECTED_REBELS..."
  for symline in "${absorb[@]}"; do
    info "  → $symline"
  done

  # Los símbolos absorbidos deben borrarse de OPTS_DISABLE en el array de
  # UNO en UNO porque pueden compartir línea literal con otros símbolos
  # (p.ej. `"A" "B" "C"`); borrar la línea entera eliminaría vecinos legítimos.
  # Estructura del perfil: declare -a OPTS_DISABLE=( ... ) y
  # declare -a EXPECTED_REBELS=( ... ). Este awk edita ambas secciones.
  local awk_prog='
    BEGIN {
      n = split(AWS, S, " ")
      for (i = 1; i <= n; i++) q[i] = "\"" S[i] "\""
      for (i = 1; i <= n; i++) still_absent[i] = 1
      in_disable = 0
      in_rebels = 0
    }
    /^declare -a OPTS_DISABLE=\(/ { in_disable = 1; print; next }
    in_disable && /^\)/ { in_disable = 0; print; next }
    /^declare -a EXPECTED_REBELS=\(/ { in_rebels = 1; print; next }
    in_rebels && /^\)/ {
      to_add = 0
      for (i = 1; i <= n; i++)
        if (still_absent[i]) to_add = 1
      if (to_add) print "# Absorbidos por --absorb-rebels: Kconfig los conserva por dependencia."
      for (i = 1; i <= n; i++)
        if (still_absent[i]) print q[i]
      if (to_add) print "# ---"
      print
      in_rebels = 0
      next
    }
    in_disable {
      line = $0
      if (line ~ /^[[:space:]]*#/) { print line; next }
      for (i = 1; i <= n; i++) {
        while (line ~ ("^[[:space:]]*" q[i]))
          sub("^[[:space:]]*" q[i], "", line)
        while (line ~ (q[i] "[[:space:]]*"))
          sub(q[i] "[[:space:]]*", "", line)
      }
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      if (line != "") print line
      next
    }
    in_rebels {
      for (i = 1; i <= n; i++)
        if (index($0, q[i]) > 0) still_absent[i] = 0
      print
      next
    }
    { print }
  '
  local syms tmpfile backup
  syms="${absorb[*]}"
  tmpfile="$(mktemp "${PROFILE_FILE}.XXXXXX")" || return 1

  if ! awk -v AWS="$syms" "$awk_prog" "$PROFILE_FILE" > "$tmpfile"; then
    rm -f "$tmpfile"
    err "Fallo al reescribir el perfil (awk)."
    return 1
  fi

  if ! bash -n "$tmpfile"; then
    rm -f "$tmpfile"
    err "El perfil reescrito no es Bash válido; se conserva el original."
    return 1
  fi

  touch "$tmpfile"
  # Backup con timestamp antes de sustituir.
  backup="${PROFILE_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
  if ! cp -a -- "$PROFILE_FILE" "$backup"; then
    rm -f "$tmpfile"
    err "No se pudo crear backup del perfil en $backup"
    return 1
  fi

  if ! mv -f -- "$tmpfile" "$PROFILE_FILE"; then
    rm -f "$tmpfile" "$backup"
    err "No se pudo sustituir el perfil (mv)."
    return 1
  fi

  ok "Perfil actualizado: ${#absorb[@]} símbolos movidos de OPTS_DISABLE a EXPECTED_REBELS."
  info "Backup del perfil previo: $backup"
  info "Revísalo si el cambio te resulta inesperado (los símbolos son los que Kconfig conserva de forma efectiva)."
  return 0
}

# ============================================================
# REPRODUCIBILIDAD / PACKAGE DISCOVERY
# ============================================================
# El nombre del kernel uname -r sigue siendo VERSION-cizen-v3. El nombre de
# paquete Arch es linux-cizen-v3 y es deliberadamente distinto: mkinitcpio
# toma pkgbase del paquete para usar linux-cizen-v3.preset.

verify_build_tree() {
  [ -f .config ] || fatal "No existe .config antes de compilar."
  [ "$(make -s kernelversion)" = "$VERSION" ] || fatal "La versión del árbol no coincide con $VERSION."

  # Estos cuatro símbolos deben quedar compilados DIRECTAMENTE en el kernel
  # (=y, nunca módulo) porque el arranque de este equipo depende de una UKI
  # sin initramfs: no hay forma de cargar un módulo antes de tener KMS
  # temprano ni de montar la raíz Btrfs. Se resuelven con resolve_symbol()
  # igual que el resto del perfil, para que un renombre futuro de Kconfig
  # (registrado con --rename) se aplique aquí también en vez de producir un
  # fatal sin explicación.
  local -a boot_critical=(X86_NATIVE_CPU BTRFS_FS DRM_I915 KVM_SMM)
  local sym resolved state
  for sym in "${boot_critical[@]}"; do
    resolved="$(resolve_symbol "$sym")"
    state="$(config_symbol_state "$resolved")"
    if [ "$state" != y ]; then
      fatal "Falta CONFIG_${resolved}=y (crítico para el arranque sin initramfs de este equipo; estado actual: $state)"
    fi
  done
}

prepare_package_identity_override() {
  local pkgbuilder="$SRC/scripts/package/PKGBUILD"
  local backup="${pkgbuilder}.cizen-orig"

  [ -f "$pkgbuilder" ] || fatal "No existe $pkgbuilder; no se puede fijar el pkgbase Cizen."

  # El PKGBUILD oficial usa PACMAN_PKGBASE cuando está disponible. Lo forzamos
  # al nombre Cizen para que el paquete generado se llame linux-cizen-v3 y,
  # sobre todo, para que el archivo /usr/lib/modules/<release>/pkgbase contenga
  # linux-cizen-v3; mkinitcpio utiliza ese valor para resolver el preset.
  # Si una ejecución anterior murió sin alcanzar EXIT (por ejemplo, corte
  # de energía o SIGKILL), recuperamos primero la receta original conservada.
  if [ -f "$backup" ]; then
    mv -f -- "$backup" "$pkgbuilder"
  fi
  cp -f -- "$pkgbuilder" "$backup"

  if ! grep -Fq 'PACMAN_PKGBASE' "$pkgbuilder"; then
    fatal "El PKGBUILD no expone el selector PACMAN_PKGBASE esperado; se aborta para no parchear una receta incompatible."
  fi
  if ! grep -Fq 'eval "package_' "$pkgbuilder" && ! grep -Fq 'package_${pkgbase}' "$pkgbuilder"; then
    fatal "El PKGBUILD no genera dinámicamente las funciones package_*; no se puede cambiar pkgbase con seguridad en este árbol."
  fi

  # Añadimos metadata temporal de transición SOLO dentro de la función
  # _package() del paquete principal. El PKGBUILD oficial genera luego las
  # funciones package_${pkgname}() dinámicamente: así conflicts/replaces/provides
  # se aplican a linux-cizen-v3, pero NO se heredan a -headers/-api-headers/-debug.
  # No se modifica permanentemente el árbol de fuentes: restore_* lo revierte.
  if ! grep -Fq "conflicts=(\"$LEGACY_PKGBASE\")" "$pkgbuilder"; then
    local pkgtmp
    pkgtmp="${pkgbuilder}.cizen-meta-${TS}"
    awk -v legacy="$LEGACY_PKGBASE" '
      BEGIN { inserted=0 }
      /^_package[[:space:]]*\(\)[[:space:]]*\{/ && !inserted {
        print
        printf "\tconflicts=(\"%s\")\n", legacy
        printf "\treplaces=(\"%s\")\n", legacy
        printf "\tprovides=(\"%s\")\n", legacy
        inserted=1
        next
      }
      { print }
    ' "$pkgbuilder" > "$pkgtmp" || { rm -f -- "$pkgtmp"; fatal "No se pudo preparar el PKGBUILD Cizen para la transición de paquete."; }
    chmod --reference="$pkgbuilder" "$pkgtmp" 2>/dev/null || true
    mv -f -- "$pkgtmp" "$pkgbuilder" || { rm -f -- "$pkgtmp"; fatal "No se pudo activar el PKGBUILD Cizen temporal."; }
  fi

  # El selector de pkgbase debe existir y la función principal donde se inyecta
  # la metadata debe seguir presente; si no, no aceptamos una receta incompatible.
  grep -Eq '^_package[[:space:]]*\(\)[[:space:]]*\{' "$pkgbuilder" || \
    fatal "El PKGBUILD no contiene la función _package() esperada; no se puede fijar metadata de transición de forma segura."

  ok "pkgbase Cizen configurado: $CIZEN_PKGBASE (reemplaza $LEGACY_PKGBASE si está instalado)"
}

restore_package_identity_override() {
  local pkgbuilder="$SRC/scripts/package/PKGBUILD"
  local backup="${pkgbuilder}.cizen-orig"

  if [ -f "$backup" ]; then
    mv -f -- "$backup" "$pkgbuilder"
  fi
}

prepare_package_revision_override() {
  local makefile="$SRC/scripts/Makefile.package"
  local backup="${makefile}.cizen-orig"

  [ -f "$makefile" ] || fatal "No existe $makefile; no se puede fijar el pkgrel."

  # scripts/Makefile.package fuerza actualmente KBUILD_REVISION a la salida
  # de scripts/build-version dentro de la receta pacman-pkg. Eso sobrescribe
  # el valor que pasamos desde el shell. Para que el pkgrel calculado por
  # este script sea realmente el que usa makepkg, sustituimos únicamente esa
  # asignación por la variable Kbuild ya calculada.
  if grep -Fq 'KBUILD_REVISION="$(shell $(srctree)/scripts/build-version)"' "$makefile"; then
    cp -f -- "$makefile" "$backup"
    sed -i \
      's@KBUILD_REVISION="$(shell $(srctree)/scripts/build-version)"@KBUILD_REVISION="$(KBUILD_REVISION)"@' \
      "$makefile"
  fi

  if ! grep -Fq 'KBUILD_REVISION="$(KBUILD_REVISION)"' "$makefile"; then
    fatal "No se pudo aplicar el override de KBUILD_REVISION en Makefile.package."
  fi

  ok "Override de pkgrel activo: KBUILD_REVISION=$PKGREL"
}

restore_package_revision_override() {
  local makefile="$SRC/scripts/Makefile.package"
  local backup="${makefile}.cizen-orig"

  if [ -f "$backup" ]; then
    mv -f -- "$backup" "$makefile"
    ok "Makefile.package original restaurado"
  fi
}

prepare_package_pruning_override() {
  local pkgbuilder="$SRC/scripts/package/PKGBUILD"

  [ -f "$pkgbuilder" ] || fatal "No existe $pkgbuilder; no se puede activar la poda de módulos."

  # La poda es opt-in robusta: sin podador ejecutable no se falla, se omite.
  if [ ! -x "$PRUNER_SCRIPT" ]; then
    if [ "$PRUNE_MODULES" = "1" ]; then
      warn "Podador de módulos no encontrado/ejecutable ($PRUNER_SCRIPT); se compila SIN poda."
      PRUNE_MODULES=0
    fi
    return 0
  fi
  [ "$PRUNE_MODULES" = "1" ] || return 0

  # Añadimos la invocación SOLO dentro de _package(): tras el modules_install
  # (que deja el árbol completo en ${modulesdir}). Depende de variables de
  # entorno exportadas por este motor antes de `make pacman-pkg`; makepkg las
  # hereda al fakeroot que ejecuta package(). Guardas: si el podador falla o
  # no está, `|| true` conserva el conjunto completo (nunca rompe la build).
  # restore_package_identity_override() revierte esta modificación con el
  # respaldo .cizen-orig; no necesita backup propio.
  if ! grep -Fq 'modules_install' "$pkgbuilder"; then
    fatal "El PKGBUILD no contiene modules_install; no se puede inyectar la poda de módulos."
  fi
  if ! grep -Fq 'CIZEN_PRUNE_MODULES' "$pkgbuilder"; then
    local pkgtmp
    pkgtmp="${pkgbuilder}.cizen-prune-${TS}"
    awk '
      BEGIN { inserted=0 }
      /modules_install/ && !inserted {
        print
        printf "\tif [ \"${CIZEN_PRUNE_MODULES:-0}\" = \"1\" ] && [ -n \"${CIZEN_PRUNE_SCRIPT:-}\" ] && [ -x \"${CIZEN_PRUNE_SCRIPT}\" ]; then\n"
        printf "\t\t\"${CIZEN_PRUNE_SCRIPT}\" \"${modulesdir}\" \"${CIZEN_KEEP_MODULES:-}\" || true\n"
        printf "\tfi\n"
        inserted=1
        next
      }
      { print }
    ' "$pkgbuilder" > "$pkgtmp" || { rm -f -- "$pkgtmp"; fatal "No se pudo inyectar la poda de módulos en el PKGBUILD."; }
    chmod --reference="$pkgbuilder" "$pkgtmp" 2>/dev/null || true
    mv -f -- "$pkgtmp" "$pkgbuilder" || { rm -f -- "$pkgtmp"; fatal "No se pudo activar el PKGBUILD con poda de módulos."; }
  fi

  ok "Poda de módulos activa: $PRUNER_SCRIPT (CIZEN_KEEP_MODULES=${CIZEN_KEEP_MODULES:--})"
}

restore_package_pruning_override() {
  # La poda vive dentro del PKGBUILD parcheado por prepare_package_identity_override;
  # restaurarlo también la elimina. Sin embargo, si una ejecución previa dejó el
  # backup sin alcanzar EXIT (SIGKILL/catástrofe), el flujo normal de
  # restore_package_identity_override lo recupera igual; nada que hacer aquí.
  :
}

determine_pkgrel() {
  local pattern file base rel max_rel=0 installed_ver installed_rel

  PKGVER_BASE="${VERSION}${LOCALVERSION_SUFFIX}"
  PKGVER_BASE="${PKGVER_BASE//-/_}"
  pattern="${CIZEN_PKGBASE}-${PKGVER_BASE}-*-x86_64.pkg.tar.zst"

  # El pkgrel del paquete Arch debe crecer en cada recompilación de la misma
  # versión del kernel. Los paquetes de builds anteriores permanecen dentro
  # del único árbol de fuentes conservado en el tmpfs y también sirven como
  # referencia para incrementar el pkgrel.
  shopt -s nullglob
  for file in "$SRC"/$pattern; do
    base="$(basename "$file")"
    if [[ "$base" =~ ^${CIZEN_PKGBASE}-${PKGVER_BASE}-([0-9]+)-x86_64\.pkg\.tar\.zst$ ]]; then
      rel="${BASH_REMATCH[1]}"
      if (( rel > max_rel )); then
        max_rel="$rel"
      fi
    fi
  done
  shopt -u nullglob

  if pacman -Q "$CIZEN_PKGBASE" >/dev/null 2>&1; then
    installed_ver="$(pacman -Q "$CIZEN_PKGBASE" | awk 'NR==1 {print $2}')"
    if [[ "$installed_ver" =~ ^${PKGVER_BASE}-([0-9]+)$ ]]; then
      installed_rel="${BASH_REMATCH[1]}"
      if (( installed_rel > max_rel )); then
        max_rel="$installed_rel"
      fi
    fi
  fi

  PKGREL=$((max_rel + 1))
  [ "$PKGREL" -ge 1 ] || fatal "pkgrel calculado inválido: $PKGREL"

  log "pkgver objetivo: $PKGVER_BASE"
  log "pkgrel siguiente: $PKGREL"
}

copy_packages_from_build() {
  local -a generated=() pkgs=() pkg
  local main_pkg="" pkg_meta

  # No confiamos en el orden de `ls` ni en el espaciado de `pacman -Qip`.
  # El paquete se identifica primero por el nombre de archivo generado por
  # kbuild, igual que el script original, y después se valida con pacman.
  mapfile -t generated < <(find "$SRC" -maxdepth 1 -type f -name '*.pkg.tar.zst' -newer "$BUILD_MARKER" \
    -print | sort -V)

  for pkg in "${generated[@]}"; do
    case "$(basename "$pkg")" in
      *debug*|*headers*) continue ;;
    esac
    case "$(basename "$pkg")" in
      ${CIZEN_PKGBASE}-*[cC]izen_v3-*.pkg.tar.zst) pkgs+=("$pkg") ;;
    esac
  done

  if [ "${#pkgs[@]}" -eq 0 ]; then
    err "No se encontró el paquete principal ${CIZEN_PKGBASE} *cizen_v3 generado por esta build."
    if [ "${#generated[@]}" -gt 0 ]; then
      warn "Artefactos pkg.tar.zst encontrados en la build:"
      for pkg in "${generated[@]}"; do printf '    %s\n' "$(basename "$pkg")"; done
    fi
    return 1
  fi

  log "Paquete(s) kernel elegibles generados en esta build:"
  for pkg in "${pkgs[@]}"; do
    printf '    %s\n' "$(basename "$pkg")"
  done

  if [ "${#pkgs[@]}" -gt 1 ]; then
    warn "Se generaron ${#pkgs[@]} paquetes principales; se selecciona el último por versión."
  fi
  main_pkg="$(printf '%s\n' "${pkgs[@]}" | sort -V | tail -n1)"

  [ -s "$main_pkg" ] || { err "El paquete seleccionado está vacío: $main_pkg"; return 1; }

  # El paquete se instala directamente desde el mismo árbol tmpfs de la build.
  # No se mantiene una segunda copia persistente en $HOME.
  PKG="$main_pkg"
  [ -s "$PKG" ] || { err "El paquete generado no existe o está vacío: $PKG"; return 1; }

  # Validamos la metadata interna del archivo .pkg.tar.zst directamente.
  # Esto evita depender del formato/semántica de salida de `pacman -Qp`.
  # .PKGINFO es parte del formato del paquete Arch y contiene pkgname/pkgver.
  pkg_meta="$(tar -xOf "$PKG" .PKGINFO 2>/dev/null || true)"
  PKG_NAME="$(printf '%s\n' "$pkg_meta" | sed -n 's/^pkgname = //p' | head -n1)"
  PKG_VERSION="$(printf '%s\n' "$pkg_meta" | sed -n 's/^pkgver = //p' | head -n1)"

  if [ -z "$PKG_NAME" ] || [ -z "$PKG_VERSION" ]; then
    err "No se pudo leer pkgname/pkgver desde .PKGINFO de $(basename "$PKG")."
    return 1
  fi

  if [[ "$PKG_NAME" != "$CIZEN_PKGBASE" ]]; then
    err "Paquete inesperado según .PKGINFO: $PKG_NAME (se esperaba $CIZEN_PKGBASE)."
    return 1
  fi

  if [[ "$(basename "$PKG")" != "${CIZEN_PKGBASE}-${PKGVER_BASE}-${PKGREL}-x86_64.pkg.tar.zst" ]]; then
    err "El nombre del paquete ($(basename "$PKG")) no coincide con el pkgrel esperado ($PKGREL)."
    return 1
  fi

  if [[ "$PKG_VERSION" != "$PKGVER_BASE-$PKGREL" ]]; then
    err "La versión interna del paquete ($PKG_VERSION) no coincide con la esperada ($PKGVER_BASE-$PKGREL)."
    return 1
  fi

  ok "Paquete verificado: $(basename "$PKG") ($PKG_NAME $PKG_VERSION)"
}

validate_split_package_transition_metadata() {
  local item base meta field value
  [ -d "$SRC" ] || return 0
  shopt -s nullglob
  for item in "$SRC"/*.pkg.tar.zst; do
    [ -f "$item" ] || continue
    [ -n "${BUILD_MARKER:-}" ] && [ -f "$BUILD_MARKER" ] && [ "$item" -nt "$BUILD_MARKER" ] || continue
    base="$(basename -- "$item")"
    case "$base" in
      *-headers-*.pkg.tar.zst|*-api-headers-*.pkg.tar.zst|*-debug-*.pkg.tar.zst) ;;
      *) continue ;;
    esac

    meta="$(tar -xOf "$item" .PKGINFO 2>/dev/null || true)"
    for field in conflict replace provides; do
      value="$(printf '%s\n' "$meta" | sed -n "s/^${field} = //p" || true)"
      if printf '%s\n' "$value" | grep -Fxq "$LEGACY_PKGBASE"; then
        shopt -u nullglob
        fatal "Metadata de transición filtrada al subpaquete $(basename -- "$item"): ${field}=$LEGACY_PKGBASE. La metadata debe pertenecer únicamente al paquete principal $CIZEN_PKGBASE."
      fi
    done
  done
  shopt -u nullglob
}

# El árbol de fuentes se conserva a propósito entre ejecuciones (ver
# unmount_tmpfs_build), pero eso significa que cada recompilación de la
# MISMA versión (probando el perfil, ajustando pkgrel, etc.) dejaba atrás
# los .pkg.tar.zst de builds anteriores sin que nada los limpiara jamás,
# compitiendo por el espacio de un tmpfs de tamaño fijo. Tras una
# instalación exitosa, pacman ya es la fuente de verdad para el pkgrel
# instalado (determine_pkgrel también consulta `pacman -Q`), así que es
# seguro podar aquí los pkgrel anteriores de esta misma versión.
prune_stale_packages() {
  local item base
  [ -d "$SRC" ] || return 0
  shopt -s nullglob
  for item in "$SRC"/"${CIZEN_PKGBASE}"*-"${PKGVER_BASE}"-*-x86_64.pkg.tar.zst; do
    base="$(basename -- "$item")"
    case "$base" in
      *"-${PKGVER_BASE}-${PKGREL}-x86_64.pkg.tar.zst") continue ;;
    esac
    rm -f -- "$item"
    log "Paquete de un pkgrel anterior eliminado del tmpfs: $base"
  done
  shopt -u nullglob
}

# ============================================================
# ROLLBACK DUAL-KERNEL  (feature 3)
# ============================================================
# Antes de instalar una versión nueva se archiva el kernel EN EJECUCIÓN
# (sus módulos + /boot/vmlinuz-linux-cizen-v3 + cmdline) en $ROLLBACK_DIR.
# kernel-update-rollback.sh (krollback) lo restaura y regenera la UKI.
# Solo se conserva el ÚLTIMO archive (el kernel previo al actual); los más
# antiguos se podan para mantener "actual + previo".
SNAPSHOT_DESC=""

prepare_rollback_archive() {
  local rel modules vmlinuz tmp
  rel="$(uname -r 2>/dev/null || true)"
  [ -n "$rel" ] || { warn "No se puede leer uname -r; no se guarda archive de rollback."; return 0; }
  # Nunca volver a archivar la versión que acabamos de dejar de arrancar si ya
  # existe un archive de la misma release: no vale la pena overwrite. Aún así se
  # poda por si quedaran archives antiguos de sesiones previas.
  [ -f "$ROLLBACK_DIR/$rel.tar.xz" ] && { info "Rollback ya existe para $rel; se conserva."; prune_rollback_archives; return 0; }

  modules="/usr/lib/modules/$rel"
  vmlinuz="/boot/vmlinuz-linux-cizen-v3"
  [ -d "$modules" ] && [ -s "$modules/vmlinuz" ] && vmlinuz="$modules/vmlinuz"
  [ -d "$modules" ] || { warn "No hay módulos para $rel ($modules); rollback omitido."; return 0; }

  if ! sudo mkdir -p -- "$ROLLBACK_DIR" 2>/dev/null; then
    warn "No se pudo crear $ROLLBACK_DIR; rollback omitido."
    return 0
  fi

  tmp="$ROLLBACK_DIR/.archive-$$.tmp"
  sudo rm -f -- "$tmp" 2>/dev/null
  if sudo tar --xz -cf "$tmp" -C / \
       "usr/lib/modules/$rel" \
       "boot/vmlinuz-linux-cizen-v3" \
       "boot/EFI/Linux/arch-linux-cizen-v3.efi" 2>/dev/null; then
    if [ -s "$tmp" ]; then
      sudo mv -f -- "$tmp" "$ROLLBACK_DIR/$rel.tar.xz" 2>/dev/null || {
        sudo rm -f -- "$tmp" 2>/dev/null
        warn "No se pudo mover el archive de rollback a $ROLLBACK_DIR/$rel.tar.xz."
        return 0
      }
      printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | sudo tee "$ROLLBACK_DIR/$rel.timestamp" >/dev/null 2>&1 || true
      VERIFY_ROLLBACK_FILE="$ROLLBACK_DIR/$rel.tar.xz"
      ok "Rollback preparado: $ROLLBACK_DIR/$rel.tar.xz (kernel en ejecución $rel)"
    else
      sudo rm -f -- "$tmp" 2>/dev/null
      warn "Archive de rollback vacío; omitido."
    fi
  else
    sudo rm -f -- "$tmp" 2>/dev/null
    warn "No se pudo crear el archive de rollback de $rel."
  fi

  prune_rollback_archives
  return 0
}

# Conserva SOLO un archive de rollback: el del kernel PREVIO al actual.
# Prioridad al de mayor versión que NO sea la release en ejecución (el
# "anterior"); si todos coincidieran con el actual, se conserva el de mayor
# versión. Nunca acumula más de uno.
prune_rollback_archives() {
  local running="" keep="" base="" candidate=""
  local -a archives=() keep_list=()
  shopt -s nullglob
  archives=("$ROLLBACK_DIR"/*.tar.xz)
  shopt -u nullglob
  [ "${#archives[@]}" -le 1 ] && return 0

  running="$(uname -r 2>/dev/null || true)"
  for keep in "${archives[@]}"; do
    base="$(basename -- "$keep")"
    case "$base" in
      "$running.tar.xz") continue ;;
    esac
    keep_list+=("$keep")
  done

  if [ "${#keep_list[@]}" -eq 0 ]; then
    candidate="$(printf '%s\n' "${archives[@]}" | sort -V | tail -n1)"
  else
    candidate="$(printf '%s\n' "${keep_list[@]}" | sort -V | tail -n1)"
  fi
  [ -n "$candidate" ] || return 0

  for keep in "${archives[@]}"; do
    [ "$keep" = "$candidate" ] && continue
    base="$(basename -- "$keep")"
    log "Pruning archive de rollback antiguo: $base"
    sudo rm -f -- "$keep" "${keep%.tar.xz}.timestamp" 2>/dev/null || true
  done
}

# ============================================================
# SNAPSHOT BTRFS READONLY DEL ROOT PRE-INSTALACIÓN  (feature 4)
# ============================================================
# Si / es btrfs y CIZEN_SNAPSHOT != 0, se monta el filesystem sin subvol en un
# punto temporal y se crea un snapshot readonly del subvol raíz en
# .snapshots/@kernel-<versión>-<ts>. Fallo blando (warn): es una red de
# seguridad, no un requisito del flujo.
create_btrfs_snapshot() {
  [ "${CIZEN_SNAPSHOT:-1}" = "1" ] || { info "Snapshot btrfs desactivado (CIZEN_SNAPSHOT=0)."; return 0; }
  command -v btrfs >/dev/null 2>&1 || { info "btrfs-progs no instalado; snapshot omitido."; return 0; }
  local fstype
  fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  [ "$fstype" = "btrfs" ] || { info "La raíz no es btrfs ($fstype); snapshot omitido."; return 0; }

  local topdev tmp snapname dst
  topdev="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [ -n "$topdev" ] || { warn "No se pudo resolver el dispositivo btrfs de /; snapshot omitido."; return 0; }
  tmp="$(mktemp -d /tmp/cizen-snap.XXXXXX 2>/dev/null)" || { warn "No se pudo crear temporal; snapshot omitido."; return 0; }

  if ! sudo mount -o subvol=/ "$topdev" "$tmp" >/dev/null 2>&1; then
    rmdir -- "$tmp" 2>/dev/null || true
    warn "No se pudo montar el btrfs top-level; snapshot omitido."
    return 0
  fi

  sudo mkdir -p -- "$tmp/$SNAPSHOT_SUBVOL" 2>/dev/null
  snapname="kernel-$VERSION-$(date +%Y%m%d-%H%M%S)"
  dst="$tmp/$SNAPSHOT_SUBVOL/@$snapname"
  if sudo btrfs subvolume snapshot -r / "$dst" >/dev/null 2>&1; then
    ok "Snapshot btrfs readonly de la raíz: subvol=/$SNAPSHOT_SUBVOL/@$snapname (kernel $VERSION)"
    SNAPSHOT_DESC="$SNAPSHOT_SUBVOL/@$snapname"
  else
    warn "No se pudo crear el snapshot btrfs readonly; se continúa sin él."
  fi

  sudo umount "$tmp" >/dev/null 2>&1 || true
  rmdir -- "$tmp" 2>/dev/null || true
  return 0
}

# ============================================================
# FIRMA DEL BUILD PARA EL VERIFICADOR POST-BOOT  (feature 2)
# ============================================================
# El servicio kernel-update-verify.sh lee este fichero tras el reboot para
# comprobar que el kernel que arrancó cumple lo que este build prometió
# (incluido el scheduler BORE).
write_verify_signature() {
  local profile_hash="" rel
  mkdir -p -- "$VERIFY_STATE_DIR" 2>/dev/null || true
  [ -f "$PROFILE_FILE" ] && profile_hash="$(sha256sum "$PROFILE_FILE" | cut -d' ' -f1 2>/dev/null || true)"
  rel="${VERSION}${LOCALVERSION_SUFFIX}"
  {
    printf 'version=%s\n' "$rel"
    printf 'bore=%s\n' "$([ "$BORE_ENABLED" = true ] && echo yes || echo no)"
    if [ "${#PATCHES_APPLIED[@]}" -gt 0 ]; then
      # bore permanece aparte por compatibilidad; el resto de parches van en patches=.
      printf 'patches=%s\n' "${PATCHES_APPLIED[*]}"
    fi
    printf 'btf=%s\n' "$([ "$BTF_REQUESTED" = true ] && echo yes || echo no)"
    printf 'clang=%s\n' "$([ "$CLANG_BUILD" = true ] && echo yes || echo no)"
    printf 'pkgrel=%s\n' "$PKGREL"
    printf 'profile_sha=%s\n' "${profile_hash:-}"
    printf 'ts=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$VERIFY_STATE_DIR/last-build" 2>/dev/null || true
  return 0
}

# ============================================================
# SINCRONIZACIÓN EXPLÍCITA DEL .EFI / UKI CIZEN
# ============================================================
CIZEN_UKI_NAME="${CIZEN_UKI_NAME:-arch-${CIZEN_PKGBASE}.efi}"
CIZEN_UKI_REQUIRED="${CIZEN_UKI_REQUIRED:-0}"
CIZEN_UKI_FORCE_DIRECT="${CIZEN_UKI_FORCE_DIRECT:-0}"
CIZEN_UKI_ALLOW_RAW_KERNEL_FALLBACK="${CIZEN_UKI_ALLOW_RAW_KERNEL_FALLBACK:-0}"

cizen_uki_fail() {
    if [ "${CIZEN_UKI_REQUIRED}" = 1 ]; then
        fatal "$*"
    else
        warn "$*"
        return 0
    fi
}

find_cizen_installed_kernel() {
    local rel="${VERSION}${LOCALVERSION_SUFFIX}"
    local c
    local -a candidates=(
        "/boot/vmlinuz-${CIZEN_PKGBASE}"
        "/boot/vmlinuz-${rel}"
        "/boot/vmlinuz-linux-cizen-v3"
        "/usr/lib/modules/${rel}/vmlinuz"
    )

    for c in "${candidates[@]}"; do
        if [ -s "$c" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done

    find /boot -maxdepth 1 -type f -name 'vmlinuz-*' \
        \( -name "*${CIZEN_PKGBASE}*" -o -name "*${rel}*" \) \
        -printf '%T@ %p\n' 2>/dev/null |
        sort -nr | head -n1 | cut -d' ' -f2-
}

prepare_cizen_cmdline_file() {
    local tmp
    tmp="$(mktemp /tmp/cizen-cmdline.XXXXXX)" || return 1

    if [ -s /etc/kernel/cmdline ]; then
        tr '\n' ' ' < /etc/kernel/cmdline |
            sed -E -e 's/[[:space:]]+/ /g' -e 's/^ //' -e 's/[[:space:]]$//' > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        sed -E \
            -e 's/(^|[[:space:]])BOOT_IMAGE=[^[:space:]]*//g' \
            -e 's/(^|[[:space:]])initrd=[^[:space:]]*//g' \
            -e 's/[[:space:]]+/ /g' \
            -e 's/^ //' \
            -e 's/[[:space:]]$//' \
            /proc/cmdline > "$tmp" || { rm -f "$tmp"; return 1; }
    fi

    printf '%s\n' "$tmp"
}

detect_cizen_esp_root() {
    local r fstype
    for r in /efi /boot/efi /boot; do
        [ -d "$r" ] || continue
        fstype="$(findmnt -n -M "$r" -o FSTYPE 2>/dev/null || true)"
        if [[ "$fstype" =~ ^(vfat|msdos|fuseblk)$ ]]; then
            printf '%s\n' "$r"
            return 0
        fi
    done
    return 1
}

find_cizen_uki_targets() {
    local name="$1" r f
    local -a found=()

    for r in /efi /boot/efi /boot; do
        [ -d "$r" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] && found+=("$f")
        done < <(sudo find "$r" -maxdepth 5 -type f -iname "$name" 2>/dev/null || true)
    done

    if [ "${#found[@]}" -gt 0 ]; then
        printf '%s\n' "${found[@]}" | sort -u
        return 0
    fi

    return 1
}

cizen_uki_targets_are_current() {
# Margen de 2 s: vfat (ESP) trunca el mtime a segundos pares; así se evitan
# falsos negativos cuando la escritura ocurre en el mismo segundo del corte.
local base="${PACMAN_INSTALL_START_EPOCH:-$(date +%s)}"
local cutoff=$((base - 2))
local f mtime any=false
while IFS= read -r f; do
# Con sudo: /boot/EFI/Linux suele ser root 0700; sin privilegios, stat y
# test -f fallan por permiso y producirían un falso "no actualizado".
mtime="$(sudo stat -c '%Y' "$f" 2>/dev/null || echo 0)"
[ "$mtime" -gt 0 ] || continue
any=true
if [ "$mtime" -lt "$cutoff" ]; then
return 1
fi
done < <(find_cizen_uki_targets "$CIZEN_UKI_NAME" || true)
[ "$any" = true ]
}

build_cizen_uki() {
    local kernel="$1" cmdline_file="$2" out="$3"
    local cmdline_text ukify_bin="" stub s

    cmdline_text="$(<"$cmdline_file")"

    ukify_bin="$(command -v ukify 2>/dev/null || true)"
    if [ -z "$ukify_bin" ] && [ -x /usr/lib/systemd/ukify ]; then
        ukify_bin="/usr/lib/systemd/ukify"
    fi

    if [ -n "$ukify_bin" ]; then
        local -a args=("$ukify_bin" build --linux="$kernel" --cmdline="$cmdline_text" --output="$out")
        if "${args[@]}"; then
            return 0
        fi
        warn "ukify falló; intento fallback con objcopy."
    fi

    stub=""
    for s in /usr/lib/systemd/boot/efi/linuxx64.efi.stub /usr/lib/gummiboot/linuxx64.efi.stub; do
        if [ -s "$s" ]; then
            stub="$s"
            break
        fi
    done

    if [ -n "$stub" ] && command -v objcopy >/dev/null 2>&1; then
        local -a objargs=(
            --add-section .cmdline="$cmdline_file"
            --set-section-flags .cmdline=noload,readonly
            --add-section .linux="$kernel"
            --set-section-flags .linux=noload,readonly
        )
        if objcopy "${objargs[@]}" "$stub" "$out"; then
            return 0
        fi
    fi

    if [ "${CIZEN_UKI_ALLOW_RAW_KERNEL_FALLBACK}" = 1 ]; then
        cp -f "$kernel" "$out"
        return 0
    fi

    return 1
}

sync_cizen_efi() {
    local kernel cmdline_file tmp out
    kernel="$(find_cizen_installed_kernel)"

    if [ -z "$kernel" ] || [ ! -s "$kernel" ]; then
        cizen_uki_fail "No encontré el kernel instalado de Cizen para actualizar ${CIZEN_UKI_NAME}."
        return 0
    fi

    cmdline_file="$(prepare_cizen_cmdline_file)" || {
        cizen_uki_fail "No pude preparar la línea de comandos para la UKI."
        return 0
    }

    local -a targets=()
    while IFS= read -r out; do
        [ -n "$out" ] && targets+=("$out")
    done < <(find_cizen_uki_targets "$CIZEN_UKI_NAME" || true)

    if [ "${#targets[@]}" -eq 0 ]; then
        local esp
        esp="$(detect_cizen_esp_root)" || true
        if [ -z "$esp" ]; then
            rm -f "$cmdline_file"
            cizen_uki_fail "No encontré una partición EFI montada ni ${CIZEN_UKI_NAME}; no actualizo el .efi."
            return 0
        fi
        targets=("$esp/EFI/Linux/$CIZEN_UKI_NAME")
    fi

    tmp="$(mktemp /tmp/cizen-uki.XXXXXX)" || {
        rm -f "$cmdline_file"
        cizen_uki_fail "No pude crear temporal para la UKI."
        return 0
    }

    if ! build_cizen_uki "$kernel" "$cmdline_file" "$tmp"; then
        rm -f "$tmp" "$cmdline_file"
        cizen_uki_fail "No pude generar la UKI (${CIZEN_UKI_NAME}). Instala ukify (systemd) o binutils y verifica /usr/lib/systemd/boot/efi/linuxx64.efi.stub."
        return 0
    fi

    for out in "${targets[@]}"; do
        log "Actualizando .efi: $out"
        if ! sudo mkdir -p "$(dirname "$out")"; then
            warn "No pude crear $(dirname "$out"); continúo con el siguiente."
            continue
        fi

        if sudo cp -f "$tmp" "${out}.cizen-tmp" && sudo mv -f "${out}.cizen-tmp" "$out"; then
            ok "UKI escrita: $out"
        elif sudo cp -f "$tmp" "$out"; then
            ok "UKI escrita (directa): $out"
        else
            warn "No se pudo actualizar $out"
        fi
    done

    rm -f "$tmp" "$cmdline_file"
    sudo sync

    if ! cizen_uki_targets_are_current; then
        cizen_uki_fail "La UKI no quedó actualizada después de escribir en el objetivo."
    fi
}

ensure_cizen_efi_updated() {
    if [ "${CIZEN_UKI_FORCE_DIRECT}" != 1 ] && cizen_uki_targets_are_current; then
        ok "UKI ya actualizada por cizen-uki-sync."
        return 0
    fi

    sync_cizen_efi
}

# ============================================================
# MENUCONFIG / PAHOLE / SELFTEST / REPO / CHANGELOG  (v27.24.0)
# ============================================================

# BTF (opcional): pahole genera el .BTF en la compilación. Solo se pide/instala
# cuando --btf está activo; si no se puede, BTF_REQUESTED=false (fatal suave).
ensure_optional_pahole() {
  [ "$BTF_REQUESTED" = true ] || return 0
  command -v pahole >/dev/null 2>&1 && { ok "pahole disponible (BTF habilitado)."; return 0; }
  if [ "${CIZEN_NO_AUTOINSTALL:-0}" != "1" ] && ask_user_yes "BTF necesita 'pahole' para generar el .BTF. ¿Instalarlo ('sudo pacman -S --needed pahole')? [S/n]"; then
    if sudo pacman -S --needed pahole && command -v pahole >/dev/null 2>&1; then
      ok "pahole instalado (BTF habilitado)."
      return 0
    fi
  fi
  warn "pahole no disponible; BTF se desactiva para esta ejecución (sudo pacman -S pahole)."
  BTF_REQUESTED=false
  return 1
}

# kcfg / --menuconfig: edición visual de la config Cizen ya validada. Guarda un
# diff frente a la config previa (con sugerencias de entrada OPTS_* por cambio),
# re-normaliza con olddefconfig y revalida para no dejar pasar un cambio roto.
report_menuconfig_diff() {
  local base="$1" line sym b c a
  declare -A base_state=()
  local -a changed=() added=() removed=()

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)=(.*)$ ]]; then
      base_state["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
      base_state["${BASH_REMATCH[1]}"]="n"
    fi
  done < "$base"

  while IFS= read -r sym; do
    [ -n "$sym" ] || continue
    b=""; c=""
    [ -n "${base_state[$sym]+x}" ] && b="${base_state[$sym]}"
    [ -n "${CONFIG_STATE[$sym]+x}" ] && c="${CONFIG_STATE[$sym]}"
    if [ -z "$b" ] && [ -n "$c" ] && [ "$c" != "n" ]; then
      added+=("$sym=$c")
    elif [ -n "$b" ] && [ -z "$c" ]; then
      removed+=("$sym")
    elif [ -n "$b" ] && [ -n "$c" ] && [ "$b" != "$c" ]; then
      # y<->m es solo un cambio de modo (ENABLE/DISABLE del perfil ya admite
      # cualquiera); no se reporta como cambio de valor real.
      if { [ "$b" = "y" ] && [ "$c" = "m" ]; } || { [ "$b" = "m" ] && [ "$c" = "y" ]; }; then
        :
      else
        changed+=("$sym: $b -> $c")
      fi
    fi
  done < <( { for a in "${!base_state[@]}"; do printf '%s\n' "$a"; done
             for a in "${!CONFIG_STATE[@]}"; do printf '%s\n' "$a"; done; } | sort -u )
  unset line sym b c a base_state

  local out="$KERNEL_BUILD_ROOT/menuconfig-diff-${TS}.txt"
  {
    printf '# menuconfig diff vs la config Cizen ya validada (%s)\n' "$(date +%F\ %T)"
    printf '# Para que un cambio sobreviva a la PRÓXIMA versión, añádelo al perfil\n'
    printf '# %s en el array que corresponde (la config base se promueve igualmente).\n' "$PROFILE"
    printf '\n== NUEVOS (=y/m)  -> añadir a OPTS_ENABLE ==\n'
    for line in "${added[@]}"; do printf 'CONFIG_%s\n' "$line"; done
    printf '\n== RETIRADOS (=n) -> añadir a OPTS_DISABLE ==\n'
    for line in "${removed[@]}"; do printf 'CONFIG_%s\n' "$line"; done
    printf '\n== CAMBIADOS      -> actualizar OPTS_SETVAL/OPTS_SETSTR ==\n'
    for line in "${changed[@]}"; do printf '%s\n' "$line"; done
  } > "$out" 2>/dev/null || true

  [ "${#added[@]}" -gt 0 ] && info "menuconfig: nuevos ${#added[@]} (ver OPTS_ENABLE en el diff)."
  [ "${#removed[@]}" -gt 0 ] && info "menuconfig: retirados ${#removed[@]} (ver OPTS_DISABLE en el diff)."
  [ "${#changed[@]}" -gt 0 ] && info "menuconfig: cambiados ${#changed[@]} (ver OPTS_SETVAL/SETSTR en el diff)."
  [ "$(( ${#added[@]} + ${#removed[@]} + ${#changed[@]} ))" -eq 0 ] && info "menuconfig: sin cambios reales respecto a la config Cizen."
}

menuconfig_edit() {
  [ "$MENUCONFIG_REQUESTED" = true ] || return 0
  if ! [ -t 0 ] && ! [ -t 1 ]; then
    warn "--menuconfig requiere una terminal interactiva; se omite."
    return 0
  fi
  if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists ncurses >/dev/null 2>&1; then
    warn "menuconfig necesita ncurses (paquete 'ncurses'). Se omite; usa scripts/config o edita el perfil."
    return 0
  fi

  local base="$KERNEL_BUILD_ROOT/config-pre-menuconfig-${TS}"
  cp -f .config "$base" 2>/dev/null || { warn "No se pudo guardar la config previa; se omite menuconfig."; return 0; }
  info "Abriendo menuconfig sobre la config Cizen validada de $VERSION (edita, guarda y sal)..."
  if ! make menuconfig >/dev/null 2>&1; then
    warn "make menuconfig falló; se restaura la configuración previa."
    cp -f "$base" .config 2>/dev/null || true
    return 0
  fi
  load_config_state
  report_menuconfig_diff "$base"
  log "Re-normalizando la configuración editada (olddefconfig + validación)..."
  run_kconfig_audit || fatal "Auditoría Kconfig tras menuconfig fallida."
  validate_config || fatal "La configuración editada con menuconfig no supera la validación del perfil."
  ok "Configuración editada con menuconfig validada."
  return 0
}

# --selftest: autoevaluación del motor (sintaxis, perfil, herramientas) + el
# harness funcional de la suite cuando existe.
run_selftest() {
  local rc=0 t
  echo
  info "Autoevaluación del motor kernel-update.sh v$SCRIPT_VERSION ..."
  if bash -n -- "$0" 2>/dev/null; then
    ok "Sintaxis del motor: bash -n OK"
  else
    err "Sintaxis del motor: bash -n falló"
    rc=1
  fi

  if load_profile 2>/dev/null; then
    ok "Perfil cargado: $PROFILE_FILE"
    build_effective_arrays
    if check_profile_contradictions 2>/dev/null; then
      ok "Perfil sin contradicciones ENABLE/DISABLE/SETVAL/SETSTR"
    else
      err "Perfil con contradicciones ENABLE/DISABLE/SETVAL/SETSTR"
      rc=1
    fi
  else
    err "El perfil no se puede cargar ($PROFILE_FILE)"
    rc=1
  fi

  for t in patch aria2c xz gpg tar ccache clang ld.lld pahole; do
    if command -v "$t" >/dev/null 2>&1; then
      ok "herramienta '$t' disponible"
    else
      info "herramienta '$t' ausente (opcional)"
    fi
  done

  local harness="$SCRIPT_DIR/tests/selftest.sh"
  # Si aún no está instalado en la suite (crear tests/ exige sudo), se cae al
  # espejo del repo git local (no compromete la suite de producción).
  [ -f "$harness" ] || harness="$HOME/cizen-linux-kernel-update/kernel-update/tests/selftest.sh"
  if [ -f "$harness" ]; then
    info "Ejecutando harness funcional: $harness"
    if bash "$harness" "$0"; then
      ok "Harness de tests: TODO CORRECTO"
    else
      err "Harness de tests: fallo(s)"
      rc=1
    fi
  else
    warn "No existe el harness funcional (tests/selftest.sh); se omiten los tests funcionales."
  fi

  [ "$rc" -eq 0 ] && ok "Autoevaluación completada sin fallos." || err "Autoevaluación completada con $rc fallo(s)."
  return "$rc"
}

# --publish-repo: tras instalar, copia el paquete a un repositorio local pacman
# y refresca su base de datos con repo-add (para las VMs libvirt / otros hosts).
publish_repo_package() {
  [ "$PUBLISH_REPO" = true ] || return 0
  [ -s "${PKG:-}" ] || { warn "No hay paquete que publicar; se omite el repo local."; return 0; }
  if ! command -v repo-add >/dev/null 2>&1; then
    warn "repo-add no está instalado (paquete pacman-contrib). Se omite la publicación: sudo pacman -S pacman-contrib"
    return 0
  fi
  if ! sudo -n true 2>/dev/null; then
    warn "Sin ticket sudo vigente; se omite la publicación en $PUBLISH_REPO_DIR."
    return 0
  fi

  local pkgfile="$(basename -- "$PKG")"
  sudo mkdir -p -- "$PUBLISH_REPO_DIR" || { warn "No se pudo crear $PUBLISH_REPO_DIR"; return 0; }
  sudo cp -f -- "$PKG" "$PUBLISH_REPO_DIR/$pkgfile" || { warn "No se pudo copiar el paquete al repo local."; return 0; }
  if sudo repo-add -q -- "$PUBLISH_REPO_DIR/cizen-linux.db.tar.gz" "$PUBLISH_REPO_DIR/$pkgfile"; then
    ok "Publicado en repo local: $PUBLISH_REPO_DIR (db 'cizen-linux')"
    PUBLISH_REPO_MSG="Repo local  : $PUBLISH_REPO_DIR (cizen-linux)
   Para usarlo en VMs/compañeros añade a /etc/pacman.conf:
     [cizen-linux]
     Server = file://$PUBLISH_REPO_DIR
     SigLevel = Optional
   (o sirve el directorio por HTTP/NFS y cambia Server.)"
  else
    warn "repo-add falló al publicar $pkgfile."
  fi
  return 0
}

# --changelog: mantenimiento. Bumpea cabecera + SCRIPT_VERSION a X.Y.(Z+1) y
# añade al top un borrador de changelog con el diff --stat del espejo git (si
# existe). NO hace commit ni push; el texto del parche lo completa el mantenedor.
changelog_bump() {
  local cur new patch ts mirror repo stat_info tmp
  cur="$SCRIPT_VERSION"
  patch="${cur##*.}"
  [[ "$patch" =~ ^[0-9]+$ ]] || { err "SCRIPT_VERSION inválido: $cur"; return 1; }
  new="${cur%.*}.$((patch + 1))"
  ts="$(date +%Y-%m-%d)"
  mirror="${CIZEN_KERNEL_MIRROR:-$HOME/cizen-linux-kernel-update/kernel-update}"
  repo="$(dirname -- "$mirror")"
  stat_info=""
  if [ -f "$mirror/kernel-update.sh" ] && git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    stat_info="$(git -C "$repo" diff --stat HEAD -- kernel-update/ 2>/dev/null || true)"
  fi
  if [ -n "$stat_info" ]; then
    info "Resumen git del espejo (referencia para el changelog):"
    printf '%s\n' "$stat_info"
  fi

  log "Preparando bump v$cur -> v$new con borrador de changelog ($ts)..."
  tmp="$(mktemp "${SCRIPT_DIR}/.kernel-update-XXXXXX")" || return 1
  awk -v new="$new" -v cur="$cur" -v ts="$ts" -v stat="$stat_info" '
    BEGIN { bumped=0; bumpver=0; n=split(stat, s, "\n") }
    !bumped && NR<=3 && $0 ~ /^# kernel-update\.sh — Cizen v/ {
      sub(/Cizen v[0-9]+[.][0-9]+[.][0-9]+/, "Cizen v" new)
      print; next
    }
    !bumped && $0 ~ /^# CHANGELOG v[0-9]/ {
      print "# CHANGELOG v" new " (borrador — completa la descripción — " ts ")"
      print "#   - RELLENAR: describe qué cambia frente a la v" cur "."
      if (n > 0) print "#   - Referencia del espejo git (diff --stat):"
      for (i=1; i<=n; i++) if (s[i] != "") print "#       " s[i]
      print "#"
      bumped=1
    }
    !bumpver && $0 ~ /^SCRIPT_VERSION="[0-9]+[.][0-9]+[.][0-9]+"$/ {
      sub(/SCRIPT_VERSION="[0-9]+[.][0-9]+[.][0-9]+"/, "SCRIPT_VERSION=\"" new "\"")
      bumpver=1
    }
    { print }
  ' "$0" > "$tmp" || { rm -f -- "$tmp"; err "Fallo al generar el borrador."; return 1; }

  if ! bash -n -- "$tmp" 2>/dev/null; then
    err "El borrador resultante no pasa bash -n; no se aplica."
    rm -f -- "$tmp"
    return 1
  fi
  chmod --reference="$0" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$0" || { rm -f -- "$tmp"; err "No se pudo reemplazar el motor."; return 1; }
  ok "Bumpeado a v$new y borrador añadido al top de $0."
  ok "Completa el texto del changelog y sincroniza el espejo: cp \"$0\" \"$mirror/kernel-update.sh\""
  return 0
}

# ============================================================
# DECISIÓN SOBRE RELEASE MÁS NUEVA
# ============================================================
confirm_newer_release() {
  local requested="$1" latest="$2" answer

  if ! [ -t 0 ] && ! [ -t 1 ]; then
    warn "Hay una release estable más nueva: $requested → $latest, pero no hay terminal interactiva; se conserva la versión solicitada."
    return 1
  fi

  printf '\n'
  printf '  Hay una release estable más nueva de kernel.org: %s → %s\n' "$requested" "$latest"
  read -r -p "  ¿Deseas compilar la versión más nueva ($latest)? [S/n] " answer < /dev/tty || answer="n"
  case "${answer:-s}" in
    s|S|si|SI|Sí|sí|y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Confirma antes de recompilar la versión ya instalada cuando no hay una release
# estable nueva. Devolver 0 -> continuar con la recompilación; 1 -> no hacer nada.
confirm_recompile_current() {
  local version="$1" answer

  if ! [ -t 0 ] && ! [ -t 1 ]; then
    warn "No hay una release estable nueva y no hay terminal interactiva; se cancela (no se recompila $version)."
    return 1
  fi

  printf '\n'
  printf '  No hay una release estable nueva para compilar (instalada: %s).\n' "$version"
  read -r -p "  ¿Quieres continuar con la recompilación del kernel $version? [S/n] " answer < /dev/tty || answer="n"
  case "${answer:-s}" in
    s|S|si|SI|Sí|sí|y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# ============================================================
# INICIO PRINCIPAL
# ============================================================
T_ALL="$(date +%s)"
PKG=""
PKG_NAME=""
PKG_VERSION=""

# Modos de mantenimiento sin sudo/red/descarga: se ejecutan pronto y salen.
if [ "$SELFTEST" = true ]; then
  run_selftest || exit 1
  exit 0
fi
if [ "$DO_CHANGELOG" = true ]; then
  changelog_bump || exit 1
  exit 0
fi

prepare_dirs
check_prerequisites

# BTF (opcional): necesita pahole para el .BTF. Si no se consigue se degrada a
# sin-BTF; se reconstruyen los arrays efectivos por si el BTF se desactivó.
if [ "$BTF_REQUESTED" = true ]; then
  ensure_optional_pahole
  build_effective_arrays
fi

# Con una versión explícita, kernel.org se consulta antes de descargar.
# Si existe una stable posterior, se pregunta una sola vez y la respuesta
# determina VERSION. A partir de ese punto todo el flujo usa esa versión.
if [ -n "$VERSION" ]; then
  resolve_latest_release
  if version_gt "$REMOTE_STABLE_VERSION" "$VERSION"; then
    REQUESTED_VERSION="$VERSION"
    if confirm_newer_release "$REQUESTED_VERSION" "$REMOTE_STABLE_VERSION"; then
      VERSION="$REMOTE_STABLE_VERSION"
      ok "Versión seleccionada: $VERSION"
    else
      info "Se conserva la versión solicitada: $VERSION"
    fi
  fi
fi

if [ "$CHECK_UPDATE" = true ]; then
  [ -z "$VERSION" ] || fatal "--check-update no acepta una versión explícita."
  resolve_latest_release
  if [ -n "$LOCAL_KERNEL_VERSION" ] && version_gt "$REMOTE_STABLE_VERSION" "$LOCAL_KERNEL_VERSION"; then
    ok "Actualización disponible: $LOCAL_KERNEL_VERSION → $REMOTE_STABLE_VERSION"
  elif [ -n "$LOCAL_KERNEL_VERSION" ]; then
    ok "No hay actualización: Cizen=$LOCAL_KERNEL_VERSION kernel.org=$REMOTE_STABLE_VERSION"
  else
    info "Stable actual de kernel.org: $REMOTE_STABLE_VERSION (sin referencia Cizen local)"
  fi
  exit 0
fi

if [ -z "$VERSION" ]; then
    resolve_latest_release
    VERSION="$REMOTE_STABLE_VERSION"
    # kcheck sin versión siempre trabaja contra la stable actual; la regla
    # "no compilar si no hay actualización" aplica solo al flujo de build.
    if [ "$CHECK_ONLY" = false ] && [ -n "$LOCAL_KERNEL_VERSION" ] && ! version_gt "$VERSION" "$LOCAL_KERNEL_VERSION"; then
      if confirm_recompile_current "$LOCAL_KERNEL_VERSION"; then
        VERSION="$LOCAL_KERNEL_VERSION"
        ok "Se continúa con la recompilación de la versión instalada: $VERSION"
      else
        ok "Recompilación cancelada: no hay una release estable nueva para compilar."
        exit 0
      fi
    fi
  fi

# La versión ya está resuelta: a partir de aquí todas las rutas son deterministas.
MAJOR="${VERSION%%.*}"
TARBALL="$KERNEL_BUILD_ROOT/linux-$VERSION.tar.xz"
SRC="$TMPFS_ROOT/linux-$VERSION"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-$VERSION.tar.xz"

# Lock exclusivo. Mantemos una única operación para evitar carreras sobre el árbol persistente.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  fatal "Ya existe otra ejecución de kernel-update.sh en curso: $LOCK_FILE"
fi

log "Kernel Cizen v$SCRIPT_VERSION — perfil $PROFILE"
log "Objetivo  : $VERSION (check=$CHECK_ONLY force=$FORCE strict=$STRICT jobs=$JOBS prio=$BUILD_PRIORITY)"
log "Cache/build: $KERNEL_BUILD_ROOT | $TMPFS_ROOT (${TMPFS_SIZE}, mín. ${TMPFS_MIN_FREE_MB} MB)"

if [ "$KEEP_SRC" = true ]; then
  info "--keep-src: las fuentes ya se conservan siempre en el tmpfs entre ejecuciones; esta bandera no cambia el comportamiento."
fi

sudo -v

# Verificación temprana de que las operaciones privilegiadas (mount/umount,
# pacman, escritura en el ESP, etc.) están permitidas por sudo, antes de
# gastar minutos en descarga/compilación.
check_sudo_capabilities

# Solo se valida el punto de montaje dedicado de compilación. El /tmp global
# no participa en la lógica de validación ni se modifica.
#
# IMPORTANTE: cleanup_old_source_trees() corre ANTES de prepare_tmpfs_build(),
# porque este último comprueba el espacio libre del tmpfs (TMPFS_MIN_FREE_MB).
# Si quedó un árbol de una versión distinta de una ejecución anterior, hay
# que liberarlo primero para no abortar por falta de espacio que esta misma
# limpieza iba a resolver segundos después.
cleanup_kernel_cache
check_disk_space
cleanup_old_source_trees
prepare_tmpfs_build

# Verificación final del punto de montaje dedicado.
# IMPORTANTE: findmnt normalmente NO imprime "exec" cuando exec es la opción
# por defecto; por eso no debe interpretarse la ausencia de "exec" como noexec.
# Comprobamos además la ejecución real de un binario pequeño dentro del tmpfs.
if ! tmpfs_is_mounted; then
  fatal "El tmpfs dedicado de compilación no quedó montado correctamente: $TMPFS_ROOT"
fi
TMPFS_FINAL_FS="$(findmnt -n -M "$TMPFS_ROOT" -o FSTYPE 2>/dev/null || true)"
TMPFS_FINAL_OPTS="$(findmnt -n -M "$TMPFS_ROOT" -o OPTIONS 2>/dev/null || true)"
[ "$TMPFS_FINAL_FS" = "tmpfs" ] || fatal "El punto de compilación no es tmpfs: $TMPFS_ROOT"

case ",${TMPFS_FINAL_OPTS}," in
  *,noexec,*)
    fatal "El tmpfs de compilación está montado con noexec; se aborta antes del chequeo/build."
    ;;
esac

TMPFS_EXEC_TEST="$TMPFS_ROOT/.cizen-exec-test-$TS"
if ! cp /bin/true "$TMPFS_EXEC_TEST" 2>/dev/null; then
  fatal "No se pudo copiar el binario de prueba al tmpfs de compilación."
fi
chmod 0755 "$TMPFS_EXEC_TEST" 2>/dev/null || { rm -f "$TMPFS_EXEC_TEST"; fatal "No se pudo preparar el binario de prueba en el tmpfs."; }
if ! "$TMPFS_EXEC_TEST" >/dev/null 2>&1; then
  rm -f "$TMPFS_EXEC_TEST"
  fatal "El tmpfs de compilación no permite ejecutar binarios; se aborta antes del chequeo/build."
fi
rm -f "$TMPFS_EXEC_TEST"
ok "tmpfs de compilación verificado (montaje + exec efectivo)"

# SRC y BUILD_MARKER ya apuntan al tmpfs objetivo; no es necesario reasignarlos.

# Tarball/extracción
get_tarball "$TARBALL" "$URL" || fatal "No se pudo obtener un tarball válido."
extract_tarball || fatal "No se pudo preparar el árbol de fuentes."

cd "$SRC"
ok "Fuentes listas: $SRC"
T_DL="$(date +%s)"

# Parches de terceros (v27.24.0): --patch / --bore / CIZEN_PATCHES. Se aplican
# antes de elegir la config base porque introducen símbolos Kconfig nuevos que
# deben existir para que olddefconfig/validación los vean.
if [ "${#PATCH_NAMES[@]}" -gt 0 ]; then
  for __patch in "${PATCH_NAMES[@]}"; do
    if apply_patch_plugin "$__patch"; then
      # Reconstruir arrays efectivos para que build_effective_arrays active los
      # símbolos del parche y los marque como esperados (no ensucia kcheck ni
      # bloquea con --strict).
      build_effective_arrays
    else
      warn "Parche $__patch no aplicado; la build continúa vanilla."
    fi
  done
  unset __patch
fi

# Config Cizen primero; /proc/config.gz o /boot/config como fallback.
choose_base_config

# Crear marcador justo antes de aplicar/configurar/compilar.
touch "$BUILD_MARKER"

# Aplicar perfil.
apply_config_requests || fatal "Falló scripts/config al aplicar el perfil."

# Auditoría oficial Kconfig.
run_kconfig_audit || fatal "Auditoría Kconfig fallida."

# La configuración de HOME se promociona SOLO después de superar toda la
# validación. Así un --check fallido jamás sustituye la base estable.
validate_config || {
  rc=$?
  fatal "Validación de configuración fallida (rc=$rc). No se compila."
}

# --absorb-rebels: si Kconfig conservó desactivaciones que aún no estaban en
# EXPECTED_REBELS, muévelas al perfil (con backup) y revalida con los arrays
# recargados para que este mismo chequeo termine limpio y la próxima ejecución
# no reproduzca los warnings.
if [ "$ABSORB_REBELS" = true ] && [ "${#DISABLE_WARN[@]}" -gt 0 ]; then
  if absorb_rebels_to_profile; then
    source "$PROFILE_FILE"
    load_profile
    build_effective_arrays
    check_profile_contradictions
    log "Re-validando con el perfil actualizado (símbolos absorbidos)..."
    validate_config || {
      rc=$?
      fatal "Re-validación tras --absorb-rebels fallida (rc=$rc)."
    }
  else
    warn "--absorb-rebels no pudo completarse; se continúa con la validación previa."
  fi
fi

verify_build_tree
report_config_diff
T_CFG="$(date +%s)"

# kcfg / --menuconfig (opcional): edición visual de la config ya validada.
# Se hace tras la absorción de rebeldes y ANTES de promover la config base.
menuconfig_edit

promote_base_config() {
  local src="$1" dst="$2" tmp
  [ -f "$src" ] || fatal "No existe la configuración efectiva a promover: $src"
  tmp="${dst}.tmp-${TS}"
  rm -f -- "$tmp"
  cp -f -- "$src" "$tmp"
  chmod 0644 "$tmp"
  # La promoción es atómica: el archivo estable solo aparece cuando la copia
  # completa ya existe. Si mv falla, el archivo anterior no se toca.
  mv -f -- "$tmp" "$dst"
}

confirm_build_after_check() {
  local answer

  if ! [ -t 0 ] && ! [ -t 1 ]; then
    warn "Validación completada sin terminal interactiva; no se inicia la compilación automáticamente."
    return 1
  fi

  echo
  while true; do
    read -r -t 300 -p "  ¿Desea continuar con la compilación del kernel $VERSION? [S/n] " answer < /dev/tty || answer="n"
    case "${answer:-s}" in
      s|S|si|SI|sí|Sí|Si|y|Y|yes|YES)
        return 0
        ;;
      n|N|no|NO)
        return 1
        ;;
      *)
        warn "Respuesta no válida. Responda S, N o simplemente presione Enter."
        ;;
    esac
  done
}

if [ "$CHECK_ONLY" = true ]; then
  if confirm_build_after_check; then
    ok "Perfecto. La configuración está validada; continuamos con la compilación de $VERSION."
    CHECK_ONLY=false
  else
    FINAL_CONFIG="$CONFIG_DIR/linux-$VERSION-cizen-v3.config"
    promote_base_config .config "$FINAL_CONFIG"
    ok "CHECK EXITOSO: configuración promovida a $FINAL_CONFIG"
    echo
    ok "Todo listo para compilar cuando lo desees; la configuración quedó validada y las fuentes esperan en su sitio."
    cleanup_success
    exit 0
  fi
fi

# ============================================================
# COMPILACIÓN
# ============================================================
declare -a MAKE_CC_OPTS=()
if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
  # Tuning (no destructivo, silencioso):
  #  - base_dir=$HOME: los hits no dependen del cwd donde se compila
  #  - max_size: límite opcional vía CCACHE_MAX_SIZE (cosa por defecto)
  #  - compiler_check=content: hash del binario del compilador, no del path
  if command -v ccache >/dev/null 2>&1; then
    ccache -o base_dir="$HOME" >/dev/null 2>&1 || true
    ccache -o compiler_check=content >/dev/null 2>&1 || true
    if [ -n "${CCACHE_MAX_SIZE:-}" ]; then
      ccache -o max_size="$CCACHE_MAX_SIZE" >/dev/null 2>&1 || true
    fi
  fi
  MAKE_CC_OPTS+=(
    'CC=ccache gcc'
    'HOSTCC=ccache gcc'
  )
  # No fijamos KBUILD_BUILD_TIMESTAMP. Kbuild utilizará la fecha/hora real
  # de compilación, evitando que uname -a muestre una fecha artificial.
  # La reproducibilidad temporal puede activarse explícitamente desde el
  # entorno si el usuario exporta KBUILD_BUILD_TIMESTAMP antes de ejecutar.
  ok "ccache activo: $CCACHE_DIR (CC/HOSTCC forzados; timestamp de build real)"
else
  warn "ccache no instalado; compilación normal."
fi

export KCFLAGS="${KCFLAGS:--pipe}"

# Build con LLVM/Clang (--clang): Kbuild aplica LLVM=1 (CC=clang, ld.lld,
# llvm-ar/nm, etc.). Si clang o ld.lld no están, se degrada a GCC (fatal suave).
CLANG_BUILD=false
if [ "$CLANG_REQUESTED" = true ]; then
  if command -v clang >/dev/null 2>&1 && command -v ld.lld >/dev/null 2>&1; then
    if command -v ccache >/dev/null 2>&1; then
      MAKE_CC_OPTS+=(
        'LLVM=1'
        'CC=ccache clang'
        'HOSTCC=ccache clang'
      )
    else
      MAKE_CC_OPTS+=('LLVM=1')
    fi
    export LLVM=1
    CLANG_BUILD=true
    ok "Compilación con LLVM/Clang (LLVM=1)."
  else
    warn "clang/ld.lld no están instalados; --clang se degrada a GCC (sudo pacman -S clang lld)."
  fi
fi

# Límite máximo configurable para la compilación. 1 h cubre con margen
# una build completa en una máquina seca (cold ~19 min, warm ~4 min),
# pero permite abortar una build realmente colgada. Configurable vía
# BUILD_TIMEOUT si un build legítimo necesitara más tiempo.
BUILD_TIMEOUT="${BUILD_TIMEOUT:-3600}"
[[ "$BUILD_TIMEOUT" =~ ^[0-9]+$ ]] || fatal "BUILD_TIMEOUT inválido: $BUILD_TIMEOUT (use segundos enteros)."
(( BUILD_TIMEOUT > 0 )) || fatal "BUILD_TIMEOUT debe ser > 0 segundos."

determine_pkgrel
prepare_package_identity_override
prepare_package_revision_override
prepare_package_pruning_override

log "Compilando con $JOBS hilos (pkgrel=$PKGREL)..."
START="$(date +%s)"

export KBUILD_REVISION="$PKGREL"
# Fuerza el pkgbase Cizen en makepkg sin depender del entorno heredado del usuario.
# El PKGBUILD oficial de kbuild soporta PACMAN_PKGBASE y lo utiliza para formar
# pkgname/pkgbase y el identificador que termina en /usr/lib/modules/<release>/pkgbase.
export PACMAN_PKGBASE="$CIZEN_PKGBASE"
# Poda de módulos: estas variables llegan a package() bajo fakeroot vía makepkg.
export CIZEN_PRUNE_MODULES="${CIZEN_PRUNE_MODULES:-$PRUNE_MODULES}"
export CIZEN_PRUNE_SCRIPT="${CIZEN_PRUNE_SCRIPT:-$PRUNER_SCRIPT}"
export CIZEN_KEEP_MODULES="${CIZEN_KEEP_MODULES:-}"
sudo_keepalive_start
build_rc=0
# --foreground: hace que make corra en el MISMO grupo de procesos de la
# terminal. Sin él, timeout(1) crea un grupo propio para make, aislado del
# foreground de la terminal, de modo que Ctrl+C (SIGINT al grupo foreground)
# solo llegaba al script y NO cancelaba la compilación. Con --foreground,
# Ctrl+C llega directo a make (que ya tiene traps INT/TERM y remata sus .o y
# sub-makes), permitiendo cancelar la build en cualquier momento.
if time "${BUILD_PRIORITY_WRAP[@]}" timeout --foreground --signal=TERM --kill-after=60s "$BUILD_TIMEOUT" \
    make -j"$JOBS" "${MAKE_CC_OPTS[@]}" KBUILD_REVISION="$PKGREL" pacman-pkg; then
  :
else
  build_rc=$?
  restore_package_revision_override || true
  restore_package_identity_override || true
  sudo_keepalive_stop
  if [ "$build_rc" -eq 124 ]; then
    err "Compilación agotó el tiempo máximo (${BUILD_TIMEOUT}s)."
  else
    err "Compilación falló (rc=$build_rc)."
  fi
  err "Fuentes conservadas en: $SRC"
  exit 1
fi

END="$(date +%s)"
DUR=$((END - START))
ok "Compilación completada en $((DUR/60))m $((DUR%60))s"
restore_package_revision_override
restore_package_identity_override

# Obtener sudo antes de modificar el sistema.
sudo -v

# Snapshot btrfs readonly del root (feature 4). Red de seguridad opcional.
create_btrfs_snapshot

copy_packages_from_build || fatal "No se pudo identificar/verificar el paquete generado."
validate_split_package_transition_metadata

# Evitar reinstalar exactamente el mismo paquete si ya está instalado.
# copy_packages_from_build() ya validó la metadata interna del paquete.
if pacman -Q "$PKG_NAME" >/dev/null 2>&1; then
  INSTALLED_VERSION="$(pacman -Q "$PKG_NAME" | awk 'NR==1 {print $2}')"
else
  INSTALLED_VERSION=""
fi

installed_rel=0
if [ -n "$INSTALLED_VERSION" ] && [[ "$INSTALLED_VERSION" == "$PKGVER_BASE-"* ]]; then
  if [[ "$INSTALLED_VERSION" =~ ^${PKGVER_BASE}-([0-9]+)$ ]]; then
    installed_rel="${BASH_REMATCH[1]:-0}"
    if (( PKGREL <= installed_rel )); then
      # Único efecto real de --force en todo el script: permitir reinstalar
      # un pkgrel igual o menor al ya instalado. No afecta ninguna
      # validación crítica de Kconfig ni de auditoría (esas nunca se pueden
      # saltar, con o sin --force).
      if [ "$FORCE" = true ]; then
        warn "El pkgrel generado ($PKGREL) no es superior al instalado ($installed_rel) para $PKGVER_BASE; se continúa por --force."
      else
        fatal "El pkgrel generado ($PKGREL) no es superior al instalado ($installed_rel) para $PKGVER_BASE. Se aborta para no instalar un paquete más viejo (usa --force para omitir esta comprobación)."
      fi
    fi
  fi
fi

log "Instalando $PKG_NAME-$PKG_VERSION ..."

# Archivar el kernel en ejecución antes de que pacman lo sustituya (feature 3).
prepare_rollback_archive

# --------------------------------------------------------------------
# Reparación segura de /var/lib/pacman/db.lck
#
# pacman no guarda de forma fiable un PID utilizable dentro de db.lck,
# por lo que la decisión correcta es comprobar primero si existe realmente
# una transacción/gestor de paquetes activo. Nunca se borra el lock si hay
# un pacman/ayudante ejecutándose: en ese caso esperamos y reintentamos.
# Si el lock existe pero no hay ningún gestor activo, se considera huérfano
# y se elimina automáticamente antes de reintentar la instalación.
# --------------------------------------------------------------------
PACMAN_LOCK="/var/lib/pacman/db.lck"
PACMAN_LOCK_WAIT_SEC="180"
PACMAN_RETRY_INTERVAL_SEC="2"
PACMAN_LOCK_SUSPECT_CURRENT=false
PACMAN_INSTALL_START_EPOCH=0
PACMAN_PREINSTALL_LOCK_MTIME=0

package_manager_pids() {
  # fuser consulta directamente al kernel quién mantiene abierto db.lck.
  # Esto cubre pacman, pamac-daemon, PackageKit y futuros frontends sin
  # depender de una lista fija de nombres de proceso.
  sudo fuser "$PACMAN_LOCK" 2>/dev/null || true
}

pacman_transaction_state() {
  local pids
  [ -e "$PACMAN_LOCK" ] || { echo "absent"; return 0; }
  pids="$(package_manager_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [ -n "$pids" ]; then
    echo "active:$pids"
  else
    echo "stale"
  fi
}

pacman_lock_mtime() {
  stat -c '%Y' "$PACMAN_LOCK" 2>/dev/null || echo 0
}

recover_pacman_lock() {
  local state elapsed pids lock_mtime
  elapsed=0

  while [ -e "$PACMAN_LOCK" ]; do
    state="$(pacman_transaction_state)"
    case "$state" in
      absent)
        return 0
        ;;
      stale)
        # Revalidación inmediata para reducir la ventana TOCTOU entre fuser
        # y rm. Si aparece un proceso, nunca eliminamos el lock.
        pids="$(package_manager_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        if [ -n "$pids" ]; then
          warn "El lock dejó de parecer huérfano durante la revalidación (PID: $pids); se espera."
          sleep "$PACMAN_RETRY_INTERVAL_SEC"
          elapsed=$((elapsed + PACMAN_RETRY_INTERVAL_SEC))
          continue
        fi

        lock_mtime="$(pacman_lock_mtime)"

        if [ "${PACMAN_INSTALL_START_EPOCH:-0}" -gt 0 ]; then
          if [ "$lock_mtime" -gt "${PACMAN_PREINSTALL_LOCK_MTIME:-0}" ] || \
             { [ "${PACMAN_PREINSTALL_LOCK_MTIME:-0}" -eq 0 ] && [ "$lock_mtime" -ge "${PACMAN_INSTALL_START_EPOCH}" ]; }; then
            warn "db.lck fue creado/modificado durante el intento de instalación actual; no se asume que sea un lock huérfano."
            warn "Se hará como máximo una reparación cautelosa; si pacman falló por otra causa, revisa su error antes de reintentar."
            PACMAN_LOCK_SUSPECT_CURRENT=true
          fi
        fi

        warn "Se detectó lock de pacman sin proceso que lo mantenga abierto: $PACMAN_LOCK"
        if [ "$PACMAN_LOCK_SUSPECT_CURRENT" = true ]; then
          warn "El lock coincide temporalmente con la instalación actual; se permite una única eliminación cautelosa."
        fi

        # Última comprobación justo antes del rm.
        pids="$(package_manager_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        [ -z "$pids" ] || {
          warn "Apareció un gestor justo antes de eliminar db.lck (PID: $pids); no se elimina."
          sleep "$PACMAN_RETRY_INTERVAL_SEC"
          elapsed=$((elapsed + PACMAN_RETRY_INTERVAL_SEC))
          continue
        }

        sudo rm -f -- "$PACMAN_LOCK" || fatal "No se pudo eliminar el lock de pacman: $PACMAN_LOCK"
        [ ! -e "$PACMAN_LOCK" ] || fatal "El lock de pacman sigue presente después de intentar repararlo: $PACMAN_LOCK"
        ok "Lock de pacman eliminado tras doble comprobación de actividad"
        return 0
        ;;
      active:*)
        pids="${state#active:}"
        if (( elapsed >= PACMAN_LOCK_WAIT_SEC )); then
          fatal "gestor de paquetes sigue activo (${pids}) y el lock no se libera después de ${PACMAN_LOCK_WAIT_SEC}s. No se elimina por seguridad: $PACMAN_LOCK"
        fi
        warn "Base de datos de pacman ocupada por gestor activo (PID: ${pids}); esperando..."
        sleep "$PACMAN_RETRY_INTERVAL_SEC"
        elapsed=$((elapsed + PACMAN_RETRY_INTERVAL_SEC))
        ;;
    esac
  done
}

install_kernel_package() {
  local rc
  local attempt=1
  local max_attempts=$((PACMAN_LOCK_WAIT_SEC / PACMAN_RETRY_INTERVAL_SEC + 1))

  # La versión de pacman disponible en este sistema no soporta
  # --resolve-conflicts=all. Como el paquete Cizen declara explícitamente
  # conflicts=("linux-upstream"), la migración debe retirar el paquete legado
  # de forma separada antes de la primera transacción -U. Se hace aquí, y no
  # antes, para que toda la preparación/build/verificación ya haya terminado.
  if pacman -Q "$LEGACY_PKGBASE" >/dev/null 2>&1; then
    log "Migración de paquete: retirando $LEGACY_PKGBASE antes de instalar $CIZEN_PKGBASE ..."
    local remove_out
    if remove_out="$(sudo pacman -R --noconfirm "$LEGACY_PKGBASE" 2>&1)"; then
      ok "Paquete legado retirado: $LEGACY_PKGBASE"
    elif printf '%s\n' "$remove_out" | grep -Fq "target not found: $LEGACY_PKGBASE"; then
      # pacman -Q lo vio instalado un instante antes, pero para cuando se
      # intentó retirar ya no estaba (otra transacción concurrente, o una
      # migración parcial de una ejecución previa que ya lo había quitado).
      # El estado deseado -$LEGACY_PKGBASE fuera del sistema- ya se cumple,
      # así que esto no es un fallo real: se continúa con la instalación.
      warn "$LEGACY_PKGBASE ya no estaba instalado al intentar retirarlo; se continúa sin tratarlo como error."
      printf '%s\n' "$remove_out" >&2
    else
      err "No se pudo retirar $LEGACY_PKGBASE; se cancela la instalación de $CIZEN_PKGBASE."
      printf '%s\n' "$remove_out" >&2
      return 1
    fi
  fi

  while (( attempt <= max_attempts )); do
    if sudo pacman -U "$PKG" --noconfirm; then
      return 0
    else
      rc=$?
    fi
    if [ ! -e "$PACMAN_LOCK" ]; then
      return "$rc"
    fi

    # Solo entrar aquí cuando el fallo coincide con un lock aún presente.
    recover_pacman_lock
    if [ "$PACMAN_LOCK_SUSPECT_CURRENT" = true ] && (( attempt >= 2 )); then
      err "No se repite automáticamente la instalación: el db.lck apareció durante el intento actual."
      return "$rc"
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

# El lock se comprueba antes de iniciar pacman y, si aparece durante el
# intento, se considera potencialmente causado por la propia transacción.
PACMAN_INSTALL_START_EPOCH="$(date +%s)"
PACMAN_PREINSTALL_LOCK_MTIME="$(pacman_lock_mtime)"

recover_pacman_lock
install_kernel_package || fatal "No se pudo instalar $PKG_NAME-$PKG_VERSION con pacman." 
ok "Paquete instalado: $PKG_NAME-$PKG_VERSION"

log "Sincronizando UKI..."
sudo cizen-uki-sync
ensure_cizen_efi_updated
ok "UKI sincronizado"

prune_stale_packages

# Firma del build para el verificador post-boot (feature 2).
write_verify_signature

# Promover la configuración final en CONFIG_DIR SOLO después de instalación + UKI.
FINAL_CONFIG="$CONFIG_DIR/linux-$VERSION-cizen-v3.config"
promote_base_config .config "$FINAL_CONFIG"
ok "Configuración final guardada: $FINAL_CONFIG"

# Repo local pacman (--publish-repo): copia el paquete instalado a un repositorio
# de archivos servible a las VMs libvirt / otros hosts.
publish_repo_package

T_END="$(date +%s)"

# Desglose de tiempos (feature 7). t_* en segundos; cada fase se muestra solo
# si tiene timestamps válidos (path completo de build siempre los tiene).
P_DL=""; P_CFG=""; P_BUILD=""; P_INST=""
if [ "${T_DL:-0}" -ge "${T_ALL:-0}" ] && [ "${T_ALL:-0}" -gt 0 ]; then
  P_DL="$((T_DL - T_ALL))"
fi
if [ "${T_CFG:-0}" -ge "${T_DL:-0}" ] && [ "${T_DL:-0}" -gt 0 ]; then
  P_CFG="$((T_CFG - T_DL))"
fi
if [ "${T_CFG:-0}" -gt 0 ] && [ "$DUR" -gt 0 ]; then
  P_BUILD="$DUR"
fi
if [ "${T_END:-0}" -gt 0 ] && [ "$DUR" -gt 0 ] && [ "${T_CFG:-0}" -gt 0 ]; then
  P_INST="$((T_END - T_CFG - DUR))"
fi

# fmt_time se define aquí (tras T_* y antes del cat del resumen).
fmt_time() { # segundos -> "Xm Ys" (o solo "Ys" si <60)
  local s="$1" m=0
  [ "${s:-0}" -le 0 ] 2>/dev/null && s=0
  if [ "$s" -ge 60 ] 2>/dev/null; then m=$((s / 60)); s=$((s % 60)); fi
  if [ "$m" -gt 0 ]; then printf '%dm %ds' "$m" "$s"; else printf '%ds' "$s"; fi
}

CCACHE_STATS=""
if [ -n "${CCACHE_DIR:-}" ] && command -v ccache >/dev/null 2>&1; then
  CCACHE_STATS="$(ccache -s 2>/dev/null | grep -E '^(Hits|Direct hits|Preprocessed cache hits|Misses|cache size|Files in cache|Uncacheable)' | sed 's/^ */  /' || true)"
fi

sudo_keepalive_stop
cleanup_success

cat <<SUMMARY

===============================================================
ACTUALIZACIÓN COMPLETADA — CIZEN v$SCRIPT_VERSION
===============================================================
 Versión     : $VERSION-cizen-v3
 pkgrel      : $PKGREL
Perfil      : $PROFILE
  Parches     : ${PATCHES_APPLIED[*]:---}
  BTF         : $([ "$BTF_REQUESTED" = true ] && echo 'sí' || echo 'no')
  CC          : $([ "$CLANG_BUILD" = true ] && echo 'LLVM/Clang' || echo 'GCC')
${PUBLISH_REPO_MSG:+  ${PUBLISH_REPO_MSG}}
  Hilos       : $JOBS
 Build prio  : $BUILD_PRIORITY (CIZEN_BUILD_PRIORITY=normal para máxima velocidad)
 Paquete     : $(basename "$PKG")
 Config base : $FINAL_CONFIG
 Build tmpfs : $TMPFS_ROOT (size=$TMPFS_SIZE)
 Podar       : $([ "${CIZEN_PRUNE_MODULES:-$PRUNE_MODULES}" = "1" ] && echo 'sí (solo módulos de este hardware)' || echo 'no')
${SNAPSHOT_DESC:+ Snapshot   : $SNAPSHOT_DESC}
${VERIFY_ROLLBACK_FILE:+ Rollback  : $VERIFY_ROLLBACK_FILE}

 Tiempos:
   Descarga+extracción : $( [ -n "$P_DL" ] && fmt_time "$P_DL" || echo '—')
   Config+validación   : $( [ -n "$P_CFG" ] && fmt_time "$P_CFG" || echo '—')
   Compilación         : $( [ -n "$P_BUILD" ] && fmt_time "$P_BUILD" || echo '—')
   Instalación+UKI     : $( [ -n "$P_INST" ] && fmt_time "$P_INST" || echo '—')

 Ccache      : ${CCACHE_DIR:-$HOME/.cache/ccache}${CCACHE_STATS:+ }$CCACHE_STATS

IMPORTANTE:
 El kernel nuevo queda instalado y el UKI ha sido sincronizado.
 Para arrancarlo:

   sudo reboot

 Después del reboot, kernel-update-verify.service comprueba que el kernel
 cumple el perfil (y BORE si se pidió), el tiempo de arranque y busca
 regresiones en el journal.
 El kernel previo quedó archivado para rollback: krollback --list
===============================================================
SUMMARY

exit 0
