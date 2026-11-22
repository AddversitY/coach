import json, math, random
from collections import defaultdict
S=json.load(open('evalwork/scored.json'))
# dedupe: prefer history row (has open line)
seen={}
for o in S:
    k=(o['playerId'],o['gameId'],o['metric'])
    if k in seen and seen[k]['src']=='history': continue
    if k in seen and o['src']!='history': continue
    seen[k]=o
U=list(seen.values())
print('rows',len(S),'unique',len(U),'overlap',len(S)-len(U))
def cl(p): return min(max(p,1e-4),1-1e-4)
def sc(rows,key):
    n=len(rows); b=sum((cl(r[key])-r['hit'])**2 for r in rows)/n
    l=-sum(math.log(cl(r[key])) if r['hit'] else math.log(1-cl(r[key])) for r in rows)/n
    return b,l
keys=[('noVig','Book no-vig close'),('model','Coach model alone'),('evenCard','Coach card (50% anchor)'),('served','Coach as served (5% pooled)')]
def table(rows,label):
    n=len(rows); hits=sum(r['hit'] for r in rows)
    line=f"{label:34s} n={n:4d} games={len({r['gameId'] for r in rows}):3d} over={hits/n:.3f} "
    for k,_ in keys:
        b,l=sc(rows,k); line+=f"| {k} B={b:.4f} L={l:.4f} "
    line+=f"| meanModel={sum(r['model'] for r in rows)/n:.3f} meanBook={sum(r['noVig'] for r in rows)/n:.3f}"
    print(line)
groups=defaultdict(list)
for r in U:
    groups[('all',)].append(r); groups[('m',r['metric'])].append(r); groups[('s',r['season'])].append(r)
    groups[('src',r['src'])].append(r); groups[('ms',r['metric'],r['season'])].append(r)
for k in sorted(groups,key=str): table(groups[k],str(k))
# bootstrap diff model-book brier, overall and per market
random.seed(1)
def boot(rows,a,b,B=2000):
    d=[(cl(r[a])-r['hit'])**2-(cl(r[b])-r['hit'])**2 for r in rows]; n=len(d)
    ms=sorted(sum(random.choice(d) for _ in range(n))/n for _ in range(B))
    return sum(d)/n, ms[int(.025*B)], ms[int(.975*B)]
for k in [('all',),('m','passing_yards'),('m','rushing_yards'),('m','receiving_yards'),('m','receptions')]:
    print('boot model-book',k, ['%.4f'%x for x in boot(groups[k],'model','noVig')], ' served-book',['%.4f'%x for x in boot(groups[k],'served','noVig')])
# agreement: when model disagrees with book by >5pts, who was right
for thr in (0.05,0.10):
    sub=[r for r in U if abs(r['model']-r['noVig'])>thr]
    if sub: print('gap>',thr,len(sub),'model side right',sum((r['model']>r['noVig'])==r['hit'] for r in sub)/len(sub), 'B model/book',sc(sub,'model')[0],sc(sub,'noVig')[0])
# open vs close (history only)
H=[r for r in S if r['src']=='history' and r.get('openLine') is not None]
mv=[r for r in H if r['openLine']!=r['line']]
print('history with open',len(H),'moved',len(mv),'mean abs move',sum(abs(r['line']-r['openLine']) for r in H)/len(H))
tow=[r for r in mv if (r['line']>r['openLine'])==(r['actual']>r['openLine'])]
print('close moved toward result (vs open line)',len(tow),'/',len(mv))
by=defaultdict(list)
for r in H: by[r['metric']].append(r)
for m,rs in by.items():
    mvm=[r for r in rs if r['openLine']!=r['line']]
    t=[r for r in mvm if (r['line']>r['openLine'])==(r['actual']>r['openLine'])]
    oo=[r for r in rs if r['actual']!=r['openLine']]
    # MAE of open line vs close line as predictor of actual
    print(m,len(rs),'moved',len(mvm),'toward',len(t),'meanabs move %.2f'%(sum(abs(r['line']-r['openLine']) for r in rs)/len(rs)),
      'MAE open %.2f close %.2f'%(sum(abs(r['actual']-r['openLine']) for r in rs)/len(rs),sum(abs(r['actual']-r['line']) for r in rs)/len(rs)))
print('MAE all open %.2f close %.2f'%(sum(abs(r['actual']-r['openLine']) for r in H)/len(H),sum(abs(r['actual']-r['line']) for r in H)/len(H)))
# books count
print('history books', sorted(set(r['books'] for r in S if r['src']=='history')), 'probs fair_books', sorted(set(r['books'] for r in S if r['src']=='probs')))
print('history hold mean', sum(r['hold'] for r in S if r['src']=='history')/len([r for r in S if r['src']=='history']))
# overlap agreement
ov=defaultdict(dict)
for r in S: ov[(r['playerId'],r['gameId'],r['metric'])][r['src']]=r
both=[v for v in ov.values() if len(v)==2]
if both: print('overlap',len(both),'same line',sum(v['history']['line']==v['probs']['line'] for v in both),'mean abs novig diff %.3f'%(sum(abs(v['history']['noVig']-v['probs']['noVig']) for v in both)/len(both)))
