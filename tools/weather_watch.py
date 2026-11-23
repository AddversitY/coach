"""Hourly wind forecast for open-air games, with the under price when it is windy.

docs/WEATHER.md: in open-air games with 15+ mph wind, totals fell about
1 to 4 points from open to close, and the under at the opener had positive
closing line value in both 2007-2014 and 2015-2021 (not yet clearly above
zero). This watch collects the live evidence:

- For each upcoming open-air game (roof and stadium location from the
  published coach-index.json), the free Open-Meteo hourly forecast for the
  three hours from kickoff: wind, gusts, rain and temperature.
- When forecast wind is 15+ mph, an alert with the earliest and newest saved
  total and the best under price now. The first sighting is kept and scored
  later against Pinnacle's close with tools/line_shop.py.

Output: assets/weather-watch.json. Research, not a pick.
"""

import json
import statistics
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

import line_shop

SCHEMA = 'coach-weather-watch-v1'
FORECAST = 'https://api.open-meteo.com/v1/forecast'
WINDY_MPH = 15
OPEN_ROOFS = {'outdoors', 'open'}
HORIZON_DAYS = 7


def forecast(lat, lon, fetch=None):
    query = urllib.parse.urlencode({
        'latitude': lat, 'longitude': lon, 'hourly': 'wind_speed_10m,wind_gusts_10m,precipitation,temperature_2m',
        'wind_speed_unit': 'mph', 'temperature_unit': 'fahrenheit', 'timezone': 'UTC', 'forecast_days': 8,
    })
    fetch = fetch or (lambda url: urllib.request.urlopen(url, timeout=30).read())
    return json.loads(fetch(f'{FORECAST}?{query}'))


def game_window(payload, kickoff):
    """Average wind, max gust, total rain and average temperature over the three hours from kickoff."""
    hourly = (payload or {}).get('hourly') or {}
    times = hourly.get('time') or []
    picked = []
    for i, t in enumerate(times):
        at = datetime.fromisoformat(t).replace(tzinfo=timezone.utc)
        if kickoff - timedelta(minutes=30) <= at < kickoff + timedelta(hours=3):
            picked.append(i)
    if not picked:
        return None
    take = lambda key: [hourly[key][i] for i in picked if hourly.get(key) and hourly[key][i] is not None]
    wind, gust, rain, temp = take('wind_speed_10m'), take('wind_gusts_10m'), take('precipitation'), take('temperature_2m')
    return {
        'windMph': round(statistics.mean(wind), 1) if wind else None,
        'gustMph': round(max(gust), 1) if gust else None,
        'rainMm': round(sum(rain), 1) if rain else None,
        'tempF': round(statistics.mean(temp), 1) if temp else None,
    }


def _totals(history, away, home, kickoff):
    rows = [r for r in history.get('observations') or [] if r.get('market') == 'totals' and r.get('away') == away
            and r.get('home') == home and str(r.get('kickoff') or '')[:16] == kickoff[:16] and r.get('decimal')]
    if not rows:
        return None, None, None
    times = sorted({r['at'] for r in rows})
    median = lambda at: statistics.median(r['line'] for r in rows if r['at'] == at and r['outcome'] == 'Under')
    unders = [r for r in rows if r['at'] == times[-1] and r['outcome'] == 'Under' and r['book'] != line_shop.SHARP_BOOK]
    best = max(unders, key=lambda r: (r['line'], r['decimal'])) if unders else None
    return median(times[0]), median(times[-1]), best


HISTORY_CODES = {'LA': 'LAR'}


def build(index, history, now, fetch=None):
    rows = []
    for event in index.get('events') or []:
        kickoff = line_shop._parse(event.get('startsAt'))
        if not kickoff or kickoff <= now or kickoff - now > timedelta(days=HORIZON_DAYS):
            continue
        if str(event.get('roof') or '').lower() not in OPEN_ROOFS:
            continue
        if event.get('latitude') is None or event.get('longitude') is None:
            continue
        window = game_window(forecast(event['latitude'], event['longitude'], fetch), kickoff)
        if not window:
            continue
        away = HISTORY_CODES.get(event.get('awayCode'), event.get('awayCode'))
        home = HISTORY_CODES.get(event.get('homeCode'), event.get('homeCode'))
        first, latest, best = _totals(history, away, home, event['startsAt'])
        row = {'away': away, 'home': home, 'kickoff': event['startsAt'], 'checkedAt': now.isoformat().replace('+00:00', 'Z'),
               **window, 'firstTotal': first, 'totalNow': latest, 'windy': (window['windMph'] or 0) >= WINDY_MPH}
        if row['windy'] and best:
            row['bet'] = {'market': 'totals', 'side': 'under', 'outcome': 'Under', 'line': best['line'],
                          'book': best['book'], 'decimal': best['decimal'], 'priceAt': best['at']}
        rows.append(row)
    return rows


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description='Hourly wind for open-air games.')
    parser.add_argument('--index', required=True)
    parser.add_argument('--history', default='assets/price-history.json')
    parser.add_argument('--output', default='assets/weather-watch.json')
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)
    path = Path(args.output)
    log = json.loads(path.read_text()) if path.exists() else {'schema': SCHEMA, 'alerts': []}
    history = json.loads(Path(args.history).read_text())
    try:
        current = build(json.loads(Path(args.index).read_text()), history, now)
        log['source'] = {'status': 'ok', 'checkedAt': now.isoformat().replace('+00:00', 'Z'), 'provider': 'Open-Meteo'}
    except Exception as error:  # noqa: BLE001 - an unavailable forecast is recorded, not invented
        current = []
        log['source'] = {'status': 'unavailable', 'detail': type(error).__name__}
    seen = {(a['away'], a['home'], a['kickoff']) for a in log['alerts']}
    for row in current:
        if row.get('bet') and (row['away'], row['home'], row['kickoff']) not in seen:
            log['alerts'].append(row)
            seen.add((row['away'], row['home'], row['kickoff']))
    del log['alerts'][:-2000]
    observations = [r for r in history.get('observations') or [] if r.get('decimal')]
    closes, _ = line_shop._closing_fair(observations)
    values = []
    for alert in log['alerts']:
        kickoff = line_shop._parse(alert['kickoff'])
        if kickoff and kickoff <= now:
            flag = {**alert['bet'], 'away': alert['away'], 'home': alert['home'], 'kickoff': alert['kickoff'], 'player': ''}
            alert['clv'] = line_shop.clv_of(flag, closes)
            values.append(alert['clv'])
    summary = line_shop.summarize(values)
    passes, reason = line_shop.gate(summary)
    log.update({'schema': SCHEMA, 'current': current, 'summary': {'clv': summary, 'passes': passes, 'reason': reason},
                'notice': 'Forecast wind at kickoff for open-air games, and the under price when windy. Research, not a pick.'})
    path.write_text(json.dumps(log, indent=1) + '\n')
    print(json.dumps({'games': len(current), 'windy': sum(1 for r in current if r['windy'])}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
