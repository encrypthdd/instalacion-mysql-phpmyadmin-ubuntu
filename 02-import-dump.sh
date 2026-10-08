#!/usr/bin/env bash
# 02-import-dump.sh
# Inspecciona y carga un dump de mysqldump en la base de QA.
#
#   sudo bash 02-import-dump.sh /ruta/al/dump.sql
#
# Opciones por variable de entorno:
#   DB_NAME=otra_base      cargar en otra base (por defecto: la de /root/.qa-db-credentials)
#   RELAX_SQLMODE=1        desactiva sql_mode estricto (dumps viejos con fechas 0000-00-00)
#   DRY_RUN=1              solo inspecciona el dump, no carga nada
#   FAST=0                 no tocar innodb_flush_log_at_trx_commit

set -euo pipefail

CRED_FILE=/root/.qa-db-credentials
DUMP="${1:-}"
DB_NAME_OVERRIDE="${DB_NAME:-}"   # capturado ANTES de cargar el cred file
RELAX_SQLMODE="${RELAX_SQLMODE:-0}"
DRY_RUN="${DRY_RUN:-0}"
FAST="${FAST:-1}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    [OK] %s\n' "$*"; }
warn() { printf '    [!!] %s\n' "$*"; }
die()  { printf '\n\033[0;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Ejecutar como root: sudo bash $0 <dump.sql>"
[[ -n "$DUMP" ]]              || die "Falta la ruta del dump: sudo bash $0 /ruta/al/dump.sql"
[[ -r "$DUMP" ]]              || die "No puedo leer '$DUMP'"
[[ -f "$CRED_FILE" ]]         || die "No existe $CRED_FILE. Ejecuta primero 01-install-mysql-pma.sh"

# shellcheck disable=SC1090
. "$CRED_FILE"
# Un DB_NAME pasado por entorno manda sobre el del cred file
[[ -n "$DB_NAME_OVERRIDE" ]] && DB_NAME="$DB_NAME_OVERRIDE"
[[ -n "${DB_NAME:-}" ]] || die "DB_NAME vacio"
[[ -n "${DB_USER:-}" ]] || die "DB_USER vacio en $CRED_FILE"

systemctl is-active --quiet mysql || die "MySQL no esta corriendo"

# --------------------------------------------------- Descompresion transparente
case "$DUMP" in
  *.gz)  command -v zcat  >/dev/null || die "Falta zcat";  READER=(zcat  "$DUMP") ;;
  *.bz2) command -v bzcat >/dev/null || die "Falta bzcat"; READER=(bzcat "$DUMP") ;;
  *.zst) command -v zstdcat >/dev/null || die "Falta zstdcat"; READER=(zstdcat "$DUMP") ;;
  *)     READER=(cat "$DUMP") ;;
esac

# --------------------------------------------------- Inspeccion previa al load
log "Inspeccionando el dump"
SIZE_H=$(du -h "$DUMP" | cut -f1)
SIZE_B=$(stat -c %s "$DUMP")
echo "    Archivo : $DUMP"
echo "    Tamano  : $SIZE_H"

HEAD=$("${READER[@]}" 2>/dev/null | head -c 200000 || true)

SRC_VER=$(printf '%s' "$HEAD" | sed -n 's/.*Server version[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -1)
[[ -n "$SRC_VER" ]] && echo "    Origen  : MySQL/MariaDB $SRC_VER"

SRC_CHARSET=$(printf '%s' "$HEAD" | grep -oiE 'DEFAULT CHARSET=[a-z0-9_]+' | head -1 | cut -d= -f2 || true)
SRC_COLLATE=$(printf '%s' "$HEAD" | grep -oiE 'COLLATE=[a-z0-9_]+' | head -1 | cut -d= -f2 || true)
[[ -n "$SRC_CHARSET" ]] && echo "    Charset : $SRC_CHARSET ${SRC_COLLATE:+/ $SRC_COLLATE}"

# Una sola pasada por el dump: con 2 GB, seis greps separados cuestan minutos.
# awk compatible con mawk (el awk por defecto de Ubuntu): sin IGNORECASE, se usa tolower().
echo "    Analizando el contenido (una pasada)..."
STATS=$("${READER[@]}" 2>/dev/null | awk -v zd="'0000-00-00" '
  function getdb(s,   n) {
    if (match(s, /`[^`]+`/)) return substr(s, RSTART + 1, RLENGTH - 2)
    n = s
    sub(/;.*$/, "", n)
    sub(/^[ \t]*[Uu][Ss][Ee][ \t]+/, "", n)
    sub(/^[ \t]*[Cc][Rr][Ee][Aa][Tt][Ee][ \t]+[Dd][Aa][Tt][Aa][Bb][Aa][Ss][Ee][ \t]+/, "", n)
    gsub(/[ \t]+$/, "", n)
    return n
  }
  { l = tolower($0) }
  l ~ /^[ \t]*create table/        { nt++ }
  index(l, "definer=")             { nd++ }
  # mysqldump envuelve los triggers en comentarios de version:
  # /*!50003 CREATE*/ /*!50017 DEFINER=...*/ /*!50003 TRIGGER `t` ...
  # por eso "create" no va seguido de espacio y hay que buscar ambas palabras por separado
  index(l, "trigger") && index(l, "create") { ntr++ }
  index($0, zd)                    { nz++ }
  l ~ /^[ \t]*create database/     { ncdb++; if (db == "") db = getdb($0) }
  l ~ /^[ \t]*use[ \t]/            { nuse++; if (db == "") db = getdb($0) }
  END { printf "%d\t%d\t%d\t%d\t%d\t%d\t%s\n", nt, nd, ntr, nz, ncdb, nuse, db }
' || true)

IFS=$'\t' read -r N_TABLES N_DEFINER N_TRIGGER N_ZERODATE HAS_CREATE_DB HAS_USE DUMP_DB <<< "$STATS"
N_TABLES=${N_TABLES:-0}; N_DEFINER=${N_DEFINER:-0}; N_TRIGGER=${N_TRIGGER:-0}
N_ZERODATE=${N_ZERODATE:-0}; HAS_CREATE_DB=${HAS_CREATE_DB:-0}; HAS_USE=${HAS_USE:-0}
DUMP_DB=${DUMP_DB:-}

echo "    CREATE TABLE : $N_TABLES"
echo "    DEFINER=     : $N_DEFINER"
echo "    TRIGGERs     : $N_TRIGGER"
echo "    Fechas 0000  : $N_ZERODATE"

(( N_TABLES > 0 )) || die "El dump no contiene ningun CREATE TABLE. Verifica que sea un dump valido."

# Decidir destino
TARGET_ARG=("$DB_NAME")
if [[ -n "$DUMP_DB" ]]; then
  warn "El dump trae su propia base: '${DUMP_DB}'"
  if [[ "$DUMP_DB" == "$DB_NAME" ]]; then
    ok "Coincide con el destino (${DB_NAME}); se carga sin forzar base"
    TARGET_ARG=()
  else
    warn "Se cargara en '${DUMP_DB}', NO en '${DB_NAME}'."
    warn "Si quieres forzarlo a ${DB_NAME}, quita las lineas CREATE DATABASE/USE del dump:"
    warn "    sed -i -E '/^[[:space:]]*(CREATE DATABASE|USE )/d' ${DUMP}"
    TARGET_ARG=()
  fi
fi

if (( N_ZERODATE > 0 )) && [[ "$RELAX_SQLMODE" != "1" ]]; then
  warn "Hay fechas '0000-00-00' y MySQL 8 las rechaza en modo estricto."
  warn "Si la carga falla por eso, repite con: RELAX_SQLMODE=1 sudo -E bash $0 $DUMP"
fi

if (( N_DEFINER > 0 )); then
  ok "Hay DEFINER=: la carga se hace como root@localhost (socket), que es inmune a ese fallo"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log "DRY_RUN=1: no se carga nada. Inspeccion terminada."
  exit 0
fi

# Aviso si la base destino ya tiene datos
if [[ ${#TARGET_ARG[@]} -gt 0 ]]; then
  EXISTING=$(mysql --protocol=socket -N -B -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';")
  if (( EXISTING > 0 )); then
    warn "'${DB_NAME}' ya contiene ${EXISTING} tablas. El dump puede sobreescribirlas (DROP TABLE IF EXISTS)."
    printf '    Escribe SI para continuar: '
    read -r RESP
    [[ "$RESP" == "SI" ]] || die "Cancelado por el usuario"
  fi
fi

# ------------------------------------------------------------------ Carga
log "Cargando el dump"

ORIG_FLUSH=""
restore_flush() {
  if [[ -n "$ORIG_FLUSH" ]]; then
    mysql --protocol=socket -e "SET GLOBAL innodb_flush_log_at_trx_commit = ${ORIG_FLUSH};" 2>/dev/null || true
    printf '    [OK] innodb_flush_log_at_trx_commit restaurado a %s\n' "$ORIG_FLUSH"
  fi
}
trap restore_flush EXIT

if [[ "$FAST" == "1" ]]; then
  ORIG_FLUSH=$(mysql --protocol=socket -N -B -e "SELECT @@innodb_flush_log_at_trx_commit;")
  mysql --protocol=socket -e "SET GLOBAL innodb_flush_log_at_trx_commit = 2;"
  ok "innodb_flush_log_at_trx_commit = 2 temporalmente (se restaura al salir)"
fi

ERRLOG="/var/log/qa-import-errors.log"
: > "$ERRLOG"

MYSQL_OPTS=(--protocol=socket --max-allowed-packet=512M --force)
PRELUDE=""
if [[ "$RELAX_SQLMODE" == "1" ]]; then
  PRELUDE="SET SESSION sql_mode='NO_ENGINE_SUBSTITUTION'; SET SESSION foreign_key_checks=0;"
  ok "sql_mode relajado y foreign_key_checks=0 para esta sesion"
else
  PRELUDE="SET SESSION foreign_key_checks=0;"
fi

START=$(date +%s)
if command -v pv >/dev/null 2>&1; then
  { printf '%s\n' "$PRELUDE"; "${READER[@]}"; } \
    | pv -s "$SIZE_B" -N "importando" \
    | mysql "${MYSQL_OPTS[@]}" "${TARGET_ARG[@]+"${TARGET_ARG[@]}"}" 2>> "$ERRLOG" || true
else
  warn "'pv' no esta instalado, no habra barra de progreso (apt install pv)"
  { printf '%s\n' "$PRELUDE"; "${READER[@]}"; } \
    | mysql "${MYSQL_OPTS[@]}" "${TARGET_ARG[@]+"${TARGET_ARG[@]}"}" 2>> "$ERRLOG" || true
fi
ELAPSED=$(( $(date +%s) - START ))
ok "Carga terminada en ${ELAPSED}s"

N_ERR=$(grep -c . "$ERRLOG" || true)
if (( N_ERR > 0 )); then
  warn "Se registraron ${N_ERR} lineas de error en ${ERRLOG}:"
  head -15 "$ERRLOG" | sed 's/^/        /'
  warn "Se uso --force, asi que la carga continuo tras cada error. Revisa el log completo."
else
  ok "Sin errores durante la carga"
fi

# ------------------------------------------------------------- Comprobacion
EFFECTIVE_DB="${DUMP_DB:-$DB_NAME}"
log "Comprobando el resultado en '${EFFECTIVE_DB}'"
LOADED=$(mysql --protocol=socket -N -B -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${EFFECTIVE_DB}' AND table_type='BASE TABLE';")
echo "    Tablas en el dump    : ${N_TABLES}"
echo "    Tablas en la base    : ${LOADED}"
if [[ "$LOADED" == "$N_TABLES" ]]; then
  ok "El numero de tablas coincide"
else
  warn "DISCREPANCIA: faltan $(( N_TABLES - LOADED )) tablas. Revisa ${ERRLOG}"
fi

# Si el dump traia su propia base, el usuario de QA necesita permisos sobre ella
if [[ -n "$DUMP_DB" && "$DUMP_DB" != "$DB_NAME" ]]; then
  log "Dando permisos a '${DB_USER}' sobre '${DUMP_DB}'"
  mysql --protocol=socket -e \
    "GRANT ALL PRIVILEGES ON \`${DUMP_DB}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
  ok "${DB_USER} ya puede ver '${DUMP_DB}' en phpMyAdmin"
fi

mysql --protocol=socket -e "
  SELECT table_name AS tabla, table_rows AS filas_aprox,
         ROUND((data_length+index_length)/1024/1024,1) AS mb
  FROM information_schema.tables
  WHERE table_schema='${EFFECTIVE_DB}' AND table_type='BASE TABLE'
  ORDER BY table_rows DESC LIMIT 15;"

echo ""
echo "  Dump cargado en: ${EFFECTIVE_DB}"
echo "  Siguiente paso:  sudo bash 03-verify.sh"
echo ""
