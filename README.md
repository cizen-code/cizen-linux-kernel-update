# Kernel Update Cizen — scripts de actualización de kernel + suite Arch

Conjunto de scripts para mantener el kernel de Arch Linux actualizado y
automatizar la suite de actualización del sistema, con soporte de
notificaciones de escritorio y flujos de compilación a plena prioridad.

## Changelog

El historial de versiones vive en [CHANGELOG.md](CHANGELOG.md), no en la
cabecera del motor (desde v27.26.0). `kernel-update.sh --changelog` añade allí
el borrador del siguiente release y bumpea banner + `SCRIPT_VERSION`.

## Estructura

```
├── CHANGELOG.md                  # Historial de versiones (v27.26.0+)
├── kernel-update/                 # Flujo de compilación del kernel Cizen
│   ├── kernel-update.sh           # Motor principal (descarga→Kconfig→build→pacman→UKI)
│   ├── podar-modulos.sh           # Poda de módulos del paquete (+ --keep-list para --lite)
│   ├── kernel-update-notify.sh    # Notificador de releases nuevas de kernel.org
│   ├── kernel-update-menu.sh      # Menú interactivo de modos (check/build/fast)
│   └── profiles/                  # Perfiles + config base (linux-*-cizen-v3.config)
├── arch-update-checker/           # Suite de actualización de Arch Linux
│   ├── arch-update-checker.sh     # Comprueba repos/AUR/flatpak/noticias
│   ├── arch-apply-updates.sh      # Aplica actualizaciones
│   ├── arch-update-notify-agent.sh# Notificador de escritorio con acciones
│   ├── arch-update-notify-user.sh # Wrapper del agente para la unit de usuario
│   ├── arch-show-pending.sh       # Muestra actualizaciones pendientes
│   └── arch-open-terminal.sh      # Abre terminal con la ruta indicada (compartido)
└── systemd/
    ├── user/                      # Units de usuario
    │   ├── kernel-update-notify.service
    │   ├── kernel-update-notify.timer
    │   └── arch-update-notify.service
    └── system/                    # Units de sistema
        ├── arch-update-checker.service
        └── arch-update-checker.timer
```

## Instalación (layout en el host)

Cada suite vive en su propio subdirectorio de `/usr/local/bin/` (no mezclada
con otras herramientas):

```
/usr/local/bin/kernel-update/          # kernel-update.sh + podar-modulos.sh + notify + menu + profiles/
/usr/local/bin/arch-update/            # los 5 scripts de la suite Arch
/usr/local/bin/arch-open-terminal.sh   # helper compartido por ambas suites (plano)
```

> `podar-modulos.sh` debe instalarse ejecutable junto al resto de la suite
> (se copia igual que `kernel-update.sh`); si falta o no es ejecutable, el
> build continúa sin poda (aviso claro, nunca falla). Si el árbol aún no
> tiene `modules.dep`/`modules.alias` (p. ej. dentro de `package()` justo
> tras `modules_install` y antes del `depmod` de la receta), desde v27.27.0
> el podador los genera con `depmod` y poda igual; la poda final los
> regenera. Para podar en caliente un árbol ya instalado:
> `sudo /usr/local/bin/kernel-update/podar-modulos.sh /usr/lib/modules/<rel>` Desde v27.27.0 la poda
> física retira también del paquete los módulos compilados pero sin uso
> (si falta `modules.dep`/`modules.alias` en `package()` los genera: v1.1.0).

- Config base del kernel: `linux-<versión>-cizen-v3.config` dentro de
  `/usr/local/bin/kernel-update/profiles/` (override: `CIZEN_CONFIG_DIR`).
- Units de usuario en `~/.config/systemd/user/`; units de sistema en
  `/etc/systemd/system/`.


## Modos de kernel-update.sh

| Modo | Comando | Descripción |
|------|---------|-------------|
| check | `kernel-update.sh --check` | Valida la configuración; ofrece compilar después y elige la variante Vanilla/BORE al confirmar |
| checkfast | `CIZEN_BUILD_PRIORITY=normal kernel-update.sh --check` | Ídem a plena prioridad (misma interactividad Vanilla/BORE) |
| build | `kernel-update.sh` | Compila e instala |
| buildfast | `CIZEN_BUILD_PRIORITY=normal kernel-update.sh` | Compila a plena prioridad |
| force | `kernel-update.sh --force` | Recompila forzando |
| check-update | `kernel-update.sh --check-update` | Consulta la release estable sin modificar nada |
| list-renames | `kernel-update.sh --list-renames` | Muestra el mapa de renombres de config |
| absorb-rebels | `kernel-update.sh <ver> --absorb-rebels` | Mueve a `EXPECTED_REBELS` los símbolos que Kconfig conserva por dependencias, dejando el perfil limpio. Desde v27.25.1 el propio check lo ofrece interactivamente antes de compilar (si la auditoría reporta que Kconfig conserva desactivaciones), sin necesidad del flag |
| no-prune | `kernel-update.sh <ver> --no-prune` | Desactiva la poda de módulos (default: activada) |
| sign | `kernel-update.sh <ver> --sign` | Firma la UKI con sbctl (Secure Boot); recomendable antes de activar SB en la BIOS |
| no-sign | `kernel-update.sh <ver> --no-sign` | No firmar la UKI (no usar con Secure Boot activo) |
| changelog | `kernel-update.sh --changelog` | Bumpea banner + `SCRIPT_VERSION` y añade el borrador del siguiente release a `CHANGELOG.md` |
| hardened | `kernel-update.sh --hardened` | Auditoría de endurecimiento del kernel EN EJECUCIÓN (símbolos de /proc/config.gz + knobs sysctl vivos); sin efectos laterales |

### Prioridad de compilación y cgroups

`CIZEN_BUILD_PRIORITY=normal` (menú: opciones 2/4/8) compila a **prioridad
máxima**: se salta nice/ionice. La prioridad por defecto es `low`
(`nice -n 10` + `ionice -c 3`).

Cuando `systemd-run` está disponible, la compilación se ejecuta en un **scope
cgroup dedicado**: `CPUWeight=100,IOWeight=100` en prioridad normal y
`CPUWeight=30,IOWeight=1` en baja (da la CPU/IO al resto del sistema). Si el
probe de delegación del cgroup falla, se degrada automáticamente al wrap
nice/ionice clásico. Al terminar (éxito o fallo) se envía una notificación de
escritorio (notify-send; desactivable con `CIZEN_NOTIFY=0`).

### Recuperación de arranque (boot counting)

Desde esta versión la UKI se escribe con un **contador de intentos** de
systemd-boot (`arch-linux-cizen-v3+3.efi`): en cada boot sin completar
`boot-complete.target` resta 1; al agotarse, sd-boot marca la entrada como
`bad` y arranca el kernel previo (p. ej. el LTS) en lugar de dejarte fuera del
sistema. `systemd-bless-boot.service` (activación automática, no hay que
habilitarla) renombra la UKI a nombre plano cuando el arranque completa.
Configurable con `CIZEN_BOOT_TRIES` (0 = UKI plana, sin boot counting). El
guard de `kernel-update-verify.sh` (check GUARD) avisa en el login siguiente si
el kernel arrancado no es el último Cizen instalado.

### Firma de la UKI (Secure Boot)

Al confirmar la solicitud de compilación (build o recompilación), el motor
**sugiere firmar la UKI** con `sbctl` ("¿Firmar la UKI del kernel con sbctl?
[S/n]"), que es **dependencia requerida** (si falta, se ofrece autoinstalarlo
con pacman). Con Secure Boot
**habilitado** en el firmware la firma es obligatoria y se aplica siempre —una
UKI sin firmar no arrancaría—, por eso la sugerencia solo aparece con Secure
Boot desactivado. Control: flags `--sign` / `--no-sign` y env
`CIZEN_SIGN_UKI=yes|no|auto` (default `auto`). La firma/verificación la ejecuta
`cizen-uki-sync` (y el camino directo `sync_cizen_efi` del motor) con `sbctl
sign`/`sbctl verify` sobre cada objetivo. `kernel-update-verify.sh` cruza la
firma del último build (`sb=` en `last-build`) con el estado real de Secure Boot
(check **SECURE BOOT**) y avisa si la UKI se firmó pero SB está desactivado, o
al revés (SB activo con UKI sin firmar).

### Anclaje SHA256 de los parches

Los parches BORE (principal de CachyOS y respaldo upstream) se verifican por
**SHA256 antes de aplicarse**: si el contenido descargado no coincide con el
hash anclado en el descriptor del motor, el parche se descarta y el build se
degrada a vanilla (nunca se aplica un parche cuya procedencia no casa con el
pin). Overrides: `CIZEN_PATCH_SHA256_MAIN` / `CIZEN_PATCH_SHA256_FALLBACK`
(otro hash bueno conocido); `CIZEN_PATCH_SHA256_VERIFY=0` desactiva el pin
(último recurso). Al actualizar a una rama nueva puede ser necesario renovar
los hashes.

### Guarda OOM pre-build

Antes de descargar, el motor aborta con mensaje claro si la memoria disponible
(MemAvailable+SwapFree) o el espacio libre del tmpfs de compilación no llegan
a umbrales mínimos — el enlace con BTF es el punto más hambriento. Umbrales
configurables: `CIZEN_BUILD_MIN_MEM_MB=8192`, `CIZEN_BUILD_MIN_TMPFS_MB=6144`,
`CIZEN_BUILD_MIN_MEM_BTF_MB=12288`, `CIZEN_BUILD_MIN_TMPFS_BTF_MB=8192`.

### Verificación post-boot (kernel-update-verify.sh)

Además de PERFIL/BOOT/JOURNAL, el verificador hace en cada arranque:
- **GUARD**: avisa si arrancó un kernel que no es el último Cizen instalado
  (fallback por boot counting o selección manual del LTS).
- **FIRMWARE**: por cada módulo cargado, `modinfo -F firmware` se contrasta
  contra `/usr/lib/firmware` (acepta binarios `.zst`) y se escanean los fallos
  "Direct firmware load failed" del journal del boot actual.

El modo lite es el **ÚNICO modo de compilación** de esta suite (v27.25.4): la
config siempre se adelgaza con `make localmodconfig` antes de compilar. No
existe build "completo" ni toggle (`--no-lite`/`CIZEN_LITE` fueron eliminados).

### Poda de módulos

Tras empaquetar, `podar-modulos.sh` retira del paquete `linux-cizen-v3` los
módulos que este hardware no usa, conservando únicamente:

1. Módulos **cargados ahora** (`/proc/modules`): audio HDA, red, GPU, KVM, FS.
2. Módulos cuyo **modalias** del hardware presente (`/sys`) casa con
   `modules.alias` del árbol compilado (resolución por patrón glob).
3. Una allowlist explícita del perfil (`CORE_KEEP`): red (`e1000e`), audio,
   USB/HID/BT, sistemas de archivos (`btrfs`, `isofs`, `exfat`, `vfat`, `xfs`),
   KVM/vfio/virtio/bridge, plataforma Dell/WMI, térmica/RAPL, input/gaming
   (`joydev`, `xpad`, ...), QoS (`sch_fq`, `tcp_bbr`), nftables y diagnóstico.
4. `/etc/modules-load.d` y `CIZEN_KEEP_MODULES="mod_a,mod_b"`.
5. Cierre **transitivo de dependencias** por `modules.dep`, y regeneración de
   los índices con `depmod`.

Los símbolos `=y` (built-in: `X86_NATIVE_CPU`, `BTRFS_FS`, `DRM_I915`,
`KVM_SMM`, ...) no tienen `.ko`: la poda nunca los toca, por lo que el arranque
sin initramfs queda intacto. Configurable con `CIZEN_PRUNE_MODULES=0` (o
`--no-prune`) y `CIZEN_PRUNE_SCRIPT` (ruta alternativa al podador).

### Modo lite (único modo de compilación, v27.25.2 y ss.)

La poda sola no acorta la **compilación**: el `make` compila todos los módulos
`=m` y la poda solo evita que entren al paquete. El modo lite ataca el
tiempo de build: ejecuta `make localmodconfig` sobre la config base con el
input `/proc/modules + podar-modulos.sh --keep-list` (allowlist `CORE_KEEP` +
`/etc/modules-load.d` + `CIZEN_KEEP_MODULES`), de modo que solo se **compilan**
los módulos que este equipo usa y sus dependencias Kconfig. En el árbol 7.2.7
real pasó de 5472 a 172 módulos `=m` (el build en frío pasa de ~19 min a una
fracción). `make localmodconfig` es una herramienta oficial del kernel y no
necesita haber compilado nada (regenera `.config` y corre `olddefconfig`).

- **Único modo** (v27.25.4): no hay toggle; todos los builds son del kernel
  mínimo. La poda del paquete sigue activa siempre.
- Se ejecuta **antes** de aplicar el perfil: los requests `ENABLE`/`CRITICAL`
  (fuerzan `=y`), `DISABLE` y la auditoría/validación siguen intactos, y los
  built-in (`=y`) nunca se tocan: el arranque sin initramfs queda garantizado.
- `podar-modulos.sh --keep-list [extra,...]` imprime el allowlist estático (un
  nombre por línea) sin necesitar un árbol de módulos; es la misma fuente que la
  poda, así que build y paquete quedan coherentes (un módulo no compilado solo
  puede faltar del paquete).
- Consecuencia esperada: hardware que **no** esté cargado/declarado en el
  allowlist durante el build no tendrá módulo compilado (p. ej. una unidad
  NTFS solo si está montada o en `CIZEN_KEEP_MODULES`). Es el precio del kernel
  mínimo; si luego necesitas un módulo, basta añadirlo y recompilar.
- El base promovido tras un `check` es la versión **delgada**
  (`profiles/linux-<ver>-cizen-v3.config`), que es la que siempre se usa.

### Menú interactivo

```bash
/usr/local/bin/kernel-update/kernel-update-menu.sh          # sin versión (consulta hábil)
/usr/local/bin/kernel-update/kernel-update-menu.sh <remote> # con versión remota en el encabezado
```

Sin argumento y en terminal interactiva, el menú consulta `latest_stable` de
kernel.org (máx. 6 s); sin conexión muestra `desconocida` y remite a la opción 6
(`--check-update`).

Variables de entorno para override:

- `CIZEN_KERNEL_SCRIPT` — ruta de `kernel-update.sh`
- `CIZEN_KERNEL_MENU_SCRIPT` — ruta del menú
- `KERNEL_RELEASES_JSON_URL` — fuente de releases.json (por defecto kernel.org)

## Notificador de kernel

Compara `latest_stable` de kernel.org contra el kernel instalado y notifica
una única vez por release. Estado persistente en
`~/.local/state/kernel-update/` (log + marca anti-spam).

```bash
./kernel-update-notify.sh --dry-run  # imprime la decisión sin notificar
```

Timer de usuario (cada 6 h, persistente):

```bash
systemctl --user enable --now kernel-update-notify.timer
```

## Suite Arch Update Checker

Los scripts de la suite (instalados en `/usr/local/bin/arch-update/`) comprueban
repositorios oficiales, AUR, Flatpak y noticias de Arch Linux. Generan un resumen
en `/var/cache/arch-update-checker/pending` y notifican con acciones accionables.

La consulta de kernel.org se eliminó de esta suite (2026-09-16); el kernel lo
vigila el notificador `kernel-update-notify.sh` por separado.

`arch-apply-updates.sh` reinicia los servicios cuyos paquetes se actualizaron,
pero **nunca** los críticos/no reiniciables en caliente (dbus, gestores de
display y sesión gráfica, `getty@*`, red y subsistemas del núcleo de systemd);
esos quedan para un reinicio del sistema. El conjunto actualizado se obtiene del
`pacman.log` real (no de `pacman -Quq` previo).

## Licencia

MIT — ver [LICENSE](LICENSE).