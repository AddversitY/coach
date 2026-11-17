import hashlib
import json
import unittest
from datetime import datetime, timezone
from verify_release import ASSETS, BASE, SERVICE, verify_release


class ReleaseVerificationTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 11, 17, 20, tzinfo=timezone.utc)
        self.commit = 'a' * 40
        self.files = {BASE + 'assets/assets/' + name: b'public evidence' for name in ASSETS}
        self.documents = {
            BASE + 'version.json': {'commit': self.commit, 'evidenceHashes': {name: hashlib.sha256(b'public evidence').hexdigest() for name in ASSETS}},
            BASE + 'data/snapshot.json': {'schemaVersion': 1, 'schedule': {'fetchedAt': '2026-11-17T19:00:00Z'}, 'board': {'events': [{'id': 'game', 'startsAt': '2026-11-22T18:00:00Z'}]}, 'odds': {'status': 'unavailable'}},
            BASE + 'data/coach-index.json': {'schemaVersion': 1, 'cutoff': '2026-11-16', 'events': [{'id': 'game', 'startsAt': '2026-11-22T18:00:00Z'}]},
            SERVICE + 'health': {'service': 'Coach', 'scheduled': {'state': 'complete', 'attemptedAt': '2026-11-17T19:59:00Z'}},
        }
        self.calls = []

    def fetch(self, url, limit):
        self.calls.append(url)
        path = url.split('?')[0]
        raw = self.files[path] if path in self.files else json.dumps(self.documents[path]).encode()
        self.assertLessEqual(len(raw), limit)
        return raw

    def verify(self):
        return verify_release(self.commit, fetch=self.fetch, now=self.now)

    def test_waiting_prices_are_valid_and_checks_never_call_ai_or_pricing(self):
        result = self.verify()
        self.assertEqual(result['verifiedAssets'], 4)
        self.assertEqual(result['prices'], 'unavailable')
        self.assertTrue(all(url.startswith(BASE) or url == SERVICE + 'health' for url in self.calls))

    def test_mixed_release_corrupt_asset_and_changed_kickoff_are_rejected(self):
        for kind in ('version', 'asset', 'kickoff'):
            with self.subTest(kind=kind):
                self.setUp()
                if kind == 'version': self.documents[BASE + 'version.json']['commit'] = 'b' * 40
                elif kind == 'asset': self.files[BASE + 'assets/assets/' + ASSETS[0]] = b'wrong evidence'
                else: self.documents[BASE + 'data/coach-index.json']['events'][0]['startsAt'] = '2026-11-22T21:00:00Z'
                with self.assertRaises(ValueError): self.verify()

    def test_stale_or_failed_schedule_service_cannot_pass_a_release(self):
        for change in ({'state': 'failed'}, {'attemptedAt': '2026-11-17T19:00:00Z'}):
            self.setUp()
            self.documents[SERVICE + 'health']['scheduled'].update(change)
            with self.assertRaises(ValueError): self.verify()
