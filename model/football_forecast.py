"""One fixed pregame football-feature residual challenger; never auto-adopted."""
import argparse,csv,hashlib,json,math
from pathlib import Path
from datetime import date,datetime,timedelta,timezone
from zoneinfo import ZoneInfo
import numpy as np
from football_features import NAMES,state_for,vector
from forecast_lab import prepare,compare,walk_forward,MARKETS
from game_forecast import ROOT,TEAMS,MIN_TRAIN,MIN_ERRORS,MAX_ERRORS,before,fit,project,draws,fair,chances
VERSION='score-football-features-v1'
SPEC={'baseRidge':8.,'baseHalfLifeDays':180.,'featureRidge':20.,'featureHalfLifeDays':180.,'correctionCap':7.,'featureCount':len(NAMES),'minimumResidualTrainingGames':100,'epaHalfLifeDays':84.,'epaRidgePlays':200.,'pacePriorIntervals':50.,'volumePriorGames':3.}

def residual_fit(examples,day):
    usable=[r for r in examples if 0<(day-date.fromisoformat(r['date'])).days<=730]
    if len(usable)<100:raise ValueError('Earlier out-of-sample residual labels required')
    x=np.array([v for r in usable for v in r['x']]);y=np.array([v for r in usable for v in r['residual']]);w=np.repeat([.5**((day-date.fromisoformat(r['date'])).days/180) for r in usable],2)
    penalty=np.full(len(NAMES),20.);penalty[0]=0;penalty[1]=4
    return np.linalg.solve(x.T@(w[:,None]*x)+np.diag(penalty),x.T@(w*y)),len(usable)

def adjusted(base,x,coef):return [float(np.clip(mean+np.clip(np.dot(features,coef),-7,7),0,65)) for mean,features in zip(base,x)]

def fold_inputs(rows,team_rows,season,week,as_of=None):
    earlier=[r for r in rows if before(r,season,week) and (as_of is None or r['date']<str(as_of))]
    stats=[r for r in team_rows if before(r,season,week) and r['date']<=max((g['date'] for g in earlier),default='')]
    return earlier,state_for(stats,earlier)

def walk(rows,team_rows):
    examples=[];predictions=[]
    for season,week in sorted({(r['season'],r['week']) for r in rows}):
        tests=[r for r in rows if (r['season'],r['week'])==(season,week)];day=min(date.fromisoformat(r['date']) for r in tests);earlier,state=fold_inputs(rows,team_rows,season,week,day)
        if len(earlier)<MIN_TRAIN or state is None:continue
        day=min(date.fromisoformat(r['date']) for r in tests)
        try:base_coef,_=fit(earlier,day,ridge=8.,half_life=180.)
        except ValueError:continue
        try:coef,_=residual_fit(examples,day)
        except ValueError:coef=None
        bank=[r['residual'] for r in predictions if r['date']<str(day)][-MAX_ERRORS:];new_examples=[];new_predictions=[]
        for r in tests:
            base=project(base_coef,r['home'],r['away'],r['neutral']);x=[vector(state,r['home'],r['away'],r['date'],not r['neutral']),vector(state,r['away'],r['home'],r['date'],False)]
            new_examples.append({'id':r['id'],'season':season,'week':week,'date':r['date'],'x':x,'residual':[r['homeScore']-base[0],r['awayScore']-base[1]]})
            if coef is None:continue
            means=adjusted(base,x,coef);residual=[r['homeScore']-means[0],r['awayScore']-means[1]]
            scored={'id':r['id'],'season':season,'week':week,'date':r['date'],'residual':residual,'markets':{}}
            if len(bank)>=MIN_ERRORS:
                sample=draws(means,bank);c=r['closing']
                for market in MARKETS:
                    try:line=-float(c['spread_line']) if market=='spreads' else float(c['total_line']) if market=='totals' else 0.
                    except (ValueError,KeyError,TypeError):continue
                    if not math.isfinite(line):continue
                    actual=r['homeScore']-r['awayScore']+line if market=='spreads' else r['homeScore']+r['awayScore']-line if market=='totals' else r['homeScore']-r['awayScore']
                    if actual==0:continue
                    pair=('home_moneyline','away_moneyline') if market=='moneyline' else ('home_spread_odds','away_spread_odds') if market=='spreads' else ('over_odds','under_odds')
                    baseline=fair(c.get(pair[0]),c.get(pair[1]));win,push=chances(sample,market,line)
                    if baseline is not None:scored['markets'][market]={'p':win/max(1e-9,1-push),'baseline':baseline,'y':int(actual>0)}
            new_predictions.append(scored)
        examples.extend(new_examples);predictions.extend(new_predictions)
    return examples,predictions

def run(history,schedule,evidence):
    expected=hashlib.sha256(json.dumps(history,sort_keys=True).encode()).hexdigest()
    if evidence['historyHash']!=expected or evidence['cutoff']!=history['cutoff']:raise ValueError('Football evidence/history mismatch')
    rows=prepare(history,schedule);examples,predictions=walk(rows,evidence['rows']);baseline=walk_forward(rows,{'ridge':8.,'halfLifeDays':180.})
    now=datetime.now(timezone.utc);blocks={};events={}
    for raw in sorted(schedule,key=lambda r:(r.get('gameday',''),r.get('gametime',''),r.get('game_id',''))):
        try:kick=datetime.fromisoformat(raw['gameday']+'T'+raw['gametime']).replace(tzinfo=ZoneInfo('America/New_York')).astimezone(timezone.utc);season=int(raw['season']);week=int(raw['week'])
        except (KeyError,TypeError,ValueError):continue
        if kick<=now or season!=history['currentSeason']:continue
        key=f'{season}_{week:02d}';home=raw['home_team'];away=raw['away_team']
        from game_forecast import team
        home,away=team(home),team(away)
        if home not in TEAMS or away not in TEAMS:continue
        if key not in blocks:
            first_day=min(r['gameday'] for r in schedule if str(r.get('season'))==str(season) and str(r.get('week'))==str(week) and r.get('gameday'))
            prior,state=fold_inputs(rows,evidence['rows'],season,week,first_day)
            try:base,_=fit(prior,date.fromisoformat(first_day),ridge=8.,half_life=180.);coef,n=residual_fit([r for r in examples if before(r,season,week)],date.fromisoformat(first_day))
            except ValueError:continue
            blocks[key]={'baseCoefficients':[round(float(v),10) for v in base],'featureCoefficients':[round(float(v),10) for v in coef],'trainingGames':n,'fitDate':first_day,'inputCutoff':state['asOf'],'state':state}
        block=blocks[key];state=block['state'];neutral=raw.get('location')=='Neutral';x=[vector(state,home,away,raw['gameday'],not neutral),vector(state,away,home,raw['gameday'],False)]
        roles={}
        for side,club in [('home',home),('away',away)]:
            p=state['profiles'][club];roles[side]={**{k:p[k] for k in ['lastObservedQB','qbChanged','qbMissing','games','lastGame']},'adjustedOffenseEpaPerPlay':p['offense'],'adjustedAllowanceEpaPerPlay':p['allowance'],'clockSecondsPerSnap':p['pace'],'recordedPlaysPerGame':p['plays'],'confirmedUpcomingStarter':None,'notice':'Recorded earlier-game role and efficiency only. No upcoming starter, active status or injury deduction is inferred.'}
        events['nflverse:'+raw['game_id']]={'block':key,'x':x,'roles':roles,'inputCutoff':state['asOf'],'startsAt':kick.isoformat().replace('+00:00','Z')}
    for block in blocks.values():block.pop('state')
    later=compare([r for r in predictions if r['season']>=2025],baseline)
    return {'schemaVersion':1,'version':VERSION,'cutoff':history['cutoff'],'trainedAt':now.isoformat(),'historyHash':expected,'evidenceHash':hashlib.sha256(json.dumps(evidence,sort_keys=True).encode()).hexdigest(),'scheduleHash':hashlib.sha256(json.dumps(schedule,sort_keys=True).encode()).hexdigest(),'teams':TEAMS,'featureNames':NAMES,'specification':SPEC,'blocks':blocks,'events':events,'residuals':[[r['residual'][0],r['residual'][1],r['season'],r['week'],r['date']] for r in predictions[-MAX_ERRORS:]],'development':compare([r for r in predictions if r['season']<2025],baseline),'retrospectiveLater':later,'validation':{'adopted':False,'hasEdge':False,'status':'shadow_only'},'protocol':{'parameterSearch':False,'featureTiming':'Entire target week excluded; EPA adjustment, pace and QB roles use strictly earlier weeks. Residual correction learns earlier out-of-sample errors. No current-game starter labels or closing lines are predictors.','historicalScope':'2025+ was not used to select this fixed specification, but appeared in previous reports; this is retrospective, not a fresh holdout. Future frozen games are untouched evaluation.','availability':'Confirmed inactive reports remain a separate gate. Upcoming starters are unknown unless explicitly sourced. Pace is a clock proxy, not neutral-situation tempo.'}}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--schedule',type=Path,required=True);p.add_argument('--output',type=Path,default=ROOT/'assets/football-research.json');a=p.parse_args()
    with a.schedule.open(encoding='utf-8-sig',newline='') as f:schedule=list(csv.DictReader(f))
    report=run(json.loads((ROOT/'assets/nfl-history.json').read_text(encoding='utf-8-sig')),schedule,json.loads((ROOT/'assets/team-efficiency.json').read_text(encoding='utf-8')));a.output.write_text(json.dumps(report,separators=(',',':'),allow_nan=False)+'\n',encoding='utf-8')
    print(json.dumps({'events':len(report['events']),'blocks':len(report['blocks']),'metrics':{m:{k:v[k] for k in ['games','brier','incumbentBrier','marketBrier','logLoss','incumbentLogLoss']} for m,v in report['retrospectiveLater'].items()}}))
