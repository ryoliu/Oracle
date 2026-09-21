#!/bin/bash

# Run as the Oracle software owner on the target Linux host.
# This script only collects information and creates one private log file.
ORACLE_BASE="/opt/oracle"
ORACLE_HOME="/opt/oracle/product/19.3.0.0/db_1"
TARGET_SID="ORCL"
DATA_DIR="/opt/oracle/oradata"
FRA_DIR="/opt/oracle/fast_recovery_area"
LISTENER_NAME="LISTENER"
LOG_DIR="."

if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: Run this script on the target Linux host."
    exit 1
fi

if [ "$(id -un)" != "oracle" ]; then
    echo "ERROR: Run this script as oracle using: su - oracle"
    exit 1
fi

umask 077
if ! LOG_FILE=$(mktemp "$LOG_DIR/oracle_dbca_info_$(date +%Y%m%d_%H%M%S)_XXXXXX.log"); then
    echo "ERROR: Cannot create the log file in $LOG_DIR"
    exit 1
fi

echo "Collecting information. Log file: $LOG_FILE"
export ORACLE_BASE ORACLE_HOME
export LC_ALL=C

# Limit external Oracle commands so collection cannot wait indefinitely.
run_check() {
    if ! command -v timeout >/dev/null 2>&1; then
        echo "SKIPPED: timeout is unavailable: $1"
        return
    fi
    timeout 45 "$@"
    CHECK_RC=$?
    if [ "$CHECK_RC" -ne 0 ]; then
        echo "CHECK WARNING: Command returned $CHECK_RC: $1"
    fi
}

{
    echo "=== Collection details ==="
    date -Is
    hostname
    id
    printf 'ORACLE_BASE=%s\nORACLE_HOME=%s\nTARGET_SID=%s\n' "$ORACLE_BASE" "$ORACLE_HOME" "$TARGET_SID"
    printf 'DATA_DIR=%s\nFRA_DIR=%s\n' "$DATA_DIR" "$FRA_DIR"
    echo "Scope: Read-only checks. No database startup or configuration changes."

    echo ""
    echo "=== Operating system and CPU ==="
    cat /etc/os-release
    uname -rmo
    getconf _NPROCESSORS_ONLN
    lscpu

    echo ""
    echo "=== Memory, swap and shared memory ==="
    free -m
    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree|HugePages_Total|HugePages_Free|Hugepagesize|Shmem):' /proc/meminfo
    df -hP /dev/shm
    echo "Soft limits:"
    ulimit -Sa
    echo "Hard limits:"
    ulimit -Ha

    echo ""
    echo "=== Filesystems and destination access ==="
    df -hPT
    df -Pi
    for CHECK_DIR in "$ORACLE_BASE" "$ORACLE_HOME" "$DATA_DIR" "$FRA_DIR" /tmp; do
        echo "Directory: $CHECK_DIR"
        if [ -d "$CHECK_DIR" ]; then
            ls -ld "$CHECK_DIR"
            if [ -w "$CHECK_DIR" ] && [ -x "$CHECK_DIR" ]; then
                echo "Oracle directory access: writable and searchable"
            else
                echo "Oracle directory access: insufficient"
            fi
        else
            echo "Directory does not exist."
        fi
        EXISTING_PARENT="$CHECK_DIR"
        while [ ! -d "$EXISTING_PARENT" ] && [ "$EXISTING_PARENT" != / ]; do
            EXISTING_PARENT=$(dirname "$EXISTING_PARENT")
        done
        echo "Nearest existing directory: $EXISTING_PARENT"
        ls -ld "$EXISTING_PARENT"
        df -mP "$EXISTING_PARENT"
        if command -v findmnt >/dev/null 2>&1; then
            findmnt -T "$EXISTING_PARENT" -o TARGET,SOURCE,FSTYPE,OPTIONS
        fi
    done

    echo ""
    echo "=== Oracle software and inventory ==="
    for CHECK_FILE in /etc/oraInst.loc /etc/oratab; do
        echo "File: $CHECK_FILE"
        if [ -r "$CHECK_FILE" ]; then
            grep -Ev '^[[:space:]]*(#|$)' "$CHECK_FILE"
        else
            echo "Missing or unreadable."
        fi
    done
    if [ -r /etc/oraInst.loc ]; then
        INVENTORY_DIR=$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc)
        if [ -n "$INVENTORY_DIR" ] && [ -r "$INVENTORY_DIR/ContentsXML/inventory.xml" ]; then
            grep '<HOME ' "$INVENTORY_DIR/ContentsXML/inventory.xml"
        fi
    fi
    for CHECK_FILE in bin/dbca bin/sqlplus bin/lsnrctl bin/netca assistants/dbca/templates/General_Purpose.dbc; do
        ls -l "$ORACLE_HOME/$CHECK_FILE"
    done
    if [ -x "$ORACLE_HOME/bin/sqlplus" ]; then
        run_check "$ORACLE_HOME/bin/sqlplus" -V
    fi
    if [ -x "$ORACLE_HOME/bin/dbca" ]; then
        run_check "$ORACLE_HOME/bin/dbca" -createDatabase -help
    fi
    echo "Root script log metadata (existence alone does not prove success):"
    if [ -d "$ORACLE_HOME/install" ]; then
        find "$ORACLE_HOME/install" -maxdepth 1 -type f -name 'root_*.log' -ls
    fi

    echo ""
    echo "=== Existing instances and target artifacts ==="
    ps -eo user,pid,comm | grep -E '(^USER|ora_pmon_|asm_pmon_|tnslsnr)' || true
    if [ -d "$ORACLE_HOME/dbs" ]; then
        find "$ORACLE_HOME/dbs" -maxdepth 1 -type f \( -name 'spfile*.ora' -o -name 'init*.ora' -o -name 'orapw*' -o -name 'lk*' \) -printf '%f\n'
    fi
    for CHECK_DIR in "$DATA_DIR/$TARGET_SID" "$FRA_DIR/$TARGET_SID"; do
        if [ -d "$CHECK_DIR" ]; then
            ls -ld "$CHECK_DIR"
            find "$CHECK_DIR" -maxdepth 2 -type f -printf '%p\n'
        fi
    done

    echo ""
    echo "=== Network and Listener ==="
    hostname -f
    getent hosts "$(hostname)"
    printf 'TNS_ADMIN=%s\n' "${TNS_ADMIN:-<not set>}"
    echo "TCP listening ports:"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn
    else
        echo "SKIPPED: ss is unavailable."
    fi
    NETWORK_DIR="${TNS_ADMIN:-$ORACLE_HOME/network/admin}"
    echo "Network configuration file metadata (contents are not collected):"
    for CHECK_FILE in listener.ora sqlnet.ora tnsnames.ora; do
        if [ -e "$NETWORK_DIR/$CHECK_FILE" ]; then
            ls -l "$NETWORK_DIR/$CHECK_FILE"
        fi
    done
    if [ -x "$ORACLE_HOME/bin/lsnrctl" ]; then
        run_check "$ORACLE_HOME/bin/lsnrctl" status "$LISTENER_NAME"
        run_check "$ORACLE_HOME/bin/lsnrctl" services "$LISTENER_NAME"
    fi

    echo ""
    echo "=== Collection complete ==="
    echo "Missing commands and failed checks are diagnostic findings."
    echo "No database connections, startup, shutdown, or configuration changes were performed."
    echo "Passwords, environment dumps, and Oracle password file contents were not collected."
} >> "$LOG_FILE" 2>&1

if ! grep -q '^=== Collection complete ===$' "$LOG_FILE"; then
    echo "ERROR: Collection did not finish. Review: $LOG_FILE"
    exit 1
fi

echo "Collection complete: $LOG_FILE"
echo "Review the log for hostnames, IP addresses, and paths before sharing."
