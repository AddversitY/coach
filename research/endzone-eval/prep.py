import json, glob, os
RAW='/cursor/stores/store-007196c2-0690-4d6f-bc64-c5a888d555a2/endzone-raw'
M={'player_pass_yds':'passing_yards','player_rush_yds':'rushing_yards','player_reception_yds':'receiving_yards','player_receptions':'receptions'}
d=json.load(open('coach-eval/assets/nfl-player-stats.json')); K=d['statKeys']
rows={}
sched={x['id']:x for x in json.load(open('coach-eval/assets/nfl-history.json'))['games']}
for r in d['rows']:
    s=dict(zip(K,r['stats'])); rows[(r['playerId'],r['season'],r['week'],r['seasonType'])]=(r,s)
def find(pid,gid):
    sea,wk=int(gid[:4]),int(gid[5:7])
    for st in ('REG','POST'):
        if (pid,sea,wk,st) in rows: return rows[(pid,sea,wk,st)],sea,wk,st
    return None,sea,wk,None
def imp(a):
    return 100/(a+100) if a>0 else -a/(-a+100)
out=[]; skipped={'no_row':0,'no_odds':0,'push':0,'no_fair':0}
# history
for f in glob.glob(f'{RAW}/hist_*.json'):
    h=json.load(open(f))['data']; m=M[h['market']]
    for g in h['games']:
        rs,sea,wk,st=find(h['player_id'],g['game_id'])
        if rs is None or rs[1].get(m) is None: skipped['no_row']+=1; continue
        if g.get('over_odds') is None or g.get('under_odds') is None: skipped['no_odds']+=1; continue
        po,pu=imp(g['over_odds']),imp(g['under_odds']); nv=po/(po+pu)
        val=rs[1][m]
        if val==g['line']: skipped['push']+=1; continue
        out.append(dict(src='history',playerId=h['player_id'],metric=m,gameId=g['game_id'],season=sea,week=wk,stype=st,date=rs[0]['date'],
            team=rs[0]['team'],opponent=rs[0]['opponent'],line=g['line'],openLine=g.get('open_line'),books=g.get('books'),noVig=nv,hold=po+pu-1,
            actual=val,apiActual=g.get('actual'),hit=val>g['line']))
# probabilities
for f in glob.glob(f'{RAW}/probs_*.json'):
    p=json.load(open(f))['data']
    for pr in p['props']:
        if pr['market'] not in M: continue
        m=M[pr['market']]
        cands=[l for l in pr['lines'] if l['line'] is not None and l['over'].get('fair_prob') is not None and l['under'].get('fair_prob') is not None]
        if not cands: skipped['no_fair']+=1; continue
        best=sorted(cands,key=lambda l:(-(l['fair_books'] or 0), l['line']!=pr['consensus_line']))[0]
        rs,sea,wk,st=find(pr['player_id'],p['game_id'])
        if rs is None or rs[1].get(m) is None: skipped['no_row']+=1; continue
        fo,fu=best['over']['fair_prob'],best['under']['fair_prob']; nv=fo/(fo+fu)
        val=rs[1][m]
        if val==best['line']: skipped['push']+=1; continue
        out.append(dict(src='probs',playerId=pr['player_id'],metric=m,gameId=p['game_id'],season=sea,week=wk,stype=st,date=rs[0]['date'],
            team=rs[0]['team'],opponent=rs[0]['opponent'],line=best['line'],books=best['fair_books'],noVig=nv,actual=val,hit=val>best['line']))
os.makedirs('/workspace/evalwork',exist_ok=True)
json.dump(out,open('/workspace/evalwork/props.json','w'))
from collections import Counter
print(len(out),skipped,Counter((o['src'],o['season'],o['stype']) for o in out),Counter(o['metric'] for o in out))
# sanity actual vs api
mm=[o for o in out if o['src']=='history' and o.get('apiActual') is not None]
print('api actual mismatch',sum(1 for o in mm if abs(o['apiActual']-o['actual'])>0.01),'of',len(mm))
