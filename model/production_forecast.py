"""Joint workload/efficiency production research, never an automatic promotion.

Current source vintages, not a historical availability archive. Rate settings
are selected on seasons before 2025, then evaluated with whole-week freezes.
Actual game quarterback identities are outcome-only slice labels.
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
import workload_forecast as workload

ROOT=Path(__file__).resolve().parents[1]
VERSION='production-joint-v1'
RIDGES=(None,1.,10.,100.)
MIN_TRAIN=200
MIN_ERRORS=120
MAX_ERRORS=512
EXTRA=('passing_yards','rushing_yards','receiving_yards','receptions')
STATS={'QB_attempts':['passing_yards'],'QB_carries':['rushing_yards'],'RB_carries':['rushing_yards'],
       'RB_targets':['receiving_yards','receptions'],'WR_targets':['receiving_yards','receptions'],'TE_targets':['receiving_yards','receptions']}
FEATURES=workload.FEATURES+['weightedEfficiency','recentEfficiency','priorEfficiency','opponentAllowedEfficiency','missingOpponentEfficiency','observedPassingEfficiencyDelta','quarterbackChangeEfficiencyInteraction']


def rate_packs(segment,team_games,other_games,day,group):
    metric=workload.GROUPS[group][1]
    rows=sorted([r for r in segment if r['date']<str(day) and 0<(day-date.fromisoformat(r['date'])).days<=730],key=lambda r:r['date'],reverse=True)[:10]
    weights=np.array([.5**(i/4) for i in range(len(rows))])
    count=np.array([r['stats'][metric] for r in rows])
    denominator=float(np.dot(weights,count))
    if not denominator:return {'production':{}}
    own=sorted([g for g in team_games if g['date']<str(day)],key=lambda r:r['date'],reverse=True)[:6]
    other=sorted([g for g in other_games if g['date']<str(day)],key=lambda r:r['date'],reverse=True)[:3]
    passer_rates=[g['passing_yards']/g['attempts'] for g in own[:3] if g['attempts']>0]
    delta=(passer_rates[0]-sum(passer_rates[1:])/len(passer_rates[1:]))/10 if len(passer_rates)>1 else 0.
    leaders=[g['leader'] for g in own[:3] if g.get('leader')]
    changed=float(len(set(leaders))>1)
    packs={}
    for stat in STATS[group]:
        baseline=[r for r in rows if r['stats'][stat]>=0]
        if len(baseline)<6:continue
        bweights=np.array([.5**(i/4) for i in range(len(baseline))])
        bcount=np.array([r['stats'][metric] for r in baseline]);bstat=np.array([r['stats'][stat] for r in baseline])
        usage=float(np.dot(bweights,bcount)/sum(bweights))
        if usage<=0:continue
        volume=min(usage*1.25,max(usage*.75,.65*float(np.mean(bcount[:3]))+.35*usage))
        baseline_mean=volume*float(np.dot(bweights,bstat)/np.dot(bweights,bcount))
        observed=float(np.dot(bweights,bstat)/sum(bweights))
        variance=float(np.dot(bweights,(bstat-observed)**2)/sum(bweights))
        baseline_sd=math.sqrt(max(1,baseline_mean*.15)**2+variance*(1+1/len(baseline)))
        values=np.array([r['stats'][stat] for r in rows])
        rate=float(np.dot(weights,values)/denominator)
        recent=float(sum(values[:3])/sum(count[:3])) if sum(count[:3]) else rate
        prior=float(sum(values[3:6])/sum(count[3:6])) if sum(count[3:6]) else rate
        pairs=[g for g in other if g.get('allowed_'+metric) is not None and g.get('allowed_'+stat) is not None]
        opp_den=sum(g['allowed_'+metric] for g in pairs)
        opp=sum(g['allowed_'+stat] for g in pairs)/opp_den if opp_den else 0.
        scale=1. if stat=='receptions' else 10.
        packs[stat]={'rate':rate,'extra':[rate/scale,recent/scale,prior/scale,opp/scale,float(not opp_den),delta,changed*rate/scale],
                     'baselineMean':baseline_mean,'baselineSd':baseline_sd,'last3':float(np.mean(values[:3])),'last6':float(np.mean(values[:6]))}
    return {'production':packs,'priorLeader':leaders[0] if leaders else None}


def fit_rate(rows,day,ridge,ablated=False):
    prior=[r for r in rows if r['actualStats'] is not None and r['y']>0 and 0<(day-date.fromisoformat(r['date'])).days<=730]
    if len(prior)<MIN_TRAIN:raise ValueError('Insufficient earlier efficiency labels')
    if ridge is None:return np.zeros(len(FEATURES)),len(prior)
    x=np.array([rate_features(r,ablated) for r in prior])
    y=np.array([r['actualStats'][r['stat']]/r['y']-r['pack']['rate'] for r in prior])
    w=np.array([.5**((day-date.fromisoformat(r['date'])).days/365)*min(r['y'],40 if r['metric']=='attempts' else 20 if r['metric']=='carries' else 10) for r in prior])
    w/=np.mean(w)
    coef=np.linalg.solve(x.T@(w[:,None]*x)+ridge*np.eye(len(FEATURES)),x.T@(w*y))
    return coef,len(prior)


def rate_features(row,ablated=False):
    x=list(row['x'])+row['pack']['extra']
    if ablated:
        for i in [14,22,23]:x[i]=0.
    return x


def samples(volume,rate,pairs,stat,cap):
    if len(pairs)<MIN_ERRORS:return None
    errors=np.asarray(pairs[-MAX_ERRORS:])
    centered=errors-errors.mean(axis=0)
    counts=np.clip(np.floor(volume+centered[:,0]+.5),0,cap)
    efficiency=np.clip(rate+centered[:,1],0 if stat=='receptions' else -20,1 if stat=='receptions' else 60)
    result=np.floor(counts*efficiency+.5)
    return np.clip(result,0 if stat=='receptions' else -999,counts if stat=='receptions' else 999)


def walk_rate(rows,ridge,ablated=False):
    prior=[];errors=[];predictions=[]
    for season,week in sorted({(r['season'],r['week']) for r in rows}):
        batch=[r for r in rows if (r['season'],r['week'])==(season,week)]
        try:coef,_=fit_rate(prior,min(date.fromisoformat(r['date']) for r in batch),ridge,ablated)
        except ValueError:prior.extend(batch);continue
        frozen=errors[-MAX_ERRORS:];new=[]
        for row in batch:
            rate=float(np.clip(row['pack']['rate']+np.dot(rate_features(row,ablated),coef),0 if row['stat']=='receptions' else -20,1 if row['stat']=='receptions' else 60))
            draws=samples(row['prediction'],rate,frozen,row['stat'],row['cap'])
            prediction=float(np.mean(draws)) if draws is not None else row['prediction']*rate
            actual=row['actualStats'][row['stat']] if row['actualStats'] is not None else None
            line=math.floor(row['pack']['baselineMean'])+.5
            p=float(np.mean(draws>line)) if draws is not None else None
            baseline_p=1-.5*(1+math.erf((line-row['pack']['baselineMean'])/(row['pack']['baselineSd']*math.sqrt(2))))
            predictions.append(dict(playerId=row['playerId'],eventId=row['eventId'],season=season,week=week,date=row['date'],stat=row['stat'],prediction=prediction,actual=actual,
                                    baseline=row['pack']['baselineMean'],last3=row['pack']['last3'],last6=row['pack']['last6'],line=line,p=p,baselineP=baseline_p,
                                    interval=[float(v) for v in np.quantile(draws,[.1,.9])] if draws is not None else None,
                                    observedChange=bool(row['x'][14]),actualChange=(row['actualLeader']!=row['priorLeader']) if row.get('actualLeader') and row.get('priorLeader') else None))
            if actual is not None:
                new.append([row['y']-row['prediction'],actual/row['y']-rate if row['y']>0 else 0.])
        errors.extend(new);prior.extend(batch)
    return predictions,errors[-MAX_ERRORS:]


def summary(rows):
    scored=[r for r in rows if r['actual'] is not None]
    if not scored:return {'recorded':0,'unresolved':len(rows)}
    average=lambda k:sum(abs(r[k]-r['actual']) for r in scored)/len(scored)
    pairs=[r for r in scored if r['p'] is not None]
    intervals=[r for r in scored if r['interval']]
    blocks={}
    for r in scored:blocks.setdefault((r['season'],r['week']),[]).append(abs(r['prediction']-r['actual'])-abs(r['baseline']-r['actual']))
    ci=None
    if len(blocks)>=12:
        sums=np.array([sum(v) for v in blocks.values()]);sizes=np.array([len(v) for v in blocks.values()])
        picks=np.random.default_rng(20261116).integers(0,len(sums),(2000,len(sums)))
        ci=[float(v) for v in np.quantile(sums[picks].sum(axis=1)/sizes[picks].sum(axis=1),[.025,.975])]
    return {'recorded':len(scored),'unresolved':len(rows)-len(scored),'mae':average('prediction'),'baselineMae':average('baseline'),'last3Mae':average('last3'),'last6Mae':average('last6'),
            'rmse':math.sqrt(sum((r['prediction']-r['actual'])**2 for r in scored)/len(scored)),
            'baselineRmse':math.sqrt(sum((r['baseline']-r['actual'])**2 for r in scored)/len(scored)),
            'pairedMaeDifference95':ci,'intervalCount':len(intervals),'interval80Coverage':sum(r['interval'][0]<=r['actual']<=r['interval'][1] for r in intervals)/len(intervals) if intervals else None,
            'referenceCutoffCount':len(pairs),'referenceBrier':sum((r['p']-int(r['actual']>r['line']))**2 for r in pairs)/len(pairs) if pairs else None,
            'baselineReferenceBrier':sum((r['baselineP']-int(r['actual']>r['line']))**2 for r in pairs)/len(pairs) if pairs else None}


def qb_comparison(full,ablated):
    other={(r['playerId'],r['eventId'],r['stat']):r for r in ablated}
    pairs=[(r,other[(r['playerId'],r['eventId'],r['stat'])]) for r in full if r['actual'] is not None and (r['playerId'],r['eventId'],r['stat']) in other]
    result={}
    for label,predicate in [('all',lambda r:True),('observedChange',lambda r:r['observedChange']),('actualChangeOutcomeOnly',lambda r:r['actualChange'] is True)]:
        selected=[(a,b) for a,b in pairs if predicate(a)]
        result[label]={'recorded':len(selected),'fullMae':sum(abs(a['prediction']-a['actual']) for a,b in selected)/len(selected) if selected else None,
                       'withoutExplicitQbSignalsMae':sum(abs(b['prediction']-a['actual']) for a,b in selected)/len(selected) if selected else None}
    return result


def run(dataset,history,schedule,volume_model):
    examples,cutoff=workload.examples(dataset,history,schedule,extra_stats=EXTRA,augment=rate_packs)
    models={};validation={}
    for volume_group,stats in STATS.items():
        group_rows=[r for r in examples if r['group']==volume_group]
        ridge=volume_model['validation'][volume_group]['selectedRidge']
        volume_rows,_=workload.walk_forward(group_rows,ridge)
        ablated_rows=[dict(r,x=[v if i!=14 else 0. for i,v in enumerate(r['x'])]) for r in group_rows]
        ablated_volume,_=workload.walk_forward(ablated_rows,ridge) if volume_group.endswith('targets') else ([],[])
        for stat in stats:
            key=volume_group.split('_')[0]+'_'+stat
            rows=[dict(r,stat=stat,pack=r['production'][stat]) for r in volume_rows if stat in r['production']]
            development=[r for r in rows if r['season']<2025]
            candidates=[]
            for rate_ridge in RIDGES:
                predicted,_=walk_rate(development,rate_ridge)
                report=summary(predicted)
                candidates.append({'ridge':rate_ridge,'recorded':report['recorded'],'mae':report.get('mae')})
            eligible=[r for r in candidates if r['recorded']>=100]
            if not eligible:continue
            selected=min(eligible,key=lambda r:(r['mae'],r['ridge'] or 0))['ridge']
            forecasts,errors=walk_rate(rows,selected)
            later=[r for r in forecasts if r['season']>=2025]
            report=summary(later)
            ci=report.get('pairedMaeDifference95')
            report['historicalCoverageWithinTolerance']=bool(report.get('intervalCount',0)>=200 and abs(report['interval80Coverage']-.8)<=.05)
            report.update(selectedRidge=selected,developmentCandidates=candidates,clearedHistoricalGate=bool(report['recorded']>=200 and ci and ci[1]<0 and report['mae']<report['baselineMae'] and report['rmse']<report['baselineRmse']),
                          seasons={str(s):summary([r for r in later if r['season']==s]) for s in sorted({r['season'] for r in later})})
            if volume_group.endswith('targets'):
                ablation_input=[dict(r,stat=stat,pack=r['production'][stat]) for r in ablated_volume if stat in r['production']]
                ablation,_=walk_rate(ablation_input,selected,True)
                report['quarterbackAblation']=qb_comparison(later,[r for r in ablation if r['season']>=2025])
            coef,n=fit_rate(rows,date.fromisoformat(cutoff)+timedelta(days=1),selected)
            models[key]={'volumeGroup':volume_group,'stat':stat,'coefficients':[round(float(v),10) for v in coef],'trainingRows':n,'ridge':selected,'residualPairs':[[round(float(v),7) for v in pair] for pair in errors],'status':'shadow_only'}
            validation[key]=report
    if not models:raise ValueError('No eligible production candidates')
    return {'schemaVersion':1,'version':VERSION,'cutoff':cutoff,'trainedAt':datetime.now(timezone.utc).isoformat(),
            'volumeModelVersion':volume_model['version'],'volumeModelHash':hashlib.sha256(json.dumps(volume_model,sort_keys=True).encode()).hexdigest(),
            'sourceHashes':{'players':hashlib.sha256(json.dumps(dataset,sort_keys=True).encode()).hexdigest(),'history':hashlib.sha256(json.dumps(history,sort_keys=True).encode()).hexdigest()},
            'featureNames':FEATURES,'models':models,'validation':validation,'adopted':False,'hasEdge':False,
            'protocol':{'selectionSeasonsBefore':2025,'evaluationSeasonsFrom':2025,'rateRidgeGrid':RIDGES,'maxResidualPairs':MAX_ERRORS,'modelBounds':{'yardEfficiency':[-20,60],'yardTotals':[-999,999],'receptionEfficiency':[0,1]},
                        'uncertainty':'Paired out-of-sample workload and efficiency residual replay, individually centered and frozen before a whole test week; counts rounded, receptions bounded by simulated targets. Zero workloads do not define efficiency: their rate residual is zero.',
                        'referenceCutoffs':'Brier comparisons use pregame baseline-mean-derived half-lines, not historical sportsbook lines or prices.',
                        'qbAblation':'Refit workload and efficiency models without explicit earlier observed QB continuity/passing-efficiency signals, holding selected ridge settings fixed. Actual game passing-leader changes are outcome-only slices, never forecast inputs. Associations are not causal effects.',
                        'limits':'Retrospective source vintage; conditional on a recorded same-team appearance. Missing appearances remain unresolved. Unverified probabilities; no automatic promotion, obtainable-return claim or superiority to AI.'}}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--players',type=Path,default=ROOT/'assets/nfl-player-stats.json');parser.add_argument('--history',type=Path,default=ROOT/'assets/nfl-history.json');parser.add_argument('--volume',type=Path,default=ROOT/'assets/workload-model.json');parser.add_argument('--schedule',type=Path,required=True);parser.add_argument('--output',type=Path,default=ROOT/'assets/production-model.json');args=parser.parse_args()
    with args.schedule.open(encoding='utf-8-sig',newline='') as f:schedule=list(csv.DictReader(f))
    read=lambda p:json.loads(p.read_text(encoding='utf-8-sig'))
    result=run(read(args.players),read(args.history),schedule,read(args.volume));args.output.write_text(json.dumps(result,separators=(',',':'),allow_nan=False)+'\n',encoding='utf-8')
    print(json.dumps({g:{k:r.get(k) for k in ['recorded','unresolved','mae','baselineMae','referenceBrier','baselineReferenceBrier','interval80Coverage','clearedHistoricalGate','quarterbackAblation']} for g,r in result['validation'].items()}))


if __name__=='__main__':main()
