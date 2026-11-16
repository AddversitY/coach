"""Versioned opponent-adjusted score model and strict earlier-week evaluation.

No odds API requests. Forecast errors are drawn only from earlier held-out weeks.
The existing EPA model is audited, not silently promoted to a profitable model.
This fixed specification is not tuned on the reported test outcomes.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import numpy as np

ROOT=Path(__file__).resolve().parents[1]
VERSION='score-ridge-empirical-v1'
TEAMS='ARI ATL BAL BUF CAR CHI CIN CLE DAL DEN DET GB HOU IND JAX KC LAC LAR LV MIA MIN NE NO NYG NYJ PHI PIT SEA SF TB TEN WAS'.split()
ALIASES={'LA':'LAR','OAK':'LV','SD':'LAC','STL':'LAR'}
HALF_LIFE=180.0
WINDOW_DAYS=730
RIDGE=40.0
MIN_TRAIN=300
MIN_ERRORS=120
MAX_ERRORS=1000

def team(value):
    return ALIASES.get(value,value)

def before(row,season,week):
    return (row['season'],row['week'])<(season,week)

def features(home,away,neutral=False):
    result=np.zeros((2,66),dtype=float)
    result[:,0]=1
    result[0,1]=0 if neutral else 1
    h,a=TEAMS.index(team(home)),TEAMS.index(team(away))
    result[0,2+h]=result[1,34+h]=1
    result[1,2+a]=result[0,34+a]=1
    return result

def fit(rows,as_of):
    rows=[r for r in rows if 0<(as_of-date.fromisoformat(r['date'])).days<=WINDOW_DAYS]
    if len(rows)<MIN_TRAIN:
        raise ValueError('Insufficient strictly earlier score observations')
    x=np.concatenate([features(r['home'],r['away'],r.get('neutral',False)) for r in rows])
    y=np.array([score for r in rows for score in [r['homeScore'],r['awayScore']]],dtype=float)
    weights=np.repeat([.5**((as_of-date.fromisoformat(r['date'])).days/HALF_LIFE) for r in rows],2)
    penalty=np.full(66,RIDGE);penalty[0]=0;penalty[1]=4
    coefficients=np.linalg.solve(x.T@(weights[:,None]*x)+np.diag(penalty),x.T@(weights*y))
    return coefficients,len(rows)

def project(coefficients,home,away,neutral=False):
    values=features(home,away,neutral)@coefficients
    return [float(np.clip(value,0,65)) for value in values]

def draws(means,errors):
    return [(max(0,min(90,int(math.floor(means[0]+e[0]+.5)))),max(0,min(90,int(math.floor(means[1]+e[1]+.5))))) for e in errors]

def chances(scores,market,line=0):
    values=[h-a+line if market=='spreads' else h+a-line if market=='totals' else h-a for h,a in scores]
    n=len(values)
    return (sum(v>0 for v in values)/n,sum(v==0 for v in values)/n)

def decimal(american):
    try:value=float(american)
    except (ValueError,TypeError):return None
    return 1+value/100 if value>=100 else 1+100/abs(value) if value<=-100 else None

def fair(a,b):
    a,b=decimal(a),decimal(b)
    return (1/a)/(1/a+1/b) if a and b else None

def measurements(rows):
    if not rows:return {'count':0,'brier':None,'logLoss':None,'baselineBrier':None,'baselineLogLoss':None,'adopted':False,'hasEdge':False}
    def brier(key):return sum((r[key]-r['outcome'])**2 for r in rows)/len(rows)
    def loss(key):return -sum(math.log(max(1e-6,min(1-1e-6,r[key] if r['outcome'] else 1-r[key]))) for r in rows)/len(rows)
    return {'count':len(rows),'brier':brier('p'),'logLoss':loss('p'),'baselineBrier':brier('baseline'),'baselineLogLoss':loss('baseline'),
        'adopted':False,'hasEdge':False,'notice':'Historical closing-line/reference evaluation only. Prospective obtainable-price validation required.'}

def train(history,legacy,schedule=None):
    cutoff=date.fromisoformat(history['cutoff'])
    rows=[]
    by_id={r.get('game_id'):r for r in schedule or []}
    for raw in history['games']:
        if date.fromisoformat(raw['date'])>cutoff:continue
        if team(raw['home']) not in TEAMS or team(raw['away']) not in TEAMS:continue
        r=dict(raw,home=team(raw['home']),away=team(raw['away']))
        original=by_id.get(raw.get('id'),{})
        r['neutral']=original.get('location')=='Neutral'
        r['closing']=original
        rows.append(r)
    rows.sort(key=lambda r:(r['season'],r['week'],r['date'],r.get('id','')))
    errors=[];scored={key:[] for key in ['moneyline','spreads','totals']};folds=[]
    for season,week in sorted({(r['season'],r['week']) for r in rows}):
        testing=[r for r in rows if (r['season'],r['week'])==(season,week)]
        earlier=[r for r in rows if before(r,season,week)]
        if len(earlier)<MIN_TRAIN:continue
        fold_day=min(date.fromisoformat(r['date']) for r in testing)
        try:coef,n=fit(earlier,fold_day)
        except ValueError:continue
        # Freeze this error pool for the entire test week: no same-week leakage.
        prior_errors=errors[-MAX_ERRORS:]
        fold_errors=[]
        for r in testing:
            mean=project(coef,r['home'],r['away'],r['neutral'])
            if len(prior_errors)>=MIN_ERRORS:
                sample=draws(mean,prior_errors)
                closing=r['closing']
                for market in scored:
                    try:
                        line=-float(closing['spread_line']) if market=='spreads' else float(closing['total_line']) if market=='totals' else 0
                    except (ValueError,KeyError,TypeError):continue
                    actual=r['homeScore']-r['awayScore']+line if market=='spreads' else r['homeScore']+r['awayScore']-line if market=='totals' else r['homeScore']-r['awayScore']
                    if actual==0:continue
                    p,push=chances(sample,market,line)
                    p=p/max(1e-9,1-push)
                    baseline=fair(closing.get('home_moneyline'),closing.get('away_moneyline')) if market=='moneyline' else fair(closing.get('home_spread_odds'),closing.get('away_spread_odds')) if market=='spreads' else fair(closing.get('over_odds'),closing.get('under_odds'))
                    if baseline is None:
                        if market=='moneyline':baseline=sum(g['homeScore']>g['awayScore'] for g in earlier)/len(earlier)
                        else:baseline=.5
                    scored[market].append({'id':r.get('id'),'p':p,'baseline':baseline,'outcome':int(actual>0)})
            fold_errors.append([r['homeScore']-mean[0],r['awayScore']-mean[1]])
        folds.append({'season':season,'week':week,'trainGames':n,'errorGames':len(prior_errors),'trainedThrough':[earlier[-1]['season'],earlier[-1]['week']]})
        errors.extend(fold_errors)
    coefficients,n=fit(rows,cutoff+timedelta(days=1))
    if len(errors)<MIN_ERRORS:raise ValueError('Insufficient earlier-week forecast errors')
    v2=legacy.get('v2',{})
    return {'schemaVersion':1,'version':VERSION,'cutoff':str(cutoff),'trainedAt':datetime.now(timezone.utc).isoformat(),'teams':TEAMS,'coefficients':[round(float(x),8) for x in coefficients],
        'baselineHomeWin':sum(r['homeScore']>r['awayScore'] for r in rows)/len(rows),'residuals':[[round(v,5) for v in e] for e in errors[-MAX_ERRORS:]],'trainingGames':n,
        'specification':{'halfLifeDays':HALF_LIFE,'windowDays':WINDOW_DAYS,'ridge':RIDGE,'minTrain':MIN_TRAIN,'minEarlierErrors':MIN_ERRORS,'maxErrors':MAX_ERRORS,'frozenBeforeEvaluation':True},
        'validation':{'method':'Earlier-week ridge fits with earlier-week empirical score errors; entire test weeks frozen. No tuning on reported scores.','markets':{m:measurements(v) for m,v in scored.items()},'folds':folds,'adopted':False,'hasEdge':False,
          'scope':'Score-only candidate; not a play-by-play model. Historical references are not proof of obtainable returns. Prospective validation starts with saved forecasts.',
          'aiBaseline':'Prospective paired benchmark only; no historical AI results invented.'},
        'legacyAudit':{'sourceAsOf':legacy.get('asOf'),'v1Brier':legacy.get('backtest',{}).get('brier'),'v1Roi':legacy.get('backtest',{}).get('roi'),'v2Adopted':v2.get('adopted',False),'v2HasEdge':v2.get('hasEdge',False),'decision':'Reuse score history, identity mapping and validation discipline; do not treat legacy ROI or v2 adoption as a proven edge for new markets.'},
        'evidenceHash':hashlib.sha256(json.dumps(history,sort_keys=True).encode()).hexdigest()}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--history',type=Path,default=ROOT/'assets/nfl-history.json');parser.add_argument('--legacy',type=Path,default=ROOT/'assets/nfl-model.json');parser.add_argument('--schedule',type=Path);parser.add_argument('--output',type=Path,default=ROOT/'assets/game-forecast-model.json');args=parser.parse_args()
    schedule=None
    if args.schedule:
        with args.schedule.open(encoding='utf-8-sig',newline='') as f:schedule=list(csv.DictReader(f))
    result=train(json.loads(args.history.read_text(encoding='utf-8-sig')),json.loads(args.legacy.read_text(encoding='utf-8-sig')),schedule)
    args.output.write_text(json.dumps(result,separators=(',',':'),allow_nan=False)+'\n',encoding='utf-8')
    print(json.dumps({'version':VERSION,'trainingGames':result['trainingGames'],'errors':len(result['residuals']),'markets':result['validation']['markets'],'hasEdge':False}))

if __name__=='__main__':main()
