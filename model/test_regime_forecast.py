import copy,unittest
from datetime import date,timedelta
from error_audit import tags
from regime_forecast import weights,walk,SPEC
class RegimeTests(unittest.TestCase):
 def test_weight_mass_and_effective_sample_guard(self):
  w=weights([[40,3]]*150,[23,17]);self.assertAlmostEqual(sum(w),1);self.assertTrue(all(abs(v-1/150)<1e-12 for v in w))
  w=weights([[40,3]]+[[200,100]]*119,[23,17]);self.assertTrue(all(abs(v-1/120)<1e-12 for v in w))
  with self.assertRaises(ValueError):weights([[40,3]]*119,[23,17])
 def test_same_week_and_future_labels_cannot_change_distribution(self):
  rows=[];day=date(2022,9,1)
  for week in range(1,50):
   for i in range(16):rows.append(dict(id=f'{week}-{i}',season=2022,week=week,date=str(day+timedelta(days=7*week)),home='BUF',away='KC',homeScore=24+i%7,awayScore=20+i%5,neutral=False,closing={'home_moneyline':'-110','away_moneyline':'-110'}))
  first=walk(rows);target=first[-32];changed=copy.deepcopy(rows)
  for r in changed:
   if r['week']>=target['week']:r['homeScore'],r['awayScore']=0,70
  second={r['id']:r for r in walk(changed)}
  self.assertEqual(target['markets']['moneyline']['p'],second[target['id']]['markets']['moneyline']['p'])
 def test_error_slices_are_descriptive_and_do_not_change_fixed_specification(self):
  rows=[dict(id=str(i),season=2024,week=i,date=f'2024-10-0{i}',home='BUF',away='KC',homeScore=40,awayScore=30,closing={'home_qb_id':'one' if i==1 else 'two','away_qb_id':'same','spread_line':'8'}) for i in [1,2]]
  labels=tags(rows);self.assertIn('observed_qb_change',labels['2']);self.assertIn('extreme_final_total',labels['2']);self.assertEqual(SPEC['totalBandwidth'],10.)
if __name__=='__main__':unittest.main()
