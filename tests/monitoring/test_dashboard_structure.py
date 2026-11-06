import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
class DashboardTest(unittest.TestCase):
    def test_scopes_and_required_rows(self):
        d = json.loads((ROOT / 'monitoring/grafana/node-traffic.json').read_text())
        self.assertEqual(d['uid'], 'node-traffic')
        self.assertEqual(d['title'], 'Node · Traffic')
        rows = {p['title'] for p in d['panels'] if p['type'] == 'row'}
        self.assertEqual(len(rows), 8)
        for p in d['panels']:
            for target in p.get('targets', []):
                query = target['expr']
                self.assertNotIn('vector(0)', query)
                if 'user_bytes_total' in query:
                    self.assertNotIn('client_ip=', query)
                    self.assertNotIn('inbound=', query)
                if 'access_events_total' in query:
                    self.assertNotIn('bytes', p['title'].lower())
    def test_metrics_match_contract(self):
        d = json.loads((ROOT / 'monitoring/grafana/node-traffic.json').read_text())
        queries = ' '.join(t['expr'] for p in d['panels'] for t in p.get('targets', []))
        for metric in ['familytraffic_user_bytes_total', 'familytraffic_inbound_bytes_total', 'familytraffic_access_events_total', 'familytraffic_fail2ban_banned', 'familytraffic_source_up']:
            self.assertIn(metric, queries)
