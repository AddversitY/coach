"""One fixed conditional-error challenger. No later-period parameter selection."""
import argparse,csv,hashlib,json,math
from datetime import date,datetime,timedelta,timezone
from pathlib import Path
import numpy as np
from forecast_lab import prepare,compare,walk_forward,INCUMBENT,EVALUATION_START,MARKETS
from game_forecast import ROOT,TEAMS,MIN_TRAIN,MIN_ERRORS,MAX_ERRORS,before,fit,project,draws,fair
VERSION='score-regime-kernel-v1'
SPEC={'totalBandwidth':10.,'marginBandwidth':7.,'uniformMixture':.5,'minimumEffectiveErrors':120,'ridge':40.,'halfLifeDays':180.}

def weights(contexts,means):
    n=len(contexts)
    if n<MIN_ERRORS:raise ValueError('Earlier residual contexts required')
    total=sum(means);margin=abs(means[0]-means[1])
    logw=np.array([-.5*(((c[0]-total)/10)**2+((c[1]-margin)/7)**2) for c in contexts])
    kernel=np.exp(logw-logw.max());kernel/=kernel.sum();w=.5/n+.5*kernel
    if 1/float(w@w)<120:w=np.full(n,1/n)
    return w.tolist()

def walk(rows):
    errors=[];contexts=[];forecasts=[]
    for season,week in sorted({(r['season'],r['week']) for r in rows}):
        testing=[r for r in rows if (r['season'],r['week'])==(season,week)]
        earlier=[r for r in rows if before(r,season,week)]
        if len(earlier)<MIN_TRAIN:continue
        day=min(date.fromisoformat(r['date']) for r in testing)
        try:coef,_=fit(earlier,day,ridge=40.,half_life=180.)
        except ValueError:continue
        frozen_errors=errors[-MAX_ERRORS:];frozen_contexts=contexts[-MAX_ERRORS:];next_errors=[];next_contexts=[]
        for r in testing:
            means=project(coef,r['home'],r['away'],r['neutral']);residual=[r['homeScore']-means[0],r['awayScore']-means[1]]
            next_errors.append(residual);next_contexts.append([sum(means),abs(means[0]-means[1])])
            scored={'id':r['id'],'season':season,'week':week,'residual':residual,'context':[sum(means),abs(means[0]-means[1])],'markets':{}}
            if len(frozen_errors)>=MIN_ERRORS:
                samples=draws(means,frozen_errors);w=weights(frozen_contexts,means);c=r['closing']
                for market in MARKETS:
                    try:line=-float(c['spread_line']) if market=='spreads' else float(c['total_line']) if market=='totals' else 0.
                    except (KeyError,TypeError,ValueError):continue
                    if not math.isfinite(line):continue
                    actual=r['homeScore']-r['awayScore']+line if market=='spreads' else r['homeScore']+r['awayScore']-line if market=='totals' else r['homeScore']-r['awayScore']
                    if actual==0:continue
                    pair=('home_moneyline','away_moneyline') if market=='moneyline' else ('home_spread_odds','away_spread_odds') if market=='spreads' else ('over_odds','under_odds')
                    baseline=fair(c.get(pair[0]),c.get(pair[1]))
                    if baseline is None:continue
                    values=[h-a+line if market=='spreads' else h+a-line if market=='totals' else h-a for h,a in samples]
                    win=sum(weight for value,weight in zip(values,w) if value>0);push=sum(weight for value,weight in zip(values,w) if value==0)
                    scored['markets'][market]={'p':win/max(1e-9,1-push),'baseline':baseline,'y':int(actual>0)}
            forecasts.append(scored)
        # Entire test week frozen before adding its labels and forecast contexts.
        errors.extend(next_errors);contexts.extend(next_contexts)
    return forecasts

def run(history,schedule):
    rows=prepare(history,schedule);predictions=walk(rows);incumbent=walk_forward(rows,INCUMBENT)
    later=[r for r in predictions if r['season']>=EVALUATION_START]
    comparison=compare(later,incumbent)
    prior_spec=json.loads((ROOT/'assets/forecast-lab.json').read_text(encoding='utf-8-sig'))['selectedSpecification']
    prior_shadow=walk_forward(rows,prior_spec)
    vs_shadow=compare(later,prior_shadow)
    coefficients,n=fit(rows,date.fromisoformat(history['cutoff'])+timedelta(days=1),ridge=40.,half_life=180.)
    source_hash=hashlib.sha256(json.dumps(history,sort_keys=True).encode()).hexdigest()
    model={'schemaVersion':1,'version':VERSION,'cutoff':history['cutoff'],'trainedAt':datetime.now(timezone.utc).isoformat(),'teams':TEAMS,'coefficients':[round(float(v),8) for v in coefficients],'residuals':[[round(v,5) for v in r['residual']] for r in predictions[-MAX_ERRORS:]],'residualContexts':[[round(v,5) for v in r['context']] for r in predictions[-MAX_ERRORS:]],'specification':SPEC,'trainingGames':n,'sourceHash':source_hash,'validation':{'adopted':False,'hasEdge':False,'markets':comparison,'status':'shadow_only'}}
    return {'schemaVersion':1,'version':'regime-research-v1','cutoff':history['cutoff'],'generatedAt':model['trainedAt'],'sourceHash':source_hash,'scheduleHash':hashlib.sha256(json.dumps(schedule,sort_keys=True).encode()).hexdigest(),'model':model,'development':compare([r for r in predictions if r['season']<2025],incumbent),'retrospectiveLater':comparison,'vsExistingShadow':vs_shadow,'existingShadowSpecification':prior_spec,'protocol':{'fixedSpecification':SPEC,'parameterSearch':False,'historicalScope':'Later seasons were previously reported; this is retrospective, not a fresh holdout. No settings are selected using these later results.','prospectiveScope':'Only future frozen pregame captures after this version is deployed are untouched evaluation.','features':'Earlier-week forecast total and absolute margin only. No closing lines, same-week outcomes or unconfirmed QB/injury deductions enter weights.','adopted':False,'hasEdge':False}}

def main():
    p=argparse.ArgumentParser();p.add_argument('--schedule',type=Path,required=True);p.add_argument('--output',type=Path,default=ROOT/'assets/regime-research.json');a=p.parse_args()
    with a.schedule.open(encoding='utf-8-sig',newline='') as f:schedule=list(csv.DictReader(f))
    report=run(json.loads((ROOT/'assets/nfl-history.json').read_text(encoding='utf-8-sig')),schedule);a.output.write_text(json.dumps(report,separators=(',',':'),allow_nan=False)+'\n',encoding='utf-8')
    print(json.dumps({'version':VERSION,'markets':{m:{k:r[k] for k in ['games','brier','incumbentBrier','marketBrier','logLoss','incumbentLogLoss']} for m,r in report['retrospectiveLater'].items()}}))
if __name__=='__main__':main()
