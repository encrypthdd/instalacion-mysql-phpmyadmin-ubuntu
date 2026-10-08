#!/usr/bin/env bash
# 03-verify.sh
# Verificacion end-to-end del QA: servicios, aislamiento de red, integridad de datos.
# Solo lee: no modifica nada. Devuelve exit 1 si algo falla.
#
#   sudo bash 03-verify.sh
#   DB_NAME=otra_base sudo -E bash 03-verify.sh
#
# Opciones por variable de entorno:
#   ALLOW_MIXED_COLLATION=1   la base tiene collations mezcladas a proposito
#                             (asi viene el dump de produccion): se informa
#                             pero no cuenta como fallo.

set -uo pipefail

CRED_FILE=/root/.qa-db-credentials
PMA_PORT="${PMA_PORT:-8080}"
ALLOW_MIXED_COLLATION="${ALLOW_MIXED_COLLATION:-0}"
DB_NAME_OVERRIDE="${DB_NAME:-}"
FAILS=0

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
pass() { printf '    \033[0;32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '    \033[0;31m[FAIL]\033[0m %s\n' "$*"; FAILS=$((FAILS+1)); }
info() { printf '    [info] %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Ejecutar como root: sudo bash $0"; exit 1; }
[[ -f "$CRED_FILE" ]] || { echo "No existe $CRED_FILE. Ejecuta 01-install-mysql-pma.sh primero."; exit 1; }
# shellcheck disable=SC1090
. "$CRED_FILE"
[[ -n "$DB_NAME_OVERRIDE" ]] && DB_NAME="$DB_NAME_OVERRIDE"

# --------------------------------------------------------- 1. Servicios
log "1. Servicios activos y habilitados en el arranque"
PHPVER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
for SVC in mysql nginx "php${PHPVER}-fpm"; do
  if systemctl is-active --quiet "$SVC"; then pass "$SVC activo"; else fail "$SVC NO activo"; fi
  if systemctl is-enabled --quiet "$SVC" 2>/dev/null; then
    pass "$SVC habilitado al arranque"
  else
    fail "$SVC NO sobrevive un reboot (systemctl enable $SVC)"
  fi
done

# ------------------------------------------- 2. Aislamiento de red (seguridad)
log "2. Aislamiento de red: nada debe escuchar fuera de localhost"
check_local_only() {
  local port="$1" label="$2" lines
  lines=$(ss -ltnH 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print $4}')
  if [[ -z "$lines" ]]; then
    fail "${label}: nadie escucha en el puerto ${port}"
    return
  fi
  local bad=0
  while read -r addr; do
    case "$addr" in
      127.0.0.1:*|\[::1\]:*) ;;
      *) bad=1; info "escucha expuesta: $addr" ;;
    esac
  done <<< "$lines"
  if (( bad == 0 )); then
    pass "${label} solo en localhost ($(printf '%s' "$lines" | tr '\n' ' '))"
  else
    fail "${label} EXPUESTO fuera de localhost"
  fi
}
check_local_only 3306 "MySQL"
check_local_only "$PMA_PORT" "phpMyAdmin/Nginx"

if mysql --protocol=socket -N -B -e \
     "SELECT COUNT(*) FROM mysql.user WHERE host NOT IN ('localhost','127.0.0.1','::1');" \
     2>/dev/null | grep -q '^0$'; then
  pass "Ningun usuario MySQL acepta conexiones remotas"
else
  fail "Hay usuarios MySQL con host remoto:"
  mysql --protocol=socket -e \
    "SELECT user, host FROM mysql.user WHERE host NOT IN ('localhost','127.0.0.1','::1');" 2>/dev/null
fi

if mysql --protocol=socket -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE user='';" 2>/dev/null | grep -q '^0$'; then
  pass "Sin usuarios anonimos"
else
  fail "Existen usuarios anonimos en mysql.user"
fi

# ----------------------------------------------- 3. phpMyAdmin responde
log "3. phpMyAdmin"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PMA_PORT}/index.php" 2>/dev/null || echo 000)

# Un codigo distinto de 200 tiene varias causas con el mismo sintoma; en vez de
# mandar a "revisa el log", imprimimos lo que distingue una de otra:
# si index.php no es legible el 404 lo da Nginx (try_files), y si si lo es el
# 404 viene de PHP/phpMyAdmin y se ve en el cuerpo de la respuesta.
pma_diag() {
  local root
  root=$(readlink -f /usr/share/phpmyadmin 2>/dev/null)
  printf '        document root : %s\n' "${root:-<symlink roto>}"
  # Hay que probarlo COMO www-data: un index.php 644 puede ser ilegible para
  # Nginx si un directorio del camino no tiene el bit x (404 + 'Permission denied').
  if ! [[ -e "${root}/index.php" ]]; then
    printf '        index.php     : ausente -> la extraccion del tarball fallo\n'
  elif sudo -u www-data test -r "${root}/index.php" 2>/dev/null; then
    printf '        index.php     : www-data lo lee (%s) -> el codigo lo genera PHP, no Nginx\n' \
           "$(stat -c '%A %U:%G' "${root}/index.php")"
  else
    printf '        index.php     : existe (%s) pero www-data NO lo puede leer\n' \
           "$(stat -c '%A %U:%G' "${root}/index.php")"
    printf '        permisos ruta : %s\n' "$(namei -m "${root}/index.php" 2>/dev/null | tr '\n' ' ')"
    printf '        arreglo       : sudo chmod 755 %s\n' "$root"
  fi
  printf '        socket PHP-FPM: %s\n' "$(ls /run/php/php*-fpm.sock 2>/dev/null | tr '\n' ' ')"
  printf '        cuerpo de la respuesta (primeras 5 lineas):\n'
  curl -s "http://127.0.0.1:${PMA_PORT}/index.php" 2>/dev/null | head -5 | sed 's/^/          /'
  printf '        pma-error.log (ultimas 3):\n'
  tail -3 /var/log/nginx/pma-error.log 2>/dev/null | sed 's/^/          /'
}

case "$HTTP" in
  200) pass "HTTP 200 en 127.0.0.1:${PMA_PORT}" ;;
  30*) pass "HTTP ${HTTP} (redireccion al login, normal en phpMyAdmin)" ;;
  000) fail "Sin respuesta en 127.0.0.1:${PMA_PORT}"; pma_diag ;;
  *)   fail "HTTP ${HTTP} en 127.0.0.1:${PMA_PORT}"; pma_diag ;;
esac

PMA_CFG=$(readlink -f /usr/share/phpmyadmin 2>/dev/null)/config.inc.php
if [[ -f "$PMA_CFG" ]]; then
  BF=$(grep -oE "blowfish_secret'\][[:space:]]*=[[:space:]]*'[^']*'" "$PMA_CFG" | sed "s/.*'\(.*\)'/\1/")
  if [[ ${#BF} -eq 32 ]]; then
    pass "blowfish_secret tiene 32 bytes"
  else
    fail "blowfish_secret tiene ${#BF} bytes (deben ser 32)"
  fi
  # El patron debe incluir el ']' de cierre del indice: la linea real es
  #   $cfg['Servers'][$i]['AllowRoot']  = false;
  if grep -qE "\['AllowRoot'\][[:space:]]*=[[:space:]]*false" "$PMA_CFG"; then
    pass "Login como root bloqueado en phpMyAdmin"
  else
    fail "phpMyAdmin permite entrar como root"
  fi
else
  fail "No encuentro $PMA_CFG"
fi

# ------------------------------------------- 4. Login del usuario de QA
log "4. Credenciales del usuario de QA"
if mysql -h 127.0.0.1 -u "$DB_USER" -p"$DB_PASS" -N -B -e "SELECT 1;" >/dev/null 2>&1; then
  pass "${DB_USER} puede conectarse por TCP a 127.0.0.1 (la via que usa phpMyAdmin)"
else
  fail "${DB_USER} NO puede conectarse. Revisa $CRED_FILE"
fi

# ----------------------------------------------- 5. Integridad de los datos
log "5. Integridad de los datos en '${DB_NAME}'"
EXISTS=$(mysql --protocol=socket -N -B -e \
  "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='${DB_NAME}';" 2>/dev/null)
if [[ "$EXISTS" != "1" ]]; then
  fail "La base '${DB_NAME}' no existe"
else
  pass "La base '${DB_NAME}' existe"
  mysql --protocol=socket -e "
    SELECT
      (SELECT COUNT(*) FROM information_schema.tables
         WHERE table_schema='${DB_NAME}' AND table_type='BASE TABLE') AS tablas,
      (SELECT COUNT(*) FROM information_schema.views    WHERE table_schema='${DB_NAME}')   AS vistas,
      (SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema='${DB_NAME}') AS triggers,
      (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema='${DB_NAME}') AS rutinas,
      (SELECT ROUND(SUM(data_length+index_length)/1024/1024,1) FROM information_schema.tables
         WHERE table_schema='${DB_NAME}') AS mb_total;" 2>/dev/null

  NT=$(mysql --protocol=socket -N -B -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_type='BASE TABLE';" 2>/dev/null)
  if (( NT > 0 )); then
    pass "${NT} tablas presentes"
  else
    fail "La base esta vacia: el dump no se cargo (ejecuta 02-import-dump.sh)"
  fi

  # Collations mezcladas: causa tipica de "Illegal mix of collations" en los JOIN
  NCOLL=$(mysql --protocol=socket -N -B -e \
    "SELECT COUNT(DISTINCT table_collation) FROM information_schema.tables
       WHERE table_schema='${DB_NAME}' AND table_collation IS NOT NULL;" 2>/dev/null)
  if (( NCOLL <= 1 )); then
    pass "Collation homogenea en todas las tablas"
  elif [[ "$ALLOW_MIXED_COLLATION" == "1" ]]; then
    # Estado aceptado a proposito: el dump viene de produccion con las
    # collations mezcladas y convertirlas haria que QA ordene y compare
    # strings distinto que prod. Se informa, pero no cuenta como fallo.
    info "Hay ${NCOLL} collations distintas (aceptado por ALLOW_MIXED_COLLATION=1, asi viene el dump de produccion)"
    mysql --protocol=socket -e \
      "SELECT table_collation, COUNT(*) AS tablas FROM information_schema.tables
         WHERE table_schema='${DB_NAME}' GROUP BY table_collation;" 2>/dev/null
    info "Ojo: comparar varchar entre tablas de grupos distintos puede dar 'Illegal mix of collations'"
  else
    fail "Hay ${NCOLL} collations distintas; los JOIN pueden dar 'Illegal mix of collations'"
    info "Si asi viene de produccion y es intencional: ALLOW_MIXED_COLLATION=1 sudo -E bash $0"
    info "Para unificar: mysql -e \"SELECT CONCAT('ALTER TABLE \\\`',table_name,'\\\` CONVERT TO CHARACTER SET utf8mb4 COLLATE ${DB_COLLATE:-utf8mb4_0900_ai_ci};') FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_type='BASE TABLE';\""
    mysql --protocol=socket -e \
      "SELECT table_collation, COUNT(*) AS tablas FROM information_schema.tables
         WHERE table_schema='${DB_NAME}' GROUP BY table_collation;" 2>/dev/null
  fi

  log "Chequeo fisico de tablas (mysqlcheck)"
  BADCHK=$(mysqlcheck --protocol=socket --check "${DB_NAME}" 2>&1 | grep -iE 'error|corrupt|warning' || true)
  if [[ -z "$BADCHK" ]]; then
    pass "mysqlcheck sin incidencias"
  else
    fail "mysqlcheck reporta problemas:"
    printf '%s\n' "$BADCHK" | head -10 | sed 's/^/        /'
  fi
fi

# ------------------------------------------------------------- 6. Logs
log "6. Ultimos errores en los logs"
for L in /var/log/mysql/error.log /var/log/nginx/pma-error.log /var/log/qa-import-errors.log; do
  if [[ -f "$L" ]]; then
    # 'grep -c' ya imprime 0 cuando no hay coincidencias, y ademas sale con 1:
    # un '|| echo 0' aqui dejaba N="0\n0" y rompia la comparacion aritmetica.
    N=$(grep -ciE '\[error\]|ERROR' "$L" 2>/dev/null || true)
    N=${N:-0}
    if (( N == 0 )); then
      pass "$(basename "$L"): sin errores"
    else
      info "$(basename "$L"): ${N} lineas con ERROR (ultimas 3)"
      grep -iE '\[error\]|ERROR' "$L" | tail -3 | sed 's/^/        /'
    fi
  fi
done

# ---------------------------------------------------------------- Resumen
echo ""
if (( FAILS == 0 )); then
  printf '\033[1;32m===== VERIFICACION OK: %s comprobaciones fallidas =====\033[0m\n' "$FAILS"
  echo ""
  echo "  Accede desde Windows (PowerShell):"
  echo "      ssh -L ${PMA_PORT}:127.0.0.1:${PMA_PORT} USUARIO@IP_DEL_SERVIDOR"
  echo "  y abre http://localhost:${PMA_PORT}"
  echo "  Usuario: ${DB_USER}   Password: sudo cat ${CRED_FILE}"
  echo ""
  exit 0
else
  printf '\033[0;31m===== VERIFICACION CON %s FALLOS (ver [FAIL] arriba) =====\033[0m\n' "$FAILS"
  echo ""
  exit 1
fi
