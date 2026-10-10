#!/usr/bin/env bash
# Create the Traceability databases and the production databases of every service on the shared
# MySQL server, each with its own user that can only reach that database (SCRUM-121, SCRUM-122).
#
#   MYSQL_ADMIN_PASSWORD=... ./azure/mysql/create-databases.sh <passwords-output-file>   # create
#   DRY_RUN=1 ./azure/mysql/create-databases.sh                                          # print the SQL
#
# Databases created (staging databases of the other services already exist and are not touched):
#
#   database           user               environment
#   traceability       trc_app            staging
#   traceability_prod  trc_app_prod       production
#   mccdb_prod         mccdb_app_prod     production
#   processingdb_prod  processingdb_app_prod  production
#   quality_lab_prod   qls_app_prod       production
#
# Passwords are generated here with openssl and written only to the output file (keep it out of
# git); they are never printed or passed on a command line. Idempotent: re-running keeps existing
# databases and users, and gives each user a new password, which is how a rotation is applied.
# Needs mysqlsh (MySQL Shell) or mysql on PATH.
set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:-wonrichmysql.mysql.database.azure.com}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_ADMIN_USER="${MYSQL_ADMIN_USER:-mccadmin}"

# database:user pairs
TARGETS=(
  "traceability:trc_app"
  "traceability_prod:trc_app_prod"
  "mccdb_prod:mccdb_app_prod"
  "processingdb_prod:processingdb_app_prod"
  "quality_lab_prod:qls_app_prod"
)

OUT="${1:-}"
DRY_RUN="${DRY_RUN:-0}"
if [ "$DRY_RUN" != 1 ]; then
  [ -n "$OUT" ] || { echo "usage: $0 <passwords-output-file>   (or DRY_RUN=1 $0)" >&2; exit 2; }
  [ -n "${MYSQL_ADMIN_PASSWORD:-}" ] || { echo "set MYSQL_ADMIN_PASSWORD (read -rs MYSQL_ADMIN_PASSWORD; export MYSQL_ADMIN_PASSWORD)" >&2; exit 2; }
fi

# Letters and digits only: ';' separates fields in a connection string and "'" ends a SQL string.
generate_password() { openssl rand -base64 36 | tr -d '/+=\n' | head -c 32; }

sql=""
creds=""
for target in "${TARGETS[@]}"; do
  db="${target%%:*}"; user="${target##*:}"
  if [ "$DRY_RUN" = 1 ]; then password='<generated>'; else password="$(generate_password)"; fi
  sql+="CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS '$user'@'%' IDENTIFIED BY '$password' REQUIRE SSL;
ALTER USER '$user'@'%' IDENTIFIED BY '$password' REQUIRE SSL;
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$user'@'%';
"
  creds+="$db  user=$user  password=$password
"
done
sql+="FLUSH PRIVILEGES;
"

if [ "$DRY_RUN" = 1 ]; then
  printf '%s' "$sql"
  exit 0
fi

# Only the databases and users above are touched. The admin password is fed on stdin, never as an
# argument, so it is not in the process list.
verify="SELECT SCHEMA_NAME AS ready FROM information_schema.SCHEMATA WHERE SCHEMA_NAME IN ($(printf "'%s'," "${TARGETS[@]%%:*}" | sed 's/,$//'));"
if command -v mysqlsh >/dev/null 2>&1; then
  printf '%s\n' "$MYSQL_ADMIN_PASSWORD" | mysqlsh --sql --passwords-from-stdin --quiet-start=2 \
    --host="$MYSQL_HOST" --port="$MYSQL_PORT" --user="$MYSQL_ADMIN_USER" --ssl-mode=REQUIRED \
    -e "$sql $verify" | grep -v 'provide the password'
elif command -v mysql >/dev/null 2>&1; then
  MYSQL_PWD="$MYSQL_ADMIN_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_ADMIN_USER" --ssl-mode=REQUIRED --batch -e "$sql $verify"
else
  echo "need mysqlsh or mysql on PATH" >&2; exit 1
fi

umask 077
printf '%s' "$creds" >> "$OUT"
echo
echo "== done. Passwords appended to $OUT (do not commit it)."
