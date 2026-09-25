#!/bin/bash

# Read-only pre-install checks for Oracle Linux 7 / 8 and Oracle Database 19c.

if ! SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; then
    echo "FAIL: Cannot determine the script directory."
    exit 1
fi
CONFIG_FILE="$SCRIPT_DIR/oracle_install.conf"

if [ -L "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    echo "FAIL: Configuration must be a regular file: $CONFIG_FILE"
    exit 1
fi

if ! . "$CONFIG_FILE"; then
    echo "FAIL: Failed to load configuration: $CONFIG_FILE"
    exit 1
fi

if [ -z "${PACKAGE_NAME:-}" ] || [ -z "${PREINSTALL_SYSCTL:-}" ] ||
   [ -z "${CUSTOM_SYSCTL:-}" ] || [ -z "${LIMITS_FILE:-}" ] ||
   [ -z "${SELINUX_CONFIG:-}" ] || [ -z "${TIMEZONE:-}" ] ||
   [ -z "${SOFTWARE_SOURCE_DIR:-}" ] || [ -z "${ZIP_FILE:-}" ] ||
   [ -z "${ORACLE_BASE:-}" ] || [ -z "${ORACLE_HOME:-}" ] ||
   [ -z "${ORA_INVENTORY:-}" ] || [ -z "${ORAINST_FILE:-}" ] ||
   [ -z "${ORACLE_OWNER:-}" ] || [ -z "${ORACLE_GROUP:-}" ] ||
   [ -z "${DATA_DIR:-}" ] || [ -z "${FRA_DIR:-}" ]; then
    echo "FAIL: Required settings are missing from: $CONFIG_FILE"
    exit 1
fi

EXTRACT_MARKER="$ORACLE_HOME/.oracle_19c_extraction_complete"
INSTALL_MARKER="$ORACLE_HOME/.oracle_19c_installer_complete"
ORAINST_ROOT_MARKER="$ORA_INVENTORY/.orainstRoot_complete"
ROOT_SH_MARKER="$ORACLE_HOME/.root_sh_complete"
DB_HOST="$(hostname -f 2>/dev/null)"
DB_SERVICE=""
CREATE_DB=0
ORACLE_SID=""
LISTENER_PORT=""
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
OS_MAJOR=""
PACKAGE_INSTALLED=0
ORACLE_USER_EXISTS=0
EXTRACT_COMPLETE=0
INSTALL_COMPLETE=0
ORAINST_ROOT_COMPLETE=0
ROOT_SH_COMPLETE=0
INVENTORY_DECLARED=0
TMP_MINIMUM_MB=1024
ORACLE_SOFTWARE_MINIMUM_MB=7373
ORACLE_SOFTWARE_RECOMMENDED_MB=102400

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
        --help)
            echo "Usage: $0 [--create-db --sid SID --listener-port PORT]"
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
    OS_MAJOR="${VERSION_ID%%.*}"
    case "$ID:$OS_MAJOR" in
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

for REQUIRED_COMMAND in awk df dirname find free getenforce getent grep hostname id ps rpm runuser sed sort ss stat sysctl systemctl timedatectl tr uname; do
    if command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
        echo "PASS: Required command is available: $REQUIRED_COMMAND"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Required command is missing: $REQUIRED_COMMAND"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

# Check the running kernel against Oracle Database 19c documented minimums.
KERNEL_RELEASE=""
KERNEL_FAMILY=""
MINIMUM_KERNEL=""
KERNEL_RU_NOTE=""

if ! KERNEL_RELEASE="$(uname -r 2>/dev/null)" || [ -z "$KERNEL_RELEASE" ]; then
    echo "FAIL: Unable to determine the running kernel release with uname -r."
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    echo "Running kernel: $KERNEL_RELEASE"

    case "$OS_MAJOR" in
        7)
            case "$KERNEL_RELEASE" in
                4.1.*el7uek*)
                    KERNEL_FAMILY="Oracle Linux 7 UEK4"
                    MINIMUM_KERNEL="4.1.12-124.19.2.el7uek.x86_64"
                    ;;
                4.14.*el7uek*)
                    KERNEL_FAMILY="Oracle Linux 7 UEK5"
                    MINIMUM_KERNEL="4.14.35-1818.1.6.el7uek.x86_64"
                    ;;
                5.4.*el7uek*)
                    KERNEL_FAMILY="Oracle Linux 7 UEK6"
                    MINIMUM_KERNEL="5.4.17-2011.4.4.el7uek.x86_64"
                    KERNEL_RU_NOTE="Oracle Linux 7 UEK6 requires Oracle Database 19c RU 19.9 or later; the current Oracle Home RU is not checked."
                    ;;
                *uek*)
                    ;;
                3.10.*el7*)
                    KERNEL_FAMILY="Oracle Linux 7 RHCK"
                    MINIMUM_KERNEL="3.10.0-862.11.6.el7.x86_64"
                    ;;
            esac
            ;;
        8)
            case "$KERNEL_RELEASE" in
                5.4.*el8uek*)
                    KERNEL_FAMILY="Oracle Linux 8 UEK6"
                    MINIMUM_KERNEL="5.4.17-2011.0.7.el8uek.x86_64"
                    ;;
                5.15.*el8uek*)
                    KERNEL_FAMILY="Oracle Linux 8 UEK7"
                    MINIMUM_KERNEL="5.15.0-202.135.2.el8uek.x86_64"
                    KERNEL_RU_NOTE="Oracle Linux 8 UEK7 requires Oracle Database 19c RU 19.21 or later; the current Oracle Home RU is not checked."
                    ;;
                *uek*)
                    ;;
                4.18.*el8*)
                    KERNEL_FAMILY="Oracle Linux 8 RHCK"
                    MINIMUM_KERNEL="4.18.0-80.el8.x86_64"
                    ;;
            esac
            ;;
    esac

    if [ -z "$MINIMUM_KERNEL" ]; then
        echo "WARN: Kernel family is not recognized for Oracle Linux ${OS_MAJOR:-unknown}: $KERNEL_RELEASE"
        echo "WARN: Verify this kernel and Oracle Database 19c combination in Oracle Certification."
        WARN_COUNT=$((WARN_COUNT + 1))
    elif ! command -v sort >/dev/null 2>&1; then
        echo "WARN: Kernel minimum could not be evaluated because GNU sort is unavailable."
    elif printf '%s\n%s\n' "$MINIMUM_KERNEL" "$KERNEL_RELEASE" | LC_ALL=C sort -V -C; then
        echo "PASS: Running kernel meets the documented minimum for $KERNEL_FAMILY: $KERNEL_RELEASE"
        echo "INFO: This checks the kernel minimum only; Oracle RU and full certification are not verified."
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Running kernel is below the documented minimum for $KERNEL_FAMILY: $KERNEL_RELEASE"
        echo "FAIL: Minimum kernel: $MINIMUM_KERNEL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    if [ -n "$KERNEL_RU_NOTE" ]; then
        echo "INFO: $KERNEL_RU_NOTE"
    fi
fi
# End running kernel check.

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

echo ""
echo "Transparent HugePages status:"
if [ -r /sys/kernel/mm/transparent_hugepage/enabled ]; then
    cat /sys/kernel/mm/transparent_hugepage/enabled
else
    echo "WARN: Transparent HugePages status file was not found."
    WARN_COUNT=$((WARN_COUNT + 1))
fi

if [ -d /tmp ]; then
    TMP_AVAILABLE_MB="$(df -Pm /tmp 2>/dev/null | awk 'NR == 2 {print $4}')"
    if [[ "$TMP_AVAILABLE_MB" =~ ^[0-9]+$ ]]; then
        echo "INFO: /tmp available space is $TMP_AVAILABLE_MB MB."
        if [ "$TMP_AVAILABLE_MB" -ge "$TMP_MINIMUM_MB" ]; then
            echo "PASS: /tmp has at least 1 GB of available space."
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo "FAIL: /tmp must have at least 1 GB of available space."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "FAIL: Cannot determine available space for /tmp."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    echo "FAIL: Filesystem path is unavailable: /tmp"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if [ -d /dev/shm ] && df -Pk /dev/shm >/dev/null 2>&1; then
    echo "PASS: Filesystem is available: /dev/shm"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "FAIL: Filesystem is unavailable: /dev/shm"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

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
if [ -L "$ORAINST_FILE" ] ||
   { [ -e "$ORAINST_FILE" ] && [ ! -f "$ORAINST_FILE" ]; }; then
    echo "FAIL: oraInst.loc must be a regular file: $ORAINST_FILE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
elif [ -f "$ORAINST_FILE" ]; then
    DECLARED_ORA_INVENTORY="$(sed -n 's/^inventory_loc=//p' "$ORAINST_FILE")"
    DECLARED_INVENTORY_GROUP="$(sed -n 's/^inst_group=//p' "$ORAINST_FILE")"
    if [ -z "$DECLARED_ORA_INVENTORY" ] || [ -z "$DECLARED_INVENTORY_GROUP" ]; then
        echo "FAIL: oraInst.loc is missing inventory_loc or inst_group: $ORAINST_FILE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif [ "$DECLARED_ORA_INVENTORY" != "$ORA_INVENTORY" ] ||
         [ "$DECLARED_INVENTORY_GROUP" != "$ORACLE_GROUP" ]; then
        echo "FAIL: oraInst.loc does not match oracle_install.conf: $ORAINST_FILE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        INVENTORY_DECLARED=1
        echo "PASS: Existing Oracle Inventory is declared: $ORA_INVENTORY"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
else
    echo "WARN: Oracle Inventory will be created: $ORA_INVENTORY"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

INVENTORY_FILE="$ORA_INVENTORY/ContentsXML/inventory.xml"
for COMPLETION_MARKER in "$EXTRACT_MARKER" "$INSTALL_MARKER" \
    "$ORAINST_ROOT_MARKER" "$ROOT_SH_MARKER"; do
    if [ -L "$COMPLETION_MARKER" ] ||
       { [ -e "$COMPLETION_MARKER" ] && [ ! -f "$COMPLETION_MARKER" ]; }; then
        echo "FAIL: Completion marker must be a regular file: $COMPLETION_MARKER"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

if [ -f "$EXTRACT_MARKER" ] && [ ! -L "$EXTRACT_MARKER" ]; then
    EXTRACT_COMPLETE=1
fi

if [ -f "$INSTALL_MARKER" ] && [ ! -L "$INSTALL_MARKER" ]; then
    if ! IFS= read -r INSTALL_BATCH_ID < "$INSTALL_MARKER" ||
       [ -z "$INSTALL_BATCH_ID" ]; then
        echo "FAIL: Installer completion marker has no installation batch ID: $INSTALL_MARKER"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif [ -f "$INVENTORY_FILE" ] && grep -Fq "LOC=\"$ORACLE_HOME\"" "$INVENTORY_FILE"; then
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

echo ""
echo "--- Oracle Home filesystem capacity ---"

ORACLE_HOME_CHECK_PATH="$ORACLE_HOME"
while [ ! -e "$ORACLE_HOME_CHECK_PATH" ]; do
    PARENT_PATH="$(dirname "$ORACLE_HOME_CHECK_PATH")"
    if [ "$PARENT_PATH" = "$ORACLE_HOME_CHECK_PATH" ]; then
        break
    fi
    ORACLE_HOME_CHECK_PATH="$PARENT_PATH"
done

ORACLE_HOME_AVAILABLE_MB="$(df -Pm "$ORACLE_HOME_CHECK_PATH" 2>/dev/null | awk 'NR == 2 {print $4}')"
if [[ "$ORACLE_HOME_AVAILABLE_MB" =~ ^[0-9]+$ ]]; then
    echo "INFO: Oracle Home filesystem available space is $ORACLE_HOME_AVAILABLE_MB MB."
    echo "INFO: Filesystem check path: $ORACLE_HOME_CHECK_PATH"
    # Require 7.2 GB only before Oracle Home extraction.
    if [ "$EXTRACT_COMPLETE" -eq 0 ] &&
       [ "$ORACLE_HOME_AVAILABLE_MB" -lt "$ORACLE_SOFTWARE_MINIMUM_MB" ]; then
        echo "FAIL: Oracle Home filesystem must have at least 7.2 GB available before extraction."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif [ "$ORACLE_HOME_AVAILABLE_MB" -lt "$ORACLE_SOFTWARE_RECOMMENDED_MB" ]; then
        echo "WARN: Oracle Home filesystem has less than the recommended 100 GB of available space."
        WARN_COUNT=$((WARN_COUNT + 1))
    else
        echo "PASS: Oracle Home filesystem has at least 100 GB of available space."
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
else
    echo "FAIL: Cannot determine available space for Oracle Home: $ORACLE_HOME"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if [ "$INSTALL_COMPLETE" -eq 1 ] && [ "$EXTRACT_COMPLETE" -eq 0 ]; then
    echo "FAIL: Installer completion is recorded but the extraction marker is missing."
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if [ -f "$ORAINST_ROOT_MARKER" ] && [ ! -L "$ORAINST_ROOT_MARKER" ]; then
    if [ "$INSTALL_COMPLETE" -eq 1 ]; then
        ORAINST_ROOT_COMPLETE=1
        echo "PASS: orainstRoot.sh completion marker is present."
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: orainstRoot.sh marker exists before installer completion is verified."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
elif [ ! -e "$ORAINST_ROOT_MARKER" ] && [ ! -L "$ORAINST_ROOT_MARKER" ] &&
     [ "$INSTALL_COMPLETE" -eq 1 ]; then
    echo "WARN: orainstRoot.sh has not completed; the installer will resume this stage."
    WARN_COUNT=$((WARN_COUNT + 1))
fi

if [ -f "$ROOT_SH_MARKER" ] && [ ! -L "$ROOT_SH_MARKER" ]; then
    if [ "$INSTALL_COMPLETE" -eq 1 ] && [ "$ORAINST_ROOT_COMPLETE" -eq 1 ]; then
        ROOT_SH_COMPLETE=1
        echo "PASS: root.sh completion marker is present."
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: root.sh marker exists before earlier software stages are complete."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
elif [ ! -e "$ROOT_SH_MARKER" ] && [ ! -L "$ROOT_SH_MARKER" ] &&
     [ "$ORAINST_ROOT_COMPLETE" -eq 1 ]; then
    echo "WARN: root.sh has not completed; the installer will resume this stage."
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

if [ "$INSTALL_COMPLETE" -eq 0 ] && [ "$EXTRACT_COMPLETE" -eq 0 ]; then
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
elif [ "$EXTRACT_COMPLETE" -eq 1 ] && [ ! -f "$ORACLE_HOME/runInstaller" ]; then
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
    LISTENER_MARKER="$ORACLE_HOME/network/admin/.LSNR_${ORACLE_SID}_complete"
    DATABASE_MARKER="$ORACLE_BASE/.DB_${ORACLE_SID}_complete"
    LISTENER_COMPLETE=0
    DATABASE_COMPLETE=0

    if [[ "$DB_SERVICE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "PASS: Database service format is valid: $DB_SERVICE"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Database service contains unsupported characters: $DB_SERVICE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    for COMPLETION_MARKER in "$LISTENER_MARKER" "$DATABASE_MARKER"; do
        if [ -L "$COMPLETION_MARKER" ] ||
           { [ -e "$COMPLETION_MARKER" ] && [ ! -f "$COMPLETION_MARKER" ]; }; then
            echo "FAIL: Completion marker must be a regular file: $COMPLETION_MARKER"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done

    if [ -f "$LISTENER_MARKER" ] && [ ! -L "$LISTENER_MARKER" ]; then
        LISTENER_COMPLETE=1
    fi
    if [ -f "$DATABASE_MARKER" ] && [ ! -L "$DATABASE_MARKER" ]; then
        DATABASE_COMPLETE=1
    fi

    if [ "$LISTENER_COMPLETE" -eq 1 ] && [ "$ROOT_SH_COMPLETE" -eq 0 ]; then
        echo "FAIL: Listener marker exists before root.sh completion is verified."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    if [ "$DATABASE_COMPLETE" -eq 1 ] && [ "$LISTENER_COMPLETE" -eq 0 ]; then
        echo "FAIL: Database marker exists without the Listener completion marker."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    if [ "$DATABASE_COMPLETE" -eq 1 ] && [ "$ROOT_SH_COMPLETE" -eq 0 ]; then
        echo "FAIL: Database marker exists before root.sh completion is verified."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    REGISTERED_DB=""
    if [ -r /etc/oratab ]; then
        if ! REGISTERED_DB=$(awk -F: -v name="$ORACLE_SID" '$0 !~ /^[[:space:]]*#/ && toupper($1)==name {print}' /etc/oratab); then
            echo "FAIL: Cannot inspect /etc/oratab."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    elif [ "$DATABASE_COMPLETE" -eq 1 ]; then
        echo "FAIL: Database marker exists but /etc/oratab is not readable."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "WARN: /etc/oratab is not available before software root scripts run."
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    PROCESS_LIST=""
    DB_RUNNING=0
    LISTENER_RUNNING=0
    if ! PROCESS_LIST=$(ps -eo args= 2>/dev/null); then
        echo "FAIL: Cannot inspect running processes."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    if printf '%s\n' "$PROCESS_LIST" | grep -Eiq "^ora_pmon_$ORACLE_SID([[:space:]]|$)"; then
        DB_RUNNING=1
    fi
    if printf '%s\n' "$PROCESS_LIST" | grep -Eiq "(^|/)tnslsnr[[:space:]]+$LISTENER_NAME([[:space:]]|$)"; then
        LISTENER_RUNNING=1
    fi

    DB_FILES=""
    if [ -d "$ORACLE_HOME/dbs" ]; then
        if ! DB_FILES=$(find "$ORACLE_HOME/dbs" -maxdepth 1 \( -iname "spfile$ORACLE_SID.ora" -o -iname "init$ORACLE_SID.ora" -o -iname "orapw$ORACLE_SID" -o -iname "lk$ORACLE_SID" \) -print 2>/dev/null); then
            echo "FAIL: Cannot inspect target database files in Oracle Home."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi

    if [ "$DATABASE_COMPLETE" -eq 1 ]; then
        if [ -z "$REGISTERED_DB" ]; then
            echo "FAIL: Database marker exists but /etc/oratab has no target entry."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            REGISTERED_COUNT=$(printf '%s\n' "$REGISTERED_DB" | awk 'NF {count++} END {print count + 0}')
            REGISTERED_HOME=$(printf '%s\n' "$REGISTERED_DB" | awk -F: 'NF {print $2; exit}')
            if [ "$REGISTERED_COUNT" -ne 1 ] || [ "$REGISTERED_HOME" != "$ORACLE_HOME" ]; then
                echo "FAIL: Database marker and /etc/oratab are inconsistent for $ORACLE_SID."
                FAIL_COUNT=$((FAIL_COUNT + 1))
            else
                echo "PASS: Database marker and /etc/oratab are consistent."
                PASS_COUNT=$((PASS_COUNT + 1))
            fi
        fi

        if [ ! -f "$ORACLE_HOME/dbs/spfile$ORACLE_SID.ora" ]; then
            echo "FAIL: Database marker exists but the target spfile is missing."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "PASS: Target database spfile is present."
            PASS_COUNT=$((PASS_COUNT + 1))
        fi

        for ROOT_DIR in "$DATA_DIR" "$FRA_DIR"; do
            if [[ "$ROOT_DIR" != /* ]] || [ "$ROOT_DIR" = / ]; then
                echo "FAIL: Storage root must be an absolute path other than /: $ROOT_DIR"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            elif [ -L "$ROOT_DIR/$ORACLE_SID" ] || [ ! -d "$ROOT_DIR/$ORACLE_SID" ]; then
                echo "FAIL: Database marker exists but the target directory is unavailable: $ROOT_DIR/$ORACLE_SID"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            else
                echo "PASS: Target database directory is present: $ROOT_DIR/$ORACLE_SID"
                PASS_COUNT=$((PASS_COUNT + 1))
            fi
        done

        if [ "$DB_RUNNING" -eq 1 ]; then
            if [ ! -x "$ORACLE_HOME/bin/sqlplus" ]; then
                echo "FAIL: Database is running but SQL*Plus is unavailable."
                FAIL_COUNT=$((FAIL_COUNT + 1))
            elif ! DATABASE_STATUS=$(runuser -u "$ORACLE_OWNER" -- env \
                ORACLE_SID="$ORACLE_SID" ORACLE_HOME="$ORACLE_HOME" \
                PATH="$ORACLE_HOME/bin:/usr/bin:/bin" LD_LIBRARY_PATH="$ORACLE_HOME/lib" \
                "$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<'SQL'
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF PAGES 0 VERIFY OFF ECHO OFF
SELECT name || ':' || open_mode FROM v$database;
EXIT SUCCESS
SQL
            ); then
                echo "FAIL: Database marker exists but OS authentication failed."
                FAIL_COUNT=$((FAIL_COUNT + 1))
            elif printf '%s\n' "$DATABASE_STATUS" | grep -Eq "^[[:space:]]*$ORACLE_SID:READ WRITE[[:space:]]*$"; then
                echo "PASS: Completed database is running and open read write."
                PASS_COUNT=$((PASS_COUNT + 1))
            else
                echo "FAIL: Database marker and database identity or open mode are inconsistent."
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        else
            echo "WARN: Completed database is stopped; the installer will start and verify it."
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    else
        if [ -n "$REGISTERED_DB" ]; then
            echo "FAIL: Target database is registered without its completion marker: $ORACLE_SID"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "PASS: Target database is not registered in /etc/oratab."
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
        if [ "$DB_RUNNING" -eq 1 ]; then
            echo "FAIL: Target database is running without its completion marker: $ORACLE_SID"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "PASS: Target database instance is not running."
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
        if [ -n "$DB_FILES" ]; then
            echo "FAIL: Target database files exist without its completion marker: $DB_FILES"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif [ -d "$ORACLE_HOME/dbs" ]; then
            echo "PASS: No target database files exist in Oracle Home."
            PASS_COUNT=$((PASS_COUNT + 1))
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
                echo "FAIL: Target database directory exists without its completion marker: $ROOT_DIR/$ORACLE_SID"
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
    fi

    LISTENER_FILE="$ORACLE_HOME/network/admin/listener.ora"
    LISTENER_CONFIG=""
    if [ -e "$LISTENER_FILE" ] && [ ! -r "$LISTENER_FILE" ]; then
        echo "FAIL: Listener configuration is not readable: $LISTENER_FILE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif [ -r "$LISTENER_FILE" ]; then
        if ! LISTENER_CONFIG=$(sed 's/#.*//' "$LISTENER_FILE"); then
            echo "FAIL: Cannot inspect Listener configuration: $LISTENER_FILE"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif printf '%s\n' "$LISTENER_CONFIG" | grep -Eiq '^[[:space:]]*IFILE[[:space:]]*='; then
            echo "FAIL: Included Listener configuration requires manual review: $LISTENER_FILE"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi

    SOCKETS=""
    PORT_IN_USE=0
    if ! SOCKETS=$(ss -H -ltn 2>/dev/null); then
        echo "FAIL: Cannot inspect listening TCP ports."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    if printf '%s\n' "$SOCKETS" | awk '{print $4}' | grep -Eq ":$LISTENER_PORT$"; then
        PORT_IN_USE=1
    fi

    if [ "$LISTENER_COMPLETE" -eq 1 ]; then
        if [ ! -r "$LISTENER_FILE" ]; then
            echo "FAIL: Listener marker exists but listener.ora is unavailable."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif ! printf '%s\n' "$LISTENER_CONFIG" | grep -Eiq "^[[:space:]]*$LISTENER_NAME[[:space:]]*=" ||
             ! printf '%s\n' "$LISTENER_CONFIG" | tr -d '[:space:]' | grep -Fiq "(HOST=$DB_HOST)" ||
             ! printf '%s\n' "$LISTENER_CONFIG" | tr -d '[:space:]' | grep -Eiq "\\(PORT=0*$LISTENER_PORT\\)"; then
            echo "FAIL: Listener marker and listener.ora are inconsistent."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "PASS: Listener marker and listener.ora are consistent."
            PASS_COUNT=$((PASS_COUNT + 1))
        fi

        if [ "$LISTENER_RUNNING" -eq 1 ]; then
            if [ ! -x "$ORACLE_HOME/bin/lsnrctl" ]; then
                echo "FAIL: Listener is running but lsnrctl is unavailable."
                FAIL_COUNT=$((FAIL_COUNT + 1))
            elif ! LISTENER_STATUS=$(runuser -u "$ORACLE_OWNER" -- env \
                ORACLE_HOME="$ORACLE_HOME" TNS_ADMIN="$ORACLE_HOME/network/admin" \
                PATH="$ORACLE_HOME/bin:/usr/bin:/bin" LD_LIBRARY_PATH="$ORACLE_HOME/lib" \
                "$ORACLE_HOME/bin/lsnrctl" status "$LISTENER_NAME" 2>&1); then
                echo "FAIL: Listener marker exists but Listener status verification failed."
                FAIL_COUNT=$((FAIL_COUNT + 1))
            elif printf '%s\n' "$LISTENER_STATUS" | tr -d '[:space:]' | grep -Fiq "(HOST=$DB_HOST)(PORT=$LISTENER_PORT)"; then
                echo "PASS: Completed Listener is running on the expected endpoint."
                PASS_COUNT=$((PASS_COUNT + 1))
            else
                echo "FAIL: Listener marker and active endpoint are inconsistent."
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        elif [ "$PORT_IN_USE" -eq 1 ]; then
            echo "FAIL: Completed Listener is stopped but its TCP port is used by another process."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "WARN: Completed Listener is stopped; the installer will start and verify it."
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    else
        if printf '%s\n' "$LISTENER_CONFIG" | grep -Eiq "^[[:space:]]*$LISTENER_NAME[[:space:]]*=" ||
           printf '%s\n' "$LISTENER_CONFIG" | tr -d '[:space:]' | grep -Eiq "\\(PORT=0*$LISTENER_PORT\\)"; then
            echo "FAIL: Listener name or port is configured without its completion marker."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "PASS: Listener name and port are not configured."
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
        if [ "$LISTENER_RUNNING" -eq 1 ]; then
            echo "FAIL: Target Listener is running without its completion marker."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif [ "$PORT_IN_USE" -eq 1 ]; then
            echo "FAIL: Listener TCP port is already in use: $LISTENER_PORT"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "PASS: Listener TCP port is available: $LISTENER_PORT"
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
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
