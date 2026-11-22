import json, time
from ez import call
P=[('00-0033106','player_pass_yds'),('00-0026498','player_pass_yds'),('00-0034869','player_pass_yds'),('00-0034855','player_pass_yds'),
('00-0032764','player_rush_yds'),('00-0034844','player_rush_yds'),('00-0036223','player_rush_yds'),('00-0038542','player_rush_yds'),
('00-0036900','player_reception_yds'),('00-0038543','player_reception_yds'),('00-0036963','player_reception_yds'),('00-0036322','player_reception_yds'),
('00-0037744','player_receptions'),('00-0039075','player_receptions'),('00-0037247','player_receptions')]
spent=0
for pid,m in P:
    for fd in ('2024-11-24','2024-12-08','2024-12-22','2025-09-01'):
        b={'player_id':pid,'market':m,'from_date':fd,'to_date':'2026-01-05','limit':200}
        e=call('get_prop_history',dict(b,estimate_only=True))
        if e.get('data',{}).get('credits')==10: break
    else:
        print('skip',pid,m); continue
    r=call('get_prop_history',b,save=f'hist_{pid}_{m}.json')
    if '_http' in r: print('ERR',pid,m,r); break
    g=r['data']['games']; spent+=10
    print(pid,m,fd,len(g),'truncated',r['data'].get('truncated'),'remaining',r['_hdrs'])
    time.sleep(1.2)
print('spent',spent)
