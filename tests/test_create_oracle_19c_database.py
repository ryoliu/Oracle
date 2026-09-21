"""Offline tests for the simple DBCA wrapper; no real Oracle commands are run."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "create_oracle_19c_database.sh"
BASH = r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash")


def unix_path(path):
    text = Path(path).resolve().as_posix()
    return "/" + text[0].lower() + text[2:] if os.name == "nt" else text


class SimpleDbcaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="simple_dbca_")
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.data = self.root / "data"
        self.fra = self.root / "fra"
        self.mocks = self.root / "mocks"
        for path in [self.home / "bin", self.home / "dbs", self.home / "network/admin",
                     self.home / "assistants/netca",
                     self.data / "ORCL", self.fra / "ORCL", self.mocks]:
            path.mkdir(parents=True)
        self.write(self.root / "oratab", "orcl:/old/home:N\n")
        self.write(self.root / "meminfo", "MemAvailable: 6291456 kB\n")
        self.write(self.root / "processes", "ora_pmon_orcl\n")
        self.write(self.root / "sockets", "")
        self.listener = self.home / "network/admin/listener.ora"
        self.write(self.listener, "LISTENER=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=dbhost)(PORT=1521)))\n")
        self.tns = self.home / "network/admin/tnsnames.ora"
        self.write(self.home / "assistants/netca/netca.rsp", '''[GENERAL]
RESPONSEFILE_VERSION="19.0"
[oracle.net.ca]
LISTENER_NUMBER=1
LISTENER_NAMES={"LISTENER"}
LISTENER_PROTOCOLS={"TCP;1521"}
LISTENER_START="LISTENER"
NSN_NUMBER=1
''')
        self.mock("uname", "echo Linux")
        self.mock("id", "echo oracle")
        self.mock("ps", 'cat "$MOCK_ROOT/processes"')
        self.mock("ss", 'cat "$MOCK_ROOT/sockets"')
        self.mock("hostname", "echo dbhost")
        self.mock("dialog", 'printf "%s" "$MOCK_SID"; exit "$MOCK_DIALOG_RC"')
        self.mock("netca", '''echo netca >> "$MOCK_ROOT/order"
if [ "$MOCK_NETCA_RC" != 0 ]; then exit "$MOCK_NETCA_RC"; fi
cp "$3" "$MOCK_ROOT/response"
echo 'LSNR_TESTDB=(ADDRESS=(PROTOCOL=TCP)(HOST=dbhost)(PORT=1522))' >> "$TNS_ADMIN/listener.ora"
''', self.home / "bin")
        self.mock("lsnrctl", '''if [ "$MOCK_LSNR_RC" != 0 ]; then exit "$MOCK_LSNR_RC"; fi
if [ "$1" = services ]; then
    printf 'Service "TESTDB" has 1 instance(s).\\n  Instance "TESTDB", status %s, has 1 handler(s)\\n' "$MOCK_STATE"
else
    echo '(ADDRESS=(PROTOCOL=TCP)(HOST=dbhost)(PORT=1522))'
fi
''', self.home / "bin")
        self.mock("tnsping", 'exit "$MOCK_TNSPING_RC"', self.home / "bin")
        self.mock("sqlplus", '''echo sqlplus >> "$MOCK_ROOT/order"
if [ "$2" = -s ]; then
    cat > "$MOCK_ROOT/register.sql"
    exit "$MOCK_SQL_RC"
fi
cp "${3#@}" "$MOCK_ROOT/verify.sql"
exit "$MOCK_LOGIN_RC"
''', self.home / "bin")
        self.mock("dbca", """printf '%s\\n' "$@" > "$MOCK_ROOT/arguments"
echo dbca >> "$MOCK_ROOT/order"
if [ "$MOCK_RC" != 0 ]; then exit "$MOCK_RC"; fi
echo "TESTDB:/mock/home:N" >> "$MOCK_ROOT/oratab"
if [ -f "$MOCK_ROOT/dbca_tns" ]; then cp "$MOCK_ROOT/dbca_tns" "$TNS_ADMIN/tnsnames.ora"; fi
""", self.home / "bin")
        source = SOURCE.read_text()
        for old, new in {
            'ORACLE_BASE="/opt/oracle"': f'ORACLE_BASE="{unix_path(self.root)}"',
            'ORACLE_HOME="/opt/oracle/product/19.3.0.0/db_1"': f'ORACLE_HOME="{unix_path(self.home)}"',
            'DATA_DIR="/opt/oracle/oradata"': f'DATA_DIR="{unix_path(self.data)}"',
            'FRA_DIR="/opt/oracle/fast_recovery_area"': f'FRA_DIR="{unix_path(self.fra)}"',
            'HOST_PROFILE="$HOME/.$(hostname).profile"': f'HOST_PROFILE="{unix_path(self.root)}/.dbhost.profile"',
            '$HOME/.db_profile.XXXXXX': unix_path(self.root) + '/.db_profile.XXXXXX',
            "/etc/oratab": unix_path(self.root / "oratab"),
            "/proc/meminfo": unix_path(self.root / "meminfo"),
            "[ ! -t 0 ] || [ ! -t 1 ]": "[ false = true ]",
        }.items():
            self.assertIn(old, source)
            source = source.replace(old, new)
        source = source.replace("# Edit these settings", f'export PATH="{unix_path(self.mocks)}:$PATH"\n# Edit these settings', 1)
        self.script = self.root / "script.sh"
        self.write(self.script, source)
        self.env = os.environ.copy()
        self.env.pop("TNS_ADMIN", None)
        self.env.update(MOCK_ROOT=unix_path(self.root), MOCK_RC="0",
                        MOCK_SID="TESTDB", MOCK_DIALOG_RC="0",
                        MOCK_NETCA_RC="0", MOCK_LSNR_RC="0", MOCK_STATE="READY",
                        MOCK_TNSPING_RC="0", MOCK_SQL_RC="0", MOCK_LOGIN_RC="0",
                        MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, value):
        Path(path).write_text(value, encoding="utf-8", newline="\n")

    def mock(self, name, body, directory=None):
        path = (directory or self.mocks) / name
        self.write(path, "#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)

    def run_script(self):
        result = subprocess.run([BASH, unix_path(self.script)], env=self.env,
                                capture_output=True, text=True, timeout=20)
        self.output = result.stdout + result.stderr
        return result.returncode

    def test_create_preserves_other_db_and_uses_netca_before_dbca(self):
        original = self.listener.read_bytes()
        self.assertEqual(self.run_script(), 0, self.output)
        args = (self.root / "arguments").read_text().splitlines()
        self.assertIn("-listeners", args)
        self.assertIn("LSNR_TESTDB", args)
        self.assertNotIn("-createListener", args)
        self.assertIn("-useOMF", args)
        self.assertTrue(self.listener.read_bytes().startswith(original))
        self.assertEqual((self.root / "order").read_text().splitlines()[:2], ["netca", "dbca"])
        self.assertIn('LISTENER_PROTOCOLS={"TCP;1522"}', (self.root / "response").read_text())
        self.assertIn("NSN_NUMBER=0", (self.root / "response").read_text())
        self.assertIn("ALTER SYSTEM REGISTER", (self.root / "register.sql").read_text())
        self.assertIn("PORT=1522", (self.root / "register.sql").read_text())
        self.assertIn("unexpected database target", (self.root / "verify.sql").read_text())
        self.assertTrue((self.data / "ORCL").is_dir())
        self.assertEqual((self.root / ".dbhost.profile").read_text(),
                         '# BEGIN ORACLE DATABASE SETTINGS\nexport ORACLE_SID="TESTDB"\nDB_NAME="$ORACLE_SID"\nDB_UNIQUE_NAME="$ORACLE_SID"\n# END ORACLE DATABASE SETTINGS\n')

    def test_dialog_cancel_makes_no_changes(self):
        self.env["MOCK_DIALOG_RC"] = "1"
        self.assertNotEqual(self.run_script(), 0)
        self.assertFalse((self.root / "order").exists())
        self.assertFalse((self.root / ".dbhost.profile").exists())

    def test_dialog_rejects_invalid_sid(self):
        self.env["MOCK_SID"] = "bad;name"
        self.assertNotEqual(self.run_script(), 0)
        self.assertFalse((self.root / "order").exists())

    def test_profile_preserves_unrelated_lines_and_backs_up(self):
        profile = self.root / ".dbhost.profile"
        original = 'export ORACLE_SID="OLDDB"\nDB_NAME="OLDDB"\nDB_UNIQUE_NAME="OLDDB"\nexport EDITOR=vi\n'
        self.write(profile, original)
        self.assertEqual(self.run_script(), 0, self.output)
        self.assertEqual(Path(str(profile) + ".pre_db.bak").read_text(), original)
        self.assertIn("export EDITOR=vi\n", profile.read_text())
        self.assertNotIn("OLDDB", profile.read_text())
        self.assertEqual(profile.read_text().count('DB_NAME='), 1)

    def test_profile_compound_assignment_is_not_modified(self):
        profile = self.root / ".dbhost.profile"
        original = 'ORACLE_SID=OLDDB; export EDITOR=vi\n'
        self.write(profile, original)
        self.assertNotEqual(self.run_script(), 0)
        self.assertEqual(profile.read_text(), original)
        self.assertNotIn("All steps completed", self.output)

    def test_profile_managed_block_is_replaced_and_repeatable(self):
        profile = self.root / ".dbhost.profile"
        original = '# Keep this comment\n# BEGIN ORACLE DATABASE SETTINGS\nexport ORACLE_SID="OLDDB"\nDB_NAME="$ORACLE_SID"\nDB_UNIQUE_NAME="$ORACLE_SID"\n# END ORACLE DATABASE SETTINGS\nexport EDITOR=vi\n'
        self.write(profile, original)
        source = self.script.read_text()
        updater = source[source.index('echo "=== Save database settings'):]
        wrapper = self.root / "profile.sh"
        self.write(wrapper, f'''#!/bin/bash
HOST_PROFILE="{unix_path(profile)}"
ORACLE_SID=TESTDB
WORK_DIR=$(mktemp -d "{unix_path(self.root)}/work.XXXXXX")
''' + updater)
        first = subprocess.run([BASH, unix_path(wrapper)], env=self.env, capture_output=True, text=True)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        content = profile.read_bytes()
        self.assertIn("# Keep this comment\n", profile.read_text())
        self.assertIn("export EDITOR=vi\n", profile.read_text())
        self.assertNotIn("OLDDB", profile.read_text())
        self.assertEqual(profile.read_text().count("# BEGIN ORACLE DATABASE SETTINGS"), 1)
        second = subprocess.run([BASH, unix_path(wrapper)], env=self.env, capture_output=True, text=True)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("skipping update", second.stdout)
        self.assertEqual(profile.read_bytes(), content)
        self.assertEqual(Path(str(profile) + ".pre_db.bak").read_text(), original)

    def test_profile_unclosed_block_is_not_modified(self):
        profile = self.root / ".dbhost.profile"
        original = '# BEGIN ORACLE DATABASE SETTINGS\nexport ORACLE_SID="OLDDB"\nexport EDITOR=vi\n'
        self.write(profile, original)
        self.assertNotEqual(self.run_script(), 0)
        self.assertEqual(profile.read_text(), original)
        self.assertNotIn("All steps completed", self.output)

    def test_rerun_blocks_without_running_dbca(self):
        self.assertEqual(self.run_script(), 0, self.output)
        (self.root / "arguments").unlink()
        self.assertNotEqual(self.run_script(), 0)
        self.assertFalse((self.root / "arguments").exists())

    def test_case_insensitive_name_blocks(self):
        self.write(self.root / "oratab", "testdb:/old/home:N\n")
        self.assertNotEqual(self.run_script(), 0)
        self.assertIn("already exists", self.output)

    def test_existing_target_file_blocks(self):
        self.write(self.home / "dbs/spfiletestdb.ora", "existing")
        self.assertNotEqual(self.run_script(), 0)
        self.assertIn("files exist", self.output)

    def test_existing_target_directory_blocks(self):
        (self.data / "testdb").mkdir()
        self.assertNotEqual(self.run_script(), 0)
        self.assertIn("directory already exists", self.output)

    def test_listener_name_blocks(self):
        self.write(self.listener, "LSNR_TESTDB=(ADDRESS=(PROTOCOL=TCP)(PORT=1523))\n")
        self.assertNotEqual(self.run_script(), 0)
        self.assertIn("already configured", self.output)

    def test_stopped_listener_port_blocks(self):
        self.write(self.listener, "OTHER=(ADDRESS = (PROTOCOL=TCP)(PORT = 1522))\n")
        self.assertNotEqual(self.run_script(), 0)
        self.assertIn("already configured", self.output)

    def test_live_port_blocks(self):
        self.write(self.root / "sockets", "LISTEN 0 128 0.0.0.0:1522 0.0.0.0:*\n")
        self.assertNotEqual(self.run_script(), 0)
        self.assertIn("in use", self.output)

    def test_low_memory_is_informational(self):
        self.write(self.root / "meminfo", "MemAvailable: 1897216 kB\n")
        self.assertEqual(self.run_script(), 0, self.output)
        self.assertIn("Available RAM", self.output)
        self.assertIn("Memory is informational", self.output)

    def test_dbca_failure_is_returned(self):
        self.env["MOCK_RC"] = "7"
        self.assertEqual(self.run_script(), 7, self.output)
        self.assertIn("DBCA returned 7", self.output)
        self.assertNotIn("completed successfully", self.output)

    def test_dbca_alias_is_preserved_if_correct(self):
        entry = "# DBCA alias\nTESTDB=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=dbhost)(PORT=1522))(CONNECT_DATA=(SERVICE_NAME=TESTDB)))\n"
        self.write(self.root / "dbca_tns", entry)
        self.assertEqual(self.run_script(), 0, self.output)
        self.assertEqual(self.tns.read_text(), entry)
        self.assertIn("skipping update", self.output)

    def test_dbca_address_list_and_dedicated_server_are_preserved(self):
        entry = "TESTDB=(DESCRIPTION=(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCP)(HOST=dbhost)(PORT=1522)))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=TESTDB)))\n"
        self.write(self.root / "dbca_tns", entry)
        self.assertEqual(self.run_script(), 0, self.output)
        self.assertEqual(self.tns.read_text(), entry)

    def test_alias_updater_can_run_twice_without_changes(self):
        source = self.script.read_text()
        updater = source[source.index('update_tns_alias() {'):source.index('echo "=== Preflight:')]
        updater += '\nupdate_tns_alias\n'
        work = self.root / "update"
        work.mkdir()
        wrapper = self.root / "update.sh"
        self.write(wrapper, f'''#!/bin/bash
TNS_ADMIN="{unix_path(self.tns.parent)}"
WORK_DIR="{unix_path(work)}"
ORACLE_SID=TESTDB
DB_HOST=dbhost
LISTENER_PORT=1522
DB_SERVICE=TESTDB
''' + updater)
        self.write(self.tns, "# Keep this entry\nOTHER=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=other)(PORT=1521)))\n")
        first = subprocess.run([BASH, unix_path(wrapper)], env=self.env, capture_output=True, text=True)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        content = self.tns.read_bytes()
        backup = Path(str(self.tns) + ".pre_alias.bak").read_bytes()
        second = subprocess.run([BASH, unix_path(wrapper)], env=self.env, capture_output=True, text=True)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("skipping update", second.stdout)
        self.assertEqual(self.tns.read_bytes(), content)
        self.assertEqual(Path(str(self.tns) + ".pre_alias.bak").read_bytes(), backup)

    def test_updates_multiline_target_preserving_unrelated_entries_and_backup(self):
        other = "# Other database\nORCL =\n (DESCRIPTION=\n (ADDRESS=(PROTOCOL=TCP)(HOST=oldhost)(PORT=1521))\n (CONNECT_DATA=(SERVICE_NAME=ORCL)))\n"
        target = "testdb\n =\n (DESCRIPTION=\n (ADDRESS=(PROTOCOL=TCP)(HOST=oldhost)(PORT=1523))\n (CONNECT_DATA=(SERVICE_NAME=TESTDB)))\n"
        self.write(self.root / "dbca_tns", other + target)
        self.assertEqual(self.run_script(), 0, self.output)
        self.assertTrue(self.tns.read_text().startswith(other))
        self.assertIn("(PORT = 1522)", self.tns.read_text())
        self.assertEqual(self.tns.read_text().upper().count("TESTDB ="), 1)
        self.assertEqual(Path(str(self.tns) + ".pre_alias.bak").read_text(), other + target)

    def test_unsafe_tns_is_not_replaced(self):
        entries = [
            "IFILE=/other/tnsnames.ora\n",
            "TESTDB=(DESCRIPTION=(ADDRESS=(PORT=1522))\n",
            "TESTDB=(DESCRIPTION=(ADDRESS=(PORT=1522)))\nTESTDB=(DESCRIPTION=(ADDRESS=(PORT=1523)))\n",
            "TESTDB,SHARED=(DESCRIPTION=(ADDRESS=(PORT=1523)))\n",
        ]
        # Isolate the updater so every case can run without recreating a database.
        source = self.script.read_text()
        updater = source[source.index('update_tns_alias() {'):source.index('echo "=== Preflight:')]
        updater += '\nupdate_tns_alias\n'
        for entry in entries:
            with self.subTest(entry=entry):
                self.write(self.tns, entry)
                work = self.root / "update"
                work.mkdir(exist_ok=True)
                wrapper = self.root / "update.sh"
                self.write(wrapper, f'''#!/bin/bash
TNS_ADMIN="{unix_path(self.tns.parent)}"
WORK_DIR="{unix_path(work)}"
ORACLE_SID=TESTDB
DB_HOST=dbhost
LISTENER_PORT=1522
DB_SERVICE=TESTDB
''' + updater)
                result = subprocess.run([BASH, unix_path(wrapper)], env=self.env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.tns.read_text(), entry)

    def test_netca_failure_prevents_dbca(self):
        self.env["MOCK_NETCA_RC"] = "1"
        self.assertNotEqual(self.run_script(), 0)
        self.assertFalse((self.root / "arguments").exists())

    def test_listener_failure_prevents_dbca(self):
        self.env["MOCK_LSNR_RC"] = "1"
        self.assertNotEqual(self.run_script(), 0)
        self.assertFalse((self.root / "arguments").exists())

    def test_registration_failure_prevents_tns_update(self):
        self.env["MOCK_SQL_RC"] = "1"
        self.assertNotEqual(self.run_script(), 0)
        self.assertFalse(self.tns.exists())

    def test_tnsping_failure_stops_before_login(self):
        self.env["MOCK_TNSPING_RC"] = "1"
        self.assertNotEqual(self.run_script(), 0)
        self.assertFalse((self.root / "verify.sql").exists())

    def test_listener_state_is_displayed_for_manual_review(self):
        self.env["MOCK_STATE"] = "UNKNOWN"
        self.assertEqual(self.run_script(), 0, self.output)
        self.assertIn("status UNKNOWN", self.output)
        self.assertIn("Review the service listing", self.output)
        self.assertTrue((self.root / "verify.sql").exists())

    def test_login_failure_is_not_success(self):
        self.env["MOCK_LOGIN_RC"] = "1"
        self.assertNotEqual(self.run_script(), 0)
        self.assertNotIn("completed successfully", self.output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
