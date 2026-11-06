import importlib.util
import pathlib
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('snapshot', pathlib.Path(__file__).resolve().parents[2] / 'monitoring/helpers/fail2ban_snapshot.py')
class SnapshotTest(unittest.TestCase):
    def module(self):
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    def test_fixed_read_commands_and_ip_validation(self):
        m = self.module()
        calls = []
        def run(args, **kw):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0, '|- Currently banned: 2\n`- Banned IP list: 192.0.2.1 2001:db8::1\n', '')
        data = m.collect(run)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0], ['/usr/bin/fail2ban-client', 'status', 'sshd'])
        self.assertEqual(data['jails']['sshd']['count'], 2)
    def test_failure_keeps_existing_snapshot(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'snapshot.json'
            p.write_text('preserved')
            with self.assertRaises(RuntimeError):
                m.publish(p, lambda *a, **kw: subprocess.CompletedProcess(a, 1, '', 'denied'))
            self.assertEqual(p.read_text(), 'preserved')

    def test_auth_counters_recover_and_preserve_mode(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'auth.log'
            p.write_text('FT_AUTH_FAILURE protocol=http src=192.0.2.1 username="secret"\n')
            p.chmod(0o600)
            first = m.read_auth({}, p, start_at_end=False)
            self.assertEqual(first['auth']['http'], 1)
            self.assertEqual(m.read_auth(first, p)['auth']['http'], 1)
            with p.open('a') as stream:
                stream.write('FT_AUTH_FAILURE protocol=socks src=192.0.2.1\n')
            second = m.read_auth(first, p)
            self.assertEqual(second['auth']['socks'], 1)
            self.assertNotIn('secret', str(second))
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)

    def test_initial_auth_snapshot_starts_at_end(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'auth.log'
            p.write_text('FT_AUTH_FAILURE protocol=http src=192.0.2.1\n')
            first = m.read_auth({}, p)
            self.assertEqual(first['auth']['http'], 0)
            with p.open('a') as stream:
                stream.write('FT_AUTH_FAILURE protocol=http src=192.0.2.1\n')
            self.assertEqual(m.read_auth(first, p)['auth']['http'], 1)
    def test_first_rotation_marker_marks_auth_possible_loss(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'auth.log'
            p.write_text('old\n')
            first = m.read_auth({}, p)
            p.write_text('FT_AUTH_FAILURE protocol=http src=192.0.2.1\n' * 3)
            (p.parent / 'traffic-rotation-generation').write_text('first')
            second = m.read_auth(first, p)
            self.assertEqual(second['auth_gaps'], 1)
