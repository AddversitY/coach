"""Dated, descriptive NFL role context. No inferred starters or point penalties."""
from datetime import datetime
import math
import re

from publish_snapshot import TEAMS, ALIASES, SOURCE

LINE = {'C', 'G', 'T', 'OT', 'OG', 'OL', 'LT', 'RT', 'LG', 'RG'}
OFFENSE = LINE | {'QB', 'RB', 'WR', 'TE', 'FB'}


def name_key(value):
    return re.sub(r'[^a-z0-9 ]', '', value.lower()).strip()


def build_context(events, dataset, records, matchup, now):
    """Build exact team/date denominators and preserve independent snap dates."""
    metadata = dataset.get('metadata', dataset)
    season = metadata['currentSeason']
    keys = dataset.get('statKeys', [])
    games, seen = {}, set()
    for raw in records:
        code = ALIASES.get(raw['team'], raw['team'])
        identity = (raw['playerId'], code, raw['date'], raw['week'])
        if identity in seen:
            raise ValueError('Duplicate player/team/game observations')
        seen.add(identity)
        if isinstance(raw['stats'], list) and len(raw['stats']) != len(keys):
            raise ValueError('Invalid packed workload stats')
        stats = dict(zip(keys, raw['stats'])) if isinstance(raw['stats'], list) else raw['stats']
        key = (code, raw['date'], raw['week'])
        row = games.setdefault(key, dict(team=code, date=raw['date'], week=raw['week'],
                                        opponent=ALIASES.get(raw.get('opponent'),raw.get('opponent')),
                                        attempts=0, carries=0, targets=0, passYards=0,
                                        rushYards=0, receivingYards=0, receptions=0, passers=[]))
        for stat, destination in [('attempts', 'attempts'), ('carries', 'carries'), ('targets', 'targets'),
                                  ('passing_yards', 'passYards'), ('rushing_yards', 'rushYards'), ('receiving_yards','receivingYards'), ('receptions','receptions')]:
            value = stats.get(stat, 0)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or (stat in ['attempts','carries','targets','receptions'] and value < 0):
                raise ValueError('Invalid recorded workload')
            row[destination] += value
        if raw['position'] == 'QB' and stats.get('attempts', 0) > 0:
            row['passers'].append(dict(id=raw['playerId'], name=raw['name'], attempts=stats['attempts']))
    team_games = sorted(games.values(), key=lambda g: (g['date'], g['team']), reverse=True)
    for g in team_games:
        other=games.get((g['opponent'],g['date'],g['week']))
        for metric in ['attempts','carries','targets']:
            g['allowed_'+metric]=other[metric] if other else None
        for stat,key in [('passing_yards','passYards'),('rushing_yards','rushYards'),('receiving_yards','receivingYards'),('receptions','receptions')]:
            g['allowed_'+stat]=other[key] if other else None
        g['passingYardsAllowed']=other['passYards'] if other else None
        g['rushingYardsAllowed']=other['rushYards'] if other else None
        g['passers'].sort(key=lambda p: (-p['attempts'], p['id']))

    snaps, snap_source = [], None
    if matchup:
        provenance = matchup.get('provenance', {}).get('snaps', {})
        cutoff, fetched = provenance.get('cutoff'), provenance.get('retrievedAt')
        # Undated historical injury files are deliberately not published here.
        if cutoff and fetched and matchup.get('season') == season:
            day = datetime.fromisoformat(cutoff).date()
            at = datetime.fromisoformat(fetched.replace('Z', '+00:00'))
            if at.tzinfo is None or at > now or day > now.date():
                raise ValueError('Invalid snap evidence provenance')
            if (now.date()-day).days <= 21:
                snap_source = dict(source='nflverse / PFR snap counts', sourceUrl=matchup['snapSource'],
                                   cutoff=cutoff, retrievedAt=fetched, season=season)
                by_week = {(g['team'], g['week']): g['date'] for g in team_games}
                unique = {}
                for raw in matchup.get('snaps', []):
                    code = ALIASES.get(raw['team'], raw['team'])
                    date = by_week.get((code, raw['week']))
                    if not date or date > cutoff or raw['week'] > provenance.get('throughWeek', 0) or raw['position'] not in OFFENSE:
                        continue
                    share = raw['offensePct']
                    if isinstance(share, bool) or not isinstance(share, (int, float)) or not math.isfinite(share) or not 0 <= share <= 1:
                        raise ValueError('Invalid snap share')
                    key = (code, raw['week'], name_key(raw['player']))
                    row = dict(team=code, week=raw['week'], date=date, name=raw['player'],
                               position=raw['position'], offenseShare=share)
                    if key in unique and unique[key] != row:
                        raise ValueError('Ambiguous snap identity')
                    unique[key] = row
                snaps = list(unique.values())
    # Keep six exact observed team games and matching snaps, not a roster claim.
    recent = [g for code in TEAMS for g in [x for x in team_games if x['team'] == code][:6]]
    recent_keys = {(g['team'], g['week']) for g in recent}
    snaps = [s for s in snaps if (s['team'], s['week']) in recent_keys]
    context_players = {}
    for s in snaps:
        if s['position'] not in LINE | {'QB'}:
            continue
        event_ids = [e['id'] for e in events if s['team'] in [e['homeCode'], e['awayCode']]]
        key = (s['team'], name_key(s['name']))
        if event_ids:
            context_players[key] = dict(id='context:'+':'.join(key), name=s['name'], team=s['team'],
                                        position=s['position'], events=event_ids, identitySource='recorded_snaps')
    for e in events:
        for side in ['home', 'away']:
            code, listed = e[side+'Code'], e.get('listedQuarterbacks', {}).get(side)
            if listed:
                key = (code, name_key(listed))
                context_players.setdefault(key, dict(id='context:'+':'.join(key), name=listed, team=code,
                                                    position='QB', events=[x['id'] for x in events if code in [x['homeCode'], x['awayCode']]],
                                                    identitySource='schedule_listing_unconfirmed'))
    return dict(schemaVersion=1, cutoff=metadata['cutoff'], retrievedAt=metadata['retrievedAt'],
                source='nflverse player box scores', sourceUrl=metadata.get('sourceUrl', SOURCE),
                teamGames=recent, snaps=snaps, snapSource=snap_source,
                contextPlayers=list(context_players.values()),
                notice='Observed appearances and snap shares, not confirmed rosters, expected snaps, routes or future participation.')
