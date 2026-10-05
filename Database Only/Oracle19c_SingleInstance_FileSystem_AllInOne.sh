#!/bin/bash
set -euo pipefail

PACKAGE="oracle-database-preinstall-19c"

ORACLE_BASE="/opt/oracle"
ORACLE_HOME="/opt/oracle/product/19.3.0.0/db_1"

ORA_INVENTORY="/opt/oraInventory"
OINSTALL_GROUP="oinstall"

SOFTWARE_BASE="/software"
DB_SOFTWARE="/software/LINUX.X64_193000_db_home.zip"

DATA_BASE="/oradata"
FRA_BASE="/fra"

INVENTORY_XML="$ORA_INVENTORY/ContentsXML/inventory.xml"
INVENTORY_ROOT_MARKER="$ORA_INVENTORY/.orainstroot_done"
DB_ROOT_MARKER="$ORACLE_HOME/.root_done"


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


echo "=== 15. Database name ==="

read -p "Enter DB_NAME: " DB_NAME

if [ -z "$DB_NAME" ]; then
    echo "ERROR: DB_NAME cannot be empty."
    exit 1
fi


DATA_DIR="$DATA_BASE"
FRA_DIR="$FRA_BASE"


echo "=== 16. Create File System directories ==="

mkdir -p "$DATA_DIR"
mkdir -p "$FRA_DIR"

chown oracle:"$OINSTALL_GROUP" "$DATA_DIR"
chown oracle:"$OINSTALL_GROUP" "$FRA_DIR"

chmod 775 "$DATA_DIR"
chmod 775 "$FRA_DIR"

ls -ld "$DATA_DIR" "$FRA_DIR"


echo "=== 17. Check Database ==="

if [ -f "$ORACLE_HOME/dbs/spfile${DB_NAME}.ora" ] || \
   [ -f "$ORACLE_HOME/dbs/init${DB_NAME}.ora" ]; then

    echo "Database $DB_NAME already exists."
    echo "Skip DBCA."

else

    echo "Database $DB_NAME does not exist."

    read -s -p "Enter SYS/SYSTEM password: " DB_PASSWORD
    echo

    if [ -z "$DB_PASSWORD" ]; then
        echo "ERROR: Password cannot be empty."
        exit 1
    fi


    echo "=== 18. Create Database ==="

    su - oracle -c "
    export ORACLE_BASE='$ORACLE_BASE'
    export ORACLE_HOME='$ORACLE_HOME'
    export PATH=\$ORACLE_HOME/bin:\$PATH
    export DISPLAY=:0

    dbca -silent -createDatabase \
        -templateName General_Purpose.dbc \
        -gdbname '$DB_NAME' \
        -sid '$DB_NAME' \
        -databaseConfigType SINGLE \
        -createAsContainerDatabase false \
        -sysPassword '$DB_PASSWORD' \
        -systemPassword '$DB_PASSWORD' \
        -storageType FS \
        -datafileDestination '$DATA_DIR' \
        -useOMF true \
        -recoveryAreaDestination '$FRA_DIR' \
        -recoveryAreaSize 8256 \
        -enableArchive true \
        -characterSet AL32UTF8 \
        -emConfiguration NONE
    "

fi


echo "=== 19. Check Database status ==="

if pgrep -f "ora_pmon_${DB_NAME}$" >/dev/null 2>&1; then

    echo "Database $DB_NAME is running."

else

    echo "Starting database $DB_NAME..."

    su - oracle -c "
    export ORACLE_SID='$DB_NAME'
    export ORACLE_BASE='$ORACLE_BASE'
    export ORACLE_HOME='$ORACLE_HOME'
    export PATH=\$ORACLE_HOME/bin:\$PATH

    sqlplus -s / as sysdba <<SQL_EOF
whenever sqlerror exit sql.sqlcode
startup;
exit
SQL_EOF
    "
fi


echo "=== 20. Configure Listener ==="

if su - oracle -c "
export ORACLE_HOME='$ORACLE_HOME'
export PATH=\$ORACLE_HOME/bin:\$PATH

lsnrctl status
" >/dev/null 2>&1; then

    echo "Listener is already running."

else

    echo "Listener does not exist or is not running."
    echo "Creating Listener..."

    su - oracle -c "
    export ORACLE_HOME='$ORACLE_HOME'
    export PATH=\$ORACLE_HOME/bin:\$PATH

    netca -silent -responsefile \$ORACLE_HOME/assistants/netca/netca.rsp
    "
fi


echo "=== Verify Listener ==="

su - oracle -c "
export ORACLE_HOME='$ORACLE_HOME'
export PATH=\$ORACLE_HOME/bin:\$PATH

lsnrctl status
"


echo "=== 21. Verify Database with SQLPlus ==="

su - oracle -c "
export ORACLE_SID='$DB_NAME'
export ORACLE_BASE='$ORACLE_BASE'
export ORACLE_HOME='$ORACLE_HOME'
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<SQL_EOF
set pagesize 100
set linesize 200

select instance_name, status, database_status
from v\\\$instance;

select name, open_mode, log_mode
from v\\\$database;

show parameter db_create_file_dest
show parameter db_recovery_file_dest

exit
SQL_EOF
"


echo "=== Oracle Database installation and creation completed ==="
