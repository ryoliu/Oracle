#!/bin/bash

# Read-only final health checks for a project-managed Oracle Database 19c.
# Run this script as root. Oracle commands run internally as ORACLE_OWNER.

set +x +v
unset DB_PASSWORD

CREDENTIAL_DIR=""

cleanup_postcheck() {
    if [ -n "$CREDENTIAL_DIR" ]; then
        rm -f -- "$CREDENTIAL_DIR/connect.sql"
        rmdir -- "$CREDENTIAL_DIR"
    fi
    unset DB_PASSWORD
}

trap cleanup_postcheck EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "ERROR: $1"
    echo "POSTCHECK RESULT: FAIL"
    exit 1
}

print_usage() {
    echo "Usage:"
    echo "  $0 --sid SID --listener-port PORT [--db-host HOST] [--db-service SERVICE]"
    echo ""
    echo "Required options:"
    echo "  --sid SID             Existing Oracle SID, using 1-8 uppercase letters or digits."
    echo "  --listener-port PORT  Existing Listener TCP port from 1024 through 65535."
    echo ""
    echo "Optional options:"
    echo "  --db-host HOST        Default: hostname -f"
    echo "  --db-service SERVICE  Default: SID"
    echo "  --password-stdin      Read the SYSTEM password from standard input for Main integration."
    echo "  --help                Show this help."
    echo ""
    echo "Example:"
    echo "  $0 --sid ORCL --listener-port 1521"
}

fail_with_usage() {
    echo "ERROR: $1"
    echo ""
    print_usage
    echo "POSTCHECK RESULT: FAIL"
    exit 1
}

ORACLE_SID=""
LISTENER_PORT=""
DB_HOST=""
DB_SERVICE=""
PASSWORD_STDIN=0

if [ "$#" -eq 0 ]; then
    fail_with_usage "--sid and --listener-port are required."
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --sid)
            if [ "$#" -lt 2 ]; then fail_with_usage "--sid requires a value."; fi
            ORACLE_SID="$2"
            shift 2
            ;;
        --listener-port)
            if [ "$#" -lt 2 ]; then fail_with_usage "--listener-port requires a value."; fi
            LISTENER_PORT="$2"
            shift 2
            ;;
        --db-host)
            if [ "$#" -lt 2 ]; then fail_with_usage "--db-host requires a value."; fi
            DB_HOST="$2"
            shift 2
            ;;
        --db-service)
            if [ "$#" -lt 2 ]; then fail_with_usage "--db-service requires a value."; fi
            DB_SERVICE="$2"
            shift 2
            ;;
        --password-stdin)
            PASSWORD_STDIN=1
            shift
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            fail_with_usage "Unknown option: $1"
            ;;
    esac
done

if [ -z "$ORACLE_SID" ] || [ -z "$LISTENER_PORT" ]; then
    fail_with_usage "Both --sid and --listener-port are required."
fi

if [ "$(id -u)" -ne 0 ]; then
    fail "Run this PostCheck as root."
fi

if ! SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; then
    fail "Cannot determine the script directory."
fi
CONFIG_FILE="$SCRIPT_DIR/oracle_install.conf"

if [ -L "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    fail "Configuration must be a regular file: $CONFIG_FILE"
fi
if ! . "$CONFIG_FILE"; then
    fail "Failed to load configuration: $CONFIG_FILE"
fi
if [ -z "${ORACLE_BASE:-}" ] || [ -z "${ORACLE_HOME:-}" ] ||
   [ -z "${ORA_INVENTORY:-}" ] || [ -z "${ORAINST_FILE:-}" ] ||
   [ -z "${ORACLE_OWNER:-}" ] || [ -z "${ORACLE_GROUP:-}" ]; then
    fail "Required Oracle settings are missing from: $CONFIG_FILE"
fi

for REQUIRED_COMMAND in awk chmod chown env getent grep hostname id mktemp rm rmdir runuser sed tr; do
    if ! command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
        fail "Required command is missing: $REQUIRED_COMMAND"
    fi
done

if [[ ! "$ORACLE_SID" =~ ^[A-Z][A-Z0-9]{0,7}$ ]]; then
    fail "SID must contain 1-8 uppercase letters or digits and start with a letter."
fi
if [[ ! "$LISTENER_PORT" =~ ^[1-9][0-9]{3,4}$ ]] ||
   [ "$LISTENER_PORT" -lt 1024 ] || [ "$LISTENER_PORT" -gt 65535 ]; then
    fail "Listener port must be between 1024 and 65535."
fi
if [ -z "$DB_HOST" ]; then
    DB_HOST="$(hostname -f 2>/dev/null)"
fi
if [ -z "$DB_SERVICE" ]; then
    DB_SERVICE="$ORACLE_SID"
fi
if [[ ! "$DB_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
    fail "Database host contains unsupported characters: $DB_HOST"
fi
if [[ ! "$DB_SERVICE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    fail "Database service contains unsupported characters: $DB_SERVICE"
fi

# PostCheck accepts only the complete project-managed Oracle Software state.
INSTALL_MARKER="$ORACLE_HOME/.oracle_19c_installer_complete"
ORAINST_ROOT_MARKER="$ORA_INVENTORY/.orainstRoot_complete"
ROOT_SH_MARKER="$ORACLE_HOME/.root_sh_complete"
INVENTORY_FILE="$ORA_INVENTORY/ContentsXML/inventory.xml"
LISTENER_MARKER="$ORACLE_HOME/network/admin/.LSNR_${ORACLE_SID}_complete"
DATABASE_MARKER="$ORACLE_BASE/.DB_${ORACLE_SID}_complete"

if [ -L "$ORACLE_HOME" ] || [ ! -d "$ORACLE_HOME" ]; then
    fail "Oracle Home must be a normal directory: $ORACLE_HOME"
fi
if [ -L "$ORAINST_FILE" ] || [ ! -f "$ORAINST_FILE" ] || [ ! -r "$ORAINST_FILE" ]; then
    fail "oraInst.loc must be a readable regular file: $ORAINST_FILE"
fi
DECLARED_ORA_INVENTORY="$(sed -n 's/^inventory_loc=//p' "$ORAINST_FILE")"
DECLARED_INVENTORY_GROUP="$(sed -n 's/^inst_group=//p' "$ORAINST_FILE")"
if [ "$DECLARED_ORA_INVENTORY" != "$ORA_INVENTORY" ] ||
   [ "$DECLARED_INVENTORY_GROUP" != "$ORACLE_GROUP" ]; then
    fail "oraInst.loc does not match oracle_install.conf: $ORAINST_FILE"
fi
if [ -L "$INVENTORY_FILE" ] || [ ! -f "$INVENTORY_FILE" ] || [ ! -r "$INVENTORY_FILE" ] ||
   ! grep -Fq "LOC=\"$ORACLE_HOME\"" "$INVENTORY_FILE"; then
    fail "Oracle Home is not registered in the project Inventory: $ORACLE_HOME"
fi
if [ -L "$INSTALL_MARKER" ] || [ ! -f "$INSTALL_MARKER" ] ||
   [ ! -r "$INSTALL_MARKER" ] || [ ! -s "$INSTALL_MARKER" ]; then
    fail "Installer completion marker is missing or invalid: $INSTALL_MARKER"
fi
for ROOT_MARKER in "$ORAINST_ROOT_MARKER" "$ROOT_SH_MARKER"; do
    if [ -L "$ROOT_MARKER" ] || [ ! -f "$ROOT_MARKER" ] || [ ! -r "$ROOT_MARKER" ]; then
        fail "Root-script completion marker is missing or invalid: $ROOT_MARKER"
    fi
done
for TARGET_MARKER in "$LISTENER_MARKER" "$DATABASE_MARKER"; do
    if [ -L "$TARGET_MARKER" ] || [ ! -f "$TARGET_MARKER" ] || [ ! -r "$TARGET_MARKER" ]; then
        fail "Target completion marker is missing or invalid: $TARGET_MARKER"
    fi
done
if ! id "$ORACLE_OWNER" >/dev/null 2>&1; then
    fail "Oracle owner is missing: $ORACLE_OWNER"
fi
for REQUIRED_GROUP in "$ORACLE_GROUP" dba; do
    if ! getent group "$REQUIRED_GROUP" >/dev/null 2>&1 ||
       ! id -nG "$ORACLE_OWNER" | tr ' ' '\n' | grep -Fxq "$REQUIRED_GROUP"; then
        fail "Oracle owner is not a member of required group: $REQUIRED_GROUP"
    fi
done
for ORACLE_TOOL in runInstaller root.sh bin/dbca bin/lsnrctl bin/sqlplus; do
    if [ ! -x "$ORACLE_HOME/$ORACLE_TOOL" ]; then
        fail "Required Oracle tool is missing or not executable: $ORACLE_HOME/$ORACLE_TOOL"
    fi
done
if [ ! -x "$ORA_INVENTORY/orainstRoot.sh" ] ||
   [ ! -r "$ORACLE_HOME/assistants/dbca/dbca.rsp" ] ||
   [ ! -d "$ORACLE_HOME/dbs" ] || [ ! -r "$ORACLE_HOME/dbs" ]; then
    fail "Required Oracle Software assets are missing or unreadable."
fi
if [ ! -r /etc/oratab ]; then
    fail "Cannot read /etc/oratab."
fi
REGISTERED_HOME="$(awk -F: -v name="$ORACLE_SID" '$0 !~ /^[[:space:]]*#/ && toupper($1)==name {print $2; exit}' /etc/oratab)"
if [ "$REGISTERED_HOME" != "$ORACLE_HOME" ]; then
    fail "The target SID is not registered with the configured Oracle Home: $ORACLE_SID"
fi
ORACLE_OWNER_HOME="$(getent passwd "$ORACLE_OWNER" | awk -F: 'NR == 1 {print $6}')"
if [ -z "$ORACLE_OWNER_HOME" ] || [ ! -d "$ORACLE_OWNER_HOME" ]; then
    fail "Cannot determine the Oracle owner home directory: $ORACLE_OWNER"
fi

if [ "$PASSWORD_STDIN" -eq 1 ]; then
    if ! IFS= read -r DB_PASSWORD; then
        fail "Cannot read the SYSTEM password from standard input."
    fi
else
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        fail "Interactive password input requires a terminal. Use --password-stdin for Main integration."
    fi
    if ! IFS= read -r -s -p "Enter SYSTEM password: " DB_PASSWORD; then
        printf '\n'
        fail "Password input was cancelled."
    fi
    printf '\n'
fi
if [ -z "$DB_PASSWORD" ] || [[ "$DB_PASSWORD" == *'"'* || "$DB_PASSWORD" =~ [[:cntrl:]] ]]; then
    fail "SYSTEM password must be nonempty and contain no double quotes or control characters."
fi

umask 077
if ! CREDENTIAL_DIR="$(mktemp -d /tmp/oracle_postcheck.XXXXXX)"; then
    fail "Cannot create the PostCheck credential directory."
fi
if ! chmod 700 "$CREDENTIAL_DIR" ||
   ! printf 'SET ECHO OFF VERIFY OFF DEFINE OFF\nWHENEVER OSERROR EXIT FAILURE\nWHENEVER SQLERROR EXIT FAILURE\nCONNECT system/"%s"@//%s:%s/%s\n' \
        "$DB_PASSWORD" "$DB_HOST" "$LISTENER_PORT" "$DB_SERVICE" > "$CREDENTIAL_DIR/connect.sql" ||
   ! chmod 600 "$CREDENTIAL_DIR/connect.sql" ||
   ! chown "$ORACLE_OWNER:$ORACLE_GROUP" "$CREDENTIAL_DIR" "$CREDENTIAL_DIR/connect.sql"; then
    fail "Cannot prepare the protected SQL*Plus credential file."
fi
unset DB_PASSWORD

echo "========================================"
echo " Oracle Database 19c PostCheck"
echo "========================================"

if ! runuser -u "$ORACLE_OWNER" -- env -i \
    HOME="$ORACLE_OWNER_HOME" PATH="/usr/bin:/bin" \
    bash --noprofile --norc -s -- \
    "$ORACLE_BASE" "$ORACLE_HOME" "$ORACLE_SID" "$LISTENER_PORT" \
    "$DB_HOST" "$DB_SERVICE" "$CREDENTIAL_DIR" "$ORACLE_OWNER" <<'ORACLE_POSTCHECK_SCRIPT'
set +x +v
ORACLE_BASE="$1"
ORACLE_HOME="$2"
ORACLE_SID="$3"
LISTENER_PORT="$4"
DB_HOST="$5"
DB_SERVICE="$6"
CREDENTIAL_DIR="$7"
ORACLE_OWNER="$8"
LISTENER_NAME="LSNR_$ORACLE_SID"

if [ "$(id -un)" != "$ORACLE_OWNER" ]; then
    echo "ERROR: Oracle commands are not running as the configured Oracle owner."
    exit 1
fi

unset TWO_TASK LOCAL ORACLE_PDB_SID SQLPATH
export ORACLE_BASE ORACLE_HOME ORACLE_SID
export TNS_ADMIN="$ORACLE_HOME/network/admin"
export LD_LIBRARY_PATH="$ORACLE_HOME/lib"
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8

echo "=== 1. Verify Listener status ==="
if ! LISTENER_STATUS=$("$ORACLE_HOME/bin/lsnrctl" status "$LISTENER_NAME"); then
    echo "ERROR: Listener status check failed."
    exit 1
fi
printf '%s\n' "$LISTENER_STATUS"
if ! printf '%s\n' "$LISTENER_STATUS" | tr -d '[:space:]' |
     grep -Fiq "(HOST=$DB_HOST)(PORT=$LISTENER_PORT)"; then
    echo "ERROR: Listener endpoint does not match the requested host and port."
    exit 1
fi

echo "=== 2. Verify database service registration ==="
if ! LISTENER_SERVICES=$("$ORACLE_HOME/bin/lsnrctl" services "$LISTENER_NAME"); then
    echo "ERROR: Listener services check failed."
    exit 1
fi
printf '%s\n' "$LISTENER_SERVICES"
if ! printf '%s\n' "$LISTENER_SERVICES" | awk -v service="$DB_SERVICE" -v sid="$ORACLE_SID" '
    BEGIN { IGNORECASE=1; in_service=0; found=0 }
    /^Service "/ {
        in_service=(index(toupper($0), "SERVICE \"" toupper(service) "\" HAS") > 0)
    }
    in_service && $0 ~ "Instance[[:space:]]+\"" sid "\",[[:space:]]+status[[:space:]]+READY" {
        found=1
    }
    END { exit(found ? 0 : 1) }
'; then
    echo "ERROR: The requested service is not registered with the target READY instance: $DB_SERVICE"
    exit 1
fi

echo "=== 3. Verify SYSTEM Easy Connect ==="
if ! "$ORACLE_HOME/bin/sqlplus" -L -s /nolog <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE
SET ECHO OFF VERIFY OFF DEFINE OFF
@"$CREDENTIAL_DIR/connect.sql"
SELECT SYS_CONTEXT('USERENV','INSTANCE_NAME') AS instance_name,
       SYS_CONTEXT('USERENV','SERVICE_NAME') AS service_name,
       SYS_CONTEXT('USERENV','CON_NAME') AS container_name FROM dual;
EXIT SUCCESS
SQL
then
    echo "ERROR: SYSTEM connection or verification query failed."
    exit 1
fi
echo "SYSTEM Easy Connect verification completed successfully."

echo "=== 4. Verify instance OPEN status ==="
if ! DATABASE_STATUS=$("$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<'SQL'
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF PAGES 0 VERIFY OFF ECHO OFF
SELECT name || ':' || open_mode || ':' || UPPER(instance_name) || ':' || UPPER(status)
FROM v$database, v$instance;
EXIT SUCCESS
SQL
); then
    echo "ERROR: Instance status query failed."
    exit 1
fi
if ! printf '%s\n' "$DATABASE_STATUS" |
     grep -Eq "^[[:space:]]*$ORACLE_SID:READ WRITE:$ORACLE_SID:OPEN[[:space:]]*$"; then
    echo "ERROR: Database identity, open mode or instance status is unexpected."
    printf '%s\n' "$DATABASE_STATUS"
    exit 1
fi
printf '%s\n' "$DATABASE_STATUS"
ORACLE_POSTCHECK_SCRIPT
then
    fail "Oracle Database health checks failed."
fi

echo "POSTCHECK RESULT: PASS"
exit 0
