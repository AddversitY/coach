# Build private research datasets for public-bias tests (box only; never commit).
import json, glob, csv, math
from collections import defaultdict
RAW='/cursor/stores/store-007196c2-0690-4d6f-bc64-c5a888d555a2/endzone-raw'
A='/workspace/coach-eval/assets'
M={'player_pass_yds':'passing_yards','player_rush_yds':'rushing_yards','player_reception_yds':'receiving_yards','player_receptions':'receptions'}
st=json.load(open(f'{A}/nfl-player-stats.json')); K=st['statKeys']
rows={}; season_pts=defaultdict(float); season_games=defaultdict(int); pos={}
def ppr(s):
    g=lambda k: s.get(k) or 0
    return .04*g('passing_yards')+4*g('passing_tds')-2*g('passing_interceptions')+.1*g('rushing_yards')+6*g('rushing_tds')+.1*g('receiving_yards')+6*g('receiving_tds')+g('receptions')-2*(g('rushing_fumbles_lost')+g('receiving_fumbles_lost'))
wk_pts=defaultdict(list)  # (pid,season)->[(week,pts)]
for r in st['rows']:
    s=dict(zip(K,r['stats'])); rows[(r['playerId'],r['season'],r['week'])]=(r,s); pos[r['playerId']]=r['position']
    if r['seasonType']=='REG':
        p=ppr(s); season_pts[(r['playerId'],r['season'])]+=p; wk_pts[(r['playerId'],r['season'])].append((r['week'],p))
# prior-season positional rank (point-in-time safe)
rank={}
by=defaultdict(list)
for (pid,sea),p in season_pts.items(): by[(sea,pos.get(pid))].append((p,pid))
for k,v in by.items():
    v.sort(reverse=True)
    for i,(p,pid) in enumerate(v): rank[(pid,k[0])]=i+1
STAR_N={'QB':12,'RB':24,'WR':24,'TE':12}
def star(pid,sea):
    r=rank.get((pid,sea-1)); n=STAR_N.get(pos.get(pid))
    if r is None or n is None: return None
    return int(r<=n)
def std_rank(pid,sea,wk):
    # season-to-date fantasy ppg among same-position players with >=2 games, weeks < wk (in-season popularity)
    return None
players={}
for r in csv.DictReader(open('/workspace/pubbias/players.csv')):
    players[r['gsis_id']]=r
def first_round(pid):
    r=players.get(pid); 
    if not r or not r['draft_round']: return 0
    return int(r['draft_round']=='1')
# schedule
G={}
for r in csv.DictReader(open('/workspace/pubbias/games.csv')):
    G[r['game_id']]=r
def prime(g):
    t=g['gametime'] or '00:00'
    return int(g['weekday'] in ('Monday','Thursday') or (g['weekday'] in('Sunday','Saturday') and t>='19:00'))
POP={'DAL','GB','PIT','KC','SF','PHI'}  # a-priori 'public' teams, fixed before testing
def am2dec(a): return 1+a/100 if a>0 else 1+100/(-a)
def imp(a): return 100/(a+100) if a>0 else -a/(-a+100)
def gameinfo(gid,team):
    g=G.get(gid)
    if not g: return {}
    home=g['home_team']==team
    sl=float(g['spread_line']) if g['spread_line'] else None  # home expected margin
    fav=None if sl is None or sl==0 else int((sl>0)==home)
    return dict(prime=prime(g),fav=fav,home=int(home),gid_ok=1)
def findgid(sea,wk,team):
    for gid,g in G.items():
        if int(g['season'])==sea and int(g['week'])==wk and team in(g['home_team'],g['away_team']): return gid
out=[]
def add(**o):
    o['pos']=pos.get(o['playerId']); o['star']=star(o['playerId'],o['season']); o['r1']=first_round(o['playerId'])
    gid=o.get('gameId') or findgid(o['season'],o['week'],o['team']); o['gameId']=gid
    o.update(gameinfo(gid,o['team'])); o['popteam']=int(o['team'] in POP)
    out.append(o)
for f in glob.glob(f'{RAW}/hist_*.json'):
    h=json.load(open(f))['data']; m=M[h['market']]
    for g in h['games']:
        sea,wk=int(g['game_id'][:4]),int(g['game_id'][5:7])
        rs=rows.get((h['player_id'],sea,wk))
        if not rs or rs[1].get(m) is None or g.get('over_odds') is None or g.get('under_odds') is None: continue
        val=rs[1][m]
        if val==g['line']: continue
        po,pu=imp(g['over_odds']),imp(g['under_odds'])
        add(src='ez_hist',playerId=h['player_id'],metric=m,gameId=g['game_id'],season=sea,week=wk,team=rs[0]['team'],line=g['line'],openLine=g.get('open_line'),
            nv=po/(po+pu),hit=int(val>g['line']),overDec=am2dec(g['over_odds']),underDec=am2dec(g['under_odds']),sharp=None,actual=val)
for f in glob.glob(f'{RAW}/probs_*.json'):
    p=json.load(open(f))['data']; gid=p['game_id']; sea,wk=int(gid[:4]),int(gid[5:7])
    for pr in p['props']:
        if pr['market'] not in M: continue
        m=M[pr['market']]
        c=[l for l in pr['lines'] if l['line'] is not None and l['over'].get('fair_prob') is not None and l['under'].get('fair_prob') is not None]
        if not c: continue
        b=sorted(c,key=lambda l:(-(l['fair_books'] or 0), l['line']!=pr['consensus_line']))[0]
        rs=rows.get((pr['player_id'],sea,wk))
        if not rs or rs[1].get(m) is None: continue
        val=rs[1][m]
        if val==b['line']: continue
        fo,fu=b['over']['fair_prob'],b['under']['fair_prob']
        ao,au=b['over'].get('avg_implied_prob'),b['under'].get('avg_implied_prob')
        add(src='ez_probs',playerId=pr['player_id'],metric=m,gameId=gid,season=sea,week=wk,team=rs[0]['team'],line=b['line'],openLine=None,
            nv=fo/(fo+fu),hit=int(val>b['line']),overDec=(1/ao if ao else 1.909),underDec=(1/au if au else 1.909),sharp=None,actual=val)
pc=json.load(open(f'{A}/prop-closes.json'))['rows']
for r in pc:
    if r['actual']==r['line']: continue
    nv=r['consensus'] if r['consensus'] is not None else r['prior']
    add(src='propline',playerId=r['playerId'],metric=r['metric'],gameId=None,season=r['season'],week=r['week'],team=r['team'],line=r['line'],openLine=None,
        nv=nv,hit=int(r['actual']>r['line']),overDec=1.909,underDec=1.909,sharp=r['pinnacle'],soft=r['consensus'],actual=r['actual'])
# dedupe (prefer ez_hist > ez_probs > propline)
pri={'ez_hist':0,'ez_probs':1,'propline':2}; seen={}
for o in out:
    k=(o['playerId'],o['season'],o['week'],o['metric'])
    if k not in seen or pri[o['src']]<pri[seen[k]['src']]: seen[k]=o
U=list(seen.values())
json.dump(U,open('/workspace/pubbias/props.json','w'))
from collections import Counter
print('props',len(out),'unique',len(U),Counter((o['src'],o['season']) for o in U))
print('star known',Counter((o['season'],o['star']) for o in U)); print('fav',Counter(o.get('fav') for o in U),'prime',Counter(o.get('prime') for o in U))
# game-level
cl=json.load(open(f'{A}/closing-lines.json'))['games']
gm=[]
idx={(int(g['season']),int(g['week']),g['home_team'],g['away_team']):g for g in G.values()}
for c in cl:
    g=idx.get((c['season'],c['week'],c['home'],c['away']))
    gm.append(dict(c, prime=prime(g) if g else None, gameId=g['game_id'] if g else None))
json.dump(gm,open('/workspace/pubbias/games.json','w'))
print('games',len(gm),'prime known',sum(1 for x in gm if x['prime'] is not None))
