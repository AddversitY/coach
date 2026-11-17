"""Read back a deployed Coach release. No odds requests, AI calls or secrets."""
import argparse
import hashlib
import json
import re
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

BASE = 'https://addversity.github.io/coach/'
SERVICE = 'https://coach-research.dds-dge.workers.dev/'
ASSETS = ('nfl-player-stats.json', 'nfl-history.json', 'nfl-matchup.json', 'parlay-calibration.json')


def download(url, limit):
    request = urllib.request.Request(url, headers={'User-Agent': 'Coach release verification', 'Cache-Control': 'no-cache'})
    with urllib.request.urlopen(request, timeout=30) as response:
        raw = response.read(limit + 1)
    if len(raw) > limit:
        raise ValueError('Published source exceeds its size budget.')
    return raw


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError('Missing published timestamp.')
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('Published timestamp has no timezone.')
    return result.astimezone(timezone.utc)


def verify_release(commit, *, fetch=download, now=None):
    if not re.fullmatch(r'[a-f0-9]{40}', commit):
        raise ValueError('Expected a full release commit.')
    now = now or datetime.now(timezone.utc)
    suffix = '?verify=' + commit
    read = lambda path, limit: json.loads(fetch(BASE + path + suffix, limit))
    version = read('version.json', 4000)
    if version.get('commit') != commit:
        raise ValueError('The public app is serving a different release.')
    hashes = version.get('evidenceHashes', {})
    if set(hashes) != set(ASSETS):
        raise ValueError('The release has incomplete evidence fingerprints.')
    for name in ASSETS:
        raw = fetch(BASE + 'assets/assets/' + name + suffix, 20_000_000)
        if hashlib.sha256(raw).hexdigest() != hashes[name]:
            raise ValueError('The public evidence does not match the release: ' + name)
    snapshot = read('data/snapshot.json', 1_000_000)
    index = read('data/coach-index.json', 3_000_000)
    if snapshot.get('schemaVersion') not in (1, 2) or index.get('schemaVersion') != 1:
        raise ValueError('Published research schema is unavailable.')
    schedule_at = timestamp(snapshot.get('schedule', {}).get('fetchedAt'))
    if not -timedelta(minutes=5) <= now - schedule_at <= timedelta(hours=24):
        raise ValueError('The published schedule is stale or future-dated.')
    events = snapshot.get('board', {}).get('events')
    if not isinstance(events, list) or len(events) > 64 or not isinstance(index.get('events'), list):
        raise ValueError('The public schedule is invalid.')
    signature = lambda rows: sorted((e['id'], e['startsAt']) for e in rows)
    if signature(events) != signature(index['events']):
        raise ValueError('The app and service disagree on game identities or kickoff times.')
    cutoff = timestamp(index.get('cutoff', '') + 'T00:00:00Z')
    if not timedelta(0) <= now - cutoff <= timedelta(days=22):
        raise ValueError('The published player research is stale or future-dated.')
    if snapshot.get('odds', {}).get('status') not in ('limited', 'unavailable', 'not_configured'):
        raise ValueError('The public price state is invalid.')
    health = json.loads(fetch(SERVICE + 'health', 10000))
    scheduled = health.get('scheduled') or {}
    if health.get('service') != 'Coach' or scheduled.get('state') not in ('running', 'complete'):
        raise ValueError('The scheduled Coach service is not healthy.')
    if not -timedelta(seconds=5) <= now - timestamp(scheduled.get('attemptedAt')) <= timedelta(minutes=10):
        raise ValueError('The scheduled Coach service has stopped refreshing.')
    return dict(commit=commit, games=len(events), playerCutoff=index['cutoff'],
                prices=snapshot['odds']['status'], scheduled=scheduled['state'], verifiedAssets=len(ASSETS))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-commit', required=True)
    args = parser.parse_args()
    # Pages caches can briefly expose a mixed release. Bounded retries read only
    # public files; they never trigger pricing, inference or forecast capture.
    for attempt in range(3):
        try:
            print(json.dumps(verify_release(args.expected_commit)))
            return
        except (ValueError, KeyError, TypeError, OSError, urllib.error.URLError) as error:
            if attempt == 2:
                raise SystemExit('Public release verification failed: ' + str(error))
            print('Waiting for a consistent public release before verifying again.')
            time.sleep(10)


if __name__ == '__main__':
    main()
