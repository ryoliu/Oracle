#!/bin/bash

ORACLE_USER="oracle"
ORACLE_BASE="/opt/oracle"
ORACLE_HOME="/opt/oracle/product/19.3.0.0/db_1"
INVENTORY_LOCATION="/opt/oracle/oraInventory"
INVENTORY_FILE="$INVENTORY_LOCATION/ContentsXML/inventory.xml"
ORAINST_FILE="/etc/oraInst.loc"

echo "========================================"
echo " Oracle Database 19c Software Install"
echo "========================================"


echo ""
echo "=== 1. Check execution user ==="

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be executed by root."
    exit 1
fi

echo "Execution user: root"


echo ""
echo "=== 2. Check Oracle user ==="

if ! id "$ORACLE_USER" >/dev/null 2>&1; then
    echo "ERROR: Oracle user does not exist."
    exit 1
fi

echo "Oracle user exists."


echo ""
echo "=== 3. Check Oracle Home ==="

if [ ! -d "$ORACLE_HOME" ]; then
    echo "ERROR: ORACLE_HOME does not exist."
    echo "$ORACLE_HOME"
    exit 1
fi

if [ ! -f "$ORACLE_HOME/runInstaller" ]; then
    echo "ERROR: runInstaller was not found."
    echo "$ORACLE_HOME/runInstaller"
    exit 1
fi

echo "ORACLE_HOME: $ORACLE_HOME"


echo ""
echo "=== 4. Check existing installation ==="

INSTALL_REQUIRED="Y"

if [ -f "$INVENTORY_FILE" ]; then

    if grep -q "LOC=\"$ORACLE_HOME\"" "$INVENTORY_FILE"; then
        echo "Oracle Database 19c software is already installed."
        echo "Skip software installation."
        INSTALL_REQUIRED="N"
    fi

fi


echo ""
echo "=== 5. Install Oracle Database 19c software ==="

if [ "$INSTALL_REQUIRED" = "Y" ]; then

    su - "$ORACLE_USER" -c "
        cd \"$ORACLE_HOME\" &&

        CV_ASSUME_DISTID=OL7 ./runInstaller \
            -silent \
            -waitforcompletion \
            -showProgress \
            oracle.install.option=INSTALL_DB_SWONLY \
            UNIX_GROUP_NAME=oinstall \
            INVENTORY_LOCATION=\"$INVENTORY_LOCATION\" \
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

    if [ "$INSTALL_STATUS" -ne 0 ]; then
        echo ""
        echo "ERROR: Oracle Database 19c software installation failed."
        echo "Exit code: $INSTALL_STATUS"
        exit 1
    fi

    echo ""
    echo "Oracle Database 19c software installation completed."

else

    echo "Software installation is not required."

fi


echo ""
echo "=== 6. Run orainstRoot.sh ==="

if [ -f "$ORAINST_FILE" ]; then

    if grep -q "^inventory_loc=$INVENTORY_LOCATION" "$ORAINST_FILE"; then
        echo "Oracle Inventory root configuration is already completed."
        echo "Skip orainstRoot.sh."
    else
        "$INVENTORY_LOCATION/orainstRoot.sh"

        if [ "$?" -ne 0 ]; then
            echo "ERROR: orainstRoot.sh failed."
            exit 1
        fi
    fi

else

    if [ ! -f "$INVENTORY_LOCATION/orainstRoot.sh" ]; then
        echo "ERROR: orainstRoot.sh was not found."
        exit 1
    fi

    "$INVENTORY_LOCATION/orainstRoot.sh"

    if [ "$?" -ne 0 ]; then
        echo "ERROR: orainstRoot.sh failed."
        exit 1
    fi

fi


echo ""
echo "=== 7. Run root.sh ==="

ROOT_SCRIPT_COMPLETED="N"

if grep -q "Finished product-specific root actions" \
    "$ORACLE_HOME"/install/root_*.log 2>/dev/null; then

    ROOT_SCRIPT_COMPLETED="Y"

fi

if [ "$ROOT_SCRIPT_COMPLETED" = "Y" ]; then

    echo "Oracle Home root configuration is already completed."
    echo "Skip root.sh."

else

    if [ ! -f "$ORACLE_HOME/root.sh" ]; then
        echo "ERROR: root.sh was not found."
        exit 1
    fi

    "$ORACLE_HOME/root.sh"

    ROOT_STATUS=$?

    if [ "$ROOT_STATUS" -ne 0 ]; then
        echo "ERROR: root.sh failed."
        exit 1
    fi

fi


echo ""
echo "========================================"
echo " Oracle Database 19c Installation Done"
echo "========================================"

echo ""
echo "ORACLE_BASE : $ORACLE_BASE"
echo "ORACLE_HOME : $ORACLE_HOME"
echo "Inventory   : $INVENTORY_LOCATION"
echo ""

exit 0
