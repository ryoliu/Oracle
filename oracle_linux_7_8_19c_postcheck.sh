#!/bin/bash

# Read-only final health checks for Oracle Database 19c.

ORACLE_SID="$1"
LISTENER_PORT="$2"
DB_HOST="$3"
DB_SERVICE="$4"
DB_SECRET_DIR="$5"
LISTENER_NAME="LSNR_$ORACLE_SID"
TNS_ADMIN="$ORACLE_HOME/network/admin"

if [ -z "${ORACLE_HOME:-}" ] || [ -z "${OPATCH_MINIMUM_VERSION:-}" ] ||
   [ -z "${RU_PATCH_ID:-}" ]; then
    echo "ERROR: Required Oracle Home or patch settings are missing."
    exit 1
fi

echo "========================================"
echo " Oracle Database 19c PostCheck"
echo "========================================"

echo "=== 1. Verify OPatch and Release Update ==="
if [ ! -x "$ORACLE_HOME/OPatch/opatch" ]; then
    echo "ERROR: OPatch is missing or not executable: $ORACLE_HOME/OPatch/opatch"
    exit 1
fi
OPATCH_VERSION="$("$ORACLE_HOME/OPatch/opatch" version 2>/dev/null |
    awk '/^OPatch Version:/ { print $3; exit }')"
if [ -z "$OPATCH_VERSION" ] ||
   ! printf '%s\n%s\n' "$OPATCH_MINIMUM_VERSION" "$OPATCH_VERSION" |
       LC_ALL=C sort -V -C; then
    echo "ERROR: OPatch version does not meet the required minimum."
    echo "Required: $OPATCH_MINIMUM_VERSION; actual: ${OPATCH_VERSION:-unknown}"
    exit 1
fi
if ! PATCH_LIST="$("$ORACLE_HOME/OPatch/opatch" lspatches)"; then
    echo "ERROR: Failed to read the Oracle Home patch inventory."
    exit 1
fi
printf '%s\n' "$PATCH_LIST"
if ! printf '%s\n' "$PATCH_LIST" | grep -Fq "$RU_PATCH_ID"; then
    echo "ERROR: Release Update patch is not present: $RU_PATCH_ID"
    exit 1
fi
echo "OPatch and Release Update verification completed successfully."

echo "=== 2. Verify Listener status ==="
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

echo "=== 3. Verify Listener port ==="
if ! ss -H -ltn | awk '{print $4}' | grep -Eq ":$LISTENER_PORT$"; then
    echo "ERROR: Listener TCP port is not active: $LISTENER_PORT"
    exit 1
fi
echo "Listener TCP port is active: $LISTENER_PORT"

echo "=== 4. Verify database service registration ==="
if ! LISTENER_SERVICES=$("$ORACLE_HOME/bin/lsnrctl" services "$LISTENER_NAME"); then
    echo "ERROR: Listener services check failed."
    exit 1
fi
printf '%s\n' "$LISTENER_SERVICES"
if ! printf '%s\n' "$LISTENER_SERVICES" | grep -Fiq "Service \"$DB_SERVICE\" has" ||
   ! printf '%s\n' "$LISTENER_SERVICES" |
        grep -Eiq "Instance[[:space:]]+\"$ORACLE_SID\",[[:space:]]+status[[:space:]]+READY"; then
    echo "ERROR: Database service is not registered with READY status: $DB_SERVICE"
    exit 1
fi

echo "=== 5. Verify tnsping ==="
if [ ! -x "$ORACLE_HOME/bin/tnsping" ]; then
    echo "ERROR: tnsping is missing or not executable: $ORACLE_HOME/bin/tnsping"
    exit 1
fi
if ! "$ORACLE_HOME/bin/tnsping" "$DB_HOST:$LISTENER_PORT/$DB_SERVICE"; then
    echo "ERROR: tnsping failed."
    exit 1
fi

echo "=== 6. Verify SYSTEM Easy Connect ==="
echo "Verify the SYSTEM connection using the password collected at startup."
if ! "$ORACLE_HOME/bin/sqlplus" -L -s /nolog <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE
SET ECHO OFF VERIFY OFF DEFINE OFF
@"$DB_SECRET_DIR/connect.sql"
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

echo "=== 7. Verify instance OPEN status ==="
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

echo "POSTCHECK RESULT: PASS"
exit 0
