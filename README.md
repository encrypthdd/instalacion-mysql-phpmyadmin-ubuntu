# QA: MySQL + phpMyAdmin en Ubuntu Server 26.04

Scripts idempotentes que montan MySQL y phpMyAdmin (Nginx + PHP-FPM) en el servidor de QA
y cargan un dump existente. phpMyAdmin queda accesible **solo por túnel SSH**: nada
escucha fuera de `127.0.0.1`, así que no hay superficie expuesta a la red.

| Script | Qué hace |
|---|---|
| `01-install-mysql-pma.sh` | Instala y asegura MySQL, Nginx, PHP-FPM y phpMyAdmin. Genera las passwords. |
| `02-import-dump.sh` | Inspecciona el dump, avisa de los problemas típicos, y lo carga. |
| `03-verify.sh` | Verificación end-to-end. Solo lee. Devuelve exit 1 si algo falla. |

Los tres son **re-ejecutables**: no duplican nada y no regeneran passwords ya creadas.

---

## Paso 1 — Copiar los scripts al servidor

Desde PowerShell en Windows:

```powershell
cd C:\ruta\a\qa-mysql-setup
scp 01-install-mysql-pma.sh 02-import-dump.sh 03-verify.sh USUARIO@IP_DEL_SERVIDOR:~/
```

## Paso 2 — Instalar

```bash
ssh USUARIO@IP_DEL_SERVIDOR
sudo bash 01-install-mysql-pma.sh
```

Tarda unos minutos. Al terminar imprime un resumen con la base, el usuario y dónde
están las passwords. Por defecto crea la base `qa_db` y el usuario `qa_user`; para
cambiarlo:

```bash
DB_NAME=mi_base DB_USER=mi_user sudo -E bash 01-install-mysql-pma.sh
```

Las credenciales generadas quedan en `/root/.qa-db-credentials` (chmod 600):

```bash
sudo cat /root/.qa-db-credentials
```

**El script se detiene solo** si detecta MariaDB instalado o el puerto 8080 ocupado —
son conflictos que conviene resolver a mano, no por sorpresa.

## Paso 3 — Subir el dump

Desde PowerShell. Para un archivo de 100 MB–2 GB conviene algo reanudable:

```powershell
# Si tienes rsync (p.ej. vía Git Bash o WSL) — reanuda si se corta la conexión
rsync -avP C:\ruta\al\dump.sql USUARIO@IP_DEL_SERVIDOR:~/

# Alternativa que ya tienes seguro
scp C:\ruta\al\dump.sql USUARIO@IP_DEL_SERVIDOR:~/
```

## Paso 4 — Inspeccionar antes de cargar (recomendado)

Esto no modifica nada y te dice de antemano con qué te vas a topar:

```bash
DRY_RUN=1 sudo -E bash 02-import-dump.sh ~/dump.sql
```

Reporta número de tablas, si el dump trae su propio `CREATE DATABASE`, si hay `DEFINER=`,
triggers, y fechas `0000-00-00`.

## Paso 5 — Cargar el dump

```bash
sudo bash 02-import-dump.sh ~/dump.sql
```

Qué hace por ti:

- Carga como `root@localhost` por socket, lo que **evita el fallo de `DEFINER=`** que
  aparece al importar vistas y triggers con un usuario sin privilegios.
- Detecta si el dump trae su propia base y, si es otra distinta, le da permisos a tu
  usuario de QA para que la vea en phpMyAdmin.
- Pide confirmación escrita (`SI`) si la base destino ya tiene tablas.
- `innodb_flush_log_at_trx_commit=2` mientras carga, y lo **restaura al salir** incluso
  si el script se interrumpe.
- Registra todo error en `/var/log/qa-import-errors.log` y compara el número de tablas
  del dump con las que acabaron en la base.
- Acepta `.sql`, `.sql.gz`, `.bz2` y `.zst` sin descomprimir a disco.

Si la carga falla por fechas `0000-00-00` (habitual en dumps de MySQL 5.7):

```bash
RELAX_SQLMODE=1 sudo -E bash 02-import-dump.sh ~/dump.sql
```

> Para un dump grande, lánzalo dentro de `tmux` o `screen` — así un corte de SSH no mata
> la importación a medio camino.

## Paso 6 — Verificar

```bash
sudo bash 03-verify.sh
```

Comprueba servicios activos **y habilitados al arranque**, que ni 3306 ni 8080 escuchen
fuera de localhost, que no haya usuarios MySQL remotos ni anónimos, que phpMyAdmin
devuelva 200, que el `blowfish_secret` tenga 32 bytes, que el usuario de QA pueda
conectarse por TCP, el recuento de tablas/vistas/triggers/rutinas, la homogeneidad de
collations y `mysqlcheck`.

Si la base tiene **collations mezcladas a propósito** —lo normal cuando el dump viene de
una producción que ya las tiene así— acéptalo explícitamente para que ese hallazgo
conocido no deje el script en fallo permanente y te haga ignorar su salida:

```bash
ALLOW_MIXED_COLLATION=1 sudo -E bash 03-verify.sh
```

Sigue imprimiendo el desglose por collation como `[info]`, pero no cuenta como fallo.
Ojo con el `-E` de `sudo`: sin él la variable no llega al script.

## Paso 7 — Entrar a phpMyAdmin

Desde PowerShell en Windows, abre el túnel y **déjalo abierto**:

```powershell
ssh -L 8080:127.0.0.1:8080 USUARIO@IP_DEL_SERVIDOR
```

Con esa sesión viva, abre en el navegador:

```
http://localhost:8080
```

Entra con `qa_user` y la password de `/root/.qa-db-credentials`. El login como `root`
está deliberadamente bloqueado.

---

## Problemas frecuentes

| Síntoma | Causa y solución |
|---|---|
| `502 Bad Gateway` | `fastcgi_pass` apunta a un socket que no existe. El script lo autodetecta; si cambias la versión de PHP, re-ejecuta `01`. |
| La web no carga por el túnel | El túnel se cerró. Mantén la sesión `ssh -L` abierta mientras uses phpMyAdmin. |
| `Illegal mix of collations` en un JOIN | El dump trae varias collations. Si QA debe reproducir producción, déjalas y usa `ALLOW_MIXED_COLLATION=1`; si quieres unificarlas, convierte las tablas con `CONVERT TO CHARACTER SET utf8mb4 COLLATE ...` y `foreign_key_checks=0` (el comando lo imprime `03-verify.sh`). |
| `Access denied for user 'qa_user'` | Lee la password real con `sudo cat /root/.qa-db-credentials`. |
| Faltan tablas tras importar | Revisa `/var/log/qa-import-errors.log`. La carga usa `--force`, así que continúa tras cada error y los acumula todos ahí. |
| Importar desde la web falla con archivos grandes | Para >100 MB usa siempre `02-import-dump.sh`, no el formulario del navegador. |

## Mantenimiento

phpMyAdmin se instala desde el tarball oficial (verificando SHA256), no por `apt`, así
que **`apt upgrade` no lo actualiza**. Para subirlo de versión, vuelve a ejecutar
`01-install-mysql-pma.sh`: detecta la última estable, la instala en un directorio
versionado y mueve el symlink `/usr/share/phpmyadmin`. Las passwords no cambian.
