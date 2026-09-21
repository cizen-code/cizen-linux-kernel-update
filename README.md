# Kernel Update Cizen — scripts de actualización de kernel + suite Arch

Conjunto de scripts para mantener el kernel de Arch Linux actualizado y
automatizar la suite de actualización del sistema, con soporte de
notificaciones de escritorio y flujos de compilación a plena prioridad.

## Estructura

```
├── kernel-update/                 # Flujo de compilación del kernel Cizen
│   ├── kernel-update.sh           # Motor principal (descarga→Kconfig→build→pacman→UKI)
│   ├── podar-modulos.sh           # Poda de módulos del paquete (v27.25.0)
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
> build continúa sin poda (aviso claro, nunca falla).

- Config base del kernel: `linux-<versión>-cizen-v3.config` dentro de
  `/usr/local/bin/kernel-update/profiles/` (override: `CIZEN_CONFIG_DIR`).
- Units de usuario en `~/.config/systemd/user/`; units de sistema en
  `/etc/systemd/system/`.


## Modos de kernel-update.sh

| Modo | Comando | Descripción |
|------|---------|-------------|
| check | `kernel-update.sh --check` | Valida la configuración; ofrece compilar después |
| checkfast | `CIZEN_BUILD_PRIORITY=normal kernel-update.sh --check` | Ídem a plena prioridad |
| build | `kernel-update.sh` | Compila e instala |
| buildfast | `CIZEN_BUILD_PRIORITY=normal kernel-update.sh` | Compila a plena prioridad |
| force | `kernel-update.sh --force` | Recompila forzando |
| check-update | `kernel-update.sh --check-update` | Consulta la release estable sin modificar nada |
| list-renames | `kernel-update.sh --list-renames` | Muestra el mapa de renombres de config |
| absorb-rebels | `kernel-update.sh <ver> --absorb-rebels` | Mueve a `EXPECTED_REBELS` los símbolos que Kconfig conserva por dependencias, dejando el perfil limpio. Desde v27.25.1 el propio check lo ofrece interactivamente antes de compilar (si la auditoría reporta que Kconfig conserva desactivaciones), sin necesidad del flag |
| no-prune | `kernel-update.sh <ver> --no-prune` | Desactiva la poda de módulos (default: activada) |

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

### Menú interactivo

```bash
/usr/local/bin/kernel-update/kernel-update-menu.sh          # sin versión (consulta hábil)
/usr/local/bin/kernel-update/kernel-update-menu.sh <remote> # con versión remota en el encabezado
```

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