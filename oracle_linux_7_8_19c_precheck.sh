#!/bin/bash

# Read-only pre-install checks for Oracle Linux 8 and Oracle Database 19c.
#
# Result policy for Main or a DBA:
#   PASS = requirement is currently satisfied.
#   WARN = Main can create or change the expected new-server state.
#   FAIL = installation must stop for correction or DBA review.
# This script never installs packages, edits files, starts services, or creates
# Oracle resources. It exits 1 when at least one FAIL is recorded.

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

if [ -z "${ORACLE_HOME:-}" ] || [ -z "${ORA_INVENTORY:-}" ] ||
   [ -z "${ORAINST_FILE:-}" ] || [ -z "${ORACLE_GROUP:-}" ]; then
    echo "FAIL: Oracle Home or Inventory settings are missing from: $CONFIG_FILE"
    exit 1
fi

INSTALL_MARKER="$ORACLE_HOME/.oracle_19c_installer_complete"
ORAINST_ROOT_MARKER="$ORA_INVENTORY/.orainstRoot_complete"
ROOT_SH_MARKER="$ORACLE_HOME/.root_sh_complete"

# Fixed paths come from oracle_install.conf. SID and Listener port are runtime
# deployment identifiers and are accepted only through explicit arguments.
DB_HOST=""
DB_SERVICE=""
CREATE_DB=0
TARGET_ONLY=0
ORACLE_SID=""
LISTENER_PORT=""
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

OS_MAJOR=""
PACKAGE_INSTALLED=0
ORACLE_USER_EXISTS=0
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
        --target-only)
            CREATE_DB=1
            TARGET_ONLY=1
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
            echo "       $0 --target-only --sid SID --listener-port PORT"
            exit 0
            ;;
        *)
            echo "FAIL: Unknown option: $1"
            exit 1
            ;;
    esac
done

# Oracle Software is the first stopping condition. Do not inspect root scripts,
# Listener, Database, Profile, or PostCheck after installed software is found.
if ! command -v grep >/dev/null 2>&1; then
    echo "FAIL: Required command is missing: grep"
    echo "PRECHECK RESULT: FAIL"
    exit 1
fi

if [ -L "$ORAINST_FILE" ] ||
   { [ -e "$ORAINST_FILE" ] && [ ! -f "$ORAINST_FILE" ]; }; then
    echo "FAIL: oraInst.loc must be a regular file: $ORAINST_FILE"
    echo "PRECHECK RESULT: FAIL"
    exit 1
elif [ -f "$ORAINST_FILE" ]; then
    if ! command -v sed >/dev/null 2>&1; then
        echo "FAIL: Required command is missing: sed"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
    DECLARED_ORA_INVENTORY="$(sed -n 's/^inventory_loc=//p' "$ORAINST_FILE")"
    DECLARED_INVENTORY_GROUP="$(sed -n 's/^inst_group=//p' "$ORAINST_FILE")"
    if [ -z "$DECLARED_ORA_INVENTORY" ] || [ -z "$DECLARED_INVENTORY_GROUP" ]; then
        echo "FAIL: oraInst.loc is missing inventory_loc or inst_group: $ORAINST_FILE"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
    if [ "$DECLARED_ORA_INVENTORY" != "$ORA_INVENTORY" ] ||
       [ "$DECLARED_INVENTORY_GROUP" != "$ORACLE_GROUP" ]; then
        echo "FAIL: oraInst.loc does not match oracle_install.conf: $ORAINST_FILE"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
    INVENTORY_DECLARED=1
else
    if [ -L "$ORA_INVENTORY" ] ||
       { [ -e "$ORA_INVENTORY" ] && [ ! -d "$ORA_INVENTORY" ]; }; then
        echo "FAIL: Undeclared Oracle Inventory path must be a normal directory: $ORA_INVENTORY"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    elif [ -d "$ORA_INVENTORY" ]; then
        if ! command -v find >/dev/null 2>&1; then
            echo "FAIL: Required command is missing: find"
            echo "PRECHECK RESULT: FAIL"
            exit 1
        fi
        FIRST_INVENTORY_ENTRY="$(find "$ORA_INVENTORY" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
        INVENTORY_FIND_STATUS=$?
        if [ "$INVENTORY_FIND_STATUS" -ne 0 ]; then
            echo "FAIL: Cannot safely inspect undeclared Oracle Inventory: $ORA_INVENTORY"
            echo "PRECHECK RESULT: FAIL"
            exit 1
        elif [ -n "$FIRST_INVENTORY_ENTRY" ]; then
            echo "FAIL: Undeclared Oracle Inventory is not empty: $ORA_INVENTORY"
            echo "DBA review is required before installation."
            echo "PRECHECK RESULT: FAIL"
            exit 1
        fi
    fi
fi

SOFTWARE_INVENTORY_FILE="$ORA_INVENTORY/ContentsXML/inventory.xml"
if [ -L "$SOFTWARE_INVENTORY_FILE" ] ||
   { [ -e "$SOFTWARE_INVENTORY_FILE" ] && [ ! -f "$SOFTWARE_INVENTORY_FILE" ]; }; then
    echo "FAIL: Oracle Inventory file must be a regular file: $SOFTWARE_INVENTORY_FILE"
    echo "PRECHECK RESULT: FAIL"
    exit 1
elif [ -f "$SOFTWARE_INVENTORY_FILE" ]; then
    if [ ! -r "$SOFTWARE_INVENTORY_FILE" ]; then
        echo "FAIL: Oracle Inventory file is not readable: $SOFTWARE_INVENTORY_FILE"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
    grep -Fq "LOC=\"$ORACLE_HOME\"" "$SOFTWARE_INVENTORY_FILE"
    INVENTORY_GREP_STATUS=$?
    if [ "$INVENTORY_GREP_STATUS" -eq 0 ]; then
        echo "FAIL: Oracle Software is already installed: $ORACLE_HOME"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    elif [ "$INVENTORY_GREP_STATUS" -ne 1 ]; then
        echo "FAIL: Cannot safely read Oracle Inventory file: $SOFTWARE_INVENTORY_FILE"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
fi

if [ -e "$INSTALL_MARKER" ] || [ -L "$INSTALL_MARKER" ]; then
    echo "FAIL: Oracle Software is already installed: $ORACLE_HOME"
    echo "PRECHECK RESULT: FAIL"
    exit 1
fi

# Partial software state also stops before unrelated prerequisite checks.
for PARTIAL_MARKER in "$ORAINST_ROOT_MARKER" "$ROOT_SH_MARKER"; do
    if [ -e "$PARTIAL_MARKER" ] || [ -L "$PARTIAL_MARKER" ]; then
        echo "FAIL: Existing completion marker requires DBA review: $PARTIAL_MARKER"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
done

if [ -L "$ORACLE_HOME" ] || { [ -e "$ORACLE_HOME" ] && [ ! -d "$ORACLE_HOME" ]; }; then
    echo "FAIL: Oracle Home must be a normal directory: $ORACLE_HOME"
    echo "PRECHECK RESULT: FAIL"
    exit 1
elif [ -d "$ORACLE_HOME" ]; then
    if ! command -v find >/dev/null 2>&1; then
        echo "FAIL: Required command is missing: find"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
    FIRST_HOME_ENTRY="$(find "$ORACLE_HOME" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
    if [ -n "$FIRST_HOME_ENTRY" ]; then
        echo "FAIL: Oracle Home is not empty: $ORACLE_HOME"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
fi

if [ "$TARGET_ONLY" -eq 1 ]; then
    if [ -z "${ORACLE_BASE:-}" ] || [ -z "${ORACLE_OWNER:-}" ] ||
       [ -z "${DATA_DIR:-}" ] || [ -z "${FRA_DIR:-}" ]; then
        echo "FAIL: Database target settings are missing from: $CONFIG_FILE"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
else
    if [ -z "${PACKAGE_NAME:-}" ] || [ -z "${PREINSTALL_SYSCTL:-}" ] ||
       [ -z "${CUSTOM_SYSCTL:-}" ] || [ -z "${LIMITS_FILE:-}" ] ||
       [ -z "${SELINUX_CONFIG:-}" ] || [ -z "${TIMEZONE:-}" ] ||
       [ -z "${SOFTWARE_SOURCE_DIR:-}" ] || [ -z "${ZIP_FILE:-}" ] ||
       [ -z "${ORACLE_BASE:-}" ] || [ -z "${ORACLE_OWNER:-}" ] ||
       [ -z "${ORACLE_GROUP:-}" ] || [ -z "${DATA_DIR:-}" ]; then
        echo "FAIL: Required settings are missing from: $CONFIG_FILE"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
fi

DB_HOST="$(hostname -f 2>/dev/null)"

if [ "$CREATE_DB" -eq 1 ] &&
   { [ -z "$ORACLE_SID" ] || [ -z "$LISTENER_PORT" ]; }; then
    echo "FAIL: Database target checks require --sid and --listener-port."
    echo "PRECHECK RESULT: FAIL"
    exit 1
fi

if [ "$TARGET_ONLY" -eq 0 ]; then

echo "========================================"
echo " Oracle Linux 8 and Oracle 19c Precheck"
echo "========================================"

echo ""
echo "=== Identity and platform ==="

# These checks identify conditions Main cannot safely correct during an Oracle
# installation, such as the wrong OS family, architecture, or hostname.
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
        ol:8)
            echo "PASS: Supported operating system detected: $ID $VERSION_ID"
            PASS_COUNT=$((PASS_COUNT + 1))
            ;;
        *)
            echo "FAIL: Supported operating system is Oracle Linux 8: ${ID:-unknown} ${VERSION_ID:-unknown}"
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

for REQUIRED_COMMAND in awk df dirname find getenforce getent grep hostname id rpm runuser sed stat sysctl systemctl timedatectl tr uname; do
    if command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
        echo "PASS: Required command is available: $REQUIRED_COMMAND"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Required command is missing: $REQUIRED_COMMAND"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

# Compare the running kernel with the documented minimum for its recognized
# Oracle Linux 8 UEK or RHCK family. Unknown newer families remain a DBA warning.
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
        8)
            case "$KERNEL_RELEASE" in
                5.4.*el8uek*)
                    KERNEL_FAMILY="Oracle Linux 8 UEK6"
                    MINIMUM_KERNEL="5.4.17-2011.0.7.el8uek.x86_64"
                    ;;
                5.15.*el8uek*)
                    KERNEL_FAMILY="Oracle Linux 8 UEK7"
                    MINIMUM_KERNEL="5.15.0-202.135.2.el8uek.x86_64"
                    KERNEL_RU_NOTE="Oracle Linux 8 UEK7 requires Oracle Database 19c RU 19.21 or later."
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
        echo "FAIL: Required command is missing for kernel comparison: sort"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif printf '%s\n%s\n' "$MINIMUM_KERNEL" "$KERNEL_RELEASE" | LC_ALL=C sort -V -C; then
        echo "PASS: Running kernel meets the documented minimum for $KERNEL_FAMILY: $KERNEL_RELEASE"
        echo "INFO: This checks the kernel minimum only; full certification is not verified."
        PASS_COUNT=$((PASS_COUNT + 1))
        if [ -n "$KERNEL_RU_NOTE" ]; then
            echo "WARN: $KERNEL_RU_NOTE"
            echo "WARN: Continuing for 19.3 Base Media testing only; this is not a certified production combination."
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    else
        echo "FAIL: Running kernel is below the documented minimum for $KERNEL_FAMILY: $KERNEL_RELEASE"
        echo "FAIL: Minimum kernel: $MINIMUM_KERNEL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi
# End running kernel check.

echo ""
echo "=== Package and operating system settings ==="

# A missing preinstall package is a warning only when yum can provide it,
# because Main owns the package installation step on a new server.
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

# Memory and Swap are installation gates. Report actual values so the DBA can
# compare the host allocation with the Oracle recommendation.
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

# oracle_install.conf is authoritative. A matching oraInst.loc only confirms
# that the configured Inventory was previously declared.
INVENTORY_GROUP="$ORACLE_GROUP"
if [ "$INVENTORY_DECLARED" -eq 1 ]; then
    echo "PASS: Existing Oracle Inventory is declared: $ORA_INVENTORY"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "WARN: Oracle Inventory will be created: $ORA_INVENTORY"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

echo "PASS: Oracle Software is not installed in the target Oracle Home."
PASS_COUNT=$((PASS_COUNT + 1))

echo ""
echo "--- Oracle Home filesystem capacity ---"

# Walk upward to the nearest existing path so a new ORACLE_HOME can still be
# checked against the filesystem that will contain it.
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
    if [ "$ORACLE_HOME_AVAILABLE_MB" -lt "$ORACLE_SOFTWARE_MINIMUM_MB" ]; then
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

if [ -d "$ORACLE_HOME" ]; then
    echo "PASS: Oracle Home is empty and ready for extraction."
    PASS_COUNT=$((PASS_COUNT + 1))
fi

if [ -f "$SOFTWARE_SOURCE_DIR/$ZIP_FILE" ]; then
    echo "PASS: Oracle Database 19c ZIP is available: $SOFTWARE_SOURCE_DIR/$ZIP_FILE"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "FAIL: Oracle Database 19c ZIP is missing: $SOFTWARE_SOURCE_DIR/$ZIP_FILE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
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

fi

if [ "$CREATE_DB" -eq 1 ]; then
    echo ""
    echo "=== Database and Listener target ==="

    # Database checks use the SID and Listener port supplied for this run.
    # They are never inferred from an existing profile or Listener file.
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

    if [[ "$DB_SERVICE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "PASS: Database service format is valid: $DB_SERVICE"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: Database service contains unsupported characters: $DB_SERVICE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    # Markers are evidence that the SID or Listener name was already used.
    # Database and Listener stages are never resumed or adopted by this project.
    if [ -e "$DATABASE_MARKER" ] || [ -L "$DATABASE_MARKER" ]; then
        echo "FAIL: Oracle SID already exists or has existing database artifacts: $ORACLE_SID"
        echo "Use a different ORACLE_SID and rerun the installer."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "PASS: No database marker exists for SID: $ORACLE_SID"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
    if [ -e "$LISTENER_MARKER" ] || [ -L "$LISTENER_MARKER" ]; then
        echo "FAIL: Listener already exists: $LISTENER_NAME"
        echo "Use a different ORACLE_SID and rerun the installer."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "PASS: No Listener marker exists for name: $LISTENER_NAME"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi

    REGISTERED_DB=""
    # Every independent Oracle trace is a conflict for a new database target.
    if [ -r /etc/oratab ]; then
        if ! REGISTERED_DB=$(awk -F: -v name="$ORACLE_SID" '$0 !~ /^[[:space:]]*#/ && toupper($1)==name {print}' /etc/oratab); then
            echo "FAIL: Cannot inspect /etc/oratab."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "WARN: /etc/oratab is not available before software root scripts run."
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    PROCESS_LIST=""
    PROCESS_INSPECTION_OK=0
    DB_RUNNING=0
    LISTENER_RUNNING=0
    if ! command -v ps >/dev/null 2>&1; then
        echo "FAIL: Required target command is missing: ps"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif ! PROCESS_LIST=$(ps -eo args= 2>/dev/null); then
        echo "FAIL: Cannot inspect running processes."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        PROCESS_INSPECTION_OK=1
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

    if [ -n "$REGISTERED_DB" ] || [ "$DB_RUNNING" -eq 1 ] || [ -n "$DB_FILES" ]; then
        echo "FAIL: Oracle SID already exists or has existing database artifacts: $ORACLE_SID"
        echo "Use a different ORACLE_SID and rerun the installer."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif [ "$PROCESS_INSPECTION_OK" -eq 1 ]; then
        echo "PASS: Oracle SID is not registered, running, or present in Oracle Home."
        PASS_COUNT=$((PASS_COUNT + 1))
    fi

    for ROOT_DIR in "$DATA_DIR" "$FRA_DIR"; do
        if [[ "$ROOT_DIR" != /* ]] || [ "$ROOT_DIR" = / ]; then
            echo "FAIL: Storage root must be an absolute path other than /: $ROOT_DIR"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif [ -L "$ROOT_DIR/$ORACLE_SID" ] || [ -e "$ROOT_DIR/$ORACLE_SID" ]; then
            echo "FAIL: Oracle SID already exists or has existing database artifacts: $ORACLE_SID"
            echo "Use a different ORACLE_SID and rerun the installer."
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
    LISTENER_CONFIG=""

    # Strip comments for simple target-name and endpoint checks. IFILE is not
    # expanded because included Listener configuration needs DBA review.
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
    SOCKET_INSPECTION_OK=0
    PORT_IN_USE=0
    if ! command -v ss >/dev/null 2>&1; then
        echo "FAIL: Required target command is missing: ss"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif ! SOCKETS=$(ss -H -ltn 2>/dev/null); then
        echo "FAIL: Cannot inspect listening TCP ports."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        SOCKET_INSPECTION_OK=1
    fi
    if printf '%s\n' "$SOCKETS" | awk '{print $4}' | grep -Eq ":$LISTENER_PORT$"; then
        PORT_IN_USE=1
    fi

    LISTENER_NAME_EXISTS=0
    if printf '%s\n' "$LISTENER_CONFIG" | grep -Eiq "^[[:space:]]*$LISTENER_NAME[[:space:]]*=" ||
       [ "$LISTENER_RUNNING" -eq 1 ]; then
        LISTENER_NAME_EXISTS=1
    elif [ -x "$ORACLE_HOME/bin/lsnrctl" ] &&
         runuser -u "$ORACLE_OWNER" -- env \
             ORACLE_HOME="$ORACLE_HOME" TNS_ADMIN="$ORACLE_HOME/network/admin" \
             PATH="$ORACLE_HOME/bin:/usr/bin:/bin" LD_LIBRARY_PATH="$ORACLE_HOME/lib" \
             "$ORACLE_HOME/bin/lsnrctl" status "$LISTENER_NAME" >/dev/null 2>&1; then
        LISTENER_NAME_EXISTS=1
    fi

    if [ "$LISTENER_NAME_EXISTS" -eq 1 ]; then
        echo "FAIL: Listener already exists: $LISTENER_NAME"
        echo "Use a different ORACLE_SID and rerun the installer."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif [ "$PROCESS_INSPECTION_OK" -eq 1 ]; then
        echo "PASS: Listener name is not configured or running: $LISTENER_NAME"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi

    if [ "$PORT_IN_USE" -eq 1 ]; then
        echo "FAIL: Listener port is already in use: $LISTENER_PORT"
        echo "Use an unused LISTENER_PORT and rerun the installer."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif [ "$SOCKET_INSPECTION_OK" -eq 1 ]; then
        echo "PASS: Listener TCP port is available: $LISTENER_PORT"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi

fi

echo ""
echo "========================================"
echo " Precheck Summary"
echo "========================================"
echo "PASS: $PASS_COUNT"
echo "WARN: $WARN_COUNT"
echo "FAIL: $FAIL_COUNT"

# Warnings describe work that Main can perform. Any failure is a hard gate.
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "PRECHECK RESULT: FAIL"
    echo "No installation changes were made by this script."
    exit 1
fi

echo "PRECHECK RESULT: PASS"
echo "Warnings may be handled by the installation script."
exit 0
