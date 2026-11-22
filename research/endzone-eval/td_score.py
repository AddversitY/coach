import json,math,random
T=json.load(open('evalwork/td_scored.json')); B=json.load(open('evalwork/td_book.json'))
cl=lambda p:min(max(p,1e-4),1-1e-4)
def sc(R,k):
    n=len(R); return (sum((cl(r[k])-r['hit'])**2 for r in R)/n, -sum(math.log(cl(r[k])) if r['hit'] else math.log(1-cl(r[k])) for r in R)/n)
for s in (2025,2026):
    R=[r for r in T if r['season']==s]
    print('repo check',s,len(R),{k:tuple(round(x,4) for x in sc(R,k)) for k in ('record','poisson','inflated')}, 'mean poisson %.3f actual %.3f'%(sum(r['poisson'] for r in R)/len(R),sum(r['hit'] for r in R)/len(R)))
idx={(r['playerId'],r['season'],r['week']):r for r in T}
J=[];miss=0
for b in B:
    r=idx.get((b['playerId'],b['season'],b['week']))
    if r is None: miss+=1; continue
    J.append({**r,**{'noVig':b['noVig'],'implied':b['implied'],'gameId':b['gameId'],'fairBooks':b['fairBooks']}})
print('book props',len(B),'joined',len(J),'no forecast',miss)
keys=['noVig','record','poisson','inflated','poissonBook','inflatedBook']
random.seed(2)
for label,cond in (('2025',lambda r:r['season']==2025),('late 2024',lambda r:r['season']==2024),('both',lambda r:True)):
    R=[r for r in J if cond(r) and r['noVig'] is not None]
    n=len(R)
    print(f'\n{label}: two-sided no-vig props n={n} games={len({r["gameId"] for r in R})} scored={sum(r["hit"] for r in R)/n:.3f} meanBook={sum(r["noVig"] for r in R)/n:.3f}')
    for k in keys:
        b,l=sc(R,k); print(f'  {k:13s} Brier {b:.4f}  LogLoss {l:.4f}  mean {sum(r[k] for r in R)/n:.3f}')
    for k in ('record','poissonBook','inflatedBook'):
        d=[(cl(r[k])-r['hit'])**2-(cl(r['noVig'])-r['hit'])**2 for r in R]
        bs=sorted(sum(random.choice(d) for _ in range(n))/n for _ in range(2000))
        print(f'  boot {k}-book Brier diff {sum(d)/n:+.4f} [{bs[50]:+.4f},{bs[1949]:+.4f}]')
    # one-sided supplemental
    R1=[r for r in J if cond(r) and r['noVig'] is None and r['implied'] is not None]
    if R1:
        n1=len(R1); print(f'  one-sided (margin left in) n={n1} scored={sum(r["hit"] for r in R1)/n1:.3f} meanImplied={sum(r["implied"] for r in R1)/n1:.3f}')
        for k in ('implied','record','poisson','inflated'):
            b,l=sc(R1,k); print(f'    {k:10s} Brier {b:.4f} LogLoss {l:.4f}')
