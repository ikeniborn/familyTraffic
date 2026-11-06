import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class TrafficDashboardTests(unittest.TestCase):
    def setUp(self):
        self.dashboard = json.loads((ROOT / 'monitoring/grafana/node-traffic.json').read_text())

    def test_identity_and_complete_rows(self):
        self.assertEqual(self.dashboard['uid'], 'node-traffic')
        self.assertEqual(self.dashboard['title'], 'Node · Traffic')
        rows = {p['title'] for p in self.dashboard['panels'] if p['type'] == 'row'}
        self.assertEqual(rows, {'Health', 'Traffic', 'Users', 'Frontends', 'Addresses', 'Errors', 'Blocking', 'Exporter'})

    def test_filters_do_not_fabricate_byte_attribution(self):
        for panel in self.dashboard['panels']:
            for target in panel.get('targets', []):
                expr = target.get('expr', '')
                self.assertNotIn('or vector(0)', expr)
                if '_bytes_total' in expr:
                    self.assertNotIn('client_ip=', expr)
                    self.assertNotIn('destination=', expr)
                if 'familytraffic_user_bytes_total' in expr:
                    self.assertNotIn('inbound=', expr)

    def test_range_aware_address_filters_and_portable_datasource(self):
        variables = {x['name']: x for x in self.dashboard['templating']['list']}
        self.assertEqual(variables['DS_PROMETHEUS']['type'], 'datasource')
        for name in ('client', 'destination'):
            self.assertEqual(variables[name]['type'], 'query')
            self.assertTrue(variables[name]['allowCustomValue'])
            self.assertIn('topk(200', variables[name]['query'])
            self.assertIn('$__range', variables[name]['query'])
        self.assertIn('$__range', variables['user']['query'])
        panels = [x for x in self.dashboard['panels'] if x['type'] != 'row']
        self.assertTrue(all(x['datasource']['uid'] == '${DS_PROMETHEUS}' for x in panels))
        self.assertTrue(any('overflow' in t.get('expr', '') for p in panels for t in p.get('targets', [])))

    def test_scope_filters_and_quality_are_independent(self):
        variables = {x['name']: x for x in self.dashboard['templating']['list']}
        self.assertTrue({'account_class', 'listener', 'jail', 'protocol', 'source'} <= variables.keys())
        quality = next(p for p in self.dashboard['panels'] if p['title'].startswith('Address completeness'))
        expressions = [x['expr'] for x in quality['targets']]
        self.assertGreaterEqual(len(expressions), 3)
        self.assertFalse(any(' + on(' in x for x in expressions))
        self.assertTrue(any('auth_collection_gaps_total' in x for p in self.dashboard['panels'] for x in [t.get('expr', '') for t in p.get('targets', [])]))

if __name__ == '__main__':
    unittest.main()
