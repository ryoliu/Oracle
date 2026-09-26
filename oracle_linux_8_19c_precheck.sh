#!/bin/bash

# Read-only pre-install checks for Oracle Linux 8 and Oracle Database 19c.
#
# Result policy for Main or a DBA:
#   PASS = requirement is currently satisfied.
#   WARN = review is required, but the current supported mode may continue.
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
   [ -z "${ORAINST_FILE:-}" ] || [ -z "${ORACLE_OWNER:-}" ] ||
   [ -z "${ORACLE_GROUP:-}" ]; then
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
ALLOW_COMPLETE_SOFTWARE=0
SOFTWARE_STATE="NEW"
ORACLE_SID=""
LISTENER_PORT=""
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# These helpers record accumulated checks. Software hard-gate failures still
# print their result and exit immediately without using these functions.
record_pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

record_warn() {
    echo "WARN: $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

record_fail() {
    echo "FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

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
        --allow-complete-software)
            ALLOW_COMPLETE_SOFTWARE=1
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

# Oracle Software is the first stopping condition. A complete project-managed
# installation may be reused only for an explicitly requested database run.
for REQUIRED_COMMAND in grep sed find; do
    if command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
        continue
    fi
    echo "FAIL: Required command is missing: $REQUIRED_COMMAND"
    echo "PRECHECK RESULT: FAIL"
    exit 1
done

if [ -L "$ORAINST_FILE" ] ||
   { [ -e "$ORAINST_FILE" ] && [ ! -f "$ORAINST_FILE" ]; }; then
    echo "FAIL: oraInst.loc must be a regular file: $ORAINST_FILE"
    echo "PRECHECK RESULT: FAIL"
    exit 1
elif [ -f "$ORAINST_FILE" ]; then
    if [ ! -r "$ORAINST_FILE" ]; then
        echo "FAIL: oraInst.loc is not readable: $ORAINST_FILE"
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
TARGET_HOME_REGISTERED=0
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
        TARGET_HOME_REGISTERED=1
    elif [ "$INVENTORY_GREP_STATUS" -ne 1 ]; then
        echo "FAIL: Cannot safely read Oracle Inventory file: $SOFTWARE_INVENTORY_FILE"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
fi

INSTALL_MARKER_PRESENT=0
ORAINST_ROOT_MARKER_PRESENT=0
ROOT_SH_MARKER_PRESENT=0

if [ -L "$INSTALL_MARKER" ] ||
   { [ -e "$INSTALL_MARKER" ] && [ ! -f "$INSTALL_MARKER" ]; }; then
    echo "FAIL: Installer completion marker must be a regular file: $INSTALL_MARKER"
    echo "PRECHECK RESULT: FAIL"
    exit 1
elif [ -f "$INSTALL_MARKER" ]; then
    if [ ! -s "$INSTALL_MARKER" ] || [ ! -r "$INSTALL_MARKER" ]; then
        echo "FAIL: Installer completion marker is empty or unreadable: $INSTALL_MARKER"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
    INSTALL_MARKER_PRESENT=1
fi

if [ -L "$ORAINST_ROOT_MARKER" ] ||
   { [ -e "$ORAINST_ROOT_MARKER" ] && [ ! -f "$ORAINST_ROOT_MARKER" ]; }; then
    echo "FAIL: Root-script completion marker must be a regular file: $ORAINST_ROOT_MARKER"
    echo "PRECHECK RESULT: FAIL"
    exit 1
elif [ -f "$ORAINST_ROOT_MARKER" ]; then
    if [ ! -r "$ORAINST_ROOT_MARKER" ]; then
        echo "FAIL: Root-script completion marker is not readable: $ORAINST_ROOT_MARKER"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
    ORAINST_ROOT_MARKER_PRESENT=1
fi

if [ -L "$ROOT_SH_MARKER" ] ||
   { [ -e "$ROOT_SH_MARKER" ] && [ ! -f "$ROOT_SH_MARKER" ]; }; then
    echo "FAIL: Root-script completion marker must be a regular file: $ROOT_SH_MARKER"
    echo "PRECHECK RESULT: FAIL"
    exit 1
elif [ -f "$ROOT_SH_MARKER" ]; then
    if [ ! -r "$ROOT_SH_MARKER" ]; then
        echo "FAIL: Root-script completion marker is not readable: $ROOT_SH_MARKER"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
    ROOT_SH_MARKER_PRESENT=1
fi

ORACLE_HOME_HAS_CONTENT=0
if [ -L "$ORACLE_HOME" ] || { [ -e "$ORACLE_HOME" ] && [ ! -d "$ORACLE_HOME" ]; }; then
    echo "FAIL: Oracle Home must be a normal directory: $ORACLE_HOME"
    echo "PRECHECK RESULT: FAIL"
    exit 1
elif [ -d "$ORACLE_HOME" ]; then
    FIRST_HOME_ENTRY="$(find "$ORACLE_HOME" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
    HOME_FIND_STATUS=$?
    if [ "$HOME_FIND_STATUS" -ne 0 ]; then
        echo "FAIL: Cannot safely inspect Oracle Home: $ORACLE_HOME"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    elif [ -n "$FIRST_HOME_ENTRY" ]; then
        ORACLE_HOME_HAS_CONTENT=1
    fi
fi

if [ "$TARGET_HOME_REGISTERED" -eq 1 ] &&
   [ "$INSTALL_MARKER_PRESENT" -eq 1 ] &&
   [ "$ORAINST_ROOT_MARKER_PRESENT" -eq 1 ] &&
   [ "$ROOT_SH_MARKER_PRESENT" -eq 1 ] &&
   [ "$ORACLE_HOME_HAS_CONTENT" -eq 1 ] &&
   [ "$INVENTORY_DECLARED" -eq 1 ]; then
    SOFTWARE_STATE="COMPLETE"
elif [ "$TARGET_HOME_REGISTERED" -eq 0 ] &&
     [ "$INSTALL_MARKER_PRESENT" -eq 0 ] &&
     [ "$ORAINST_ROOT_MARKER_PRESENT" -eq 0 ] &&
     [ "$ROOT_SH_MARKER_PRESENT" -eq 0 ] &&
     [ "$ORACLE_HOME_HAS_CONTENT" -eq 0 ]; then
    SOFTWARE_STATE="NEW"
else
    echo "FAIL: Oracle Software state is partial or inconsistent: $ORACLE_HOME"
    echo "DBA review is required. No repair or root-script retry was attempted."
    echo "PRECHECK RESULT: FAIL"
    exit 1
fi

if [ "$SOFTWARE_STATE" = "COMPLETE" ]; then
    if ! id "$ORACLE_OWNER" >/dev/null 2>&1; then
        echo "FAIL: Oracle owner is missing for the complete Software state: $ORACLE_OWNER"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
    for REQUIRED_GROUP in "$ORACLE_GROUP" dba; do
        if ! getent group "$REQUIRED_GROUP" >/dev/null 2>&1 ||
           ! id -nG "$ORACLE_OWNER" | tr ' ' '\n' | grep -Fxq "$REQUIRED_GROUP"; then
            echo "FAIL: Oracle owner is not a member of required group: $REQUIRED_GROUP"
            echo "PRECHECK RESULT: FAIL"
            exit 1
        fi
    done
    for REQUIRED_ORACLE_TOOL in runInstaller root.sh bin/dbca bin/lsnrctl bin/sqlplus; do
        if [ ! -x "$ORACLE_HOME/$REQUIRED_ORACLE_TOOL" ]; then
            echo "FAIL: Required Oracle tool is missing or not executable: $ORACLE_HOME/$REQUIRED_ORACLE_TOOL"
            echo "PRECHECK RESULT: FAIL"
            exit 1
        fi
    done
    if [ ! -x "$ORA_INVENTORY/orainstRoot.sh" ]; then
        echo "FAIL: Required Oracle Inventory root script is missing or not executable: $ORA_INVENTORY/orainstRoot.sh"
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
    if [ ! -r "$ORACLE_HOME/assistants/dbca/dbca.rsp" ] ||
       [ ! -d "$ORACLE_HOME/dbs" ] || [ ! -r "$ORACLE_HOME/dbs" ] ||
       [ ! -f /etc/oratab ] || [ ! -r /etc/oratab ]; then
        echo "FAIL: Required database creation assets are missing or unreadable."
        echo "PRECHECK RESULT: FAIL"
        exit 1
    fi
    if [ "$ALLOW_COMPLETE_SOFTWARE" -ne 1 ]; then
        echo "FAIL: Oracle Software is already installed: $ORACLE_HOME"
        echo "Use --create-db to create a new database with this verified Oracle Home."
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
elif [ "$SOFTWARE_STATE" = "COMPLETE" ]; then
    if [ -z "${PACKAGE_NAME:-}" ] || [ -z "${PREINSTALL_SYSCTL:-}" ] ||
       [ -z "${CUSTOM_SYSCTL:-}" ] || [ -z "${LIMITS_FILE:-}" ] ||
       [ -z "${SELINUX_CONFIG:-}" ] || [ -z "${TIMEZONE:-}" ] ||
       [ -z "${ORACLE_BASE:-}" ] || [ -z "${ORACLE_OWNER:-}" ] ||
       [ -z "${ORACLE_GROUP:-}" ] || [ -z "${DATA_DIR:-}" ] ||
       [ -z "${FRA_DIR:-}" ]; then
        echo "FAIL: Database-only settings are missing from: $CONFIG_FILE"
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
    record_pass "Running as root."
else
    record_fail "Run this precheck as root."
fi

if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_MAJOR="${VERSION_ID%%.*}"
    case "$ID:$OS_MAJOR" in
        ol:8)
            record_pass "Supported operating system detected: $ID $VERSION_ID"
            ;;
        *)
            record_fail "Supported operating system is Oracle Linux 8: ${ID:-unknown} ${VERSION_ID:-unknown}"
            ;;
    esac
else
    record_fail "Cannot read /etc/os-release."
fi

if [ "$(uname -m)" = "x86_64" ]; then
    record_pass "Architecture is x86_64."
else
    record_fail "Oracle Database 19c media in this project requires x86_64: $(uname -m)"
fi

if [ -n "$DB_HOST" ] && [[ "$DB_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
    record_pass "Hostname is available: $DB_HOST"
else
    record_fail "A valid hostname or FQDN is required."
fi

for REQUIRED_COMMAND in awk df dirname find getenforce getent grep hostname id rpm runuser sed stat sysctl systemctl timedatectl tr uname; do
    if command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
        record_pass "Required command is available: $REQUIRED_COMMAND"
    else
        record_fail "Required command is missing: $REQUIRED_COMMAND"
    fi
done

# Compare the running kernel with the documented minimum for its recognized
# Oracle Linux 8 UEK or RHCK family. Unknown newer families remain a DBA warning.
KERNEL_RELEASE=""
KERNEL_FAMILY=""
MINIMUM_KERNEL=""
KERNEL_RU_NOTE=""

if ! KERNEL_RELEASE="$(uname -r 2>/dev/null)" || [ -z "$KERNEL_RELEASE" ]; then
    record_fail "Unable to determine the running kernel release with uname -r."
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
        record_warn "Kernel family is not recognized for Oracle Linux ${OS_MAJOR:-unknown}: $KERNEL_RELEASE"
        echo "WARN: Verify this kernel and Oracle Database 19c combination in Oracle Certification."
    elif ! command -v sort >/dev/null 2>&1; then
        record_fail "Required command is missing for kernel comparison: sort"
    elif printf '%s\n%s\n' "$MINIMUM_KERNEL" "$KERNEL_RELEASE" | LC_ALL=C sort -V -C; then
        record_pass "Running kernel meets the documented minimum for $KERNEL_FAMILY: $KERNEL_RELEASE"
        echo "INFO: This checks the kernel minimum only; full certification is not verified."
        if [ -n "$KERNEL_RU_NOTE" ]; then
            record_warn "$KERNEL_RU_NOTE"
            echo "WARN: Continuing for 19.3 Base Media testing only; this is not a certified production combination."
        fi
    else
        record_warn "Running kernel is below the documented minimum for $KERNEL_FAMILY: $KERNEL_RELEASE"
        echo "Minimum kernel: $MINIMUM_KERNEL"
    fi
fi
# End running kernel check.

echo ""
echo "=== Package and operating system settings ==="

# A missing preinstall package is a warning only for a new Software install
# when yum can provide it. Database-only mode never installs the package.
if rpm -q "$PACKAGE_NAME" >/dev/null 2>&1; then
    PACKAGE_INSTALLED=1
    record_pass "Package is installed: $PACKAGE_NAME"
else
    if [ "$SOFTWARE_STATE" = "COMPLETE" ]; then
        record_fail "Package is missing for database-only mode: $PACKAGE_NAME"
    elif ! command -v yum >/dev/null 2>&1; then
        record_fail "Package is not installed and yum is unavailable: $PACKAGE_NAME"
    elif yum -q list available "$PACKAGE_NAME" >/dev/null 2>&1; then
        record_warn "Package is available and will be installed: $PACKAGE_NAME"
    else
        record_fail "Package is not installed or available from enabled repositories: $PACKAGE_NAME"
    fi
fi

if [ -r "$PREINSTALL_SYSCTL" ]; then
    record_pass "Preinstall sysctl file is readable: $PREINSTALL_SYSCTL"
elif [ "$PACKAGE_INSTALLED" -eq 1 ]; then
    record_fail "Installed preinstall package is missing its sysctl file: $PREINSTALL_SYSCTL"
else
    record_warn "Preinstall sysctl file will be provided by the package: $PREINSTALL_SYSCTL"
fi

if [ -e "$CUSTOM_SYSCTL" ] && [ ! -r "$CUSTOM_SYSCTL" ]; then
    record_fail "Custom sysctl file is not readable: $CUSTOM_SYSCTL"
elif [ -r "$CUSTOM_SYSCTL" ]; then
    record_pass "Custom sysctl file is readable: $CUSTOM_SYSCTL"
else
    record_pass "No custom Oracle sysctl file is configured."
fi

if [ -r "$LIMITS_FILE" ]; then
    record_pass "Oracle limits file is readable: $LIMITS_FILE"
elif [ "$PACKAGE_INSTALLED" -eq 1 ]; then
    record_fail "Installed preinstall package is missing its limits file: $LIMITS_FILE"
else
    record_warn "Oracle limits file will be provided by the package: $LIMITS_FILE"
fi

if [ -r "$SELINUX_CONFIG" ]; then
    CURRENT_SELINUX="$(getenforce 2>/dev/null)"
    if [ "$SOFTWARE_STATE" = "COMPLETE" ]; then
        if ! grep -qx "SELINUX=disabled" "$SELINUX_CONFIG"; then
            record_fail "Persistent SELinux configuration must already be disabled for database-only mode."
        elif [ "$CURRENT_SELINUX" = "Disabled" ] || [ "$CURRENT_SELINUX" = "Permissive" ]; then
            record_pass "SELinux is not enforcing and persistent configuration is disabled."
        else
            record_fail "SELinux must not be enforcing for database-only mode: ${CURRENT_SELINUX:-unknown}"
        fi
    elif [ "$CURRENT_SELINUX" = "Disabled" ]; then
        record_pass "SELinux is disabled."
    else
        record_warn "SELinux is ${CURRENT_SELINUX:-unknown}; the installer will configure it as disabled."
    fi
else
    record_fail "SELinux configuration file is not readable: $SELINUX_CONFIG"
fi

SERVICE_INSPECTION_OK=1
if ! SERVICE_UNITS="$(systemctl list-unit-files --type=service 2>/dev/null)"; then
    record_fail "Cannot inspect system service definitions."
    SERVICE_INSPECTION_OK=0
fi

for SERVICE_NAME in firewalld iptables; do
    if [ "$SERVICE_INSPECTION_OK" -ne 1 ]; then
        continue
    elif printf '%s\n' "$SERVICE_UNITS" | grep -q "^${SERVICE_NAME}\.service[[:space:]]"; then
        SERVICE_ACTIVE="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)"
        SERVICE_ENABLED="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null)"
        if [ "$SERVICE_ACTIVE" = "inactive" ] &&
           { [ "$SERVICE_ENABLED" = "disabled" ] || [ "$SERVICE_ENABLED" = "masked" ]; }; then
            record_pass "$SERVICE_NAME is inactive and not enabled."
        else
            if [ "$SOFTWARE_STATE" = "COMPLETE" ]; then
                record_fail "$SERVICE_NAME must already be inactive and disabled for database-only mode; active=$SERVICE_ACTIVE enabled=$SERVICE_ENABLED"
            else
                record_warn "$SERVICE_NAME will be stopped and disabled; active=$SERVICE_ACTIVE enabled=$SERVICE_ENABLED"
            fi
        fi
    else
        record_pass "Service is not installed: $SERVICE_NAME"
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
    record_pass "Timezone is configured: $TIMEZONE"
elif [ -n "$CURRENT_TIMEZONE" ]; then
    if [ "$SOFTWARE_STATE" = "COMPLETE" ]; then
        record_fail "Timezone must already match for database-only mode: current=$CURRENT_TIMEZONE expected=$TIMEZONE"
    else
        record_warn "Timezone will be changed from $CURRENT_TIMEZONE to $TIMEZONE."
    fi
else
    record_fail "Cannot determine the current timezone."
fi

echo ""
echo "=== Memory and filesystem resources ==="

# Memory and Swap are installation gates. Report actual values so the DBA can
# compare the host allocation with the Oracle recommendation.
if MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)" &&
   SWAP_KB="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)" &&
   [ -n "$MEM_KB" ] && [ -n "$SWAP_KB" ]; then
    record_pass "Memory is $((MEM_KB / 1024)) MB; Swap is $((SWAP_KB / 1024)) MB."
    if [ "$MEM_KB" -lt 2097152 ]; then
        record_fail "At least 2 GB of RAM is required."
    else
        record_pass "Minimum memory requirement is satisfied."
        if [ "$MEM_KB" -le 16777216 ]; then
            REQUIRED_SWAP_KB=$MEM_KB
        else
            REQUIRED_SWAP_KB=16777216
        fi
        if [ "$SWAP_KB" -ge "$REQUIRED_SWAP_KB" ]; then
            record_pass "Swap requirement is satisfied."
        else
            record_fail "Swap must be at least $(((REQUIRED_SWAP_KB + 1023) / 1024)) MB."
        fi
    fi
else
    record_fail "Cannot read memory and Swap information."
fi

echo ""
echo "Transparent HugePages status:"
if [ -r /sys/kernel/mm/transparent_hugepage/enabled ]; then
    cat /sys/kernel/mm/transparent_hugepage/enabled
else
    record_warn "Transparent HugePages status file was not found."
fi

if [ -d /tmp ]; then
    TMP_AVAILABLE_MB="$(df -Pm /tmp 2>/dev/null | awk 'NR == 2 {print $4}')"
    if [[ "$TMP_AVAILABLE_MB" =~ ^[0-9]+$ ]]; then
        echo "INFO: /tmp available space is $TMP_AVAILABLE_MB MB."
        if [ "$TMP_AVAILABLE_MB" -ge "$TMP_MINIMUM_MB" ]; then
            record_pass "/tmp has at least 1 GB of available space."
        else
            record_fail "/tmp must have at least 1 GB of available space."
        fi
    else
        record_fail "Cannot determine available space for /tmp."
    fi
else
    record_fail "Filesystem path is unavailable: /tmp"
fi

if [ -d /dev/shm ] && df -Pk /dev/shm >/dev/null 2>&1; then
    record_pass "Filesystem is available: /dev/shm"
else
    record_fail "Filesystem is unavailable: /dev/shm"
fi

if id "$ORACLE_OWNER" >/dev/null 2>&1; then
    ORACLE_USER_EXISTS=1
    record_pass "Oracle owner exists: $ORACLE_OWNER"
else
    if [ "$SOFTWARE_STATE" = "COMPLETE" ]; then
        record_fail "Oracle owner is missing for database-only mode: $ORACLE_OWNER"
    elif [ "$PACKAGE_INSTALLED" -eq 1 ]; then
        record_fail "Oracle owner is missing although the preinstall package is installed: $ORACLE_OWNER"
    else
        record_warn "Oracle owner will be created by the preinstall package: $ORACLE_OWNER"
    fi
fi

for GROUP_NAME in "$ORACLE_GROUP" dba; do
    if getent group "$GROUP_NAME" >/dev/null 2>&1; then
        record_pass "Required group exists: $GROUP_NAME"
    elif [ "$SOFTWARE_STATE" = "COMPLETE" ]; then
        record_fail "Required group is missing for database-only mode: $GROUP_NAME"
    elif [ "$PACKAGE_INSTALLED" -eq 1 ]; then
        record_fail "Required group is missing: $GROUP_NAME"
    else
        record_warn "Group will be created by the preinstall package: $GROUP_NAME"
    fi
done

echo ""
echo "=== Oracle installation state ==="

# oracle_install.conf is authoritative. A matching oraInst.loc only confirms
# that the configured Inventory was previously declared.
INVENTORY_GROUP="$ORACLE_GROUP"
if [ "$INVENTORY_DECLARED" -eq 1 ]; then
    record_pass "Existing Oracle Inventory is declared: $ORA_INVENTORY"
else
    record_warn "Oracle Inventory will be created: $ORA_INVENTORY"
fi

if [ "$SOFTWARE_STATE" = "COMPLETE" ]; then
    record_pass "Project-managed Oracle Software is complete: $ORACLE_HOME"
    record_pass "Inventory and all Software completion markers are consistent."
else
    record_pass "Oracle Software is not installed in the target Oracle Home."
fi

echo ""
echo "--- Oracle Home filesystem capacity ---"

if [ "$SOFTWARE_STATE" = "NEW" ]; then
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
            record_fail "Oracle Home filesystem must have at least 7.2 GB available before extraction."
        elif [ "$ORACLE_HOME_AVAILABLE_MB" -lt "$ORACLE_SOFTWARE_RECOMMENDED_MB" ]; then
            record_warn "Oracle Home filesystem has less than the recommended 100 GB of available space."
        else
            record_pass "Oracle Home filesystem has at least 100 GB of available space."
        fi
    else
        record_fail "Cannot determine available space for Oracle Home: $ORACLE_HOME"
    fi
else
    record_pass "Oracle Home filesystem capacity check is not required for database-only mode."
fi

for ORACLE_DIR in "$SOFTWARE_SOURCE_DIR" "$ORACLE_BASE" "$ORACLE_HOME" "$ORA_INVENTORY"; do
    if [ "$SOFTWARE_STATE" = "COMPLETE" ] && [ "$ORACLE_DIR" = "$SOFTWARE_SOURCE_DIR" ]; then
        continue
    fi
    if [ -e "$ORACLE_DIR" ] && [ ! -d "$ORACLE_DIR" ]; then
        record_fail "Path exists but is not a directory: $ORACLE_DIR"
    elif [ -d "$ORACLE_DIR" ]; then
        record_pass "Directory exists: $ORACLE_DIR"
    elif [ "$SOFTWARE_STATE" = "COMPLETE" ]; then
        record_fail "Required database-only directory is missing: $ORACLE_DIR"
    elif [ "$ORACLE_DIR" = "$ORA_INVENTORY" ] && [ "$INVENTORY_DECLARED" -eq 1 ]; then
        record_fail "oraInst.loc points to a missing Inventory directory: $ORA_INVENTORY"
    else
        record_warn "Directory will be created: $ORACLE_DIR"
    fi
done

if [ -d "$ORA_INVENTORY" ]; then
    if ! getent group "$INVENTORY_GROUP" >/dev/null 2>&1; then
        record_fail "Oracle Inventory group does not exist: $INVENTORY_GROUP"
    elif [ "$(stat -c %G "$ORA_INVENTORY" 2>/dev/null)" != "$INVENTORY_GROUP" ]; then
        record_fail "Oracle Inventory directory group does not match $INVENTORY_GROUP: $ORA_INVENTORY"
    else
        record_pass "Oracle Inventory directory group is correct: $INVENTORY_GROUP"
    fi
    if [ "$ORACLE_USER_EXISTS" -eq 1 ]; then
        if id -nG "$ORACLE_OWNER" | tr ' ' '\n' | grep -Fxq "$INVENTORY_GROUP" &&
           runuser -u "$ORACLE_OWNER" -- test -r "$ORA_INVENTORY" &&
           runuser -u "$ORACLE_OWNER" -- test -w "$ORA_INVENTORY" &&
           runuser -u "$ORACLE_OWNER" -- test -x "$ORA_INVENTORY"; then
            record_pass "$ORACLE_OWNER can use the Oracle Inventory."
        else
            record_fail "$ORACLE_OWNER cannot use Inventory group or directory: $ORA_INVENTORY"
        fi
    fi
fi

if [ -d "$ORACLE_HOME" ]; then
    if [ "$SOFTWARE_STATE" = "COMPLETE" ]; then
        record_pass "Oracle Home contains the verified Oracle Software installation."
    else
        record_pass "Oracle Home is empty and ready for extraction."
    fi
fi

if [ "$SOFTWARE_STATE" = "NEW" ]; then
    if [ -f "$SOFTWARE_SOURCE_DIR/$ZIP_FILE" ]; then
        record_pass "Oracle Database 19c ZIP is available: $SOFTWARE_SOURCE_DIR/$ZIP_FILE"
    else
        record_fail "Oracle Database 19c ZIP is missing: $SOFTWARE_SOURCE_DIR/$ZIP_FILE"
    fi
fi

if [ "$ORACLE_USER_EXISTS" -eq 1 ]; then
    for ORACLE_DIR in "$ORACLE_BASE" "$ORACLE_HOME"; do
        if [ -d "$ORACLE_DIR" ]; then
            if runuser -u "$ORACLE_OWNER" -- test -r "$ORACLE_DIR" &&
               runuser -u "$ORACLE_OWNER" -- test -w "$ORACLE_DIR" &&
               runuser -u "$ORACLE_OWNER" -- test -x "$ORACLE_DIR"; then
                record_pass "$ORACLE_OWNER can read, write, and access: $ORACLE_DIR"
            else
                record_fail "$ORACLE_OWNER cannot read, write, and access: $ORACLE_DIR"
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
        record_pass "SID format is valid: $ORACLE_SID"
    else
        record_fail "SID must contain 1-8 uppercase letters or digits and start with a letter."
    fi

    if [[ "$LISTENER_PORT" =~ ^[1-9][0-9]{3,4}$ ]] &&
       [ "$LISTENER_PORT" -ge 1024 ] && [ "$LISTENER_PORT" -le 65535 ]; then
        record_pass "Listener port format is valid: $LISTENER_PORT"
    else
        record_fail "Listener port must be between 1024 and 65535."
    fi

    if [ -z "$DB_SERVICE" ]; then
        DB_SERVICE="$ORACLE_SID"
    fi
    LISTENER_NAME="LSNR_$ORACLE_SID"
    LISTENER_MARKER="$ORACLE_HOME/network/admin/.LSNR_${ORACLE_SID}_complete"
    DATABASE_MARKER="$ORACLE_BASE/.DB_${ORACLE_SID}_complete"

    if [[ "$DB_SERVICE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        record_pass "Database service format is valid: $DB_SERVICE"
    else
        record_fail "Database service contains unsupported characters: $DB_SERVICE"
    fi

    # Markers are evidence that the SID or Listener name was already used.
    # Database and Listener stages are never resumed or adopted by this project.
    if [ -e "$DATABASE_MARKER" ] || [ -L "$DATABASE_MARKER" ]; then
        record_fail "Oracle SID already exists or has existing database artifacts: $ORACLE_SID"
        echo "Use a different ORACLE_SID and rerun the installer."
    else
        record_pass "No database marker exists for SID: $ORACLE_SID"
    fi
    if [ -e "$LISTENER_MARKER" ] || [ -L "$LISTENER_MARKER" ]; then
        record_fail "Listener already exists: $LISTENER_NAME"
        echo "Use a different ORACLE_SID and rerun the installer."
    else
        record_pass "No Listener marker exists for name: $LISTENER_NAME"
    fi

    REGISTERED_DB=""
    # Every independent Oracle trace is a conflict for a new database target.
    if [ -r /etc/oratab ]; then
        if ! REGISTERED_DB=$(awk -F: -v name="$ORACLE_SID" '$0 !~ /^[[:space:]]*#/ && toupper($1)==name {print}' /etc/oratab); then
            record_fail "Cannot inspect /etc/oratab."
        fi
    else
        record_warn "/etc/oratab is not available before software root scripts run."
    fi

    PROCESS_LIST=""
    PROCESS_INSPECTION_OK=0
    DB_RUNNING=0
    LISTENER_RUNNING=0
    if ! command -v ps >/dev/null 2>&1; then
        record_fail "Required target command is missing: ps"
    elif ! PROCESS_LIST=$(ps -eo args= 2>/dev/null); then
        record_fail "Cannot inspect running processes."
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
            record_fail "Cannot inspect target database files in Oracle Home."
        fi
    fi

    if [ -n "$REGISTERED_DB" ] || [ "$DB_RUNNING" -eq 1 ] || [ -n "$DB_FILES" ]; then
        record_fail "Oracle SID already exists or has existing database artifacts: $ORACLE_SID"
        echo "Use a different ORACLE_SID and rerun the installer."
    elif [ "$PROCESS_INSPECTION_OK" -eq 1 ]; then
        record_pass "Oracle SID is not registered, running, or present in Oracle Home."
    fi

    for ROOT_DIR in "$DATA_DIR" "$FRA_DIR"; do
        if [[ "$ROOT_DIR" != /* ]] || [ "$ROOT_DIR" = / ]; then
            record_fail "Storage root must be an absolute path other than /: $ROOT_DIR"
        elif [ -L "$ROOT_DIR/$ORACLE_SID" ] || [ -e "$ROOT_DIR/$ORACLE_SID" ]; then
            record_fail "Oracle SID already exists or has existing database artifacts: $ORACLE_SID"
            echo "Use a different ORACLE_SID and rerun the installer."
        elif [ -e "$ROOT_DIR" ] && [ ! -d "$ROOT_DIR" ]; then
            record_fail "Storage root exists but is not a directory: $ROOT_DIR"
        elif [ -d "$ROOT_DIR" ]; then
            record_pass "Storage root is ready: $ROOT_DIR"
        else
            record_warn "Storage root will be created: $ROOT_DIR"
        fi
    done

    LISTENER_FILE="$ORACLE_HOME/network/admin/listener.ora"
    LISTENER_CONFIG=""

    # Strip comments for simple target-name and endpoint checks. IFILE is not
    # expanded because included Listener configuration needs DBA review.
    if [ -e "$LISTENER_FILE" ] && [ ! -r "$LISTENER_FILE" ]; then
        record_fail "Listener configuration is not readable: $LISTENER_FILE"
    elif [ -r "$LISTENER_FILE" ]; then
        if ! LISTENER_CONFIG=$(sed 's/#.*//' "$LISTENER_FILE"); then
            record_fail "Cannot inspect Listener configuration: $LISTENER_FILE"
        elif printf '%s\n' "$LISTENER_CONFIG" | grep -Eiq '^[[:space:]]*IFILE[[:space:]]*='; then
            record_fail "Included Listener configuration requires manual review: $LISTENER_FILE"
        fi
    fi

    SOCKETS=""
    SOCKET_INSPECTION_OK=0
    PORT_IN_USE=0
    if ! command -v ss >/dev/null 2>&1; then
        record_fail "Required target command is missing: ss"
    elif ! SOCKETS=$(ss -H -ltn 2>/dev/null); then
        record_fail "Cannot inspect listening TCP ports."
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
        record_fail "Listener already exists: $LISTENER_NAME"
        echo "Use a different ORACLE_SID and rerun the installer."
    elif [ "$PROCESS_INSPECTION_OK" -eq 1 ]; then
        record_pass "Listener name is not configured or running: $LISTENER_NAME"
    fi

    if [ "$PORT_IN_USE" -eq 1 ]; then
        record_fail "Listener port is already in use: $LISTENER_PORT"
        echo "Use an unused LISTENER_PORT and rerun the installer."
    elif [ "$SOCKET_INSPECTION_OK" -eq 1 ]; then
        record_pass "Listener TCP port is available: $LISTENER_PORT"
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
echo "Warnings require DBA review but do not block the selected supported mode."
exit 0
