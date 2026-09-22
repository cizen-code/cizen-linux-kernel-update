# Publicar cambios

El repo está en `~/Proyectos/cizen-linux-kernel-update/` (copia espejo). Los scripts
**operativos** viven en las rutas reales del sistema y el repo mantiene
copias para publicar.

## Estructura de fuentes

| Operativo (sistema) | Espejo en el repo |
|---|---|
| `/usr/local/bin/kernel-update/kernel-update.sh` | `kernel-update/kernel-update.sh` |
| `/usr/local/bin/kernel-update/podar-modulos.sh` | `kernel-update/podar-modulos.sh` |
| `/usr/local/bin/kernel-update/kernel-update-notify.sh` | `kernel-update/kernel-update-notify.sh` |
| `/usr/local/bin/kernel-update/kernel-update-menu.sh` | `kernel-update/kernel-update-menu.sh` |
| `/usr/local/bin/kernel-update/kernel-update-verify.sh` | `kernel-update/kernel-update-verify.sh` |
| `/usr/local/bin/kernel-update/kernel-update-rollback.sh` | `kernel-update/kernel-update-rollback.sh` |
| `/usr/local/bin/kernel-update/tests/selftest.sh` | `kernel-update/tests/selftest.sh` |
| `/usr/local/bin/kernel-update/profiles/` | `kernel-update/profiles/` |
| `/usr/local/bin/kernel-update/CHANGELOG.md` | `CHANGELOG.md` (raíz del repo) |
| `/usr/local/bin/arch-update/*.sh` + `/usr/local/bin/arch-open-terminal.sh` | `arch-update-checker/` |
| `~/.config/systemd/user/kernel-update-notify.{service,timer}` | `systemd/user/` |
| `~/.config/systemd/user/arch-update-notify.service` | `systemd/user/` |
| `/etc/systemd/system/arch-update-checker.{service,timer}` | `systemd/system/` |

## Flujo

1. Editar el script **operativo** en su ruta del sistema.
2. Copiarlo al repo: `cp /usr/local/bin/kernel-update/kernel-update.sh ~/Proyectos/cizen-linux-kernel-update/kernel-update/`
3. Commitear y subir (los scripts operativos son `root:root`, por lo que se
   suelen editar como copia en `/tmp/opencode` y desplegar con
   `sudo -n install -m 0755 -o root -g root` — `install` está en el allowlist
   de sudo):

```bash
cd ~/Proyectos/cizen-linux-kernel-update
git add -A
git commit -m "descripción del cambio"
git push
```

- Remoto **HTTPS**. Autenticación con el token de `gh` (cuenta `cizen-code`);
  la identidad del commit se inyecta one-off con
  `git -c user.name=cizen-code -c user.email=cizen-code@users.noreply.github.com`
  (no se persiste en `~/.gitconfig`).
- El `.gitignore` excluye artefactos de build, `.config` y secretos.

## Wiki

La documentación pública es este repo aparte:
`https://github.com/cizen-code/cizen-linux-kernel-update.wiki.git` (rama
`master`). Clon local: `~/Proyectos/cizen-linux-kernel-update.wiki`. Tras
publicar cambios en los scripts, actualiza las páginas afectadas y súbelas:

```bash
cd ~/Proyectos/cizen-linux-kernel-update.wiki
git add -A
git commit -m "Wiki: descripción del cambio"
git push
```

Páginas: `Home`, `kernel-update-menu`, `kernel-update-notify`,
`arch-update-checker`, `publish`.