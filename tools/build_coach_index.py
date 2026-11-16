"""Publish a compact, dated Coach retrieval index. No odds-provider calls."""
import argparse, ast, csv, hashlib, io, json, urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from publish_snapshot import SOURCE, TEAMS, ALIASES, build_snapshot, iso

def build_index(schedule, dataset, rows, now, stadiums):
    metadata=dataset.get('metadata',dataset)
    cutoff=datetime.fromisoformat(metadata['cutoff']).date()
    retrieved=datetime.fromisoformat(metadata['retrievedAt'].replace('Z','+00:00'))
    if retrieved.tzinfo is None or retrieved>now or cutoff>now.date() or (now.date()-cutoff).days>21:
        raise ValueError('Player evidence is unverifiable or too old for Coach indexing')
    expected={e['id']:e for e in schedule['board']['events']}
    normalized={e['id']:e for e in build_snapshot(rows,now)['board']['events']}
    if any(normalized.get(key)!=event for key,event in expected.items()):
        raise ValueError('Venue schedule differs from the deployed schedule')
    by_schedule={'nflverse:'+r['game_id']:r for r in rows}
    events=[]
    for event in expected.values():
        row=by_schedule[event['id']]
        venue=row.get('stadium','').strip();point=stadiums.get(venue)
        events.append(dict(event,venue=venue,roof=row.get('roof','unknown'),
            latitude=point[0] if point else None,longitude=point[1] if point else None))
    permitted=[]
    for row in dataset['rows']:
        day=datetime.fromisoformat(row['date']).date()
        if day<=cutoff and day<now.date() and row['season']==metadata['currentSeason'] and row['seasonType']=='REG' and row['position'] in ['QB','RB','WR','TE']:
            permitted.append(row)
    grouped={}
    for row in permitted:grouped.setdefault(row['playerId'],[]).append(row)
    players=[]
    for player_id,history in grouped.items():
        history.sort(key=lambda r:r['date'],reverse=True);latest=history[0]
        if (now.date()-datetime.fromisoformat(latest['date']).date()).days>35:continue
        team=TEAMS.get(ALIASES.get(latest['team'],latest['team']))
        event_ids=[e['id'] for e in events if team in [e['away'],e['home']]]
        if not event_ids:continue
        # Do not silently combine a trade segment or ambiguous latest clubs.
        if len({r['team'] for r in history if r['date']==latest['date']})!=1:continue
        segment=[]
        for record in history:
            if record['team']!=latest['team']:break
            stats=record['stats']
            if isinstance(stats,list):
                if len(stats)!=len(dataset['statKeys']):raise ValueError('Invalid packed stats')
                record=dict(record,stats=dict(zip(dataset['statKeys'],stats)))
            segment.append(record)
        keys={'passing_yards','rushing_yards','receiving_yards','receptions','attempts','carries','targets'}
        compact=[{'date':g['date'],'week':g['week'],'stats':{k:v for k,v in g['stats'].items() if k in keys}} for g in segment[:10]]
        players.append({'id':player_id,'name':latest['name'],'team':latest['team'],
            'position':latest['position'],'events':event_ids,'games':compact})
    return {'schemaVersion':1,'builtAt':iso(now),'cutoff':str(cutoff),
        'retrievedAt':iso(retrieved),'evidenceHash':hashlib.sha256(json.dumps(dataset,sort_keys=True).encode()).hexdigest(),
        'events':events,'players':players,'notice':'Recorded participants, not confirmed rosters. Marginal probabilities are not validated live forecasts.'}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--schedule',type=Path,required=True)
    parser.add_argument('--players',type=Path,default=Path('assets/nfl-player-stats.json'))
    parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    with urllib.request.urlopen(SOURCE,timeout=30) as r:rows=list(csv.DictReader(io.StringIO(r.read().decode('utf-8-sig'))))
    tree=ast.parse(Path('model/weather.py').read_text(encoding='utf-8'))
    stadiums=next(ast.literal_eval(node.value) for node in tree.body if isinstance(node,ast.AnnAssign) and getattr(node.target,'id',None)=='STADIUMS')
    result=build_index(json.loads(args.schedule.read_text(encoding='utf-8')),json.loads(args.players.read_text(encoding='utf-8-sig')),rows,datetime.now(timezone.utc),stadiums)
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,allow_nan=False,separators=(',',':')),encoding='utf-8')
    print(f'Coach index: {len(result["players"])} recorded players; zero odds credits.')
if __name__=='__main__':main()
