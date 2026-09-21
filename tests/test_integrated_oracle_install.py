"""Exercise integration with mocked OS/Oracle tools, never a real installation."""
from pathlib import Path
import subprocess
import unittest

import test_create_oracle_19c_database as standalone_tests

BASH = standalone_tests.BASH
unix_path = standalone_tests.unix_path


SOURCE = Path(__file__).resolve().parents[1] / "oracle_linux_7_8_19c_full_install.sh"


class IntegratedInstallTests(unittest.TestCase):
    write = standalone_tests.SimpleDbcaTests.write
    mock = standalone_tests.SimpleDbcaTests.mock
    tearDown = standalone_tests.SimpleDbcaTests.tearDown

    def setUp(self):
        standalone_tests.SimpleDbcaTests.setUp(self)
        self.write(self.root / "os-release", 'ID=ol\nVERSION_ID=8\n')
        (self.home / "assistants/dbca").mkdir()
        self.write(self.home / "assistants/dbca/dbca.rsp",
                   'responseFileVersion=/oracle/assistants/rspfmt_dbca_response_schema_v19.0.0\nsysPassword=\nsystemPassword=\n')
        self.mock("id", '''case "$1" in
-u) echo 0 ;;
-un) echo oracle ;;
oracle) [ "$MOCK_USER_EXISTS" = 1 ] ;;
*) exit 1 ;;
esac''')
        self.mock("dialog", '''echo "dialog" >> "$MOCK_ROOT/events"
if [ "$MOCK_DIALOG_RC" != 0 ]; then exit "$MOCK_DIALOG_RC"; fi
case "$*" in
*"Confirm the oracle OS"*) printf '%s' "$MOCK_OS_CONFIRM" ;;
*"Enter the oracle OS"*) printf '%s' "$MOCK_OS_PASSWORD" ;;
*"Enter SID"*) printf '%s' "$MOCK_SID" ;;
*"Enter Listener TCP"*) printf '%s' "$MOCK_PORT" ;;
*"Confirm the shared"*) printf '%s' "$MOCK_DB_CONFIRM" ;;
*"Enter the shared"*) printf '%s' "$MOCK_DB_PASSWORD" ;;
*) exit 2 ;;
esac''')
        self.mock("mock_install", '''echo "install" >> "$MOCK_ROOT/events"
exit "$MOCK_INSTALL_RC"''')
        self.mock("chpasswd", '''echo "chpasswd" >> "$MOCK_ROOT/events"
IFS= read -r credentials
if [ "$credentials" != "oracle:$MOCK_OS_PASSWORD" ]; then exit 1; fi
exit 0''')
        # NTFS does not implement Linux ownership; record the requested operations.
        self.mock("chown", 'printf "%s\\n" "$*" >> "$MOCK_ROOT/ownership"')
        self.mock("chmod", '''printf '%s\\n' "$*" >> "$MOCK_ROOT/modes"
/usr/bin/chmod "$@"''')
        self.mock("runuser", '''printf '%s\\n' "$@" > "$MOCK_ROOT/runuser.args"
echo "worker" >> "$MOCK_ROOT/events"
if [ "$MOCK_INTERRUPT" = 1 ]; then
    kill -TERM "$PPID"
    sleep 1
    exit 143
fi
shift 3
exec "$@"''')
        self.mock("dbca", '''echo "dbca" >> "$MOCK_ROOT/events"
printf '%s\\n' "$@" > "$MOCK_ROOT/arguments"
while [ "$#" -gt 0 ]; do
    if [ "$1" = -responseFile ]; then shift; response="$1"; break; fi
    shift
done
test -f "$response" || exit 2
cp "$response" "$MOCK_ROOT/observed.rsp"
printf '%s\\n' "${response%/*}" > "$MOCK_ROOT/secret.path"
if [ "$MOCK_RC" != 0 ]; then exit "$MOCK_RC"; fi
echo "TESTDB:/mock/home:N" >> "$MOCK_ROOT/oratab"
if [ -f "$MOCK_ROOT/dbca_tns" ]; then cp "$MOCK_ROOT/dbca_tns" "$TNS_ADMIN/tnsnames.ora"; fi
''', self.home / "bin")
        self.mock("sqlplus", '''echo "sqlplus" >> "$MOCK_ROOT/events"
printf '%s\\n' "$@" >> "$MOCK_ROOT/sqlplus.args"
if [ "$3" = / ]; then
    cat > "$MOCK_ROOT/register.sql"
    exit "$MOCK_SQL_RC"
fi
script="${4#@}"
cp "$script" "$MOCK_ROOT/verify.sql"
login=$(sed -n 's/^@"\\(.*connect.sql\\)"$/\\1/p' "$script")
test -f "$login" || exit 2
cp "$login" "$MOCK_ROOT/observed.sql"
exit "$MOCK_LOGIN_RC"
''', self.home / "bin")
        source = SOURCE.read_text()
        # Keep the real password application; replace only the large OS installer body.
        begin = source.index('# BEGIN SOFTWARE INSTALLATION')
        end = source.index('# END SOFTWARE INSTALLATION')
        password_start = source.index('if [ "$ORACLE_USER_EXISTED_BEFORE_PREINSTALL" -eq 0 ] ||\n   [ "$PASSWORD_RESET_REQUESTED" -eq 1 ]; then', begin)
        password_end = source.index('\nfi', password_start) + len('\nfi')
        self.password_apply = source[password_start:password_end]
        source = source[:begin] + 'if ! mock_install; then exit 1; fi\n' + self.password_apply + '\n' + source[end:]
        for old, new in {
            'ORACLE_BASE="/opt/oracle"': f'ORACLE_BASE="{unix_path(self.root)}"',
            'ORACLE_HOME="/opt/oracle/product/19.3.0.0/db_1"': f'ORACLE_HOME="{unix_path(self.home)}"',
            'DATA_DIR="/opt/oracle/oradata"': f'DATA_DIR="{unix_path(self.data)}"',
            'FRA_DIR="/opt/oracle/fast_recovery_area"': f'FRA_DIR="{unix_path(self.fra)}"',
            '/etc/os-release': unix_path(self.root / 'os-release'),
            '/etc/oratab': unix_path(self.root / 'oratab'),
            '/proc/meminfo': unix_path(self.root / 'meminfo'),
            '/tmp/oracle_db_credentials.XXXXXX': unix_path(self.root) + '/credentials.XXXXXX',
            'HOST_PROFILE="$HOME/.$(hostname).profile"': f'HOST_PROFILE="{unix_path(self.root)}/.dbhost.profile"',
            '$HOME/.db_profile.XXXXXX': unix_path(self.root) + '/.db_profile.XXXXXX',
            '[ ! -t 0 ] || [ ! -t 1 ]': '[ false = true ]',
        }.items():
            self.assertIn(old, source)
            source = source.replace(old, new)
        source = source.replace('set +x +v', f'set +x +v\nexport PATH="{unix_path(self.mocks)}:$PATH"', 1)
        self.write(self.script, source)
        self.env.update(MOCK_USER_EXISTS='1', MOCK_INSTALL_RC='0', MOCK_PORT='1522',
                        MOCK_INTERRUPT='0',
                        MOCK_OS_PASSWORD='OsSecret42!', MOCK_OS_CONFIRM='OsSecret42!',
                        MOCK_DB_PASSWORD='DbSecret42!$#@&', MOCK_DB_CONFIRM='DbSecret42!$#@&')

    def run_script(self, *args, trace=False):
        command = [BASH]
        if trace:
            command += ['-x']
        result = subprocess.run(command + [unix_path(self.script), *args], env=self.env,
                                capture_output=True, text=True, timeout=30)
        self.output = result.stdout + result.stderr
        return result.returncode

    def events(self):
        path = self.root / 'events'
        return path.read_text().splitlines() if path.exists() else []

    def assert_clean(self):
        self.assertEqual(list(self.root.glob('credentials.*')), [])
        self.assertEqual(list((self.home / 'network/admin').glob('.create_db.*')), [])

    def test_help_needs_no_dialog_or_install(self):
        self.assertEqual(self.run_script('--help'), 0, self.output)
        self.assertIn('--create-db', self.output)
        self.assertEqual(self.events(), [])

    def test_software_only_preserves_existing_password_and_skips_db(self):
        self.assertEqual(self.run_script(), 0, self.output)
        self.assertEqual(self.events(), ['install'])
        self.assertFalse((self.root / '.dbhost.profile').exists())
        self.assertFalse((self.root / 'runuser.args').exists())

    def test_new_os_user_password_is_collected_before_install(self):
        self.env['MOCK_USER_EXISTS'] = '0'
        self.assertEqual(self.run_script(), 0, self.output)
        self.assertEqual(self.events(), ['dialog', 'dialog', 'install', 'chpasswd'])

    def test_existing_os_user_can_reset_password(self):
        self.assertEqual(self.run_script('--set-password', '--la-paz'), 0, self.output)
        self.assertEqual(self.events(), ['dialog', 'dialog', 'install', 'chpasswd'])
        self.assertIn('America/La_Paz', self.output)

    def test_full_creation_collects_everything_first_and_cleans_secrets(self):
        self.assertEqual(self.run_script('--create-db', '--set-password', trace=True), 0, self.output)
        events = self.events()
        self.assertEqual(events[:8], ['dialog'] * 6 + ['install', 'chpasswd'])
        self.assertNotIn('dialog', events[8:])
        args = (self.root / 'arguments').read_text()
        self.assertIn('-responseFile', args)
        self.assertIn('-listeners', args)
        self.assertIn('LSNR_TESTDB', args)
        rsp = (self.root / 'observed.rsp').read_text()
        self.assertIn('sysPassword=' + self.env['MOCK_DB_PASSWORD'] + '\n', rsp)
        self.assertIn('systemPassword=' + self.env['MOCK_DB_PASSWORD'] + '\n', rsp)
        login = (self.root / 'observed.sql').read_text()
        self.assertIn('DEFINE OFF', login)
        self.assertIn('CONNECT system/"' + self.env['MOCK_DB_PASSWORD'] + '"@TESTDB\n', login)
        profile = (self.root / '.dbhost.profile').read_text()
        self.assertIn('DB_NAME="$ORACLE_SID"', profile)
        self.assertIn('DB_UNIQUE_NAME="$ORACLE_SID"', profile)
        for secret in [self.env['MOCK_DB_PASSWORD'], self.env['MOCK_OS_PASSWORD']]:
            for content in [self.output, args, (self.root / 'runuser.args').read_text(), (self.root / 'sqlplus.args').read_text()]:
                self.assertNotIn(secret, content)
        modes = (self.root / 'modes').read_text()
        self.assertIn('700 ', modes)
        self.assertIn('600 ', modes)
        self.assertIn('oracle:oinstall', (self.root / 'ownership').read_text())
        self.assert_clean()

    def test_cancel_prevents_install(self):
        self.env['MOCK_DIALOG_RC'] = '1'
        self.assertNotEqual(self.run_script('--create-db'), 0)
        self.assertNotIn('install', self.events())

    def test_mismatched_password_prevents_install(self):
        self.env['MOCK_DB_CONFIRM'] = 'different'
        self.assertNotEqual(self.run_script('--create-db'), 0)
        self.assertNotIn('install', self.events())

    def test_os_password_mismatch_prevents_install(self):
        self.env['MOCK_OS_CONFIRM'] = 'different'
        self.assertNotEqual(self.run_script('--set-password'), 0)
        self.assertNotIn('install', self.events())

    def test_missing_dialog_prevents_install(self):
        (self.mocks / 'dialog').unlink()
        self.assertNotEqual(self.run_script('--create-db'), 0)
        self.assertIn('Install dialog', self.output)
        self.assertNotIn('install', self.events())

    def test_unsupported_os_prevents_prompts(self):
        self.write(self.root / 'os-release', 'ID=ubuntu\nVERSION_ID=24\n')
        self.assertNotEqual(self.run_script('--create-db'), 0)
        self.assertEqual(self.events(), [])

    def test_root_script_uses_preset_answers(self):
        original = SOURCE.read_text()
        start = original.index('# Answer the standard local-bin prompt')
        end = original.index('echo "root.sh completed successfully."', start)
        self.mock('root.sh', '''IFS= read -r local_bin
printf '%s\\n' "$local_bin" > "$MOCK_ROOT/root.answers"
for tool in dbhome oraenv coraenv; do
    IFS= read -r overwrite
    printf '%s\\n' "$overwrite" >> "$MOCK_ROOT/root.answers"
done
''', self.home)
        wrapper = self.root / 'root-input.sh'
        self.write(wrapper, f'ORACLE_HOME="{unix_path(self.home)}"\nLOCAL_BIN_DIR=/usr/local/bin\n' + original[start:end])
        result = subprocess.run([BASH, unix_path(wrapper)], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'root.answers').read_text().splitlines(), ['/usr/local/bin', 'n', 'n', 'n'])

    def test_invalid_sid_and_port_prevent_install(self):
        for key, value in [('MOCK_SID', 'bad;sid'), ('MOCK_PORT', '70000')]:
            with self.subTest(key=key):
                original = self.env[key]
                self.env[key] = value
                self.assertNotEqual(self.run_script('--create-db'), 0)
                self.assertNotIn('install', self.events())
                self.env[key] = original

    def test_invalid_password_characters_prevent_install(self):
        for value in ['bad"password', 'bad\npassword', 'bad\rpassword']:
            with self.subTest(value=repr(value)):
                self.env.update(MOCK_DB_PASSWORD=value, MOCK_DB_CONFIRM=value)
                self.assertNotEqual(self.run_script('--create-db'), 0)
                self.assertNotIn('install', self.events())

    def test_response_escapes_backslash_and_spaces_without_changing_sql_password(self):
        password = ' Secret\\a42! '
        self.env.update(MOCK_DB_PASSWORD=password, MOCK_DB_CONFIRM=password)
        self.assertEqual(self.run_script('--create-db'), 0, self.output)
        rsp = (self.root / 'observed.rsp').read_text()
        escaped = password.replace('\\', '\\\\').replace(' ', '\\ ')
        self.assertIn('sysPassword=' + escaped + '\n', rsp)
        self.assertIn('"' + password + '"', (self.root / 'observed.sql').read_text())

    def test_install_failure_prevents_worker(self):
        self.env['MOCK_INSTALL_RC'] = '1'
        self.assertNotEqual(self.run_script('--create-db'), 0)
        self.assertNotIn('worker', self.events())
        self.assert_clean()

    def test_existing_database_is_not_recreated(self):
        self.write(self.root / 'oratab', 'TESTDB:/old/home:N\n')
        self.assertNotEqual(self.run_script('--create-db'), 0)
        self.assertNotIn('dbca', self.events())
        self.assert_clean()

    def test_dbca_failure_is_returned_and_secrets_are_removed(self):
        self.env['MOCK_RC'] = '7'
        self.assertEqual(self.run_script('--create-db'), 7, self.output)
        self.assertNotIn(' Completed', self.output)
        self.assertFalse((self.root / '.dbhost.profile').exists())
        self.assert_clean()

    def test_login_failure_does_not_update_profile(self):
        self.env['MOCK_LOGIN_RC'] = '1'
        self.assertNotEqual(self.run_script('--create-db'), 0)
        self.assertFalse((self.root / '.dbhost.profile').exists())
        self.assert_clean()

    def test_netca_failure_cleans_secrets_and_prevents_dbca(self):
        self.env['MOCK_NETCA_RC'] = '1'
        self.assertNotEqual(self.run_script('--create-db'), 0)
        self.assertNotIn('dbca', self.events())
        self.assert_clean()

    def test_signal_cleans_private_credentials(self):
        self.env['MOCK_INTERRUPT'] = '1'
        self.assertEqual(self.run_script('--create-db'), 143, self.output)
        self.assertNotIn('dbca', self.events())
        self.assert_clean()

    def test_existing_tns_and_profile_entries_are_preserved(self):
        other = 'OTHER=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=other)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=OTHER)))\n'
        self.write(self.root / 'dbca_tns', other)
        profile = self.root / '.dbhost.profile'
        original = 'export EDITOR=vi\n'
        self.write(profile, original)
        self.assertEqual(self.run_script('--create-db'), 0, self.output)
        self.assertTrue(self.tns.read_text().startswith(other))
        self.assertTrue(profile.read_text().startswith(original))
        self.assertEqual(Path(str(profile) + '.pre_db.bak').read_text(), original)
        self.assert_clean()

    def test_rerun_does_not_recreate_target(self):
        self.assertEqual(self.run_script('--create-db'), 0, self.output)
        count = self.events().count('dbca')
        profile = (self.root / '.dbhost.profile').read_bytes()
        self.assertNotEqual(self.run_script('--create-db'), 0)
        self.assertEqual(self.events().count('dbca'), count)
        self.assertEqual((self.root / '.dbhost.profile').read_bytes(), profile)
        self.assert_clean()


if __name__ == '__main__':
    unittest.main(verbosity=2)
