#!/usr/bin/env python3
"""Build assets/play-units.json from a local nflverse play-by-play cache.

The cache is the free CC BY 4.0 release. This script does not log in, does
not use a proxy, and does not read an API key. A missing cache leaves the
committed file alone.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = 'coach-play-units-v1'


def build(cache: Path) -> dict:
    rows: dict[tuple, dict] = {}

    def row_for(game_id: str, team: str, season, week, season_type, opponent: str) -> dict:
        key = (game_id, team)
        found = rows.get(key)
        if found is None:
            found = {
                'id': game_id,
                'season': int(season),
                'week': int(week),
                'seasonType': str(season_type),
                'team': team,
                'opponent': opponent,
                'plays': 0,
                'epaSum': 0.0,
                'successes': 0,
                'dropbacks': 0,
                'sacks': 0,
                'hits': 0,
                'thirdConverted': 0,
                'thirdFailed': 0,
                'passOeSum': 0.0,
                'passOePlays': 0,
            }
            rows[key] = found
        return found

    for year in (2024, 2025, 2026):
        path = cache / f'play_by_play_{year}.parquet'
        frame = pd.read_parquet(
            path,
            columns=[
                'game_id',
                'season',
                'week',
                'season_type',
                'posteam',
                'defteam',
                'play_type',
                'epa',
                'success',
                'third_down_converted',
                'third_down_failed',
                'sack',
                'qb_hit',
                'qb_dropback',
                'pass_oe',
            ],
        )
        frame = frame[frame.posteam.notna() & frame.defteam.notna() & frame.season.notna() & frame.week.notna()]
        scrimmage = frame[frame.play_type.isin(['pass', 'run']) & frame.epa.notna()]
        grouped = scrimmage.groupby(['game_id', 'posteam'], as_index=False).agg(
            season=('season', 'first'),
            week=('week', 'first'),
            season_type=('season_type', 'first'),
            opponent=('defteam', 'first'),
            plays=('epa', 'size'),
            epaSum=('epa', 'sum'),
            successes=('success', lambda s: float(s.fillna(0).sum())),
        )
        for item in grouped.itertuples(index=False):
            target = row_for(item.game_id, item.posteam, item.season, item.week, item.season_type, item.opponent)
            target['plays'] = int(item.plays)
            target['epaSum'] = round(float(item.epaSum), 4)
            target['successes'] = int(item.successes)
        drops = frame[(frame.qb_dropback == 1) & frame.play_type.isin(['pass', 'run'])]
        rush = drops.groupby(['game_id', 'posteam'], as_index=False).agg(
            season=('season', 'first'),
            week=('week', 'first'),
            season_type=('season_type', 'first'),
            opponent=('defteam', 'first'),
            dropbacks=('qb_dropback', 'size'),
            sacks=('sack', lambda s: float(s.fillna(0).sum())),
            hits=('qb_hit', lambda s: float(s.fillna(0).sum())),
        )
        for item in rush.itertuples(index=False):
            target = row_for(item.game_id, item.posteam, item.season, item.week, item.season_type, item.opponent)
            target['dropbacks'] = int(item.dropbacks)
            target['sacks'] = int(round(item.sacks))
            target['hits'] = int(round(item.hits))
        thirds = frame[
            ((frame.third_down_converted == 1) | (frame.third_down_failed == 1))
            & (frame.play_type != 'no_play')
        ]
        third = thirds.groupby(['game_id', 'posteam'], as_index=False).agg(
            season=('season', 'first'),
            week=('week', 'first'),
            season_type=('season_type', 'first'),
            opponent=('defteam', 'first'),
            thirdConverted=('third_down_converted', lambda s: int((s == 1).sum())),
            thirdFailed=('third_down_failed', lambda s: int((s == 1).sum())),
        )
        for item in third.itertuples(index=False):
            target = row_for(item.game_id, item.posteam, item.season, item.week, item.season_type, item.opponent)
            target['thirdConverted'] = int(item.thirdConverted)
            target['thirdFailed'] = int(item.thirdFailed)
        expected = frame[frame.pass_oe.notna() & frame.posteam.notna()]
        proe = expected.groupby(['game_id', 'posteam'], as_index=False).agg(
            season=('season', 'first'),
            week=('week', 'first'),
            season_type=('season_type', 'first'),
            opponent=('defteam', 'first'),
            passOeSum=('pass_oe', 'sum'),
            passOePlays=('pass_oe', 'size'),
        )
        for item in proe.itertuples(index=False):
            target = row_for(item.game_id, item.posteam, item.season, item.week, item.season_type, item.opponent)
            target['passOeSum'] = round(float(item.passOeSum), 4)
            target['passOePlays'] = int(item.passOePlays)
    games = sorted(rows.values(), key=lambda item: (item['season'], item['week'], item['id'], item['team']))
    return {
        'schema': SCHEMA,
        'license': 'CC BY 4.0',
        'licenseUrl': 'https://creativecommons.org/licenses/by/4.0/',
        'source': (
            'nflverse play-by-play. EPA and success use pass and run plays with a recorded EPA. '
            'Third downs are third_down_converted divided by converted plus failed, and a no_play is excluded. '
            'Pressure is sacks plus quarterback hits divided by dropbacks. '
            'Pass rate over expected is the mean of pass_oe. A rating uses earlier weeks only.'
        ),
        'games': games,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--cache', type=Path, default=Path('/tmp/nflverse'))
    parser.add_argument('--output', type=Path, default=ROOT / 'assets' / 'play-units.json')
    args = parser.parse_args()
    if not (args.cache / 'play_by_play_2026.parquet').exists():
        raise SystemExit(f'Missing play-by-play cache in {args.cache}')
    payload = build(args.cache)
    check = [
        row
        for row in payload['games']
        if row['id'] == '2026_11_IND_HOU'
    ]
    for row in check:
        attempts = row['thirdConverted'] + row['thirdFailed']
        print(
            f"{row['team']} third {row['thirdConverted']} of {attempts} "
            f"epaPlays {row['plays']} dropbacks {row['dropbacks']}"
        )
    args.output.write_text(json.dumps(payload, separators=(',', ':')) + '\n', encoding='utf-8')
    print(json.dumps({'games': len(payload['games']), 'output': str(args.output)}))


if __name__ == '__main__':
    main()
