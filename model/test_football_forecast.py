import copy,unittest
from datetime import date,timedelta
from football_features import state_for,vector,NAMES
from football_forecast import fold_inputs,walk,adjusted,residual_fit

class FootballTests(unittest.TestCase):
 def fixture(self,weeks=49):
  games=[];stats=[];day=date(2022,9,1)
  for week in range(1,weeks+1):
   for i in range(16):
    g=dict(id=f'{week}-{i}',season=2022,week=week,date=str(day+timedelta(days=7*week)),home='BUF',away='KC',homeScore=24+i%7,awayScore=20+i%5,neutral=False,closing={'home_moneyline':'-110','away_moneyline':'-110'})
    games.append(g)
    for club,opp in [('BUF','KC'),('KC','BUF')]:
     stats.append(dict(gameId=g['id'],season=2022,week=week,date=g['date'],team=club,opponent=opp,plays=60,epaSum=6 if club=='BUF' else -3,paceIntervals=40,paceSeconds=1200,passers=[dict(id=club,name=club,dropbacks=30)]))
  return games,stats
 def test_current_week_and_future_labels_roles_and_epa_cannot_change_prediction(self):
  games,stats=self.fixture();_,first=walk(games,stats);target=first[-32]
  changed=copy.deepcopy(games);changed_stats=copy.deepcopy(stats)
  for g in changed:
   if g['week']>=target['week']:g.update(homeScore=0,awayScore=70,closing={'home_moneyline':'-10000','away_moneyline':'10000'})
  for r in changed_stats:
   if r['week']>=target['week']:r.update(epaSum=999,paceSeconds=200,passers=[dict(id='future',name='Future starter',dropbacks=60)])
  _,second=walk(changed,changed_stats);other={r['id']:r for r in second}[target['id']]
  self.assertEqual(target['markets']['moneyline']['p'],other['markets']['moneyline']['p'])
  self.assertNotEqual(target['markets']['moneyline']['baseline'],other['markets']['moneyline']['baseline'])
 def test_date_guard_and_missing_role_flags(self):
  games,stats=self.fixture(3);day=games[-1]['date']
  games.append(dict(games[0],id='bad-date',date='2030-01-01'));stats.append(dict(stats[0],gameId='bad-date',date='2030-01-01',epaSum=99999))
  prior,state=fold_inputs(games,stats,2022,3,day)
  self.assertTrue(all(g['date']<day and g['week']<3 for g in prior))
  self.assertLess(state['profiles']['BUF']['offense'],1)
  missing=vector(state,'ARI','BUF',day)
  self.assertEqual(len(missing),len(NAMES));self.assertEqual(missing[11:13],[1,1]);self.assertEqual(missing[-1],1)
  self.assertIsNone(state['profiles']['ARI']['lastObservedQB'])
 def test_prior_role_change_is_observed_and_not_a_starter_claim(self):
  games,stats=self.fixture(2)
  for r in stats:
   if r['week']==2 and r['team']=='BUF':r['passers']=[dict(id='replacement',name='Replacement',dropbacks=30)]
  state=state_for([r for r in stats if r['gameId'].endswith('-0')],games)
  self.assertTrue(state['profiles']['BUF']['qbChanged']);self.assertFalse(state['profiles']['BUF']['qbMissing'])
  self.assertEqual(state['profiles']['BUF']['lastObservedQB']['name'],'Replacement')
  self.assertNotIn('confirmedUpcomingStarter',state['profiles']['BUF'])
 def test_residual_labels_require_prior_dates_and_corrections_are_bounded(self):
  with self.assertRaises(ValueError):residual_fit([{'date':'2026-11-16'}]*100,date(2026,11,16))
  x=[[1]*16,[1]*16]
  self.assertEqual(adjusted([64,2],x,[100]*16),[65,9])
  self.assertEqual(adjusted([2,64],x,[-100]*16),[0,57])

if __name__=='__main__':unittest.main()
