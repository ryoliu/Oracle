#!/bin/bash

# Oracle Linux 7 / 8 full preparation for Oracle Database 19c
# Run this script as root.
# The Oracle 19c ZIP can be copied by root before ORACLE_OWNER exists.
# OS preparation runs as root; software extraction runs as ORACLE_OWNER.

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
ORA_INVENTORY="/opt/oraInventory"
ORACLE_OWNER="oracle"
ORACLE_GROUP="oinstall"
PASSWORD_RESET_REQUESTED=0
ORACLE_PASSWORD_STATUS="preserved"

for SCRIPT_OPTION in "$@"; do
    case "$SCRIPT_OPTION" in
        --la-paz)
            TIMEZONE="America/La_Paz"
            ;;
        --set-password)
            PASSWORD_RESET_REQUESTED=1
            ;;
        *)
            echo "ERROR: Unknown option: $SCRIPT_OPTION"
            echo "Usage: $0 [--la-paz] [--set-password]"
            exit 1
            ;;
    esac
done

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
if [ -f /etc/oracle-release ]; then
    cat /etc/oracle-release
else
    cat /etc/os-release
fi

echo ""
echo "--- Kernel ---"
uname -r

echo ""
echo "--- Architecture ---"
uname -m

echo ""
echo "--- Hostname ---"
hostname
hostname -f 2>/dev/null || echo "WARNING: Unable to resolve FQDN."

echo ""
echo "=== 2. Check yum and install 19c preinstall package ==="

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

if rpm -q "$PACKAGE_NAME" >/dev/null 2>&1; then
    echo "Package is already installed: $PACKAGE_NAME"
else
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
echo "=== 3. Check Oracle Preinstall Sysctl ==="

if [ -f "$PREINSTALL_SYSCTL" ]; then
    echo "Oracle 19c preinstall sysctl file exists."
    echo "$PREINSTALL_SYSCTL"
else
    echo "WARNING: Oracle 19c preinstall sysctl file not found."
    echo "Please check whether oracle-database-preinstall-19c is installed."
fi

echo ""
echo "=== 4. Check Preinstall Parameters ==="

if [ -f "$PREINSTALL_SYSCTL" ]; then
    cat "$PREINSTALL_SYSCTL"
fi

echo ""
echo "=== 5. Configure Additional Parameters ==="

# Add additional kernel parameters here if required.
#
# Example:
#
# echo "vm.nr_hugepages = 4096" > "$CUSTOM_SYSCTL"
#
# IMPORTANT:
# vm.nr_hugepages must be calculated according to Oracle SGA size.
# Do not use a fixed value for every database server.

if [ -f "$CUSTOM_SYSCTL" ]; then
    echo "Custom sysctl file exists:"
    cat "$CUSTOM_SYSCTL"
else
    echo "No additional kernel parameters configured."
fi

echo ""
echo "=== 6. Apply Kernel Parameters ==="

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
echo "=== 7. Check Current Kernel Parameters ==="

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
echo "=== 8. Check Oracle User and Groups ==="

id oracle
getent group oinstall
getent group dba

echo ""
echo "=== 9. Create Oracle Directories ==="

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
    echo "=== Oracle User Password ==="

    if ! IFS= read -r -s -p "Enter password for oracle user: " ORACLE_PASSWORD; then
        echo ""
        echo "ERROR: Failed to read the oracle user password."
        exit 1
    fi
    echo ""

    if ! IFS= read -r -s -p "Confirm password for oracle user: " ORACLE_PASSWORD_CONFIRM; then
        echo ""
        unset ORACLE_PASSWORD
        echo "ERROR: Failed to read the oracle user password confirmation."
        exit 1
    fi
    echo ""

    if [ -z "$ORACLE_PASSWORD" ]; then
        unset ORACLE_PASSWORD ORACLE_PASSWORD_CONFIRM
        echo "ERROR: Oracle password cannot be empty."
        exit 1
    fi

    if [ "$ORACLE_PASSWORD" != "$ORACLE_PASSWORD_CONFIRM" ]; then
        unset ORACLE_PASSWORD ORACLE_PASSWORD_CONFIRM
        echo "ERROR: Passwords do not match."
        exit 1
    fi

    unset ORACLE_PASSWORD_CONFIRM
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

# Check existing Inventory without changing ownership or permissions.
INVENTORY_GROUP="$ORACLE_GROUP"
if [ -f /etc/oraInst.loc ]; then
    EXISTING_ORA_INVENTORY="$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc)"
    INVENTORY_GROUP="$(sed -n 's/^inst_group=//p' /etc/oraInst.loc)"
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

# Keep existing handling for other directories; skip paths matching Inventory.
for ORACLE_DIR in "$SOFTWARE_SOURCE_DIR" "$ORACLE_BASE" "$ORACLE_HOME"; do
    if [ "$ORACLE_DIR" -ef "$ORA_INVENTORY" ]; then
        continue
    fi
    if ! mkdir -p "$ORACLE_DIR" ||
       ! chown "$ORACLE_OWNER:$ORACLE_GROUP" "$ORACLE_DIR" ||
       ! chmod 775 "$ORACLE_DIR"; then
        echo "ERROR: Failed to configure directory: $ORACLE_DIR"
        exit 1
    fi
done

echo "Directory is ready: $SOFTWARE_SOURCE_DIR"
echo "Directory is ready: $ORACLE_BASE"
echo "Directory is ready: $ORACLE_HOME"
echo "Directory is ready: $ORA_INVENTORY"

echo "Oracle directories were configured successfully."

echo ""
echo "=== 10. Check Preinstall Limits File ==="

if [ -f "$LIMITS_FILE" ]; then
    echo "Limits file exists:"
    echo "$LIMITS_FILE"
else
    echo "WARNING: Oracle 19c limits file not found."
fi

echo ""
echo "=== 11. Show Oracle Limits Settings ==="

if [ -f "$LIMITS_FILE" ]; then
    grep -v "^#" "$LIMITS_FILE" | grep -v "^$"
fi

echo ""
echo "=== 12. Check Oracle User Current Limits ==="

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
echo "=== 13. Check Memory / Swap / tmp / shm ==="

echo ""
echo "--- Memory ---"
free -h

echo ""
echo "--- Swap ---"
grep -E "^SwapTotal:" /proc/meminfo

echo ""
echo "--- /tmp ---"
df -h /tmp

echo ""
echo "--- /dev/shm ---"
df -h /dev/shm

echo ""
echo "=== 14. Check Transparent HugePages ==="

if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    cat /sys/kernel/mm/transparent_hugepage/enabled
else
    echo "Transparent HugePages status file was not found."
fi

echo ""
echo "=== 15. Disable SELinux ==="

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
echo "=== 16. Disable firewalld ==="

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
echo "=== 17. Disable iptables ==="

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
echo "=== 18. Check timezone ==="

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

echo "=== 19. Configure Oracle User Profile ==="

echo "Switching to oracle user to configure .bash_profile..."

su - oracle -c "bash -s -- '$ORACLE_BASE' '$ORACLE_HOME'" <<'ORACLE_PROFILE_SCRIPT'

ORACLE_BASE_VALUE="$1"
ORACLE_HOME_VALUE="$2"

PROFILE_FILE="$HOME/.bash_profile"
ALIAS_FILE="$HOME/.bash_alias"

echo ""
echo "--- Configure Oracle DBA aliases ---"

if [ "$(id -un)" != "oracle" ]; then
    echo "ERROR: Oracle user profile configuration must run as the oracle user."
    exit 1
fi

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

if [ -L "$PROFILE_FILE" ]; then
    echo "ERROR: Profile file is a symbolic link. Review it before continuing: $PROFILE_FILE"
    exit 1
fi

if [ -e "$PROFILE_FILE" ] && [ ! -f "$PROFILE_FILE" ]; then
    echo "ERROR: Profile path is not a regular file: $PROFILE_FILE"
    exit 1
fi

if ! cat > "$PROFILE_FILE" <<EOF
if [ -f "\$HOME/.bashrc" ]; then
    . "\$HOME/.bashrc"
fi

umask 022

export ORACLE_BASE=$ORACLE_BASE_VALUE
export ORACLE_HOME=$ORACLE_HOME_VALUE
export LD_LIBRARY_PATH=\$ORACLE_HOME/lib
export PATH=\$ORACLE_HOME/bin:\$PATH
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
    echo "ERROR: Failed to write $PROFILE_FILE"
    exit 1
fi

echo "Oracle 19c environment configured successfully."

ORACLE_PROFILE_SCRIPT

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to configure oracle .bash_profile."
    exit 1
fi

echo "Oracle .bash_profile configuration completed."

echo ""
echo "=== 20. Extract Oracle 19c Database Home ==="

# The marker records successful extraction only, not installation or file integrity.
if [ -f "$EXTRACT_MARKER" ]; then
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
echo "This script has not executed the installer."


echo ""
echo "========================================"
echo " Final Status"
echo "========================================"

echo ""
echo "--- Oracle 19c preinstall package ---"
rpm -q "$PACKAGE_NAME"

echo ""
echo "--- Kernel Parameters ---"
sysctl fs.aio-max-nr
sysctl fs.file-max
sysctl kernel.sem
sysctl kernel.shmmax
sysctl kernel.shmall
sysctl vm.nr_hugepages

echo ""
echo "--- Oracle User and Groups ---"
id oracle
getent group oinstall
getent group dba

echo ""
echo "--- Oracle Directories ---"
ls -ld "$SOFTWARE_SOURCE_DIR"
ls -ld "$ORACLE_BASE"
ls -ld "$ORACLE_HOME"
ls -ld "$ORA_INVENTORY"

echo ""
echo "--- OS / Kernel / Architecture / Hostname ---"
if [ -f /etc/oracle-release ]; then
    cat /etc/oracle-release
else
    cat /etc/os-release
fi
uname -r
uname -m
hostname
hostname -f 2>/dev/null || true

echo ""
echo "--- Memory / Swap / tmp / shm ---"
free -h
grep -E "^SwapTotal:" /proc/meminfo
df -h /tmp
df -h /dev/shm

echo ""
echo "--- Transparent HugePages ---"
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    cat /sys/kernel/mm/transparent_hugepage/enabled
fi

echo ""
echo "--- SELinux ---"
sestatus
grep "^SELINUX=" "$SELINUX_CONFIG"

echo ""
echo "--- firewalld ---"
systemctl is-active firewalld 2>/dev/null
systemctl is-enabled firewalld 2>/dev/null

echo ""
echo "--- iptables ---"
systemctl is-active iptables 2>/dev/null
systemctl is-enabled iptables 2>/dev/null

echo ""
echo "--- Timezone ---"
timedatectl | grep -i "time zone"


echo ""
echo "--- Oracle Profile ---"
echo "ORACLE_BASE=$ORACLE_BASE"
echo "ORACLE_HOME=$ORACLE_HOME"
su - oracle -c "cat ~/.bash_profile 2>/dev/null"

echo ""
echo "========================================"
echo " Completed"
echo "========================================"
if [ "$ORACLE_PASSWORD_STATUS" = "configured" ]; then
    echo "Oracle user password was configured."
else
    echo "Oracle user password was preserved."
fi
echo "Oracle 19c extraction completed or previously marked complete: $ORACLE_HOME"
echo "The Oracle installer has not been executed."
echo "Reboot is required to fully disable SELinux."
echo "After login as oracle, run: . ~/.bash_profile"

exit 0
