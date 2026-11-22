import json, math, random
from collections import defaultdict
random.seed(7)
P=json.load(open('/workspace/pubbias/props.json')); GM=json.load(open('/workspace/pubbias/games.json'))
def cl(p): return min(max(p,1e-4),1-1e-4)
def lg(p): p=cl(p); return math.log(p/(1-p))
def sg(z): return 1/(1+math.exp(-z))
def am2dec(a): return 1+a/100 if a>0 else 1+100/(-a)
def imp(a): return 100/(a+100) if a>0 else -a/(-a+100)
LAM=5.0; MINACT=30
def fit(train):
    act=[r for r in train if r['x']!=0]
    if len(act)<MINACT: return 0.0
    b=0.0
    for _ in range(25):
        g=2*LAM*b; h=2*LAM
        for r in act:
            p=sg(lg(r['nv'])+b*r['x']); g+=(p-r['hit'])*r['x']; h+=p*(1-p)*r['x']**2
        b-=g/h
    return b
def walk(rows):
    rows=sorted(rows,key=lambda r:(r['season'],r['week']))
    keys=sorted({(r['season'],r['week']) for r in rows}); bycut={}
    for k in keys:
        tr=[r for r in rows if (r['season'],r['week'])<k]
        bycut[k]=fit(tr)
    for r in rows:
        r['b']=bycut[(r['season'],r['week'])]; r['p']=sg(lg(r['nv'])+r['b']*r['x'])
    return rows
def brier(rows,k): return sum((cl(r[k])-r['hit'])**2 for r in rows)/len(rows)
def boot(rows,B=1000):
    cl_={}
    for r in rows: cl_.setdefault(r['cid'],[]).append((cl(r['p'])-r['hit'])**2-(cl(r['nv'])-r['hit'])**2)
    cs=list(cl_.values()); n=len(rows); ms=[]
    for _ in range(B):
        s=0; m=0
        for _ in range(len(cs)):
            c=random.choice(cs); s+=sum(c); m+=len(c)
        ms.append(s/m)
    ms.sort(); return ms[int(.025*B)],ms[int(.975*B)]
def roi(rows,side_fn):
    bets=[(r,side_fn(r)) for r in rows]; bets=[(r,s) for r,s in bets if s is not None]
    if not bets: return 0,None
    pl=0
    for r,s in bets:
        win=(r['hit']==1) if s=='yes' else (r['hit']==0)
        d=r['decYes'] if s=='yes' else r['decNo']
        pl+= (d-1) if win else -1
    return len(bets),pl/len(bets)
OUT=[]
def pr(s=''): print(s); OUT.append(s)
NT=0
def report(name,rows,antipub,seasons,desc):
    global NT; NT+=1
    rows=walk([dict(r) for r in rows])
    pr(f'--- {name}: {desc}')
    res={}
    for s in seasons:
        R=[r for r in rows if r['season']==s]
        if not R: pr(f'  {s}: no rows'); continue
        act=[r for r in R if r['x']!=0]
        bp,bn=brier(R,'p'),brier(R,'nv'); lo,hi=boot(R) if any(r['b']!=0 for r in R) else (0.0,0.0)
        line=f'  {s}: all n={len(R)} games={len({r["cid"] for r in R})} | Brier debiased={bp:.4f} books noVig={bn:.4f} diff={bp-bn:+.4f} [95% CI {lo:+.4f},{hi:+.4f}] | mean coef b={sum(r["b"] for r in act)/len(act) if act else 0:+.3f}'
        pr(line)
        if act:
            h=sum(r['hit'] for r in act)/len(act); im=sum(r['nv'] for r in act)/len(act)
            se=math.sqrt(max(h*(1-h),1e-9)/len(act)); z=(h-im)/se if se>0 else 0
            n1,r1=roi(act,lambda r:antipub); n2,r2=roi(act,lambda r: None if r['b']==0 else ('yes' if r['p']>r['nv'] else 'no'))
            small=' (SMALL SAMPLE)' if len(act)<200 else ''
            pr(f'        signal group n={len(act)}{small} event-rate={h:.3f} implied={im:.3f} diff={h-im:+.3f} [95% CI {h-im-1.96*se:+.3f},{h-im+1.96*se:+.3f}] z={z:+.2f} | ROI bet anti-public side ({antipub}) n={n1} {r1*100:+.1f}% | ROI walk-forward rule n={n2} '+(f'{r2*100:+.1f}%' if r2 is not None else 'no bets (no coef yet)'))
        res[s]=(bp,bn)
    passed=all(s in res and res[s][0]<res[s][1] for s in (2025,2026))
    pr(f'  PASS both 2025 & 2026: {"YES" if passed else "no"}')
    return passed
summary=[]
# ---------- PROPS ----------
def P_rows(xf,filt=lambda r:True):
    out=[]
    for r in P:
        if not filt(r): continue
        x=xf(r)
        out.append(dict(season=r['season'],week=r['week'],nv=r['nv'],hit=r['hit'],x=x,cid=r['gameId'] or f"{r['season']}_{r['week']}_{r['team']}",decYes=r['overDec'],decNo=r['underDec']))
    return out
S=(2024,2025,2026)
pr('=== PLAYER PROPS (yards + receptions), event = OVER hits; books no-vig = consensus close ===')
for s in S:
    R=[r for r in P if r['season']==s]; pr(f'  {s}: n={len(R)} over-rate={sum(r["hit"] for r in R)/len(R):.3f} mean noVig over={sum(r["nv"] for r in R)/len(R):.3f} Brier noVig={sum((r["nv"]-r["hit"])**2 for r in R)/len(R):.4f}  sources: '+str({k:sum(1 for r in R if r["src"]==k) for k in ("ez_hist","ez_probs","propline")}))
T=[
 ('P1 overall over/under bias',lambda r:1,lambda r:True,'no','all props; public is said to like overs'),
 ('P2 star-player overs',lambda r:1 if r['star']==1 else 0,lambda r:True,'no','star = prior-season fantasy PPR top-12 QB/TE, top-24 RB/WR (nflverse, point-in-time)'),
 ('P3 first-round-pick overs',lambda r:r['r1'],lambda r:True,'no','player was a 1st-round draft pick (hype proxy)'),
 ('P4 popular-team player overs',lambda r:r['popteam'],lambda r:True,'no','team in a-priori public list DAL GB PIT KC SF PHI'),
 ('P5 prime-time overs',lambda r:r.get('prime') or 0,lambda r:True,'no','Thu/Mon or Sat/Sun night kickoff'),
 ('P6 favored-team player overs',lambda r:r.get('fav') or 0,lambda r:True,'no','player\'s team favored by closing spread'),
 ('P7 composite public score',lambda r:(1 if r['star']==1 else 0)+r['popteam']+(r.get('prime') or 0)+(r.get('fav') or 0),lambda r:True,'no','x = count of P2,P4,P5,P6 flags (0-4)'),
 ('P8 line moved from open',lambda r:(1 if r['line']>r['openLine'] else -1 if r['line']<r['openLine'] else 0),lambda r:r['src']=='ez_hist' and r.get('openLine') is not None,'no','EndzoneAPI history rows only (2024-25): +1 line moved up (toward over/public), -1 down'),
]
for name,xf,filt,anti,desc in T:
    summary.append((name,report(name,P_rows(xf,filt),anti,S,desc)))
# P9 soft vs sharp (2026 PropLine only)
pr('--- P9 soft books vs Pinnacle disagreement (PropLine sample, 2026 weeks 2-3 only)')
NT+=1
Q=[r for r in P if r['src']=='propline' and r.get('sharp') is not None and r.get('soft') is not None]
if Q:
    bs=sum((r['soft']-r['hit'])**2 for r in Q)/len(Q); bp_=sum((r['sharp']-r['hit'])**2 for r in Q)/len(Q)
    pr(f'  n={len(Q)} Brier soft-books mean={bs:.4f} Pinnacle alone={bp_:.4f}')
    for thr in (0.02,0.04):
        d=[r for r in Q if abs(r['sharp']-r['soft'])>=thr]
        if d:
            right=sum((r['sharp']>r['soft'])==bool(r['hit']) for r in d)/len(d)
            n,ro=roi(P_rows(lambda r:1,lambda r,dd=d: r in dd),lambda r:None)
            # bet the side Pinnacle prefers at -110
            pl=sum((0.909 if (r['sharp']>r['soft'])==bool(r['hit']) else -1) for r in d)/len(d)
            pr(f'  gap>={thr}: n={len(d)} (SMALL SAMPLE) Pinnacle side right {right:.3f} | ROI betting Pinnacle side at -110 {pl*100:+.1f}%')
    wk2=[r for r in Q if r['week']==2]; wk3=[r for r in Q if r['week']==3]
    # walk-forward: blend weight on Pinnacle chosen on week 2, scored on week 3
    best=min((sum(((1-w)*r['soft']+w*r['sharp']-r['hit'])**2 for r in wk2)/len(wk2),w) for w in [i/10 for i in range(11)])
    w=best[1]; b3=sum(((1-w)*r['soft']+w*r['sharp']-r['hit'])**2 for r in wk3)/len(wk3); s3=sum((r['soft']-r['hit'])**2 for r in wk3)/len(wk3)
    pr(f'  walk-forward: Pinnacle weight picked on week 2 = {w}; week 3 Brier blend={b3:.4f} vs soft books={s3:.4f} (n={len(wk3)})')
    pr('  PASS both 2025 & 2026: no (no 2025 two-book data; one season, two weeks)')
summary.append(('P9 soft vs sharp books',False))
# ---------- GAMES ----------
POP={'DAL','GB','PIT','KC','SF','PHI'}
pr(''); pr('=== GAME LINES (nflverse closing lines + prices, 2015-2026 regular season), walk-forward from 2015 ===')
def nvpair(a,b): pa,pb=imp(a),imp(b); return pa/(pa+pb)
G=[g for g in GM if g['homeSpreadOdds'] is not None]
def grow(g,nv,hit,x,dy,dn):
    return dict(season=g['season'],week=g['week'],nv=nv,hit=hit,x=x,cid=f"{g['season']}_{g['week']}_{g['home']}",decYes=dy,decNo=dn)
def totals(xf):
    out=[]
    for g in G:
        if g['overOdds'] is None: continue
        t=g['homeScore']+g['awayScore']
        if t==g['totalLine']: continue
        out.append(grow(g,nvpair(g['overOdds'],g['underOdds']),int(t>g['totalLine']),xf(g),am2dec(g['overOdds']),am2dec(g['underOdds'])))
    return out
def fav_cover(xf,filt=lambda g:True):
    out=[]
    for g in G:
        if g['spreadLine']==0 or not filt(g): continue
        m=g['homeScore']-g['awayScore']
        if m==g['spreadLine']: continue
        homecov=int(m>g['spreadLine']); hf=g['spreadLine']>0
        nvh=nvpair(g['homeSpreadOdds'],g['awaySpreadOdds'])
        if hf: out.append(grow(g,nvh,homecov,xf(g),am2dec(g['homeSpreadOdds']),am2dec(g['awaySpreadOdds'])))
        else: out.append(grow(g,1-nvh,1-homecov,xf(g),am2dec(g['awaySpreadOdds']),am2dec(g['homeSpreadOdds'])))
    return out
def pop_cover():
    out=[]
    for g in G:
        hp,ap=g['home'] in POP,g['away'] in POP
        if hp==ap: continue
        m=g['homeScore']-g['awayScore']
        if m==g['spreadLine']: continue
        homecov=int(m>g['spreadLine']); nvh=nvpair(g['homeSpreadOdds'],g['awaySpreadOdds'])
        if hp: out.append(grow(g,nvh,homecov,1,am2dec(g['homeSpreadOdds']),am2dec(g['awaySpreadOdds'])))
        else: out.append(grow(g,1-nvh,1-homecov,1,am2dec(g['awaySpreadOdds']),am2dec(g['homeSpreadOdds'])))
    return out
def ml_fav():
    out=[]
    for g in G:
        if g['homeMoneyline'] is None or g['homeScore']==g['awayScore']: continue
        nvh=nvpair(g['homeMoneyline'],g['awayMoneyline']); hw=int(g['homeScore']>g['awayScore'])
        if nvh>=0.5: out.append(grow(g,nvh,hw,1,am2dec(g['homeMoneyline']),am2dec(g['awayMoneyline'])))
        else: out.append(grow(g,1-nvh,1-hw,1,am2dec(g['awayMoneyline']),am2dec(g['homeMoneyline'])))
    return out
GS=(2025,2026)
gt=[
 ('G1 overall over bias (totals)',totals(lambda g:1),'no','all games'),
 ('G2 prime-time overs',totals(lambda g:g['prime']),'no','Thu/Mon/Sat-Sun night'),
 ('G3 popular-team game overs',totals(lambda g:int(g['home'] in POP or g['away'] in POP)),'no','DAL GB PIT KC SF PHI involved'),
 ('G4 favorites cover (spread)',fav_cover(lambda g:1),'no','all non-pick games, event = favorite covers'),
 ('G5 big favorites cover (7+)',fav_cover(lambda g:int(abs(g['spreadLine'])>=7)),'no','x=1 when spread >= 7'),
 ('G6 prime-time favorites cover',fav_cover(lambda g:g['prime']),'no','x=1 prime-time'),
 ('G7 road favorites cover',fav_cover(lambda g:int(g['spreadLine']<0)),'no','x=1 favorite is the away team'),
 ('G8 popular team covers',pop_cover(),'no','games with exactly one public team; event = public team covers'),
 ('G9 moneyline favorites win',ml_fav(),'no','favorite-longshot bias check'),
]
for name,rows,anti,desc in gt:
    summary.append((name,report(name,rows,anti,(2023,2024,2025,2026),desc)))
pr(''); pr(f'TESTS RUN: {NT} (Bonferroni 5% family-wise threshold |z| >= {abs(__import__("statistics").NormalDist().inv_cdf(0.025/NT)):.2f})')
pr('PASSED (debiased Brier below books no-vig in BOTH 2025 and 2026): '+(', '.join(n for n,p in summary if p) or 'none'))
open('/workspace/pubbias/out.txt','w').write('\n'.join(OUT))
