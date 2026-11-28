"""The acceptance judge (scripts/rr/acceptance.py) on synthetic snapshots and samples; no device or app."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('acceptance', Path(__file__).parents[1] / 'acceptance.py')
acc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(acc)


def android_snapshot(version, code, pid, lease="a"):
    pref = lambda t, v: {'type': t, 'value': v}  # noqa: E731
    return {
        'versionName': version, 'versionCode': code, 'pid': pid, 'unattended': False,
        'prefs': {
            'bridgey': {'device_id': pref('String', 'd-1')},
            'bridgey.settings': {'device_name': pref('String', 'Acceptance phone'), 'connection.keep_wifi_awake': pref('Boolean', True)},
            'bridgey.attach': {'pending_draft.v1': pref('String', json.dumps({'version': 1, 'leaseProcess': lease, 'files': []}))},
            'bridgey.reconnect': {'address_book_v1': pref('String', '{"m":{"lastConnectedAt":%d}}' % pid)},
        },
        'trusted': [{'id': 'mac-1', 'agent': False, 'features': {'screen_draft1': True}, 'controlMode': 'always', 'controlChoice': 'always'}],
        'files': {
            'activity-stream.json': {'items': [{'id': 1}, {'id': 2}]},
            'file-resume.json': {'records': [{'offerId': 'kept'}]},
            'phone-control-grants.json': {'grants': {'version': 1, 'unattended': False, 'devices': {'mac-1': {'mode': 'always'}}}},
        },
    }


class CompareTests(unittest.TestCase):
    def test_a_clean_upgrade_passes_and_ignores_volatile_and_per_process_values(self):
        before = android_snapshot('1.0.0-beta.11-stress', 1, 10, lease='a')
        after = android_snapshot('1.0.0-nightly-stress', 2, 11, lease='b')
        after['files']['file-resume.json']['records'].append({'offerId': 'cut-by-upgrade'})
        final = copy.deepcopy(after)
        final['files']['activity-stream.json']['items'].append({'id': 3})
        final['files']['file-resume.json']['records'] = []
        failures, _ = acc.compare('android', before, after, final)
        self.assertEqual(failures, [])

    def test_lost_settings_grants_history_and_records_fail(self):
        before = android_snapshot('1.0.0-beta.11-stress', 1, 10)
        after = android_snapshot('1.0.0-nightly-stress', 2, 11)
        del after['prefs']['bridgey.settings']['device_name']
        after['unattended'] = True
        after['files']['file-resume.json']['records'] = []
        final = copy.deepcopy(after)
        final['files']['activity-stream.json']['items'] = [{'id': 2}]
        final['files']['file-resume.json']['records'] = [{'offerId': 'stale'}]
        failures = ' | '.join(acc.compare('android', before, after, final)[0])
        for expected in ('setting removed by the upgrade: bridgey.settings:device_name', 'Unattended access went from False to True',
                         'resume record lost in the upgrade', '1 of 2 items from before the upgrade are gone', 'left after both partials finished'):
            self.assertIn(expected, failures)

    def test_a_downgrade_or_the_same_build_fails(self):
        before = android_snapshot('1.0.0-beta.11-stress', 5, 10)
        after = android_snapshot('1.0.0-beta.11-stress', 5, 10)
        failures = ' | '.join(acc.compare('android', before, after, after)[0])
        self.assertIn('not an upgrade', failures)
        self.assertIn('did not restart', failures)


class SoakTests(unittest.TestCase):
    def samples(self, hours, rss_growth_per_hour, fds_end=60, pid_change=False, threads_end=40):
        out = []
        t = 0
        while t <= hours * 3600:
            idle = (t // 600) % 6 == 5
            out.append({'kind': 'app', 't': t, 'gc': (t // 60) % 5 == 0, 'idle': idle,
                        'app': {'ok': True, 'pid': 2 if pid_change and t > 3600 else 1, 'rss_kb': int((120 + rss_growth_per_hour * t / 3600) * 1024),
                                'threads': 40 if t < hours * 2400 else threads_end, 'fds': 60 if t < hours * 2400 else fds_end, 'javaUsed': 5 * 1024 * 1024, 'cpuMs': t * 2},
                        'peer': {'rss_kb': 9000}})
            if t % 600 == 0:
                out.append({'kind': 'op', 't': t, 'op': 'send-whole', 'ok': True, 'rounds': [{'done': True, 'size': 32 << 20, 'mib_per_s': 50.0}]})
            t += 60
        return out

    def judge(self, samples, report=None, device_log=None):
        checks, metrics, _ = acc.judge_soak('android', report or {'ok': True}, samples, '', device_log)
        return {c['check']: c['ok'] for c in checks}, metrics

    def test_a_steady_run_passes(self):
        verdict, metrics = self.judge(self.samples(4, 0.5))
        self.assertTrue(all(verdict.values()), verdict)
        self.assertAlmostEqual(metrics['idle']['cpu_percent'], 0.2, places=2)

    def test_growth_leaks_and_crashes_fail(self):
        verdict, _ = self.judge(self.samples(4, 20, fds_end=90, pid_change=True))
        self.assertFalse(verdict['resident memory'])
        self.assertFalse(verdict['open files'])
        self.assertFalse(verdict['no crash'])

    def test_a_short_run_is_judged_on_growth_not_slope(self):
        # Half an hour with 30 MiB of warm-up: an hourly slope says 60, the windows say little.
        verdict, _ = self.judge(self.samples(0.5, 30))
        self.assertTrue(verdict['resident memory'])
        verdict, _ = self.judge(self.samples(0.5, 300))
        self.assertFalse(verdict['resident memory'])

    def test_thread_growth_counts_only_on_long_runs(self):
        # 20 minutes with the IO dispatcher's threads up by 10: load, not a leak, so only the peak is judged.
        verdict, _ = self.judge(self.samples(1 / 3, 0.5, threads_end=50))
        self.assertTrue(verdict['threads'])
        # The same growth over 4 hours fails, and a runaway peak fails on any run.
        verdict, _ = self.judge(self.samples(4, 0.5, threads_end=50))
        self.assertFalse(verdict['threads'])
        verdict, _ = self.judge(self.samples(1 / 3, 0.5, threads_end=200))
        self.assertFalse(verdict['threads'])

    def test_notification_updates_shed_by_android_fail(self):
        quiet = ('11-28 00:40:01.100  1650  1650 I Bridgey : CLIP sent\n'
                 '11-28 00:40:02.000   600   640 E NotificationService: Package enqueue rate is 5.31. Shedding '
                 '0|com.example.other|7|null|10200. package=com.example.other\n')
        verdict, metrics = self.judge(self.samples(1 / 3, 0.5), device_log=quiet)
        self.assertTrue(verdict['notification updates shed'])
        self.assertEqual(metrics['notifications_shed']['lines'], 0)
        shed = quiet + ('11-28 00:41:10.512   600   641 E NotificationService: Package enqueue rate is 5.6243. Shedding '
                        '0|in.roundrobin.bridgey.stress|42458|null|10234. package=in.roundrobin.bridgey.stress\n'
                        '11-28 00:41:16.020   600   641 E NotificationService: Package enqueue rate is 6.0. Shedding '
                        '0|in.roundrobin.bridgey.stress|50731|null|10234. package=in.roundrobin.bridgey.stress\n')
        verdict, metrics = self.judge(self.samples(1 / 3, 0.5), device_log=shed)
        self.assertFalse(verdict['notification updates shed'])
        self.assertEqual(metrics['notifications_shed'], {'lines': 2, 'max_rate': 6.0, 'ids': ['42458', '50731']})
        # Without a device log (a run before the check, or the Mac) the check is not made.
        verdict, _ = self.judge(self.samples(1 / 3, 0.5))
        self.assertNotIn('notification updates shed', verdict)

    def test_a_missing_device_log_fails_the_check(self):
        with tempfile.TemporaryDirectory() as d:
            samples = os.path.join(d, 'samples.jsonl')
            with open(samples, 'w') as f:
                for s in self.samples(1 / 3, 0.5):
                    f.write(json.dumps(s) + '\n')
            report = os.path.join(d, 'soak.json')
            with open(report, 'w') as f:
                json.dump({'ok': True}, f)
            args = type('A', (), {'platform': 'android', 'report': report, 'samples': samples, 'out': d, 'crash_log': None,
                                  'device_log': os.path.join(d, 'app.log')})
            self.assertEqual(acc.cmd_soak(args), 1)
            with open(os.path.join(d, 'app.log'), 'w') as f:
                f.write('11-28 00:40:01.100  1650  1650 I Bridgey : CLIP sent\n')
            self.assertEqual(acc.cmd_soak(args), 0)

    def test_graphs_are_written(self):
        with tempfile.TemporaryDirectory() as d:
            samples = os.path.join(d, 'samples.jsonl')
            with open(samples, 'w') as f:
                for s in self.samples(2, 0.5):
                    f.write(json.dumps(s) + '\n')
            report = os.path.join(d, 'soak.json')
            with open(report, 'w') as f:
                json.dump({'ok': True}, f)
            args = type('A', (), {'platform': 'android', 'report': report, 'samples': samples, 'out': d, 'crash_log': None})
            self.assertEqual(acc.cmd_soak(args), 0)
            self.assertTrue(os.path.exists(os.path.join(d, 'rss.svg')))
            with open(os.path.join(d, 'soak-summary.json')) as f:
                self.assertTrue(json.load(f)['ok'])


if __name__ == '__main__':
    unittest.main()
