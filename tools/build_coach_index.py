"""Publish a compact, dated Coach retrieval index. No odds-provider calls."""
import argparse, ast, csv, hashlib, io, json, urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from publish_snapshot import SOURCE, TEAMS, ALIASES, build_snapshot, iso
from build_game_context import build_context

def build_index(schedule, dataset, rows, now, stadiums, forecast_model=None, game_history=None, forecast_lab=None, matchup=None):
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
        events.append(dict(event,homeCode=ALIASES.get(row['home_team'],row['home_team']),awayCode=ALIASES.get(row['away_team'],row['away_team']),venue=venue,roof=row.get('roof','unknown'),
            latitude=point[0] if point else None,longitude=point[1] if point else None,neutral=row.get('location')=='Neutral',
            listedQuarterbacks={side:row.get(side+'_qb_name','').strip() or None for side in ['home','away']},
            restDays={side:int(row[side+'_rest']) if str(row.get(side+'_rest','')).isdigit() and 0<int(row[side+'_rest'])<=30 else None for side in ['home','away']},
            scheduleEvidence={'sourceUrl':SOURCE,'retrievedAt':iso(now),'notice':'Schedule quarterback names are unconfirmed listings, not a depth chart or starter announcement.'}))
    permitted=[];role_records=[]
    for row in dataset['rows']:
        day=datetime.fromisoformat(row['date']).date()
        if day<=cutoff and day<now.date() and row['season']==metadata['currentSeason'] and row['seasonType']=='REG':
            role_records.append(row)
            if row['position'] in ['QB','RB','WR','TE']:permitted.append(row)
    context=build_context(events,dataset,role_records,matchup,now)
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
    model=None
    if forecast_model:
        model_cutoff=datetime.fromisoformat(forecast_model['cutoff']).date()
        trained=datetime.fromisoformat(forecast_model['trainedAt'].replace('Z','+00:00'))
        if forecast_model.get('schemaVersion')!=1 or trained.tzinfo is None or trained>now or model_cutoff>now.date() or (now.date()-model_cutoff).days>21 or len(forecast_model['coefficients'])!=66 or not 120<=len(forecast_model['residuals'])<=1000:
            raise ValueError('Forecast model provenance is invalid or stale')
        model=forecast_model
        codes={value:key for key,value in TEAMS.items()}
        for event in events:
            h,a=[model['teams'].index(codes[event[key]]) for key in ['home','away']]
            c=model['coefficients'];event['forecast']={'homeMean':max(0,min(65,c[0]+(0 if event['neutral'] else c[1])+c[2+h]+c[34+a])),
                'awayMean':max(0,min(65,c[0]+c[2+a]+c[34+h])),'modelVersion':model['version'],'cutoff':model['cutoff']}
    results=[]
    if game_history:
        history_cutoff=datetime.fromisoformat(game_history['cutoff']).date()
        fetched=datetime.fromisoformat(game_history['retrievedAt'].replace('Z','+00:00'))
        if fetched.tzinfo is None or fetched>now or history_cutoff>now.date():raise ValueError('Invalid result provenance')
        current_games=[g for g in game_history['games'] if g['season']==metadata['currentSeason'] and now.date()-timedelta(days=50)<=datetime.fromisoformat(g['date']).date()<=min(history_cutoff,now.date()-timedelta(days=1))]
        for game in current_games:
            stats={}
            for record in permitted:
                if record['season']==game['season'] and record['week']==game['week'] and record['date']==game['date'] and ALIASES.get(record['team'],record['team']) in [ALIASES.get(game['home'],game['home']),ALIASES.get(game['away'],game['away'])]:
                    values=record['stats'];values=dict(zip(dataset['statKeys'],values)) if isinstance(values,list) else values
                    stats[record['playerId']]={key:values[key] for key in ['passing_yards','rushing_yards','receiving_yards','receptions'] if key in values}
            results.append({'eventId':'nflverse:'+game['id'],'homeScore':game['homeScore'],'awayScore':game['awayScore'],'date':game['date'],'home':TEAMS[ALIASES.get(game['home'],game['home'])],'away':TEAMS[ALIASES.get(game['away'],game['away'])],'playerStats':stats})
    lab=None;shadow=None
    if forecast_lab:
        shadow=forecast_lab['challengerModel']
        generated=datetime.fromisoformat(forecast_lab['generatedAt'].replace('Z','+00:00'))
        trained=datetime.fromisoformat(shadow['trainedAt'].replace('Z','+00:00'))
        if (forecast_lab.get('schemaVersion')!=1 or generated.tzinfo is None or generated>now or trained.tzinfo is None or trained>now
            or not game_history or not isinstance(forecast_lab.get('sourceHash'),str) or len(forecast_lab['sourceHash'])!=64 or any(c not in '0123456789abcdef' for c in forecast_lab['sourceHash'])
            or forecast_lab['cutoff']>game_history['cutoff'] or shadow['cutoff']!=forecast_lab['cutoff']
            or (now.date()-datetime.fromisoformat(shadow['cutoff']).date()).days>21
            or len(shadow.get('teams',[]))!=32 or set(shadow['teams'])!=set(TEAMS) or len(shadow['coefficients'])!=66 or not 120<=len(shadow['residuals'])<=1000
            or forecast_lab['decision'].get('adopted') is not False or forecast_lab['decision'].get('hasEdge') is not False):
            raise ValueError('Invalid shadow research provenance')
        lab={k:v for k,v in forecast_lab.items() if k!='challengerModel'}
        lab['matchesLatestHistory']=forecast_lab['sourceHash']==hashlib.sha256(json.dumps(game_history,sort_keys=True).encode()).hexdigest()
    return {'roleContext':context,'contextPlayers':context['contextPlayers'],'forecastLab':lab,'shadowScoreModel':shadow,'clubs':TEAMS,'scoreModel':model,'results':results,'schemaVersion':1,'builtAt':iso(now),'cutoff':str(cutoff),
        'retrievedAt':iso(retrieved),'evidenceHash':hashlib.sha256(json.dumps(dataset,sort_keys=True).encode()).hexdigest(),
        'events':events,'players':players,'notice':'Recorded participants, not confirmed rosters. Marginal probabilities are not validated live forecasts.'}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--schedule',type=Path,required=True)
    parser.add_argument('--players',type=Path,default=Path('assets/nfl-player-stats.json'))
    parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    with urllib.request.urlopen(SOURCE,timeout=30) as r:rows=list(csv.DictReader(io.StringIO(r.read().decode('utf-8-sig'))))
    tree=ast.parse(Path('model/weather.py').read_text(encoding='utf-8'))
    stadiums=next(ast.literal_eval(node.value) for node in tree.body if isinstance(node,ast.AnnAssign) and getattr(node.target,'id',None)=='STADIUMS')
    result=build_index(json.loads(args.schedule.read_text(encoding='utf-8')),json.loads(args.players.read_text(encoding='utf-8-sig')),rows,datetime.now(timezone.utc),stadiums,json.loads(Path('assets/game-forecast-model.json').read_text(encoding='utf-8')),json.loads(Path('assets/nfl-history.json').read_text(encoding='utf-8-sig')),json.loads(Path('assets/forecast-lab.json').read_text(encoding='utf-8-sig')),json.loads(Path('assets/nfl-matchup.json').read_text(encoding='utf-8-sig')))
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,allow_nan=False,separators=(',',':')),encoding='utf-8')
    print(f'Coach index: {len(result["players"])} recorded players; zero odds credits.')
if __name__=='__main__':main()
