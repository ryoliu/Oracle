#!/bin/bash

# Read-only final health checks for Oracle Database 19c.
#
# The checks progress from the network listener to database identity and the
# final kernel parameter state:
#   Listener process -> TCP port -> service registration -> client tools
#   -> password-based Easy Connect -> SYSDBA instance state -> kernel parameters
# No configuration is changed by this script. The first failed check exits 1.

ORACLE_SID="$1"
LISTENER_PORT="$2"
DB_HOST="$3"
DB_SERVICE="$4"
DB_SECRET_DIR="$5"
LISTENER_NAME="LSNR_$ORACLE_SID"
TNS_ADMIN="$ORACLE_HOME/network/admin"

# Main already validates these deployment identifiers. PostCheck receives the
# same values so every test targets the requested database and dedicated Listener.
echo "========================================"
echo " Oracle Database 19c PostCheck"
echo "========================================"

echo "=== 1. Verify Listener status ==="
# lsnrctl status proves both Listener availability and the configured endpoint.
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

echo "=== 2. Verify Listener port ==="
# Confirm the operating system has an active TCP listening socket on the port.
if ! ss -H -ltn | awk '{print $4}' | grep -Eq ":$LISTENER_PORT$"; then
    echo "ERROR: Listener TCP port is not active: $LISTENER_PORT"
    exit 1
fi
echo "Listener TCP port is active: $LISTENER_PORT"

echo "=== 3. Verify database service registration ==="
# A listening port is not enough. The requested service and instance must be
# dynamically registered with READY status.
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

echo "=== 4. Verify tnsping ==="
# Test Oracle Net name resolution and reachability with an Easy Connect string.
if [ ! -x "$ORACLE_HOME/bin/tnsping" ]; then
    echo "ERROR: tnsping is missing or not executable: $ORACLE_HOME/bin/tnsping"
    exit 1
fi
if ! "$ORACLE_HOME/bin/tnsping" "$DB_HOST:$LISTENER_PORT/$DB_SERVICE"; then
    echo "ERROR: tnsping failed."
    exit 1
fi

echo "=== 5. Verify SYSTEM Easy Connect ==="
echo "Verify the SYSTEM connection using the password collected at startup."
# This validates password authentication through Listener and service routing.
# The connect.sql file is private and is removed by Main after PostCheck.
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

echo "=== 6. Verify instance OPEN status ==="
# Finish with local SYSDBA verification of database name, open mode, instance
# name, and instance status. This distinguishes connectivity from database health.
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

echo "=== 7. Verify Current Kernel Parameters ==="
# Main verifies these values immediately after sysctl --system. PostCheck reads
# them again so the final installation report includes the active kernel state.
for KERNEL_PARAMETER in \
    fs.aio-max-nr \
    fs.file-max \
    kernel.sem \
    kernel.shmmax \
    kernel.shmall \
    vm.nr_hugepages
do
    if ! sysctl "$KERNEL_PARAMETER"; then
        echo "ERROR: Failed to read kernel parameter: $KERNEL_PARAMETER"
        exit 1
    fi
done

echo "POSTCHECK RESULT: PASS"
exit 0
