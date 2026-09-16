# Kernel Update Cizen — scripts de actualización de kernel + suite Arch

Conjunto de scripts para mantener el kernel de Arch Linux actualizado y
automatizar la suite de actualización del sistema, con soporte de
notificaciones de escritorio y flujos de compilación a plena prioridad.

## Estructura

```
├── kernel-update/                 # Flujo de compilación del kernel Cizen
│   ├── kernel-update.sh           # Motor principal (descarga→Kconfig→build→pacman→UKI)
│   ├── kernel-update-notify.sh    # Notificador de releases nuevas de kernel.org
│   ├── kernel-update-menu.sh      # Menú interactivo de modos (check/build/fast)
│   └── profiles/                  # Perfiles de configuración del kernel
├── arch-update-checker/           # Suite de actualización de Arch Linux
│   ├── arch-update-checker.sh     # Comprueba repos/AUR/flatpak/noticias
│   ├── arch-apply-updates.sh      # Aplica actualizaciones
│   ├── arch-update-notify-agent.sh# Notificador de escritorio con acciones
│   ├── arch-show-pending.sh       # Muestra actualizaciones pendientes
│   └── arch-open-terminal.sh      # Abre terminal con la ruta indicada
└── systemd/user/                  # Units de usuario (timer 6h + oneshot)
    ├── kernel-update-notify.service
    └── kernel-update-notify.timer
```

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

### Menú interactivo

```bash
~/kernel-update-menu.sh          # sin versión (consulta hábil)
~/kernel-update-menu.sh <remote> # con versión remota en el encabezado
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

Los scripts de `/usr/local/bin/` comprueban repositorios oficiales, AUR,
Flatpak y noticias de Arch Linux. Generan un resumen en
`/var/cache/arch-update-checker/pending` y notifican con acciones accionables.

La consulta de kernel.org se eliminó de esta suite (2026-09-16); el kernel lo
vigila el notificador `kernel-update-notify.sh` por separado.

## Licencia

MIT — ver [LICENSE](LICENSE).