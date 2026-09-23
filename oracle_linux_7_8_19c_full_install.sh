#!/bin/bash

# Do not trace input values or password handling.
set +x +v
unset ORACLE_PASSWORD DB_PASSWORD PASSWORD_CONFIRM DB_PASSWORD_RSP

# Oracle Linux 7 / 8 preparation and Oracle Database 19c software installation
# Run this script as root.
# The Oracle 19c ZIP can be copied by root before ORACLE_OWNER exists.
# OS preparation and root scripts run as root; extraction and installation run as ORACLE_OWNER.
# OL8 installation assumes acceptance of CV_ASSUME_DISTID=OL7 for the 19.3 media.
# This script does not apply an RU or verify OS/kernel/Oracle certification.

PACKAGE_NAME="oracle-database-preinstall-19c"
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
# Database settings apply only with --create-db.
DATA_DIR="/opt/oracle/oradata"
FRA_DIR="/opt/oracle/fast_recovery_area"
TOTAL_MEMORY_MB=2048
FRA_SIZE_MB=10240
CHARACTER_SET="AL32UTF8"
NATIONAL_CHARACTER_SET="AL16UTF16"
LISTENER_PORT=1521
DB_SERVICE=""
DB_HOST="$(hostname -f 2>/dev/null)"
LOCAL_BIN_DIR="/usr/local/bin"
CREATE_DB=0
DB_SECRET_DIR=""
DB_WORKER_PID=""
CURRENT_STAGE="input validation"
PASSWORD_RESET_REQUESTED=0
ORACLE_PASSWORD_STATUS="preserved"

for SCRIPT_OPTION in "$@"; do
    case "$SCRIPT_OPTION" in
        --create-db)
            CREATE_DB=1
            ;;
        --help)
            echo "Usage: $0 [--create-db] [--la-paz] [--set-password] [--help]"
            echo "Default: prepare Oracle Linux and install Oracle 19c software only."
            echo "--create-db: also create a single-instance non-CDB after installation."
            echo "--set-password: reset the existing oracle OS account password."
            echo "--la-paz: use America/La_Paz instead of Asia/Taipei."
            exit 0
            ;;
        --la-paz)
            TIMEZONE="America/La_Paz"
            ;;
        --set-password)
            PASSWORD_RESET_REQUESTED=1
            ;;
        *)
            echo "ERROR: Unknown option: $SCRIPT_OPTION"
            echo "Usage: $0 [--create-db] [--la-paz] [--set-password] [--help]"
            exit 1
            ;;
    esac
done

# Only remove the exact temporary files created by this invocation.
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
echo " Oracle Linux 7 / 8 and Oracle 19c"
echo "========================================"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Please run this script as root."
    exit 1
fi

if id "$ORACLE_OWNER" >/dev/null 2>&1; then
    ORACLE_USER_EXISTED_BEFORE_PREINSTALL=1
else
    ORACLE_USER_EXISTED_BEFORE_PREINSTALL=0
fi

echo ""
echo "=== 1. Check OS / Kernel / Architecture / Hostname ==="

echo ""
echo "--- OS ---"
if [ ! -r /etc/os-release ]; then
    echo "ERROR: Cannot read /etc/os-release."
    exit 1
fi

. /etc/os-release
INSTALLER_DISTID=""
case "$ID:${VERSION_ID%%.*}" in
    ol:7)
        echo "Oracle Linux 7 detected. No CV_ASSUME_DISTID override is required."
        ;;
    ol:8)
        INSTALLER_DISTID="OL7"
        echo "Oracle Linux 8 detected. Using CV_ASSUME_DISTID=OL7 for the 19.3 installer."
        echo "Installation prerequisite: accept this override; no RU or certification check is included."
        ;;
    *)
        echo "ERROR: This script supports Oracle Linux 7 and 8 only: $ID $VERSION_ID"
        exit 1
        ;;
esac

# Collect all user input before installing packages or changing the system.
if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "ERROR: Run this script in an interactive terminal."
    exit 1
fi
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
    if ! IFS= read -r -p "Enter SID (1-8 uppercase letters or digits, starting with a letter): " ORACLE_SID; then
        echo "Cancelled before system changes."
        exit 1
    fi
    if ! IFS= read -r -p "Enter Listener TCP port (1024-65535) [$LISTENER_PORT]: " LISTENER_PORT_INPUT; then
        echo "Cancelled before system changes."
        exit 1
    fi
    if [ -n "$LISTENER_PORT_INPUT" ]; then
        LISTENER_PORT="$LISTENER_PORT_INPUT"
    fi
    unset LISTENER_PORT_INPUT
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

# Check existing Inventory without changing ownership or permissions.
INVENTORY_GROUP="$ORACLE_GROUP"
if [ -f "$ORAINST_FILE" ]; then
    EXISTING_ORA_INVENTORY="$(sed -n 's/^inventory_loc=//p' "$ORAINST_FILE")"
    INVENTORY_GROUP="$(sed -n 's/^inst_group=//p' "$ORAINST_FILE")"
    if [ -z "$EXISTING_ORA_INVENTORY" ] || [ -z "$INVENTORY_GROUP" ]; then
        echo "ERROR: oraInst.loc is missing inventory_loc or inst_group."
        exit 1
    fi
    ORA_INVENTORY="$EXISTING_ORA_INVENTORY"
    if [ ! -d "$ORA_INVENTORY" ]; then
        echo "ERROR: oraInst.loc points to a missing Inventory: $ORA_INVENTORY"
        exit 1
    fi
fi

INVENTORY_FILE="$ORA_INVENTORY/ContentsXML/inventory.xml"
INSTALL_REQUIRED="Y"

# Inventory registration alone does not prove that runInstaller succeeded.
# This marker records installer success only; root scripts run on every execution.
if [ -f "$INSTALL_MARKER" ]; then
    if ! IFS= read -r INSTALL_BATCH_ID < "$INSTALL_MARKER" ||
       [ -z "$INSTALL_BATCH_ID" ]; then
        echo "ERROR: Installer completion marker has no installation batch ID."
        echo "Legacy markers require DBA review of installer and root-script completion."
        exit 1
    fi
    if [ ! -f "$INVENTORY_FILE" ] ||
       ! grep -Fq "LOC=\"$ORACLE_HOME\"" "$INVENTORY_FILE"; then
        echo "ERROR: Installer completion marker exists, but Inventory registration is missing."
        echo "Review Oracle Home and Inventory before rerunning this script."
        exit 1
    fi
    INSTALL_REQUIRED="N"
elif [ -f "$INVENTORY_FILE" ] &&
     grep -Fq "LOC=\"$ORACLE_HOME\"" "$INVENTORY_FILE"; then
    echo "ERROR: Oracle Home is registered, but installer success has not been recorded."
    echo "Review the previous installer logs and resolve the installation state before rerunning."
    echo "Inventory registration alone is not treated as installation success."
    exit 1
fi

if [ "$INSTALL_REQUIRED" = "Y" ] && [ ! -f "$EXTRACT_MARKER" ] &&
   [ -d "$ORACLE_HOME" ]; then
    if ! FIRST_HOME_ENTRY="$(find "$ORACLE_HOME" -mindepth 1 -maxdepth 1 -print -quit)"; then
        echo "ERROR: Failed to inspect Oracle Home: $ORACLE_HOME"
        exit 1
    fi
    if [ -n "$FIRST_HOME_ENTRY" ]; then
        echo "ERROR: Oracle Home is not empty and has no completion marker: $ORACLE_HOME"
        echo "DBA review is required before system changes."
        exit 1
    fi
fi

echo "=== 2. Check yum and install 19c preinstall package ==="

if rpm -q "$PACKAGE_NAME" >/dev/null 2>&1; then
    echo "Package is already installed: $PACKAGE_NAME"
else
    if ! command -v yum >/dev/null 2>&1; then
        echo "ERROR: yum command was not found."
        echo "SYS ACTION REQUIRED: Please check the yum installation."
        exit 1
    fi

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
sysctl --system

if [ $? -ne 0 ]; then
    echo "Failed to apply kernel parameters."
    exit 1
fi

echo ""
echo "=== 4. Check Current Kernel Parameters ==="

echo ""
echo "fs.aio-max-nr:"
sysctl fs.aio-max-nr

echo ""
echo "fs.file-max:"
sysctl fs.file-max

echo ""
echo "kernel.sem:"
sysctl kernel.sem

echo ""
echo "kernel.shmmax:"
sysctl kernel.shmmax

echo ""
echo "kernel.shmall:"
sysctl kernel.shmall

echo ""
echo "vm.nr_hugepages:"
sysctl vm.nr_hugepages

echo ""
echo "=== 5. Check Oracle User, Groups, and Directories ==="

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

# Configure new directories only; preserve existing ownership and permissions.
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
echo "=== 6. Check Preinstall Limits Settings ==="

if [ -f "$LIMITS_FILE" ]; then
    echo "Limits file exists:"
    echo "$LIMITS_FILE"
    grep -v "^#" "$LIMITS_FILE" | grep -v "^$"
else
    echo "WARNING: Oracle 19c limits file not found."
fi

echo ""
echo "=== 7. Check Oracle User Current Limits ==="

echo "Open files soft limit:"
su - oracle -c "ulimit -Sn"

echo "Open files hard limit:"
su - oracle -c "ulimit -Hn"

echo "Processes soft limit:"
su - oracle -c "ulimit -Su"

echo "Processes hard limit:"
su - oracle -c "ulimit -Hu"

echo "Stack soft limit:"
su - oracle -c "ulimit -Ss"

echo "Stack hard limit:"
su - oracle -c "ulimit -Hs"

echo "Locked memory soft limit:"
su - oracle -c "ulimit -Sl"

echo "Locked memory hard limit:"
su - oracle -c "ulimit -Hl"

echo ""
echo "=== 8. Check Transparent HugePages ==="

if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    cat /sys/kernel/mm/transparent_hugepage/enabled
else
    echo "Transparent HugePages status file was not found."
fi

echo ""
echo "=== 9. Disable SELinux ==="

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
echo "=== 10. Disable firewalld ==="

if ! CURRENT_SELINUX="$(getenforce)" ||
   { [ "$CURRENT_SELINUX" != "Permissive" ] && [ "$CURRENT_SELINUX" != "Disabled" ]; }; then
    echo "ERROR: Current SELinux status verification failed."
    exit 1
fi

if ! SERVICE_UNITS="$(systemctl list-unit-files --no-pager)"; then
    echo "ERROR: Failed to retrieve the service list."
    exit 1
fi

if printf '%s\n' "$SERVICE_UNITS" | grep -q "^firewalld\.service[[:space:]]"; then
    if ! systemctl stop firewalld || ! systemctl disable firewalld; then
        echo "ERROR: Failed to stop or disable firewalld."
        exit 1
    fi
    SERVICE_ACTIVE="$(systemctl is-active firewalld 2>/dev/null)"
    SERVICE_ENABLED="$(systemctl is-enabled firewalld 2>/dev/null)"
    if [ "$SERVICE_ACTIVE" != "inactive" ] ||
       { [ "$SERVICE_ENABLED" != "disabled" ] && [ "$SERVICE_ENABLED" != "masked" ]; }; then
        echo "ERROR: firewalld stopped or disabled status verification failed."
        exit 1
    fi
    echo "firewalld has been stopped and disabled."
else
    echo "firewalld is not installed."
fi

echo ""
echo "=== 11. Disable iptables ==="

if printf '%s\n' "$SERVICE_UNITS" | grep -q "^iptables\.service[[:space:]]"; then
    if ! systemctl stop iptables || ! systemctl disable iptables; then
        echo "ERROR: Failed to stop or disable iptables."
        exit 1
    fi
    SERVICE_ACTIVE="$(systemctl is-active iptables 2>/dev/null)"
    SERVICE_ENABLED="$(systemctl is-enabled iptables 2>/dev/null)"
    if [ "$SERVICE_ACTIVE" != "inactive" ] ||
       { [ "$SERVICE_ENABLED" != "disabled" ] && [ "$SERVICE_ENABLED" != "masked" ]; }; then
        echo "ERROR: iptables stopped or disabled status verification failed."
        exit 1
    fi
    echo "iptables has been stopped and disabled."
else
    echo "iptables service is not installed."
fi

echo ""
echo "=== 12. Check timezone ==="

get_current_timezone() {
    CURRENT_TIMEZONE=""
    TIMEZONE_TARGET="$(readlink -f /etc/localtime 2>/dev/null)"

    case "$TIMEZONE_TARGET" in
        /usr/share/zoneinfo/*)
            CURRENT_TIMEZONE="${TIMEZONE_TARGET#/usr/share/zoneinfo/}"
            ;;
    esac

    if [ -z "$CURRENT_TIMEZONE" ]; then
        CURRENT_TIMEZONE="$(LC_ALL=C timedatectl 2>/dev/null | awk '
            /^[[:space:]]*Time zone:/ { print $3; exit }
            /^[[:space:]]*Timezone:/ { print $2; exit }
        ')"
    fi

    [ -n "$CURRENT_TIMEZONE" ]
}

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

echo "=== 13. Configure Oracle User Profile ==="

echo "Switching to oracle user to configure shell startup files..."

su - oracle -c "bash -s -- '$ORACLE_BASE' '$ORACLE_HOME'" <<'ORACLE_PROFILE_SCRIPT'

ORACLE_BASE_VALUE="$1"
ORACLE_HOME_VALUE="$2"

PROFILE_FILE="$HOME/.bash_profile"
ALIAS_FILE="$HOME/.bash_alias"
ENV_FILE="$HOME/.oracle_env"
BASHRC_FILE="$HOME/.bashrc"

echo ""
echo "--- Configure Oracle DBA aliases ---"

if [ "$(id -un)" != "oracle" ]; then
    echo "ERROR: Oracle user profile configuration must run as the oracle user."
    exit 1
fi

for TARGET_FILE in "$ALIAS_FILE" "$PROFILE_FILE" "$ENV_FILE" "$BASHRC_FILE"; do
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

# These four files use the fixed project standard on every run.
if ! cat > "$ALIAS_FILE" <<'EOF'
alias ORADATA="ls -lur /oradata/*_*/*/data/*.dbf"
alias ORAPS="ps -ef | grep -iv 'grep' | egrep -i -n 'smon|lsnr'; df -h | grep -i /ora"
alias dba="sqlplus / as sysdba"
EOF
then
    echo "ERROR: Failed to write .bash_alias."
    exit 1
fi

echo "Oracle DBA aliases configured: $ALIAS_FILE"
echo "Current user: $(id -un)"
echo "Profile file: $PROFILE_FILE"

# Load once per shell and block recursive loading from the host profile.
if ! cat > "$ENV_FILE" <<EOF
if [ "\${ORACLE_ENV_SHELL_PID:-}" = "\$BASHPID" ]; then
    return
fi
ORACLE_ENV_SHELL_PID=\$BASHPID
ORACLE_ENV_LOADING=1

umask 022

export ORACLE_BASE="$ORACLE_BASE_VALUE"
export ORACLE_HOME="$ORACLE_HOME_VALUE"
export LD_LIBRARY_PATH="\$ORACLE_HOME/lib"
case ":\$PATH:" in
    *":\$ORACLE_HOME/bin:"*) ;;
    *) export PATH="\$ORACLE_HOME/bin:\$PATH" ;;
esac
export EDITOR=vi

HOST_PROFILE="\$HOME/.\$(hostname).profile"

if [ -f "\$HOST_PROFILE" ]; then
    . "\$HOST_PROFILE"
fi

if [ -f "\$HOME/.bash_alias" ]; then
    . "\$HOME/.bash_alias"
fi
unset ORACLE_ENV_LOADING
EOF
then
    echo "ERROR: Failed to write $ENV_FILE"
    exit 1
fi

if ! cat > "$PROFILE_FILE" <<'EOF'
if [ "${ORACLE_ENV_LOADING:-0}" = "1" ]; then
    return
fi
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
EOF
then
    echo "ERROR: Failed to write $PROFILE_FILE"
    exit 1
fi

if ! cat > "$BASHRC_FILE" <<'EOF'
if [ "${ORACLE_ENV_LOADING:-0}" = "1" ]; then
    return
fi
if [ -f "$HOME/.oracle_env" ]; then
    . "$HOME/.oracle_env"
fi
EOF
then
    echo "ERROR: Failed to write $BASHRC_FILE"
    exit 1
fi

if ! bash -n "$ENV_FILE" || ! bash -n "$PROFILE_FILE" ||
   ! bash -n "$BASHRC_FILE" || ! bash -n "$ALIAS_FILE"; then
    echo "ERROR: Shell startup file syntax validation failed."
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
echo "=== 14. Extract Oracle 19c Database Home ==="

# The marker records successful extraction only, not installation or file integrity.
if [ "$INSTALL_REQUIRED" = "N" ]; then
    echo "Installer completion marker and Inventory registration found. Skipping extraction."
elif [ -f "$EXTRACT_MARKER" ]; then
    echo "Oracle 19c was already extracted. Skipping extraction."
    echo "Completion marker: $EXTRACT_MARKER"
else
    if [ ! -f "$SOFTWARE_SOURCE_DIR/$ZIP_FILE" ]; then
        echo "ERROR: Prerequisite configuration is complete, but the Oracle 19c ZIP file is missing:"
        echo "$SOFTWARE_SOURCE_DIR/$ZIP_FILE"
        echo "Copy the ZIP file to SOFTWARE_SOURCE_DIR and rerun this script."
        exit 1
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        echo "ERROR: unzip was not found. Install the unzip package as root."
        exit 1
    fi

    if ! command -v runuser >/dev/null 2>&1; then
        echo "ERROR: runuser was not found."
        exit 1
    fi

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
        echo "ERROR: Oracle Home is not empty and has no completion marker."
        echo "Oracle Home: $ORACLE_HOME"
        echo "DBA review is required. No files were removed or extracted."
        echo "Use a clean Oracle Home after reviewing any existing or incomplete installation."
        exit 1
    fi

    # Do not run another extraction or installer in this Oracle Home concurrently.
    echo "Extracting: $SOFTWARE_SOURCE_DIR/$ZIP_FILE"
    echo "Destination: $ORACLE_HOME"
    echo "Extraction user: $ORACLE_OWNER"

    if ! runuser -u "$ORACLE_OWNER" -- unzip -n "$SOFTWARE_SOURCE_DIR/$ZIP_FILE" -d "$ORACLE_HOME"; then
        echo "ERROR: Oracle 19c extraction failed. No completion marker was created."
        echo "Partial files may remain. Review Oracle Home before trying again."
        exit 1
    fi

    # Create the marker as the software owner only after unzip succeeds.
    if ! runuser -u "$ORACLE_OWNER" -- touch "$EXTRACT_MARKER"; then
        echo "ERROR: Extraction succeeded, but the completion marker could not be created."
        echo "DBA review is required before rerunning this script."
        exit 1
    fi

    echo "Oracle 19c extraction completed."
    echo "Completion marker: $EXTRACT_MARKER"
fi

echo "Installer path: $ORACLE_HOME/runInstaller"

echo ""
echo "=== 15. Install Oracle Database 19c software ==="

if [ ! -f "$ORACLE_HOME/runInstaller" ]; then
    echo "ERROR: runInstaller was not found: $ORACLE_HOME/runInstaller"
    exit 1
fi

if [ "$INSTALL_REQUIRED" = "N" ]; then
    echo "Previous installer success and Inventory registration were verified."
    echo "Skip software installation."
fi

if [ "$INSTALL_REQUIRED" = "Y" ]; then
    echo ""
    echo "=== Check Memory and Swap ==="

    if ! MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo) ||
       ! SWAP_KB=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo); then
        echo "ERROR: Failed to read Memory and Swap from /proc/meminfo."
        exit 1
    fi
    if ! [ "$MEM_KB" -gt 0 ] 2>/dev/null ||
       ! [ "$SWAP_KB" -ge 0 ] 2>/dev/null; then
        echo "ERROR: Invalid Memory or Swap value in /proc/meminfo."
        exit 1
    fi

    echo "Memory: $((MEM_KB / 1024)) MB"
    echo "Swap:   $((SWAP_KB / 1024)) MB"

    if [ "$MEM_KB" -lt 2097152 ]; then
        echo "ERROR: This script requires at least 2 GB of RAM."
        exit 1
    elif [ "$MEM_KB" -le 16777216 ]; then
        REQUIRED_SWAP_KB=$MEM_KB
    else
        REQUIRED_SWAP_KB=16777216
    fi

    if [ "$SWAP_KB" -lt "$REQUIRED_SWAP_KB" ]; then
        echo "ERROR: Swap size is insufficient for Oracle Database installation."
        echo "Required Swap: at least $(((REQUIRED_SWAP_KB + 1023) / 1024)) MB"
        echo "Please increase Swap and rerun this script."
        exit 1
    fi

    echo "Swap size check passed."

    su - "$ORACLE_OWNER" -c "
        unset CV_ASSUME_DISTID
        if [ -n \"$INSTALLER_DISTID\" ]; then
            export CV_ASSUME_DISTID=\"$INSTALLER_DISTID\"
        fi
        cd \"$ORACLE_HOME\" &&
        ./runInstaller \
            -silent \
            -waitforcompletion \
            -ignorePrereqFailure \
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
            echo "WARNING: Oracle Database 19c software installation succeeded with prerequisite warnings."
            echo "Please review the Oracle installer log."
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

    if ! IFS= read -r INSTALL_BATCH_ID < /proc/sys/kernel/random/uuid ||
       [ -z "$INSTALL_BATCH_ID" ]; then
        echo "ERROR: Installer succeeded, but an installation batch ID could not be generated."
        exit 1
    fi

    if ! printf '%s\n' "$INSTALL_BATCH_ID" > "$INSTALL_MARKER"; then
        echo "ERROR: Installer succeeded, but its completion marker could not be created."
        echo "Review the installation state before rerunning this script."
        exit 1
    fi

    echo "Oracle Database 19c software installation completed."
fi

echo ""
echo "=== 16. Run orainstRoot.sh ==="

if [ ! -f "$ORA_INVENTORY/orainstRoot.sh" ]; then
    echo "ERROR: orainstRoot.sh was not found:"
    echo "$ORA_INVENTORY/orainstRoot.sh"
    exit 1
fi

if ! "$ORA_INVENTORY/orainstRoot.sh"; then
    echo "ERROR: orainstRoot.sh failed."
    exit 1
fi

echo "orainstRoot.sh completed successfully."


echo ""
echo "=== 17. Run root.sh ==="

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
if [ ! -f "$INVENTORY_FILE" ] ||
   ! grep -Fq "LOC=\"$ORACLE_HOME\"" "$INVENTORY_FILE"; then
    echo "ERROR: Oracle Home is not registered in Inventory."
    exit 1
fi
echo "Installer marker: $INSTALL_MARKER"
echo "Oracle Database 19c software is registered in Inventory."

echo ""
# END SOFTWARE INSTALLATION

if [ "$CREATE_DB" -eq 1 ]; then
    CURRENT_STAGE="database creation"
    echo "=== Create and verify the database as oracle ==="
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
    # Only non-secret settings and the private directory path are arguments.
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
PROFILE_TEMP=""
cleanup_db_work() {
    if [ -n "$WORK_DIR" ]; then
        rm -f -- "$WORK_DIR/listener.ora" "$WORK_DIR/verify.sql"
        rmdir -- "$WORK_DIR"
    fi
    if [ -n "$PROFILE_TEMP" ]; then rm -f -- "$PROFILE_TEMP"; fi
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

echo "=== Preflight: Check target database and files ==="
if ! REGISTERED_DB=$(awk -F: -v name="$DB_NAME" '$0 !~ /^[[:space:]]*#/ && toupper($1)==name {print}' /etc/oratab); then
    exit 1
fi
if ! PROCESSES=$(ps -eo args=); then
    exit 1
fi
if [ -n "$REGISTERED_DB" ] || printf '%s\n' "$PROCESSES" | grep -Eiq "^ora_pmon_$ORACLE_SID([[:space:]]|$)"; then
    echo "ERROR: Target DB already exists. Other names may remain; this target will not be recreated."
    exit 1
fi
if ! DB_FILES=$(find "$ORACLE_HOME/dbs" -maxdepth 1 \( -iname "spfile$ORACLE_SID.ora" -o -iname "init$ORACLE_SID.ora" -o -iname "orapw$ORACLE_SID" -o -iname "lk$ORACLE_SID" \) -print); then
    exit 1
fi
if [ -n "$DB_FILES" ]; then
    echo "ERROR: Target DB files exist: $DB_FILES"
    exit 1
fi
for ROOT_DIR in "$DATA_DIR" "$FRA_DIR"; do
    if [[ "$ROOT_DIR" != /* ]] || [ "$ROOT_DIR" = / ] || [ -L "$ROOT_DIR/$DB_UNIQUE_NAME" ]; then
        echo "ERROR: Use an absolute storage root and no symlink for the target DB directory."
        exit 1
    fi
    if [ -e "$ROOT_DIR" ]; then
        if [ ! -d "$ROOT_DIR" ] || [ ! -r "$ROOT_DIR" ] || [ ! -x "$ROOT_DIR" ]; then
            echo "ERROR: Cannot inspect $ROOT_DIR"
            exit 1
        fi
        if ! DB_FILES=$(find "$ROOT_DIR" -mindepth 1 -maxdepth 1 -iname "$DB_UNIQUE_NAME" -print); then
            exit 1
        fi
        if [ -n "$DB_FILES" ]; then
            echo "ERROR: Target DB directory already exists: $DB_FILES"
            exit 1
        fi
    fi
done

echo "=== Preflight: Check dedicated Listener and port ==="
LISTENER_FILE="$TNS_ADMIN/listener.ora"
if [ -e "$LISTENER_FILE" ]; then
    if [ ! -r "$LISTENER_FILE" ]; then
        echo "ERROR: Cannot read $LISTENER_FILE"
        exit 1
    fi
    if ! CONFIG=$(sed 's/#.*//' "$LISTENER_FILE"); then
        exit 1
    fi
    if printf '%s\n' "$CONFIG" | grep -Eiq '^[[:space:]]*IFILE[[:space:]]*='; then
        echo "ERROR: Review included Listener configuration manually before using this simple script."
        exit 1
    fi
    if printf '%s\n' "$CONFIG" | grep -Eiq "^[[:space:]]*$LISTENER_NAME[[:space:]]*=" ||
       printf '%s\n' "$CONFIG" | tr -d '[:space:]' | grep -Eiq "\\(PORT=0*$LISTENER_PORT\\)"; then
        echo "ERROR: Listener name or port is already configured. Select a new name/port."
        exit 1
    fi
fi
if printf '%s\n' "$PROCESSES" | grep -Eiq "(^|/)tnslsnr[[:space:]]+$LISTENER_NAME([[:space:]]|$)"; then
    echo "ERROR: Target Listener is already running."
    exit 1
fi
if ! SOCKETS=$(ss -H -ltn); then
    exit 1
fi
if printf '%s\n' "$SOCKETS" | awk '{print $4}' | grep -Eq ":$LISTENER_PORT$"; then
    echo "ERROR: TCP port $LISTENER_PORT is in use."
    exit 1
fi

echo "=== Review memory before creating resources ==="
AVAILABLE_MB=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
echo "Available RAM: ${AVAILABLE_MB:-unknown} MB; database memory: $TOTAL_MEMORY_MB MB."
echo "Memory is informational; allow capacity for the OS and other databases."
if ! mkdir -p "$DATA_DIR" "$FRA_DIR"; then
    echo "ERROR: Cannot create storage roots."
    exit 1
fi
echo "Database: $DB_NAME; Listener: $LISTENER_NAME:$LISTENER_PORT"
echo "DATA: $DATA_DIR/$DB_UNIQUE_NAME; FRA: $FRA_DIR/$DB_UNIQUE_NAME"

echo "=== 2. Create and start dedicated Listener ==="
if ! mkdir -p "$TNS_ADMIN"; then
    exit 1
fi
# Preserve the first backup before changing network settings.
for CONFIG_FILE in listener.ora sqlnet.ora; do
    if [ -f "$TNS_ADMIN/$CONFIG_FILE" ] && [ ! -e "$TNS_ADMIN/$CONFIG_FILE.pre_create.bak" ]; then
        if ! cp -p "$TNS_ADMIN/$CONFIG_FILE" "$TNS_ADMIN/$CONFIG_FILE.pre_create.bak"; then
            exit 1
        fi
    fi
done
if ! WORK_DIR=$(mktemp -d "$TNS_ADMIN/.create_db.XXXXXX"); then
    exit 1
fi
if [ -f "$LISTENER_FILE" ]; then
    if ! cp -p "$LISTENER_FILE" "$WORK_DIR/listener.ora"; then
        exit 1
    fi
else
    if ! : > "$WORK_DIR/listener.ora" || ! chmod 640 "$WORK_DIR/listener.ora"; then
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
if ! LISTENER_STATUS=$("$ORACLE_HOME/bin/lsnrctl" status "$LISTENER_NAME"); then
    echo "ERROR: The target Listener did not remain available after startup."
    exit 1
fi
printf '%s\n' "$LISTENER_STATUS"
if ! printf '%s\n' "$LISTENER_STATUS" | tr -d '[:space:]' | grep -Fiq "(HOST=$DB_HOST)(PORT=$LISTENER_PORT)"; then
    echo "ERROR: Listener endpoint does not match DB_HOST and LISTENER_PORT. Review before DBCA."
    exit 1
fi

echo "=== 3. Create Database with DBCA ==="
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
echo "=== 4-5. Set LOCAL_LISTENER and register ==="
# Use an explicit address for both default and custom ports to remove stale aliases.
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

echo "=== 6. Verify Listener and client connectivity ==="
if ! "$ORACLE_HOME/bin/lsnrctl" status "$LISTENER_NAME" ||
   ! "$ORACLE_HOME/bin/lsnrctl" services "$LISTENER_NAME"; then
    echo "ERROR: Listener verification failed."
    exit 1
fi
echo "Review the service listing above: the target instance should have READY status."
if ! cat > "$WORK_DIR/verify.sql" <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE
SET ECHO OFF VERIFY OFF DEFINE OFF
@"$DB_SECRET_DIR/connect.sql"
SELECT SYS_CONTEXT('USERENV','INSTANCE_NAME') AS instance_name,
       SYS_CONTEXT('USERENV','SERVICE_NAME') AS service_name,
       SYS_CONTEXT('USERENV','CON_NAME') AS container_name FROM dual;
BEGIN
    IF LOWER(SYS_CONTEXT('USERENV','INSTANCE_NAME')) <> LOWER('$ORACLE_SID')
       OR LOWER(SYS_CONTEXT('USERENV','SERVICE_NAME')) <> LOWER('$DB_SERVICE')
       OR LOWER(SYS_CONTEXT('USERENV','CON_NAME')) <> LOWER('$DB_NAME') THEN
        RAISE_APPLICATION_ERROR(-20002, 'Connected to an unexpected database target');
    END IF;
END;
/
EXIT SUCCESS
SQL
then
    exit 1
fi
echo "Verify the SYSTEM connection using the password collected at startup."
if ! "$ORACLE_HOME/bin/sqlplus" -L -s /nolog "@$WORK_DIR/verify.sql" </dev/null; then
    echo "ERROR: SYSTEM connection or target verification failed."
    exit 1
fi
echo "Database creation and verification completed successfully."
echo "Configure $TNS_ADMIN/tnsnames.ora manually if a local TNS alias is required."

echo "=== Save database settings in the host profile ==="
PROFILE_INPUT="$HOST_PROFILE"
if [ ! -e "$HOST_PROFILE" ]; then
    PROFILE_INPUT=/dev/null
fi
if ! PROFILE_TEMP=$(mktemp "$HOME/.db_profile.XXXXXX"); then
    exit 1
fi
# Replace the managed block. Migrate simple assignments from older versions once.
if ! awk '
    /^# BEGIN ORACLE DATABASE SETTINGS$/ {
        if (inside || seen++) exit 1
        inside=1
        next
    }
    /^# END ORACLE DATABASE SETTINGS$/ {
        if (!inside) exit 1
        inside=0
        next
    }
    inside { next }
    /^[[:space:]]*(export[[:space:]]+)?(ORACLE_SID|DB_NAME|DB_UNIQUE_NAME)=/ {
        if ($0 !~ /^[[:space:]]*(export[[:space:]]+)?(ORACLE_SID|DB_NAME|DB_UNIQUE_NAME)=("[A-Za-z0-9_$./{}-]*"|[A-Za-z0-9_$./{}-]+)[[:space:]]*(#.*)?$/) exit 1
        next
    }
    { print }
    END { if (inside) exit 1 }
' "$PROFILE_INPUT" > "$PROFILE_TEMP"; then
    echo "ERROR: Cannot safely update profile assignments; original retained. Review $HOST_PROFILE."
    exit 1
fi
if ! cat >> "$PROFILE_TEMP" <<EOF
# BEGIN ORACLE DATABASE SETTINGS
export ORACLE_SID="$ORACLE_SID"
DB_NAME="\$ORACLE_SID"
DB_UNIQUE_NAME="\$ORACLE_SID"
# END ORACLE DATABASE SETTINGS
EOF
then
    exit 1
fi
if ! bash -n "$PROFILE_TEMP"; then
    echo "ERROR: Updated profile failed syntax validation; original retained."
    exit 1
fi
if cmp -s "$PROFILE_INPUT" "$PROFILE_TEMP"; then
    echo "Host profile is already configured; skipping update."
else
    if [ -f "$HOST_PROFILE" ]; then
        if [ ! -e "$HOST_PROFILE.pre_db.bak" ]; then
            if ! cp -p "$HOST_PROFILE" "$HOST_PROFILE.pre_db.bak"; then
                exit 1
            fi
        fi
        if ! chmod --reference="$HOST_PROFILE" "$PROFILE_TEMP"; then
            exit 1
        fi
    fi
    if ! mv "$PROFILE_TEMP" "$HOST_PROFILE"; then
        exit 1
    fi
    echo "Updated host profile: $HOST_PROFILE"
fi
echo "All steps completed. Profile settings apply to future logins."
ORACLE_DATABASE_SCRIPT
    DB_WORKER_PID=$!
    wait "$DB_WORKER_PID"
    DB_RESULT=$?
    DB_WORKER_PID=""
    if [ "$DB_RESULT" -ne 0 ]; then
        echo "ERROR: Database stage failed with status $DB_RESULT. Review the stage output before continuing manually."
        exit "$DB_RESULT"
    fi
    if ! rm -f -- "$DB_SECRET_DIR/dbca.rsp" "$DB_SECRET_DIR/connect.sql" ||
       ! rmdir -- "$DB_SECRET_DIR"; then
        echo "ERROR: Could not remove database credential files."
        exit 1
    fi
    DB_SECRET_DIR=""
    echo "Database and profile configuration completed. Review Listener READY status in the output."
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
    echo "tnsnames.ora requires manual configuration."
else
    echo "Software-only mode completed. No database was created."
fi
echo "Oracle Database 19c installer success and Inventory registration were verified."
echo "Reboot is required to fully disable SELinux."
echo "New oracle Bash terminals load ~/.oracle_env automatically."
echo "For an existing oracle session, run once: . ~/.oracle_env"

exit 0
