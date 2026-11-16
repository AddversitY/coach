"""Error slices; development findings are isolated from retrospective later scores."""
import argparse,csv,json,math,hashlib
from pathlib import Path
from datetime import datetime,timezone
from forecast_lab import prepare,walk_forward,INCUMBENT,EVALUATION_START
from game_forecast import ROOT

def tags(rows):
    result={};history={};passers={}
    for season,week in sorted({(r['season'],r['week']) for r in rows}):
        group=[r for r in rows if (r['season'],r['week'])==(season,week)]
        for r in group:
            c=r['closing'];labels=['all_games']
            try:
                spread=abs(float(c['spread_line']));labels.append('large_favorite_7plus' if spread>=7 else 'close_spread_3orless' if spread<=3 else 'middle_spread')
            except (KeyError,TypeError,ValueError):pass
            changed=False;known=False;form=False
            for side in ['home','away']:
                club=r[side];qb=c.get(side+'_qb_id') or c.get(side+'_qb_name');prior=passers.get(club)
                if qb and prior:known=True;changed |= qb!=prior
                points=history.get(club,[])
                if len(points)>=6:form |= abs(sum(points[-3:])/3-sum(points[-6:-3])/3)>=7
            if known:labels.append('observed_qb_change' if changed else 'observed_qb_continuity')
            if form:labels.append('prior_scoring_swing_7plus')
            total=r['homeScore']+r['awayScore']
            labels.append('extreme_final_total' if total<=30 or total>=60 else 'ordinary_final_total')
            result[r['id']]=labels
        # No label from this week enters pregame recent-form state.
        for r in group:
            for side in ['home','away']:
                history.setdefault(r[side],[]).append(r[side+'Score'])
                qb=r['closing'].get(side+'_qb_id') or r['closing'].get(side+'_qb_name')
                if qb:passers[r[side]]=qb
    return result

def summarize(forecasts,labels):
    output={}
    for tag in sorted({t for r in forecasts for t in labels[r['id']]}):
        rows=[r for r in forecasts if tag in labels[r['id']]]
        markets={}
        for m in ['moneyline','spreads','totals']:
            values=[r['markets'][m] for r in rows if m in r['markets']]
            if not values:continue
            loss=lambda p,y:-math.log(max(1e-6,min(1-1e-6,p if y else 1-p)))
            markets[m]={'games':len(values),'brier':sum((v['p']-v['y'])**2 for v in values)/len(values),'marketBrier':sum((v['baseline']-v['y'])**2 for v in values)/len(values),'logLoss':sum(loss(v['p'],v['y']) for v in values)/len(values),'marketLogLoss':sum(loss(v['baseline'],v['y']) for v in values)/len(values)}
        output[tag]={'games':len(rows),'scoreMae':sum(r['absoluteError'] for r in rows)/len(rows),'markets':markets}
    return output

def run(history,schedule):
    rows=prepare(history,schedule);forecast=walk_forward(rows,INCUMBENT);labels=tags(rows)
    return {'schemaVersion':1,'version':'game-error-audit-v1','cutoff':history['cutoff'],'generatedAt':datetime.now(timezone.utc).isoformat(),'sourceHash':hashlib.sha256(json.dumps(history,sort_keys=True).encode()).hexdigest(),'scheduleHash':hashlib.sha256(json.dumps(schedule,sort_keys=True).encode()).hexdigest(),
        'development':summarize([r for r in forecast if r['season']<EVALUATION_START],labels),
        'retrospectiveLater':summarize([r for r in forecast if r['season']>=EVALUATION_START],labels),
        'protocol':{'developmentSeasonsBefore':EVALUATION_START,'warning':'Later seasons have appeared in prior reports and are NOT a fresh holdout. Future captured games are the untouched evaluation. Closing-line slices are market-reference diagnostics, not features. Observed QB changes and extreme final totals are outcome-only slices, not causal pregame adjustments.'}}

def main():
    p=argparse.ArgumentParser();p.add_argument('--schedule',type=Path,required=True);p.add_argument('--output',type=Path,default=ROOT/'assets/game-error-audit.json');a=p.parse_args()
    with a.schedule.open(encoding='utf-8-sig',newline='') as f:schedule=list(csv.DictReader(f))
    report=run(json.loads((ROOT/'assets/nfl-history.json').read_text(encoding='utf-8-sig')),schedule);a.output.write_text(json.dumps(report,separators=(',',':'))+'\n',encoding='utf-8')
    print(json.dumps({'development':{k:{'games':v['games'],'scoreMae':v['scoreMae']} for k,v in report['development'].items()}}))
if __name__=='__main__':main()
