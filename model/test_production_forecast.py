import copy
import unittest
from datetime import date, timedelta
import numpy as np
from production_forecast import samples, rate_features, fit_rate, walk_rate, rate_packs, EXTRA
from workload_forecast import examples


class ProductionTests(unittest.TestCase):
    def test_current_game_passer_changes_only_the_outcome_slice(self):
        games=[];records=[];schedule=[]
        for week in range(1,10):
            day=str(date(2024,9,1)+timedelta(days=week*7));game_id=f'2024_{week:02d}_MIA_BUF'
            games.append(dict(id=game_id,date=day,season=2024,week=week,home='BUF',away='MIA'))
            schedule.append(dict(game_id=game_id,game_type='REG'))
            for player,position,attempts in [('q','QB',30),('backup','QB',1),('r','WR',0)]:
                records.append(dict(playerId=player,name=player,position=position,team='BUF',date=day,season=2024,week=week,seasonType='REG',stats={'attempts':attempts,'carries':1,'targets':8 if position=='WR' else 0,'passing_yards':attempts*7,'rushing_yards':3,'receiving_yards':64 if position=='WR' else 0,'receptions':5 if position=='WR' else 0}))
        dataset={'cutoff':games[-1]['date'],'rows':records};history={'cutoff':games[-1]['date'],'games':games}
        original,_=examples(dataset,history,schedule,extra_stats=EXTRA,augment=rate_packs)
        other=copy.deepcopy(dataset)
        for r in other['rows']:
            if r['week']==8 and r['playerId']=='backup':r['stats']['attempts']=50;r['stats']['passing_yards']=350
        changed,_=examples(other,history,schedule,extra_stats=EXTRA,augment=rate_packs)
        a=next(r for r in original if r['week']==8 and r['playerId']=='r')
        b=next(r for r in changed if r['week']==8 and r['playerId']=='r')
        self.assertNotEqual(a['actualLeader'],b['actualLeader'])
        self.assertEqual(a['x'],b['x']);self.assertEqual(a['production'],b['production'])

    def test_pairing_retains_volume_efficiency_dependence(self):
        paired=[[1.,1.],[-1.,-1.]]*100
        independent=[[1.,-1.],[-1.,1.]]*100
        together=samples(10.,5.,paired,'passing_yards',100)
        reversed_pair=samples(10.,5.,independent,'passing_yards',100)
        self.assertNotEqual(float(np.mean(together)),float(np.mean(reversed_pair)))
        self.assertTrue(np.all(together==np.floor(together)))
        self.assertIsNone(samples(10,5,paired[:100],'passing_yards',100))

    def test_receptions_cannot_exceed_the_simulated_target_count(self):
        values=samples(5.,.8,[[1.,1.],[-1.,-2.]]*100,'receptions',40)
        self.assertTrue(np.all(values>=0))
        self.assertTrue(np.all(values<=6))

    def test_actual_quarterback_identity_is_never_a_feature(self):
        row={'x':[1.]*17,'pack':{'extra':[.5]*7,'rate':7.,'baselineMean':200.,'baselineSd':70.,'last3':200.,'last6':200.},'actualLeader':'future-a'}
        other=copy.deepcopy(row);other['actualLeader']='future-b'
        self.assertEqual(rate_features(row),rate_features(other))
        ablated=rate_features(row,True)
        for i in [14,22,23]:self.assertEqual(ablated[i],0.)

    def test_same_week_labels_do_not_change_other_forecasts(self):
        base={'playerId':'p','eventId':'g','stat':'passing_yards','metric':'attempts','x':[1.]+[.1]*16,'pack':{'extra':[.5]*7,'rate':7.,'baselineMean':210.,'baselineSd':70.,'last3':210.,'last6':210.},'prediction':30.,'cap':100.,'actualLeader':'q','priorLeader':'q','y':30.}
        prior=[dict(base,season=2024,week=1,date='2024-09-01',actualStats={'passing_yards':210+i%10}) for i in range(220)]
        batch=[dict(base,season=2024,week=2,date='2024-09-08',actualStats={'passing_yards':250.}),dict(base,playerId='other',season=2024,week=2,date='2024-09-08',actualStats={'passing_yards':230.})]
        first,_=walk_rate(prior+batch,10.)
        changed=copy.deepcopy(batch);changed[0]['actualStats']['passing_yards']=999.
        second,_=walk_rate(prior+changed,10.)
        self.assertEqual(first[1]['prediction'],second[1]['prediction'])
        coef,n=fit_rate(prior,date(2024,9,8),10.)
        extra=dict(batch[0],date='2024-09-09')
        other,m=fit_rate(prior+[extra],date(2024,9,8),10.)
        np.testing.assert_allclose(coef,other);self.assertEqual(n,m)


if __name__=='__main__':unittest.main()
