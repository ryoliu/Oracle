#!/bin/bash

# Read-only pre-install checks for Oracle Linux 7 / 8 and Oracle Database 19c.

PACKAGE_NAME="oracle-database-preinstall-19c"
PREINSTALL_SYSCTL="/etc/sysctl.d/99-oracle-database-preinstall-19c-sysctl.conf"
CUSTOM_SYSCTL="/etc/sysctl.d/99-oracle-custom.conf"
LIMITS_FILE="/etc/security/limits.d/oracle-database-preinstall-19c.conf"
SELINUX_CONFIG="/etc/selinux/config"
TIMEZONE="Asia/Taipei"
SOFTWARE_SOURCE_DIR="/opt/software/oracle"
ZIP_FILE="LINUX.X64_193000_db_home.zip"
ORACLE_BASE="/opt/oracle"
ORACLE_HOME="/opt/oracle/product/19.3.0.0/db_1"
EXTRACT_MARKER="$ORACLE_HOME/.oracle_19c_extraction_complete"
INSTALL_MARKER="$ORACLE_HOME/.oracle_19c_installer_complete"
ORA_INVENTORY="/opt/oraInventory"
ORAINST_FILE="/etc/oraInst.loc"
ORACLE_OWNER="oracle"
ORACLE_GROUP="oinstall"
DATA_DIR="/opt/oracle/oradata"
FRA_DIR="/opt/oracle/fast_recovery_area"
DB_HOST="$(hostname -f 2>/dev/null)"
DB_SERVICE=""
CREATE_DB=0
ORACLE_SID=""
LISTENER_PORT=1521
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
PACKAGE_INSTALLED=0
ORACLE_USER_EXISTS=0
INSTALL_COMPLETE=0
INVENTORY_DECLARED=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --create-db)
            CREATE_DB=1
            shift
            ;;
        --sid)
            if [ "$#" -lt 2 ]; then
                echo "FAIL: --sid requires a value."
                exit 1
            fi
            ORACLE_SID="$2"
            shift 2
            ;;
        --listener-port)
            if [ "$#" -lt 2 ]; then
                echo "FAIL: --listener-port requires a value."
                exit 1
            fi
            LISTENER_PORT="$2"
            shift 2
            ;;
        --timezone)
            if [ "$#" -lt 2 ]; then
                echo "FAIL: --timezone requires a value."
                exit 1
            fi
            TIMEZONE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--create-db --sid SID --listener-port PORT] [--timezone ZONE]"
            exit 0
            ;;
        *)
            echo "FAIL: Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "========================================"
echo " Oracle Linux 7 / 8 and Oracle 19c Precheck"
echo "========================================"

echo ""
echo "=== Identity and platform ==="

if [ "$(id -u)" -eq 0 ]; then
    echo "PASS: Running as root."
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "FAIL: Run this precheck as root."
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "$ID:${VERSION_ID%%.*}" in
        ol:7|ol:8)
            echo "PASS: Supported operating system detected: $ID $VERSION_ID"
            PASS_COUNT=$((PASS_COUNT + 1))
            ;;
        *)
            echo "FAIL: Supported operating systems are Oracle Linux 7 and 8: ${ID:-unknown} ${VERSION_ID:-unknown}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            ;;
    esac
else
    echo "FAIL: Cannot read /etc/os-release."
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if [ "$(uname -m)" = "x86_64" ]; then
    echo "PASS: Architecture is x86_64."
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "FAIL: Oracle Database 19c media in this project requires x86_64: $(uname -m)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if [ -n "$DB_HOST" ] && [[ "$DB_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
    echo "PASS: Hostname is available: $DB_HOST"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "FAIL: A valid hostname or FQDN is required."
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

for REQUIRED_COMMAND in awk df find free getenforce getent grep hostname id ps rpm runuser sed ss stat sysctl systemctl timedatectl tr uname; do
    if command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
        echo "PASS: Required command is available: $REQUIRED_COMMAND"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Required command is missing: $REQUIRED_COMMAND"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

echo ""
echo "=== Package and operating system settings ==="

if rpm -q "$PACKAGE_NAME" >/dev/null 2>&1; then
    PACKAGE_INSTALLED=1
    echo "PASS: Package is installed: $PACKAGE_NAME"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    if ! command -v yum >/dev/null 2>&1; then
        echo "FAIL: Package is not installed and yum is unavailable: $PACKAGE_NAME"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif yum -q list available "$PACKAGE_NAME" >/dev/null 2>&1; then
        echo "WARN: Package is available and will be installed: $PACKAGE_NAME"
        WARN_COUNT=$((WARN_COUNT + 1))
    else
        echo "FAIL: Package is not installed or available from enabled repositories: $PACKAGE_NAME"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

if [ -r "$PREINSTALL_SYSCTL" ]; then
    echo "PASS: Preinstall sysctl file is readable: $PREINSTALL_SYSCTL"
    PASS_COUNT=$((PASS_COUNT + 1))
elif [ "$PACKAGE_INSTALLED" -eq 1 ]; then
    echo "FAIL: Installed preinstall package is missing its sysctl file: $PREINSTALL_SYSCTL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    echo "WARN: Preinstall sysctl file will be provided by the package: $PREINSTALL_SYSCTL"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

if [ -e "$CUSTOM_SYSCTL" ] && [ ! -r "$CUSTOM_SYSCTL" ]; then
    echo "FAIL: Custom sysctl file is not readable: $CUSTOM_SYSCTL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
elif [ -r "$CUSTOM_SYSCTL" ]; then
    echo "PASS: Custom sysctl file is readable: $CUSTOM_SYSCTL"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "PASS: No custom Oracle sysctl file is configured."
    PASS_COUNT=$((PASS_COUNT + 1))
fi

if [ -r "$LIMITS_FILE" ]; then
    echo "PASS: Oracle limits file is readable: $LIMITS_FILE"
    PASS_COUNT=$((PASS_COUNT + 1))
elif [ "$PACKAGE_INSTALLED" -eq 1 ]; then
    echo "FAIL: Installed preinstall package is missing its limits file: $LIMITS_FILE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    echo "WARN: Oracle limits file will be provided by the package: $LIMITS_FILE"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

if [ -r "$SELINUX_CONFIG" ]; then
    CURRENT_SELINUX="$(getenforce 2>/dev/null)"
    if [ "$CURRENT_SELINUX" = "Disabled" ]; then
        echo "PASS: SELinux is disabled."
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "WARN: SELinux is ${CURRENT_SELINUX:-unknown}; the installer will configure it as disabled."
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
else
    echo "FAIL: SELinux configuration file is not readable: $SELINUX_CONFIG"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

for SERVICE_NAME in firewalld iptables; do
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${SERVICE_NAME}\.service[[:space:]]"; then
        SERVICE_ACTIVE="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)"
        SERVICE_ENABLED="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null)"
        if [ "$SERVICE_ACTIVE" = "inactive" ] &&
           { [ "$SERVICE_ENABLED" = "disabled" ] || [ "$SERVICE_ENABLED" = "masked" ]; }; then
            echo "PASS: $SERVICE_NAME is inactive and not enabled."
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo "WARN: $SERVICE_NAME will be stopped and disabled; active=$SERVICE_ACTIVE enabled=$SERVICE_ENABLED"
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    else
        echo "PASS: Service is not installed: $SERVICE_NAME"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
done

CURRENT_TIMEZONE="$(LC_ALL=C timedatectl 2>/dev/null | awk -F: '
    tolower($1) ~ /^[[:space:]]*time zone[[:space:]]*$/ {
        value=$2
        sub(/^[[:space:]]*/, "", value)
        split(value, fields, /[[:space:]]+/)
        print fields[1]
        exit
    }
')"
if [ "$CURRENT_TIMEZONE" = "$TIMEZONE" ]; then
    echo "PASS: Timezone is configured: $TIMEZONE"
    PASS_COUNT=$((PASS_COUNT + 1))
elif [ -n "$CURRENT_TIMEZONE" ]; then
    echo "WARN: Timezone will be changed from $CURRENT_TIMEZONE to $TIMEZONE."
    WARN_COUNT=$((WARN_COUNT + 1))
else
    echo "FAIL: Cannot determine the current timezone."
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo ""
echo "=== Memory and filesystem resources ==="

if MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)" &&
   SWAP_KB="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)" &&
   [ -n "$MEM_KB" ] && [ -n "$SWAP_KB" ]; then
    echo "PASS: Memory is $((MEM_KB / 1024)) MB; Swap is $((SWAP_KB / 1024)) MB."
    PASS_COUNT=$((PASS_COUNT + 1))
    if [ "$MEM_KB" -lt 2097152 ]; then
        echo "FAIL: At least 2 GB of RAM is required."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "PASS: Minimum memory requirement is satisfied."
        PASS_COUNT=$((PASS_COUNT + 1))
        if [ "$MEM_KB" -le 16777216 ]; then
            REQUIRED_SWAP_KB=$MEM_KB
        else
            REQUIRED_SWAP_KB=16777216
        fi
        if [ "$SWAP_KB" -ge "$REQUIRED_SWAP_KB" ]; then
            echo "PASS: Swap requirement is satisfied."
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo "FAIL: Swap must be at least $(((REQUIRED_SWAP_KB + 1023) / 1024)) MB."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
else
    echo "FAIL: Cannot read memory and Swap information."
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

for CHECK_PATH in /tmp /dev/shm; do
    if [ -d "$CHECK_PATH" ] && df -Pk "$CHECK_PATH" >/dev/null 2>&1; then
        echo "PASS: Filesystem is available: $CHECK_PATH"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Filesystem is unavailable: $CHECK_PATH"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

if id "$ORACLE_OWNER" >/dev/null 2>&1; then
    ORACLE_USER_EXISTS=1
    echo "PASS: Oracle owner exists: $ORACLE_OWNER"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    if [ "$PACKAGE_INSTALLED" -eq 1 ]; then
        echo "FAIL: Oracle owner is missing although the preinstall package is installed: $ORACLE_OWNER"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "WARN: Oracle owner will be created by the preinstall package: $ORACLE_OWNER"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
fi

for GROUP_NAME in "$ORACLE_GROUP" dba; do
    if getent group "$GROUP_NAME" >/dev/null 2>&1; then
        echo "PASS: Required group exists: $GROUP_NAME"
        PASS_COUNT=$((PASS_COUNT + 1))
    elif [ "$PACKAGE_INSTALLED" -eq 1 ]; then
        echo "FAIL: Required group is missing: $GROUP_NAME"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "WARN: Group will be created by the preinstall package: $GROUP_NAME"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
done

echo ""
echo "=== Oracle installation state ==="

INVENTORY_GROUP="$ORACLE_GROUP"
if [ -f "$ORAINST_FILE" ]; then
    DECLARED_ORA_INVENTORY="$(sed -n 's/^inventory_loc=//p' "$ORAINST_FILE")"
    DECLARED_INVENTORY_GROUP="$(sed -n 's/^inst_group=//p' "$ORAINST_FILE")"
    if [ -z "$DECLARED_ORA_INVENTORY" ] || [ -z "$DECLARED_INVENTORY_GROUP" ]; then
        echo "FAIL: oraInst.loc is missing inventory_loc or inst_group: $ORAINST_FILE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        ORA_INVENTORY="$DECLARED_ORA_INVENTORY"
        INVENTORY_GROUP="$DECLARED_INVENTORY_GROUP"
        INVENTORY_DECLARED=1
        echo "PASS: Existing Oracle Inventory is declared: $ORA_INVENTORY"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
else
    echo "WARN: Oracle Inventory will be created: $ORA_INVENTORY"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

INVENTORY_FILE="$ORA_INVENTORY/ContentsXML/inventory.xml"
if [ -f "$INSTALL_MARKER" ]; then
    if [ -f "$INVENTORY_FILE" ] && grep -Fq "LOC=\"$ORACLE_HOME\"" "$INVENTORY_FILE"; then
        INSTALL_COMPLETE=1
        echo "PASS: Installer marker and Inventory registration are consistent."
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Installer marker exists without matching Inventory registration."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
elif [ -f "$INVENTORY_FILE" ] && grep -Fq "LOC=\"$ORACLE_HOME\"" "$INVENTORY_FILE"; then
    echo "FAIL: Oracle Home is registered but the installer completion marker is missing."
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    echo "WARN: Oracle software installation has not completed."
    WARN_COUNT=$((WARN_COUNT + 1))
fi

for ORACLE_DIR in "$SOFTWARE_SOURCE_DIR" "$ORACLE_BASE" "$ORACLE_HOME" "$ORA_INVENTORY"; do
    if [ -e "$ORACLE_DIR" ] && [ ! -d "$ORACLE_DIR" ]; then
        echo "FAIL: Path exists but is not a directory: $ORACLE_DIR"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif [ -d "$ORACLE_DIR" ]; then
        echo "PASS: Directory exists: $ORACLE_DIR"
        PASS_COUNT=$((PASS_COUNT + 1))
    elif [ "$ORACLE_DIR" = "$ORA_INVENTORY" ] && [ "$INVENTORY_DECLARED" -eq 1 ]; then
        echo "FAIL: oraInst.loc points to a missing Inventory directory: $ORA_INVENTORY"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "WARN: Directory will be created: $ORACLE_DIR"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
done

if [ -d "$ORA_INVENTORY" ]; then
    if ! getent group "$INVENTORY_GROUP" >/dev/null 2>&1; then
        echo "FAIL: Oracle Inventory group does not exist: $INVENTORY_GROUP"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif [ "$(stat -c %G "$ORA_INVENTORY" 2>/dev/null)" != "$INVENTORY_GROUP" ]; then
        echo "FAIL: Oracle Inventory directory group does not match $INVENTORY_GROUP: $ORA_INVENTORY"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "PASS: Oracle Inventory directory group is correct: $INVENTORY_GROUP"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
    if [ "$ORACLE_USER_EXISTS" -eq 1 ]; then
        if id -nG "$ORACLE_OWNER" | tr ' ' '\n' | grep -Fxq "$INVENTORY_GROUP" &&
           runuser -u "$ORACLE_OWNER" -- test -r "$ORA_INVENTORY" &&
           runuser -u "$ORACLE_OWNER" -- test -w "$ORA_INVENTORY" &&
           runuser -u "$ORACLE_OWNER" -- test -x "$ORA_INVENTORY"; then
            echo "PASS: $ORACLE_OWNER can use the Oracle Inventory."
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo "FAIL: $ORACLE_OWNER cannot use Inventory group or directory: $ORA_INVENTORY"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
fi

if [ "$INSTALL_COMPLETE" -eq 0 ] && [ ! -f "$EXTRACT_MARKER" ]; then
    if [ -d "$ORACLE_HOME" ]; then
        FIRST_HOME_ENTRY="$(find "$ORACLE_HOME" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
        if [ -n "$FIRST_HOME_ENTRY" ]; then
            echo "FAIL: Oracle Home is not empty and has no extraction marker: $ORACLE_HOME"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "PASS: Oracle Home is empty and ready for extraction."
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
    fi
    if [ -f "$SOFTWARE_SOURCE_DIR/$ZIP_FILE" ]; then
        echo "PASS: Oracle Database 19c ZIP is available: $SOFTWARE_SOURCE_DIR/$ZIP_FILE"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Oracle Database 19c ZIP is missing: $SOFTWARE_SOURCE_DIR/$ZIP_FILE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
elif [ -f "$EXTRACT_MARKER" ] && [ ! -f "$ORACLE_HOME/runInstaller" ]; then
    echo "FAIL: Extraction marker exists but runInstaller is missing: $ORACLE_HOME/runInstaller"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    echo "PASS: Oracle Home extraction state is consistent."
    PASS_COUNT=$((PASS_COUNT + 1))
fi

if [ "$ORACLE_USER_EXISTS" -eq 1 ]; then
    for ORACLE_DIR in "$ORACLE_BASE" "$ORACLE_HOME"; do
        if [ -d "$ORACLE_DIR" ]; then
            if runuser -u "$ORACLE_OWNER" -- test -r "$ORACLE_DIR" &&
               runuser -u "$ORACLE_OWNER" -- test -w "$ORACLE_DIR" &&
               runuser -u "$ORACLE_OWNER" -- test -x "$ORACLE_DIR"; then
                echo "PASS: $ORACLE_OWNER can read, write, and access: $ORACLE_DIR"
                PASS_COUNT=$((PASS_COUNT + 1))
            else
                echo "FAIL: $ORACLE_OWNER cannot read, write, and access: $ORACLE_DIR"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        fi
    done
fi

if [ "$CREATE_DB" -eq 1 ]; then
    echo ""
    echo "=== Database and Listener target ==="

    if [[ "$ORACLE_SID" =~ ^[A-Z][A-Z0-9]{0,7}$ ]]; then
        echo "PASS: SID format is valid: $ORACLE_SID"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: SID must contain 1-8 uppercase letters or digits and start with a letter."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    if [[ "$LISTENER_PORT" =~ ^[1-9][0-9]{3,4}$ ]] &&
       [ "$LISTENER_PORT" -ge 1024 ] && [ "$LISTENER_PORT" -le 65535 ]; then
        echo "PASS: Listener port format is valid: $LISTENER_PORT"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Listener port must be between 1024 and 65535."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    if [ -z "$DB_SERVICE" ]; then
        DB_SERVICE="$ORACLE_SID"
    fi
    LISTENER_NAME="LSNR_$ORACLE_SID"

    if [[ "$DB_SERVICE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "PASS: Database service format is valid: $DB_SERVICE"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Database service contains unsupported characters: $DB_SERVICE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    if [ -r /etc/oratab ]; then
        if awk -F: -v name="$ORACLE_SID" '$0 !~ /^[[:space:]]*#/ && toupper($1)==name {found=1} END {exit !found}' /etc/oratab; then
            echo "FAIL: Target database is already registered in /etc/oratab: $ORACLE_SID"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "PASS: Target database is not registered in /etc/oratab."
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
    else
        echo "WARN: /etc/oratab is not available before software root scripts run."
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    if ps -eo args= 2>/dev/null | grep -Eiq "^ora_pmon_$ORACLE_SID([[:space:]]|$)"; then
        echo "FAIL: Target database instance is already running: $ORACLE_SID"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "PASS: Target database instance is not running."
        PASS_COUNT=$((PASS_COUNT + 1))
    fi

    if [ -d "$ORACLE_HOME/dbs" ]; then
        DB_FILES="$(find "$ORACLE_HOME/dbs" -maxdepth 1 \( -iname "spfile$ORACLE_SID.ora" -o -iname "init$ORACLE_SID.ora" -o -iname "orapw$ORACLE_SID" -o -iname "lk$ORACLE_SID" \) -print 2>/dev/null)"
        if [ -n "$DB_FILES" ]; then
            echo "FAIL: Target database files already exist in Oracle Home: $DB_FILES"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "PASS: No target database files exist in Oracle Home."
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
    else
        echo "WARN: Oracle dbs directory will be installed before database creation."
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    for ROOT_DIR in "$DATA_DIR" "$FRA_DIR"; do
        if [[ "$ROOT_DIR" != /* ]] || [ "$ROOT_DIR" = / ]; then
            echo "FAIL: Storage root must be an absolute path other than /: $ROOT_DIR"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif [ -L "$ROOT_DIR/$ORACLE_SID" ]; then
            echo "FAIL: Target database directory must not be a symbolic link: $ROOT_DIR/$ORACLE_SID"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif [ -e "$ROOT_DIR/$ORACLE_SID" ]; then
            echo "FAIL: Target database directory already exists: $ROOT_DIR/$ORACLE_SID"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif [ -e "$ROOT_DIR" ] && [ ! -d "$ROOT_DIR" ]; then
            echo "FAIL: Storage root exists but is not a directory: $ROOT_DIR"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif [ -d "$ROOT_DIR" ]; then
            echo "PASS: Storage root is ready: $ROOT_DIR"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo "WARN: Storage root will be created: $ROOT_DIR"
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    done

    LISTENER_FILE="$ORACLE_HOME/network/admin/listener.ora"
    if [ -e "$LISTENER_FILE" ] && [ ! -r "$LISTENER_FILE" ]; then
        echo "FAIL: Listener configuration is not readable: $LISTENER_FILE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif [ -r "$LISTENER_FILE" ]; then
        LISTENER_CONFIG="$(sed 's/#.*//' "$LISTENER_FILE")"
        if printf '%s\n' "$LISTENER_CONFIG" | grep -Eiq '^[[:space:]]*IFILE[[:space:]]*='; then
            echo "FAIL: Included Listener configuration requires manual review: $LISTENER_FILE"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif printf '%s\n' "$LISTENER_CONFIG" | grep -Eiq "^[[:space:]]*$LISTENER_NAME[[:space:]]*="; then
            echo "FAIL: Listener name is already configured: $LISTENER_NAME"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif printf '%s\n' "$LISTENER_CONFIG" | tr -d '[:space:]' | grep -Eiq "\\(PORT=0*$LISTENER_PORT\\)"; then
            echo "FAIL: Listener port is already configured: $LISTENER_PORT"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "PASS: Listener name and port are not configured."
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
    else
        echo "PASS: No existing listener.ora conflicts with the target."
        PASS_COUNT=$((PASS_COUNT + 1))
    fi

    if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":$LISTENER_PORT$"; then
        echo "FAIL: Listener TCP port is already in use: $LISTENER_PORT"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "PASS: Listener TCP port is available: $LISTENER_PORT"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi

    if [ "$INSTALL_COMPLETE" -eq 1 ]; then
        for ORACLE_TOOL in dbca lsnrctl sqlplus; do
            if [ -x "$ORACLE_HOME/bin/$ORACLE_TOOL" ]; then
                echo "PASS: Oracle tool is available: $ORACLE_TOOL"
                PASS_COUNT=$((PASS_COUNT + 1))
            else
                echo "FAIL: Installed Oracle Home is missing tool: $ORACLE_TOOL"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        done
    else
        echo "WARN: Oracle database tools will be checked again after software installation."
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
fi

echo ""
echo "========================================"
echo " Precheck Summary"
echo "========================================"
echo "PASS: $PASS_COUNT"
echo "WARN: $WARN_COUNT"
echo "FAIL: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "Precheck failed. No installation changes were made by this script."
    exit 1
fi

echo "Precheck passed. Warnings may be handled by the installation script."
exit 0
