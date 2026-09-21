#!/bin/bash

# Edit these settings, then run as oracle in an interactive terminal.
# Leave empty to use the SID entered in the dialog.
DB_SERVICE=""
ORACLE_BASE="/opt/oracle"
ORACLE_HOME="/opt/oracle/product/19.3.0.0/db_1"
DATA_DIR="/opt/oracle/oradata"
FRA_DIR="/opt/oracle/fast_recovery_area"
TOTAL_MEMORY_MB=2048
FRA_SIZE_MB=10240
LISTENER_PORT=1522
DB_HOST="$(hostname -f)"

# Keep the TNS parser separate so the creation steps stay readable.
update_tns_alias() {
    TNS_FILE="$TNS_ADMIN/tnsnames.ora"
    TNS_INPUT="$TNS_FILE"
    if [ ! -e "$TNS_FILE" ]; then
        TNS_INPUT=/dev/null
    fi
    if [ -L "$TNS_FILE" ] || [ ! -r "$TNS_INPUT" ]; then
        echo "ERROR: TNS file must be readable and must not be a symlink."
        exit 1
    fi
    # Parse complete parenthesized entries, never replace arbitrary matching lines.
    # Unsupported syntax is rejected without changing the original file.
    if ! awk -v alias="$ORACLE_SID" -v host="$DB_HOST" -v port="$LISTENER_PORT" -v service="$DB_SERVICE" '
    function compact(value) {
        gsub(/[[:space:]]/, "", value)
        value=toupper(value)
        gsub(/\(SERVER=DEDICATED\)/, "", value)
        # A single ADDRESS_LIST wrapper does not change the target endpoint.
        sub(/\(ADDRESS_LIST=\(ADDRESS=/, "(ADDRESS=", value)
        sub(/\)\)\)\(CONNECT_DATA=/, "))(CONNECT_DATA=", value)
        return value
    }
    function fail() { bad=1; exit 1 }
    function finish(    header, names, count, i, target) {
        header=substr(clean,1,index(clean,"=")-1)
        gsub(/[[:space:]]/, "", header)
        if (header !~ /^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$/) fail()
        count=split(header,names,",")
        for (i=1;i<=count;i++) if (toupper(names[i])==toupper(alias)) target=1
        if (target) {
            if (count!=1 || found++) fail()
            if (compact(clean)==compact(desired)) output=output raw
            else output=output desired "\n"
        } else output=output raw
        raw=""; clean=""; opened=0
    }
    BEGIN {
        desired=alias " =\n  (DESCRIPTION =\n    (ADDRESS = (PROTOCOL = TCP)(HOST = " host ")(PORT = " port "))\n    (CONNECT_DATA = (SERVICE_NAME = " service "))\n  )"
    }
    {
        line=$0
        sub(/#.*/, "", line)
        if (line ~ /["\047\\]/ || toupper(line) ~ /^[[:space:]]*IFILE[[:space:]]*=/) fail()
        if (raw=="" && line ~ /^[[:space:]]*$/) { output=output $0 "\n"; next }
        raw=raw $0 "\n"; clean=clean line "\n"
        for (i=1;i<=length(line);i++) {
            ch=substr(line,i,1)
            if (ch=="(") { depth++; opened=1 }
            if (ch==")") {
                depth--
                if (depth<0) fail()
                if (depth==0 && substr(line,i+1) !~ /^[[:space:]]*$/) fail()
            }
        }
        if (opened && depth==0) finish()
    }
    END {
        if (bad || raw!="" || depth!=0) exit 1
        if (!found) output=output "\n" desired "\n"
        printf "%s", output
    }' "$TNS_INPUT" > "$WORK_DIR/tnsnames.ora"; then
        echo "ERROR: TNS update refused: malformed syntax, IFILE, quotes, escapes, duplicate alias or shared target alias."
        echo "Review $TNS_FILE manually. The file was not changed by the updater."
        exit 1
    fi
    if cmp -s "$TNS_INPUT" "$WORK_DIR/tnsnames.ora"; then
        echo "DB connection alias is already configured; skipping update."
    else
        if [ -f "$TNS_FILE" ]; then
            if [ ! -e "$TNS_FILE.pre_alias.bak" ]; then
                if ! cp -p "$TNS_FILE" "$TNS_FILE.pre_alias.bak"; then
                    exit 1
                fi
            fi
            if ! chmod --reference="$TNS_FILE" "$WORK_DIR/tnsnames.ora"; then
                exit 1
            fi
        else
            if ! chmod 640 "$WORK_DIR/tnsnames.ora"; then
                exit 1
            fi
        fi
        if ! mv "$WORK_DIR/tnsnames.ora" "$TNS_FILE"; then
            exit 1
        fi
        echo "DB connection alias updated; unrelated entries retained."
    fi
}

echo "=== Preflight: Check user and settings ==="
if [ "$(uname -s)" != Linux ] || [ "$(id -un)" != oracle ]; then
    echo "ERROR: Run as oracle on the target Linux host."
    exit 1
fi
if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "ERROR: Run interactively for the SID dialog and password prompts."
    exit 1
fi
if ! command -v dialog >/dev/null 2>&1; then
    echo "ERROR: Install dialog to display the SID input window."
    exit 1
fi
if ! ORACLE_SID=$(dialog --stdout --title "Oracle Database Creation" \
    --inputbox "Enter ORACLE_SID (1-8 uppercase letters or digits, starting with a letter):" 10 76); then
    echo "Cancelled. No database changes were made."
    exit 1
fi
DB_NAME="$ORACLE_SID"
DB_UNIQUE_NAME="$ORACLE_SID"
if [ -z "$DB_SERVICE" ]; then
    DB_SERVICE="$ORACLE_SID"
fi
LISTENER_NAME="LSNR_$ORACLE_SID"
HOST_PROFILE="$HOME/.$(hostname).profile"
if [ -L "$HOST_PROFILE" ] || { [ -e "$HOST_PROFILE" ] && [ ! -f "$HOST_PROFILE" ]; }; then
    echo "ERROR: Host profile must be a regular file: $HOST_PROFILE"
    exit 1
fi
if [[ ! "$ORACLE_SID" =~ ^[A-Z][A-Z0-9]{0,7}$ ]]; then
    echo "ERROR: SID must be 1-8 uppercase letters or digits, starting with a letter."
    exit 1
fi
if [[ ! "$LISTENER_PORT" =~ ^[1-9][0-9]{3,4}$ ]] || [ "$LISTENER_PORT" -lt 1024 ] || [ "$LISTENER_PORT" -gt 65535 ]; then
    echo "ERROR: Use an unused port from 1024 to 65535."
    exit 1
fi
if [[ ! "$DB_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] ||
   [[ ! "$DB_SERVICE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    echo "ERROR: Use a DNS name or IPv4 address and a valid database service name."
    exit 1
fi
if [[ ! "$TOTAL_MEMORY_MB" =~ ^[1-9][0-9]{0,6}$ ]] || [[ ! "$FRA_SIZE_MB" =~ ^[1-9][0-9]{0,6}$ ]]; then
    echo "ERROR: Memory and FRA sizes must be positive integers in MB."
    exit 1
fi
if ! command -v ss >/dev/null 2>&1; then
    echo "ERROR: Missing command: ss"
    exit 1
fi
for TOOL in netca dbca lsnrctl sqlplus tnsping; do
    if [ ! -x "$ORACLE_HOME/bin/$TOOL" ]; then
        echo "ERROR: Missing Oracle tool: $TOOL"
        exit 1
    fi
done
NETCA_TEMPLATE="$ORACLE_HOME/assistants/netca/netca.rsp"
if [ ! -r "$NETCA_TEMPLATE" ]; then
    echo "ERROR: Cannot read $NETCA_TEMPLATE"
    exit 1
fi
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

echo "=== 2. Create and start Listener with NETCA ==="
if ! mkdir -p "$TNS_ADMIN"; then
    exit 1
fi
# Preserve the first backup before either assistant changes network settings.
for CONFIG_FILE in listener.ora sqlnet.ora tnsnames.ora; do
    if [ -f "$TNS_ADMIN/$CONFIG_FILE" ] && [ ! -e "$TNS_ADMIN/$CONFIG_FILE.pre_create.bak" ]; then
        if ! cp -p "$TNS_ADMIN/$CONFIG_FILE" "$TNS_ADMIN/$CONFIG_FILE.pre_create.bak"; then
            exit 1
        fi
    fi
done
if ! WORK_DIR=$(mktemp -d "$TNS_ADMIN/.create_db.XXXXXX"); then
    exit 1
fi
trap 'rm -f "$WORK_DIR/netca.rsp" "$WORK_DIR/tnsnames.ora" "$WORK_DIR/verify.sql"; rmdir "$WORK_DIR"' EXIT
# Use the installed response template so its version and sections remain intact.
for KEY in LISTENER_NUMBER LISTENER_NAMES LISTENER_PROTOCOLS LISTENER_START; do
    if ! grep -Eq "^[[:space:]]*$KEY[[:space:]]*=" "$NETCA_TEMPLATE"; then
        echo "ERROR: Missing NETCA template setting: $KEY"
        exit 1
    fi
done
if ! sed -e "s/^[[:space:]]*LISTENER_NUMBER[[:space:]]*=.*/LISTENER_NUMBER=1/" \
    -e "s/^[[:space:]]*LISTENER_NAMES[[:space:]]*=.*/LISTENER_NAMES={\"$LISTENER_NAME\"}/" \
    -e "s/^[[:space:]]*LISTENER_PROTOCOLS[[:space:]]*=.*/LISTENER_PROTOCOLS={\"TCP;$LISTENER_PORT\"}/" \
    -e "s/^[[:space:]]*LISTENER_START[[:space:]]*=.*/LISTENER_START=\"$LISTENER_NAME\"/" \
    -e '/^[[:space:]]*NSN_NUMBER[[:space:]]*=/d' \
    -e '/^[[:space:]]*\[oracle.net.ca\][[:space:]]*$/a NSN_NUMBER=0' \
    "$NETCA_TEMPLATE" > "$WORK_DIR/netca.rsp"; then exit 1; fi
if ! grep -q '^NSN_NUMBER=0$' "$WORK_DIR/netca.rsp"; then
    echo "ERROR: Missing NETCA response section."
    exit 1
fi
if ! "$ORACLE_HOME/bin/netca" -silent -responsefile "$WORK_DIR/netca.rsp"; then
    echo "ERROR: NETCA failed. Review its log and retained configuration before retrying."
    exit 1
fi
if ! LISTENER_STATUS=$("$ORACLE_HOME/bin/lsnrctl" status "$LISTENER_NAME"); then
    echo "ERROR: NETCA did not start the target Listener."
    exit 1
fi
printf '%s\n' "$LISTENER_STATUS"
if ! printf '%s\n' "$LISTENER_STATUS" | tr -d '[:space:]' | grep -Fiq "(HOST=$DB_HOST)(PORT=$LISTENER_PORT)"; then
    echo "ERROR: Listener endpoint does not match DB_HOST and LISTENER_PORT. Review before DBCA."
    exit 1
fi

echo "=== 3. Create Database with DBCA ==="
"$ORACLE_HOME/bin/dbca" -silent -createDatabase \
    -templateName General_Purpose.dbc \
    -gdbName "$DB_NAME" -sid "$ORACLE_SID" \
    -initParams "db_unique_name=$DB_UNIQUE_NAME" \
    -databaseConfigType SINGLE -createAsContainerDatabase false \
    -databaseType MULTIPURPOSE -storageType FS -useOMF true \
    -datafileDestination "$DATA_DIR" \
    -recoveryAreaDestination "$FRA_DIR" -recoveryAreaSize "$FRA_SIZE_MB" \
    -characterSet AL32UTF8 -nationalCharacterSet AL16UTF16 \
    -memoryMgmtType AUTO_SGA -totalMemory "$TOTAL_MEMORY_MB" \
    -listeners "$LISTENER_NAME" \
    -enableArchive false -emConfiguration NONE -sampleSchema false

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

echo "=== 6. Create or update the DB connection alias ==="
update_tns_alias

echo "=== 7. Verify Listener and client connectivity ==="
if ! "$ORACLE_HOME/bin/lsnrctl" status "$LISTENER_NAME" ||
   ! "$ORACLE_HOME/bin/lsnrctl" services "$LISTENER_NAME" ||
   ! "$ORACLE_HOME/bin/tnsping" "$ORACLE_SID"; then
    echo "ERROR: Listener or TNS verification failed."
    exit 1
fi
echo "Review the service listing above: the target instance should have READY status."
if ! cat > "$WORK_DIR/verify.sql" <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE
SET ECHO OFF VERIFY OFF
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
echo "Enter the SYSTEM password at the SQL*Plus prompt for the connection test."
if ! "$ORACLE_HOME/bin/sqlplus" -L "system@$ORACLE_SID" "@$WORK_DIR/verify.sql"; then
    echo "ERROR: SYSTEM connection or target verification failed."
    exit 1
fi
echo "Database creation and verification completed successfully."

echo "=== Save database settings in the host profile ==="
PROFILE_INPUT="$HOST_PROFILE"
if [ ! -e "$HOST_PROFILE" ]; then
    PROFILE_INPUT=/dev/null
fi
if ! PROFILE_TEMP=$(mktemp "$HOME/.db_profile.XXXXXX"); then
    exit 1
fi
trap 'rm -f "$WORK_DIR/netca.rsp" "$WORK_DIR/tnsnames.ora" "$WORK_DIR/verify.sql" "$PROFILE_TEMP"; rmdir "$WORK_DIR"' EXIT
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
