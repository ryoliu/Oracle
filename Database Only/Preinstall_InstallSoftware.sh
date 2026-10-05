#!/bin/bash
set -euo pipefail

PACKAGE="oracle-database-preinstall-19c"

ORACLE_BASE="/opt/oracle"
ORACLE_HOME="/opt/oracle/product/19.3.0.0/db_1"

ORA_INVENTORY="/opt/oraInventory"
OINSTALL_GROUP="oinstall"

SOFTWARE_BASE="/software"
DB_SOFTWARE="/software/LINUX.X64_193000_db_home.zip"

INVENTORY_XML="$ORA_INVENTORY/ContentsXML/inventory.xml"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Please run this script as root."
    exit 1
fi

echo "=== 1. Install Oracle preinstall package ==="

if rpm -q "$PACKAGE" >/dev/null 2>&1; then
    echo "$PACKAGE is already installed."
else
    yum install -y "$PACKAGE"
fi


echo "=== 2. Verify Oracle groups ==="

for GROUP in oinstall dba; do
    if getent group "$GROUP" >/dev/null 2>&1; then
        echo "$GROUP group exists."
    else
        echo "ERROR: $GROUP group does not exist."
        exit 1
    fi
done


echo "=== 3. Configure oracle user ==="

usermod -aG dba oracle


echo "=== 4. Verify kernel parameters ==="

sysctl kernel.shmmax
sysctl kernel.shmall
sysctl fs.file-max
sysctl kernel.sem


echo "=== 5. Verify user limits ==="

su - oracle -c 'ulimit -n; ulimit -u'


echo "=== 6. Create Oracle directories ==="

mkdir -p "$ORACLE_BASE"
mkdir -p "$ORACLE_HOME"
mkdir -p "$ORA_INVENTORY"

chown oracle:"$OINSTALL_GROUP" "$ORACLE_BASE"
chown oracle:"$OINSTALL_GROUP" "$ORACLE_HOME"
chown oracle:"$OINSTALL_GROUP" "$ORA_INVENTORY"

chmod 775 "$ORACLE_BASE"
chmod 775 "$ORACLE_HOME"
chmod 775 "$ORA_INVENTORY"


echo "=== 7. Configure software permissions ==="

chown root:"$OINSTALL_GROUP" "$SOFTWARE_BASE"
chmod 750 "$SOFTWARE_BASE"

chown root:"$OINSTALL_GROUP" "$DB_SOFTWARE"
chmod 640 "$DB_SOFTWARE"


echo "=== 8. Configure oracle .bash_profile ==="

cat > /home/oracle/.bash_profile <<PROFILE_EOF
# .bash_profile

if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi

export DISPLAY=:0
export ORACLE_BASE=$ORACLE_BASE
export ORACLE_HOME=$ORACLE_HOME
export PATH=\$ORACLE_HOME/bin:\$PATH
PROFILE_EOF

chown oracle:"$OINSTALL_GROUP" /home/oracle/.bash_profile


echo "=== 9. Verify oracle environment ==="

su - oracle -c 'echo "ORACLE_BASE=$ORACLE_BASE"'
su - oracle -c 'echo "ORACLE_HOME=$ORACLE_HOME"'


echo "=== 10. Verify Database software ==="

ls -lh "$DB_SOFTWARE"


echo "=== 11. Extract Database software ==="

if [ -f "$ORACLE_HOME/runInstaller" ]; then
    echo "Database software already extracted."
else
    su - oracle -c "
    unzip '$DB_SOFTWARE' -d '$ORACLE_HOME'
    "
fi


echo "=== 12. Install Database Software Only ==="

if [ -f "$INVENTORY_XML" ] && \
   grep -Fq "LOC=\"$ORACLE_HOME\"" "$INVENTORY_XML"; then

    echo "Oracle Database software is already installed."

else

    INSTALL_RC=0

    su - oracle -c "
    export ORACLE_BASE='$ORACLE_BASE'
    export ORACLE_HOME='$ORACLE_HOME'
    export PATH=\$ORACLE_HOME/bin:\$PATH

    cd \$ORACLE_HOME

    ./runInstaller -silent \
        -waitforcompletion \
        oracle.install.option=INSTALL_DB_SWONLY \
        UNIX_GROUP_NAME=oinstall \
        INVENTORY_LOCATION='$ORA_INVENTORY' \
        ORACLE_HOME='$ORACLE_HOME' \
        ORACLE_BASE='$ORACLE_BASE' \
        oracle.install.db.InstallEdition=EE \
        oracle.install.db.OSDBA_GROUP=dba \
        oracle.install.db.OSOPER_GROUP=dba \
        oracle.install.db.OSBACKUPDBA_GROUP=dba \
        oracle.install.db.OSDGDBA_GROUP=dba \
        oracle.install.db.OSKMDBA_GROUP=dba \
        oracle.install.db.OSRACDBA_GROUP=dba \
        DECLINE_SECURITY_UPDATES=true
    " || INSTALL_RC=$?

    if [ "$INSTALL_RC" -eq 6 ]; then
        echo "Oracle Database software installed with warnings."
    elif [ "$INSTALL_RC" -ne 0 ]; then
        echo "ERROR: Oracle installation failed. Exit code: $INSTALL_RC"
        exit "$INSTALL_RC"
    fi

fi


echo "=== 13. Run root scripts ==="

INVENTORY_ROOT_MARKER="$ORA_INVENTORY/.orainstroot_done"
DB_ROOT_MARKER="$ORACLE_HOME/.root_done"

if [ -f "$INVENTORY_ROOT_MARKER" ]; then
    echo "orainstRoot.sh already completed."
else
    "$ORA_INVENTORY/orainstRoot.sh"
    touch "$INVENTORY_ROOT_MARKER"
fi

if [ -f "$DB_ROOT_MARKER" ]; then
    echo "Database root.sh already completed."
else
    "$ORACLE_HOME/root.sh"
    touch "$DB_ROOT_MARKER"
fi


echo "=== 14. Verify Database software installation ==="

su - oracle -c "
export ORACLE_BASE='$ORACLE_BASE'
export ORACLE_HOME='$ORACLE_HOME'
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -v
"


echo "=== Oracle Database software installation completed ==="
