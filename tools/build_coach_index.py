"""Publish a compact, dated Coach retrieval index. No odds-provider calls."""
import argparse, ast, csv, hashlib, io, json, math, urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from publish_snapshot import SOURCE, TEAMS, ALIASES, build_snapshot, iso
from build_game_context import build_context

def build_index(schedule, dataset, rows, now, stadiums, forecast_model=None, game_history=None, forecast_lab=None, matchup=None, workload_model=None, production_model=None, regime_research=None, error_audit=None, football_research=None, team_efficiency=None):
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
    trial_history={}
    for record in dataset['rows']:
        day=datetime.fromisoformat(record['date']).date()
        if record['seasonType']=='REG' and day<=cutoff and day<now.date() and (now.date()-day).days<=730 and record['position'] in ['QB','RB','WR','TE']:
            trial_history.setdefault(record['playerId'],[]).append(record)
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
        compact=[{'date':g['date'],'week':g['week'],'position':g['position'],'stats':{k:v for k,v in g['stats'].items() if k in keys}} for g in segment[:10]]
        prior=[];compact_keys={(g['date'],g['week']) for g in compact}
        for record in sorted(trial_history.get(player_id,[]),key=lambda r:r['date'],reverse=True):
            if ALIASES.get(record['team'],record['team'])!=ALIASES.get(latest['team'],latest['team']) or record['position']!=latest['position']:break
            if (record['date'],record['week']) in compact_keys:continue
            stats=record['stats'];stats=dict(zip(dataset['statKeys'],stats)) if isinstance(stats,list) else stats
            trial_keys=['attempts','carries','targets','passing_yards','rushing_yards','receiving_yards','receptions']
            if not all(key in stats for key in trial_keys):raise ValueError('Incomplete prior trial history')
            prior.append([record['date'],record['week'],record['position'],*[stats[key] for key in trial_keys]])
            if len(prior)>=max(0,10-len(compact)):break
        prior=prior[:max(0,10-len(compact))]
        players.append({'priorTrialGames':prior,'id':player_id,'name':latest['name'],'team':latest['team'],
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
            stats={};player_teams={}
            for record in permitted:
                if record['season']==game['season'] and record['week']==game['week'] and record['date']==game['date'] and ALIASES.get(record['team'],record['team']) in [ALIASES.get(game['home'],game['home']),ALIASES.get(game['away'],game['away'])]:
                    values=record['stats'];values=dict(zip(dataset['statKeys'],values)) if isinstance(values,list) else values
                    player_teams[record['playerId']]=ALIASES.get(record['team'],record['team'])
                    stats[record['playerId']]={key:values[key] for key in ['passing_yards','rushing_yards','receiving_yards','receptions','attempts','carries','targets'] if key in values}
            results.append({'eventId':'nflverse:'+game['id'],'homeScore':game['homeScore'],'awayScore':game['awayScore'],'date':game['date'],'home':TEAMS[ALIASES.get(game['home'],game['home'])],'away':TEAMS[ALIASES.get(game['away'],game['away'])],'playerStats':stats,'playerTeams':player_teams})
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
    if workload_model:
        trained=datetime.fromisoformat(workload_model['trainedAt'].replace('Z','+00:00'))
        if (workload_model.get('schemaVersion')!=1 or workload_model.get('version')!='workload-ridge-v1' or workload_model.get('adopted') is not False or workload_model.get('hasEdge') is not False
            or trained.tzinfo is None or trained>now or workload_model['cutoff']>str(cutoff) or (now.date()-datetime.fromisoformat(workload_model['cutoff']).date()).days>21
            or len(workload_model.get('featureNames',[]))!=17 or not 1<=len(workload_model.get('models',{}))<=6
            or any(len(m['coefficients'])!=17 or len(m['residuals'])>1000 or m['trainingRows']<200 for m in workload_model['models'].values())):
            raise ValueError('Invalid workload research model')
    if production_model:
        trained=datetime.fromisoformat(production_model['trainedAt'].replace('Z','+00:00'))
        if (production_model.get('schemaVersion')!=1 or production_model.get('version')!='production-joint-v1' or production_model.get('adopted') is not False or production_model.get('hasEdge') is not False
            or trained.tzinfo is None or trained>now or production_model['cutoff']>str(cutoff) or (now.date()-datetime.fromisoformat(production_model['cutoff']).date()).days>21
            or not workload_model or production_model.get('volumeModelHash')!=hashlib.sha256(json.dumps(workload_model,sort_keys=True).encode()).hexdigest()
            or len(production_model.get('featureNames',[]))!=24 or not 1<=len(production_model.get('models',{}))<=9
            or any(len(m['coefficients'])!=24 or not 120<=len(m['residualPairs'])<=512 or m['trainingRows']<200 for m in production_model['models'].values())):
            raise ValueError('Invalid joint production research model')
    regime=None;regime_summary=None
    history_hash=hashlib.sha256(json.dumps(game_history,sort_keys=True).encode()).hexdigest() if game_history else None
    if regime_research:
        regime=regime_research.get('model',{});trained=datetime.fromisoformat(regime.get('trainedAt','').replace('Z','+00:00'))
        if (regime.get('version')!='score-regime-kernel-v1' or regime.get('schemaVersion')!=1 or trained.tzinfo is None or trained>now
            or not forecast_model or regime.get('cutoff')!=forecast_model['cutoff'] or regime_research.get('sourceHash')!=history_hash or regime.get('sourceHash')!=history_hash
            or len(regime.get('coefficients',[]))!=66 or not all(math.isfinite(v) for v in regime['coefficients'])
            or regime.get('teams')!=forecast_model['teams'] or not 120<=len(regime.get('residuals',[]))<=1000
            or len(regime.get('residualContexts',[]))!=len(regime['residuals'])
            or any(len(row)!=2 or any(not math.isfinite(v) for v in row) for row in regime['residuals']+regime['residualContexts'])
            or regime.get('validation',{}).get('adopted') is not False or regime.get('validation',{}).get('hasEdge') is not False
            or regime.get('specification')!={'totalBandwidth':10.,'marginBandwidth':7.,'uniformMixture':.5,'minimumEffectiveErrors':120,'ridge':40.,'halfLifeDays':180.}):
            raise ValueError('Invalid scoring-regime research provenance')
        regime_summary={k:v for k,v in regime_research.items() if k!='model'}
    if error_audit and (error_audit.get('version')!='game-error-audit-v1' or error_audit.get('sourceHash')!=history_hash or error_audit.get('cutoff')!=game_history['cutoff']):
        raise ValueError('Invalid game-error audit provenance')
    football=None;football_summary=None
    if football_research:
        f=football_research;trained=datetime.fromisoformat(f.get('trainedAt','').replace('Z','+00:00'))
        if (f.get('version')!='score-football-features-v1' or f.get('schemaVersion')!=1 or trained.tzinfo is None or trained>now or f.get('historyHash')!=history_hash
            or not team_efficiency or team_efficiency.get('historyHash')!=history_hash or f.get('evidenceHash')!=hashlib.sha256(json.dumps(team_efficiency,sort_keys=True).encode()).hexdigest()
            or not forecast_model or f.get('cutoff')!=forecast_model['cutoff'] or f.get('teams')!=forecast_model['teams']
            or len(f.get('featureNames',[]))!=16 or f.get('validation',{}).get('adopted') is not False or f.get('validation',{}).get('hasEdge') is not False
            or f.get('specification')!={'baseRidge':8.,'baseHalfLifeDays':180.,'featureRidge':20.,'featureHalfLifeDays':180.,'correctionCap':7.,'featureCount':16,'minimumResidualTrainingGames':100,'epaHalfLifeDays':84.,'epaRidgePlays':200.,'pacePriorIntervals':50.,'volumePriorGames':3.}
            or not 120<=len(f.get('residuals',[]))<=1000 or any(len(row)!=5 or any(not math.isfinite(v) for v in row[:4]) or not isinstance(row[4],str) or row[4]>f['cutoff'] for row in f['residuals'])):
            raise ValueError('Invalid football feature research provenance')
        selected={};blocks={}
        for event in events:
            record=f.get('events',{}).get(event['id'])
            if not record:continue
            key=record['block'];b=f['blocks'][key]
            parts=event['id'].split(':',1)[1].split('_');target=(int(parts[0]),int(parts[1]))
            allowed=max((g['date'] for g in game_history['games'] if (g['season'],g['week'])<target and g['date']<b['fitDate']),default='')
            if (key!=f'{target[0]}_{target[1]:02d}' or b['inputCutoff']!=allowed
                or any(p.get('lastGame') and p['lastGame']>allowed or p.get('lastObservedQB') and p['lastObservedQB']['date']>allowed for p in record['roles'].values())
                or datetime.fromisoformat(record['startsAt'].replace('Z','+00:00'))!=datetime.fromisoformat(event['startsAt'].replace('Z','+00:00'))
                or record['inputCutoff']!=b['inputCutoff'] or record['inputCutoff']>f['cutoff'] or record['inputCutoff']>=event['startsAt'][:10]
                or len(b['baseCoefficients'])!=66 or len(b['featureCoefficients'])!=16 or b['trainingGames']<100
                or any(not math.isfinite(v) for v in b['baseCoefficients']+b['featureCoefficients'])
                or len(record['x'])!=2 or any(len(row)!=16 or row[0]!=1 or any(not math.isfinite(v) or abs(v)>100 for v in row) for row in record['x'])):
                raise ValueError('Invalid earlier-game football inputs')
            selected[event['id']]=record;blocks[key]=b
        football={k:f[k] for k in ['schemaVersion','version','cutoff','trainedAt','teams','featureNames','specification','residuals','validation','historyHash','evidenceHash']}
        football.update(events=selected,blocks=blocks,sourceUrl=team_efficiency['sourceUrl'],sourceRetrievedAt=team_efficiency['retrievedAt'])
        football_summary={k:f[k] for k in ['version','cutoff','featureNames','specification','development','retrospectiveLater','protocol','validation']}
        football_summary['coverage']={'teamGames':len(team_efficiency['rows']),'seasons':len(team_efficiency['sources']),'sourceUrl':team_efficiency['sourceUrl'],'retrievedAt':team_efficiency['retrievedAt']}
    context_players=context.pop('contextPlayers')
    return {'footballScoreModel':football,'footballResearch':football_summary,'regimeScoreModel':regime,'regimeResearch':regime_summary,'errorAudit':error_audit,'priorTrialFields':['date','week','position','attempts','carries','targets','passing_yards','rushing_yards','receiving_yards','receptions'],'productionModel':production_model,'workloadModel':workload_model,'roleContext':context,'contextPlayers':context_players,'forecastLab':lab,'shadowScoreModel':shadow,'clubs':TEAMS,'scoreModel':model,'results':results,'schemaVersion':1,'builtAt':iso(now),'cutoff':str(cutoff),
        'retrievedAt':iso(retrieved),'evidenceHash':hashlib.sha256(json.dumps(dataset,sort_keys=True).encode()).hexdigest(),
        'events':events,'players':players,'notice':'Recorded participants, not confirmed rosters. Marginal probabilities are not validated live forecasts.'}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--schedule',type=Path,required=True)
    parser.add_argument('--players',type=Path,default=Path('assets/nfl-player-stats.json'))
    parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    with urllib.request.urlopen(SOURCE,timeout=30) as r:rows=list(csv.DictReader(io.StringIO(r.read().decode('utf-8-sig'))))
    tree=ast.parse(Path('model/weather.py').read_text(encoding='utf-8'))
    stadiums=next(ast.literal_eval(node.value) for node in tree.body if isinstance(node,ast.AnnAssign) and getattr(node.target,'id',None)=='STADIUMS')
    result=build_index(json.loads(args.schedule.read_text(encoding='utf-8')),json.loads(args.players.read_text(encoding='utf-8-sig')),rows,datetime.now(timezone.utc),stadiums,json.loads(Path('assets/game-forecast-model.json').read_text(encoding='utf-8')),json.loads(Path('assets/nfl-history.json').read_text(encoding='utf-8-sig')),json.loads(Path('assets/forecast-lab.json').read_text(encoding='utf-8-sig')),json.loads(Path('assets/nfl-matchup.json').read_text(encoding='utf-8-sig')),json.loads(Path('assets/workload-model.json').read_text(encoding='utf-8-sig')),json.loads(Path('assets/production-model.json').read_text(encoding='utf-8-sig')),json.loads(Path('assets/regime-research.json').read_text(encoding='utf-8-sig')),json.loads(Path('assets/game-error-audit.json').read_text(encoding='utf-8-sig')),json.loads(Path('assets/football-research.json').read_text(encoding='utf-8')),json.loads(Path('assets/team-efficiency.json').read_text(encoding='utf-8')))
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,allow_nan=False,separators=(',',':')),encoding='utf-8')
    print(f'Coach index: {len(result["players"])} recorded players; zero odds credits.')
if __name__=='__main__':main()
