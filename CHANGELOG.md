## [27.31.25] - 2026-09-25

El compilador se elige al vuelo en cualquier build, no solo en `variant`.

Preguntar el CC solo en la 14 dejaba a las opciones que se usan a diario —`build`,
`buildfast`, `force`, `buildbore`, `buildborefast`, `ntsync`, `cachy`— atadas al
default del motor, sin forma de forzar `gcc` o `clang` justo cuando hace falta
(un LTO de clang que falla, o comparar compilers de verdad). Ahora al elegir
cualquiera de ellas (3, 4, 5, 7, 8, 14, 15, 16) aparece:

```
  CC (Enter usa el default):
    auto  elige según el sistema (clang si LTO/toolchain LLVM viable; si no gcc) (default)
    gcc   compilador GCC
    clang Clang/LLVM (necesario para el LTO)
    otro  teclea TU compilador (p. ej. gcc-14, clang-17 o una ruta). Se exigirá como dependencia si falta.
  CC [Enter=auto]:
```

- Enter no añade argumento: el default del motor ya es `auto`. Lo tecleado se
  pasa tal cual como `--cc`, así que también vale `gcc-14`, `clang-17` o una ruta.
- `ask_cc()` es una función compartida por todas las opciones, incluida la 14: la
  14 arrastraba su propia copia del submenú y ya se habían desincronizado (su
  prompt decía `lauto` en vez de `auto`, con un `l` de más).
- El submenú va a **stderr** y lo tecleado sale por stdout, para poder capturarlo
  con `$( )` sin que la pregunta desaparezca dentro del subshell.
- La prioridad `baja`/`alta` de cada opción se aplica en el mismo sitio, sin
  depender de un `VAR=x exec` (que solo exporta por su cuenta en algunos casos).
- 6 tests nuevos: las 7 opciones de build pasan por `build_and_exec`, la 14
  reutiliza `ask_cc`, `--cc` llega tal cual al motor, Enter no añade nada, la
  prioridad `alta` se propaga, y el submenú se ve. Suite: 273 ok, 0 fail.

## [27.31.24] - 2026-09-25

El rollback deja de ser un extracting de ficheros y pasa a reinstalar el paquete,
y el menú dice a cuál se vuelve antes de que elijas la opción.

Lo que pasaba: `krollback` extraía un `.tar.xz` con módulos + vmlinuz + UKI y
decía, muy honestamente, "esto NO es un downgrade de paquete". El resultado era
que **el kernel anterior no quedaba en ninguna parte del host**:

- El paquete que genera la build vive en el tmpfs de compilación, que se
  desmonta al terminar ("no se mantiene una segunda copia persistente").
- El paquete anterior **tampoco está en la caché de pacman**: con
  `CleanMethod=KeepCurrent` —el de `/etc/pacman.conf` en este host— la
  transacción que instala el nuevo borra el viejo de la caché.
- `/usr/lib/modules` solo conserva el release instalado: bore y bmq comparten
  `7.2.7-cizen-v3`, así que al cambiar de scheduler el anterior desaparece.

O sea que la redundancia era de mentira: el "kernel previo" archivado era una
foto de un kernel de tres builds antes, y deshacer un cambio de scheduler
implicaba recompilar.

- **El motor preserva el PAQUETE que acaba de instalar**: lo copia a
  `$ROLLBACK_DIR` en el momento de instalarlo (el último en que el fichero
  existe) y se queda solo con ese —"actual + previo", cada uno ~100 MB.
- **`rollback.info`**: manifiesto con `pkgbase`, `pkgver`, `release`, `sched`,
  `pkgfile` y fecha. El rollback se elige por paquete, no por release, porque
  bore y bmq tienen la MISMA release y solo difieren en el pkgrel.
- **`krollback` reinstala**: `pacman -U` del paquete preservado (módulos,
  vmlinuz y hooks) y después `cizen-uki-sync`, porque el UKI del ESP sigue
  apuntando al kernel recién sustituido y sin regenerarlo el reboot vuelve al
  kernel nuevo. La base de datos de pacman deja de mentir sobre qué hay
  instalado.
- **`krollback --list`** enseña el kernel anterior con su scheduler, su release
  y si el paquete está presente de verdad.
- **El archive de ficheros no se toca**: pasa a ser plan B para cuando falló la
  copia del paquete, y avisa de que deja pacman desincronizado.
- **Un archive de la misma release pero de otro pkgrel ya no se da por bueno.**
  Antes `prepare_rollback_archive` veía el fichero, veía que la release
  coincidía y lo conservaba —pudiendo ser el kernel de otro scheduler. Ahora se
  comprueba contra el manifiesto, y sin manifiesto se rehace.
- La copia va a temporal y se renombra: un `.pkg.tar.zst` truncado por una
  interrupción no llega a existe para que pacman lo instale a medias.
- `CIZEN_ROLLBACK_PKG=0` desactiva la preservación y vuelve al plan B.
- **El menú (opción 9) enseña en la etiqueta qué kernel hay para deshacer**:
  `volver al kernel anterior · linux-cizen-v3-7.2.7_cizen_v3-2 (bmq)`. Con bore y
  bmq compartiendo release, esa línea es la que distingue "vuelvo al mismo" de
  "vuelvo a otro kernel del mismo nombre". Si el manifiesto apunta a un paquete
  que ya no está, lo dice (`⚠ sin paquete`) en vez de dejar que se descubra al
  entrar; y si no hay manifiesto, no inventa uno.
- La opción 9 comprueba que el script exista y admite `CIZEN_KROLLBACK_SCRIPT`:
  vive fuera del motor y se instala por su cuenta, y un `exec` a un path
  inexistente solo suelta un error de bash que no explica nada.

Lo que esto **no** arregla: el paquete de bore (pkgrel-2) que había en este host
ya no existe en ninguna parte, así que volver a él sigue necesitando un build
`--sched bore`. A partir de ahora, ese build sí deja el paquete de BMQ
disponible para volver atrás.

## [27.31.23] - 2026-09-25

Un banco para comparar schedulers, porque el tiempo de arranque no sirve.

Preguntar "¿qué scheduler va mejor?" con los datos que había era comparar
manzanas con peras. El verificador solo guarda **el último arranque**, y de los
anteriores no queda ni el scheduler. Rehecha la extracción desde el journal, la
tabla que sale es esta:

| kernel | n | total min/med/máx | kernel | userspace |
|---|---|---|---|---|
| cizen-3 = **BMQ** | **1** | 18.406 | 2.321 | 6.963 |
| cizen-2 = **BORE** | **6** | 13.533 / **15.900** / 17.193 | 1.494 | 3.718 |

Se lee "BMQ es un 16% más lento" y no significa nada: **n=1 en el lado de BMQ**,
y ese arranque es el primero tras compilar e instalar (caché fría, mkinitcpio
recién ejecutado, UKI sin estrenar). Encima el tramo `firmware` —el mismo
hardware, cero influence del scheduler— se mueve de 4.639 a 7.240 s entre
arranques: ±1,5 s de ruido para una diferencia de 2,5 s. Y el 70% de la
diferencia está en `userspace`, que va de I/O y servicios. Los schedulers
alternativos compiten en **latencia interactiva**, no en arranque; un arranque
no es su métrica.

- **`kernel-update/sched-bench.sh`**: mide throughput de un hilo, escalado en
  paralelo y —la que de verdad distingue a estos schedulers— **cuánto tarda una
  tarea de primer plano con la máquina saturada**. Sin `time(1)`, con el
  `TIMEFORMAT` de bash y `date +%s%3N`: `/usr/bin/time` no está en el host, y
  el `time` de bash no da milisegundos.
- **`--resumen`**: tabla con la **mediana** de cada cifra por kernel, que es la
  que vale cuando hay que comparar dos builds.
- **Histórico acumulativo**: un bloque por ejecución en
  `~/.local/state/kernel-update/sched-bench-<kernel>-<scheduler>.txt`. El
  scheduler va en el nombre porque 7.2.7-cizen-v3 con `bore` y con `bmq` se
  llaman igual, y sin eso el segundo machacaba al primero y la comparación se
  comparaba consigo misma.
- **El scheduler medido sale de `/proc/config.gz`**, del kernel en marcha y no
  del que se pidió en el build: si el arranque falló y arranque otro, el
  resultado es del que hay.
- **La carga en paralelo se mata por PID**, nunca con `pkill -f`: el patrón
  coincide con la propia línea de órdenes de quien lanza el banco y se mata
  solo (pasó: dejó la máquina al 400% hasta que venció el tiempo).
- Se anota el **load average de antes** de medir, que es la única referencia
  útil para descartar una tirada hecha con el escritorio ocupado.
- Un parámetro mal escrito sale con `rc=2` **antes de medir**, no después de
  quemarte dos minutos de CPU al 100%.

Con el banco ya instalado, la mitad de BMQ queda medida: 7.459 ms de un hilo,
20.405 ms con 4, 10.107 ms de latencia con la máquina saturada. La mitad de BORE
no se puede tomar sin recompilar ese kernel (el rollback solo guarda el
tarball de fuentes), así que el par queda pendiente hasta que haya un build BORE.

## [27.31.22] - 2026-09-25

El verificador ya no confunde "imposible de habilitar" con "incumplido".

Lo que pasaba: el perfil pide `SCHED_AUTOGROUP` como símbolo CRÍTICO, pero el
parche PRJC que usan bmq/pds/lfbmq mete `depends on !SCHED_ALT` en ese Kconfig
(igual que en PSI, PSI_DEFAULT_DISABLED, NUMA_BALANCING y SCHED_CACHE): con el
scheduler alternativo puesto, **no hay forma de activarlo**. El motor lo sabe
desde v27.31.6 —los saca de las exigencias efectivas antes de validar, así que el
build sale bien y el perfil puede pedirlos sin problema—, pero el verificador
post-boot leía el perfil en crudo y contaba su ausencia como incidencia:

```
⚠ El kernel en ejecución NO cumple el perfil (1):
    CRITICAL: CONFIG_SCHED_AUTOGROUP no existe en el kernel en ejecución
```

O sea: `Perfil: FALLO` y notificación `critical` en cada arranque por un símbolo
que nadie puede arreglar, y que tampoco era un problema: el kernel arrancado
cumplía todo lo exigible. En este host era la única incidencia que quedaba, la
que vestía de alarma el aviso de "kernel verificado".

- **La firma del build graba `retired=`**: los símbolos que `PATCH_RETIRED_ALL`
  retiró, que es la lista real que el motor aplicó (no una suposición del
  verificador). Se omite la línea cuando no hay ninguno, para no fijar una lista
  vacía que taparía la deducción por `sched=`.
- **El verificador los salta** en los cuatro bucles del perfil (ENABLE, CRITICAL,
  SETVAL y SETSTR), los informa como `• perfil: N exigencia(s) omitidas —
  retiradas por el parche del scheduler (BMQ)` y **no cuenta incidencia**: mismo
  criterio que los `=m` del modo lite y que el firmware presente en el árbol.
- **Firmas anteriores (sin `retired=`)**: se deducen del scheduler efectivo con la
  misma tabla que el motor, así que el arreglo surte efecto sin esperar a un
  build nuevo. bore y muqss no retiran nada —su patch no toca esos símbolos— y esa
  tabla está fijada por tests para que no se invente una lista más ancha de la
  cuenta.
- **Rastro en el log**: `verify.log` anota cuántos símbolos se saltan y de dónde
  salió la lista, para que un "omitida" no sea un misterio al auditar a mano.
- El resumen y la notificación pasan a `Perfil: OK` / **0 incidencias**, con
  severidad `normal` en vez de alarma.

Tests: 13 nuevos (selftest **222 → 235, 0 fail**): `retired=` se graba con lo que
retiró `PATCH_RETIRED_ALL` y no se graba si no hay nada (y la firma sigue
íntegra); la tabla cubre pds/bmq/lfbmq y **no** inventa retirados para
bore/muqss/eevdf; la firma manda sobre la tabla, sin firma no se salta nada, y
sin `retired=` la lista se deduce; el motivo identifica al scheduler; y los
cuatro bucles del perfil saltan los retirados **antes** de contar la incidencia.

## [27.31.21] - 2026-09-25

La notificación del verificador solo sale cuando el estado **cambia**.

Lo que pasaba: con el estado ya limpio de v27.31.20 quedaban 2 incidencias
recurrentes —el scheduler arrancado hasta que haya reboot, y Secure Boot
desconocido, que no se arregla solo— y la unit, que corre en cada arranque,
volvía a lanzar una notificación `critical` con icono de alarma **por lo mismo**
una y otra vez. Un aviso que se repite no informa de nada: entrena al usuario a
ignorarlo, y el día que aparezca algo de verdad ya no se mira.

- **Firma de estado** (`verify_state_fingerprint`) con lo que hay que reaccionar:
  `perfil`, `sched` (kronizado/en ejecución), `journal`, `fw`, `sb` e
  `iss`. Se guarda en `~/.local/state/kernel-update/verify-notify-state`.
- **El tiempo de arranque queda fuera de la firma a propósito**: 15.8675 s frente
  a 15.8671 s no es un cambio de estado, y si estuviera dentro no se callaría
  nunca. Un boot que empeora sí notifica, pero porque lo marca como incidencia
  (umbral de factor y delta), no porque el número se mueva.
- **La notificación explica qué cambió**: cuerpo con el diff componente a
  componente (`• sched: bmq/bore → bmq/bmq`, `• journal: 0 → 1`).
- **Resolver no es una alarma**: a 0 incidencias la notificación baja a
  severidad `normal` con icono `emblem-ok` («sin incidencias»).
- **Primer arranque de un kernel nuevo** sigue avisando siempre: eso sí es novedad.
- **`--no-notify`**: verifica y actualiza el estado sin lanzar notificación.
  Sirve para sembrar la línea base (si no, la primera ejecución habría disparado
  un «cambio» que no lo es) y para pasar la comprobación a mano sin que salte un
  aviso en el escritorio. `--dry-run` no guarda estado, para que una simulación
  no pueda silenciar la notificación real siguiente.

**Falso positivo que sale de paso: Secure Boot no estaba pendiente.** El
verificadorlehía el estado de Secure Boot con `case` sobre la línea de
`bootctl status`, y los patrones eran `*'enabled'` / `*'disabled'`. En `case`, un
patrón sin comodín final exige que la cadena **termine** ahí, y `bootctl` imprime
`Secure Boot: enabled (user)` — que acaba en `(user)`. El patrón no casaba nunca,
así que el verificador informaba **"SB desconocido" con Secure Boot
perfectamente activo** y pedía activarlo en la BIOS a quien ya lo tenía
activado, con `critical` incluido, y lo repetía en cada arranque. Anclado al
campo (`*'Secure Boot: enabled'*`).

Con el arreglo, en este host: `Secure Boot: yes (UKI firmada; SB HABILITADO)`
(`sbctl`: Setup Mode **Disabled**, Secure Boot **Enabled**), y las incidencias
bajan de 2 a 1: **solo queda el scheduler**, que sí está pendiente hasta que
reinicies en la UKI BMQ.

Tests: 9 nuevos sobre la notificación (selftest **207 → 222, 0 fail**): estado
persistido, cobertura de la firma, tiempo de arranque fuera de la firma, y el
comportamiento real de `notify_state_changed` con el estado escrito a mano
(primera vez notifica, idéntico no, cambio en el número de incidencias sí), diff
en el cuerpo, bajada de severidad al resolverse y `--dry-run` sin persistir. El
4 de los 15 nuevos fijan el estado real de Secure Boot, contra un `bootctl` de
mentira con la salida auténtica (`enabled (user)` → HABILITADO y sin incidencia,
`disabled` → desactivado, sin dato → desconocido): el patrón roto convivía con
los tests porque **nadie comprobaba que la función leyera bien el valor** —que es
justo el fallo que hacía que dijera "desconocido"—. Los 2 restantes no son del
parche. Uno es un test de la unit que desde v27.31.19
era **imposible de satisfacer** al correr el selftest instalado (buscaba
`/usr/local/bin/systemd/user/…` con una ruta relativa): falso rojo sin motivo
real, el tipo de test que entrena a ignorar los que fallan. Ahora mira la unit
donde vive en cada layout (repo o `~/.config/systemd/user/`) y, si están las dos
copias, exige que no hayan divergido. El otro fija que el fichero de estado se
guarde con `
` final: sin él, `while read` se salta la última línea, que es
justo la que dice qué estado se guardó.

- En **rojo** contra el verify de v27.31.20: **209 ok, 7 fail**; contra el
  commiteado de v27.31.18: **199 ok, 19 fail** (6 de ellos de este parche).
- Selftest **instalado**: **221 ok, 0 fail** (un test menos: el de comparar las
  dos copias de la unit solo aplica en el layout del repo).

Verificado en el host: sembrada la línea base con `--no-notify` y, tras dos
ejecuciones más de la unit, `Incidencias: 2` con **ninguna notificación** nueva.
El próximo aviso llegará cuando cambies de kernel (al reiniciar en la UKI bmq)
o cuando se arregle Secure Boot.

## [27.31.20] - 2026-09-25

El verificador deja de contar como fallos cosas que el propio motor acepta.

Lo que pasaba: con la unit ya instalada y habilitada (v27.31.19), la primera
notificación llegó con **6 incidencias** en un arranque perfectamente bueno:

    Kernel Cizen: 7.2.7-cizen-v3 verificado con 6 incidencias
    Perfil: FALLO | Boot: 15.867s | Journal: 0 patrones | FW: 1

Cuatro de las seis no eran nada:

- **3 × `Perfil: FALLO`** (`CONFIG_BT_HCIBTUSB`, `CONFIG_SND_HDA_CODEC_ALC269`,
  `CONFIG_SND_HDA_CODEC_HDMI_INTEL` en `=m` donde el perfil pide `y`). El motor
  **acepta `y` o `m`** en `OPTS_ENABLE` (`validate_config`) porque el modo lite
  hace `make localmodconfig`, que degrada a módulo lo que este hardware no tiene
  cargado; el config promovido del build nuevo los tiene igual en `=m`. El
  verificador era más estricto que el motor y cobraba como fallo algo que él
  mismo acaba de producir. Ahora `=m` se informa como nota y no cuenta;
  `=n` y `missing` siguen contando.
- **`FW: 1`** — `Direct firmware load for i915/kbl_dmc_ver1_04.bin failed`. El
  fichero **sí está** en el árbol: `/usr/lib/firmware/i915/kbl_dmc_ver1_04.bin.zst`
  (`linux-firmware-intel` 20260916-1, instalado el 21 de septiembre, antes del
  arranque). El driver pide el nombre sin extensión, el kernel tiene el
  comprimido y sigue funcionando: el propio driver lo dice
  («Disabling runtime power management»). Ahora se distingue: carga fallida con
  el fichero presente en el árbol = nota; fichero ausente de verdad = incidencia.

Las dos que quedan son reales y accionables: el **scheduler** arrancado (`BORE`)
no es el que kronizó el último build (`BMQ`) —se arregla reiniciando en la UKI
nueva, que ya tiene `CONFIG_SCHED_BMQ=y`— y **Secure Boot desconocido** (la UKI
se firmó con sbctl, pero sin SB activado la firma no efecto; falta
`sbctl enroll-keys --microsoft` + activar SB en la BIOS).

Tests: 4 nuevos (selftest **203 → 207, 0 fail**): el verificador acepta `=m`
como el motor, distingue firmware presente de ausente, lo ausente sigue
contando, y la extracción del nombre de firmware admite rutas con
subdirectorios (`i915/…`, `intel/ice/…`). En **rojo** contra el verify instalado
de v27.31.19: **205 ok, 2 fail**. Comprobado además en vivo: con
`CIZEN_FIRMWARE_DIR` apuntando a un árbol vacío el chequeo de firmware vuelve a
dar 5 problemas, o sea que la rama de «ausente de verdad» sigue viva.

## [27.31.19] - 2026-09-25

El verificador post-boot comprueba **todos** los schedulers, y el tmpfs de
compilación se desmonta de verdad tras cualquier build exitoso.

Lo que pasaba (v27.31.18 y anteriores): el resumen de un build terminado
prometía «Después del reboot, kernel-update-verify.service comprueba que el
kernel cumple el perfil (y BORE si se pidió)» cuando **ese servicio no existía**
—ni de sistema ni de usuario— y su script ni siquiera estaba instalado. Y lo
peor: el verificador solo miraba `CONFIG_SCHED_BORE`, así que un build `bmq`
se reportaba como «EEVDF vanilla» y se daba por bueno **sin comprobar nada**.

- **SCHED para todos los schedulers.** El motor graba el scheduler **efectivo**
  en la firma (`sched=` en `~/.local/state/kernel-update/last-build`, vía la
  nueva `effective_scheduler`; `inherit` se resuelve a lo que se aplicó de
  verdad, porque «inherit» no es comprobable). El verificador lee
  `SCHED_BORE`/`SCHED_PDS`/`SCHED_BMQ`/`SCHED_LFBMQ`/`SCHED_MUQSS` del config en
  ejecución y compara: cubre `inherit`, `eevdf`, `bore`, `pds`, `bmq`, `lfbmq` y
  `muqss`. Es tolerante a que un kernel tenga más de un símbolo activo (BORE y
  los conviven en el fork): se exige el del scheduler prometido, no que los
  demás estén apagados. Las firmas anteriores sin `sched=` se siguen deduciendo
  de `bore=`/`patches=`, así que no hay que reconstruir.
- **`sched_check` es un paso propio.** Estaba dentro de `profile_check`, que
  corre en sustitución de comandos: los globales que fijaba se perdían y el
  resumen siempre imprimía `Scheduler: unknown`. Además, `sched_check` vive
  fuera porque su salida va al journal mientras que el resumen va a stdout.
- **Desmontaje garantizado tras éxito total.** `unmount_tmpfs_build` reintenta
  (2 intentos, 2 s de margen para el subproceso que suele sujetar el árbol) y
  **mide la RAM recuperada** con la nueva `get_mem_available_mb`
  (`MemAvailable` del sistema, no el espacio del tmpfs). Distingue los dos fallos
  posibles: sin credenciales sudo utilizables, o EBUSY — y en el EBUSY lista los
  procesos que están dentro del tmpfs. `sudo -n umount`: nunca se queda
  esperando una contraseña a mitad de un build. `CIZEN_KEEP_TMPFS=1` sigue siendo
  el opt-out, y ahora se dice que es deliberado. Los flujos parciales (un `check`
  que prepara el entorno) **no** desmontan: el build siguiente reutiliza el árbol.
- **Red de seguridad en el trap EXIT.** Si un flujo completo saliera por una vía
  que no llegue a `cleanup_success`, el tmpfs se desmonta igualmente al salir
  (`rc == 0 && FULL_PIPELINE_OK && !CLEANUP_DONE`).
- **El resumen dice la verdad.** `Build tmpfs:` termina con su estado real
  (desmontado y cuántos GB volvieron a la RAM / no desmontado con el motivo /
  conservado a propósito) y `Verificador:` comprueba si el script y la unit
  existen y están habilitados, en vez de prometer una comprobación que no ocurre.
  El reinicio se **sugiere** (`Para arrancarlo (no se reinicia solo)`), nunca se
  ejecuta.
- **La unit existe.** `systemd/user/kernel-update-verify.service` (nuevo),
  `Type=oneshot`, `After=graphical-session.target`, `WantedBy=default.target`,
  `TimeoutStartSec=300` (el escaneo de firmware de todos los módulos cargados es
  la parte lenta). Instalada y habilitada; con `--dry-run` se puede ejecutar a
  mano sin persistir estado ni notificar.

Tests: 30 nuevos (selftest **173 → 203, 0 fail**): `effective_scheduler` para los
6 schedulers + `inherit` nunca devuelto + bore dentro de `PATCHES_APPLIED` +
solo-`ntsync` = eevdf; `sched=` en la firma; desmontaje en éxito total, en
apilados, con EBUSY (2 intentos + aviso), con `CIZEN_KEEP_TMPFS=1` y en flujo
parcial; red de seguridad del trap EXIT; las cuatro variantes del resumen;
`running_sched`/`sched_symbol_for`/`sched_label`/`expected_sched_from_signature`
(incluidos los fallbacks de firma antigua); `sched_check` fuera de
`profile_check`; existencia y contenido de la unit. En **rojo** contra el
v27.31.18 instalado: **186 ok, 17 fail**. `shellcheck` sin avisos nuevos (los
SC2034 que quedan son preexistentes).

Dos cosas que solo aparecieron probando de verdad: (1) la sonda previa
`sudo -n true` **nunca habría dejado desmontar nada** en un host con allowlist de
sudoers por comando (este host la tiene): se deniega aunque `umount` sí esté
permitido, así que el `umount` ni siquiera llegaba a intentarse — ahora la sonda se
quitó y solo se usa el error real para explicar el fallo; (2) la RAM devuelta se
medía con `df` del tmpfs, que tras el desmontaje cambia de filesystem y daba
siempre «~0 GB» — por eso `get_mem_available_mb`. Con el código nuevo, el
tmpfs de 7,1 GB que había quedado del build `7.2.7-cizen-v3` se desmontó y
`MemAvailable` pasó de 2,5 GB a 7,9 GB.

## [27.31.18] - 2026-09-25

El motor ya no ofrece compilar una versión que no puede compilar (cierra la
contradicción de la opción 14 con pds/bmq/lfbmq/muqss).

Lo que pasaba: el menú (v27.31.16) ofrece correctamente la release del fork
cuando el scheduler solo existe allí —aceptabas 7.2.7 y el motor arrancaba— pero
enseguida el motor hacía su **otra** pregunta, la de kernel.org:

    ✓ Nueva release (stable) detectada: 7.2.7 → 7.2.8
      Hay una release estable más nueva de kernel.org: 7.2.7 → 7.2.8
      ¿Deseas compilar la versión más nueva (7.2.8)? [S/n]

Con `S` no empezaba el build: `resolve_cachyos_release 7.2.8` abortaba porque el
fork no la tiene. Dos preguntando por lo mismo, en sitios distintos, y la
segunda deshacía lo acordado en la primera.

- `cachyos_release_tagrel <ver>`: la consulta al fork (API de releases + sondeo
  de `.asc`) separada de `resolve_cachyos_release`, que se queda con la
  resolución y su `fatal`. La nueva **no aborta nunca**: deja el tagrel en
  `CACHYOS_TAGREL` y el contexto en `CACHYOS_API_OK`, `CACHYOS_SEEN_TAGS` y
  `CACHYOS_LATEST_MINOR` (última X.Y.Z de la misma línea, vía `sort -V`).
  Una sola fuente de verdad: si el fork no tiene la versión, ahora lo dicen el
  aviso y el fatal por la misma llamada.
- `confirm_newer_release` consulta al fork **solo** si el árbol es `cachyos`:
  - el fork no la publica → no se pregunta; se explica («aún no publica 7.2.8 y
    este build compila contra su árbol») y, si la última de esa línea es
    distinta de la pedida, se recuerda (no si ya ibas a esa).
  - el fork sí la publica → la oferta se mantiene y se dice que es compilable.
  - la consulta falla (red, rate-limit) → **fail-open**: no se afirma una
    ausencia que no se ha podido comprobar y la oferta sigue como antes.
  Con árbol `vanilla` no se toca la red: 7.2.8 sí se puede compilar.
- `resolve_kernel_tree` se llama **antes** de la pregunta (es pura e
  idempotente, depende solo de `CIZEN_KERNEL_TREE` y `PATCH_NAMES`): sin eso
  `KERNEL_TREE` seguía valiendo `auto` y la comprobación no podía hacerse.

Tests: 11 nuevos (no ofrecer lo que el fork no tiene, el consejo accionable
7.2.7, no repetirlo si ya la pediste, vanilla sin tocar la red, oferta intacta
si el fork sí la tiene, fail-open sin red, la consulta no pisa `CACHYOS_TAGREL`,
dos guardas estáticas, y la consulta al fork por separado: tagrel máximo,
versión ausente con `CACHYOS_API_OK=1` y `CACHYOS_LATEST_MINOR`). Selftest
**162 → 173, 0 fail**; `shellcheck` sin avisos nuevos. Además, con el motor
entero y la red simulada (kernel.org 7.2.8, fork solo hasta 7.2.7):

    kernel-update.sh 7.2.7 --sched bmq  → ⚠ aún no publica 7.2.8 … se conserva 7.2.7
    kernel-update.sh 7.2.6 --sched bmq  → ⚠ + • su última 7.2.x publicada es 7.2.7
    kernel-update.sh 7.2.7 --sched eevdf → sin cambios, no consulta al fork

## [27.31.17] - 2026-09-25

Desmontaje inteligente: el tmpfs de compilación deja de arrastrar árboles que
no sirven para el build que va a salir, y se desmonta entero (devolviendo la
RAM) cuando no queda nada aprovechable.

El problema de fondo: el directorio del árbol solo lleva la versión
(`$TMPFS_ROOT/linux-X.Y.Z`), así que "reutilizar el árbol" **mezclaba** sin
avisar:

- Un vanilla conservado se reutilizaba para un build del fork de la **misma**
  versión. Los parches `-cachy` no aplican sobre vanilla, y el fallo no aparece
  como error de parche sino como kernel equivocado.
- El margen de espacio se decidía con `[ -d "$SRC" ]`: un árbol del tipo
  equivocado contaba como reutilizable, así que el motor aplicaba el margen
  incremental (2048 MB) y luego `extract_tarball` lo borraba para extraer
  4-5 GB de cero → `ENOSPC` a mitad de la extracción.
- Un build interrumpido dejaba el árbol a medias (con `Makefile` y todo) y el
  siguiente lo reutilizaba tal cual.

- `tree_usable_for <dir> <versión> <tipo>`: fuente única de verdad de si un
  árbol sirve. El tipo lo fija el parche/scheduler (`pds|bmq|lfbmq|muqss` →
  `cachyos`), que es la dimensión que hace que dos árboles no sean
  intercambiables; los parches de terceros se aplican en cada build y no
  invalidan nada.
- `reconcile_tmpfs_trees`, antes del chequeo de espacio: clasifica cada
  `linux-*` del tmpfs (reutilizable / otro tipo / otra versión / a medias),
  **descarta siempre** lo que no sirve y, si no queda nada aprovechable y no hay
  nada más que preservar (paquetes, artefactos), **desmonta el tmpfs entero**
  para devolver la RAM de golpe y montar limpio. `CIZEN_SMART_UMOUNT=0` o
  `CIZEN_KEEP_TMPFS=1` purgan sin desmontar.
- `source_tree_reusable` sustituye a `[ -d "$SRC" ]` en los tres puntos donde
  se decidía el margen de espacio (`check_build_memory`, `prepare_tmpfs_build`,
  `liberate_tmpfs_space`), que es donde el bug se traducía en ENOSPC.
- Testigo `.cizen-extracting-<versión>` en la raíz del tmpfs mientras se extrae:
  una extracción interrumpida deja el árbol a medias y ya no cuenta como
  reutilizable. Vive fuera del árbol para no interferir con la extracción ni
  con el renombrado del tarball del fork (que extrae en `cachyos-X.Y.Z-N`).
- Testigo `.cizen-tree` (version + kind) en cada árbol recién extraído, para
  que la reconciliación no tenga que deducir la identidad del `Makefile`. Los
  árboles anteriores se deducen igual (`kernel/sched/poc_selector.c` = fork).
- Montajes **apilados** tolerados: un `umount` interrumpido deja varios tmpfs en
  el mismo punto y `findmnt -M` devuelve una línea por montaje, así que las
  comparaciones veían `tmpfs\ntmpfs` y el motor se paraba con un error
  ilegible. Todas las consultas toman la primera línea, se avisa de la pila y
  `tmpfs_umount_all` desmonta todos los niveles (uno solo no devuelve la RAM).
- Corregido de paso `ntsync`: la decisión de añadir el parche para kernels sin
  soporte nativo (< 6.10) estaba en un bloque top-level que llamaba a
  `kernel_version_ge`, definida 5000 líneas más abajo. Con `set -e` dentro de
  `! ...` el 127 no abortaba pero **invertía la decisión**: `ntsync` se añadía a
  todos los kernels, y cada ejecución escribía `kernel_version_ge: orden no
  encontrada` en el stderr. Ahora la decisión vive en
  `auto_add_ntsync_patch()`, llamada desde el flujo principal.

Tests: 23 nuevos (identidad, reutilización por tipo, árbol a medias, purga,
paquete que impide el desmontaje, `CIZEN_SMART_UMOUNT`/`CIZEN_KEEP_TMPFS`,
tmpfs no montado, apilados, tmpfs ocupado, ntsync) y el detector de orden de
funciones reescrito: antes solo miraba `$1` y por eso no vio el bug de
`ntsync`; ahora examina la línea entera (solo nombres que son funciones
definidas en el fichero, así que sin falsos positivos) y lleva un test que lo
comprueba contra un fixture. Selftest **138 → 162, 0 fail**, en rojo (17
fallos) contra v27.31.16. `shellcheck` sin avisos nuevos.

Verificado además sobre un tmpfs real (montado y desmontado de verdad): árbol
vanilla incompatible → purga + desmontaje; árbol propio correcto → se conserva
y se purga el ajeno sin desmontar; montajes apilados → se desmontan los tres.

## [27.31.16] - 2026-09-25

El menú avisa **antes** de compilar cuando la stable que anuncia kernel.org
todavía no está publicada en el fork CachyOS/linux, en lugar de dejar que el
build reviente a mitad con el error de `resolve_cachyos_release`. Es la
continuación de v27.31.15: el aviso mostraba la causa, pero el usuario se
enteraba tras haber lanzado el build.

- `load_fork_tags` sondea la API de releases del fork (máx. 5 s) y **cachea**
  los tags 6 h en `${XDG_STATE_HOME:-$HOME/.local/state}/kernel-update/cachyos-fork-tags.cache`
  (`CIZEN_FORK_TAGS_TTL` para ajustar). Sin red o API caída no se avisa de nada
  y el menú sigue igual: **fail-open**, nunca bloquea. `CIZEN_MENU_SKIP_FORK_CHECK=1`
  lo desactiva.
- Cabecera: aviso con la última release del fork de esa línea (`7.2.x → 7.2.7`)
  y la opción 14 marcada. Si el fork no tiene ninguna release de esa línea, el
  aviso dice que use `eevdf` y que los schedulers del fork volverán cuando se
  publiquen.
- Opción 14: si el scheduler elegido (`pds|bmq|lfbmq|muqss`) solo existe en el
  fork y la versión no está allí, **ofrece la última del fork** de esa línea
  («¿Compilar 7.2.7 en su lugar? [S/n]») y pasa la versión como argumento
  posicional al motor. Responder `n` deja la versión pedida (el motor explica la
  causa). Sin TTY no se pregunta: se comporta como antes.
- `bore` y `eevdf` no se ven afectados: `bore` compila vanilla y `eevdf` es
  mainline, así que ninguno fuerza el árbol del fork.

Tests: 5 nuevos (bash -n del menú, tagrel máximo, fallback de la línea sin
inventar releases a partir de tags `-rc`, `7.2.80` no se confunde con `7.2.8`,
y fail-open + TTL + guarda de TTY). Selftest **133 → 138, 0 fail**; verificados
en rojo contra el menú instalado anterior. `shellcheck` sin avisos nuevos.

Deploy con paridad sha256 (motor `19492d02…`, menú `9aca2555…`, selftest
`2573953f…`).

## [27.31.15] - 2026-09-25

La opción 14 (bmq/clang) sobre la nueva stable **7.2.8** abortaba con un error
inexplicable — `Error 1 en línea 1081: tail -n1` — y sin llegar al diagnóstico
que el propio motor tenía preparado. Causa raíz: **CachyOS todavía no ha
publicado 7.2.8** (su último release 7.2.x es `cachyos-7.2.7-1`; 7.3 va por
`rc4`), así que la resolución del tagrel no encuentra nada y el `grep` final de
la tubería de parseo del JSON devuelve 1. Con `set -Eeuo pipefail` + `trap ERR`
eso **mata la run entera**: no se llega al sondeo directo de `.asc` ni al
`fatal` que explicaba la causa. El bug era que la tubería no estaba guardada.

- `|| true` en la tubería de parseo: sin coincidencias devuelve vacío y el
  flujo sigue su curso (sondeo directo → `fatal`).
- Diagnóstico accionable cuando el fork no tiene la versión: se listan los
  últimos tags publicados, se recuerda que los schedulers/tuning del proyecto
  solo existen en el fork, y se ofrecen las dos salidas reales (compilar una
  versión que el fork sí tenga con `--version`, o un scheduler de mainline
  que sí puede compilar esa versión vanilla desde kernel.org).
- **Regresión cubierta**: dos tests del selftest que reproducen el marco real
  (`set -Eeuo pipefail` en un subshell **sin** `||`/`&&` alrededor — una
  sustitución de comandos dentro de una lista `||` hereda errexit desactivado y
  daría falso verde) y comprueban que la función alcanza su propio `fatal`, y
  que la guarda no rompe el camino feliz. Verificados en rojo contra el motor
  sin la guarda. Selftest **131 → 133, 0 fail**.

⚠️ Estado del objetivo: para completar el build end-to-end con bmq/clang hay que
usar **7.2.7** (la última que el fork publica), no 7.2.8.

Deploy con paridad sha256 (motor `f58f61b0…`, selftest `b5dc2c28…`).

## [27.31.14] - 2026-09-25

Cierra el build end-to-end de la opción 14 (bmq/clang): el fallo de
post-compilación era un **bug latente de orden de funciones**.
`collect_build_artifact` se invocaba desde el flujo principal (línea 8507,
top-level) y se definía 200 líneas más abajo (8705). En bash el archivo se
interpreta secuencialmente, así que la llamada se ejecutaba antes de que la
función existiera → `orden no encontrada` y el `fatal` de
"No se pudo identificar/verificar el artefacto generado". `bash -n` no lo
detecta (no es un error de sintaxis) y la ruta nunca se había ejecutado en
ningún build anterior, por eso llevaba latente desde que el helper entró en
v27.30.0.

- Fix: el bloque de `collect_build_artifact` se mueve justo detrás de
  `copy_packages_from_build` (su único helper), de forma que toda la cadena de
  artefactos queda definida antes del flujo principal.
- Barrido estático de las 158 funciones del motor: no queda ninguna llamada
  top-level anterior a su definición.
- **Regresión cubierta**: nuevo test del selftest que analiza el motor en dos
  pasadas (definiciones y luego llamadas) y falla si aparece una referencia
  adelantada. Verificado en rojo contra el motor v27.31.12 commiteado
  (`collect_build_artifact, línea 8507, def 8705`) y en verde con el fix.
  Selftest **130 → 131, 0 fail**.

De paso se consolida en el repo el perfil **v5.12.1 → v5.12.2**: los 16
símbolos que Kconfig conserva por dependencia (codecs HDA `ALC260…ALC882` +
`HDMI_ATI/NVIDIA/MCP/SIMPLE/TEGRA`, `TDX_HOST_SERVICES`,
`WATCHDOG_PRETIMEOUT_GOV_SEL`) pasan de `OPTS_DISABLE` a `EXPECTED_REBELS`. Es
lo que hace el propio motor con `--absorb-rebels` (con backup
`.bak-<fecha>`), pero el cambio se había quedado solo en la copia instalada:
ahora repo == instalado, con la nota de por qué en la cabecera. No se fuerza
`CONFIG_EXPERT` (lo apagaría todo, cientos de prompts); solo se absorbe lo que
la validación ya demostró que no se puede desactivar. Perfil: ENABLE 33,
DISABLE 263→247, REBELS 34→50, sin duplicados ni contradicciones.

Deploy con paridad sha256 (motor `b97b1f2d…`, perfil `5d6b8351…`, selftest
`079a93aa…`, root:root 755/644).

## [27.31.13] - 2026-09-25

Fix de validación FATAL en la opción 14: `SETVAL CONFIG_HID_PLAYSTATION
esperado=m real=missing`. Causa raíz: v27.31.10 metió `LEDS_CLASS_MULTICOLOR` en
`OPTS_DISABLE`, pero el driver de mandos PS4/PS5 (`HID_PLAYSTATION=m`, exigido
por el perfil) tiene `depends on LEDS_CLASS_MULTICOLOR` — al desactivarlo el
símbolo no podía resolverse y la auditoría abortaba. Perfil **v5.12.0 → v5.12.1**:
`LEDS_CLASS_MULTICOLOR` sale de la poda (DISABLE 264→263); el allowlist del
podador ya conserva `hid_playstation hid_sony hid_nintendo hid_steam xpad joydev
uhid hidp`, así que los mandos siguen compilándose aunque ahora mismo no haya
ninguno conectado. Verificado en el árbol 7.2.7: con `LEDS_CLASS_MULTICOLOR=m`,
`HID_PLAYSTATION=m` se resuelve con `olddefconfig`.
Nota: los 16 avisos de códecs que "Kconfig conserva" (ALC260…ALC882, HDMI_*,
TDX_HOST_SERVICES, WATCHDOG_PRETIMEOUT_GOV_SEL) son NO fatales — esos `=m` solo
se pueden desactivar con `CONFIG_EXPERT=y` (ni el config base ni CachyOS lo
activan); el ahorro real de v27.31.10 viene de ASoC/SOF/SST, sí efectivo.
Deploy con paridad sha256 del perfil (repo==instalado, `374617ff…`). El motor no
cambia (sigue v27.31.12).

## [27.31.12] - 2026-09-25

Fix del arranque del motor cuando el perfil se instaló con `sudo` (propietario
root uid 0): el perfil se ejecuta con `source` y el chequeo de confianza exigía
`_pf_uid == id -u`, abortando para el usuario normal incluso con una instalación
de sistema legítima. Ahora se acepta también **root (uid 0)**; el otro criterio
sigue intacto (no escribible por grupo u otros usuarios, `mode` sin 2/3/6/7).
Un perfil root `755` es de mayor confianza, no menor: solo root puede
modificarlo. Selftest 129→130 (test del nuevo chequeo). Deploy con paridad
sha256 (motor `f0c84d62…`, selftest `19a877e3…`).

## [27.31.11] - 2026-09-25

`modprobed-db` deja de ser opt-in: el motor pasa a **auto-descubrimiento por
defecto** (`CIZEN_MODPROBED_DB=1` + `--modprobed-db` también disponible como
`--no-modprobed-db` para desactivar). El usuario instaló `modprobed-db` v2.50
(base en `~/.local/share/modprobed-db/modprobed.db`, 65 módulos capturados), que
es justo la primera ruta que `prepare_lite_config` sondea; el historial
persistente alimenta `make localmodconfig` junto a `/proc/modules` y el
allowlist, de modo que en el próximo build iterativo solo se compilan los
módulos que este hardware ha llegado a cargar alguna vez.

- Default `CIZEN_MODPROBED_DB:-0 → :-1` (sigue aceptando ruta explícita).
- `modprobed-db` pasa a ser **dependencia requerida**: `check_prerequisites`
  aborta si falta (con la sugerencia `yay -S modprobed-db`, ya que es un
  paquete AUR y no puede autoinstalarse con pacman). `--no-modprobed-db`
  (`CIZEN_MODPROBED_DB=0`) la exime explícitamente.
- Selftest 126→129 (default auto + requerida con yay + exención `--no-...`).
- Deploy con paridad sha256 (motor `c7eb9975…`, selftest `3de87cdf…`).

## [27.31.10] - 2026-09-25

Adelgazamiento del perfil para el i5-7500/Kaby Lake (petición del usuario: kernel
menos gordo y compilación más rápida). El host usa ALSA HDA legacy
(`lsmod`: `snd_hda_intel` + codec `ALC269` + `intelhdmi`, y **cero**
`snd_soc*`/`sof*`/`soundwire*`), así que se retiran del árbol source todo el
gasto de compilación ajeno al hardware:

- **ASoC/SOF/SST completo**: `SND_SOC`, `SND_SOC_SOF_TOPLEVEL`,
  `SND_SOC_SOF_INTEL_TOPLEVEL`, `SND_SOC_INTEL_SST_TOPLEVEL`,
  `SND_SOC_INTEL_MACH`, `SND_SOC_INTEL_USER_FRIENDLY_LONG_NAMES`,
  `SND_SOC_SDCA_OPTIONAL`, `SND_SOC_I2C_AND_SPI`, `SND_SOC_HDA`.
- **Códecs HDA de otros vendors**: `SND_HDA_CODEC_ALC260/262/268/662/680/861/
  861VD/880/882` y `SND_HDA_CODEC_HDMI_ATI/NVIDIA/NVIDIA_MCP/SIMPLE/TEGRA`.
  Se conservan `ALC269` (el ALC3234 usa este driver), `REALTEK*` y
  `SND_HDA_CODEC_HDMI` + `HDMI_INTEL` (este último con su `select`
  `HDMI_GENERIC` → queda intacto).
- **Huecos de plataforma**: `TDX_HOST_SERVICES` (Kaby Lake no tiene TDX),
  `WATCHDOG_PRETIMEOUT_GOV_SEL`, `LEDS_CLASS_MULTICOLOR`,
  `ACPI_PROCESSOR_AGGREGATOR`, `PERF_EVENTS_INTEL_RAPL` (movido de SETVAL a
  DISABLE; RAPL sensado sigue vía `INTEL_RAPL_CORE`) y `MQ_IOSCHED_ADIOS`.
- Nota: `SND_INTEL_SOUNDWIRE_ACPI` **NO** se desactiva: el `select` de
  `SND_INTEL_DSP_CONFIG` (exigido por `SND_HDA_INTEL`) lo mantiene en `=m`
  con los humildes bytes de su helper ACPI.
- Perfil: `cizen-optiplex7050.conf` v5.12.0 (OPTS_DISABLE 249→264). El modo
  lite ya es el único modo de compilación, así que el recorte reduce directa-
  mente los `.ko` que Kbuild produce en paralelo a `vmlinux`.

## [27.31.9] - 2026-09-24

La build clang real de la opción 14 (BMQ sobre `cachyos-7.2.7-1`) llegó por fin
al enlazado final de `vmlinux`, pero el `LD` falló con `undefined symbol:
rt_mutex_futex_pre_schedule` / `rt_mutex_futex_post_schedule`. Causa raíz:
mainline 7.x llama a esos hooks desde `kernel/locking/rtmutex_api.c` (path de
futex PI en `rt_mutex_wait_proxy_lock`), pero con `SCHED_ALT` se compila
`kernel/sched/alt_core.c` **en lugar de** `core.c` (donde mainline los define),
y el forward-port PRJC incrustado no los portó.

- Nueva función `_sched_alt_rtmutex_futex_fixup()`: autocontenida e idempotente.
  Solo actúa si (1) existe `kernel/sched/alt_core.c` (scheduler SCHED_ALT
  activo), (2) `rtmutex_api.c` referencia `rt_mutex_futex_pre_schedule` (mainline
  lo pide) y (3) `alt_core.c` aún no lo define (re-ejecuciones / árbol
  conservado). Entonces añade al final de `alt_core.c` las dos funciones con la
  misma semántica que `core.c` (guardadas en `CONFIG_RT_MUTEXES`, con un
  `lockdep_assert` propio). No afecta a MuQSS (no compila `alt_core.c`) ni a
  kernels que no tengan esos hooks.
- Se invoca tras registrar cualquier parche aplicado, cubriendo tanto el flujo
  normal como el de "árbol conservado ya parcheado" (`patch_markers_hit`).
- Selftest: extracción + casos funcionales del fixup (añade, idempotente, no-op
  sin hooks, no-op sin `alt_core.c`). 121→125 OK.

## [27.31.8] - 2026-09-24

Primera build clang real (tras el fix de v27.31.7) rompía en `build()` con
`llvm-ar: orden no encontrada`: con `LLVM=1`, Kbuild usa `llvm-ar` en lugar de
`ar` para archivar objetos, y `check_prerequisites` solo exigía `clang` + `ld.lld`.

- `check_prerequisites` ahora exige la **toolchain LLVM completa** cuando
  `CC_FAMILY=clang`: `ld.lld` + `llvm-ar` + `llvm-nm` + `llvm-objcopy` +
  `llvm-strip` + `llvm-objdump` + `llvm-readelf` (y clang si el launcher es
  genérico). `TOOL_PKG` mapea toda la familia `llvm-*` al paquete `llvm`, así que
  la falta entra por el flujo estándar `sudo pacman -S --needed ... llvm`, igual
  que el resto de dependencias (sin degradar ni abortar a mano).
- Selftest: guardas para la familia clang (`tools+=(ld.lld llvm-ar ... llvm-readelf)`)
  y los mapeos `[llvm-*]=llvm` en TOOL_PKG. 121/121 OK.

## [27.31.7] - 2026-09-24

Al compilar con clang (`LLVM=1`), las fases de preparación de config
(`listnewconfig`/`olddefconfig`/`localmodconfig`) corrían con el compilador por
defecto (gcc), así que los símbolos que solo existen con `CC_IS_CLANG` (p. ej.
`AUTOFDO_CLANG`, "Enable Clang's AutoFDO build") quedaban **fuera de `.config`**.
Entonces el build real con `LLVM=1` re-ejecutaba `conf --syncconfig`, los veía
como `(NEW)` y **preguntaba interactivamente** ("Restart config...") colgando la
compilación esperando respuesta en una terminal no supervisada.

- Nuevo array `KCONFIG_CC_OPTS`: se construye justo tras resolver el compilador y
  lleva `LLVM=1` cuando `CC_FAMILY=clang` (y `CC/HOSTCC` si el launcher es un
  binario/ruta concreta). Se inyecta en TODAS las fases de preparación de config:
  `run_kconfig_audit` (`listnewconfig` + `olddefconfig`), `prepare_lite_config`
  (su `olddefconfig` final) y `apply_patch_and_recheck`. La preparación ya ve el
  mismo compilador que la build → los símbolos clang quedan fijados con su default
  y `syncconfig` no tiene nada que preguntar.
- Selftest: nueva sección "KCONFIG_CC_OPTS" (declaración del array, rama LLVM=1
  para clang, y presencia en audit/lite/recheck). 119/119 OK.

## [27.31.6] - 2026-09-24

Al compilar un kernel del fork CachyOS con scheduler alternativo (bmq/pds/lfbmq,
`SCHED_ALT=y`), los símbolos CFS que `init/Kconfig` hace dependientes de
`!SCHED_ALT` (PSI, PSI_DEFAULT_DISABLED, NUMA_BALANCING, SCHED_CACHE y
SCHED_AUTOGROUP) son **imposibles** de habilitar: `olddefconfig` los deja fuera y
la validación del perfil los bloqueaba con FATAL aunque el usuario no los hubiera
pedido mal.

- Nuevo mecanismo `PATCH_RETIRED_SYMBOLS`: cada descriptor de scheduler declara
  qué símbolos retira (`_patch_desc_scheduler_base`; bmq/pds/lfbmq). Al
  registrarse el parche, `apply_patch_register` los acumula en `PATCH_RETIRED_ALL`
  y `build_effective_arrays` los elimina de EFF_ENABLE/EFF_CRITICAL/EFF_SETVAL/
  EFF_SETSTR (incluidos SEEN y EXPECTED_REBEL_SET), de modo que la validación deja
  de exigirlos y pasa a informarlos como "retirados por el scheduler alternativo".
- El perfil `cizen-optiplex7050` (que exige PSI=y, PSI_DEFAULT_DISABLED=n y
  SCHED_AUTOGROUP) ya no rompe el build de 7.2.7+bmq/clang con los 3 fallos FATAL
  de config; ahora son un aviso informativo.
- Bash-ism robusto: la reconstrucción de arrays usa `local` correcto y no deja
  referencias a variables del bucle; `bash -n` y selftest 112/112 OK.
- Fix: el reporte informativo de retirados usaba `${#PATCH_RETIRED_ALL[@]:-0}`, que
  es bad substitution de bash (no válido con `${#arr[@]}`; `:-0` no aplica). El
  run real de la opción 14 (bmq/clang) abortó ahí tras pasar toda la validación
  (VALIDACIÓN 38/38… SETSTR 2/2). Corregido a `${#PATCH_RETIRED_ALL[@]}` con la
  guarda `-gt 0`; se añadió al harness un test que detecta el patrón
  `${#arr[@]:-...}` en el motor. Selftest 113/113 OK (repo e instalado).

## [27.31.5] - 2026-09-24

Compila los kernels del fork CachyOS con su scheduler PRJC (bmq/pds) incluso cuando
el forward-port `master/7.2` de CachyOS/kernel-patches ya no aplica limpio sobre la
release publicada (p. ej. `cachyos-7.2.7-1`, que refactorizó `fair.c`/`exit.c`/`Kconfig.preempt`).

- Nuevo fallback intermedio en `apply_patch_plugin`: si el main upstream no aplica,
  se intenta un **forward-port incrustado en el motor** (`PATCH_EMBED_B64`): blob
  base64 (de un `.gz`) del `0001-prjc-cachy.patch` regenerado contra el árbol real
  del fork. Se decodifica, se valida por marcador + `patch --dry-run` y, si vale, se
  usa en vez de degradar a vanilla. Si tampoco aplica, se sigue con el upstream.
- `source_tree_kind()` detecta el tipo del árbol conservado (`cachyos` si existe
  `kernel/sched/poc_selector.c`, si no `vanilla`); `extract_tarball()` reutiliza el
  árbol SÓLO si coincide el tipo con `KERNEL_TREE` (fix del bug de reutilizar el
  árbol vanilla stale aunque `make kernelversion` diera la misma versión).
- El blob embebido es el parche forward-port validado por compilación: en 7.2.7-1
  `kernel/` y `kernel/sched/` compilan con `CONFIG_SCHED_ALT=y + CONFIG_SCHED_BMQ=y`
  (smoke build real). Solo los descriptores bmq/pds llevan embed (lfbmq/muqss usan
  MAIN file propio).

## [27.31.4] - 2026-09-24

Arreglado un cuelgue del motor al resolver el release del fork CachyOS (elección
de un scheduler PRJC/MuQSS o `--tree cachyos` con la versión ya instalada).

- El probe de `resolve_cachyos_release` (JSON de releases de la API de GitHub y
  sondeo de `.asc`) usaba `download_file`, que con aria2c lanzaba `--split=4` +
  `--max-tries=5` contra `api.github.com`; la API no atiende descargas parciales
  fiables y terminaba con "Size mismatch" y reintentos eternos (el archivo se
  descendía entero pero aria2c no salía). Se añade `download_small_file()`
  (curl con `--connect-timeout 15 --max-time 45`, o wget) de UN solo hilo,
  usado por el probe de releases y el sondeo `.asc`.
- La API se consulta con `per_page=20` en vez de 100: payload ~330KB (12s)
  frente a ~2MB a <100KB/s que agotaba el timeout.

## [27.31.3] - 2026-09-24

Arreglado un aborto del motor al resolver el árbol de fuentes del fork CachyOS.

- `resolve_kernel_tree()` terminaba con `[ "$KERNEL_TREE" = "auto" ] && KERNEL_TREE="vanilla"`: al resolver `auto → cachyos` (scheduler bmq/pds/lfbmq/muqss) ese test devolvía 1 y, bajo `set -Eeuo pipefail` + trap ERR, la llamada desnuda en la línea 5451 abortaba la operación ("Error 1 en línea 5451") antes de descargar nada. Sustituido por un `if` que no propaga el estado de salida 1.
- El árbol `cachyos` se resuelve y continúa el flujo normalmente.
- Selftest: añadido test de regresión (resolve bajo `set -e`) → es el motivo por el que el harness anterior no lo cazaba (usaba `set -u` sin `-e`).

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
