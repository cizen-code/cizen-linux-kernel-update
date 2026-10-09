## [27.35.9] - 2026-10-08

**Perfil `cizen-optiplex7050` v5.26.1 → v5.27.0: optimizaciones #3, #5, #6 y #7
de la lista priorizada (RCU offload, micro-podas, zram LZ4, imagen LZ4). Sin
cambios de código en el motor; el único cambio de suite es el selftest.**

Validado antes de tocar nada con `kconfig-validate.sh`/`validar.sh` sobre el
árbol Kconfig real **linux-7.2.9**: base `linux-7.2.8-cizen-v3.config`. Resultado
del perfil v5.27.0: **ENABLE 53/53, CRITICAL 13/13, DISABLE 599/601 (2 rebeldes
esperados: `MODULE_DEBUGFS`, `SCHED_SMT`), SETVAL 29, 0 FATALES**. Valores
comprobados en el `.config` generado: `RCU_NOCB_CPU=y`,
`RCU_NOCB_CPU_DEFAULT_ALL=y`, `NR_CPUS=4`, `SLUB_DEBUG=n`, `PSI=n`,
`X86_KERNEL_IBT=n`, `KERNEL_LZ4=y`/`KERNEL_ZSTD=n`,
`ZRAM_BACKEND_LZ4=y`/`ZRAM_BACKEND_ZSTD=n`.

- **#3 RCU offload (Fase 3 §69.4).** `RCU_NOCB_CPU` sale de `OPTS_DISABLE` y pasa
  a `OPTS_ENABLE`; se activa `RCU_NOCB_CPU_DEFAULT_ALL` para offloadear los 4
  CPUs **sin tocar `/etc/kernel/cmdline`** (el motor no genera cmdline). `RCU_LAZY`
  se mantiene en `OPTS_DISABLE`: con NOCB ya es un símbolo vivo y se quiere fuera
  por latencia. Efecto: `call_rcu()`/`kfree_rcu()` dejan de correr en softirq de
  los 4 cores y pasan a kthreads `rcuo/N`. **Pendiente de validar en arranque**
  (hilos `rcuo/*`, `/proc/softirqs`) tras el primer reboot del build.
- **#5 micro-podas.** `NR_CPUS` 8 → **4** (el i5-7500 es 4C/4T; el margen de 8 no
  lo usaba nada). `SLUB_DEBUG` a `OPTS_DISABLE` (queda `/sys/kernel/slab` pero sin
  validación); al caer, `STACKDEPOT` pierde su selector y sale de
  `EXPECTED_REBELS`. `PSI` a `OPTS_DISABLE` (systemd-oomd inactive; sin `psi=`),
  retirando `PSI`/`PSI_DEFAULT_DISABLED` de `OPTS_SETVAL`. `X86_KERNEL_IBT` a
  `OPTS_DISABLE` (inerte en Kaby Lake sin CET; cae `X86_CET`, `OBJTOOL` sigue por
  `STACK_VALIDATION`).
- **#6 zram zstd → lz4.** `ZRAM_BACKEND_LZ4` vuelve a `OPTS_ENABLE` y
  `ZRAM_BACKEND_ZSTD` pasa a `OPTS_DISABLE`. Runtime aparte (fuera del repo):
  `/etc/systemd/zram-generator.conf` pasa a `compression-algorithm = lz4`;
  **efectivo solo en el primer arranque con el kernel nuevo** (el kernel en
  marcha aún no lleva el backend LZ4).
- **#7 arranque.** `KERNEL_LZ4` a `OPTS_ENABLE` y `KERNEL_ZSTD` a `OPTS_DISABLE`
  (choice de `init/Kconfig`, `HAVE_KERNEL_LZ4=y` en x86_64). Imagen algo mayor,
  descompresión más rápida; **A/B de boot-time pendiente (§47)**.

Override consciente de §0.4 ("intocables ZRAM/ZSTD, …") y del comentario v5 del
perfil ("NO se fuerzan fuera RCU, PSI, …"): decisión explícita del usuario en la
lista priorizada de 2026-10-08. `SCRIPT_VERSION` 27.35.8 → **27.35.9** y cabecera.
Selftest: bloque nuevo con los invariantes de v5.27.0.

## [27.35.8] - 2026-10-08

**ccache: `hash_dir=false` + `sloppiness=file_stat_matches`** para mejorar
estabilidad y ratio de acierto con compilaciones en paths temporales/variantes
del kernel (kernel-update.sh). Sin cambios funcionales en el motor.

El «usado» de `free` (procps 4.0.7) es `total − MemAvailable`, así que el salto
de 2613 MiB (30-sep) a 4680 MiB (8-oct) en el mismo punto de arranque **tenía
que estar en `MemAvailable`**, y estaba: el uso real no-caché no se movió
(2028 → **1982 MiB**). `si_mem_available()` (`mm/show_mem.c`) descuenta
`totalreserve = Σ(high_wmark + lowmem_reserve)` y con `scale=500` el `zoneinfo`
daba **Σhigh=1743 MiB** y **Σlow=915 MiB** (antes: 48732 y 32620 kB). La cuenta
cerró con 5 MB de error: **11333524 kB** predichos contra **11328500** medidos.

Los dos sysctls siguen comentados en su fuente con las cifras, la fórmula y el
rollback, y hay paridad de tres vías (`repo == /usr/local/bin/kernel-update
== /etc/sysctl.d`). El kernel arranca en defaults: `scale=10` y `min_free=16384`
(recalculado por `calculate_min_free_kbytes()` en cada boot). O-5 de §67.5 queda
cerrada sin medir.

`scripts/verify-installed.sh` tampoco verificaba nada: comparaba el repo contra
su propio manifest (autocomprobación) y el generador salía **corrompido** —
`awk "{…substr("$f")…}"` expandía `$f` como campo de awk, no como shell, así que
salían paths vacíos y colas de `.git/objects` (993 líneas, 949 de ellas objetos
git). Ahora: paths relativos reales, excluidos `.git` y `*.bak*` (el motor los
regenera al editar un perfil), regeneración automática del manifest si está
desfasado, y **comparación contra la suite instalada** entrada por entrada
(`kernel-update/*` + `cizen-uki-sync`), con `FALTA`/`DIFIERE` y rc=2. Mismas
exclusiones en `install.sh`. Además faltaba `/usr/local/bin/cizen-uki-sync`
(el verificador abortaba antes de llegar a la paridad).

Estado: `make verify` → **Paridad OK (23 ficheros + cizen-uki-sync)**, `make
test` → **694 ok / 0 fail**, `bash -n` y ShellCheck limpios. Commits `457e89d`
(runtime) y `9598cc7` (scripts).

`SCRIPT_VERSION` 27.35.7 → **27.35.8** (ccache: `hash_dir=false` + `sloppiness=file_stat_matches`; cambios en `kernel-update.sh`. Motor estable.) y cabecera.

## [27.35.7] - 2026-10-07

**Dos FAIL falsos en el selftest: el parser de arrays no recortaba el comentario
final de línea; y en `/usr/local` el selftest y el CHANGELOG seguían en la
versión del 3-oct.**

Los dos FAIL venían del mismo sitio y **ninguno era un problema del perfil**. La
suite lee `OPTS_ENABLE`/`OPTS_DISABLE` con `awk` para comprobar dos invariantes
(duplicados dentro de un bloque, y que ningún símbolo esté en los dos), y ese
`awk` saltaba solo las líneas que **empiezan** por `#`: un comentario al final de
una línea de array se tragaba entero y sus palabras contaban como símbolos.
Resultado:

- `"SCHED_SMT"  # … select SCHED_SMT if SMP (arch/x86/Kconfig:335).` → la
  palabra `SCHED_SMT` se contaba **dos veces** → «símbolos repetidos en
  OPTS_DISABLE: SCHED_SMT».
- `"DEFAULT_FQ"  # … lo ancla en runtime también.` (ENABLE) y ese mismo
  comentario de SCHED_SMT (DISABLE) aportaban `#` y `en` a los dos bloques →
  «a la vez en ENABLE y DISABLE: # en».

El perfil está limpio: hay **una sola** entrada de `SCHED_SMT` en DISABLE y
ningún símbolo real en los dos bloques. bash, que es quien reparte el literal de
array de verdad, trata ese `#` como comentario, así que el parser del test era
el único que lo veía. Arreglo: `sub(/[[:space:]]+#.*$/,"",$0)` dentro de los
tres `awk`, antes de partir por campos.

**Y el despliegue estaba desfasado**: `kernel-update/tests/selftest.sh` y
`CHANGELOG.md` en `/usr/local/bin/kernel-update/` eran los del **3-oct**
(mtime 2026-10-03, CHANGELOG parado en 27.35.3), pese a que 27.35.6 anotó
paridad: lo que se sincronizó entonces fue el motor, no `tests/`. Por eso la
suite instalada corría sin el bloque `snap` de 27.35.6 (4 tests) y ejecutaba el
parser viejo. Ahora los tres ficheros tocados tienen paridad sha256 repo ==
`/usr/local`.

Estado: **694 ok / 0 fail** contra el repo y **693 ok / 0 fail** contra el
instalado (la diferencia es el test de coherencia repo↔instalado, que solo
existe al correr desde el repo, igual que en [27.31.52]), `bash -n` limpio y
**0 hallazgos de nivel error en ShellCheck**.

`SCRIPT_VERSION` 27.35.6 → **27.35.7** (cambios en `tests/`; el motor no cambia
de comportamiento) y cabecera.

## [27.35.6] - 2026-10-06

**El snapshot btrfs previo a cada build se ha perdido SIEMPRE en esta máquina:
`mount` recibía `/dev/sda2[/@]`. Detectado en el build de 7.2.9 (6-oct).**

El build imprimió `⚠ No se pudo montar el btrfs top-level; snapshot omitido.` y
tenía toda la pinta de un tropiezo transitorio (ese mismo día el tmpfs del build
se me quedaba ocupado y tuve que desmontarlo a mano). No lo era: `findmnt -n -o
SOURCE /` en btrfs devuelve el dispositivo **con el subvolumen entre corchetes** —
`/dev/sda2[/@]` — y `create_btrfs_snapshot` se lo pasaba a `mount` tal cual, que
buscaba un bloque llamado literalmente así:

```
mount: el dispositivo especial /dev/sda2[/@] no existe.   (rc 32)
```

Con el trozo limpio (`/dev/sda2`) el mismo montaje devuelve 0, así que la función
entera estaba bien: solo faltaba trinar la llave.

La consecuencia lleva desde **v27.23.0**, cuando entró la función. Montando el
top-level a mano, **`<top>/.snapshots` —el directorio que la función crea— ni
siquiera existe**, y no hay ni un `@kernel-*` en todo el top-level: el `mkdir -p`
de cada build corrió siempre contra un montaje que nunca estuvo ahí. (Cuidado con
la evidencia fácil: `/.snapshots`, vacío desde el 20 de septiembre, es
`<top>/@/.snapshots`, y en el top-level hay además un `@snapshots` de snapper del
mismo día; ninguno de los dos es el suyo, y los tres se parecen.) Una red de
seguridad que no cubrió nada jamás, con un `warn` que parecía del montaje y era
del parsing. El rollback que sí funcionaba era el otro (el `tar.xz` de
`rollback/`), y por eso el aviso costó: anunciaba algo cuya ausencia no molestaba
a nadie.

Arreglo: `topdev="${topdev%%\[*}"` justo después de leer SOURCE (si SOURCE no
lleva corchete, no se toca nada). El resto de la función ya estaba: los avisos de
`mkdir` y de `btrfs subvolume snapshot` siguen ahí para el fallo de verdad.

4 tests nuevos (bloque `snap`) que ejecutan `create_btrfs_snapshot` con
`findmnt`, `mount`, `btrfs`, `mktemp` y `sudo` stubbeados: el montaje tiene que
llegar con `/dev/sda2` limpio y el snapshot tiene que crearse; además se prueba la
misma función **sin** el recorte, que tiene que volver a fallar con rc 32, para
que el test no deje de cubrir nada si alguien lo quita. **694 ok / 0 fail**
(el selftest por defecto corre contra el motor instalado, así que primero se
despliega y luego se cuentan).

`SCRIPT_VERSION` 27.35.3 → **27.35.6** (las dos entradas anteriores, [27.35.4] y
[27.35.5], no tocaban código del motor) y cabecera, que seguía en v27.34.0.

## [27.35.5] - 2026-10-06

**Perfil `cizen-optiplex7050` v5.21.0 → v5.22.0: las optimizaciones RT-Lite
(P0 + P1 + P2 + runtime) preparadas de punta a punta, con los tres rebeldes
medidos contra el Kconfig de 7.2.9 y la cmdline al Nivel 2.**

Sin cambios de código en el motor: todo lo que sigue es perfil, runtime y
`/etc/kernel/cmdline`.

### El gate se corrió antes de tocar nada

`config` del kernel en marcha (`/proc/config.gz`): **P0, P1 y P2 todos
APLICAN** — `MAXSMP=y` con `NR_CPUS=8192` y los 6 símbolos debug `=y`; en P1
los 16 símbolos `=y` y el estado runtime limpio (sin `kexec_load`, sin
`crashkernel`, `auditd` inactivo, sin `CONFIG_BSD_PROCESS_ACCT`, arranque sin
`security=`, `/etc/udev/rules.d` vacío); `RT_GROUP_SCHED` ni siquiera existe en
este Kconfig.

### Cambios en el perfil

| Array | v5.21.0 | v5.22.0 |
|---|---|---|
| `OPTS_DISABLE` | 340 | **368** (+28) |
| `OPTS_ENABLE` | 38 | **45** (+7 anclas) |
| `OPTS_SETVAL` | 29 | **30** (`NR_CPUS=8`) |
| `CRITICAL_OPTS` | 14 | **13** (`SCHED_AUTOGROUP` fuera) |

`SCHED_AUTOGROUP` sale de `CRITICAL_OPTS` y pasa a `OPTS_DISABLE`: dejarlo como
crítico haría que `validate_config` lo reportara insatisfecho en cada build, ya
que la Fase 4 lo poda.

`NR_CPUS=8` sobrevive porque `apply_config_requests` (`kernel-update.sh:2116`)
manda **todos los `--disable` antes que los `--set-val`**: al revés,
`olddefconfig` repondría 8192.

### Los tres rebeldes se midieron, no se supusieron

El primer `--check` devolvió **374/377 desactivaciones resueltas** y exactamente
tres sin resolver, los tres candidatos que el procedimiento anticipaba:

| Símbolo | Por qué Kconfig lo devuelve a `=y` |
|---|---|
| `MODULE_DEBUGFS` | `bool` sin prompt (`kernel/module/Kconfig:26`); lo levanta `select MODULE_DEBUGFS` de `MODULE_UNLOAD_TAINT_TRACKING` (`Kconfig:153`, `=y` aquí) |
| `STACKDEPOT` | `bool` sin prompt (`lib/Kconfig:560`, y encima hace `select STACKTRACE`); lo levanta `SLUB_DEBUG` (`=y`) en `mm/Kconfig.debug:52` |
| `SCHED_SMT` | `select SCHED_SMT if SMP` en `arch/x86/Kconfig:335` con `SMP=y`; el caso «infraestructura x86 SMP» que el procedimiento preveía |

Siguen en `OPTS_DISABLE` (se pidió podarlos) y se añaden a `EXPECTED_REBELS` con
la razón escrita: la validación pasa de «3 sin resolver» a **«3 rebeldes
esperados»**. No se fuerzan con `--force`. Recordatorio de v5.21.0: un símbolo
solo en `EXPECTED_REBELS` y **fuera de `OPTS_DISABLE`** no lo mira nadie.

### Runtime

- **Nuevo `runtime/sysctl.d/99-cizen-rt-lite.conf`**: `dirty_background_bytes`
  16 MiB, `dirty_bytes` 64 MiB, `dirty_writeback/expire` 500/1500,
  `compaction_proactiveness=0`, `min_free_kbytes=131072`,
  `sched_rt_runtime_us=-1`, `perf_cpu_time_max_percent=1`, `netdev_budget`
  128/4000, `tcp_congestion_control=bbr`, `default_qdisc=fq` (`/etc` manda sobre
  el `fq_codel` de `/usr/lib/sysctl.d/50-default.conf`).
  `kernel.sched_migration_cost_ns` **no existe aquí**: el scheduler es BORE, así
  que se omite en vez de dejar un sysctl muerto.
- `99-cizen-memory.conf`: fuera `dirty_ratio` y `dirty_background_ratio`
  (los sustituyen los bytes); los valores medidos (`swappiness=10`,
  `watermark_boost_factor=0`, `vfs_cache_pressure=100`) se quedan intactos.
- `99-cizen-sata-ssd.rules` reescrito: `mq-deadline` anclado, `nr_requests=32`,
  `read_ahead_kb=128`, `add_random=0` y **sin `rotational=0`** — esa línea
  habría hecho que el sistema mintiera sobre el USB rotacional (§57).

El motor sobrescribe `/etc/sysctl.d/99-cizen-*` y `/etc/udev/rules.d/*` en cada
build: **la fuente es el repo**, y `runtime_tuning_pairs()` globula estos
directorios así que los ficheros nuevos se despliegan solos.

### Cmdline Nivel 2

`/etc/kernel/cmdline` → `preempt=full threadirqs
transparent_hugepage=madvise nmi_watchdog=0`, conservando raíces, subvol,
`intel_idle.max_cstate=4` y las mitigaciones apagadas. Respaldo
`cmdline.bak-20261006-150336`. **Conflicto abierto**: v27.32.0 migró
`preempt=full` → `lazy` porque `full` es el modo más caro y cede spinlocks
contended (peor para KVM), y la §53.5 pasó de lazy a `none` para medir. El
cambio se eligió conscientemente y es reversible editando un campo.

### Verificación

Tres `--check`, todos limpios:

| Corrida | Flags | Resultado |
|---|---|---|
| ruta repo | `--no-btf` | 46/46 · 13/13 · **374/377 (3 rebeldes)** · 30/30 · 2/2 |
| ruta repo, tras `EXPECTED_REBELS` | `--no-btf` | 374/377 **(3 rebeldes esperados)** |
| **ruta instalada, flags reales del build** | `--no-btf --clang --patch bore --pgo …` | **48/48 · 13/13 · 368/371 · 30/30 · 2/2** |

Config promovida verificada antes de compilar: `NR_CPUS=8`, `MAXSMP` apagado,
`KEXEC/AUDIT/CRASH_DUMP/SCHED_AUTOGROUP/RT_GROUP_SCHED/REMOTEPROC/
PCSPKR_PLATFORM/X86_USER_SHADOW_STACK` apagados, `PREEMPT=y` +
`PREEMPT_DYNAMIC=y` + `IRQ_FORCED_THREADING=y` (sin esto, `preempt=full` y
`threadirqs` no sirven de nada), las 7 anclas `=y`, `SCHED_BORE=y`,
`AUTOFDO_CLANG=y` + `LTO_CLANG_THIN=y`, `KVM=m`, `XFS_FS=y`, sin BTF.

`kconfig-validate.sh` contra el Kconfig real: **sin FATALES** (45/45, 13/13,
365/368 con 3 rebeldes esperados, 30, 2). Dato nuevo: **75 de los `OPTS_DISABLE`
ya no existen** en el Kconfig de 7.2.9 — ruido heredado, no fallo, y candidato a
limpieza.

Arnés: **689 ok / 0 fail** (el motor no se toca).

### Despliegue

Perfil y runtime con **paridad sha256** en las tres rutas (repo,
`/usr/local/bin/kernel-update/`, `~/.config/kernel-update/profiles/`), motor
intacto (`e41afd1c…`), respaldos `.bak-20261006-*`. Se **borra**
`kernel-update/profiles/linux-7.2.9-cizen-v3.config` del repo: era un artefacto
sin seguimiento generado desde el repo, **sin `AUTOFDO_CLANG` ni `SCHED_BORE`**,
y esa misma semilla es lo que lee la siguiente build — una copia stale en el
sitio exacto de §62.

Pendiente de lanzar (sin TTY no compila: `confirm_build_after_check` devuelve 1
y sale con `CHECK EXITOSO` sin compilar):

```bash
cizen-build 7.2.9 --no-btf --clang --patch bore --pgo ~/kernel-pgo/7.2.8-cizen-v3.afdo
```

## [27.35.4] - 2026-10-03

**Perfil `cizen-optiplex7050` v5.20.0: XFS pasa de la poda a OBLIGATORIO. El
kernel no podía montar `/home`, que es XFS, y el motivo llevaba dos builds
escrito en el sitio equivocado.**

`/home` es XFS de verdad (`/dev/sda3`, `crc=1`, `realtime=none`) y este host
arranca por UKI verificado, **sin initramfs** que cargue `xfs.ko` a tiempo. Con
`XFS_FS` apagado el kernel no monta `/home`. Y estaba apagado porque v5.19.0
metió `XFS_FS` en el `OPTS_DISABLE` del Bloque C, como parte de la receta
"apago cuotas y XFS". O sea que **no era un fallo de Kconfig: era el perfil
apagándolo en cada build**, y por eso recompilar no lo arreglaba.

Dos intentos anteriores de arreglarlo no podían funcionar, y conviene dejarlos
escritos porque los dos son la misma clase de error:

1. `~/perfil-kernel-instalado.txt` **no es el perfil**: es una copia byte a byte
   de `profiles/linux-7.2.9-cizen-v3.config`, que es la **semilla de la
   siguiente build** (`choose_base_config` → `promote_base_config`), o sea un
   *resultado*. Editarla no cambia el kernel; el motor la regenera al final de
   cada build.
2. `~/kernel-update-fixed.sh` **no es el motor**: el motor es
   `/usr/local/bin/kernel-update/kernel-update.sh` (lo fija `KU=` en `.bashrc`).
   Los tres bloques "Fix XFS" que se le habían añadido además estaban en la
   rama `else` de `if [ "$CHECK_ONLY" = true ]`, o sea que solo se ejecutaban
   cuando se **declinaba** compilar.

Cambios: `XFS_FS` y `XFS_POSIX_ACL` a `OPTS_ENABLE`, `XFS_FS` a
`CRITICAL_OPTS`, y `XFS_FS` fuera de `OPTS_DISABLE`.

**`=y` y no `=m`**, y no por gusto: `XFS_POSIX_ACL` es `bool depends on XFS_FS`,
así que con XFS en módulo Kconfig lo degrada a `n`. `XFS_POSIX_ACL=y` y
`XFS_POSIX_ACL=m` son incompatibles.

### Lo que la medición contradijo: el resultado dependía de la BASE

Con el perfil puesto, el banco daba `CONFIG_QUOTACTL=y` como desactivación no
resuelta. La causa no era la que decía v5.19.0 (`XFS_FS` como raíz de
`QUOTACTL`): `fs/xfs/Kconfig:80` es el `select` de **`XFS_QUOTA`**, no de
`XFS_FS`. Y con la base de 7.2.9 promovida se apagaba, pero con
**`/proc/config.gz`** —el fallback de una build de versión nueva— no, porque ahí
`GFS2_FS=m` (`fs/gfs2/Kconfig:7`) y `OCFS2_FS` (`fs/ocfs2/Kconfig:8`) también
devuelven `QUOTA`/`QUOTACTL` a `=y`.

O sea que la receta de v5.19.0 ("los tres juntos o nada") era una lista de
**síntomas**, no de raíces, y solo cerraba con algunas bases. Como relajar una
optimización es más barato que ampliar una poda a dos filesystems que nadie
pidió podar, `QUOTA` y `QUOTACTL` **salen** de `OPTS_DISABLE` (y con ellos
`XFS_QUOTA`): `/home` va con `noquota` y no hay `quota` instalado, así que no hay
ningún efecto observable. Lo que sí se apaga es `TMPFS_QUOTA`, que es la raíz de
verdad y se apaga bien.

Lo mismo, un nivel más abajo: los sub-símbolos de XFS **dependían de la base**,
porque `olddefconfig` conserva el valor explícito que venga. Con `/proc/config.gz`
`XFS_SUPPORT_V4`, `XFS_SUPPORT_ASCII_CI`, `XFS_QUOTA` y `XFS_RT` salían `=y`, y
con las bases promovidas de Cizen salían `=n`: el mismo perfil daba dos kernels
distintos. Se fijan a `n`, cada uno por su motivo medido:

| Símbolo | Por qué `n` |
|---|---|
| `XFS_SUPPORT_V4` | `/home` es `crc=1` (V5). El formato V4 (`crc=0`) está deprecado desde 2025 y es superficie de ataque. |
| `XFS_SUPPORT_ASCII_CI` | Su propio `help` dice que activarlo hace a XFS vulnerable a ataques de sensibilidad a mayúsculas; `/home` va `ascii-ci=0`. |
| `XFS_RT` | `/home` va `realtime=none`. |
| `XFS_QUOTA` | Cuota que no se usa, y raíz que devuelve `QUOTACTL` a `=y`. |

No se tocan `XFS_ONLINE_SCRUB`, `XFS_ONLINE_REPAIR`, `XFS_DRAIN_INTENTS` ni
`XFS_LIVE_HOOKS`: salen `=y` por default y son los que hacen útiles `xfs_scrub` y
`xfs_repair` en caliente.

**Verificado contra las TRES bases** que puede usar una build —la promovida de
7.2.8, la promovida de 7.2.9 y `/proc/config.gz`— y con las tres sale lo mismo:
**37/37 ENABLE, 14/14 CRITICAL, 320/320 DISABLE, 0 sin resolver, 0 FATAL**, y un
bloque XFS idéntico. Medir contra una sola base es lo que dejó pasar el
`QUOTACTL`; §57.7 ya había reprobado eso mismo en los bancos.

Arnés: **684 ok / 5 fail**, y los 5 `fail` son del grupo `rollback` y son
**preexistentes**: se comprobó con una baseline con el perfil de `HEAD`
desplegado en las tres rutas, y sale exactamente lo mismo. Este cambio no añade
ninguna regresión. Los `rollback` quedan pendientes de mirar aparte.

## [27.35.3] - 2026-10-03

**El aviso de AppArmor de v27.35.1 solo salía el primer build. Estaba en el sitio
equivocado, y eso no se ve leyendo la condición.**

El build de 7.2.9 (3-oct) imprimió `3 fichero(s) ya estaban al día` y **no
imprimió el aviso**. La causa: estaba dentro del

```
elif [ "$cambios" -gt 0 ]; then
```

de `deploy_runtime_tuning`, así que solo se ejecutaba cuando algún fichero de
runtime cambiaba — que es el primer build y ningún otro. Es un aviso sobre el
**perfil del kernel** colgado de una condición sobre **ficheros de runtime** que
no tienen nada que ver: después del primer build se iba solo, que es la forma más
fácil de que un aviso deje de avisar.

v27.35.1 lo arregló por dentro (la pregunta era la correcta: el estado del perfil
en vez de un `grep -x` que nunca casaba) pero lo dejó dentro del `elif`. Por eso
§60.6 lo daba por verificado solo porque la condición ya no mentía, sin mirar
dónde estaba.

Ahora el aviso va **después** del `if/elif/fi`, así que se emite en todos los
builds. Verificado además que el perfil está cargado cuando
`deploy_runtime_tuning` corre (`load_profile` en el pipeline, línea 1616, muy
antes), que es lo que hace que `mac_desactivado` tenga respuesta en vez de callar
por prudencia.

1 test nuevo (5/5 del bloque `mac`) que exige que la llamada no esté dentro de la
rama de `$cambios`. **689 ok / 0 fail**.

## [27.35.2] - 2026-10-03

**La poda que acompañaba al backup del UKI borraba todos los backups, siempre,
y el log de cada build anunciaba que se habían respaldado. Detectado en el build
de 7.2.9.**

El build de 7.2.9 imprimió

```
✓ UKI previo respaldado en /var/lib/kernel-update/uki-backups/arch-linux-cizen-v3.efi.before-7.2.9-cizen-v3-20261003-174234
```

y `/var/lib/kernel-update/uki-backups/` está **vacío**. No falló la copia: la
poda que venía justo después en la misma función la borró.

Dos bugs apilados en `uki_backup_prev`:

1. El glob era `-name "$(basename "$f")*"`, y `basename` incluye el timestamp
   (`…efi.before-7.2.9-cizen-v3-20261003-174234`), así que el patrón **solo
   encontraba el propio fichero**. La lista de «los 8 más recientes» nunca
   llegaba a formarse.
2. Aun formándose, la decisión estaba **invertida**: `head -n -8` devuelve los
   más **antiguos**, y el código conservaba los que estaban en esa lista.

Con 8 backups o menos `head -n -8` no imprime nada, así que todo caía en la rama
de borrar. Comprobado con una simulación de la poda: con 1, con 2, con 8, con 9 y
con 10 backups, **sobran 0**. Es decir, la función nunca ha dejado una sola copia
viva, desde que existe.

Es la **segunda** vez que esta función falla (§56: `find_cizen_uki_targets` sin
argumento, `find -iname ""` no encuentra nada y el bucle no iteraba nunca). Las
dos veces el síntoma fue el mismo: el directorio quedaba creado y vacío detrás de
un mensaje de éxito. Por eso ahora la poda es una función aparte,
`uki_backup_prune()`, con `CIZEN_UKI_BACKUP_KEEP` (8 por defecto), testeable sin
montar nada: ordena por nombre —el timestamp `YYYYMMDD-HHMMSS` ordena
lexicográficamente igual que cronológicamente— y conserva los 8 últimos.

Lo que **no** se rompe: `~/kernel-pgo/ukis/auto/` (UKI de 7.2.9 archivado, 27 582 008 B)
y `/var/lib/kernel-update/rollback/7.2.8-cizen-v3.tar.xz` (62 MB) sí están. El
respaldo del que se lamentaba la poda sí funcionaba.

8 tests nuevos. El primero es el caso real —un backup recién creado no puede
evaporarse— y los demás cubren el tope de 8, que no se borre nada por debajo, que
sobreviva el **más reciente**, y que el glob malo no vuelva. **688 ok / 0 fail**.

## [27.35.1] - 2026-10-03

**El aviso de seguridad que decía «si instalas libvirt, sus perfiles AppArmor
quedarán inertes sin avisar» no se emitía nunca. Y no por culpa del aviso.**

Desde v27.34.0 el motor comprueba si AppArmor está apagado con

```
grep -qx 'SECURITY_APPARMOR' "$PROFILE_FILE"
```

y eso **no matchea jamás**. El perfil no lista `SECURITY_APPARMOR n`: lista
`"SECURITY_SELINUX" "SECURITY_APPARMOR" "SECURITY_SMACK" …`, los símbolos como
palabras entrecomilladas de un array repartidas en varias líneas, y `-x` exige
que la línea entera sea exactamente eso. El aviso llevaba una versión entera
sin decir nada, y el log parecía el de un despliegue que sí avisa.

Se sustituye por `mac_desactivado()`, que lee el array `OPTS_DISABLE` que el
motor ya tiene cargado en memoria. La diferencia de fondo no es el `grep`: es que
la pregunta correcta («¿este símbolo está apagado?») la responde el estado del
perfil, no una coincidencia de texto en un fichero cuyo formato no es el que el
grep daba por supuesto.

Si el perfil no está cargado, la función **no dice nada**. Un aviso que afirma
que AppArmor está apagado sin haberlo comprobado sería un aviso que puede
mentir, y un aviso que miente entrena a ignorarlo —que es exactamente el daño
que causaba el `grep`.

4 tests nuevos, uno de ellos el bug original por si vuelve a colarse un grep:
**679 ok / 0 fail**.

## [27.35.0] - 2026-10-03

**`pgo-collect.sh --merge`: fusionar varias capturas de PGO en un perfil, sin
root y sin volver a muestrear. Y por qué la vía obvia no funciona.**

Un perfil de 15 min de escritorio solo optimiza lo que el escritorio hizo.
Fusionar varias sesiones reduce ese sesgo, así que el modo toma N capturas
`.perf.data` ya existentes y produce un único `.afdo`.

**No se fusionan los `.perf.data` en binario, y no es por elección:** en LLVM
23.1.1 `llvm-profgen --perfdata A --perfdata B` se queda con el **último** y
descarta el resto sin decir nada. Se comprobó con un fichero inexistente en
primera posición: si fuera fusión se quejaría de él, y no dice nada. Un script
que pasara las capturas así anunciaría un perfil «fusionado» hecho de la última
sesión, que es justo el sesgo que se vino a quitar. `perf merge` tampoco existe
en perf 7.2.8, y `--perfscript` aborta con «Invalid perf script input!» porque
su parser (`PerfReader.cpp`, `checkPerfScriptType`) no entiende el texto de
`perf script`.

La vía que sí funciona es la del propio llvm-profgen: descomponer cada captura
a texto sin simbolizar (`--skip-symbolization`), concatenar los textos y
simbolizar una sola vez (`--unsymbolized-profile`). El formato intermedio es
una lista plana sin cabecera, así que concatenar es una suma exacta.

Verificado de punta a punta con un banco propio (programa con DWARF, dos
capturas LBR): 50 + 50 muestras, 2576 bytes = la suma exacta de las partes, y
la densidad del perfil pasa de **1,7 a 5,8** mientras el aviso de muestras
insuficientes baja de 29,4x a 8,6x.

Tres fallos que la fusión tenía que hacer ruidosos, porque todos producen un
perfil con **apariencia** de fusionado:

- Una captura sin eventos SAMPLE **aborta**: si no, el perfil saldría de las
  demás sesiones y se presentaría como completo.
- Una captura que se descompone vacía (llvm-profgen escribe `0\n0\n`) aborta
  igual, en vez de aportar cero muestras sin decirlo.
- El texto concatenado se compara con la **suma de bytes de las partes**. Si no
  cuadra, aborta.

Y `--merge` **no se eleva a root**: solo lee ficheros y llama a llvm-profgen.
Elevar askiría contraseña para nada, y el `exec sudo` con `env_reset` de Arch
perdería el array de capturas por el camino — otro perfil de una sola sesión,
esta vez sin avisar.

9 tests nuevos. Uno comprueba que `--perfdata` no aparece dos veces en una misma
línea de código (el grep filtra los comentarios, porque el que documenta la
trampa escribe `--perfdata A --perfdata B` a propósito). Arnés: **674 ok /
0 fail** en el repo, **673 ok / 0 fail** instalado.

**Lo que NO está verificado, y no se da por bueno**: la vuelta completa con una
captura real de kernel. El banco de §27.35.0 usa un binario de espacio de usuario
con DWARF, que valida el algoritmo (la descomposición, la concatenación, la
suma exacta de bytes y la densidad) pero no el `--kernel`, que es cosa de
llvm-profgen. La captura real de 484 MB de §50 y el `vmlinux` con símbolos que
haría falta ya **no están en disco**, y rehacerlos pide `perf record -a`, que
necesita root y no está en el allowlist. Con lo que hay, `--merge` sobre capturas
de kernel no se ha probado de punta a punta: se ha probado la fusión, y se ha
comprobado que `--kernel` se pasa y que llvm-profgen rechaza entradas que no son
de kernel («Kernel is requested, but no kernel is found in mmap events»).

## [27.34.0] - 2026-10-03

**El §7 del documento de optimización no tenía ninguna forma de llegar al
rootfs: `sysctl.d` y las reglas udev había que copiarlos a mano. Nuevo paso
`deploy_runtime_tuning()` en el pipeline. Y el perfil `cizen-optiplex7050`
pasa a v5.19.0 con 14 símbolos del documento verificados uno a uno contra el
Kconfig real de 7.2.9.**

`~/Descargas/Optimizacion-kernel.txt` (v5.19.0) pedía 65 símbolos de Kconfig y
14 claves de runtime. Verificados contra el Kconfig real —árbol de 7.2.9 de
cdn.kernel.org, `sha256 b4c5dfbe…d8d8ba`, verificado contra `sha256sums.asc`,
con `scripts/config` + `make olddefconfig`—, **solo 14 son necesarios**:

- **Bloque A**: `SUSPEND`, `HIBERNATION`. Los tres bloques juntos apagan 57
  símbolos fuera de sus listas (ver "la cascada no es «11 símbolos»" más
  abajo). Se pierden
  `systemctl suspend` y `systemctl hibernate`; en un sobremesa sin tapa ni
  batería el coste es nulo.
- **Bloque B**: `SECURITY_SELINUX`, `SECURITY_APPARMOR`, `SECURITY_SMACK`,
  `SECURITY_TOMOYO`, `SECURITY_LOADPIN`, `SECURITY_LOCKDOWN_LSM`,
  `SECURITY_SAFESETID`, `INTEGRITY`. Sin nada en uso hoy (`/etc/apparmor.d`
  vacío, sin `security=` en el cmdline, lockdown `[none]`, IMA/EVM ya
  apagados). **Riesgo anotado**: si se instala libvirt con sus perfiles
  AppArmor, quedarán inertes sin avisar, y este host virtualiza KVM. La firma
  de módulos no se rompe: `MODULE_SIG_KEY="certs/signing_key.pem"` es la clave
  embebida de la build, no la db de UEFI.
- **Bloque C**: `TMPFS_QUOTA`, `XFS_FS`, `QUOTA`, `QUOTACTL`.
- **Bloque D**: nada. Los 18 ya estaban apagados o no existen.
- **No existen en 7.2.9**: `SYSV_FS`, `REISERFS_FS`, `IP_DCCP`, `CAIF`,
  `ISDN`, `HAMRADIO`, `IRDA`.
- **`AUTOFS_FS` NO se desactiva**, aunque el documento lo pida: systemd monta
  `/proc/sys/fs/binfmt_misc` con automount y ahí está el handler `DOSWin` de
  `/usr/lib/binfmt.d/wine.conf`; sin él, un `.exe` deja de ejecutarse con un
  doble clic.
- **`QUOTA` no se apaga poniéndolo a `n`**: `TMPFS_QUOTA` (`fs/Kconfig:238`) y
  `XFS_FS` (`fs/xfs/Kconfig:80`) lo `select`ean, y `olddefconfig` conserva el
  `=y` viejo si no se retiran las raíces.
- **0 `EXPECTED_REBELS` nuevos**. Impacto sobre el `.config`: 46 símbolos `=y`
  → `n`, 0 módulos. Los MB y segundos que estima el documento **no se afirman**
  hasta que exista la build que los mida.

**Y los dos bancos que son la evidencia de todo eso, versionados**:
`kconfig-bench.sh` recorre los cuatro bloques del documento contra el Kconfig real
y separa los cinco casos en que puede estar un símbolo —no existe, ya estaba
apagado, se apaga en cascada, Kconfig lo rechaza, lo apagó el propio bloque—; y
`kconfig-validate.sh` replica `validate_config()` del motor, de modo que lo que
él cantaría en pleno build se ve en un minuto. Los 14 sale de ejecutarlos, no de
contarlos.

Dos cosas que solo aparecieron al publicar el banco y que cambian el relato:

- **El bloque C del documento está roto tal como está escrito.** `QUOTA` y
  `QUOTACTL` salen `Kconfig RECHAZA apagarla`, porque el documento lista los
  síntomas y no las raíces: no menciona `TMPFS_QUOTA`, que es lo que
  `select`ea `QUOTA` (`fs/Kconfig:238`). Por eso la receta final añade las dos
  raíces además de los dos síntomas.
- **La cascada no es «11 símbolos»**: los tres bloques apagan **57** símbolos que
  no estaban en sus listas, y eso lo cuenta el diff de los dos `.config`. La
  primera versión del banco Etiquetaba de «cascada» a los símbolos que el propio
  documento pedía apagar —`AUTOFS_FS` entre ellos—, que es justo lo contrario de
  una cascada.

Del §7 se aplican **3 claves de memoria y 2 de red**. Los tres sysctl que el
usuario tiene medidos (`vm.swappiness=10`, `vm.vfs_cache_pressure=100`,
`vm.watermark_boost_factor=0`) se respetan y se quedan en
`/etc/sysctl.d/99-optimizaciones.conf`; el nuevo fichero no solapa ni una
clave con él. De red, el documento **rebajaba** `net.ipv4.tcp_rmem` de 32 MiB
a 4 MiB, lo cual no es una mejora, y `core.rmem_max`/`wmem_max` ya estaban en
el valor pedido.

La regla udev del documento declaraba `ATTR{queue/rotational}="0"` a **todo**
`sd[a-z]`, con lo que el Kingston DataTraveler de `sdb` —que es
`rotational=1`— quedaba declarado no rotacional y el planificador habría
dejado de usar ascensores para el USB. Aquí ese atributo **no se escribe**: se
exige como condición, y con `ACTION=="add"` en vez de `"add|change"`.

**`deploy_runtime_tuning()`** despliega `runtime/{sysctl.d,udev}/` a `/etc`
comparando contenido (no reescribe lo que ya está bien), respalda lo anterior
**en `/var/lib/kernel-update/runtime-backups/<sello>/`** y nunca al lado del
original —systemd-sysctl se come todo `/etc/sysctl.d`, y un `*.conf.bak` con
una clave vieja puede abortar el arranque—, aplica en caliente con
`sudo -n sysctl -p` y `udevadm` y **da el comando copiable** cuando no están en
el allowlist NOPASSWD (en este host no lo están). Dispara
`udevadm trigger --subsystem-match=block` para que no espere a un reinicio.
**Nunca propaga error**: un sysctl que no carga no ensucia el veredicto de un
kernel bien compilado. `CIZEN_RUNTIME_TUNING=0` lo desactiva.

## [27.33.9] - 2026-10-03

**El UKI del ESP es `-rwx------ root`: una copia hecha con `sudo cp` al home del
usuario sale root 700, ilegible sin sudo e inútil justo para lo que se copia,
que es un rollback.**

Al preparar el build del kernel 7.2.9 se pidió respaldar la UKI antes de
reiniciar, porque con `CleanMethod=KeepCurrent` el paquete anterior no queda en la
pacman y no hay UKI de rollback en `/var/lib/kernel-update/uki-backups`. La copia
manual quedó `root root` y modo 700: el usuario no podía leerla. Y el backup que
la suite dice hacer desde v27.30.0 **no estaba haciendo nada**, por dos motivos
independientes.

- **`uki_backup_prev` nunca ha respaldado nada.** Se llamaba a
  `find_cizen_uki_targets` **sin argumento**, y `find -iname ""` no encuentra
  ningún fichero, así que el bucle no iteraba nunca. Los otros tres call sites sí
  pasan `$(cizen_uki_efi_name)`. Por eso `/var/lib/kernel-update/uki-backups`
  estaba creado y vacío: no es que el backup estuviera desactivado, es que la
  búsqueda no encontraba el UKI. Arreglado pasando el nombre. Y la copia cambia de
  `cp` a `install -m644`, pero **no por el allowlist**: `cp` sí está en él
  (`sudo -n -l` lo confirma, y §49 ya lo decía bien). Es por el modo — `cp` sin
  `-p` hereda el del origen, y el del UKI del ESP es 700.

Lo nuevo es `uki_archive_current`: archiva el UKI **nuevo**, ya firmado, en
`~/kernel-pgo/ukis/auto/`, legible y sin sudo, conservando los 2 más recientes
— la anterior y la actual, que es justo el par que hace falta para volver
atrás. Cada build deja una y podar a 2 mantiene siempre el par.

Tres decisiones que no son negociables:

- **Se copia con `install -m644` y se devuelve el dueño con `chown`.** Los dos
  están en el allowlist de §3. El modo importa tanto como el dueño: `cp` sin
  `-p` hereda el del origen, y el del UKI del ESP es 700 — que es exactamente el
  defecto que hizo inútil la copia manual. `install` lleva **sin** `-f`: el de
  GNU no acepta esa opción (es de BSD) y aborta con `opción inválida -- 'f'`. Un
  test cazó eso; en producción habría caído como un simple `warn` de "no se pudo
  archivar" que no dice nada del motivo.
- **La poda no sale del subdirectorio propio ni toca ficheros que no empiecen por
  `uki-`.** Un `rm *.efi` en `~/kernel-pgo/ukis/` se llevaría por delante la
  copia manual del usuario, que es justo lo que se quiere conservar.
- **La poda ordena por mtime, no por nombre.** La etiqueta lleva la versión y
  `7.2.10` ordenaría antes que `7.2.9` en texto, así que un `sort | head -n -N`
  podaría la copia equivocada.

La etiqueta incluye **pkgrel** (`uki-7.2.9-cizen-v3-1-…`), no solo `uname -r`:
dos builds distintos pueden llamarse igual (v27.33.7) y un rollback necesita
saber cuál es cuál. Y una copia cuyo tamaño no cuadre con el original se **borra**
en vez de archivarse: un backup truncado es peor que ninguno, porque además
esconde que no lo hay.

Se invoca solo si la sincronización fue bien —si falló, el ESP conserva el UKI
anterior y archivarlo como si fuera el de este build sería mentira—, antes de
`FULL_PIPELINE_OK` para que un fallo de archivado no ensucie el veredicto, y la
función nunca propaga error.

12 tests nuevos → **639 ok / 0 fail**. Verificado **por mutación**: cambiar el
`N` de reserva a 3 hace fallar el test del valor no numérico.

## [27.33.8] - 2026-10-03

**El motor se lanzaba con `sudo` y perdía el build entero —y la caché caliente—
sin que ninguna de las dos cosas se anunciara.**

El build de `7.2.9` se invocó como `sudo kernel-update.sh 7.2.9 --patch bore
--clang --no-btf --no-pgo`. Configuró, aplicó BORE y validó el perfil a la
perfección, y murió al empaquetar:

```
==> ERROR: Ejecutar makepkg como superusuario no está permitido ya que puede causar
    daños permanentes y catastróficos a su sistema.
make[2]: *** [scripts/Makefile.package:155: pacman-pkg] Error 10
```

Ese `makepkg` no es culpa del paquete que genera el motor: es el motor entero,
que **está pensado para correr como usuario** y se ha ejecutado así siempre. Los
tres puntos que necesitan privilegios los pide él solo, con su `sudo -v` del
preflight: montar el tmpfs (`sudo mount`), instalar el `.pkg`
(`sudo pacman -U`, línea 11838) y firmar la UKI con `sbctl`.

- **`make pacman-pkg` llama a `makepkg` sin más, y `makepkg` aborta con EUID==0.**
  No hay bandera para saltárselo. El aviso es además tardío: llega tras la
  configuración completa, así que el build se pierde entero y no queda paquete
  que instalar a mano.
- **Con `sudo`, `HOME` pasa a `/root`.** El log lo delata:
  `Cache/build: /root/.cache/kernel-kbuild` y
  `ccache activo: /root/.cache/ccache`. La caché caliente del usuario —9,1 GB,
  ~50% de aciertos— no se toca, y el build deja de ser incremental, que es
  exactamente el mecanismo que lo hace rápido.
- **El tmpfs queda con `uid=0`.** Montado sin `uid=`/`gid=`, el árbol fuente
  acaba en `root:root` y el usuario ya no puede escribir en él ni borrarlo, así
  que tampoco sirve para el siguiente intento: hay que desmontar.

El defecto de fondo era que el motor **no tenía ninguna guardia** contra esto.
Confiaba en que se invocara bien y por eso el fallo se descubre al final y en
el sitio más caro posible. Ahora aborta antes de `prepare_dirs`, con un mensaje
que explica las dos causas y no solo la primera.

La guarda va **después** del dispatch de los modos de mantenimiento
(`--selftest`, `--changelog`, `--hardened`), que no compilan y sí son válidos
como root, y **antes** de `prepare_dirs`, primer punto que comparten todos los
modos que acaban tocando `makepkg`. Además `Agente.md` §54.5 —la única sección
de la bitácora que usaba `sudo`, y justo la que nunca se ejecutó— queda
corregida; el alias `cizen-build` de `~/.bashrc` ya era correcto y se deja así.

Cinco tests nuevos, uno de ellos **ejecutando** la guarda con `id` y `fatal`
simulados para poder probar la rama `EUID==0` sin ser root.

## [27.33.7] - 2026-10-02

**Arrancar un kernel recién compilado no se anunciaba: la identidad del kernel
era su nombre, y la suite compila varios builds con el mismo nombre.**

El ciclo de PGO de la v27.33.6 arrancó `7.2.8_cizen_v3-13` y el verificador se
calló. No era que no corriera: corrió, dio 0 incidencias y, siendo el estado
idéntico al del arranque anterior, no había nada que notificar. El defecto está
una línea más abajo, en **qué se considera el mismo kernel**.

- **`uname -r` no distingue dos builds.** `_12` y `_13` son los dos
  `7.2.8-cizen-v3`; solo difieren en el pkgrel. Con el nombre como identidad,
  arrancar lo que acabas de compilar era indistinguible de reiniciar lo de
  antes: `FIRST_BOOT` no saltaba y la firma de estado no cambiaba.
- **El mecanismo ya existía y estaba escrito para esto.** El comentario de
  `verify_state_fingerprint` dice que el campo `ver=` está ahí para que "arrancar
  un kernel NUEVO con el MISMO número de incidencias" avise. Cumplía cuando el
  *nombre* cambiaba; no cuando cambiaba el build, que es el caso normal aquí,
  porque la suite bumpea pkgrel en cada compilación.
- **`running_pkgv()`**: el `pkgver-pkgrel` del build en marcha, resuelto en
  runtime por `pacman -Qo /usr/lib/modules/$(uname -r)` para no dar por supuesto
  el nombre del paquete (funciona igual para `linux-lts`). Sin pacman, o sin
  paquete que contenga el módulo, devuelve vacío sin fallar, y entonces no se
  inventa etiqueta ni identidad: es una máquina sin base de datos de paquetes,
  no un kernel distinto.
- **`first_boot_detected()`**: compara identidades, no nombres. Es una
  **función** y no tres líneas en el cuerpo precisamente para poder extraerla en
  el arnés: la primera versión estaba escrita en el cuerpo, y los tests que la
  cubrían la reimplementaban dentro del test, de modo que **pasaban contra el
  código viejo** — no medían el script, se medían a sí mismos. Corregido, y
  añadido un guard que falla si alguna de las tres funciones no existe, porque
  un `if fn; then ok else ok fi` pasa en verde contra un fichero donde la
  función no está.
- **La identidad se guarda SIN espacios, y esto no es cosmético.**
  `verify-last`/`verify-history` son líneas delimitadas por espacios. Una
  identidad con un espacio dentro (`"<uname -r> <pkgver-pkgrel>"`, que fue la
  primera versión) añade un campo de más: `read` lee 10 campos donde esperaba 9
  y el del build queda **vacío**. La primera implementación fallaba exactamente
  al probarla de punta a punta, con la suite entera en verde, porque los tests le
  pasaban la identidad por la línea de comandos sin pasar por el formato. De ahí
  que la función devuelva solo el `pkgver-pkgrel`, y de ahí el test que falla si
  el valor lleva un espacio. **Un test que esquiva el formato no prueba el
  formato.**
- **La ausencia de identidad no se toma como un cambio.** Si la línea guardada
  no tiene el campo (escrita antes de este cambio) se compara por nombre, como
  antes: desplegar esto en una máquina que lleva semanas con el mismo kernel no
  puede producir un "kernel arrancado" espurio. La otra lectura —tratar el
  vacío como una identidad distinta— sí lo producía.
- **La primera corrida tras desplegar sí anuncia**, y es correcto: la firma
  guardada la escribió una versión que no veía el pkgrel, así que la
  identidad ha cambiado de verdad y ahora es visible. A partir de ahí se
  estabiliza; verificado ejecutando el script contra el `verify-last` real.
- **`build_label()`**: " (build 13)" en los títulos de las dos notificaciones y
  una línea `Build (paquete)` en el informe. Sin ella, "7.2.8-cizen-v3
  arrancado" es ambiguo entre dos builds.
- **El campo va al final de `verify-last`/`verify-history`** (noveno), por el
  mismo motivo y con la misma regla que el `boot_id` de la v27.33.1: para no
  desplazar lo que ya se leía. El campo 1 sigue siendo la versión a propósito,
  porque `boot_ref` filtra por él para la mediana de arranque, y en eso un
  pkgrel nuevo sigue siendo el mismo kernel para el usuario.
- **Limitación documentada en el código**: esto es el build *instalado*, no el
  de la imagen que arrancó. Un rollback a una UKI anterior sin reinstalar se
  anunciará como nuevo. Falla hacia el aviso de más, nunca hacia el silencio.

Lo que **no** cambia: con todo limpio y el mismo build, sigue sin notificarse.
Lo nuevo es que un build nuevo se anuncia **aunque esté limpio**, que es lo que
`notify_first_boot` siempre quiso hacer.

## [27.33.6] - 2026-10-02

**Cerrado el ciclo de PGO de punta a punta: por primera vez en esta máquina hay
un `.afdo` real, y el build que lo consume lo aplicó de verdad.** La primera
mitad es lo que cuenta abajo (captura, LBR, conversión). La segunda son estos dos
ajustes, que salieron **ejecutando** el build con el perfil en la mano, y que
ningún test habría encontrado antes: no había nada que testear hasta que el ciclo
llegó a cerrarse.

**Primera mitad: el perfil nunca llegó a existir.** Quince minutos de captura y
365 MB de `perf.data` tirados a la basura: el `.afdo` no llegó a existir nunca. El perfil falló en la conversión, después de
todo el trabajo, y el `trap` de limpieza se llevó la captura con él. Tres fallos
encadenados, ninguno de los tres visibles en el mensaje que salió.

- **`llvm-profgen` sin `--kernel`.** La receta de
  `docs.kernel.org/dev-tools/autofdo.html` para el kernel es
  `llvm-profgen --kernel --binary=<vmlinux> --perfdata=<perf.data>`. Sin ese
  flag, `llvm-profgen` busca binarios de **espacio de usuario** en los mmap
  events del `perf.data`; como el muestreo es solo de kernel, no encuentra
  ninguno y aborta con `No relevant mmap event is found in perf data`. El script
  nunca lo pasó. (Habría bastado además `-kallsyms` en el `perf record` para que
  saliera el mmap de `[kernel.kallsyms]`, pero la vía correcta es `--kernel`.)
- **La captura no tenía ni una sola rama.** El script grababa
  `perf record -F 999 -a -g`, que es una radiografía de IPs. AutoFDO no pondera
  «cuántas veces se ejecutó una línea» sino las **predicciones** de cada bloque
  básico, y eso solo sale de la pila de ramas: el `--help` del propio
  `llvm-profgen` avisa («it should be profiled with `-b`») y la doc prescribe el
  evento LBR del fabricante con periodo primo. SeSampling por frecuencia y sin
  `-b` habría producido, como mucho, un perfil inservible.
  Ahora `pgo_perf_event()` elige la receta de la doc según el vendor:
  `br_inst_retired.near_taken:k -b -c 500009` en Intel con LBR,
  `--pfm-events RETIRED_TAKEN_BRANCH_INSTRUCTIONS:k -b` en AMD Zen3 (BRS) o
  Zen4 (`amd_lbr_v2`), y **error con explicación** donde no hay LBR, en vez de
  capturar en balde.
- **El reparto de argumentos se rompía por el `IFS` del propio script.** Al
  cambiar la captura, la receta se pasaba como texto y se expandía sin comillas
  (`$PERF_LBR`). El script declara `IFS=$'\n\t'` — **sin espacio** — así que no
  se parte en palabras: `perf record` recibía
  `-e "br_inst_retired.near_taken:k -b"` como **un** evento y moría con
  `event syntax error: '..ar_taken:k -b'`, otra vez antes de muestrear. Es la
  misma trampa que el `read -r a b c` de la v27.33.5, por el mismo motivo. La
  receta se deja ahora en el array `PGO_PERF_ARGS` y se pasa como
  `"${PGO_PERF_ARGS[@]}"`, con lo que el `IFS` deja de importar. Hay un test
  que reproduce el `IFS` real y exige 3 tokens, no una frase.
- **`trap 'rm -rf "$TMPD"' EXIT` borraba la captura justo cuando hacía falta.**
  Ahora el `perf.data` se conserva junto al `.afdo` si la conversión falla
  (`<salida>.perf.data`, más `--keep-perfdata` para conservarlo siempre), así
  que un fallo de conversión se reconvierte sin volver a muestrear.
- **El perfil salía en `/root/kernel-pgo` y en un directorio que no podías
  tocar.** `sudo` cambia `$HOME`, así que el `.afdo` se escribía donde el paso 3
  del ciclo (`kernel-update.sh --pgo` a secas, que busca en `$HOME/kernel-pgo`)
  no lo ve. Se resuelve el home de `$SUDO_USER` y se deja el fichero con su
  propietario. Y el **directorio** también: si nace de root, el `.afdo` es tuyo
  pero no puedes borrarlo, porque unlink pide escritura en el directorio, no en
  el fichero. Con `--out` explícito se respeta lo que digas.
- **La receta de captura se imprimía partida en tres renglones.** El join
  `"${PGO_PERF_ARGS[*]}"` une por el primer carácter del `IFS`, que aquí es `\n`.
  Cosmético, pero esconde el resto de la línea: el mensaje parecía truncado.
- **Aviso nuevo, no bloqueante:** si el kernel en marcha no se compiló con
  `CONFIG_AUTOFDO_CLANG`, se dice. Upstream lo llama *advisable* (el perfil usa
  números de línea relativos y tolera la diferencia), así que el ciclo puede
  seguir; lo que no puede seguir es creerse que el perfil es de primera.
- **El resumen anunciaba un build SIN PGO, justo en la forma que documenta el
  README.** `ask_build_pgo` marca `PGO_CHANGED` solo en el camino interactivo y en
  `--pgo` a secas; la rama de `--pgo <fichero>` —la que dice el README, y la que
  se usó— entraba y salía con `PGO_CHANGED=0`. Ese flag es lo único que lee
  `pgo_disp_suffix`, así que el bloque «Configuración lista para compilar» imprimía
  `+ bore + clang` sin `+ PGO`. **El build llevaba `-fprofile-sample-use`
  igualmente**: el perfil viaja por `KCONFIG_CC_OPTS` (líneas ~919 y ~11007), que
  no mira ese flag. Un resumen que miente sobre lo que lleva la build es peor que
  no resumir, porque es la línea donde uno comprueba si el perfil entró antes de
  esperar media hora al compilador. Ahora la rama también marca `PGO_CHANGED=1`,
  con la condición de que el perfil no esté vacío: sin fichero detrás no se
  anuncia un perfil que no existe. La causa era la ambigüedad del flag, cuyo
  comentario decía «cambió el perfil en esta llamada» cuando lo que significa de
  verdad es «esta build lleva PGO». Es la v27.31.53 en sentido inverso: allí el
  `+ PGO` salía siempre, aquí no salía nunca en un caso.
- **La suite se despliega a mano, y a mano se le olvidó el `+x` a dos
  ficheros.** No hay `PKGBUILD`, `Makefile` ni script de instalación en el repo: el
  README documenta un `install -Dm755` **por fichero**, y el 2-oct el motor y
  `pgo-collect.sh` quedaron en `644` en `/usr/local/bin/kernel-update/` mientras
  los otros ocho seguían en `755`. El síntoma fue «Permiso denegado» al arrancar
  el motor recién compilado. No es un bug corregible en el motor —es el modo de
  despliegue—, así que lo que se hace es no volver a hacerlo: el README lleva la
  receta completa y un test recorre la suite exigiendo el bit `+x` en los 10
  ejecutables del repo, que es el único lado que el repo controla.
- **Tests: 22 nuevos → 601 ok / 0 fail**, en rojo contra el commit anterior.
  Cubren la elección de evento con cuatro cpuinfo de mentira (Intel con y sin
  el evento, AMD con `brs`, AMD con `amd_lbr_v2`, AMD sin LBR y vendor
  desconocido), que toda receta lleve `-b`, que los argumentos lleguen a `perf`
  como tokens sueltos con el `IFS` real del script, que la conversión pase
  `--kernel`, que el trap conserve la captura, el periodo primo por defecto, la
  resolución del home con y sin `SUDO_USER`, y la detección de
  `CONFIG_AUTOFDO_CLANG`. El arnés extrae por primera vez de
  `pgo-collect.sh`, que no vive en el motor: si el script está pero sus
  funciones no son extraíbles, eso se marca como **fallo**, no como «omitido».
  Los cinco últimos cubren el cierre del ciclo: que `--pgo <fichero>` marque el
  cambio y ponga `+ PGO` en el resumen, que `--pgo` a secas siga funcionando, que
  sin PGO no se anuncie (el resumen no puede mentir al revés), que `--pgo` sin
  perfil detrás no invente un perfil, y que los 10 ejecutables de la suite
  lleguen con `+x`. Los de PGO extraen `ask_build_pgo` y `pgo_disp_suffix` y
  comprueban el **flag** que alimenta el anuncio, no el texto impreso: un test
  que grepa la cadena de salida pasa aunque el resumen vuelva a mentir, porque
  el texto es una consecuencia del flag.

## [27.33.5] - 2026-10-02

**El resumen de acierto de ccache no se había impreso nunca, y su error salía
en la última línea del build.** Todo por un `read` de tres variables con el IFS
del motor, que no incluye el espacio.

- **`IFS=$'\n\t'` (línea 147) y `read -r a b c`.** Con ese IFS, `read` **no**
  reparte por espacios: la foto que `CCACHE_BEFORE` tomaba antes de compilar
  («41407 34418 0») se iba **entera** a `_cb_h` y `_cb_m`/`_cb_u` quedaban
  vacías. La línea siguiente es una aritmética, así que el build terminaba con
  `arithmetic syntax error in expression (error token is "34418 0 ")` y
  `_d_h` nunca se asignaba: `CCACHE_STATS` quedaba **vacío** y el bloque —que
  existe desde v27.31.52 precisamente para decir si esta build ha reutilizado
  la caché— no imprimió ni una vez. En el build del 2-oct, el primer indicio fue
  ese error suelto después de «Configuración final guardada».
- **Se parsea con `ccache_snapshot_parse()`**, una función que imprime las tres
  cifras en líneas separadas y satura a 0 lo que no sea numérico, y el resumen
  las lee con `mapfile` (que no depende del IFS). La función existe **para poder
  testearla**: el `read` en línea era imposible de cubrir, y un bloque no
  testeable es exactamente cómo llegó esto a producción. Un `for` de cinturón
  convierte cualquier foto futura mal formada en ceros en vez de un error de
  aritmética.
- **Tests: 3 nuevos → 579 ok / 0 fail**, 2 de ellos en rojo contra el commit
  anterior. El montaje pone el IFS real del motor (`$'\n\t'`), que es la
  trampa, y comprueba con la foto exacta que dejó el build del 2-oct.
- **Nada de esto afecta al kernel compilado**: es un resumen. Se corrigió porque
  un error de aritmética al final de un build de 32 minutos es exactamente el
  tipo de ruido que hace mirar para otro lado el siguiente aviso.

## [27.33.4] - 2026-10-02

**El store de `vmlinux` nunca se escribía en este host, y el README lo prometía
en contrário.** El ciclo de PGO es: compilar sin perfil → el motor archiva solo el
`vmlinux` (el árbol vive en un tmpfs que se desmonta al final) → colectar →
recompilar. El paso 2 fallaba en silencio y el flujo solo se cerraba si alguien
archivaba el fichero a mano.

- **`archive_vmlinux` usaba tres comandos sudo que el propio motor no declara.**
  La escritura era `sudo cp` a `.tmp` + `sudo mv` al final, y el testigo `.meta` con
  `sudo sh -c 'printf ... > ...'`. El motor **declara** sus dependencias de sudo en
  `SUDO_OPS_REQUERIDOS` / `_OPCIONALES` y `preflight_sudo` las dice al build, pero
  el store usaba `sh`, que **no está en ninguna de las dos listas** (una
  dependencia sin declarar), y `mv` y `cp`, que solo son *opcionales*: por eso
  `preflight_sudo` no podía avisar de nada. En `/etc/sudoers.d/99-cizen-build` la
  allowlist cubre `cp`, `mkdir`, `rm` e `install` pero no `mv` ni `sh`, así que el
  `cp` dejaba el `.tmp`, el `mv` fallaba, y el store acababa sin `vmlinux` ni
  testigo mientras el motor solo ponía un `warn` y el README prometía lo
  contrario. Además la función se introdujo en v27.31.52, **después** del último
  build de esta máquina, así que no la había ejecutado nadie aquí. Ahora escribe
  con `sudo install` (`store_install`), y a secas si el destino es escribible por
  el usuario: sus comandos quedan **dentro de `SUDO_OPS_REQUERIDOS`**, que es lo
  que un store —sin el cual el ciclo de PGO no existe— debería poder exigir.
- **La atomicidad no se pierde, cambia de sitio.** `install` no es un rename, así
  que la garantía de «nunca queda un `vmlinux` a medias» la da ahora el testigo:
  `$release.meta` se escribe DESPUÉS de copiar y con el tamaño real de lo
  archivado, y `pgo-collect.sh` **exige** ese testigo y **comprueba el tamaño**
  antes de usar un fichero del store. Sin él, el candidato se salta con aviso
  (copia a medias, o build anterior a esta versión). Un `--vmlinux` explícito no
  pasa por el filtro: ahí el usuario está señalando el fichero a mano.
- **`CIZEN_VMLINUX_STORE` se perdía al elevar.** `pgo-collect.sh` se re-ejecuta
  con `exec sudo`, y el `env_reset` de Arch (sin `env_keep`) borra las variables
  del usuario: un store personalizado se transformaba en «no encuentro el
  vmlinux» sin más explicación, siendo un fichero que el motor acababa de
  archivar. Ahora viaja explícitamente al proceso elevado, igual que el resto del
  entorno de PGO.
- **Perfil de esta máquina, v5.18.0.** Poda de código que no se ejecuta nunca,
  verificada contra el Kconfig de 7.2.8 con `olddefconfig` (no de memoria):
  `HYPERVISOR_GUEST`, `KVM_GUEST` (esta máquina es anfitriona, no invitada),
  `LIRC` (mando IR muerto desde 2017), `KSM` (=y pero `run=0`, nunca activado) y
  `TCG_TIS`/`TCG_CRB` (TPM apagado en BIOS). Dos más resultaron IMPOSIBLES y
  pasan a `EXPECTED_REBELS`: `DRM_TTM`, que `select` i915, y `KVM_COMPAT`,
  `def_bool y` mientras KVM esté puesto. Se dejan fuera a propósito y con
  criterio medido: `ZRAM` (red de seguridad del tmpfs de 10 GiB sobre 16 GiB de
  RAM), `BT` (=m, nunca se carga, pero `bluetooth.service` está enabled y se
  pondría roja al apagar `CONFIG_BT`), y las mitigaciones, que en 7.x son
  parámetros de runtime y no de Kconfig. `COMPAT` tampoco se apaga: lo decidió el
  usuario, y hay 77 paquetes `lib32-*` y prefijos `~/.wine`/`~/.mt5` con
  ejecutables PE32 de 32 bits. El `.config` promovido baja de 2032 a 2011
  símbolos activos y recoge además el arreglo del gobernador que v5.17.0 dejó
  pendiente. Validado con `--check`: 308/308 desactivaciones resueltas, 0 avisos.
- **Tests.** 9 nuevos (576 ok / 0 fail), y 6 fail contra el commit anterior
  (cada red muerde al código viejo). El archivado se prueba de verdad, contra un
  árbol falso: que copia `vmlinux` y `vmlinux.unstripped`, que escribe el `.meta`
  con el tamaño real, y que con un store escribible **no pide sudo ni una vez** (si
  lo pidiera, el fallo se vería en el log de `sudo` del montaje). La regresión de
  alcance no es una lista de comandos escrita a mano, sino el **contrato del
  motor**: se extrae `SUDO_OPS_REQUERIDOS` y se comprueba que el store no use
  ningún `sudo` fuera de ahí, así que reintroducir `sudo mv` o `sudo sh` falla
  aunque el store funcione. Y del lado del consumidor, las dos funciones de
  búsqueda se extraen tal cual de `pgo-collect.sh` y se comprueban los tres casos:
  sin `.meta` no se usa, con el tamaño que no cuadra no se usa, con testigo y
  tamaño correcto sí.

## [27.33.3] - 2026-10-01

**Auditoría del 1-oct: siete defectos, siete redes.** Todos comparten la misma
forma —el motor corre con `set -Eeuo pipefail` y hay sitios donde eso convierte un
detalle en un fallo de build o en un silencio— y todos verificados contra el
código, no contra la lectura.

- **Fuga de estado entre parches (`--sched pds --bore`).** `apply_patch_plugin`
  reseteaba el estado del descriptor antes de cada parche, pero se le escaparon
  tres variables: `PATCH_CHOICE_DISABLE`, `PATCH_RETIRED_SYMBOLS` y
  `PATCH_EMBED_B64`. `patch_desc_bore` no las declara (no las necesita: BORE no
  activa SCHED_ALT ni lleva parche embebido), así que en un run con dos
  schedulers heredaba las del primero. Lo que se acumulaba: un
  `--disable SCHED_PDS` que nadie pidió, los cinco símbolos de BMQ duplicados en
  `PATCH_RETIRED_ALL` (y `build_effective_arrays` borra de `EFF_CRITICAL` /
  `EFF_SETVAL` justo los que están en esa lista), y **el parche BMQ embebido
  usado como fallback del parche BORE**: si el de red fallaba, se aplicaba el de
  otro scheduler y el build continuaba creyendo que llevaba BORE.
- **`SECURE_BOOT: variable sin asignar`, al final de un build entero.** La
  condición de `module_sign_installed` leía `$SECURE_BOOT`, que no existe en
  ningún punto del motor. Con `set -u` el build moría —compilación hecha,
  paquete instalado, módulos sin firmar— y solo en la primera ejecución: para la
  segunda el certificado ya existía y la línea no se alcanzaba. De ahí que
  pareciera intermitente. Ahora decide por `secure_boot_active`.
- **Módulos comprimidos sin firmar.** El perfil de esta máquina lleva
  `CONFIG_MODULE_COMPRESS_ZSTD=y` y `CONFIG_MODULE_COMPRESS_ALL=y`, así que el
  árbol instalado no tiene ni un `.ko` pelado; la búsqueda era solo
  `-name '*.ko'`, no encontraba nada y aun así informaba `ok: 0 módulos
  firmados`. Nuevo `_sign_installed_module`: descomprime (zstd/gzip/xz/lz4),
  firma, recomprime y mueve encima del original solo si el compresor sale bien;
  un módulo corrupto se queda como estaba. Como el temporal vive en `/tmp`, el
  `mv` arrastraba su propietario y su modo, así que se restauran `root:root` y
  el modo original: un módulo de usuario con modo 600 en `/usr/lib/modules` no
  es aceptable. Y `0 firmados` es aviso, no éxito.
- **Un árbol de fuentes truncado pasaba por bueno.** `extract_tarball` se invoca
  como `extract_tarball || fatal`, y eso desactiva `errexit` en todo su cuerpo:
  un `tar` a medias se comía el fallo y, como el resto de la función solo mira
  que exista `$SRC/Makefile`, se compilaba un kernel incompleto sin un aviso.
- **La migración de `linux-upstream` se ejecutaba en cada build.** La prueba
  usaba `pacman -Q`, que resuelve `provides` —y el propio motor declara
  `provides=("linux-upstream")` en su paquete—, así que respondía 0 siempre, con
  `linux-cizen-v3` en la salida; la retirada, que solo acepta nombres, fallaba
  con `target not found` y se reportaba como «ya no estaba instalado» más el
  error crudo. Ahora la prueba usa `pacman -R --print`, el mismo resolutor que
  la retirada, y no toca nada.
- **La poda abortaba con `bad array subscript`.** Un módulo conservado sin
  `depends=` daba un elemento vacío que se usaba como subíndice. El motor
  inyecta el script con `|| true`, así que la consecuencia era un paquete
  instalado **sin poda y sin índices de dependencias**, sin ningún aviso. Además
  `/etc/modules-load.d` admite `kvm_intel   # para KVM`: se quitaba el
  comentario pero no los espacios, y la clave del allowlist no casaba.
  `podar-modulos.sh` pasa a v1.1.2.
- **El histórico del banco de schedulers se llenaba de «desc».** Con
  `SCHED_BENCH_LOAD_N=1`, la regla `/^1 hilo/` (sin ancla al final) también
  casaba con la línea del brazo paralelo `1 hilos : ...`: se la comía,
  `par` nunca se fijaba y `flush()` descartaba todas las muestras. Reglas
  ancladas: `/^1 hilo[ ]/`, `/^4 hilos[ ]/`.
- **`pgo-collect.sh` pedía contraseña para `--help`.** El `exec sudo` estaba
  antes de parsear los argumentos, y `CIZEN_PGO_DURATION` / `_VMLINUX` / `_OUT`
  se perdían con el `env_reset` de sudo (sin `env_keep`): un perfil de 60 s se
  compilaba con 600 s en silencio. Ahora parsea primero y pasa el entorno de
  forma explícita.
- **El menú llegaba a una ruta fija inexistente.** La opción 17 (gestor de
  kernels) ya resuelve el script como hace el rollback: `CIZEN_KMANAGER_SCRIPT`,
  hermano por directorio y ruta instalada, con diagnóstico si no lo encuentra.
- **Un test cazó un fallo en su propia corrección.** El recuento de directivas de
  un `.frag` dividía tokens entre dos (`--set-str` gasta tres) y anunciaba «4
  directivas» donde eran 3; el primer arreglo usaba `shift 2`, que dejaba el
  valor suelto y lo contaba como una directiva más (6 donde debían ser 3). Es
  `shift 3`, y está cubierto.
- **Tests.** 33 nuevos, con montajes sintéticos donde hace falta (árbol de
  módulos con `depmod`, log del banco de schedulers, stubs de root y de
  `sign-file`). 567 ok / 0 fail; contra la v27.33.2 fallan 29, uno por cada
  defecto y por sus variantes.

## [27.33.2] - 2026-10-01

**«El kernel es anterior al perfil» se contaba dos veces.** Consecuencia directa
de v27.33.1: al quedar la duplicación de perfil como única incidencia real, el
número que acompaña a la notificación era el que inflaba el recuento.

- **El defecto.** `profile_check` contaba el mismo hecho por dos lados: una
  incidencia por cada símbolo que el perfil pide y el kernel no tiene (`bad[]`),
  y otra por el sha distinto del perfil del build. Con un desfase real son la
  **misma causa** y el arreglo es el mismo —reconstruir—, así que la
  notificación de hoy ponía `Perfil: FALLO` con 2 incidencias por un único
  hecho.
- **Qué cambia.** El desfase se detecta **antes** de contar, porque decide cómo
  se cuenta. Con sha distinto: una sola incidencia, y los símbolos pasan a ser
  el detalle del aviso (`N símbolo(s) que el perfil pide y este kernel no
  cumple, por ese desfase`), sin perder ni uno. Sin sha distinto **no cambia
  nada**: cada símbolo incumplido sigue contando uno, porque entonces el kernel
  se compiló con ese mismo perfil y no cumplirlo sí es un fallo del build.
- **Desfase sin síntomas.** Si el kernel es anterior al perfil pero cumple todo
  lo que el perfil pide —un cambio de comentario, un nombre—, se informa con
  `pc_info` y **no** cuenta incidencia: no hay nada roto.
- **El criterio sigue siendo el sha, nunca la `mtime`.** Un `cp`, un `touch` o
  un checkout de git tocan el fichero sin cambiar su contenido; avisar por la
  fecha sería ruido. Hay un test que falla si vuelve a aparecer un `stat -c %Y`
  sobre el perfil.
- **Etiqueta de la notificación.** `Perfil (símbolos)` → `Perfil`: el número ya
  no cuenta símbolos (el 1 agrupa varios), y la etiqueta anterior mentía sobre
  lo que mide.
- **Tests.** 6 nuevos, con perfil y firma sintéticos para cubrir los dos lados
  (con el perfil real de esta máquina solo se puede provocar uno), más el del
  `mtime`. 534 ok / 0 fail; contra la copia v27.32 fallan 9, los de v27.33.1 y
  los de este bloque.

## [27.33.1] - 2026-10-01

**La comparación de arranque deja de ser ruido.** El verificador notificaba un
"boot más lento" en un arranque de 17.795 s que era exactamente la mediana del
propio kernel, y `--dry-run` cambiaba la línea base de la verificación real.

- **Por qué 17.795 no era una regresión.** El total de arranque de este host va
  de 11.8 a 22.8 s con desviación de 2.9. El criterio anterior era `1.35x` y
  `+3 s` contra el arranque **inmediatamente anterior**: una sola muestra, así
  que cualquier salto de ruido cruzaba el umbral. En el historial real eso son
  3 de 44 pares (6 %), y el caso peor era 17.795 s contra 12.823 — con una
  mediana de 17.795 s detrás. No había regresión; había una muestra mala.
- **Qué cambia.** `boot_ref()` calcula la **mediana de los últimos `N=7`
  arranques del mismo kernel**, con mínimo `3` muestras
  (`CIZEN_VERIFY_BOOT_REF_N`, `CIZEN_VERIFY_BOOT_REF_MIN`). Una mediana no se
  desplaza por un arranque lento suelto, que es justo lo que hay que detectar
  como anomalía y no como nuevo nivel. Sin muestras suficientes se cae al
  arranque previo, que es el comportamiento de siempre.
- **Solo el mismo kernel.** El 22.797 s del 27-sep era el
  `6.18.54-1.1-lts`, no una regresión del Cizen. La referencia se filtra por
  versión.
- **Una línea por arranque, no por verificación.** Se registra el
  `boot_id` al final de cada línea de `verify-history` y `boot_ref` deduplica
  por él: una unit que corre dos veces en el mismo arranque, una verificación
  manual y un `--dry-run` son el mismo dato. La primera versión deduplicaba por
  "total igual al anterior" y rompía justo en el caso que más importa — con un
  arranque determinista (5 arranques de 13.0 s seguidos) colapsaba las cinco
  muestras en una y la mediana no se usaba nunca. El campo va al final, así que
  las lecturas antiguas (`read -r v ke us tot j iss ts`) siguen funcionando.
- **`--dry-run` deja de escribir.** Se anunciaba como "imprime sin notificar,
  útil tras un reboot para auditar", pero escribía `verify-last` y
  `verify-history`. Dos consecuencias: `verify-last` quedaba con los tiempos del
  arranque **en curso**, así que el "previo" que leen `boot_check` y
  `journal_check` acababa siendo el propio arranque y la comparación no
  comprobaba nada; y metía líneas falsas en el historial, que es de donde sale
  la referencia.
- **Efecto medido.** Replay del historial real (77 verificaciones): el criterio
  viejo daba **5** notificaciones de boot, el nuevo **3**, y desaparece el
  *flapping* de "dispara y en la siguiente verificación del mismo arranque no".
  Las 3 restantes son del tramo inicial, cuando aún no hay historial y se usa el
  fallback.
- **Tests.** 11 nuevos en `selftest.sh`, y la suite se comprobó en rojo contra
  la copia instalada anterior (6 fallos, todos de este bloque). Uno de ellos
  comprueba que un arranque verificado 5 veces no pesa como 5 arranques, con un
  historial donde deduplicar y no deduplicar dan medianas distintas (13.000 vs
  40.0) para que el test no pueda pasar por casualidad.

## [27.33.0] - 2026-09-30

**El menú pasa `--no-btf` en todas las builds.** Decisión del usuario: este
equipo usa **solo BORE**, sin sched_ext.

- **Por qué BTF no servía.** `CONFIG_DEBUG_INFO_BTF` se pedía únicamente para
  `SCHED_CLASS_EXT`, y con BORE no hay dónde anclarla: BORE *sustituye* a
  `SCHED_CORE`, que es justo donde sched_ext se engancha. Con las dos
  compiladas a la vez, `sudo scx_bpfland` falla con `Failed to load BPF
  program`. El perfil v5.16.0 ya lo había decidido así (y quitado
  `SCHED_CLASS_EXT` de `OPTS_ENABLE`), pero **solo declarándolo**: apagarlo de
  verdad requería el flag, y el menú no tenía forma de pasarlo.
- **Por qué era un coste real, no teórico.** El pase de `pahole` sobre el
  `vmlinux` se come ~6,7 GB de RSS, y fue lo que provocó el swapeo y los 34
  min del build de pkgrel 9 (§36.2 de Agente.md). Se estaba pagando en cada
  compilación por una capacidad inalcanzable.
- **Por qué el perfil no puede arreglarlo solo.** `CIZEN_NO_BTF` se lee en
  `kernel-update.sh:881` y el perfil se sourcea en la 1515, **después**; ponerlo
  dentro del perfil llega tarde. El motor además lo enciende por defecto
  (`BTF_REQUESTED=true`, línea 316). El menú era el único punto de entrada real.
- **Qué cambia.** `resolve_btf_flag()` devuelve `--no-btf`, y lo usan
  `build_and_exec()` (opciones 1-5, 7, 8, 15, 16, 18) **y la 14**, que construye
  fuera de `build_and_exec` y se habría quedado fuera. Se añade una línea visible
  en la sección «Compilación» para que no sea unBehaviour invisible.
- **Escape hatch:** `CIZEN_BTF=1` devuelve la llamada a como estaba, por si
  algún día hace falta (`bpftrace`, etc.).
- **Tests.** 4 nuevos, y se actualizan las 3 aserciones de args exactos de
  `build_and_exec` (ahora llevan `--no-btf`). Uno comprueba el porqué —que el
  motor siga siendo opt-out— para que si algún día se invierte el default, el
  test falle y obligue a revisar el menú en vez de dejar un `--no-btf` inofensivo.
  Otro cubre `CIZEN_BTF=1`, en particular que no cuelgue un argumento vacío
  (`set -- "$@" ""` invocaría el motor con un flag fantasma).
- **Fuera de este cambio, por si se busca:** el perfil del usuario en
  `~/.config/kernel-update/profiles/` estaba en **v5.13.0**, 327 líneas por
  detrás del instalado (v5.17.0). No rompía nada —el motor resuelve primero
  `$SCRIPT_DIR/profiles/` (`kernel-update.sh:206-210`), así que el rancio estaba
  muerto— pero habría reactivado `SCHED_CLASS_EXT` y BTF si el instalado
  desapareciera. Sincronizado con paridad sha256 y el v5.13.0 queda como `.bak`.

## [27.32.0] - 2026-09-30

Auditoría de rendimiento del host en tres capas, porque el cuello de botella
puede estar en cualquiera de ellas y el perfil solo controla una.

La conclusión de fondo es incómoda y conviene decirla primero: **la capa Kconfig
estaba impeccable.** 61 `OPTS_ENABLE` respetados y **0** violaciones en los 449
`OPTS_DISABLE`. Los tres `OPTS_ENABLE` que salen `=m` en vez de `=y`
(`BT_HCIBTUSB`, `SND_HDA_CODEC_ALC269`, `SND_HDA_CODEC_HDMI_INTEL`) son
equivalentes funcionalmente y los carga udev. Ese barrido se hizo extrayendo
cada array del perfil por nombre, saltando los comentarios que viven **dentro**
de los arrays, y comparando contra `/proc/config.gz` del kernel en ejecución, no
contra la config del repo. Un parser que se desborda da cuatrocientas falsas
entradas: conviene decirlo porque es el error fácil.

Lo que sí estaba mal estaba en la capa de arranque.

- **`preempt=full` anulaba `CONFIG_PREEMPT_DYNAMIC`.** El kernel se compila con
  preempción dinámica, así que el cmdline no la cancela: la **fija** al modo más
  caro, donde además *"tasks will also yield contended spinlocks"*. Se pagaba el
  coste entero de `full` sin obtener nada de `DYNAMIC` — que entre otras cosas
  permite cambiar de modo sin reiniciar. Y los caminos de spinlock y vmexit son
  exactamente los que peor toleratean, en una máquina que además corre KVM.
  Pasa a **`preempt=lazy`**: mantiene casi la latencia interactiva de `full`
  dejando un tick de HZ para que la tarea ceda por sí misma, con mucho menos ruido
  de preempción. Para escritorio + KVM es el punto que casi nadie prueba.
- **`+ retp=rethunk`.** El kernel en ejecución reportaba
  `spectre_v2: Mitigation: IBRS; IBPB: conditional; STIBP: disabled; RSB filling`.
  Según el propio kernel (`arch/x86/kernel/cpu/bugs.c`), esa cadena significa IBRS
  *o* RSB filling, y el retorno por thunks sería la alternativa. Con
  `CONFIG_MITIGATION_RETHUNK=y` y clang 22.1.8 (`-mfunction-return=thunk-extern`)
  la mitigación **equivalente** es más barata. No es prueba directa —`dmesg` no es
  legible sin privilegios—, es una inferencia sólida, y queda como candidata a A/B.
- **Gobernador `powersave` → `performance`** (perfil v5.17.0). Aquí hubo que
  corregirse a uno mismo: la hipótesis inicial era que `powersave` anclaba la CPU
  al P-state más bajo. **Es falsa.** El `power-profiles-daemon` de Arch está en
  perfil `performance` y sobrescribe el EPP a `performance`; el host ya iba a
  máximo. Lo que arregla el cambio no es rendimiento, es **fragilidad**: con
  `powersave` compilado, si el PPD no arrancara —rescate, arranque mínimo, unidad
  fallida— el sistema caía en silencio a EPP 255. Ahora config y realidad
  coinciden y el fallback también es de máximo rendimiento.

**Descartado explícitamente.** BORE con `NO_HZ_FULL` desactivado *parecía* un
conflicto, así que se leyó `kernel/sched/bore.c`: BORE solo se condiciona a
`CONFIG_SCHED_BORE`, sin dependencia dura de `NO_HZ_FULL`. No era un conflicto y
`NO_HZ_FULL` sigue sin activarse. También se confirma que no hay problema en
zram (16 GiB de zstd con **cero** uso, RAM al 56 %), en Btrfs
(`noatime`/`compress=zstd:3`/`ssd`/`discard=async`/`space_cache=v2`), y que las
mitigaciones ya están en su variante **barata**: IBRS con `IBPB: conditional` y
`STIBP: disabled`.

El cambio de cmdline vive en `/etc/kernel/cmdline`, no en este script:
`prepare_cizen_cmdline_file()` lo **hereda** (y cae a `/proc/cmdline` si no
existe), así que no hay nada que generar aquí.

## [27.31.54] - 2026-09-30

Un árbol de fuentes parcheado ya no se hereda como si fuera limpio. Lo cazó el
usuario en una build de verdad.

El síntoma era raro, la causa era de fondo: **la identidad de un árbol era solo
`<versión>|<tipo>`**. Un vanilla 7.2.8 al que una ejecución anterior le aplicó
BORE seguía siendo `<7.2.8>|vanilla`, así que la siguiente run lo reutilizaba sin
mirar dentro. El resultado fue una build anunciada como *vanilla* que compilaba
con BORE, y un símbolo en el resumen (`SCHED_BORE: y → n`) que no era el que
esperaba: el resolvedor de nombres lo ofrecía como equivalente de `SCHED_BMQ`
precisamente porque el residuo del parche lo hacía parecer presente en un árbol
que no lo llevaba. El árbol reutilizado tenía 39 menciones de `CONFIG_SCHED_BORE`
en `kernel/sched/fair.c`; el tarball firmado, 0.

- **`patches=` en el testigo `.cizen-tree`**: `none` en un árbol recién extraído, o
  la lista de los aplicados. Es el estado que faltaba.
- **Un árbol con parches no se reutiliza como árbol limpio.** `extract_tarball` lo
  descarta, lo dice nombrando el parche que sobra, y vuelve a extraer. El aviso
  importa tanto como el descarte: un "se va a reextraer" genérico deja al usuario
  sin saber por qué.
- **"No se puede probar" no es "está limpio".** Un testigo heredado (sin la clave,
  de versiones anteriores) o un árbol sin testigo dan `unknown` y **no** se
  reutilizan. Cuesta una reextracción única, y a partir de ahí el árbol sale con
  `patches=none`. Es el mismo criterio que el resto del motor: si no se puede
  probar algo, no se da por bueno.
- **La descarga del tarball se exige también con un árbol sucio.** Si se saltaba,
  la reextracción se quedaría sin fichero del que tirar (o con el de otra versión
  que hubiera en caché). `get_tarball` ahora exige *reutilizable **y** limpio*.
- `apply_patch_register` es el punto donde queda anotado el parche, porque es por
  donde pasan los **dos** caminos de éxito: el que acaba de aplicarlo y el que
  encuentra el parche ya puesto en el árbol conservado. Anotarlo en
  `apply_patch_plugin` habría dejado fuera el segundo.

`tree_usable_for` **no** cambia: la consultan ocho sitios para saltar trabajo
(márgenes de disco, evitar el tarball…) y un árbol ya parcheado en esta misma run
es perfectamente válido ahí. Lo que no puede es heredarse a la siguiente. Por eso
el filtro vive en `tree_clean_reusable`, en `extract_tarball`, que se llama **una
sola vez por run** y antes de aplicar nada.

Verificado: `bash -n` limpio, **0 errores en ShellCheck**, **513 ok, 0 fail** en
selftest contra el motor del repo (20 tests nuevos). Los siete mutantes —cada
parte del arreglo por separado— los detecta el banco.

**Un fallo del propio banco, que es lo relevante de esta entrada.** Los tres
escenarios de `extract_tarball` se puntúan desde un subshell que escribe
veredictos a fichero, y el `while read` leía el primer campo para elegir la
descripción. La rama de fallo escribía `sucio fail: …`, así que el primer campo
era `sucio`: el mismo nombre que el escenario **correcto**. Los tres se puntuaban
como buenos con el motor mutado, y dos de las siete mutaciones pasaban
desapercibidas. Lo mismo con el estado global: la sección dejaba
`VERSION=7.2.8`/`KERNEL_TREE=vanilla` y la de `reconcile_tmpfs_trees` no los
reasigna en su primer test, así que invertía sus cinco expectativas. Ahora los
veredictos llevan el `ok`/`fail` en su propio campo, los stubs van en subshell, y
el estado global se guarda y se devuelve. Se añadió además un test que **cuenta
los veredictos emitidos**: si el subshell muere antes de terminar, los escenarios
dejan de existir y la sección pasa sin comprobar nada, que es la forma más
silenciosa de tener un banco que no prueba.

## [27.31.53] - 2026-09-30

PGO con perfil AutoFDO sale del internaje: era posible usarlo, pero había que
saber la variable de entorno y el fichero, y en el menú no existía. Ahora es una
pregunta más, y una pregunta **propia**.

- **Opción 18 en el menú** (`pgo`) y pregunta de PGO al final de *cualquier*
  compilación, junto a scheduler y compilador. Antes solo se preguntaban esos
  dos, porque PGO no se preguntaba en ningún sitio. Es independiente: vale
  igual con Vanilla que con BORE, con ntsync que con cachy.
- La pregunta **lista los perfiles que hay** con el de tu versión marcado, en vez
  de dar un sí/no a ciegas. `Enter` se lleva el recomendado; `n` pasa; un número
  o una ruta eligen otro. Sin ningún `.afdo` explica cómo conseguir uno en vez de
  fingir que se puede.
- `--pgo [ruta.afdo]`, `--no-pgo` y `CIZEN_PGO_PROFILE` conviven. `--pgo` a secas
  busca solo el perfil de la versión objetivo, que es lo que quiere la opción 18.
- **Exige clang y lo dice.** AutoFDO es de LLVM y `CONFIG_AUTOFDO_CLANG` no
  existe con GCC. Con GCC la pregunta no sale y se avisa de por qué, en vez de
  compilar con un perfil que no se está aplicando. `--pgo` + GCC sigue siendo un
  error de arranque, como ya era.
- El perfil elegido entra en `KCONFIG_CC_OPTS` y **dispara la revalidación** de
  la config, igual que el compilador. Sin eso, `CONFIG_AUTOFDO_CLANG` se
  encendería a medias, sin pasar por la auditoría ni la validación: es el mismo
  fallo que motivó `resolve_symbol_into`, y por el mismo motivo de fondo.
- `verify_build_tree` usaba `resolve_symbol`/`config_symbol_state` en subshell,
  que devuelven por stdout: con `set -u` petaba con `resolved: unbound variable`
  y la build no llegaba a compilar. Ahora usa las variantes `_into`. Este fix no
  tenía entrada propia y por eso aparece aquí.

**Un fix de una línea que salió en una build real**: el resumen
`Configuración lista para compilar con … + PGO.` anunciaba **+ PGO en todas las
compilaciones**, PGO o no, porque usaba `${PGO_CHANGED:+ + PGO}` y el
modificador `:+` pregunta por "vacío", no por "distinto de 1" — y `0` no está
vacío. La build era correcta; el resumen mentía. Lo delata el usuario en una
build sin ningún perfil. Sustituido por `pgo_disp_suffix()`, que **compara
contra 1** y además es testeable por separado.

Verificado: `bash -n` limpio, **0 errores en ShellCheck**, **493 ok, 0 fail** en
selftest contra el motor del repo. Los 17 tests nuevos de PGO se comprobaron por
mutación (14 mutantes, uno por cosa que podría romperse en silencio: el `Enter`
que se ignoraba, el guard de clang, la inyección en Kconfig, la revalidación, la
opción 18, el rango del menú, los flags fuera del parser, la lista que no se
imprime, la ruta inexistente aceptada). Cinco de ellos pasaron al primer intento
porque grepeaban en todo el motor, donde la misma cadena ya existía por la vía
temprana; se acotaron al bloque `ask_build_prefs`. El `Enter` prometía el perfil
marcado y lo ignoraba: ese bug lo encontró el banco, no el test.

## [27.31.52] - 2026-09-30

Rendimiento y correctitud del motor. Todo lo que se toca aquí se verificó
ejecutándolo, no solo leyendo: `bash -n` limpio, **0 hallazgos de nivel error en
ShellCheck** (y dos menos que antes: `newsym` y `newstate`, ya sin uso), **467
ok, 0 fail** en selftest contra el motor del repo, **466 ok, 0 fail** contra el
instalado (la diferencia es el propio test de coherencia repo↔instalado, que solo
corre apuntando al repo), y cuatro bancos de pruebas nuevos (índices Kconfig,
contadores de ccache, selector de scope y manifiesto de rollback) que se quedan
en `/tmp` porque replicar aquí su andamiaje no compensa. Dos sospechas que
parecían grandes resultaron **falsas al medirlas** y no se tocaron:
`compiler_check=content` de ccache (clang aquí es un driver de 178 KB,
2.798 s vs 2.799 s) y la configuración de acierto de ccache (probada, acierta
con normalidad).

### El build iba con nice/ionice sin que nadie lo supiera

El probe de `systemd-run` solo probaba el scope **de sistema**. Medido aquí: ese
D-Bus responde *"Connection timed out"*, así que todas las builds caían a
`nice -n 10` + `ionice -c 3` — el sobrecoste que el propio script documenta como
**20-40%** — mientras que `systemd-run --user --scope` sí funciona y admite las
mismas `CPUWeight`/`IOWeight`. Ahora se prueban los dos niveles antes de rendirse.
No es cosmético: con `CPUWeight=30` la build cede solo cuando el escritorio pide
CPU; con `nice 10` cede ante **cualquier** proceso de nice 0 (packagekit,
updatedb, tracker). Las tres ramas quedan probadas con shims, incluida la
degradación a nice/ionice si fallan ambas.

### El resumen de ccache no mostraba los aciertos

`grep -E '^(Hits|Direct hits|...)'` capturaba **1 línea de 7**. Dos motivos, los
dos verificados contra la salida real de ccache 4.14: el ancla `^` no casa con la
indentación (`  Hits:`, `    Direct:`) y los nombres de etiqueta cambiaron
(`Direct hits:` → `Direct:`). Con 54% de aciertos acumulados, el informe solo
enseñaba la línea de *uncacheable*. Nuevo `ccache_read_counter` con coincidencia
**exacta** de etiqueta —necesaria porque en el formato 3.x el desglose se llama
`Direct hits:` y buscar la subcadena devolvía el parcial en vez del total— y el
resumen pasa a dar el **delta de esta build**, que es el único dato accionable,
con aviso si el acierto baja del 20%.

### Miles de subshells que no hacía falta abrir

`resolve_symbol` y `config_symbol_state` se llamaban siempre como
`"$(...)"`, así que la memoización se fijaba **dentro** de un subshell que se
perdía al salir: el padre volvía a calcular y a cachear lo mismo. Con ~800
símbolos por lista eso son miles de forks de bash para leer una clave de un array
asociativo. Variantes `*_into` con `printf -v` (que no abre subshell) para
`build_effective_arrays` y `validate_config`; `load_rename_map` invalida la caché
porque deriva de `RENAME_MAP`. Igual con `kernelrelease`, que se resolvía **tres
veces** con tres `make` y tres `|| echo` de respaldo independientes: si uno
fallaba de forma distinta, los tres reportaban un release distinto para el mismo
build.

### Índices Kconfig: la mitad de los pases y sin autoengaño

`build_kconfig_symbol_index` y `build_kconfig_type_index` eran **dos recorridos
idénticos** de los ~6.000 `Kconfig*` del árbol; ahora un `find` y un `awk` que
emite nombre TAB tipo y llena los dos mapas de una pasada. Y
`kconfig_index_invalidate` vacía **los dos** mapas: antes solo limpiaba
`KCONFIG_SYMBOL_KNOWN`, de modo que un símbolo que un parche cambiara de `bool` a
`int` conservaba su tipo viejo para siempre, y uno retirado nunca desaparecía.

`lite_missing_check` hacía, **por cada símbolo**, un `grep -rq` recursivo sobre
todo el árbol de 40k ficheros. Los tres datos que consultaba en bucle (módulos
cargados, `.config`, `EFF_DISABLE`) se leen ahora una vez y la pregunta "¿existe
este símbolo en el Kconfig?" la responde el índice que ya está en memoria.

### El self-test llevaba una versión por detrás, y por eso daba un falso positivo

El fallo que abrió esta versión (`_stype: variable sin asignar`) **no era del
motor**: era del arnés. `extract_fn` extrae del motor las funciones que cada test
ejercita, de una lista escrita a mano, y la lista se quedó en la versión
anterior. No incluía ninguna de las cinco que esta versión añadió
(`kconfig_symbol_type_into`, `resolve_symbol_into`, `tree_identity_into`,
`rollback_manifest_set_many`, `rollback_manifest_unset`).

Hasta aquí el arnés se salvaba por accidente: el motor las llamaba dentro de
`$( )`, y un subshell se traga el rc 127 de "orden no encontrada" y devuelve
cadena vacía. Al pasarlas a llamada directa —el cambio que evita miles de
subshells— el error aflora, y con `set -u` tumba el test entero. Encima faltaban
las globales que esas leen (`KCONFIG_*`, `RENAME_MAP`, `RESOLVED_SYMBOL`,
`TREE_IDENTITY`); esta última indexa por ruta, así que sin `declare -A` bash
evalúa `/tmp/.../linux-7.2.7` como expresión aritmética y devuelve la identidad
vacía.

Dos bugs **reales** salieron a la luz al arreglar esto:

- `for s in "${PATCH_SYMBOLS[@]:-}"` itera **una vez con cadena vacía** cuando el
  array está vacío, así que un parche sin símbolos metía literalmente `""` en
  `PATCH_ENABLE_ALL` y `PATCH_REBEL_ALL`. Era invisible porque
  `"${PATCH_ENABLE_ALL[*]:-}"` devuelve `""` tanto para un array vacío como para
  uno con un único elemento vacío. Ahora se salta con `continue`, con un test que
  mira el **número** de elementos, que sí distingue los dos casos.
- El test del flujo pedía `SCHED_BORE` y `MIN_BASE_SLICE_NS` los dos en
  `ENABLE`, y pasaba **por el motivo equivocado**: el tipo salía vacío (el mismo
  bug de arriba) y el `case` caía en la rama `""`. `min_base_slice_ns` es un int y
  `"=y"` no le valdría — `olddefconfig` se lo revierte —, así que va a
  `PATCH_VALUE_SYMBOLS`.

También se portablearon del arnés instalado los cuatro tests de PGO, que vivían
solo en `/usr/local/bin` y no en el repo: el rescate del store de vmlinux se
había instalado sin una sola prueba que lo cubriera.

### Fallos reales, no solo lentitud

- **`rollback_manifest_set_many` reventaba con un número impar de argumentos**:
  `kv[$((_i+1))]` con `set -u` es "variable sin asignar", que el `trap ERR`
  convierte en muerte del script. El tope pasa a ser `_i + 1 < ${#kv[@]}` y la
  pareja suelta se ignora. No lo disparaba ningún llamador actual.
- **Fuga de montaje btrfs**: un `sudo mkdir` era el único comando sin `|| true`
  de toda `create_btrfs_snapshot`; si fallaba, las dos líneas de `umount`+`rmdir`
  no llegaban a ejecutarse y el top-level se quedaba montado en
  `/tmp/cizen-snap.XXXXXX` para el resto de la sesión.
- **`get_avail_mb` podía matar la run**: si `df` fallaba, la asignación devolvía
  su rc, `trap ERR` saltaba y se moría con "Error N en línea" en vez de con el
  mensaje de espacio. Ahora satura a 0 para que sea el llamador el que aplique su
  margen.
- **El tarball se verificaba sin usarse**: `get_tarball` (`xz -t` sobre ~145 MB
  más una verificación GPG que lo descomprime entero) se llamaba siempre, aunque
  un árbol reutilizable no abre un solo byte del fichero. Se salta, y
  `extract_tarball` lo exigirá en cuanto lo necesite de verdad.
- **`rollback_manifest_set archive ""` no hacía nada**: la función descartaba el
  valor vacío, así que la clave se quedaba apuntando a un archive viejo. Ahora se
  desvincula con `rollback_manifest_unset`, y las seis claves del paquete se
  escriben en **una** operación en vez de seis read-modify-write encadenados.
- `check_build_memory` preguntaba `source_tree_reusable` hasta **cuatro veces**
  y `tmpfs_is_mounted` otras dos, revalidando directorio, Makefile, testigo e
  identidad en cada una; ahora decide una vez y reutiliza el veredicto.
- `verify_build_tree` iba a por un quinto `make` sobre el mismo árbol; compara
  contra la versión que `extract_tarball` ya tenía resuelta.

### La semilla de configuración estaba sin versionar, y no era un artefacto

`.gitignore` traía `linux-*.config` desde hacía tiempo, y con razón aparente: el
motor **escribe** `CONFIG_DIR/linux-$VERSION-cizen-v3.config` al terminar cada
build (`promote_base_config`, y también en la salida de `--check`). Por eso
parece una salida desechable.

El detalle es que ese mismo fichero es la **entrada** del build siguiente:
`choose_base_config` → `find_latest_cizen_config` elige la semilla de versión
`<=` a la objetivo y la copia a `.config`. No es un artefacto, es estado que se
arrastra hacia adelante. Con la línea entera ignorada, un `git clean -xfd` o un
clon nuevo lo borraba **en silencio**, y la siguiente build caía al fallback
`/proc/config.gz`: el config del kernel arrancado, no el afinado. El resultado es
un kernel materialmente distinto, y lo único que aparecía en pantalla era un
`warn` de "no se encontró configuración Cizen" que en una build no interactiva
pasa desapercibido.

Ahora la semilla **sí se versiona** (`.gitignore` mantiene `linux-*.config`
para configs sueltos y añade una excepción cerrada a
`kernel-update/profiles/linux-*-cizen-v3.config`, que es exactamente el patrón
que genera el motor). Dos avisos sobre lo que esto implica:

- Cada build reescribe el fichero de **su** versión, así que el árbol de trabajo
  solo se marca sucio si el config deriva de verdad. No hay ruido por mtime.
- El repo acumula una semilla por versión. Las viejas ya no sirven para nada
  (`find_latest_cizen_config` solo acepta versión `<=` a la objetivo), así que se
  pueden podar cuando molesten; conservar la última es lo habitual.

Escaneados antes de publicarlos: sin rutas de home, sin IPs ni correos, sin
claves. Lo único identificable es `CONFIG_DEFAULT_HOSTNAME="archlinux"`, que es
el default de la distro, y `CONFIG_LOCALVERSION="-cizen-v3"`, que ya era público.

### Decisiones de alcance

El salto de `get_tarball` se dejó **dentro** de un `if source_tree_reusable` en
vez de cambiar la firma de `extract_tarball`: si el árbol dejase de ser
reutilizable entre la comprobación y la extracción, se degrada a un `fatal`
explícito (tar ausente), no a una corrupción silenciosa. Y las dos sospechas de
ccache del primer párrafo se documentan **medidas y descartadas**, para que nadie
las reintente como si fueran hallazgos.

Tampoco se tocaron los defaults deliberados del perfil: Clang automático,
ThinLTO, `CIZEN_CFLAGS_OLEVEL=inherit` y la heurística de `JOBS` (que en esta
máquina da 4 = número de CPU). `CIZEN_BUILD_PRIORITY=low` se mantiene: el
default sacrifica velocidad por tener el escritorio usable, y eso es una decisión
del usuario, no un bug. Lo que se arregla es que el coste fuese **invisible**.

## [27.31.51] - 2026-09-29

Revisión a fondo de la suite (motor, UKI, manager, rollback, verify, helpers y
perfil). Todo lo que se toca aquí se verificó contra el código real, y la parte
del perfil se verificó además con `make olddefconfig` sobre linux-7.2.8.
Estado: **459 ok, 0 fail** en selftest (34 tests nuevos), `bash -n` limpio en
los 9 scripts, **0 hallazgos de nivel error en ShellCheck** en toda la suite
(incluido `tests/selftest.sh`, que arrastraba dos desde v27.31.34).

### Motor (`kernel-update.sh`)

- **Tres `abort` que no deberían abortar.** Con `set -Eeuo pipefail`, una
  degradación documentada que devuelve `1` se convierte en muerte del script:
  `ensure_optional_pahole` (sin `pahole` se perdía BTF *y* el build entero),
  `secure_boot_guided_setup` (sin `sbctl` se caía el build aunque el propio
  mensaje dijera "continuando") y la validación de `CIZEN_KERNEL_TRACK`
  inválido, que se ejecutaba **antes** de que `fatal` estuviera definida y
  moría con `fatal: command not found` (127) en vez de con su mensaje. Las tres
  ahora degradan o avisan.
- **Un fallo de UKI se anunciaba como éxito.** `sync_cizen_efi` no propagaba el
  fallo: si `cizen-uki-sync` fallaba y el camino directo tampoco, el motor
  acababa imprimiendo `✓ UKI sincronizado`. Con el Secure Boot puesto eso deja al
  sistema arrancando el UKI viejo sin decirlo. Ahora una bandera
  `CIZEN_UKI_SYNC_FAILED` marca el estado y el resumen avisa de que el UKI
  anterior sigue en pie, con el comando para relanzar.
- **El fallback `objcopy` fabricaba una UKI sin initramfs.** Las variables se
  declaraban dentro de la rama de `ukify` (sin `ukify`, `set -u` las reventaba),
  pero el fallo de fondo era peor: la preparación del initramfs estaba **dentro**
  de esa misma rama, así que el camino de `objcopy` se encontraba con
  `have_initrd=0` sin haberlo preparado nunca —UKI sin initrd justo en el equipo
  que no tiene `ukify`. Ahora el initramfs se regenera y valida antes de elegir
  constructor, y las dos vías embeben `.initrd`, `.uname` y `.ucode`; los
  temporales se limpian. Dos regresiones fijan el orden y la unicidad.
- **El fallback sin `ukify` escribía un `vmlinuz` desnudo** en el ESP, con nombre
  de UKI, y de paso avisaba de que no era una UKI. Eso no arranca. Se quitó: si
  no hay `ukify`, no se escribe nada y se dice por qué.
- `lite_missing_check` partía la lista de símbolos por espacios (con el
  `IFS` global del script, un `for` sin comillas no parte por espacios); `relaunch_with_version`
  también expandía argumentos vacíos y phantom; `cizen_uki_sign_targets_verify`
  usaba `$SBCTL_BIN` mal documentado y no comprobaba que hubiera objetivos.

### UKI, manager, rollback y verify

- `kernel-update-manager.sh`: `cmd_flip` y `cmd_backup` elegían el **primer**
  `*.efi` del ESP, que puede ser el del LTS: un `flip 7.2.8-cizen-v3` one-shot
  a otro kernel. Ahora se lee el `.uname` de cada UKI y se exige coincidencia
  exacta con el release pedido. `release_by_arg` distingue exacto > Cizen >
  distro (antes `6.18.54` devolvía el kernel en ejecución), `cmd_remove` se niega
  a borrar un kernel de distro, y el ESP se deriva con `findmnt` como el resto de
  la suite.
- `kernel-update-rollback.sh`: `resolve_archive` comparaba versiones con orden
  **alfabético** (`7.2.10` < `7.2.9`); ahora usa `sort -V`. `list_archives` se
  comía su propio código de salida.
- `kernel-update-verify.sh`: la huella de estado no incluía la versión del
  kernel, así que arrancar un kernel distinto se comía los avisos de
  inconsistencias pendientes.

### Los fallos que solo aparecen al ejecutarlo de verdad

Lo anterior se encontró leyendo el código. Lo siguiente se encontró ejecutando
la suite contra el sistema real, y **ninguno de los cuatro lo delata un mock**:
los cuatro necesitan un ESP con permisos de root o un manifiesto incompleto.

- **`sudo <cmd>` sin `-n` pide contraseña SIEMPRE**, aunque el allowlist de
  `sudoers` cubriera ese comando: el prompt se abre *antes* de que sudo mire la
  lista. `rollback --list` —que solo lee— terminaba en `Se necesita sudo para
  restaurar` y no servía en cron, en un agente ni sin terminal. Ahora hay un
  helper `_priv` (igual que en el manager): primero el comando sin privilegios,
  luego `sudo -n`, y solo al final la contraseña de verdad, que es lo que hace
  falta para **restaurar**. El gate `sudo -v` de `list_archives` desaparece por
  lo mismo.
- **`sudo -n test` no funciona, y no por culpa del allowlist**: `test` es un
  builtin de bash, sudo lo busca en `secure_path` y no lo encuentra, así que
  falla con 127 aunque `/usr/bin/test` sea ejecutable y esté en la lista. El
  manager usaba `sudo -n test -r/-d` para comprobar la existencia del ESP, o
  sea justo los ficheros que root-only no deja ni mirar. Se usa la ruta
  absoluta.
- **`set -u` + `local x` sin asignar = `unbound variable`.** `list_archives`
  declaraba `pkgpath` y solo lo asignaba si el manifiesto traía `pkgfile`; un
  manifiesto sin ese campo —uno viejo, o a medio escribir— abortaba el `list`
  entero con `pkgpath: unbound variable` en vez de decir que no hay paquete.
- **Un test puede fallar por su propia explicación.** Los comentarios que
  documentan el `sudo -n test` antiguo se leían igual que código, así que el
  grep que buscaba ese patrón los encontraba a ellos. Las regresiones de sudo
  comparan solo líneas de código.

### `cizen-uki-sync --help` regeneraba la UKI (y aquí sí se rompió el arranque)

Esto ya no es una lectura de código: pasó de verdad, ejecutando
`cizen-uki-sync --help` para ver la ayuda.

El bucle de argumentos hacía `*) break`, así que cualquier argumento
desconocido se ignoraba y **la regeneración se ligaba igual**. En un script que
reescribe el fichero del que arranca el equipo, pedir la ayuda regeneraba la UKI
sobre el ESP. Como además no había TTY para `mkinitcpio`, el initramfs no se
regeneró y la UKI nueva salió **sin `.initrd` y sin firmar** encima de la que sí
arrancaba.

Lo que evitó que el equipo quedara sin arranque fue el fichero
`.cizen-prev`, no el código: **la red de seguridad no llegó a dispararse**,
porque `uki_prev_restore` comprobaba `"${SUDO[@]}" test -f "$t.cizen-prev"` y
`test` es un builtin de bash que sudo no encuentra en `secure_path` (devuelve
127). El script creyó que no había copia y se fue sin restaurar. La UKI se
restauró a mano y quedó verificada (firmada, `.initrd` de 15.5 MB,
`.uname=7.2.8-cizen-v3`).

Tres arreglos:

- **`-h|--help` imprime la ayuda y sale; un argumento desconocido es un error**
  (rc 2). Nada cae ya en la regeneración por el camino equivocado.
- **Las nueve llamadas `sudo test` de este script usan `/usr/bin/test`.** La
  comprobación de las claves de sbctl tenía el mismo problema, y hacía que
  `sbctl_keys_present` dijera que no hay claves cuando sí las había.
- **Una UKI sin `.initrd` ya no puede sustituir a una que sí lo tiene.** Antes
  solo salía un aviso de «arranque degradado» y la escritura continuaba: un
  `mkinitcpio` fallido cambiaba un arranque con initramfs por uno sin `/init`,
  sin udev y sin keymap, y con Secure Boot sin firma directamente no arranca.
  Se necesita `CIZEN_UKI_ALLOW_DEGRADED_INITRD=1` para hacerlo a propósito.

Verificado contra el sistema real: `list` e `info` del manager sin prompt,
`flip` a un release inexistente y a un kernel de distro rechazados **sin tocar
el arranque**, `backup` completo con la UKI correcta verificada por su
`.uname`, y `rollback --list` sin TTY resolviendo el plan B por `sort -V`.

### Réplicas y helpers

- `cizen-uki-sync` y el motor tienen copias de la construcción de UKI, y se
  habían separado: `claim_preset` machacaba el initramfs propio del perfil, y
  ambas firmaban **antes** de limpiar las UKIs viejas (sbctl se negaba a firmar
  con una UKI duplicada en el ESP). La limpieza ahora va antes de firmar, en
  los dos, y `claim_preset` respeta `cizen_initramfs_path()`.
- `kernel-update-notify.sh` usaba `local` como nombre de variable (SC2316, nivel
  error) y `sched-bench.sh` lanzaba `ITERS` procesos en vez de `LOAD_N` en el
  modo paralelo, comparando luego `ITERS²` contra `ITERS`. `podar-modulos.sh`
  usaba `DONE` como estado de array, que shellcheck lee como problema.

### Perfil v5.16.1 (poda verificada)

Se aplicó el perfil entero con `scripts/config` y se normalizó con
`make olddefconfig` sobre linux-7.2.8; después se releyó el `.config` con una
réplica de `validate_config()`. Resultado: **ENABLE 35/35, CRITICAL 13/13,
DISABLE 299/299, 0 `DISABLE_WARN`**, y el kernel pasa de **2141 a 2029**
símbolos en `=y`/`=m` (**-112**).

- **Xen**: se apaga la raíz `XEN` y caen los 28 `CONFIG_XEN*`. Este host usa
  KVM/QEMU como hipervisor; no es dom0 ni guest de Xen.
- **Intel TDX**: Kaby Lake no tiene TDX, y el Kconfig lo pone `=y` por defecto.
  La raíz correcta es `INTEL_TDX_HOST` (la relación es `KVM_INTEL_TDX depends on
  INTEL_TDX_HOST`): apagar solo `KVM_INTEL_TDX` dejaba `TDX_HOST_SERVICES=**m**`
  y sacaba `ARCH_KEEP_MEMBLOCK=y`. Con la raíz correcta caen los tres y se
  resuelve el "rebel" `TDX_HOST_SERVICES` que se toleraba desde v5.12.2.
- **ftrace**: la raíz `FTRACE` y sus 12 trazadores hijos. El perfil ya pedía "sin
  profilers" pero el motor seguía compilado. *Cambio visible*: se pierde `ftrace`
  y `perf trace` (`perf record`/`perf stat` y bpftrace siguen, usan la PMU).
- `NUMA_BALANCING` (socket único) y `ZSWAP_DEFAULT_ON` (el cmdline ya pone
  `zswap.enabled=0` y aquí se usa ZRAM, no swap en disco).
- 9 símbolos que solo imprimen diagnóstico (`ACPI_DEBUG`, `PM_DEBUG`,
  `FW_LOADER_DEBUG`, `VIRTIO_DEBUG`, …) que inundaban el journal de arranque.
- `MODULE_SIG_ALL` pasa a `OPTS_ENABLE`: ya salía `=y` por `default y`, pero
  anclarlo evita depender del default de upstream para algo de Secure Boot.
- **Retirados** `PERF_GUEST_EVENTS` y `MQ_IOSCHED_ADIOS`: no existen en 7.2.8
  (0 coincidencias en todo el árbol Kconfig) y solo generaban el aviso de
  "símbolo no existente" en cada build. Igual en el frag de i915, que pedía
  `CONFIG_EXTRA_FIRMWARE_FILE`, que tampoco es un símbolo.
- `X86_FRED` a `EXPECTED_REBELS`: `KVM_INTEL` lo selecciona sin condiciones
  (`arch/x86/kvm/Kconfig:99`) y KVM es obligatorio, así que es inapagable.
- Se listan **solo las raíces**: Kconfig cascada a los hijos, y enumerarlos los
  convertía en "RETIRED / símbolo inexistente" al validarlos. Se comprobó que la
  lista de raíces da un `.config` **idéntico byte a byte** a la lista con hijos.

## [27.31.50] - 2026-09-29

Cierra los tres hallazgos que salieron al leer el log del build de
`7.2.8_cizen_v3-10` (§39 de `~/.agente/Agente.md`), más la recuperación de un
cambio que vivía **solo en la copia instalada** de `kernel-update-verify.sh`.
Estado: **425 ok, 0 fail** en selftest (los 6 tests nuevos fallan contra la
v27.31.49 instalada), `bash -n` limpio en los 4 scripts tocados.

- **El archive de rollback se poda a sí mismo.** `prepare_rollback_archive()`
  deja el archive del kernel **en ejecución** y, en la misma función, llama a
  `prune_rollback_archives()`, que excluía siempre esa release de los
  candidatos. En el build del 2026-09-29 se vio en el log, en el mismo segundo:
  `✓ Rollback preparado: …/7.2.8-cizen-v3.tar.xz (kernel en ejecución …)` y acto
  seguido `⚠ Pruning archive de rollback antiguo: 7.2.8-cizen-v3.tar.xz`. Es
  decir, la red de seguridad del build nuevo desaparecía en la pasada que la
  creaba. Ahora `prune_rollback_archives` acepta el archive a **proteger** y lo
  mete en la lista de candidatos antes que el filtro de la release en ejecución;
  los demás se siguen podando ("nunca más de uno" se mantiene).
- **El manifiesto dejaba de anunciar un archive inexistente.** Nuevo
  `rollback_manifest_unset()` (`rollback_manifest_set` no puede: con valor vacío
  hace `return 0` a propósito) y el prune llama a it cuando el fichero que borra
  es el que el manifiesto nombra. Antes `rollback.info` quedaba con
  `archive=7.2.8-cizen-v3.tar.xz` colgando y `resolve_archive()` caía al
  `*.tar.xz` más reciente, que era **7.2.7**: un rollback a otro kernel.
- **El resumen ya no anuncia un `Rollback :` inexistente**, y sí lo anuncia
  cuando el archive ya existía y se conservó (antes esa rama no lo mostraba).
- **Las opciones 1 y 2 del menú compilan** (van por `build_and_exec`, como
  comprueba el selftest) pero se rotulaban `validar config · baja/alta`: quien
  las elegía para validar se comía un build de 33 minutos. Ahora rotulan
  `validar y compilar · baja/alta`, y el README aclara que la validación sin
  compilar es responder `n` al "¿Desea continuar?" (`CHECK EXITOSO`).
- **Recuperado `kernel-update-verify.sh` desde la copia instalada** (4,7 KB por
  delante del repo desde el 2026-09-28, sin commitear: el repo era el que
  estaba atrasado). Mejora el cuerpo de la notificación: etiquetas legibles
  (`Perfil (símbolos)`, `Scheduler`…), fuera los ceros decorativos, tiempo de
  arranque con un decimal, incidencias en el título, diff de 4 líneas como
  máximo, y comparación sobre lo **mostrado** (el scheduler `?/bore → bore/bore`
  ya no se notifica como `BORE → BORE`). Verificado con `--dry-run` en vivo.
- **6 tests nuevos** (5 del prune/manifiesto y 1 de la etiqueta del menú), todos
  en rojo contra la v27.31.49 instalada.

## [27.31.49] - 2026-09-29

Dos correcciones de **presentación del resumen final**, encontradas leyendo el
log del build de `7.2.8_cizen_v3-10` (BORE + clang/THIN LTO, 32m 54s). No
tocan la compilación ni el flujo: solo lo que el motor le enseña al usuario al
terminar. Estado: **419 ok, 0 fail** en selftest (418 si se ejecuta contra la
copia instalada, que se salta el test de paridad de la unit de verify por no
tener `_repo_root`) y `bash -n` sin avisos.

- **`Paquete:` duplicaba la ruta.** Era
  `Paquete     : ${PKG:+$(basename "$PKG")}${PKG:---sin paquete (modules_install)}`.
  El segundo trozo no es un "si está vacío, muestra esto": es `${PKG:-defecto}`,
  el operador de **valor por defecto**, así que con `PKG` puesto devuelve el
  valor de `PKG` entero. Resultado en pantalla:
  `Paquete : linux-cizen-v3-7.2.8_cizen_v3-10-x86_64.pkg.tar.zst/tmp/cizen-kernel-build/linux-7.2.8/linux-cizen-v3-7.2.8_cizen_v3-10-x86_64.pkg.tar.zst`
  (el basename pegado a la ruta absoluta). Ahora es un `basename` con su rama
  de "sin paquete", igual que el resto del bloque.
- **El consejo de prioridad se contradecía a sí mismo.** El resumen tenía
  hardcodeado `(CIZEN_BUILD_PRIORITY=normal para máxima velocidad)` para todos
  los casos, así que en un build a plena prioridad salía
  `Build prio : máxima (CIZEN_BUILD_PRIORITY=normal para máxima velocidad)`.
  El consejo solo se muestra si el rótulo actual **no** es `máxima`.

Verificado con `bash -n`, con las 4 combinaciones (paquete con ruta / vacío ×
rótulo `máxima` / `low`) y con el selftest.

## [Perfil Cizen v5.15.0] - 2026-09-28

Adelgaza el perfil del OptiPlex 7050 (v5.13.0 → v5.14.0 → v5.15.0) y **audita
el fichero "Bloques para acelerar la compilación"** que se pasó: de sus tres
bloques, solo uno era aplicable. Todo verificado contra el Kconfig real de
Linux 7.2.8 y contra el hardware de la máquina. **No cambia `SCRIPT_VERSION`**
(esto es solo el perfil del host, no el motor).

**v5.14.0 — seis frentes de poda, con BTF resuelto.** 32 símbolos nuevos,
todos existentes en 7.2.8 y **los 32 ya estaban `=y`** (impacto real, no
decorativo): `SATA_MOBILE_LPM_POLICY` de `3` a `0` (el `3` es "min_power" y
provoca resets de disco al reanudar desde suspensión), `PROC_KCORE`,
`DEVMEM`, `ZRAM_BACKEND_LZ4`/`_842`, 27 símbolos MFD/PMIC/TWL/Wolfson de
hardware ausente, y `PINCTRL_AMD` (este socket nunca tendrá AMD). Bonus:
`STRICT_DEVMEM` cae sin pedirlo, porque `depends on MMU && DEVMEM`
(`lib/Kconfig.debug:1964`).

Se conservan a propósito `MFD_CORE`, `MFD_SYSCON`, `MFD_INTEL_LPSS(_PCI)` y
`REGULATOR_NETLINK_EVENTS`: son infraestructura genérica en uso, y apagarlos
rompe más de lo que ahorra.

**Decisión BTF: se conserva `CONFIG_DEBUG_INFO_BTF=y`, no se usa `FAST_BUILD`.**
`SCHED_CLASS_EXT depends on BPF_SYSCALL && BPF_JIT && DEBUG_INFO_BTF`
(`kernel/Kconfig.preempt:171`) y `scx-scheds` necesita BTF para sus
schedulers CO-RE. Quitar BTF no es ahorro de build: es quedarse sin
planificador. `--no-btf` queda como opt-out, con la condición de quitar
también `SCHED_CLASS_EXT` y aceptar perder `scx-scheds`.

**v5.15.0 — auditoría del fichero de "bloques para acelerar".**

- **BLOQUE 1 (DEBUG_INFO): no aplicado.** Además de arrastrar BTF, su parte de
  compresión es contradictoria: `DEBUG_INFO_COMPRESSED_NONE` ya es la opción
  activa y el bloque mete `NONE`, `ZLIB` y `ZSTD` a la vez en `DISABLE`,
  dejando la `choice` sin ninguna opción válida. Se recupera solo lo seguro:
  **`DEBUG_INFO_BTF_MODULES`** (depende de `DEBUG_INFO_BTF && MODULES`, así que
  puede ser `n` con BTF intacto; ni el motor ni el verificador lo miran) y
  `GDB_SCRIPTS`. Ahorra pasar `pahole` por cada uno de los 129 módulos.
- **BLOQUE 2 (70 `NET_VENDOR_*`): no aplicado, porque no ahorra nada.** Los 70
  existen y los 70 estaban `=y`, pero `--lite` es el **único** modo de la
  suite (`kernel-update.sh:54`, no existe `--no-lite`) y siempre ejecuta
  `make localmodconfig`, que ya apaga los drivers hijos: `R8169 is not set`,
  `NETXEN_NIC is not set`, y solo quedan 129 `=m` en toda la config. Poner los
  bools padre a `n` limpia texto, no compila nada menos.
- **BLOQUE 3 (MFD): ya aplicado en v5.14.0 salvo los GPIO.** Tres de los cuatro
  `GPIO_*` ya habían caído solos al apagarse sus MFD; solo quedaba
  `GPIO_CRYSTAL_COVE` (`=y`), que depende de `INTEL_SOC_PMIC`, el PMIC de
  Atom/Baytrail, y estaba activo por herencia en un Kaby Lake de escritorio.

**Aceleración de la compilación: tres palancas medidas, las tres negativas**
(así que no se aplicó ninguna). Método importante: **cccache contamina las
mediciones de tiempo**; con ccache activo, `-Os` salía *más lento* que `-O2`.
Todo se midió con `CCACHE_DISABLE=1` o contra una caché de contenido conocido.

| palanca | medición | decisión |
|---|---|---|
| `-j6` / `-j8` | −3% / **+8%** frente a `-j4` | no aplicado; 4 núcleos ya es el techo |
| `sloppiness` de ccache | +7% (ruido) | no aplicado |
| quitar DWARF (BLOQUE 1) | 20%, no 30-50% | no aplicado (costaría BTF) |
| `-Os` | ~6% | no aplicado (degrada runtime) |

- **ccache funciona bien**: una segunda pasada idéntica de `net/core/` va de
  65.133 ms a **2.642 ms** (25×). El "63,7% de aciertos" que muestra
  `ccache -s` es un promedio histórico acumulado, no un fallo. Tocar
  `include/generated/autoconf.h` **no** invalida la caché, porque ccache hashea
  contenido y no mtime; por eso `sloppiness` no aportaba nada.
- Se retiró una hipótesis falsa: `scaling_governor=powersave` a 900 MHz NO es
  cuello de botella; bajo carga la CPU sube a 3.600 MHz (EPP
  `balance_performance`).

**ccache a 20 GiB** (documentado porque es fácil de hacer mal): el motor
exporta `CCACHE_DIR="$HOME/.cache/ccache"` (`kernel-update.sh:10481`), así que
`ccache -o max_size=20G` debe escribirse ahí, no en
`~/.config/ccache/ccache.conf`. Y `CCACHE_MAX_SIZE` no es una variable de
ccache sino del motor (línea 10488), que solo aplica si se exporta.

Validación: `--check` en verde (`EXIT 0`, `ENABLE 37/37`, `DISABLE 291/291` con
0 rebeldes, `SETVAL 29/29`, `SETSTR 2/2`). Nota para la siguiente build: el
motor detecta el renombre `SCHED_BORE → SCHED_CORE` (viene del patch BORE, no
del perfil) y lo reaplica en cada ejecución; es ruido, no rotura.

## [27.31.48] - 2026-09-29

Arregla un **error de orden de definición** en el motor que abortaba el
preflight con `Error 127` antes de compilar nada, y actualiza el test del perfil
a la decisión v5.16.0 (BORE, sin sched_ext). Estado: **419 ok, 0 fail**.

- **Qué pasaba.** El motor se ejecuta línea a línea mientras bash lo lee, así que
  una llamada a nivel superior solo ve las definiciones **ya leídas**.
  `build_effective_arrays()` se invoca en el nivel superior (L1651) y su cierre
  transitivo usaba `eff_remove()` (L6459) y `apply_config_requests()` (L6665),
  definidos miles de líneas más abajo. Con un símbolo a la vez en
  `OPTS_ENABLE` y `OPTS_DISABLE` —el caso real: el motor hace
  `add_unique enable DEBUG_INFO_BTF` (`kernel-update.sh:1639`) y el perfil lo
  desactivaba para no pagar `pahole`— `add_unique()` reventaba con
  `line 1538: eff_remove: orden no encontrada` y el preflight moría con
  `Error 127`. El workaround era no listar nunca `DEBUG_INFO_BTF` en el perfil.
- **Por qué no lo veían los tests**: los dos tests de `add_unique` y del overlay
  de LTO hacen `eval "$(sed -n '/^eff_remove() {/,/^}/p' …)"` a mano, en el orden
  correcto. El fallo solo se manifiesta en la **ejecución real**, donde nada
  evalúa esas dos funciones antes de tiempo.
- **Arreglo**: se traslada el subsistema Kconfig completo (493 líneas, 12
  funciones y los cuatro `declare -A`/`KCONFIG_*_BUILT` que accompany, todos
  dentro del rango) por encima de `add_unique()`, de modo que el cierre
  transitivo de `build_effective_arrays()` esté definido antes de su llamada.
  No se mueve la llamada: `check_profile_contradictions()` se invoca en el nivel
  superior en L1678 e itera `EFF_ENABLE`/`EFF_DISABLE`/`EFF_SETVAL`/`EFF_SETSTR`,
  así que los arrays tienen que estar poblados ahí y retrasarla rompería la
  validación de contradicciones.
- **No era una sola función**: el análisis del cierre transitivo de
  `build_effective_arrays()` revela seis funciones usadas antes de existir, no una:
  `build_kconfig_symbol_index` (L6235), `kconfig_symbol_known` (L6260),
  `kconfig_auto_candidate` (L6324), `auto_resolve_effective_symbols` (L6393),
  `eff_remove` (L6459) y `apply_config_requests` (L6665). Solo `eff_remove`
  crasheaba porque las demás estaban en ramas que aquel `--check` no tomaba:
  la misma bomba, detonando por turnos.
- **Test de regresión** (`tests/selftest.sh`): comprueba el **orden real del
  fichero** —que las seis estén definidas antes de la primera invocación de
  nivel superior de `build_effective_arrays()`— en vez de evaluarlas a mano.
  Comprobado en rojo contra el motor previo (falla, y nombra las seis) y en
  verde con este.
- **Test del perfil actualizado a v5.16.0**: las expectativas seguían clavadas en
  el layout de v5.13.0 (`SCHED_CLASS_EXT` en `OPTS_ENABLE`). Ahora comprueban la
  decisión actual: `SCHED_CLASS_EXT` en `OPTS_DISABLE` (y ausente de
  `OPTS_ENABLE`), `KALLSYMS_ALL` y `SLAB_MERGE_DEFAULT` en `OPTS_DISABLE`.
  De paso el `awk` del test **ignora los comentarios**: el perfil explica por qué
  *no* lista `DEBUG_INFO_BTF` y lo cita entrecomillado, y antes eso contaba como
  si fuera una entrada de la lista.
- **Verificado**: el escenario que fallaba (perfil con `DEBUG_INFO_BTF` a la vez
  en `OPTS_DISABLE` y en el `enable` del motor) da `Error 127` con el motor
  anterior y `CHECK EXITOSO` (exit 0) con este. `shellcheck` sin deltas (41
  avisos antes y después; solo cambian los números de línea). Suite completa
  **419 ok / 0 fail** (antes 417 ok / 2 fail con este mismo perfil).

## [Perfil Cizen v5.16.0] - 2026-09-29

El usuario elige **BORE** y renuncia a sched_ext y a BTF. Sustituye a la decisión
documentada en v5.15.0, que conservaba `CONFIG_DEBUG_INFO_BTF=y` para no perder
`scx-scheds`.

- **`SCHED_CLASS_EXT`: de `OPTS_ENABLE` a `OPTS_DISABLE`.** BORE sustituye a
  `SCHED_CORE` como planificador de núcleo, y sched_ext se engancha precisamente
  a `SCHED_CORE`: son excluyentes. Con BORE no hay sched_ext que perder.
- **BTF se apaga y `DEBUG_INFO_REDUCED` se enciende.** Sigue habiendo
  información de tipo (estructuras legibles, backtraces con nombres de símbolo)
  sin pagar el `pahole`, que llegó a 6,7 GB de RSS y dejó la máquina con 338 MiB
  de RAM disponibles durante la build de v5.15.0. `DEBUG_INFO_BTF_MODULES` y
  `GDB_SCRIPTS` se mantienen apagados.
- **`DEBUG_INFO_BTF` NO se lista en `OPTS_DISABLE`, y es deliberado.** El motor
  lo activa por su cuenta (`kernel-update.sh:1639`) y listarlo aquí creaba un
  conflicto que, con el motor de v27.31.47, abortaba el preflight con `Error 127`
  (ver [27.31.48]). El apagado correcto es el opt-out del motor: `--no-btf`, o
  `CIZEN_NO_BTF=1` exportado antes de lanzarlo, que además baja el umbral de
  preflight de 12288 MB a 8192 MB. Un símbolo en `OPTS_DISABLE` que el motor
  quita por dependencia además dispara un aviso:
  `CONFIG_DEBUG_INFO_BTF no existe en esta configuración`.
- Sin cambio de `SCRIPT_VERSION` (esto es el perfil del host, no el motor).

## [27.31.47] - 2026-09-28

Arregla un flake del propio harness (`tests/selftest.sh`), no del motor ni de
`sched-bench.sh`: el test de la medición degenerada dependía de la carga del
equipo y salía en rojo durante las builds de kernel. Estado: **418 ok, 0 fail**
(era 418 ok, 1 fail de forma intermitente).

- **Qué pasaba.** El test simula "no se midió nada" de la única forma que se le
  ocurrió: meter un `sha256sum` falso en el `PATH` que hace `exit 0` sin leer.
  Pero lo que el banco cronometra es `bucle()`, que solo invoca a `sha256sum`; al
  falsearlo, lo único que queda por medir es **la latencia de arranque del
  proceso**, que aquí es de 3-4 ms. El suelo del guard es
  `SIZE_MB*ITERS/4` = `20*1/4` = **5 ms**. Es decir, el test comparaba 3-4 ms
  contra 5 ms: un margen de 1-2 ms, y con una build de kernel a 4 hilos
  (load 5,5 en 4 núcleos) la medición se pasaba el suelo, el guard no disparaba,
  el banco escribía la fila y el test se ponía rojo. En vez de una comprobación
 fallen, era una moneda al aire.
- **Por qué el suelo estaba mal calibrado para el caso**: el comentario del
  guard razona que 0,25 ms/MB son ~4 GB/s, "diez veces más rápido que lo
  físicamente posible" porque `sha256sum` va a ~400 MB/s. Ese razonamiento es
  correcto para una medición real (20 MB de SHA-256 ≈ 50 ms contra un suelo de
  5 ms, margen de sobra) y falso para el stub, que no lee nada. El suelo nunca
  se calibró contra la medición que el test realmente provoca.
- **Arreglo**: además del `sha256sum` nulo, se congela también el reloj con un
  `date` falso de salida constante. Así toda medición vale exactamente 0 ms y el
  "no pasó tiempo" que el propio guard describe en su comentario se reproduce de
  forma **exacta y determinista**, en vez de por medio de una latencia de proceso
  que depende de la carga. `date` solo se usa en `ms()` (el reloj) y en la
  cabecera `fecha` del histórico, que está *después* del guard, así que en esta
  ruta nunca se llega a la segunda.
- **La pareja positiva ya existía** y se queda: `una medición diminuta pero real
  sí se anota` (20 MB de SHA-256 de verdad contra el suelo de 5 ms) sigue
  comprobando que el guard no se ha vuelto un guard que siempre suena.
- **Verificado**: con el método viejo, tres ejecuciones seguidas bajo carga dan
  `rc=0,1` ficheros / `rc=1,1` fichero / `rc=0,1` fichero (indeterminista, que
  es justo el flake). Con el reloj fijo, las tres dan `rc=1, 0` ficheros. Selftest
  completo: 418 ok / 0 fail. `shellcheck` sin deltas en el harness (sigue el
  aviso preexistente SC1072/SC1073 de la línea 3465, documentado en §32.12).

## [27.31.46] - 2026-09-28

Fix del overlay de LTO introducido en v27.31.45: el motor se contradecía a sí
mismo y toda build con Thin/Full-LTO moría en validación. Estado: **417 ok,
0 fail** en el selftest instalado (415 + 2 tests nuevos) y **418 ok** en el
árbol del repo, verificado en rojo contra v27.31.45.

- **Causa raíz.** En `inject_build_overlay`, la rama `thin|full` del `case
  "$CIZEN_LLVM_LTO"` hacía:
  ```bash
  o="LTO_CLANG_${CIZEN_LLVM_LTO^^}"   # con CIZEN_LLVM_LTO=thin -> LTO_CLANG_THIN
  add_unique enable "$o"
  add_unique disable "LTO_CLANG_FULL"
  add_unique disable "LTO_CLANG_THIN"   # <-- la elegida, otra vez
  add_unique disable "LTO_NONE"
  ```
  `add_unique` deduplica **por array**, no entre arrays, así que el símbolo
  elegido acababa en `EFF_ENABLE` **y** en `EFF_DISABLE`. La fase de config
  (`apply_config_requests`) recorre primero las activaciones y después las
  desactivaciones, así que el `--disable` pisaba al `--enable` y la `.config`
  quedaba con `CONFIG_LTO_CLANG_THIN=n`. La validación lo detectaba
  correctamente (`[ENABLE] CONFIG_LTO_CLANG_THIN quedó n`, FATAL) y `--force` se
  negaba a continuar: la config estaba mal de verdad, el motor hacía bien en
  parar. Todo lo demás estaba bien (perfil, toolchain, BORE, PGP), por eso el
  fallo se leía como "de repente el motor se rompió".
- **Arreglo 1 (`inject_build_overlay`).** Solo se desactivan las opciones
  *alternativas*, saltando explícitamente la elegida:
  ```bash
  for _lto in LTO_CLANG_THIN LTO_CLANG_FULL LTO_NONE; do
    [ "$_lto" = "$o" ] && continue
    add_unique disable "$_lto"
    EXPECTED_REBEL_SET["$_lto"]=1
  done
  ```
  `EXPECTED_REBEL_SET` queda solo para los símbolos que se pide desactivar (los
  que Kconfig pueda conservar); el elegido se valida por la vía normal de
  `EFF_ENABLE`.
- **Arreglo 2 (`add_unique`, guarda estructural).** `EFF_ENABLE` y
  `EFF_DISABLE` pasan a ser **disjuntos**: al pedir `enable` de un símbolo que ya
  estaba en disable (y viceversa) se retira de la lista opuesta y de su índice
  `SEEN_*`; gana la última intención explícita. Así la contradicción se
  deshace en el punto donde se crea, en vez de producir una `.config` rota que
  solo se detecta treinta segundos y un `olddefconfig` después. Con esto el
  resto del overlay (OLEVEL, HZ, NTSYNC, schedulers) queda protegido por
  construcción, y `build_effective_arrays` sigue reseteando `SEEN_*` junto a
  `EFF_*`.
- **Regresión en selftest (2 tests).** Uno evalúa el bloque `case
  "$CIZEN_LLVM_LTO"` **real** del motor (extraído con `sed`, no copiado a mano)
  para `thin`, `full` y `0`, con stubs de `info`: exige que el símbolo elegido
  quede solo en `EFF_ENABLE`, que ninguna opción esté en las dos listas, y que
  la alternativa no elegida esté en `EFF_DISABLE`. El otro comprueba el
  invariante de `add_unique` (enable+disable del mismo símbolo → solo
  sobrevive el último). Comprobado que **fallan** contra el motor de v27.31.45
  y pasan con el de v27.31.46.
- **Verificación en el sistema.** Desplegado a
  `/usr/local/bin/kernel-update/{kernel-update.sh,tests/selftest.sh}` con
  `sudo install` (allowlist §3). Recompilación real de 7.2.8 con BORE +
  Thin-LTO: `✓ [ENABLE] 38/38`, `✓ [CRITICAL] 13/13`, `✓ [DISABLE] 250/250
  (0 rebeldes)`, y el diff frente al kernel en ejecución muestra
  `CONFIG_LTO_NONE y → n` + `CONFIG_LTO_CLANG_THIN n → y`.
- **Flake conocido al medir en caliente**: `banco: la medición degenerada se
  anota igual` falla si el selftest corre con la CPU saturada (p. ej. con una
  build de kernel a full tilt). `sched-bench.sh` pone suelo de 0,25 ms/MB a la
  escritura de 20 MB y sale por debajo si el `sha256sum` no llega a 5 ms. Es
  sensible a la carga **por diseño** (el propio script avisa: *"si la carga del
  equipo lo ha interrumpido, no es un fallo del banco"*) y no tiene relación con
  este cambio: comprobado que da idéntico `rc=0, 1 fichero` contra el árbol de
  v27.31.45. Con la máquina tranquila sale verde.
  **Corregido en [27.31.47]** (la causa real era que el test cronometraba la
  latencia de arranque del `sha256sum` falso contra ese mismo suelo, con un
  margen de 1-2 ms). Se deja aquí el síntoma porque es donde se cita por
  primera vez; el arreglo y su explicación están en 27.31.47.

## [27.31.45] - 2026-09-27

Mejoras de velocidad/alto rendimiento del kernel Cizen (perfil v5.13.0 + motor).
Estado: **416 ok, 0 fail** en selftest y `shellcheck` sin deltas contra v27.31.44
(precedente de la auditoría: por diff, no por número de avisos).

- **Thin-LTO por defecto.** `CIZEN_LLVM_LTO` default pasa de `0` a `thin`:
  `auto` resuelve a clang/LLVM y el overlay inyecta `CONFIG_LTO_CLANG_THIN=y`
  (los símbolos `LTO_*` positivos van a EXPECTED_REBEL_SET). Escape explícito:
  `--no-lto` / `CIZEN_LLVM_LTO=0`. Concluye el comentario de la v27.31.x que
  dejaba el LTO "solo viable con clang": ahora es el camino por defecto.
- **sched_ext reactivado (perfil v5.13.0).** `SCHED_CLASS_EXT` sale de
  `OPTS_DISABLE` (v5.3) y entra en `OPTS_ENABLE`: schedulers Linux-eBPF
  (scx_bpfland/rusty/lavd) para cambiar de scheduler en caliente sin reboot.
  Requiere BTF/BPF, ya presentes.
- **Quick wins de dieta/aislamiento (perfil v5.13.0).** `KALLSYMS_ALL=n` y
  `SLAB_MERGE_DEFAULT=n` en `OPTS_DISABLE`: menos RAM en kallsyms y caches
  slab sin fusionar (rendimiento aislado).
- **PGO/AutoFDO (opt-in, nuevo).** Motor: `CIZEN_PGO_PROFILE` → valida que el
  perfil exista antes de config, fuerza `CONFIG_AUTOFDO_CLANG` en el overlay y
  entrega el perfil al make como `CLANG_AUTOFDO_PROFILE` (fases config y build,
  incl. la reconstrucción de KCONFIG_CC_OPTS tras reevaluar LTO). Nuevo helper
  `kernel-update/pgo-collect.sh`: `perf record -F 999 -a -g` de N segundos +
  conversión con `llvm-profgen` a `.afdo`. La build PGO real (2 builds, recogida
  de perfil entre medias) se deja documentada para el usuario, no se construyó
  aquí.
- **Regresión en selftest**: default LTO-thin (no volver a gcc en silencio),
  perfil v5.13.0 (sched_ext en ENABLE, KALLSYMS/SLAB en DISABLE), plumbing PGO
  y sintaxis de motor/perfil/helper. 416 ok / 0 fail (era 412+2 nuevos
  bloques).
- **Sistema (no repo)**: `/etc/kernel/cmdline` + `intel_idle.max_cstate=4`
  (reduce latencia de wake desde los estados de reposo profundos; reversible).
  DMC i915 Kaby Lake (`kbl_dmc_ver1_04.bin`) ya estaba en el sistema: sin
  cambios de firmware. Requiere regenerar la UKI (`sudo cizen-uki-sync`) y
  reboot para aplicarse.

## [27.31.44] - 2026-09-27

Auditoría exhaustiva del flujo completo: un conjunto grande y dispar de
defectos, mayoría confirmados **en código**, no en teoría. Al pie de cada
defecto, la línea que lo demostraba. El selftest pasa de **402 a 412 ok,
0 fail**, y `shellcheck -S warning` no añade ni uno solo contra la v27.31.43
instalada.

Lista por fichero:

- **motor: `--save-auto-renames` no consumía su argumento.** El `case` metía
  `SAVE_AUTO_RENAMES=true` pero **ningún `shift`**: el parser volvía a empezar
  siempre con la misma opción y `while $#` giraba al **100% de CPU para
  siempre**. Demostrado: `timeout 3 bash kernel-update.sh --save-auto-renames`
  → 124. Ahora `shift ;;`.
- **motor: `check_installed_release_generic()` se llamaba antes de definirse.**
  Se usaba en la línea 10655 y se definía en la 10821; con `set -e` eso es
  «command not found» (127) y abortaba. Cualquier backend no-arch la tocaba.
  Movida al 10633 (< 10673).
- **motor: el fallo del sync externo abortaba antes del camino directo.** El
  motor delega en `cizen-uki-sync` y el `if !` enrojece, pero sin `|| true`
  moría con `set -e` **antes** de `ensure_cizen_efi_updated`. Ahora: si el
  sync externo falla se avisa, se reintenta por el camino directo del motor y
  solo entonces es fatal de verdad.
- **motor: `uki_backup_prev()` respaldaba en silencio.** La rama que no podía
  copiar la UKI anterior no decía nada; si fallaba, el rollback no tenía a qué
  volver. Ahora `warn "No se pudo respaldar el UKI previo en $dst."`.
- **motor: leaks en las rutas de fallo.** `build_cizen_uki` devolvía 1 sin
  borrar el `$osrel_file` temporal, y el fallo de la build lite dejaba
  `.config.cizen-lite.old`. Los dos se limpian.
- **motor + sync: `cizen_uki_cleanup_variants()` y `cleanup_uki_variants()` se
  colgaban con la clave vacía.** Si el glob no encontraba variantes, `$key`
  en blanco entraba en el `seen[]` y tiraba los `rm -f` *por defecto*: un
  `cleanup "*"` podía borrar el padre. Guard `[ -n "$key" ] || continue` en
  ambas. Y `-name` → `-iname`: mkinitcpio escribe el pkgbase en minúsculas pero
  `EFI/Linux/ARCH-LINUX-*` (getconf LONG_BIT=32) era invisible.
- **motor + sync: `sbctl` se invocaba... por nombre literal.** El `PATH`
  debería existir (§33.3), pero los dos scripts tienen la variable
  `SBCTL_BIN`/`$SBCTL_BIN` exactamente para no fiarse: ahora `sudo "$SBCTL_BIN"
  sign --save`. El sbctl real está en el allowlist de sudo, sin cambio de
  comportamiento en este host.
- **`cizen-uki-sync`: el fallback objcopy producía una UKI sin `.initrd`.** La
  preparación del initramfs vivía **solo** en la rama ukify; si caía al
  fallback (sin ukify) no había `.initrd` ni `.uname`, y `cizen_uki_verify_image`
  (que exige .initrd) te tumbaba la run ya en el ESP. Ahora la preparación es
  común y el fallback embeble `.initrd`, `.uname` (contenido = `$rel`, que es
  justo lo que sd-boot espera con el prefijo «Linux ») y `.ucode` si lo hay.
- **`cizen-uki-sync`: `--dry-run` podía abortar con fatal.** `resolve_sign_request`
  y la búsqueda de kernel/cmdline reventaban antes de imprimir nada (un `sudo
  sbctl status` tras los 5 minutos de ticket → «no detected» → fatal). En seco
  ya no se resuelve nada de eso; se imprime kernel/objetivos/signature y sale 0.
- **`kernel-update-verify.sh`: el corte por módulos solo veía `.zst`.** El
  journal aceptaba `.zst/.xz/.gz` integrales; el conteo por módulos marcaba
  como «firmware ausente» un binario `.xz/.gz`. Se igualan a las tres.
- **`kernel-update-notify.sh`: notificar a ciegas.** El `rc` de `notify-send`
  se tragaba con `2>/dev/null` en una sustitución de comando y
  independientemente del resultado se registraba como notificada. Ahora
  `return "$rc"`, y solo si `rc=0` se escribe la marca; si no, se registra el
  reintento.
- **`kernel-update-menu.sh`: `read` con stdin cerrado = bucle infinito.** En
  cron/systemd (sin TTY) `read` devuelve EOF y el `while true` giraba
  consumiendo CPU. `choice || break` sale limpiamente.
- **`podar-modulos.sh`: cierre transitivo muerto.** El `IFS=$'\n\t'` global no
  incluye el espacio, y `modules.dep` separa dependencias con espacios: el
  `for` del cierre no añadía nada, así que cualquier módulo con dependencias
  se quedaba sin el resto y el arranque podía petar. Ambos bucles parten con
  `IFS=' ' read -r -a _deparr <<< "…"`.
- **`kernel-update-rollback.sh`: archive huérfano.** Al faltar el archive del
  manifiesto (o sin manifiesto) `list_archives`/`restore_from_archive` ignoraban
  el `*.tar.xz` realmente más reciente. Nuevo `resolve_archive()`: manifiesto
  si lo hay, si no el más reciente.
- **`kernel-update-manager.sh`: flip/backup apuntaban al primer `*.efi`.** Con
  dos kernels (p. ej. LTS) `head -n1` podía fijar el oneshot al equivocado.
  `cizen_ukis()` filtra por `*${UKI_SUFFIX}*.efi`, y `cmd_flip` casa la UKI por
  pkgbase del release (`arch-${pb}[+0-9]*.efi`) cayendo a la UKI Cizen más
  reciente; el ESP se deriva como la suite (`find_esp_root`).

Regresiones: 10 tests nuevos en el selftest (uno por defecto listo para poder
volver a rojo). El motor pasa `bash -n`; los 8 ficheros tocados no añaden ni
una línea a `shellcheck -S warning` contra la copia instalada.

## [27.31.43] - 2026-09-27

El motor llamaba a `cizen-uki-sync` por nombre desnudo, así que decidía el `PATH` — y una copia vieja en `/usr/local/bin` reenvenenaba la UKI después de cada actualización.

Cuarto defecto de la misma familia (§33), encontrado al auditar por qué `sudo sbctl verify` revienta con `panic: bytes.Buffer: truncation out of range`. En producción:

```
✓ UKI escrita (atómica): /boot/EFI/Linux/arch-linux-cizen-v3.efi
✓ Firmada con sbctl: /boot/EFI/Linux/arch-linux-cizen-v3.efi
✓ Firmas sbctl verificadas (sbctl verify).
```

El último `✓` no significaba nada. Dos cosas distintas, y las dos importan:

- **La mina de §33 volvía a estar abierta.** Se borró la copia plana de
  `cizen-uki-sync`, pero el despliegue de las 20:07 la volvió a crear, y el
  defecto era de código: `sudo cizen-uki-sync` sin ruta deja que el `PATH`
  elija, así que con dos copias instaladas gana la que esté antes. La que
  envenenaba la UKI era exactamente la que `PATH` iba a elegir.
- **`sbctl verify` a secas no puede ser un veredicto ni una alarma.** Recorre
  todo el ESP, exige descubrir la ESP —que en este host no encuentra
  (§33.6)— y `go-uefi` revienta con *panic* ante cualquier PE raro que
  encuentre por el camino: su código de salida no dice nada de esta UKI. Con
  un `panic` siempre salía el `warn` de «ficheros sin firmar», que es ruido
  puro, y con `ok` da un falso seguro de que todo está bien.

Cambios:

- **`cizen_uki_sync_bin()`** (motor y `kernel-update-rollback.sh`): resuelve
  primero el **hermano** —el `cizen-uki-sync` que se despliega junto a cada
  script— y el `PATH` queda solo como recurso. El mensaje de sincronización
  dice qué binario se usó, para que no vuelva a ser una caja negra.
- **`check_prerequisites`** deja de exigir `cizen-uki-sync` en el `PATH`
  (`tools`) y lo comprueba con el mismo helper: que no esté en el `PATH` ya
  no es un «falta dependencia», con `fatal` y todo.
- **El motor se quita el `sbctl verify` global**: el veredicto de la firma lo
  dio `sbctl sign --save` (que no devuelve 0 si no firmó) más la sección
  `.sig`, dentro de `cizen-uki-sync`. Se deja una `info` con la orden de
  revisarlo a mano, sin convertir ruido en alarma.
- **`cleanup_uki_variants()`** se lleva también el *staging* de una run que
  murió antes de `uki_prev_drop()`: `<uki>.cizen-prev` y `<uki>.cizen-tmp`
  (del UKI plano y de las variantes `+N`). Son de un uso —solo viven dentro de
  la run que los crea, para poder restaurar la UKI anterior si la nueva no se
  firma— y **47 MB por UKI en el ESP**: cada run muerta dejaba una copia
  huérfana que ni el boot ni el desbarate posterior necesitan.
  `CIZEN_UKI_ROOT_PREFIX` (solo para los tests) permite ejercitarlo sin `/boot`
  sin tocar la lista de raíces ni su orden, que decide con qué grafía se firma.
- **El harness seaba a sí mismo de rojo**: `VERIFY_SRC` se calculaba como
  `$(dirname $0)/../kernel-update-verify.sh`, o sea que **asumía que vivía en
  `tests/`**. En `/usr/local/bin/kernel-update/` hay una copia plana del
  harness, y desde ahí `..` es `/usr/local/bin`: los **31 tests del verificador**
  fallaban todos sin un solo defecto detrás. Mismo disease que §33 —una
  duplicación que decide por ella misma—, y el mismo remedio ya usado aquí:
  se buscan los dos layouts, y si el verificador no está en ninguno se
  **omite el bloque diciendo por qué** en vez de sembrar 31 rojos. Un test que
  solo puede pasar en uno de los dos layouts no mide nada: entrena a ignorar
  los que fallan.
- **`*.efi.bak` en el ESP: 72 MB, dos firmados «OK» y dos pánicos.** Al
  Auditar el panic de `sbctl verify` (§ más abajo) salieron a la luz dos ficheros
  `*.efi.bak` en `EFI/Linux/`, uno por kernel. No los había puesto el motor —su
  respaldo es `<uki>.cizen-prev` y el paquete de rollback se queda en el
  tarball—: eran copias manuales. Hacían daño de dos maneras, no de una:
  - `sbctl verify` recorre la ESP entera y **go-uefi revienta con `panic`**
    (`bytes.Buffer: truncation out of range`, `authenticode/checksum.go`, que
    trunca el resto sin validar el tamaño). Medido: los `.efi.bak` dan **rc=2**,
    las UKI de verdad **rc=0**. Y `arch-linux-cizen-v3.efi.bak` mide 43
    caracteres: la ruta exacta de la traza.
  - el hook `zzz-sbctl.hook` corre **`sbctl sign-all -g` en cada transacción de
    pacman**, y `sign-all` firma lo que encuentra en la ESP: cada copia firmaba,
    y con ella una entrada más en la base de datos de Secure Boot.

  `cleanup_efi_bak_copies()` (en `cizen-uki-sync`) y
  `cizen_uki_cleanup_efi_bak()` (la copia del motor) barren `*.efi.bak` **por
  patrón global, no por kernel actual**: el `.bak` del lts sufría el mismo
  panic y la misma firma si solo se barriera el base del kernel que compila. Se
  conservan los `*.efi` a secas, con y sin contador: son los que se arrancan.
  Y de paso, la copia del motor **dejaba de barrer su propio staging** —crea
  `.cizen-prev`/`.cizen-tmp` ella misma y solo limpiaba los `+N`, así que cada
  run muerta dejaba 47 MB—: ahora barren las dos cosas, con un test que falla si
  las dos implementaciones divergen.
- **El harness firmaba en un archivo llamado `--save`.** El `sbctl` de mentira
  tomaba `${2}` como nombre de fichero, pero el motor firma con
  `sbctl sign --save <file>`: el flag va **primero**, así que el stub firmaba en
  `--save` y sembraba ese archivo en el directorio de trabajo. No era teoría: uno
  de esos archivos entró en el commit `7842a89` con once líneas `firmado`, y
  `git status` lo enseñaba como `M` porque cada ejecución del selftest lo
  re-creaba. Ahora el destino es el último argumento no-flag y lo que se
  escribe es `<file>.sig` —que es justo lo que el motor mira después—, más un
  test que falla si aparece un `--save` o si la `.sig` no existe.

Tests: 7 nuevos (resolución hermano-primero con dos `cizen-uki-sync` en el
`PATH`, *fallback* al `PATH`, llamada por ruta resuelta, prerrequisitos,
rollback, y los tres del desbarate). Selftest **392→399, 0 fail**; en **rojo**
contra la v27.31.42 instalada: **393 ok, 5 fail**.

## [27.31.42] - 2026-09-27

Un `sbctl verify` que no encuentra la ESP se estaba tomando por una UKI sin firmar — y el script llegaba a decir «el sistema no arrancaría» sobre una UKI correctamente firmada.

Tercer defecto del mismo arranque, y el más ruidoso. En producción:

```
  ✓ UKI escrita (atómica): /boot/EFI/Linux/arch-linux-cizen-v3.efi
  ✓ Firmada con sbctl: /boot/EFI/Linux/arch-linux-cizen-v3.efi
  ✗ La verificación de la firma falló: /boot/EFI/Linux/arch-linux-cizen-v3.efi
  ✗ La UKI no quedó firmada con Secure Boot ACTIVO: el sistema no arrancaría.
```

`sbctl sign` había dicho que sí. Lo que falla es el **verificador**: `sbctl verify`
exige descubrir la ESP y en este host responde `failed to find EFI system
partition` (§33.6), o sea que **nunca** verifica nada aquí. El script usaba su
código de salida como veredicto de «¿está firmado?», con lo que un
verificador inservible se convertía en un diagnóstico de firma, y el
`fatal` que lo acompaña ("el sistema no arrancaría") convertía un falso
positivo en un diagnóstico de máquina rota. Además la firma se comprueba **después**
de escribir en el ESP, así que el daño —una UKI sin firmar en el disco— ya
estaba hecho cuando se decidía abortar.

- **El veredicto es el código de salida de `sbctl sign`**, que no devuelve 0 si
  no firmó. `sbctl verify` y la sección `.sig` pasan a ser comprobaciones de
  apoyo que solo avisan: ya no pueden convertir un fichero firmado en un fallo.
- **Respaldo y reversión**: antes de sobrescribir, `uki_prev_stage()` deja una
  copia de trabajo en `<uki>.cizen-prev`; si la firma falla de verdad,
  `uki_prev_restore()` devuelve la UKI anterior —que sí arrancaba— y solo
  entonces avisa. Se borra con `uki_prev_drop()` al firmarse bien. La firma
  sigue yendo **después** de escribir a propósito: `sbctl sign --save` inscribe
  la ruta final en `/var/lib/sbctl/files.json`, y firmar el temporal de `/tmp`
  dejaría una entrada huérfana, que es justo lo que tumba `pacman -Syu` (§32.4).
  No es el `uki_backup_prev` de v27.30.0 (LinuxLocker, con fecha y desactivable):
  esto es la red de seguridad del acto.
- `cizen_uki_sign_targets_verify()` (la usa el wizard de Secure Boot para decidir
  si ofrece volver a firmar) tenía el mismo problema: con el verificador roto
  declaraba sin firmar un `systemd-boot` que sí lo estaba. Ahora basta que
  `.sig` **o** `sbctl verify` lo confirmen; como un «no» solo dispara una
  pregunta y un «sí» es inocuo, el coste de equivocarse es cero.
- `uki_has_sig_section()` (objdump) queda como **apoyo**, no como veredicto, y
  se dice por qué en el código: no se ha podido comprobar contra una UKI real de
  este equipo (`/boot` es 0077) que la versión de binutils liste siempre `.sig`,
  y una suposición errada en un guard que además restaura UKIs es peor que no
  tener guard.

Selftest: 387 -> 391. Los dos de comportamiento en rojo contra 27.31.41
(`rc_firmado=1`, el síntoma exacto de producción); los otros dos fijan que un
fallo real de `sbctl sign` sigue dando veredicto de fallo, y que el motor
replica la regla.

## [27.31.41] - 2026-09-27

`build_uki` con initramfs moría con `ucode_tmp: unbound variable` — el camino normal, el que se usa siempre.

Fix de 27.31.40, encontrado al desplegarlo: en el primer `sudo cizen-uki-sync
--sign` de este release, el script llegó a `ukify build`, escribió el UKI
unsigned en `/tmp`, y se llevó por delante **la firma, la copia al ESP y la
limpieza**:

```
Wrote unsigned /tmp/cizen-uki.8qwIGN
/usr/local/bin/cizen-uki-sync: line 744: ucode_tmp: unbound variable
```

`ucode_tmp` se declaraba con `local` **dentro** de la rama
`if [ "$have_initrd" -eq 0 ]` (el microcode standalone, de 27.31.38), pero la
limpieza `[ -n "$ucode_tmp" ] && rm -f ...` está **fuera** de ese `if`, porque
tiene que correr con y sin initramfs. Con `set -u`, usarla sin declarar es
error fatal. O sea que solo moría en la rama donde la variable **no** se
declara: la normal.

Ni `bash -n` ni shellcheck lo ven (es perfectly valid code), y el selftest
tampoco, porque su test de la UKI hace
`cizen_initramfs_prepare(){ INITRAMFS_PATH=""; return 1; }`: ejercita justo la
rama donde `ucode_tmp` sí se declara. El defecto era invisible **por la
misma razón** que el bug original de §33 — la prueba estaba construida sobre
la suposición equivocada, no sobre el camino real.

- Las cinco variables (`ucode_tmp`, `ucode_dir`, `cpuid_hex`, `ucode_bin`,
  `ucode_rev`) se declaran junto al resto de `local` de la función, **antes**
  del `if`, en el motor y en `cizen-uki-sync`.
- Tres tests nuevos, y el primero invierte el stub del test viejo: ahora
  `cizen_initramfs_prepare` **devuelve initramfs**, que es el camino que se
  ejecuta siempre. Comprueba que `build_uki` no muere, que `ukify` recibe
  `--initrd=` con el fichero validado, y que **no** se inyecta `--microcode`
  (el microcode ya va dentro del initramfs) — lo segundo fija en el camino real
  el comportamiento de 27.31.38, que hasta ahora solo se comprobaba en el
  standalone.
- Trampa al escribir ese test: la aserción buscaba `unbound variable`, y el
  mensaje de bash sale en el idioma del entorno (`variable sin asignar` en una
  sesión en español). Con el `grep` atado al inglés, **el test pasaba con el bug
  presente**. La sonda exporta ahora `LC_ALL=C` como los scripts reales, y el
  `grep` acepta las dos grafías.

Selftest: 384 -> 387. Los tres en rojo contra 27.31.40 (comprobado revirtiendo
el arreglo en una copia: `FAIL … line 120: ucode_tmp: unbound variable`).

Lo bueno: la UKI del ESP **no se tocó**. El fallo fue después de `ukify` y
antes de firmar, así que la UKI sana de §33 siguió en su sitio.

## [27.31.40] - 2026-09-27

Una sola fuente de la verdad para initramfs y UKI, y el bug que de verdad tumbaba el arranque.

Existían **dos productores de la misma UKI**: este flujo (`ukify build`) y el
preset de mkinitcpio (`default_uki=`), que dispara el hook `90-mkinitcpio-install`
al instalar el kernel y con `mkinitcpio -P`. Gana el último que corra, y como
este motor nunca llama a mkinitcpio, aquel era además el único que generaba el
initramfs: la UKI se construía **embebiendo a ciegas** el fichero que hubiera en
`/boot`. Si no había ninguno, la UKI salía sin initrd sin decir nada; si había
uno corrupto o de otra versión, se embebía igual.

- `cizen_uki_claim_preset()` deja el preset en su sitio: se le comenta el
  `*_uki=` con un marcador `#CIZEN-UKI-OWNED` y se le reactiva el `*_image=`, de
  modo que mkinitcpio sigue haciendo su parte y la UKI es de este flujo y de
  nadie más. Original a mano en `<preset>.cizen-orig`;
  `CIZEN_UKI_ALLOW_MKINITCPIO_UKI=1` lo deja como estaba.
- `cizen_initramfs_prepare()` regenera el initramfs y lo **valida** antes de
  embeberlo. `build_uki()` es la única puerta por la que pasa todo initrd que
  acabe en una UKI, así que la comprobación va ahí y no antes.
- `cizen_uki_verify_image()` revisa la UKI ya construida: la sección `.initrd`
  tiene que medir exactamente lo que mide el initramfs validado (`ukify` la
  copia tal cual), y **la sección `.ucode`, si existe, tiene que empezar por un
  cpio newc**. Sin initramfs no se aborta —el equipo arranca igual porque btrfs y
  el resto van built-in— pero se dice en voz alta que el arranque va degradado;
  `CIZEN_INITRAMFS_REQUIRED=1` lo convierte en error.

La validación del initramfs recorre la imagen **como lo hace el kernel**
(`unpack_to_rootfs()`): segmentos cpio sin comprimir, relleno NUL, un segmento
comprimido, y el requisito de alineación a 4 bytes para el salto de segmento.
Importa porque el veto anterior era **un diagnóstico equivocado**: exigía que
el *primer* cpio trajera `init`, rechazaba el cpio concatenado que `mkinitcpio`
produce con `zstd` (CPIO temprano con los `.ko.zst` y el microcode + cpio
comprimido detrás) y recetaba `COMPRESSION="cat"` como arreglo — que además no
arreglaba nada, porque con `cat` el CPIO temprano sigue ahí, sin comprimir. Como
el concatenado es el diseño normal de mkinitcpio y el kernel lo recorre sin
problema, ese "arreglo" solo quitaba el microcode del initramfs y desactivaba la
compresión, y luego se daba por bueno con el mismo validador equivocado.

Lo que sí tumbaba el arranque era la sección `.ucode`: llevaba el microcode
Intel **en crudo** (el fichero `/usr/lib/firmware/intel-ucode/06-9e-09` tal
cual) en vez de un cpio. systemd-boot le pasa al kernel `.ucode` + `.initrd`
concatenados, el primer byte del microcode no es ni NUL ni `'0'` ni una magic de
compresión, y el kernel aborta en el primer segmento con `Initramfs unpacking
failed: invalid magic at start of compressed archive` **sin desempaquetar
nada**: ni `/init`, ni udev, ni el microcode que sí venía dentro del `.initrd`.
Como btrfs va built-in, el equipo arrancaba igual y solo se notaba en una línea
del log. Pasó en los **dos** kernels, y ninguna comprobación sobre el fichero de
initramfs podía verlo, porque el `.ucode` es otra sección. De ahí el guard de
`.ucode` en `cizen_uki_verify_image()`: es el que faltaba.

`CIZEN_INITRAMFS_ALLOW_CONCAT` desaparece: con la validación correcta el
concatenado se acepta, así que el opt-in ya no significa nada.

Lo que también entra aquí y venía sin registrar (el `CHANGELOG` se había
quedado en `[27.31.36]`, así que esto cubre el trabajo de 37, 38 y 39):

- **Confirmación previa en todos los builds**: `confirm_build_after_check()` se
  invoca también en la rama de build directo, no solo en `--check`. Antes, un
  build sin `--check` preguntaba variante y compilador y se ponía a compilar sin
  haber confirmado nada con el usuario; con la pregunta previa, cancela limpio y
  sin estrenar la promoción de la config.
- **Opción 14 del menú sin UI propia**: ya no tiene su prompt de scheduler (ni
  el `inherit` que se añadió en 37.31.16) ni pasa `--no-ask-variant`; solo lanza
  el motor con `--absorb-rebels` y deja que pregunte `ask_build_prefs` tras la
  confirmación. El fallback de versión del fork lo lleva `fork_release_guard` en
  el motor. Un solo sitio donde preguntar, y el motor es el que sabe qué versión
  del fork hay.
- **Scheduler y compilador al motor** (37.31.37): `build_and_exec()` ya no
  pregunta nada; el motor expone `ask_build_prefs()`, una sola vez, en orden
  fijo variante → compilador, respetando `NO_ASK_VARIANT`, `NO_ASK_CC` y
  `CC_EXPLICIT`. La razón de fondo es que el menú preguntaba **antes** de
  validar la config y descargar fuentes: si el usuario cancelaba, se perdían
  nueve minutos de descarga.
- **`--microcode` solo en UKI standalone** (37.31.38): con initramfs, el hook
  `microcode` de mkinitcpio ya lleva el microcode dentro del CPIO, así que
  inyectarlo otra vez por `--microcode` era duplicarlo. Sin initramfs se genera
  un CPIO mínimo con el blob del CPUID de la CPU (un cpio, no el blob suelto).

Selftest: 380 -> 384. Los cuatro nuevos, todos en rojo contra 27.31.39: el
cpio concatenado **se acepta**, el concatenado con un byte de relleno en vez de
alineación a 4 **se rechaza**, el microcode crudo se rechaza, y una `.ucode` con
microcode crudo **bloquea** la escritura de la UKI. Los que fijaban la premisa
equivada (rechazar el concatenado, el opt-in) se han invertido o fuera.

## [27.31.36] - 2026-09-26

Los submenús del menú a stdout: se perdían enteros si stderr no era la terminal.

Las tres preguntas del menú (variante, compilador y la oferta de la release del
fork) imprimían su submenú y su prompt **a stderr** y devolvían la respuesta por
stdout, para poder capturarla con `$( )`. El truco funciona en una terminal
normal, pero en cuanto stderr no es la terminal el submenú **desaparece**: solo
queda el prompt pelado, sin las opciones. Y hay sitios donde eso es lo que pasa:
un log, un pane, un `| tee`, un launcher que manda stderr a `/dev/null` —el
propio `kernel-update-notify.sh` lanza el menú con `setsid … >/dev/null 2>&1`—.

- **La UI (submenú + prompt) va a stdout y la respuesta a una global**:
  `ASK_CC`, `ASK_VARIANT` y `FORK_CHOICE`. Sin `$( )` que capturar, así que el
  bloque se imprime entero, en orden, y en el mismo flujo que el resto del menú.
  Lo que sigue yendo a stderr es el error fatal de arranque, que es un error y
  no una pregunta.
- **El prompt se imprime con `printf` y no con `read -p`**: bash solo escribe el
  prompt de `read -p` si stdin es una terminal, así que tampoco dependía de eso.
- **La opción 14 preguntaba el compilador dos veces** y **descartaba la primera
  respuesta**: la llamada a `ask_cc` se había quedado antes de la oferta de la
  release del fork (v27.31.16 la intercaló en medio) y la segunda la sobreescribía
  sin avisar. Ahora se pregunta una vez, después de saber qué versión y qué
  scheduler van a compilar. También se fue el bloque de comentario duplicado que
  arrastraba esa función.

Selftest: 330 -> 331. Los tres nuevos, en rojo contra el menú de 27.31.35: el
submenú y el prompt en stdout (y stderr vacío), y la 14 llamando a `ask_cc` una
sola vez y sin `$( )`. Los que comparaban la fila del motor con igualdad exacta ahora la filtran con
`sed`: el prompt no lleva salto de línea —lo pone el Enter que teclea el
usuario— y con la entrada por tubería no hay eco, así que la fila del motor
llega pegada a él. Selector: 331 ok en el repo, 330 en el instalado (el que
falta es el que compara la unit instalada consigo mismo).

## [27.31.35] - 2026-09-26

Firmar siempre con la misma ruta: la grafía del alias meteía claves de más en la BD.

La deduplicación por inodo de 27.31.33 funciona, pero elige la grafía de la
**primera raíz** que encuentra el fichero, y el orden era `/efi`, `/boot/efi`,
`/boot`. En este ESP (vfat, `/boot` es el punto de montaje) ganaba `/boot/efi`,
así que cada sync firmaba `/boot/efi/Linux/arch-linux-cizen-v3.efi` y
`sbctl sign --save` **inscribía una clave nueva** para un fichero que ya estaba
en la BD con su grafía buena, `/boot/EFI/…`. Con las dos claves en la BD,
`sbctl sign-all` firma el mismo UKI dos veces y `sbctl verify` lo lista dos
veces. No rompe nada —en vfat las dos rutas son el mismo directorio para
siempre, así que ninguna entrada puede quedar caduca— pero es ruido que se
acumula en cada actualización de kernel.

- **Las siete listas de raíces empiezan por `/boot`** (`/boot /efi /boot/efi`) en
  los dos scripts: cuando dos rutas llevan al mismo fichero gana la primera, y
  `/boot` es el punto de montaje real, así que gana **su grafía en disco**. Es el
  mismo orden en los siete sitios (los dos `find_uki_targets`, los dos
  `cleanup_variants`, los dos `detect_esp_root` y `collect_systemd_boot_targets`)
  para que no vuelva a colarse uno por cambiar solo uno.
- **`collect_systemd_boot_targets` también deduplica por inodo**: tenía el mismo
  fallo que la UKI (el `sort -u` de su consumidor deduplica cadenas, no
  ficheros), así que el gestor también se podía firmar dos veces con dos grafías.
  El resto del comportamiento no cambia.

Selftest: 322 -> 330. Los ocho nuevos, en rojo contra el código de 27.31.34
(los siete que comprueban el orden de las raíces, más el que comprueba que el
gestor deduplica por inodo). Los dos probes funcionales de la deduplicación
siguen igual a propósito: sustituyen la lista de raíces entera por `$TEST_ROOTS`,
así que no pueden medir el orden; para eso están los siete de grep.

## [27.31.34] - 2026-09-26

v27.31.33 se llevó el sync entero por delante en producción.

Una línea del comentario nuevo se quedó sin su `#`:

```
/boot/efi y /boot/EFI son el MISMO directorio, y 'sort -u' solo deduplica
```

Como orden es **sintaxis válida** — `/boot/efi` con argumentos — así que ni
`bash -n` ni shellcheck la miran: solo revienta al ejecutarse, y lo hizo como
`line 165: /boot/efi: Is a directory` (como root) o `Permission denied` (sin
root), con el script muerto antes de su primera línea de log. Deployed y
documentado sin que nada lo viera: ni el selftest (extrae las funciones por
rango, y el comentario queda fuera), ni el test de paridad de la unit, ni el
`bash -n` de despliegue. Todo lo demás de 27.31.33 era correcto y sigue igual.

El arreglo es el `#`; lo que no debe repetirse es el agujero de verificación,
así que ahora hay **humo de verdad**: el selftest ejecuta `cizen-uki-sync
--dry-run` con un suffix inexistente (donde no puede encontrar kernel y solo
puede morir con su propio mensaje) y `kernel-update.sh` con una opción
inventada, y exige que la salida sea exactamente la esperada **sin ningún
`Is a directory`, `command not found` ni `syntax error`**. Dos tests que fallan
si una línea suelta vuelve a colarse en el flujo.

Selftest: 320 -> 322. Los dos nuevos, en rojo contra el código de 27.31.33.

## [27.31.33] - 2026-09-26

El UKI se escribía y firmaba dos veces en cada sincronización.

Al buscar objetivos se recorren `/efi`, `/boot/efi` y `/boot` porque el ESP
puede estar montado en cualquiera, pero el ESP de aquí es vfat y **vfat no
distingue mayúsculas**: `/boot/efi` y `/boot/EFI` son el mismo directorio. El
`find` de cada raíz devolvía el UKI, así que la lista tenía el mismo fichero dos
veces con dos grafías, y `sort -u` no lo arreglaba porque deduplica cadenas, no
ficheros. Resultado en la última actualización: la UKI se escribía dos veces y
`sbctl sign --save` se ejecutaba dos veces (dos líneas de log, doble firma). Las
variantes `+N` viejas también se intentaban borrar dos veces en el cleanup.

La identidad real de un fichero es el par (dispositivo, inodo), así que ahora
`find_uki_targets`, `cleanup_uki_variants`, `find_cizen_uki_targets` y
`cizen_uki_cleanup_variants` deduplican por `stat -c '%d:%i'`: el primero que
aparece gana y el resto se descarta. Sin `stat` (si no se puede leer `/boot` sin
privilegios) se degrada al nombre de antes, que es el comportamiento de siempre.
La BD de sbctl no se vio afectada: ya guardaba una sola entrada, porque las dos
grafías son el mismo fichero.

Selftest: 316 -> 320. Los cuatro nuevos, en rojo contra el código anterior
(find_uki_targets devolvía 2 objetivos y el cleanup intentaba borrar la `+3`
dos veces) y en verde con el nuevo. El falso ESP del test es un directorio real
y un alias con otra grafía al mismo sitio, como hace vfat con mayúsculas.

## [27.31.32] - 2026-09-26

La UKI con contador de intentos rompía cada `pacman -Syu`.

El boot counting de systemd-boot obliga a que el fichero del ESP se llame
`arch-linux-cizen-v3+3.efi`. Firmarlo con `sbctl sign --save` registra **ese**
nombre en `/var/lib/sbctl/files.json`, y al completar el arranque
`systemd-bless-boot` lo renombra a `arch-linux-cizen-v3.efi`: la entrada queda
apuntando a un fichero inexistente para siempre. El hook `zz-sbctl.hook` ejecuta
`sbctl sign-all -g` en toda transacción de pacman que toque `/boot`, así que
desde el primer arranque bueno cualquier actualización acababa en:

```
failed signing /boot/EFI/Linux/arch-linux-cizen-v3+3.efi: ... does not exist
error: la orden no se ejecutó correctamente
```

Los 48 paquetes se instalaban, pero pacman devolvía error y el actualizador lo
contaba como fallo. El renombrado no es algo que se pueda evitar mientras el
nombre lleve contador: es el mecanismo mismo del boot counting.

Dos cambios:

- **`CIZEN_BOOT_TRIES=0` por defecto** (antes 3) en `kernel-update.sh` y
  `cizen-uki-sync`: la UKI se escribe con su nombre plano, que no se renombra
  nunca, con lo que la entrada de sbctl sigue siendo válida. También coincide con
  el `default_uki` del preset de mkinitcpio, así que el `+3` no puede dejar al
  `bootctl`/`systemd-boot` sin UKI con el nombre esperado, y `bootctl set-oneshot`
  (menu `flip`) deja de apuntar a un `+3` que ya no está. `CIZEN_BOOT_TRIES=3`
  sigue disponible como opt-in explícito.
- **Saneado de la BD de sbctl** (`cizen_uki_sbctl_prune` en el motor,
  `sbctl_prune_stale` en `cizen-uki-sync`): antes de firmar, y también al final
  aunque no se firme, se borran con `sbctl remove-file` las entradas cuyo fichero
  ya no existe. Es la autorreparación: un huérfano heredado de cualquier build
  anterior (no solo del boot counting) vuelve a matar el hook de pacman. Es
  idempotente y solo toca entradas huérfanas, nunca las que existen.

Selftest: 310 -> 316. Los seis nuevos, en rojo contra el código anterior
(`CIZEN_BOOT_TRIES` a 3, `uki_efi_name` devolvía el `+3` por defecto, y el purge
no existía) y en verde con el nuevo. Uno de ellos es el que fija el coste del opt-in:
`CIZEN_BOOT_TRIES=3` **sigue** produciendo el nombre con contador, para que
reactivar el boot counting sea una decisión, no un cambio de comportamiento
invisible.

## [27.31.31] - 2026-09-26

El banco de schedulers se envenena solo: dos filas basura en el histórico.

En `~/.local/state/kernel-update/sched-bench-7.2.7-cizen-v3-BMQ.txt` había ocho
mediciones y dos de ellas no median nada: `iteraciones: 0` con `1 hilo: 1 ms`. La
validación de parámetros ya las rechazaba (`ITERS=0` → rc=2), así que no se
escribieron desde el banco tal como está — pero la fila está, y **`--resumen` se
la creía**: contaba ocho, sacaba la mediana de las ocho y las basura se colaban
en el número. Con dos no se notaba; con una tercera la fila entera se desplaza
para siempre, y el síntoma (una cifra que no cuadra con lo medido) no señala al
dato basura.

Dos filtros, en los dos sitios donde puede colarse:

- **Al escribir**: suelo de 0,25 ms por MB y por iteración —~4 GB/s, diez veces
  más rápido que `sha256sum` en esta máquina—, y por debajo `rc=1` **sin
  anotar**. Con `ITERS>=1` y 20 MB no se puede medir en 2 ms, así que si salta es
  que el bucle no ha corrido. Se dice qué ha pasado y se recuerda que la culpa
  suele ser del equipo cargado, no del banco.
- **Al resumir**: `--resumen` parsea el histórico por bloques (cada medición
  empieza en su línea `iteraciones:`) y solo acumula los de `iteraciones >= 1`.
  Los que no se filtran salen en una columna nueva, `desc.`, contados: lo
  que no se ve en la mediana tiene que verse en algún sitio, o el filtro es
  indistinguible de un banco que no midió.

El resumen anterior, además, era un `grep`/`sort`/`awk` por líneas sueltas y
terminaba en `${un:-?}`: un cálculo que fallaba salía como `?` en la tabla, que
es justo lo que hay que ver cuando el histórico está corrupto. Ahora el cálculo
entra y sale de una función, `resumen_datos`, con la mediana en awk y las
cifras sin inicializar a cero por el camino (un `-1` de "todavía no medido", no
un 0 que parece una medición de 0 ms).

Selftest: 307 -> 310. Los tres tests nuevos, en rojo contra el banco instalado
(`--resumen` no filtra: `5 100 ms`; la guarda no existe: rc=0 y fichero
escrito) y en verde con el nuevo. El tercero es el que evita una guarda
inútil: una medición diminuta pero **real** (20 MB, una vuelta) tiene que pasar
y anotarse, porque una guarda que siempre suena es ruido, no seguridad.

## [27.31.30] - 2026-09-26

Ruido de `ukify` al construir la UKI, visible en el build de 7.2.8 + BORE.

```
Kernel version not specified, starting autodetection 😖.
Found uname version: 7.2.8-cizen-v3
```

`ukify build` recibe ahora `--uname` con la versión del kernel (la misma que ya se
usaba para el `.osrel`), en las **dos** copias de la llamada: el motor y
`cizen-uki-sync`. Antes ukify la deducía por su cuenta, y esa deducción es una
adivinanza: recorre `/usr/lib/modules` y con varios kernels instalados puede
quedarse con otra versión, de modo que la UKI queda firmada con una sección
`.uname` que no corresponde a la imagen que contiene. Además, con `set -u` en el
camino importa que el valor venga de la ruta ya resuelta y no de otro sitio.

Ojo al flag: es `--uname`, **no** `--version`. `--version` en `ukify` imprime la
versión del programa y sale con rc=0, o sea que la UKI se daría por construida
y no existiría. El selftest fija las dos cosas: que `--uname` llegue, y que
`--version` no se cuele.

Selftest: 305 -> 307.

## [27.31.29] - 2026-09-26

Regresiones de v27.31.28, cazadas con un `--check` real contra 7.2.8 + BORE.

**El tipo de los símbolos nunca se leía.** El motor trabaja con `IFS=$'\n\t'`, así
que el `read -r sym tipo` del índice **no partía por el espacio**: las claves
quedaban siendo `"MIN_BASE_SLICE_NS int"` enteras. Ninguna búsqueda por nombre
encontraba nada, todos los símbolos parecían booleanos y `MIN_BASE_SLICE_NS`
volvía a la rama de "forzar a `=y`": el `37/38` que v27.31.28 juraba haber
arreglado. Se lee con tabulador explícito, y el selftest reproduce ya el IFS del
motor (el arnés no lo fijaba, y por eso el test pasaba con el bug dentro).

```
✗ línea 6718: ${#PATCH_VALUE_SYMBOLS[@]:-}: bad substitution
```

`${#ARR[@]:-}` no es sintaxis de bash (sí lo es `${ARR[@]:-}`, que el motor usa
en 12 sitios y es válido): el motor se caía al imprimir el resumen.

**El renombrado automático era demasiado listo.** Con la regla laxa de v27.31.28
resolvía `PERF_GUEST_EVENTS` a `PERF_EVENTS` (comparten 5 letras al principio y
`EVENTS` al final) y activaba un símbolo que el perfil no había pedido nunca. Con
`--absorb-rebels` la auditoría lo acababa **escribiendo en el perfil**, así que el
fallo era persistente. Y `PREEMPT_DYNAMIC_KSYMS` se "renombraba" a
`PREEMPT_DYNAMIC`, que es su padre, no su versión nueva. Ahora solo se resuelve
cuando es **el mismo nombre**: prefijo común de 6+ caracteres, ninguno prefijo
del otro y diferencia de 4 caracteres o menos (el final cambiado). Se rechazan a
propósito las divisiones de feature y las opciones nuevas; si no hay candidato
inequívoco se dice y se omite, que es lo correcto.

**El árbol conservado ya parcheado no invalidaba el índice.** Con el árbol
reutilizado (`BORE ya estaba aplicado`) se saltaba la invalidación, que es
justo cuando el árbol no cambia pero el proceso sí ha construido el índice antes.
Igual que en la aplicación real.

**Las claves de SETVAL/SETSTR se corrompían al renombrar.** El round-trip
`"SYM=$>valor"` con `${x%%=*>}`/`${x#*=>}` no casaba nunca (exige un `>` al final
del match, y el valor va detrás del separador): la clave acababa siendo
`"HZ=$>1000"`, el validador contaba 28 valores numéricos y 1 de texto como
inexistentes con una `.config` correcta, y `scripts/config` escribía basura real.

Resultado del mismo `--check` que fallaba, ahora sobre el árbol de verdad:

```
✓ [ENABLE]   37/37 activaciones satisfechas
✓ [CRITICAL] 13/13 críticos presentes
✓ [DISABLE]  249/249 desactivaciones resueltas
✓ [SETVAL]   28/28 valores numéricos
✓ [SETSTR]   2/2 valores de texto
• Símbolos de valor que aportan los parches (no booleanos): MIN_BASE_SLICE_NS
```

Selftest: 301 -> 305.

## [27.31.28] - 2026-09-26

La variante se pregunta antes que el compilador, y los símbolos Kconfig se
resuelven solos (con el tipo correcto y diciendo qué símbolo falla).

**1) Variante antes que compilador.** Elegías la opción, preguntaba el
compilador, y la variante se preguntaba **al final**: después de descargar
(600 MB), verificar firmas y validar la config. Nueve minutos tarde, con la
decisión ya tomada sobre un tarball que igual no servía. Ahora las dos preguntas
van juntas y en ese orden, y el motor recibe `--no-ask-variant` para no
preguntar dos veces:

```
  Variante (Enter usa el default):
    1  Vanilla (EEVDF)      4  BMQ (prjc)
    2  BORE                 5  LFBMQ (prjc)
    3  PDS (prjc)           6  MuQSS
  Variante [Enter=1]: 2
  CC [Enter=auto]: clang
```

De paso, el motor sabe la variante desde el primer segundo, así que una variante
de solo-fork se detecta **antes** de gastar la descarga. La oferta de la última
release del CachyOS, que antes solo vivía en la opción 14, se reutiliza en
todas las de build.

**2) Símbolos Kconfig: se acaba el "no existe en esta versión" falso.** El
índice de símbolos se cacheaba una sola vez por proceso, **antes** de aplicar el
parche BORE. Al validar, el motor decía:

```
WARN: ENABLE: CONFIG_SCHED_BORE no existe en esta versión; si Kconfig lo
      renombró, regístralo con: kernel-update.sh --rename SCHED_BORE=NUEVO_NOMBRE
[ENABLE] 37/38 activaciones satisfechas
```

Un símbolo que el propio parche acababa de añadir en `init/Kconfig`, con un
`--rename` que no arreglaba nada (no era un renombre: era caché). Y el `37/38`
sin decir cuál. Tres arreglos:

- **El índice se tira cuando un parche toca el árbol**, así que ve lo que el
  parche introduce.
- **Los tipos se respetan.** `PATCH_SYMBOLS` asumía que todo era booleano y
  ponía `=y` a lo que no lo era. `MIN_BASE_SLICE_NS` es un `int` (lo declara BORE
  en `kernel/Kconfig.hz`): un `=y` no es un valor válido, `olddefconfig` lo
  devuelve a su default y el `37/38` se quedaba ahí para siempre. Los no
  booleanos van ahora a su propia lista y se deja su default.
- **Renombrado automático.** Si un símbolo no existe en esta versión, se busca
  el más parecido entre los 21.718 que sí existen, y se aplica **solo** si hay
  un candidato único y claramente mejor que el segundo. Con empate no se inventa
  nada: es preferible preguntar a activar el símbolo equivocado en un kernel que
  se va a arrancar. `--save-auto-renames` los deja escritos para el siguiente.

```
INFO: Renombres detectados y aplicados por similitud en el Kconfig de 7.2.8:
        PREEMPT_DYNAMIC_KSYMS → PREEMPT_RT
```

Y el resumen de validación nombra lo que falta, en vez de solo contarlo:

```
[ENABLE]   37/38 activaciones satisfechas
WARN: [ENABLE] 1 activación(es) sin satisfacer:
              CONFIG_MIN_BASE_SLICE_NS no existe
```

## [27.31.27] - 2026-09-25

Si sudo rechaza la contraseña, el motor lo dice y qué hacer con ello, en vez de
soltar una línea de código.

Lo que pasaba: un `sudo -v` fallido abortaba el build por el ERR trap con
`Error 1 en línea 8614: sudo -v`, sin decir por qué ni qué hacer. Y como el
ticket de sudo caduca a los 5 minutos (default) mientras un build dura 20+, el
segundo prompt caía **después** de compilar, que es el peor sitio posible para
perder el trabajo por una contraseña mal tecleada.

```
WARN: sudo sin ticket vigente: sudo rechazó la contraseña de cizen tras 3 intentos
LOG:   Sí dispensan contraseña (allowlist NOPASSWD): install mount pacman swapoff swapon systemctl umount
WARN:  Y el build necesita privilegios que NO están en esa lista: chown mkdir rm
WARN:  Además, esto pedirá contraseña más adelante si hace falta: mv cp find stat test sync cat tee od tar du openssl make sbctl mokutil fuser cizen-uki-sync

INFO: Comprueba la contraseña en una terminal, sin el build de por medio:
    sudo -k; sudo -v
  Si tampoco la acepta ahí, no es cosa del motor: tu contraseña de cizen no es la
  que estás tecleando (o el teclado está en otro layout). 'passwd -S cizen' dice
  cuándo se cambió por última vez.
    passwd -S cizen
FATAL: sudo rechaza la contraseña y faltan privilegios (chown mkdir rm): no se
       puede montar el tmpfs ni instalar el kernel. Arregla la contraseña (ver
       arriba) y repite; aún no se ha compilado nada.
```

- **`preflight_sudo()`** sustituye a los tres `sudo -v` pelados. Con ticket
  vigente no pregunta nada; sin ticket y sin tty (cron, CI) lo dice en vez de
  reintentar a ciegas.
- **Sigue adelante sin ticket cuando puede.** Se enumera lo que el build necesita
  de verdad (`SUDO_OPS_REQUERIDOS`) y se contrasta con el allowlist NOPASSWD real,
  leído de `sudo -n -l` (que no necesita contraseña). Si está todo cubierto, avisa
  y continúa; si falta algo, aborta diciendo exactamente qué.
- **El mensaje tras compilar no dice "se ha perdido el build"**, porque no es
  cierto: el paquete sigue en el tmpfs y se puede instalar con `sudo pacman -U`,
  sin desmontar nada.
- La lista de cubiertos sale de los bloques `NOPASSWD:` de `sudo -l` y no del
  resto de su salida: `secure_path` y `Defaults!/usr/bin/visudo` producían
  "bin", "sbin" y "binRunas" en el aviso. También se unen las continuaciones de
  línea con las que sudo parte las listas largas, y se reconoce `NOPASSWD: ALL`.
- 12 tests nuevos con un `sudo` falso que cubre las ramas: con ticket, sin
  contraseña, con allowlist suficiente, con `NOPASSWD: ALL`, y la limpieza de la
  salida de `sudo -l`. Suite: 285 ok, 0 fail.

## [27.31.26] - 2026-09-25

El compilador se elige al vuelo en cualquier build, no solo en `variant`.

Preguntar el CC solo en la 14 dejaba a las opciones que se usan a diario —`build`,
`buildfast`, `force`, `buildbore`, `buildborefast`, `ntsync`, `cachy`— atadas al
default del motor, sin forma de forzar `gcc` o `clang` justo cuando hace falta
(un LTO de clang que falla, o comparar compiladores de verdad). Ahora al elegir
cualquiera de ellas (1, 2, 3, 4, 5, 7, 8, 14, 15, 16) aparece:

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
- También las de **check** (1 `check-upgrade` y 2 `check-upgradefast`): un check
  build compila el árbol entero, así que heredar el compilador del host sin poder
  elegirlo hacía que no sirviera para comprobar si ese compiler arranca.
- 6 tests nuevos: las 9 opciones que compilan pasan por `build_and_exec`, la 14
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
