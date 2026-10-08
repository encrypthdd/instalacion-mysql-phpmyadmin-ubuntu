#!/usr/bin/env bash
# 01-install-mysql-pma.sh
# MySQL + phpMyAdmin (Nginx + PHP-FPM) en Ubuntu Server 26.04, solo accesible por tunel SSH.
# Idempotente: se puede re-ejecutar sin romper nada ni cambiar passwords ya generadas.
#
#   sudo bash 01-install-mysql-pma.sh
#
# Variables opcionales:
#   DB_NAME=mi_base DB_USER=mi_user PMA_PORT=8080 sudo -E bash 01-install-mysql-pma.sh

set -euo pipefail

DB_NAME="${DB_NAME:-qa_db}"
DB_USER="${DB_USER:-qa_user}"
DB_COLLATE="${DB_COLLATE:-utf8mb4_0900_ai_ci}"
PMA_PORT="${PMA_PORT:-8080}"
PMA_LINK=/usr/share/phpmyadmin
CRED_FILE=/root/.qa-db-credentials

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    [OK] %s\n' "$*"; }
warn() { printf '    [!!] %s\n' "$*"; }
die()  { printf '\n\033[0;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Ejecutar como root: sudo bash $0"

# ------------------------------------------------------------ Fase 0: recon
log "Fase 0 - Reconocimiento"
. /etc/os-release
echo "    Sistema: ${PRETTY_NAME}"
[[ "${ID:-}" == "ubuntu" ]] || warn "No es Ubuntu (${ID:-?}); el script asume paquetes Debian/Ubuntu"
case "${VERSION_ID:-}" in
  26.04) ok "Ubuntu 26.04 confirmado" ;;
  *)     warn "Se esperaba 26.04, se encontro '${VERSION_ID:-?}'. Continuo igualmente." ;;
esac

MEM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
MEM_MB=$(( MEM_KB / 1024 ))
POOL_MB=$(( MEM_MB / 2 ))
(( POOL_MB < 128 )) && POOL_MB=128
DISK_AVAIL=$(df -BG --output=avail /var | tail -1 | tr -dc '0-9')
echo "    RAM: ${MEM_MB} MB  ->  innodb_buffer_pool_size = ${POOL_MB}M"
echo "    Espacio libre en /var: ${DISK_AVAIL} GB"
if (( DISK_AVAIL < 5 )); then
  warn "Menos de 5 GB libres en /var; un dump de 2 GB puede no caber"
fi

# Conflictos que hay que resolver a mano, no por sorpresa
if dpkg -l 2>/dev/null | grep -qE '^ii[[:space:]]+mariadb-server'; then
  die "MariaDB esta instalado. Instalar MySQL encima provoca conflictos. Desinstala MariaDB primero (respalda sus datos)."
fi
# Nombre del proceso que escucha en un puerto; vacio si el puerto esta libre
port_owner() {
  ss -ltnp 2>/dev/null \
    | sed -n "s/.*[:.]$1[[:space:]].*users:((\"\([^\"]*\)\".*/\1/p" | head -1 || true
}

# El paquete de Nginx trae un sitio por defecto en 0.0.0.0:80. Si algo ya ocupa
# ese puerto, el postinst no logra arrancar el servicio. Lo detectamos aqui y
# desactivamos ese sitio en la Fase 2: aqui solo hace falta 127.0.0.1:${PMA_PORT}.
PORT80=$(port_owner 80)
if [[ -n "$PORT80" ]]; then
  warn "El puerto 80 lo ocupa '${PORT80}'. No lo toco; desactivare el sitio por defecto de Nginx."
elif systemctl is-active --quiet apache2 2>/dev/null; then
  warn "Apache2 esta activo. No lo toco (Nginx usara solo 127.0.0.1:${PMA_PORT})."
fi

# Un Nginx ya escuchando en PMA_PORT es el de una ejecucion anterior de este
# script, no un conflicto: si no se distingue, el script se aborta a si mismo y
# deja de ser idempotente. Cualquier otro proceso si es un conflicto real.
PMA_OWNER=$(port_owner "$PMA_PORT")
if [[ "$PMA_OWNER" == "nginx" ]]; then
  ok "El puerto ${PMA_PORT} ya lo sirve Nginx (ejecucion previa); se reaprovecha"
elif [[ -n "$PMA_OWNER" ]]; then
  die "El puerto ${PMA_PORT} lo ocupa '${PMA_OWNER}'. Elige otro con PMA_PORT=xxxx."
elif ss -ltn 2>/dev/null | grep -qE "[:.]${PMA_PORT}[[:space:]]"; then
  die "El puerto ${PMA_PORT} esta en uso por un proceso que no pude identificar. Revisa: ss -ltnp | grep ${PMA_PORT}"
fi
ok "Sin conflictos bloqueantes"

log "Actualizando indice de paquetes"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
ok "apt actualizado"

# --------------------------------------------------------------- Fase 1: MySQL
log "Fase 1 - MySQL"
if ! dpkg -l mysql-server 2>/dev/null | grep -q '^ii'; then
  apt-get install -y -qq mysql-server
  ok "mysql-server instalado"
else
  ok "mysql-server ya estaba instalado"
fi
# pv da la barra de progreso al importar el dump en 02-import-dump.sh
apt-get install -y -qq pv >/dev/null 2>&1 || warn "No pude instalar pv (solo afecta la barra de progreso)"
systemctl enable --now mysql >/dev/null 2>&1 || true
systemctl is-active --quiet mysql || die "mysql no arranca. Revisa: journalctl -u mysql -n 50"
MYSQL_VER=$(mysqld --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
ok "MySQL ${MYSQL_VER} corriendo"

# Credenciales: se generan UNA vez y se reutilizan en cada re-ejecucion
if [[ -f "$CRED_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$CRED_FILE"
  ok "Reutilizando credenciales de ${CRED_FILE}"
else
  DB_PASS=$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 24)
  PMA_PASS=$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 24)
  umask 077
  {
    echo "# Credenciales generadas por 01-install-mysql-pma.sh - NO versionar"
    echo "DB_NAME='${DB_NAME}'"
    echo "DB_USER='${DB_USER}'"
    echo "DB_PASS='${DB_PASS}'"
    echo "PMA_PASS='${PMA_PASS}'"
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  ok "Credenciales nuevas guardadas en ${CRED_FILE} (chmod 600)"
fi

log "Endureciendo MySQL (equivalente no-interactivo de mysql_secure_installation)"
# DROP USER en lugar de DELETE FROM mysql.user: manipular esa tabla a mano esta
# desaconsejado en MySQL 8 y deja cachés de privilegios inconsistentes.
DROPS=$(mysql --protocol=socket -N -B -e "
  SELECT CONCAT('DROP USER ', QUOTE(user), '@', QUOTE(host), ';')
  FROM mysql.user
  WHERE user = ''
     OR (user = 'root' AND host NOT IN ('localhost','127.0.0.1','::1'));")
if [[ -n "$DROPS" ]]; then
  printf '%s\n' "$DROPS" | mysql --protocol=socket
  printf '%s\n' "$DROPS" | sed 's/^/        /'
  ok "Usuarios anonimos / root remoto eliminados"
else
  ok "No habia usuarios anonimos ni root remoto"
fi
mysql --protocol=socket -e "DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;"
ok "Base 'test' eliminada"
ok "root@localhost sigue usando auth_socket (se administra con 'sudo mysql')"

log "Creando base '${DB_NAME}' y usuario '${DB_USER}'"
mysql --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE ${DB_COLLATE};
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
ok "Base y usuario listos (collation ${DB_COLLATE})"

log "Aplicando tuning para importar dumps grandes"
# innodb_log_file_size esta deprecado desde 8.0.30 en favor de innodb_redo_log_capacity
REDO_DIRECTIVE="innodb_redo_log_capacity   = 512M"
MY_MAJOR=${MYSQL_VER%%.*}
MY_REST=${MYSQL_VER#*.}
MY_MINOR=${MY_REST%%.*}
MY_PATCH=${MYSQL_VER##*.}
if (( MY_MAJOR == 8 && MY_MINOR == 0 && MY_PATCH < 30 )); then
  REDO_DIRECTIVE="innodb_log_file_size       = 256M"
fi
TUNING=/etc/mysql/mysql.conf.d/zz-qa-tuning.cnf
cat > "$TUNING" <<CNF
# Generado por 01-install-mysql-pma.sh - tuning para importar dumps grandes
[mysqld]
max_allowed_packet         = 512M
innodb_buffer_pool_size    = ${POOL_MB}M
${REDO_DIRECTIVE}
bind-address               = 127.0.0.1

[mysqldump]
max_allowed_packet         = 512M

# Ojo: NO usar [client] aqui. Ese grupo lo leen TODOS los clientes y
# mysqlcheck/mysqladmin no aceptan max_allowed_packet: abortan con
# "unknown variable". Solo los grupos de los binarios que si la soportan.
[mysql]
max_allowed_packet         = 512M
CNF
if mysqld --validate-config >/dev/null 2>&1; then
  ok "Config validada por 'mysqld --validate-config'"
else
  mysqld --validate-config 2>&1 | head -10
  rm -f "$TUNING"
  die "La config de tuning es invalida para MySQL ${MYSQL_VER}; se revirtio el archivo."
fi
systemctl restart mysql
systemctl is-active --quiet mysql || die "mysql no arranca tras el tuning. journalctl -u mysql -n 50"
ok "MySQL reiniciado con el tuning aplicado"

if ss -ltn | grep -E '[:.]3306[[:space:]]' | grep -qv '127.0.0.1'; then
  warn "3306 parece escuchar fuera de localhost. Revisa bind-address."
else
  ok "3306 escucha solo en 127.0.0.1"
fi

# ---------------------------------------------------- Fase 2: Nginx + PHP-FPM
log "Fase 2 - Nginx + PHP-FPM"
apt-get install -y -qq nginx php-fpm php-mysql php-mbstring php-zip php-gd php-curl php-xml php-bz2 php-intl

# El sitio por defecto escucha en 0.0.0.0:80 y es lo unico que impide arrancar
# Nginx cuando Apache (u otro servidor) ya tiene ese puerto tomado. phpMyAdmin
# se sirve solo en 127.0.0.1:${PMA_PORT}, asi que el default no hace falta.
if [[ -e /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
  ok "Sitio por defecto de Nginx (0.0.0.0:80) desactivado"
fi

PHPVER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
systemctl enable --now "php${PHPVER}-fpm" >/dev/null 2>&1 || true
FPM_SOCK=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1)
if [[ -z "$FPM_SOCK" ]]; then
  die "No encuentro el socket de PHP-FPM en /run/php/. Revisa: systemctl status php${PHPVER}-fpm"
fi
ok "PHP ${PHPVER}, socket ${FPM_SOCK}"

# Overrides en conf.d en lugar de editar php.ini: idempotente y facil de revertir
cat > "/etc/php/${PHPVER}/fpm/conf.d/99-phpmyadmin.ini" <<'INI'
; Generado por 01-install-mysql-pma.sh
upload_max_filesize = 512M
post_max_size       = 512M
memory_limit        = 512M
max_execution_time  = 600
max_input_time      = 600
INI
systemctl restart "php${PHPVER}-fpm"
ok "Limites de PHP ampliados"

# -------------------------------------------- Fase 3: phpMyAdmin (tarball)
log "Fase 3 - phpMyAdmin"
PMA_VER=$(curl -fsSL --max-time 20 https://www.phpmyadmin.net/home_page/version.json 2>/dev/null \
          | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][^"]*\)".*/\1/p' | head -1 || true)
if [[ -z "$PMA_VER" ]]; then
  PMA_VER=5.2.3
  warn "No pude consultar la ultima version; uso el fallback ${PMA_VER}"
else
  ok "Ultima version estable: ${PMA_VER}"
fi
PMA_TARGET="/usr/share/phpmyadmin-${PMA_VER}"

if [[ ! -f "${PMA_TARGET}/index.php" ]]; then
  TMPD=$(mktemp -d)
  trap 'rm -rf "$TMPD"' EXIT
  BASE="https://files.phpmyadmin.net/phpMyAdmin/${PMA_VER}"
  TAR="phpMyAdmin-${PMA_VER}-all-languages.tar.gz"
  curl -fsSL --max-time 300 -o "${TMPD}/${TAR}"        "${BASE}/${TAR}"
  curl -fsSL --max-time 60  -o "${TMPD}/${TAR}.sha256" "${BASE}/${TAR}.sha256"
  if ! ( cd "$TMPD" && sha256sum -c "${TAR}.sha256" >/dev/null 2>&1 ); then
    die "El SHA256 del tarball de phpMyAdmin NO coincide. Descarga abortada."
  fi
  ok "Tarball descargado y SHA256 verificado"
  mkdir -p "$PMA_TARGET"
  tar xzf "${TMPD}/${TAR}" -C "$PMA_TARGET" --strip-components=1
  ok "Extraido en ${PMA_TARGET}"
else
  ok "phpMyAdmin ${PMA_VER} ya estaba extraido"
fi

# Si root tiene una umask restrictiva (077), 'mkdir -p' crea el directorio en
# 0700 y www-data no puede ni atravesarlo: Nginx responde 404 y el log dice
# 'stat() ... failed (13: Permission denied)'. Los permisos se fijan explicitos
# y no se dejan a la umask heredada. Va antes de escribir config.inc.php y de
# tocar tmp/, cuyos permisos mas estrictos se aplican despues.
chmod 755 "$PMA_TARGET"
find "$PMA_TARGET" -type d -exec chmod 755 {} +
find "$PMA_TARGET" -type f -exec chmod 644 {} +

if ! sudo -u www-data test -r "${PMA_TARGET}/index.php"; then
  die "www-data no puede leer ${PMA_TARGET}/index.php. Revisa los permisos de /usr/share y de ${PMA_TARGET}."
fi
ok "www-data puede leer el arbol de phpMyAdmin (permisos 755/644)"

ln -sfn "$PMA_TARGET" "$PMA_LINK"
mkdir -p "${PMA_TARGET}/tmp" /var/lib/phpmyadmin/upload
chown -R www-data:www-data "${PMA_TARGET}/tmp" /var/lib/phpmyadmin
chmod 700 "${PMA_TARGET}/tmp"
ok "Symlink ${PMA_LINK} -> ${PMA_TARGET}"

# Configuration storage: marcadores, historial SQL, relaciones entre tablas
mysql --protocol=socket < "${PMA_TARGET}/sql/create_tables.sql"
mysql --protocol=socket <<SQL
CREATE USER IF NOT EXISTS 'pma'@'localhost' IDENTIFIED BY '${PMA_PASS}';
ALTER USER 'pma'@'localhost' IDENTIFIED BY '${PMA_PASS}';
GRANT SELECT, INSERT, UPDATE, DELETE ON \`phpmyadmin\`.* TO 'pma'@'localhost';
FLUSH PRIVILEGES;
SQL
ok "Base 'phpmyadmin' y usuario de control 'pma' configurados"

BLOWFISH=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)
cat > "${PMA_TARGET}/config.inc.php" <<PHPCONF
<?php
/* Generado por 01-install-mysql-pma.sh */
declare(strict_types=1);

\$cfg['blowfish_secret'] = '${BLOWFISH}';

\$i = 1;
\$cfg['Servers'][\$i]['auth_type']        = 'cookie';
\$cfg['Servers'][\$i]['host']             = '127.0.0.1';
\$cfg['Servers'][\$i]['compress']         = false;
\$cfg['Servers'][\$i]['AllowNoPassword']  = false;
\$cfg['Servers'][\$i]['AllowRoot']        = false;

/* Configuration storage */
\$cfg['Servers'][\$i]['controluser']      = 'pma';
\$cfg['Servers'][\$i]['controlpass']      = '${PMA_PASS}';
\$cfg['Servers'][\$i]['pmadb']            = 'phpmyadmin';
\$cfg['Servers'][\$i]['bookmarktable']    = 'pma__bookmark';
\$cfg['Servers'][\$i]['relation']         = 'pma__relation';
\$cfg['Servers'][\$i]['table_info']       = 'pma__table_info';
\$cfg['Servers'][\$i]['table_coords']     = 'pma__table_coords';
\$cfg['Servers'][\$i]['pdf_pages']        = 'pma__pdf_pages';
\$cfg['Servers'][\$i]['column_info']      = 'pma__column_info';
\$cfg['Servers'][\$i]['history']          = 'pma__history';
\$cfg['Servers'][\$i]['table_uiprefs']    = 'pma__table_uiprefs';
\$cfg['Servers'][\$i]['tracking']         = 'pma__tracking';
\$cfg['Servers'][\$i]['userconfig']       = 'pma__userconfig';
\$cfg['Servers'][\$i]['recent']           = 'pma__recent';
\$cfg['Servers'][\$i]['favorite']         = 'pma__favorite';
\$cfg['Servers'][\$i]['users']            = 'pma__users';
\$cfg['Servers'][\$i]['usergroups']       = 'pma__usergroups';
\$cfg['Servers'][\$i]['navigationhiding'] = 'pma__navigationhiding';
\$cfg['Servers'][\$i]['savedsearches']    = 'pma__savedsearches';
\$cfg['Servers'][\$i]['central_columns']  = 'pma__central_columns';
\$cfg['Servers'][\$i]['designer_settings']= 'pma__designer_settings';
\$cfg['Servers'][\$i]['export_templates'] = 'pma__export_templates';

\$cfg['TempDir']   = '${PMA_TARGET}/tmp';
\$cfg['UploadDir'] = '/var/lib/phpmyadmin/upload';
PHPCONF
chown root:www-data "${PMA_TARGET}/config.inc.php"
chmod 640 "${PMA_TARGET}/config.inc.php"
ok "config.inc.php escrito (blowfish_secret de 32 bytes, solo-lectura para www-data)"

log "Configurando vhost de Nginx (solo 127.0.0.1:${PMA_PORT})"
cat > /etc/nginx/sites-available/phpmyadmin <<NGINX
# Generado por 01-install-mysql-pma.sh
server {
    listen 127.0.0.1:${PMA_PORT};
    server_name localhost;

    root ${PMA_LINK};
    index index.php index.html;

    access_log /var/log/nginx/pma-access.log;
    error_log  /var/log/nginx/pma-error.log;

    client_max_body_size 512M;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${FPM_SOCK};
        fastcgi_read_timeout 600;
    }

    location ~ ^/(libraries|setup/lib|templates|vendor|sql|examples)/ { deny all; }
    location ~ /\.  { deny all; }
}
NGINX
ln -sfn /etc/nginx/sites-available/phpmyadmin /etc/nginx/sites-enabled/phpmyadmin
# Capturamos la salida antes de filtrarla: con 'set -o pipefail' un 'nginx -t'
# fallido dentro de una tuberia abortaria el script sin mensaje propio.
NGINX_TEST=$(nginx -t 2>&1 || true)
printf '%s\n' "$NGINX_TEST" | sed 's/^/    /'
nginx -t >/dev/null 2>&1 || die "La config de Nginx es invalida (ver arriba)"

# 'reload' falla si el servicio no quedo activo al instalar el paquete, que es
# justo lo que pasa cuando el :80 del sitio por defecto estaba ocupado.
if systemctl is-active --quiet nginx; then
  systemctl reload nginx
  ok "Nginx recargado"
else
  if ! systemctl start nginx; then
    journalctl -u nginx -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || true
    die "Nginx no arranca (ver log arriba). Si es 'Address already in use', otro proceso tiene el puerto."
  fi
  ok "Nginx arrancado"
fi
systemctl enable nginx >/dev/null 2>&1 || true

log "Comprobacion local de phpMyAdmin"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PMA_PORT}/index.php" || echo 000)
case "$HTTP" in
  200) ok "phpMyAdmin responde 200 en 127.0.0.1:${PMA_PORT}" ;;
  502) die "502 Bad Gateway: fastcgi_pass apunta mal. Socket detectado: ${FPM_SOCK}" ;;
  *)   warn "Respuesta HTTP ${HTTP}. Revisa /var/log/nginx/pma-error.log" ;;
esac

# ---------------------------------------------------------------------- Resumen
echo ""
echo "===================== INSTALACION COMPLETA ====================="
echo ""
echo "  MySQL         ${MYSQL_VER}  (escucha solo en 127.0.0.1:3306)"
echo "  PHP           ${PHPVER}  socket ${FPM_SOCK}"
echo "  phpMyAdmin    ${PMA_VER}  en ${PMA_TARGET}"
echo "  Nginx         escucha solo en 127.0.0.1:${PMA_PORT}"
echo ""
echo "  Base de datos ${DB_NAME}"
echo "  Usuario       ${DB_USER}"
echo "  Password      ver ${CRED_FILE}   ->   sudo cat ${CRED_FILE}"
echo ""
echo "  PARA ENTRAR, desde tu maquina Windows (PowerShell):"
echo ""
echo "      ssh -L ${PMA_PORT}:127.0.0.1:${PMA_PORT} USUARIO@IP_DEL_SERVIDOR"
echo ""
echo "  y con esa sesion abierta, en el navegador:  http://localhost:${PMA_PORT}"
echo ""
echo "  SIGUIENTE PASO: cargar el dump"
echo "      sudo bash 02-import-dump.sh /ruta/al/dump.sql"
echo ""
echo "================================================================"
echo ""
