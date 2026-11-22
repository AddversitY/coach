import json, time, os
from ez import call, RAW
g=json.load(open('coach-eval/assets/nfl-history.json'))['games']
by={}
for x in g: by.setdefault((x['season'],x['week']),[]).append(x['id'])
pick=[]
for w in range(2,19):
    ids=sorted(by[(2025,w)]); pick.append(ids[len(ids)//3])
    if w in (6,8,10,12,13,14,15,16): pick.append(ids[(2*len(ids))//3])
for w in (13,14,15,16):
    ids=sorted(by[(2024,w)]); pick.append(ids[len(ids)//2])
print(len(pick))
for gid in pick:
    f=f'probs_{gid}.json'
    if os.path.exists(os.path.join(RAW,f)): continue
    r=call('get_prop_probabilities',{'game_id':gid},save=f)
    if '_http' in r: print('ERR',gid,r); continue
    print(gid,len(r['data']['props']),r['_hdrs'].get('x-credits-remaining'))
    if int(r['_hdrs'].get('x-credits-remaining',0))<=50: print('stop reserve'); break
    time.sleep(1.2)
