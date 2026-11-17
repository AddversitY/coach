"""Dated team-game EPA and pace evidence from free nflverse play-by-play."""
import csv,hashlib,json,math
from pathlib import Path
from datetime import date,datetime,timedelta,timezone
import numpy as np
import pandas as pd
import pyarrow.parquet as pq
from game_forecast import ROOT,TEAMS,team,before
VERSION='pregame-football-features-v1'
NAMES=['intercept','home','ownAdjustedOffense','opponentAdjustedAllowance','ownClockPace','opponentClockPace','ownPlayVolume','opponentPlayVolume','restDifference','priorPassingLeaderChange','lastPassingLeaderShare','quarterbackHistoryMissing','ownEfficiencyMissing','opponentEfficiencyMissing','paceHistoryMissing','restHistoryMissing']

def aggregate(history,cache):
    games={g['id']:g for g in history['games'] if g['date']<=history['cutoff']};rows=[];sources=[]
    columns=['game_id','season','week','posteam','defteam','play_type','epa','qb_kneel','qb_spike','qtr','drive','game_seconds_remaining','play_id','passer_player_id','passer_player_name','qb_dropback']
    for season in sorted({g['season'] for g in games.values()}):
        path=cache/f'play_by_play_{season}.parquet'
        if not path.exists():continue
        schema=set(pq.read_schema(path).names)
        if not {'game_id','posteam','defteam','epa','play_type'}.issubset(schema):continue
        frame=pq.read_table(path,columns=[k for k in columns if k in schema]).to_pandas()
        frame=frame[frame.game_id.isin(games)].copy();frame['posteam']=frame.posteam.map(team);frame['defteam']=frame.defteam.map(team)
        frame=frame[frame.play_type.isin(['pass','run'])&frame.epa.notna()&frame.posteam.isin(TEAMS)&frame.defteam.isin(TEAMS)].copy()
        for key in ['qb_kneel','qb_spike']:
            if key in frame:frame=frame[frame[key].fillna(0)!=1]
        frame=frame.sort_values(['game_id','play_id'])
        frame['paceDelta']=np.nan
        if {'drive','qtr','game_seconds_remaining'}.issubset(frame):
            previous=frame.groupby(['game_id','posteam','drive','qtr']).game_seconds_remaining.shift(1)
            delta=previous-frame.game_seconds_remaining
            frame['paceDelta']=delta.where((delta>=1)&(delta<=80))
        for (game_id,club),group in frame.groupby(['game_id','posteam']):
            g=games[game_id];opponent=team(g['away'] if team(g['home'])==club else g['home'])
            if club not in [team(g['home']),team(g['away'])] or set(group.defteam)!={opponent}:continue
            qbs=[]
            if {'passer_player_id','qb_dropback'}.issubset(group):
                drop=group[(group.qb_dropback==1)&group.passer_player_id.notna()]
                for ident,q in drop.groupby('passer_player_id'):
                    qbs.append({'id':str(ident),'name':str(q.passer_player_name.iloc[0]) if 'passer_player_name' in q else '', 'dropbacks':len(q)})
            qbs.sort(key=lambda q:(-q['dropbacks'],q['id']))
            rows.append({'gameId':game_id,'season':g['season'],'week':g['week'],'date':g['date'],'team':club,'opponent':opponent,'plays':len(group),'epaSum':round(float(group.epa.sum()),6),'paceIntervals':int(group.paceDelta.notna().sum()),'paceSeconds':round(float(group.paceDelta.sum()),6),'passers':qbs})
        sources.append({'season':season,'url':f'https://github.com/nflverse/nflverse-data/releases/download/pbp/play_by_play_{season}.parquet','sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
    if len(rows)<1000:raise ValueError('Insufficient sourced team-game efficiency evidence')
    rows.sort(key=lambda r:(r['season'],r['week'],r['date'],r['team']))
    return {'schemaVersion':1,'version':VERSION,'cutoff':history['cutoff'],'retrievedAt':datetime.now(timezone.utc).isoformat(),'historyHash':hashlib.sha256(json.dumps(history,sort_keys=True).encode()).hexdigest(),'source':'nflverse play-by-play','license':'CC BY 4.0','sourceUrl':'https://github.com/nflverse/nflverse-data/releases/tag/pbp','sources':sources,'rows':rows,'notice':'Reconstructed dated observations, not archived publication vintages. Clock pace uses within-drive, same-quarter snap gaps of 1–80 game-clock seconds; it is not neutral-situation pace. No upcoming starter or participation is inferred.'}

def state_for(team_rows,prior_games):
    if not prior_games:return None
    latest=max(g['date'] for g in prior_games);as_of=date.fromisoformat(latest)+timedelta(days=1)
    recent=[r for r in team_rows if 0<(as_of-date.fromisoformat(r['date'])).days<=730]
    if not recent:return None
    x=[];y=[];w=[]
    for r in recent:
        row=np.zeros(65);row[0]=1;row[1+TEAMS.index(r['team'])]=1;row[33+TEAMS.index(r['opponent'])]=1
        x.append(row);y.append(r['epaSum']/r['plays']);w.append(r['plays']*.5**((as_of-date.fromisoformat(r['date'])).days/84))
    x=np.array(x);y=np.array(y);w=np.array(w);penalty=np.full(65,200.);penalty[0]=0
    coefficients=np.linalg.solve(x.T@(w[:,None]*x)+np.diag(penalty),x.T@(w*y))
    pace_n=sum(r['paceIntervals'] for r in recent);league_pace=sum(r['paceSeconds'] for r in recent)/pace_n if pace_n else 30.
    league_plays=sum(r['plays'] for r in recent)/len(recent)
    profiles={}
    for club in TEAMS:
        own=sorted([r for r in recent if r['team']==club],key=lambda r:(r['date'],r['gameId']),reverse=True)
        weights=[.5**((as_of-date.fromisoformat(r['date'])).days/84) for r in own]
        plays=sum(v*r['plays'] for v,r in zip(weights,own));intervals=sum(v*r['paceIntervals'] for v,r in zip(weights,own));game_weight=sum(weights)
        qb=[]
        for r in own:
            if (as_of-date.fromisoformat(r['date'])).days>180:continue
            p=r['passers']
            if not p or len(p)>1 and p[0]['dropbacks']==p[1]['dropbacks']:break
            qb.append({**p[0],'date':r['date'],'share':p[0]['dropbacks']/sum(passer['dropbacks'] for passer in p)})
            if len(qb)==2:break
        profiles[club]={'offense':float(coefficients[1+TEAMS.index(club)]),'allowance':float(coefficients[33+TEAMS.index(club)]),'pace':(sum(v*r['paceSeconds'] for v,r in zip(weights,own))+50*league_pace)/(intervals+50),'plays':(sum(v*r['plays'] for v,r in zip(weights,own))+3*league_plays)/(game_weight+3),'efficiencyMissing':plays<100,'paceMissing':intervals<20,'qbMissing':len(qb)<2,'qbChanged':len(qb)==2 and qb[0]['id']!=qb[1]['id'],'qbShare':qb[0]['share'] if qb else .9,'lastObservedQB':qb[0] if qb else None,'lastGame':own[0]['date'] if own else None,'games':len(own)}
    return {'asOf':latest,'leaguePace':league_pace,'leaguePlays':league_plays,'profiles':profiles}

def vector(state,own,opponent,day,home=False):
    if state is None:raise ValueError('Missing earlier efficiency state')
    a,b=[state['profiles'][t] for t in [own,opponent]]
    rest=[]
    for p in [a,b]:
        days=(date.fromisoformat(day)-date.fromisoformat(p['lastGame'])).days if p['lastGame'] else 999
        rest.append(days if 1<=days<=30 else None)
    x=[1.,float(home),a['offense']/.1,b['allowance']/.1,(a['pace']-state['leaguePace'])/5,(b['pace']-state['leaguePace'])/5,(a['plays']-state['leaguePlays'])/10,(b['plays']-state['leaguePlays'])/10,max(-1,min(1,(rest[0]-rest[1])/7)) if None not in rest else 0.,float(a['qbChanged']), (a['qbShare']-.9)*5,float(a['qbMissing']),float(a['efficiencyMissing']),float(b['efficiencyMissing']),float(a['paceMissing'] or b['paceMissing']),float(None in rest)]
    return [float(v) for v in x]

if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser();p.add_argument('--cache',type=Path,default=ROOT/'model/.cache');p.add_argument('--output',type=Path,default=ROOT/'assets/team-efficiency.json');a=p.parse_args()
    result=aggregate(json.loads((ROOT/'assets/nfl-history.json').read_text(encoding='utf-8-sig')),a.cache);a.output.write_text(json.dumps(result,separators=(',',':'),allow_nan=False)+'\n',encoding='utf-8');print(json.dumps({'teamGames':len(result['rows']),'sources':len(result['sources']),'cutoff':result['cutoff']}))
