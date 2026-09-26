#!/bin/bash

# Do not trace input values or password handling.
set +x +v
unset ORACLE_PASSWORD DB_PASSWORD PASSWORD_CONFIRM DB_PASSWORD_RSP

# Oracle Linux 8 preparation and Oracle Database 19c software installation
# Run this script as root.
# The Oracle 19c ZIP can be copied by root before ORACLE_OWNER exists.
# OS preparation and root scripts run as root; extraction and installation run as ORACLE_OWNER.
# OL8 installation assumes acceptance of CV_ASSUME_DISTID=OL7 for the 19.3 media.
# The Bug 29772579 workaround is enabled only when OL8 lacks compat-libcap1.
# When enabled, OUI can ignore all prerequisite failures, so log review is required.
# Mandatory PreCheck verifies the supported OS and known kernel minimums.
# This script does not apply an RU or replace full Oracle certification checks.
#
# Execution model for DBA review:
#   1. Validate configuration, input, and any existing installation state.
#   2. Prepare Oracle Linux and the oracle operating-system account.
#   3. Extract and install the Oracle Database software.
#   4. Run both Oracle root scripts in the same installation invocation.
#   5. Optionally create and verify one single-instance non-CDB.
#
# Stop policy:
#   - Installed Oracle Software stops the script before any deployment input.
#   - Software and root-script markers are audit evidence, not resume points.
#   - SID, Listener name, and Listener port must all be unused for a new install.
#   - Unknown or partial state stops for DBA review; it is not repaired automatically.

if ! SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; then
    echo "ERROR: Cannot determine the script directory."
    exit 1
fi
CONFIG_FILE="$SCRIPT_DIR/oracle_install.conf"
PRECHECK_SCRIPT="$SCRIPT_DIR/oracle_linux_8_19c_precheck.sh"

if [ -L "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration must be a regular file: $CONFIG_FILE"
    exit 1
fi

if ! . "$CONFIG_FILE"; then
    echo "ERROR: Failed to load configuration: $CONFIG_FILE"
    exit 1
fi

if [ -z "${ORACLE_HOME:-}" ] || [ -z "${ORA_INVENTORY:-}" ] ||
   [ -z "${ORAINST_FILE:-}" ] || [ -z "${ORACLE_GROUP:-}" ]; then
    echo "ERROR: Oracle Home or Inventory settings are missing from: $CONFIG_FILE"
    exit 1
fi

INSTALL_MARKER="$ORACLE_HOME/.oracle_19c_installer_complete"
ORAINST_ROOT_MARKER="$ORA_INVENTORY/.orainstRoot_complete"
ROOT_SH_MARKER="$ORACLE_HOME/.root_sh_complete"
LISTENER_PORT=""
DB_SERVICE=""
DB_HOST=""
CREATE_DB=0
DB_SECRET_DIR=""
DB_WORKER_PID=""
CURRENT_STAGE="input validation"
PASSWORD_RESET_REQUESTED=0
ORACLE_PASSWORD_STATUS="preserved"

require_command() {
    local COMMAND_NAME="$1"

    if ! command -v "$COMMAND_NAME" >/dev/null 2>&1; then
        echo "ERROR: Required command was not found: $COMMAND_NAME"
        exit 1
    fi
}

# Read the effective login limit as the oracle owner, not the root shell limit.
show_oracle_limit() {
    local LIMIT_LABEL="$1"
    local LIMIT_OPTION="$2"
    local LIMIT_VALUE

    if ! LIMIT_VALUE="$(runuser -u "$ORACLE_OWNER" -- bash -c 'ulimit "$1"' bash "$LIMIT_OPTION")"; then
        echo "ERROR: Failed to read Oracle user limit: $LIMIT_LABEL"
        exit 1
    fi

    echo "$LIMIT_LABEL: $LIMIT_VALUE"
}

# Service state and boot enablement are separate checks. Both must match the
# requested disabled state before this function reports success.
disable_service() {
    local SERVICE_NAME="$1"
    local SERVICE_ACTIVE
    local SERVICE_ENABLED

    if printf '%s\n' "$SERVICE_UNITS" | grep -q "^${SERVICE_NAME}\.service[[:space:]]"; then
        echo "Stopping and disabling $SERVICE_NAME..."

        if ! systemctl stop "$SERVICE_NAME" ||
           ! systemctl disable "$SERVICE_NAME"; then
            echo "ERROR: Failed to stop or disable $SERVICE_NAME."
            exit 1
        fi

        SERVICE_ACTIVE="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)"
        SERVICE_ENABLED="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null)"

        if [ "$SERVICE_ACTIVE" != "inactive" ] ||
           { [ "$SERVICE_ENABLED" != "disabled" ] &&
             [ "$SERVICE_ENABLED" != "masked" ]; }; then
            echo "ERROR: $SERVICE_NAME stopped or disabled status verification failed."
            exit 1
        fi

        echo "$SERVICE_NAME has been stopped and disabled."
    else
        echo "$SERVICE_NAME is not installed."
    fi
}

# Read the current timezone on Oracle Linux 8.
get_current_timezone() {
    CURRENT_TIMEZONE="$(LC_ALL=C timedatectl 2>/dev/null | awk '
        /^[[:space:]]*Time zone:/ { print $3; exit }
    ')"

    [ -n "$CURRENT_TIMEZONE" ]
}

# Keep command-line options intentionally small. SID and Listener port remain
# interactive deployment identifiers and are not stored in oracle_install.conf.
for SCRIPT_OPTION in "$@"; do
    case "$SCRIPT_OPTION" in
        --create-db)
            CREATE_DB=1
            ;;
        --help)
            echo "Usage: $0 [--create-db] [--set-password] [--help]"
            echo "Default: prepare Oracle Linux and install Oracle 19c software only."
            echo "--create-db: also create a single-instance non-CDB after installation."
            echo "--set-password: reset the existing oracle OS account password."
            exit 0
            ;;
        --set-password)
            PASSWORD_RESET_REQUESTED=1
            ;;
        *)
            echo "ERROR: Unknown option: $SCRIPT_OPTION"
            echo "Usage: $0 [--create-db] [--set-password] [--help]"
            exit 1
            ;;
    esac
done

# Only remove credential and work files created by this invocation. Oracle
# software, Inventory, Listener, and database files are never removed here.
cleanup_install() {
    INSTALL_EXIT_CODE=$?
    if [ -n "$DB_WORKER_PID" ]; then
        kill -TERM "$DB_WORKER_PID" 2>/dev/null || true
        wait "$DB_WORKER_PID" 2>/dev/null || true
    fi
    if [ -n "$DB_SECRET_DIR" ]; then
        rm -f -- "$DB_SECRET_DIR/dbca.rsp" "$DB_SECRET_DIR/connect.sql"
        rmdir -- "$DB_SECRET_DIR"
    fi
    unset ORACLE_PASSWORD DB_PASSWORD PASSWORD_CONFIRM DB_PASSWORD_RSP
    if [ "$INSTALL_EXIT_CODE" -ne 0 ]; then
        echo "ERROR: Stopped during $CURRENT_STAGE. Existing installation and database resources were retained."
    fi
}
trap cleanup_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "========================================"
echo " Oracle Linux 8 and Oracle 19c"
echo "========================================"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Please run this script as root."
    exit 1
fi

if [ -L "$PRECHECK_SCRIPT" ] || [ ! -f "$PRECHECK_SCRIPT" ]; then
    echo "ERROR: PreCheck must be a regular file: $PRECHECK_SCRIPT"
    exit 1
fi

echo ""
echo "=== Mandatory PreCheck ==="

# PreCheck evaluates Oracle Software first. Installed software stops here before
# the script asks for passwords, SID, or Listener port.
if ! bash "$PRECHECK_SCRIPT"; then
    echo "ERROR: Mandatory PreCheck failed. No system changes were made."
    exit 1
fi

echo "Mandatory general PreCheck completed successfully."

if [ -z "${PACKAGE_NAME:-}" ] || [ -z "${LIMITS_FILE:-}" ] ||
   [ -z "${SELINUX_CONFIG:-}" ] || [ -z "${TIMEZONE:-}" ] ||
   [ -z "${SOFTWARE_SOURCE_DIR:-}" ] || [ -z "${ZIP_FILE:-}" ] ||
   [ -z "${ORACLE_BASE:-}" ] || [ -z "${ORACLE_OWNER:-}" ] ||
   [ -z "${ORACLE_GROUP:-}" ] || [ -z "${LOCAL_BIN_DIR:-}" ] ||
   [ -z "${DATA_DIR:-}" ]; then
    echo "ERROR: Base installation settings are missing from: $CONFIG_FILE"
    exit 1
fi

if [ "$CREATE_DB" -eq 1 ]; then
    if [ -z "${FRA_DIR:-}" ] || [ -z "${TOTAL_MEMORY_MB:-}" ] ||
       [ -z "${FRA_SIZE_MB:-}" ] || [ -z "${CHARACTER_SET:-}" ] ||
       [ -z "${NATIONAL_CHARACTER_SET:-}" ]; then
        echo "ERROR: Database creation settings are missing from: $CONFIG_FILE"
        exit 1
    fi
fi

DB_HOST="$(hostname -f 2>/dev/null)"

require_command runuser

if id "$ORACLE_OWNER" >/dev/null 2>&1; then
    ORACLE_USER_EXISTED_BEFORE_PREINSTALL=1
else
    ORACLE_USER_EXISTED_BEFORE_PREINSTALL=0
fi

echo ""
echo "=== 1. Set Oracle Installer Compatibility ==="

. /etc/os-release
if [ "$ID" != "ol" ] || [ "${VERSION_ID%%.*}" != "8" ]; then
    echo "ERROR: Supported operating system is Oracle Linux 8: ${ID:-unknown} ${VERSION_ID:-unknown}"
    exit 1
fi

INSTALLER_DISTID=""
# The 19.3 base installer uses the OL7 compatibility identifier on OL8.
# This changes Installer platform detection only; it does not change the OS.
if [ "$ID" = "ol" ] && [ "${VERSION_ID%%.*}" = "8" ]; then
    INSTALLER_DISTID="OL7"
fi

# Collect deployment input only after the general PreCheck confirms that the
# target Oracle Software is not installed and the new-install state is usable.
if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "ERROR: Run this script in an interactive terminal."
    exit 1
fi

if [ "$CREATE_DB" -eq 1 ]; then
    if ! IFS= read -r -p "Enter SID (1-8 uppercase letters or digits, starting with a letter): " ORACLE_SID; then
        echo "Cancelled before system changes."
        exit 1
    fi
    if ! IFS= read -r -p "Enter Listener TCP port (1024-65535): " LISTENER_PORT; then
        echo "Cancelled before system changes."
        exit 1
    fi
    if [[ ! "$ORACLE_SID" =~ ^[A-Z][A-Z0-9]{0,7}$ ]] ||
       [[ ! "$LISTENER_PORT" =~ ^[1-9][0-9]{3,4}$ ]] ||
       [ "$LISTENER_PORT" -lt 1024 ] || [ "$LISTENER_PORT" -gt 65535 ]; then
        echo "ERROR: Invalid SID or Listener port."
        exit 1
    fi
    if [ -z "$DB_SERVICE" ]; then DB_SERVICE="$ORACLE_SID"; fi
    if [[ ! "$DB_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] ||
       [[ ! "$DB_SERVICE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] ||
       [[ ! "$TOTAL_MEMORY_MB" =~ ^[1-9][0-9]{0,6}$ ]] ||
       [[ ! "$FRA_SIZE_MB" =~ ^[1-9][0-9]{0,6}$ ]]; then
        echo "ERROR: Review database host, service, memory and FRA settings."
        exit 1
    fi
    for STORAGE_ROOT in "$DATA_DIR" "$FRA_DIR"; do
        if [[ "$STORAGE_ROOT" != /* ]] || [ "$STORAGE_ROOT" = / ]; then
            echo "ERROR: Use an absolute storage root other than /."
            exit 1
        fi
    done

    echo ""
    echo "=== Database and Listener Target PreCheck ==="
    if ! bash "$PRECHECK_SCRIPT" --target-only \
        --sid "$ORACLE_SID" --listener-port "$LISTENER_PORT"; then
        echo "ERROR: Database and Listener target PreCheck failed. No system changes were made."
        exit 1
    fi
    echo "Database and Listener target PreCheck completed successfully."
fi

# Password values remain in shell variables only until their required stage.
if [ "$ORACLE_USER_EXISTED_BEFORE_PREINSTALL" -eq 0 ] || [ "$PASSWORD_RESET_REQUESTED" -eq 1 ]; then
    if ! IFS= read -r -s -p "Enter the oracle OS account password: " ORACLE_PASSWORD; then
        printf '\n'
        echo "Cancelled before system changes."
        exit 1
    fi
    printf '\n'
    if ! IFS= read -r -s -p "Confirm the oracle OS account password: " PASSWORD_CONFIRM; then
        printf '\n'
        echo "Cancelled before system changes."
        exit 1
    fi
    printf '\n'
    if [ -z "$ORACLE_PASSWORD" ] || [ "$ORACLE_PASSWORD" != "$PASSWORD_CONFIRM" ] ||
       [[ "$ORACLE_PASSWORD" == *$'\n'* || "$ORACLE_PASSWORD" == *$'\r'* ]]; then
        echo "ERROR: OS passwords must match, be nonempty and contain no line breaks."
        exit 1
    fi
    unset PASSWORD_CONFIRM
fi

if [ "$CREATE_DB" -eq 1 ]; then
    if ! IFS= read -r -s -p "Enter the shared SYS/SYSTEM password (no double quotes or control characters): " DB_PASSWORD; then
        printf '\n'
        echo "Cancelled before system changes."
        exit 1
    fi
    printf '\n'
    if ! IFS= read -r -s -p "Confirm the shared SYS/SYSTEM password: " PASSWORD_CONFIRM; then
        printf '\n'
        echo "Cancelled before system changes."
        exit 1
    fi
    printf '\n'
    if [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" != "$PASSWORD_CONFIRM" ] ||
       [[ "$DB_PASSWORD" == *'"'* || "$DB_PASSWORD" =~ [[:cntrl:]] ]]; then
        echo "ERROR: DB passwords must match, be nonempty and contain no double quotes or control characters."
        exit 1
    fi
    unset PASSWORD_CONFIRM
fi
echo "=== Installation settings ==="
echo "Configuration: $CONFIG_FILE"
echo "Oracle Home: $ORACLE_HOME; Base: $ORACLE_BASE; timezone: $TIMEZONE"
echo "root.sh local bin: $LOCAL_BIN_DIR; existing helper scripts will be preserved."
if [ "$CREATE_DB" -eq 1 ]; then
    echo "Mode: software and database; SID: $ORACLE_SID; Listener: LSNR_$ORACLE_SID:$LISTENER_PORT"
    echo "Host: $DB_HOST; service: $DB_SERVICE; DATA: $DATA_DIR; FRA: $FRA_DIR"
    echo "Database memory: $TOTAL_MEMORY_MB MB; FRA limit: $FRA_SIZE_MB MB"
    echo "Character sets: $CHARACTER_SET / $NATIONAL_CHARACTER_SET"
else
    echo "Mode: software only; no Listener or database will be created."
fi

CURRENT_STAGE="software installation"
# BEGIN SOFTWARE INSTALLATION

INVENTORY_GROUP="$ORACLE_GROUP"
INVENTORY_FILE="$ORA_INVENTORY/ContentsXML/inventory.xml"

echo "=== 2. Check yum and install 19c preinstall package ==="

if rpm -q "$PACKAGE_NAME" >/dev/null 2>&1; then
    echo "Package is already installed: $PACKAGE_NAME"
else
    require_command yum

    echo "Checking enabled yum repositories..."
    if ! yum repolist; then
        echo "ERROR: Unable to query the yum repositories."
        echo "SYS ACTION REQUIRED: Please check the yum server and repository configuration."
        exit 1
    fi

    echo "Checking package availability: $PACKAGE_NAME"

    if ! yum list available "$PACKAGE_NAME" >/dev/null 2>&1; then
        echo "ERROR: Package is not available from the enabled yum repositories: $PACKAGE_NAME"
        echo "SYS ACTION REQUIRED: Please enable or correct the Oracle Linux yum repository."
        exit 1
    fi

    echo "Installing package: $PACKAGE_NAME"

    if ! yum install -y "$PACKAGE_NAME"; then
        echo "ERROR: Package installation failed: $PACKAGE_NAME"
        echo "SYS ACTION REQUIRED: Please check the yum output and repository configuration."
        exit 1
    fi

    if ! rpm -q "$PACKAGE_NAME" >/dev/null 2>&1; then
        echo "ERROR: Package verification failed: $PACKAGE_NAME"
        echo "SYS ACTION REQUIRED: Please check the RPM database and installation result."
        exit 1
    fi

    echo "Package installation completed: $PACKAGE_NAME"
fi

echo ""
echo "=== 3. Apply Kernel Parameters ==="

# Display Oracle-managed sysctl sources before applying the complete sysctl.d
# configuration. The console output gives the DBA an audit trail.
echo "Oracle sysctl files that will be applied:"

ORACLE_SYSCTL_FOUND=0

for SYSCTL_FILE in /etc/sysctl.d/*oracle*.conf; do
    if [ -f "$SYSCTL_FILE" ]; then
        ORACLE_SYSCTL_FOUND=1
        echo ""
        echo "--- $SYSCTL_FILE ---"
        cat "$SYSCTL_FILE"
    fi
done

if [ "$ORACLE_SYSCTL_FOUND" -eq 0 ]; then
    echo "No Oracle sysctl files were found."
fi

echo ""
echo "Applying kernel parameters..."
if ! sysctl --system; then
    echo "ERROR: Failed to apply kernel parameters."
    exit 1
fi

echo ""
echo "=== 4. Read Current Kernel Parameters ==="

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

echo "Kernel parameter verification completed successfully."

echo ""
echo "=== 5. Check Oracle User, Groups, and Directories ==="

# The preinstall RPM is expected to create the oracle account and standard
# installation groups. Missing identities after package installation are fatal.
if ! id "$ORACLE_OWNER" >/dev/null 2>&1; then
    echo "ERROR: User does not exist: $ORACLE_OWNER"
    exit 1
fi

if ! getent group "$ORACLE_GROUP" >/dev/null 2>&1; then
    echo "ERROR: Group does not exist: $ORACLE_GROUP"
    exit 1
fi

echo "Oracle owner: $ORACLE_OWNER"
echo "Oracle install group: $ORACLE_GROUP"
echo "Oracle primary group: $(id -gn "$ORACLE_OWNER")"

if [ "$(id -gn "$ORACLE_OWNER")" != "$ORACLE_GROUP" ]; then
    echo "WARNING: oracle primary group is not $ORACLE_GROUP."
fi

if [ "$ORACLE_USER_EXISTED_BEFORE_PREINSTALL" -eq 0 ] ||
   [ "$PASSWORD_RESET_REQUESTED" -eq 1 ]; then
    echo ""
    echo "=== Apply the previously entered Oracle OS password ==="

    echo "Setting password for oracle user..."

    if ! printf '%s:%s\n' "$ORACLE_OWNER" "$ORACLE_PASSWORD" | chpasswd; then
        unset ORACLE_PASSWORD
        echo "ERROR: Failed to set password for oracle user."
        exit 1
    fi

    unset ORACLE_PASSWORD
    ORACLE_PASSWORD_STATUS="configured"
    echo "Oracle user password was configured successfully."
else
    echo "Oracle user existed before the preinstall package. Password was preserved."
fi

if [ -d "$ORA_INVENTORY" ]; then
    # Preserve an existing Inventory exactly as found. Only verify that its
    # group and oracle-owner access agree with oraInst.loc.
    if ! getent group "$INVENTORY_GROUP" >/dev/null; then
        echo "ERROR: Inventory group does not exist: $INVENTORY_GROUP"
        exit 1
    fi
    if [ "$(stat -c %G "$ORA_INVENTORY")" != "$INVENTORY_GROUP" ]; then
        echo "ERROR: Inventory directory group does not match. DBA review is required."
        exit 1
    fi
    if ! id -nG "$ORACLE_OWNER" | tr ' ' '\n' | grep -Fxq "$INVENTORY_GROUP"; then
        echo "ERROR: $ORACLE_OWNER is not a member of Inventory group $INVENTORY_GROUP"
        exit 1
    fi
    if ! runuser -u "$ORACLE_OWNER" -- test -r "$ORA_INVENTORY" ||
       ! runuser -u "$ORACLE_OWNER" -- test -w "$ORA_INVENTORY" ||
       ! runuser -u "$ORACLE_OWNER" -- test -x "$ORA_INVENTORY"; then
        echo "ERROR: Oracle user cannot read, write, or access Inventory. DBA review is required."
        exit 1
    fi
    echo "Existing Inventory check completed. Original permissions preserved: $ORA_INVENTORY"
else
    if ! mkdir -p "$ORA_INVENTORY" ||
       ! chown "$ORACLE_OWNER:$INVENTORY_GROUP" "$ORA_INVENTORY" ||
       ! chmod 775 "$ORA_INVENTORY"; then
        echo "ERROR: Failed to create or configure the new Inventory."
        exit 1
    fi
fi

# New directories receive the project standard ownership and mode. Existing
# directories are not silently chowned because they may require DBA review.
for ORACLE_DIR in "$SOFTWARE_SOURCE_DIR" "$ORACLE_BASE" "$ORACLE_HOME"; do
    if [ "$ORACLE_DIR" -ef "$ORA_INVENTORY" ]; then
        continue
    fi
    if [ -e "$ORACLE_DIR" ] && [ ! -d "$ORACLE_DIR" ]; then
        echo "ERROR: Path exists but is not a directory: $ORACLE_DIR"
        exit 1
    fi

    if [ ! -d "$ORACLE_DIR" ]; then
        if ! mkdir -p "$ORACLE_DIR" ||
           ! chown "$ORACLE_OWNER:$ORACLE_GROUP" "$ORACLE_DIR" ||
           ! chmod 775 "$ORACLE_DIR"; then
            echo "ERROR: Failed to configure new directory: $ORACLE_DIR"
            exit 1
        fi
    else
        echo "Preserving existing directory ownership and permissions: $ORACLE_DIR"
    fi

    if ! runuser -u "$ORACLE_OWNER" -- test -x "$ORACLE_DIR"; then
        echo "ERROR: $ORACLE_OWNER cannot access directory: $ORACLE_DIR"
        exit 1
    fi
    if [ "$ORACLE_DIR" = "$ORACLE_BASE" ] || [ "$ORACLE_DIR" = "$ORACLE_HOME" ]; then
        if ! runuser -u "$ORACLE_OWNER" -- test -r "$ORACLE_DIR" ||
           ! runuser -u "$ORACLE_OWNER" -- test -w "$ORACLE_DIR"; then
            echo "ERROR: $ORACLE_OWNER cannot read or write directory: $ORACLE_DIR"
            exit 1
        fi
    fi
done

echo "Directory is ready: $SOFTWARE_SOURCE_DIR"
echo "Directory is ready: $ORACLE_BASE"
echo "Directory is ready: $ORACLE_HOME"
echo "Directory is ready: $ORA_INVENTORY"

echo "Oracle directories were configured successfully."

echo ""
echo "=== 6. Verify Preinstall Limits Settings ==="

if [ ! -r "$LIMITS_FILE" ]; then
    echo "ERROR: Oracle 19c limits file is missing or unreadable: $LIMITS_FILE"
    exit 1
fi

echo "Active limits settings: $LIMITS_FILE"
if ! grep -Ev '^[[:space:]]*(#|$)' "$LIMITS_FILE"; then
    echo "ERROR: Oracle 19c limits file has no active settings: $LIMITS_FILE"
    exit 1
fi

echo ""
echo "=== 7. Verify Oracle User Current Limits ==="

show_oracle_limit "Open files soft limit" -Sn
show_oracle_limit "Open files hard limit" -Hn
show_oracle_limit "Processes soft limit" -Su
show_oracle_limit "Processes hard limit" -Hu
show_oracle_limit "Stack soft limit" -Ss
show_oracle_limit "Stack hard limit" -Hs
show_oracle_limit "Locked memory soft limit" -Sl
show_oracle_limit "Locked memory hard limit" -Hl

echo "Oracle user limit verification completed successfully."

echo ""
echo "=== 8. Disable SELinux ==="

# Persistent and current SELinux states are separate. SELINUX=disabled takes
# full effect after reboot; setenforce only changes the current running state.
if [ ! -f "$SELINUX_CONFIG" ]; then
    echo "ERROR: SELinux configuration file was not found: $SELINUX_CONFIG"
    exit 1
fi

if grep -q "^SELINUX=disabled" "$SELINUX_CONFIG"; then
    echo "SELinux config is already disabled."
else
    echo "Set SELINUX=disabled."

    if grep -q "^SELINUX=" "$SELINUX_CONFIG"; then
        if ! sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$SELINUX_CONFIG"; then
            echo "ERROR: Failed to modify SELinux configuration."
            exit 1
        fi
    else
        if ! echo "SELINUX=disabled" >> "$SELINUX_CONFIG"; then
            echo "ERROR: Failed to write SELinux configuration."
            exit 1
        fi
    fi
fi

if ! grep -qx "SELINUX=disabled" "$SELINUX_CONFIG"; then
    echo "ERROR: Persistent SELinux configuration verification failed."
    exit 1
fi
if ! CURRENT_SELINUX="$(getenforce)"; then
    echo "ERROR: Failed to query SELinux status."
    exit 1
fi
echo "Current SELinux status: $CURRENT_SELINUX"

if [ "$CURRENT_SELINUX" = "Enforcing" ]; then
    echo "Set SELinux to Permissive."
    if ! setenforce 0; then
        echo "ERROR: Failed to set SELinux to Permissive."
        exit 1
    fi
else
    echo "SELinux is not enforcing."
fi

echo ""
echo "=== 9. Disable firewalld ==="

if ! CURRENT_SELINUX="$(getenforce)" ||
   { [ "$CURRENT_SELINUX" != "Permissive" ] && [ "$CURRENT_SELINUX" != "Disabled" ]; }; then
    echo "ERROR: Current SELinux status verification failed."
    exit 1
fi

if ! SERVICE_UNITS="$(systemctl list-unit-files --no-pager)"; then
    echo "ERROR: Failed to retrieve the service list."
    exit 1
fi

disable_service firewalld

echo ""
echo "=== 10. Disable iptables ==="

disable_service iptables

echo ""
echo "=== 11. Check timezone ==="

if ! get_current_timezone; then
    echo "ERROR: Failed to query the current timezone."
    exit 1
fi
echo "Current timezone: $CURRENT_TIMEZONE"

if [ "$CURRENT_TIMEZONE" = "$TIMEZONE" ]; then
    echo "Timezone is already correct: $TIMEZONE"
else
    echo "Set timezone to: $TIMEZONE"
    if ! timedatectl set-timezone "$TIMEZONE"; then
        echo "ERROR: Failed to set timezone."
        exit 1
    fi
fi


echo ""
if ! get_current_timezone ||
   [ "$CURRENT_TIMEZONE" != "$TIMEZONE" ]; then
    echo "ERROR: Timezone configuration verification failed."
    exit 1
fi

echo "=== 12. Configure Oracle User Profile ==="

# Profile load order is deliberately one-way:
# .bash_profile -> .oracle_env -> host profile -> .bash_alias
# The host profile is populated after database creation because it contains SID.
echo "Switching to oracle user to configure shell startup files..."

su - oracle -c "bash -s -- '$ORACLE_BASE' '$ORACLE_HOME' '$DATA_DIR'" <<'ORACLE_PROFILE_SCRIPT'

ORACLE_BASE_VALUE="$1"
ORACLE_HOME_VALUE="$2"
DATA_DIR_VALUE="$3"

PROFILE_FILE="$HOME/.bash_profile"
ALIAS_FILE="$HOME/.bash_alias"
ENV_FILE="$HOME/.oracle_env"

echo ""
echo "--- Configure Oracle DBA aliases ---"

if [ "$(id -un)" != "oracle" ]; then
    echo "ERROR: Oracle user profile configuration must run as the oracle user."
    exit 1
fi

for TARGET_FILE in "$ALIAS_FILE" "$PROFILE_FILE" "$ENV_FILE"; do
    if [ -L "$TARGET_FILE" ] || { [ -e "$TARGET_FILE" ] && [ ! -f "$TARGET_FILE" ]; }; then
        echo "ERROR: Review symbolic link or non-regular profile path: $TARGET_FILE"
        exit 1
    fi
    if [ -f "$TARGET_FILE" ] && [ ! -e "$TARGET_FILE.pre_oracle_install.bak" ]; then
        if ! cp -p "$TARGET_FILE" "$TARGET_FILE.pre_oracle_install.bak"; then
            echo "ERROR: Failed to preserve the original profile file: $TARGET_FILE"
            exit 1
        fi
    fi
done

# These files use the fixed project standard on every run. They do not parse or
# merge an unknown legacy Oracle profile.
if ! cat > "$ALIAS_FILE" <<EOF
alias ORADATA="ls -lur $DATA_DIR_VALUE/*_*/*/data/*.dbf"
alias ORAPS="ps -ef | grep -iv 'grep' | egrep -i -n 'smon|lsnr'; df -h | grep -i /ora"
alias dba="sqlplus / as sysdba"
EOF
then
    echo "ERROR: Failed to write $ALIAS_FILE"
    exit 1
fi

echo "Oracle DBA aliases configured: $ALIAS_FILE"
echo "Current user: $(id -un)"
echo "Profile file: $PROFILE_FILE"

if ! cat > "$ENV_FILE" <<EOF
umask 022

export ORACLE_BASE="$ORACLE_BASE_VALUE"
export ORACLE_HOME="$ORACLE_HOME_VALUE"
export LD_LIBRARY_PATH="\$ORACLE_HOME/lib"
export PATH="\$ORACLE_HOME/bin:\$PATH"
export EDITOR=vi

HOST_PROFILE="\$HOME/.\$(hostname).profile"

if [ -f "\$HOST_PROFILE" ]; then
    . "\$HOST_PROFILE"
fi

if [ -f "\$HOME/.bash_alias" ]; then
    . "\$HOME/.bash_alias"
fi
EOF
then
    echo "ERROR: Failed to write $ENV_FILE"
    exit 1
fi

if ! cat > "$PROFILE_FILE" <<'EOF'
if [ -f "$HOME/.oracle_env" ]; then
    . "$HOME/.oracle_env"
fi
EOF
then
    echo "ERROR: Failed to write $PROFILE_FILE"
    exit 1
fi

if ! bash -n "$ALIAS_FILE"; then
    echo "ERROR: Bash syntax validation failed: $ALIAS_FILE"
    exit 1
fi

if ! bash -n "$ENV_FILE"; then
    echo "ERROR: Bash syntax validation failed: $ENV_FILE"
    exit 1
fi

if ! bash -n "$PROFILE_FILE"; then
    echo "ERROR: Bash syntax validation failed: $PROFILE_FILE"
    exit 1
fi

echo "Oracle 19c environment configured successfully."

ORACLE_PROFILE_SCRIPT

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to configure oracle shell startup files."
    exit 1
fi

echo "Oracle shell startup configuration completed."

echo ""
echo "=== 13. Extract Oracle 19c Database Home ==="

if [ ! -f "$SOFTWARE_SOURCE_DIR/$ZIP_FILE" ]; then
    echo "ERROR: Prerequisite configuration is complete, but the Oracle 19c ZIP file is missing:"
    echo "$SOFTWARE_SOURCE_DIR/$ZIP_FILE"
    exit 1
fi

require_command unzip

if ! ZIP_OWNER="$(stat -Lc %U "$SOFTWARE_SOURCE_DIR/$ZIP_FILE")"; then
    echo "ERROR: Failed to check ZIP file owner."
    exit 1
fi

if [ "$ZIP_OWNER" = "$ORACLE_OWNER" ]; then
    echo "ZIP file owner is already $ORACLE_OWNER. Skipping ownership change."
else
    echo "Changing ZIP file owner from $ZIP_OWNER to $ORACLE_OWNER..."
    if ! chown "$ORACLE_OWNER" "$SOFTWARE_SOURCE_DIR/$ZIP_FILE"; then
        echo "ERROR: Failed to change ZIP file owner."
        exit 1
    fi

    if ! ZIP_OWNER="$(stat -Lc %U "$SOFTWARE_SOURCE_DIR/$ZIP_FILE")" ||
       [ "$ZIP_OWNER" != "$ORACLE_OWNER" ]; then
        echo "ERROR: ZIP file owner verification failed."
        exit 1
    fi
    echo "ZIP file owner was changed to $ORACLE_OWNER."
fi

if ! runuser -u "$ORACLE_OWNER" -- test -r "$SOFTWARE_SOURCE_DIR/$ZIP_FILE"; then
    echo "ERROR: $ORACLE_OWNER cannot read: $SOFTWARE_SOURCE_DIR/$ZIP_FILE"
    exit 1
fi

if ! runuser -u "$ORACLE_OWNER" -- test -w "$ORACLE_HOME" ||
   ! runuser -u "$ORACLE_OWNER" -- test -x "$ORACLE_HOME"; then
    echo "ERROR: $ORACLE_OWNER cannot write to or access Oracle Home: $ORACLE_HOME"
    exit 1
fi

# Include hidden files when checking whether Oracle Home is empty.
if ! FIRST_HOME_ENTRY="$(runuser -u "$ORACLE_OWNER" -- find "$ORACLE_HOME" -mindepth 1 -maxdepth 1 -print -quit)"; then
    echo "ERROR: Failed to inspect Oracle Home: $ORACLE_HOME"
    exit 1
fi

if [ -n "$FIRST_HOME_ENTRY" ]; then
    echo "ERROR: Oracle Home is not empty: $ORACLE_HOME"
    echo "DBA review is required. No files were removed or extracted."
    exit 1
fi

echo "Extracting: $SOFTWARE_SOURCE_DIR/$ZIP_FILE"
echo "Destination: $ORACLE_HOME"
echo "Extraction user: $ORACLE_OWNER"

if ! runuser -u "$ORACLE_OWNER" -- unzip -n "$SOFTWARE_SOURCE_DIR/$ZIP_FILE" -d "$ORACLE_HOME"; then
    echo "ERROR: Oracle 19c extraction failed."
    echo "Partial files may remain. DBA review is required before another run."
    exit 1
fi

echo "Oracle 19c extraction completed."

echo "Installer path: $ORACLE_HOME/runInstaller"

echo ""
echo "=== 14. Install Oracle Database 19c software ==="

if [ ! -f "$ORACLE_HOME/runInstaller" ]; then
    echo "ERROR: runInstaller was not found: $ORACLE_HOME/runInstaller"
    exit 1
fi

# Activation is limited to the documented OL8 compat-libcap1 condition associated
# with Bug 29772579. The OUI option itself can ignore all prerequisite failures.
BUG_29772579_OPTION=""
if [ "$ID" = "ol" ] && [ "${VERSION_ID%%.*}" = "8" ]; then
    if rpm -q compat-libcap1 >/dev/null 2>&1; then
        echo "compat-libcap1 is installed. Oracle Bug 29772579 workaround is not required."
    else
        BUG_29772579_OPTION="-ignorePrereqFailure"
        echo "Oracle Bug 29772579 condition detected on Oracle Linux 8."
        echo "compat-libcap1 is not installed; enable the documented prerequisite workaround."
        echo "WARNING: -ignorePrereqFailure causes OUI to ignore all prerequisite failures."
        echo "Project PreCheck passed, but it does not replace all OUI prerequisite checks."
        echo "Review the Oracle installer log for every ignored prerequisite result."
    fi
fi

# Run Oracle Universal Installer as the software owner. Exit code 6 means the
# installation completed after prerequisite checks or warnings were ignored.
su - "$ORACLE_OWNER" -c "
    unset CV_ASSUME_DISTID
    if [ -n \"$INSTALLER_DISTID\" ]; then
        export CV_ASSUME_DISTID=\"$INSTALLER_DISTID\"
    fi
    cd \"$ORACLE_HOME\" &&
    ./runInstaller $BUG_29772579_OPTION \
        -silent \
        -waitforcompletion \
        oracle.install.option=INSTALL_DB_SWONLY \
        UNIX_GROUP_NAME=\"$INVENTORY_GROUP\" \
        INVENTORY_LOCATION=\"$ORA_INVENTORY\" \
        ORACLE_HOME=\"$ORACLE_HOME\" \
        ORACLE_BASE=\"$ORACLE_BASE\" \
        oracle.install.db.InstallEdition=EE \
        oracle.install.db.OSDBA_GROUP=dba \
        oracle.install.db.OSOPER_GROUP=dba \
        oracle.install.db.OSBACKUPDBA_GROUP=dba \
        oracle.install.db.OSDGDBA_GROUP=dba \
        oracle.install.db.OSKMDBA_GROUP=dba \
        oracle.install.db.OSRACDBA_GROUP=dba \
        oracle.install.db.rootconfig.executeRootScript=false
"

INSTALL_STATUS=$?
case "$INSTALL_STATUS" in
    0)
        echo "Oracle Database 19c software installation succeeded."
        ;;
    6)
        echo "WARNING: Oracle Database 19c installation completed after OUI ignored prerequisite results."
        echo "Exit code 6 does not prove that only compat-libcap1 was ignored."
        echo "Review the Oracle installer log before accepting this installation."
        ;;
    *)
        echo "ERROR: Oracle Database 19c software installation failed."
        echo "Exit code: $INSTALL_STATUS"
        exit 1
        ;;
esac

if [ ! -f "$INVENTORY_FILE" ] ||
   ! grep -Fq "LOC=\"$ORACLE_HOME\"" "$INVENTORY_FILE"; then
    echo "ERROR: Oracle Home was not registered in Inventory: $INVENTORY_FILE"
    exit 1
fi

# Record success only after this exact Oracle Home appears in Inventory.
if ! IFS= read -r INSTALL_BATCH_ID < /proc/sys/kernel/random/uuid ||
   [ -z "$INSTALL_BATCH_ID" ]; then
    echo "ERROR: Installer succeeded, but an installation batch ID could not be generated."
    exit 1
fi

if ! printf '%s\n' "$INSTALL_BATCH_ID" > "$INSTALL_MARKER"; then
    echo "ERROR: Installer succeeded, but its completion marker could not be created."
    echo "DBA review is required before another run."
    exit 1
fi

echo "Oracle Database 19c software installation completed."

echo ""
echo "=== 15. Run orainstRoot.sh ==="

if [ ! -f "$ORA_INVENTORY/orainstRoot.sh" ]; then
    echo "ERROR: orainstRoot.sh was not found:"
    echo "$ORA_INVENTORY/orainstRoot.sh"
    exit 1
fi

if ! "$ORA_INVENTORY/orainstRoot.sh"; then
    echo "ERROR: orainstRoot.sh failed."
    exit 1
fi

if ! touch "$ORAINST_ROOT_MARKER"; then
    echo "ERROR: Failed to create orainstRoot.sh completion marker: $ORAINST_ROOT_MARKER"
    exit 1
fi

echo "orainstRoot.sh completed successfully."


echo ""
echo "=== 16. Run root.sh ==="

if [ ! -f "$ORACLE_HOME/root.sh" ]; then
    echo "ERROR: root.sh was not found:"
    echo "$ORACLE_HOME/root.sh"
    exit 1
fi

# Answer the standard local-bin prompt and preserve existing helper scripts.
if ! "$ORACLE_HOME/root.sh" <<ROOT_SCRIPT_INPUT
$LOCAL_BIN_DIR
n
n
n
ROOT_SCRIPT_INPUT
then
    echo "ERROR: root.sh failed."
    exit 1
fi

if ! touch "$ROOT_SH_MARKER"; then
    echo "ERROR: Failed to create root.sh completion marker: $ROOT_SH_MARKER"
    exit 1
fi

echo "root.sh completed successfully."


echo ""
echo "========================================"
echo " Software Installation Status"
echo "========================================"

echo "Oracle Home: $ORACLE_HOME"
echo "Inventory: $ORA_INVENTORY"
if [ ! -s "$INSTALL_MARKER" ]; then
    echo "ERROR: Installer completion marker is missing or empty: $INSTALL_MARKER"
    exit 1
fi
echo "Installer marker: $INSTALL_MARKER"
echo "orainstRoot.sh marker: $ORAINST_ROOT_MARKER"
echo "root.sh marker: $ROOT_SH_MARKER"
echo "Oracle Database 19c software is registered in Inventory."

echo ""
# END SOFTWARE INSTALLATION

if [ "$CREATE_DB" -eq 1 ]; then
    CURRENT_STAGE="database creation"
    echo "=== Create and verify the database as oracle ==="

    # Credentials are written only to a private temporary directory. The
    # cleanup trap removes these files on success, failure, or interruption.
    DBCA_TEMPLATE="$ORACLE_HOME/assistants/dbca/dbca.rsp"
    if [ ! -r "$DBCA_TEMPLATE" ]; then
        echo "ERROR: Missing DBCA response template: $DBCA_TEMPLATE"
        exit 1
    fi
    umask 077
    if ! DB_SECRET_DIR=$(mktemp -d /tmp/oracle_db_credentials.XXXXXX); then exit 1; fi
    if ! chmod 700 "$DB_SECRET_DIR"; then exit 1; fi
    # DBCA response values follow Java properties escaping, not shell quoting.
    DB_PASSWORD_RSP=${DB_PASSWORD//\\/\\\\}
    DB_PASSWORD_RSP=${DB_PASSWORD_RSP// /\\ }
    if ! sed '/^[[:space:]]*sysPassword[[:space:]]*=/d; /^[[:space:]]*systemPassword[[:space:]]*=/d' \
        "$DBCA_TEMPLATE" > "$DB_SECRET_DIR/dbca.rsp" ||
       ! printf '\nsysPassword=%s\nsystemPassword=%s\n' "$DB_PASSWORD_RSP" "$DB_PASSWORD_RSP" >> "$DB_SECRET_DIR/dbca.rsp"; then
        echo "ERROR: Cannot prepare the DBCA response file."
        exit 1
    fi
    if ! printf 'SET ECHO OFF VERIFY OFF DEFINE OFF\nWHENEVER OSERROR EXIT FAILURE\nWHENEVER SQLERROR EXIT FAILURE\nCONNECT system/"%s"@//%s:%s/%s\n' \
        "$DB_PASSWORD" "$DB_HOST" "$LISTENER_PORT" "$DB_SERVICE" > "$DB_SECRET_DIR/connect.sql"; then
        echo "ERROR: Cannot prepare the SQL*Plus login file."
        exit 1
    fi
    if ! chmod 600 "$DB_SECRET_DIR/dbca.rsp" "$DB_SECRET_DIR/connect.sql" ||
       ! chown "$ORACLE_OWNER:$ORACLE_GROUP" "$DB_SECRET_DIR" "$DB_SECRET_DIR/dbca.rsp" "$DB_SECRET_DIR/connect.sql"; then
        echo "ERROR: Cannot protect database credential files."
        exit 1
    fi
    unset DB_PASSWORD DB_PASSWORD_RSP
    # Run Listener and DBCA work in a clean oracle-owned shell. Only non-secret
    # settings and the private credential directory path are command arguments.
    runuser -u "$ORACLE_OWNER" -- bash --noprofile --norc -s -- \
        "$ORACLE_BASE" "$ORACLE_HOME" "$ORACLE_SID" "$LISTENER_PORT" \
        "$DB_HOST" "$DB_SERVICE" "$DATA_DIR" "$FRA_DIR" \
        "$TOTAL_MEMORY_MB" "$FRA_SIZE_MB" "$DB_SECRET_DIR" \
        "$CHARACTER_SET" "$NATIONAL_CHARACTER_SET" <<'ORACLE_DATABASE_SCRIPT' &
set +x +v
umask 077
ORACLE_BASE="$1"
ORACLE_HOME="$2"
ORACLE_SID="$3"
LISTENER_PORT="$4"
DB_HOST="$5"
DB_SERVICE="$6"
DATA_DIR="$7"
FRA_DIR="$8"
TOTAL_MEMORY_MB="$9"
FRA_SIZE_MB="${10}"
DB_SECRET_DIR="${11}"
CHARACTER_SET="${12}"
NATIONAL_CHARACTER_SET="${13}"
DB_NAME="$ORACLE_SID"
DB_UNIQUE_NAME="$ORACLE_SID"
LISTENER_NAME="LSNR_$ORACLE_SID"
HOST_PROFILE="$HOME/.$(hostname).profile"
WORK_DIR=""

# Remove only the temporary Listener work file. Installed Listener and database
# files are retained when a stage fails so the DBA can inspect the result.
cleanup_db_work() {
    if [ -n "$WORK_DIR" ]; then
        rm -f -- "$WORK_DIR/listener.ora"
        rmdir -- "$WORK_DIR"
    fi
}
trap cleanup_db_work EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$(id -un)" != oracle ]; then
    echo "ERROR: Database work must run as oracle."
    exit 1
fi
if [ -L "$HOST_PROFILE" ] || { [ -e "$HOST_PROFILE" ] && [ ! -f "$HOST_PROFILE" ]; }; then
    echo "ERROR: Host profile must be a regular file."
    exit 1
fi
if ! command -v ss >/dev/null 2>&1; then
    echo "ERROR: Missing command: ss"
    exit 1
fi

for TOOL in dbca lsnrctl sqlplus; do
    if [ ! -x "$ORACLE_HOME/bin/$TOOL" ]; then
        echo "ERROR: Missing Oracle tool: $TOOL"
        exit 1
    fi
done
if [ ! -r /etc/oratab ] || [ ! -r "$ORACLE_HOME/dbs" ]; then
    echo "ERROR: Check dbs permissions and /etc/oratab."
    exit 1
fi
if [ -n "${TNS_ADMIN:-}" ] && [ "$TNS_ADMIN" != "$ORACLE_HOME/network/admin" ]; then
    echo "ERROR: TNS_ADMIN points outside this Oracle Home."
    exit 1
fi
unset TWO_TASK LOCAL ORACLE_PDB_SID
export ORACLE_BASE ORACLE_HOME ORACLE_SID
export TNS_ADMIN="$ORACLE_HOME/network/admin"
export LD_LIBRARY_PATH="$ORACLE_HOME/lib"
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8

verify_listener_endpoint() {
    local LISTENER_STATUS

    if ! LISTENER_STATUS=$("$ORACLE_HOME/bin/lsnrctl" status "$LISTENER_NAME"); then
        echo "ERROR: Listener status check failed: $LISTENER_NAME"
        return 1
    fi

    printf '%s\n' "$LISTENER_STATUS"

    if ! printf '%s\n' "$LISTENER_STATUS" |
         tr -d '[:space:]' |
         grep -Fiq "(HOST=$DB_HOST)(PORT=$LISTENER_PORT)"; then
        echo "ERROR: Listener endpoint does not match DB_HOST and LISTENER_PORT."
        return 1
    fi

    return 0
}

# Database completion requires both the requested DB_NAME and READ WRITE mode.
# A successful SQL*Plus process alone is not enough.
verify_database_open() {
    local DATABASE_STATUS

    if ! DATABASE_STATUS=$("$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<'SQL'
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF PAGES 0 VERIFY OFF ECHO OFF
SELECT name || ':' || open_mode FROM v$database;
EXIT SUCCESS
SQL
    ); then
        echo "ERROR: Database connection or status query failed."
        return 1
    fi

    if ! printf '%s\n' "$DATABASE_STATUS" |
         grep -Eq "^[[:space:]]*$DB_NAME:READ WRITE[[:space:]]*$"; then
        echo "ERROR: Database identity or open mode is inconsistent."
        return 1
    fi

    return 0
}

echo "=== Preflight: Check target database and files ==="
LISTENER_MARKER="$TNS_ADMIN/.LSNR_${ORACLE_SID}_complete"
DATABASE_MARKER="$ORACLE_BASE/.DB_${ORACLE_SID}_complete"

# Repeat only creation-blocking checks because the environment may have changed
# since target PreCheck. Markers remain conflict evidence and never allow reuse.
if [ ! -r /etc/oratab ] ||
   ! REGISTERED_DB=$(awk -F: -v name="$DB_NAME" '$0 !~ /^[[:space:]]*#/ && toupper($1)==name {print}' /etc/oratab); then
    echo "ERROR: Cannot inspect /etc/oratab before database creation."
    exit 1
fi
if ! PROCESSES=$(ps -eo args=); then
    echo "ERROR: Cannot inspect running processes before database creation."
    exit 1
fi
if ! DB_FILES=$(find "$ORACLE_HOME/dbs" -maxdepth 1 \( -iname "spfile$ORACLE_SID.ora" -o -iname "init$ORACLE_SID.ora" -o -iname "orapw$ORACLE_SID" -o -iname "lk$ORACLE_SID" \) -print); then
    echo "ERROR: Cannot inspect target database files in Oracle Home."
    exit 1
fi

if [ -e "$DATABASE_MARKER" ] || [ -L "$DATABASE_MARKER" ] ||
   [ -n "$REGISTERED_DB" ] ||
   printf '%s\n' "$PROCESSES" | grep -Eiq "^ora_pmon_$ORACLE_SID([[:space:]]|$)" ||
   [ -n "$DB_FILES" ]; then
    echo "ERROR: Oracle SID already exists or has existing database artifacts: $ORACLE_SID"
    echo "Use a different ORACLE_SID and rerun the installer."
    exit 1
fi

for ROOT_DIR in "$DATA_DIR" "$FRA_DIR"; do
    if [ -L "$ROOT_DIR/$DB_UNIQUE_NAME" ] || [ -e "$ROOT_DIR/$DB_UNIQUE_NAME" ]; then
        echo "ERROR: Oracle SID already exists or has existing database artifacts: $ORACLE_SID"
        echo "Use a different ORACLE_SID and rerun the installer."
        exit 1
    fi
done

echo "=== Preflight: Check dedicated Listener and port ==="
LISTENER_FILE="$TNS_ADMIN/listener.ora"
CONFIG=""
if [ -e "$LISTENER_FILE" ]; then
    # Existing unrelated Listener entries are preserved. The requested name is
    # new-install identity and must not already appear in listener.ora.
    if [ ! -r "$LISTENER_FILE" ]; then
        echo "ERROR: Cannot read $LISTENER_FILE"
        exit 1
    fi
    if ! CONFIG=$(sed 's/#.*//' "$LISTENER_FILE"); then
        echo "ERROR: Failed to parse Listener configuration: $LISTENER_FILE"
        exit 1
    fi
    if printf '%s\n' "$CONFIG" | grep -Eiq '^[[:space:]]*IFILE[[:space:]]*='; then
        echo "ERROR: Review included Listener configuration manually before using this simple script."
        exit 1
    fi
fi
if [ -e "$LISTENER_MARKER" ] || [ -L "$LISTENER_MARKER" ] ||
   printf '%s\n' "$CONFIG" | grep -Eiq "^[[:space:]]*$LISTENER_NAME[[:space:]]*=" ||
   printf '%s\n' "$PROCESSES" | grep -Eiq "(^|/)tnslsnr[[:space:]]+$LISTENER_NAME([[:space:]]|$)" ||
   "$ORACLE_HOME/bin/lsnrctl" status "$LISTENER_NAME" >/dev/null 2>&1; then
    echo "ERROR: Listener already exists: $LISTENER_NAME"
    echo "Use a different ORACLE_SID and rerun the installer."
    exit 1
fi
if ! SOCKETS=$(ss -H -ltn); then
    echo "ERROR: Cannot inspect listening TCP ports."
    exit 1
fi
if printf '%s\n' "$SOCKETS" | awk '{print $4}' | grep -Eq ":$LISTENER_PORT$"; then
    echo "ERROR: Listener port is already in use: $LISTENER_PORT"
    echo "Use an unused LISTENER_PORT and rerun the installer."
    exit 1
fi

if ! mkdir -p "$DATA_DIR" "$FRA_DIR"; then
    echo "ERROR: Cannot create storage roots."
    exit 1
fi
echo "Database: $DB_NAME; Listener: $LISTENER_NAME:$LISTENER_PORT"
echo "DATA: $DATA_DIR/$DB_UNIQUE_NAME; FRA: $FRA_DIR/$DB_UNIQUE_NAME"

echo "=== 2. Create and start dedicated Listener ==="
if ! mkdir -p "$TNS_ADMIN"; then
    echo "ERROR: Failed to create Oracle network directory: $TNS_ADMIN"
    exit 1
fi
# Preserve the first Listener configuration backup. Build the new file in
# the same directory, verify it, and only then record completion.
LISTENER_BACKUP="$LISTENER_FILE.pre_create.bak"
if [ -f "$LISTENER_FILE" ] && [ ! -e "$LISTENER_BACKUP" ]; then
    if ! cp -p "$LISTENER_FILE" "$LISTENER_BACKUP"; then
        echo "ERROR: Cannot back up the Listener configuration."
        exit 1
    fi
fi
if ! WORK_DIR=$(mktemp -d "$TNS_ADMIN/.create_db.XXXXXX"); then
    echo "ERROR: Failed to create Listener work directory in: $TNS_ADMIN"
    exit 1
fi
if [ -f "$LISTENER_FILE" ]; then
    if ! cp -p "$LISTENER_FILE" "$WORK_DIR/listener.ora"; then
        echo "ERROR: Failed to copy Listener configuration to the work directory."
        exit 1
    fi
else
    if ! : > "$WORK_DIR/listener.ora" || ! chmod 640 "$WORK_DIR/listener.ora"; then
        echo "ERROR: Failed to initialize the temporary Listener configuration."
        exit 1
    fi
fi
if ! printf '\n%s =\n  (DESCRIPTION_LIST =\n    (DESCRIPTION =\n      (ADDRESS = (PROTOCOL = TCP)(HOST = %s)(PORT = %s))\n    )\n  )\n' \
    "$LISTENER_NAME" "$DB_HOST" "$LISTENER_PORT" >> "$WORK_DIR/listener.ora"; then
    echo "ERROR: Cannot prepare the dedicated Listener configuration."
    exit 1
fi
if ! mv "$WORK_DIR/listener.ora" "$LISTENER_FILE"; then
    echo "ERROR: Cannot install the dedicated Listener configuration."
    exit 1
fi
if ! "$ORACLE_HOME/bin/lsnrctl" start "$LISTENER_NAME"; then
    echo "ERROR: Failed to start the target Listener. Review $LISTENER_FILE before retrying."
    exit 1
fi

if ! verify_listener_endpoint; then
    echo "ERROR: Listener endpoint verification failed after creation."
    exit 1
fi
if ! touch "$LISTENER_MARKER"; then
    echo "ERROR: Failed to create Listener completion marker: $LISTENER_MARKER"
    exit 1
fi
echo "Listener creation completed successfully."

echo "=== 3. Create Database with DBCA ==="
# DBCA failure is intentionally not cleaned up automatically. Any generated
# datafiles, logs, or oratab entry must be reviewed before another attempt.
"$ORACLE_HOME/bin/dbca" -silent -createDatabase -responseFile "$DB_SECRET_DIR/dbca.rsp" \
    -templateName General_Purpose.dbc \
    -gdbName "$DB_NAME" -sid "$ORACLE_SID" \
    -initParams "db_unique_name=$DB_UNIQUE_NAME" \
    -databaseConfigType SINGLE -createAsContainerDatabase false \
    -databaseType MULTIPURPOSE -storageType FS -useOMF true \
    -datafileDestination "$DATA_DIR" \
    -recoveryAreaDestination "$FRA_DIR" -recoveryAreaSize "$FRA_SIZE_MB" \
    -characterSet "$CHARACTER_SET" -nationalCharacterSet "$NATIONAL_CHARACTER_SET" \
    -memoryMgmtType AUTO_SGA -totalMemory "$TOTAL_MEMORY_MB" \
    -listeners "$LISTENER_NAME" \
    -enableArchive false -emConfiguration NONE -sampleSchema false </dev/null

DBCA_RC=$?
if [ "$DBCA_RC" -ne 0 ]; then
    echo "ERROR: DBCA returned $DBCA_RC. Review $ORACLE_BASE/cfgtoollogs/dbca/$DB_NAME."
    echo "Existing files are retained. No automatic retry or cleanup was performed."
    exit "$DBCA_RC"
fi

if ! REGISTERED_HOME=$(awk -F: -v name="$DB_NAME" '$0 !~ /^[[:space:]]*#/ && toupper($1)==name {print $2; exit}' /etc/oratab) ||
   [ "$REGISTERED_HOME" != "$ORACLE_HOME" ]; then
    echo "ERROR: DBCA succeeded, but /etc/oratab does not match the target Oracle Home."
    exit 1
fi
if [ ! -f "$ORACLE_HOME/dbs/spfile$ORACLE_SID.ora" ]; then
    echo "ERROR: DBCA succeeded, but the target spfile is missing."
    exit 1
fi
if ! verify_database_open; then
    echo "ERROR: DBCA completed, but database verification failed."
    exit 1
fi
# Create the database marker only after oratab, spfile, DB_NAME, and
# READ WRITE mode have all been verified.
if ! touch "$DATABASE_MARKER"; then
    echo "ERROR: Failed to create database completion marker: $DATABASE_MARKER"
    exit 1
fi
echo "Database creation completed successfully."
echo "=== 4-5. Set LOCAL_LISTENER and register ==="
# Use an explicit address for both default and custom ports to avoid stale aliases.
if ! "$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE
SET ECHO OFF VERIFY OFF
SHOW PARAMETER local_listener
ALTER SYSTEM SET LOCAL_LISTENER='(ADDRESS=(PROTOCOL=TCP)(HOST=$DB_HOST)(PORT=$LISTENER_PORT))' SCOPE=BOTH;
ALTER SYSTEM REGISTER;
EXIT SUCCESS
SQL
then
    echo "ERROR: Listener configuration or registration failed. Database is retained."
    exit 1
fi

echo "Configure $TNS_ADMIN/tnsnames.ora manually if a local TNS alias is required."
echo "=== 6. Set host profile ==="
# The host-specific profile contains SID identity only. ORACLE_HOME and PATH
# remain in .oracle_env so the profile load direction stays one-way.
if ! cat > "$HOST_PROFILE" <<EOF; then
export ORACLE_SID="$ORACLE_SID"
DB_NAME="$ORACLE_SID"
DB_UNIQUE_NAME="$ORACLE_SID"
EOF
    echo "ERROR: Failed to write host profile: $HOST_PROFILE"
    exit 1
fi

if ! bash -n "$HOST_PROFILE"; then
    echo "ERROR: Host profile syntax validation failed: $HOST_PROFILE"
    exit 1
fi

echo "Updated host profile: $HOST_PROFILE"
echo "Database and profile configuration completed."
ORACLE_DATABASE_SCRIPT
    DB_WORKER_PID=$!
    wait "$DB_WORKER_PID"
    DB_RESULT=$?
    DB_WORKER_PID=""
    if [ "$DB_RESULT" -ne 0 ]; then
        echo "ERROR: Database stage failed with status $DB_RESULT. Review the stage output before continuing manually."
        exit "$DB_RESULT"
    fi

    # PostCheck is a separate read-only gate. Credential files are retained
    # until Easy Connect verification finishes, then removed immediately.
    CURRENT_STAGE="post-install health check"
    POSTCHECK_SCRIPT="$SCRIPT_DIR/oracle_linux_8_19c_postcheck.sh"
    if [ -L "$POSTCHECK_SCRIPT" ] || [ ! -f "$POSTCHECK_SCRIPT" ]; then
        echo "ERROR: PostCheck must be a regular file: $POSTCHECK_SCRIPT"
        exit 1
    fi
    if ! runuser -u "$ORACLE_OWNER" -- env \
        ORACLE_BASE="$ORACLE_BASE" ORACLE_HOME="$ORACLE_HOME" ORACLE_SID="$ORACLE_SID" \
        TNS_ADMIN="$ORACLE_HOME/network/admin" LD_LIBRARY_PATH="$ORACLE_HOME/lib" \
        bash "$POSTCHECK_SCRIPT" "$ORACLE_SID" "$LISTENER_PORT" \
        "$DB_HOST" "$DB_SERVICE" "$DB_SECRET_DIR"; then
        echo "ERROR: Oracle Database PostCheck failed."
        exit 1
    fi
    if ! rm -f -- "$DB_SECRET_DIR/dbca.rsp" "$DB_SECRET_DIR/connect.sql" ||
       ! rmdir -- "$DB_SECRET_DIR"; then
        echo "ERROR: Could not remove database credential files."
        exit 1
    fi
    DB_SECRET_DIR=""
    echo "Database, profile, and PostCheck completed successfully."
fi
CURRENT_STAGE="completed"

echo "========================================"
echo " Completed"
echo "========================================"
if [ "$ORACLE_PASSWORD_STATUS" = "configured" ]; then
    echo "Oracle user password was configured."
else
    echo "Oracle user password was preserved."
fi
echo "Oracle 19c Home: $ORACLE_HOME"
if [ "$CREATE_DB" -eq 1 ]; then
    echo "Database: $ORACLE_SID; Listener: LSNR_$ORACLE_SID:$LISTENER_PORT"
    echo "Database, Listener, and SQL*Plus Easy Connect verification completed."
    echo "PostCheck completed successfully."
    echo "tnsnames.ora requires manual configuration."
else
    echo "Software-only mode completed. No database was created."
fi
echo "Oracle Database 19c installer success and Inventory registration were verified."
echo "Reboot is required to fully disable SELinux."
echo "New oracle Bash terminals load ~/.oracle_env automatically."
echo "For an existing oracle session, run once: . ~/.oracle_env"

exit 0
