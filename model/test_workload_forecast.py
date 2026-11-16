import copy
import unittest
from datetime import date, timedelta
import numpy as np
from workload_forecast import feature_pack, fit, walk_forward, examples, select_ridge, FEATURES


class WorkloadTests(unittest.TestCase):
    def test_features_use_only_earlier_counts_and_preserve_missing_team_context(self):
        day=date(2026,11,16)
        rows=[dict(date=str(day-timedelta(days=7*(i+1))),week=10-i,stats={'attempts':30+i}) for i in range(6)]
        one=feature_pack(rows,[],[],day,'QB_attempts',True)
        future=dict(date='2026-11-17',week=12,stats={'attempts':999})
        self.assertEqual(one,feature_pack(rows+[future],[],[],day,'QB_attempts',True))
        self.assertEqual(one['records'],6)
        self.assertEqual(len(one['x']),len(FEATURES))
        self.assertEqual(one['x'][-1],1.)
        self.assertIsNone(feature_pack(rows[:5],[],[],day,'QB_attempts',True))

    def test_same_week_and_future_labels_cannot_change_emitted_forecasts(self):
        rows=[dict(date='2026-10-01',season=2026,week=1,x=[1.]+[i%3/10]*16,incumbent=20.,last3=20.,last6=20.,y=22+i%4,cap=100.) for i in range(240)]
        batch=[dict(rows[0],date='2026-10-08',week=2,y=30.),dict(rows[1],date='2026-10-11',week=2,y=25.)]
        first,_=walk_forward(rows+batch,10.)
        changed=copy.deepcopy(batch);changed[0]['y']=99.
        other,_=walk_forward(rows+changed,10.)
        self.assertEqual(first[1]['prediction'],other[1]['prediction'])
        coef,n=fit(rows,date(2026,10,8),10.)
        later,m=fit(rows+[dict(batch[0],date='2026-10-09',y=999.)],date(2026,10,8),10.)
        np.testing.assert_allclose(coef,later);self.assertEqual(n,m)

    def test_pre_game_cohort_retains_absence_without_imputing_zero(self):
        games=[];records=[];schedule=[]
        day=date(2026,9,1)
        for week in range(1,10):
            at=str(day+timedelta(days=7*week));gid=f'2026_{week:02d}_MIA_BUF'
            games.append(dict(id=gid,date=at,season=2026,week=week,home='BUF',away='MIA'))
            schedule.append(dict(game_id=gid,game_type='REG'))
            if week!=7:
                records.append(dict(playerId='p',name='QB',position='QB',team='BUF',date=at,season=2026,week=week,seasonType='REG',stats={'attempts':30,'carries':4,'targets':0}))
        data={'cutoff':games[-1]['date'],'rows':records}
        rows,_=examples(data,{'cutoff':games[-1]['date'],'games':games},schedule)
        target=next(r for r in rows if r['week']==7 and r['group']=='QB_attempts')
        self.assertIsNone(target['y'])
        self.assertEqual(target['records'],6)
        self.assertEqual(target['incumbent'],30.)
        records.append(dict(records[0],date='2027-01-01',week=30,stats={'attempts':999,'carries':0,'targets':0}))
        unchanged,_=examples(data,{'cutoff':games[-1]['date'],'games':games},schedule)
        self.assertEqual(rows,unchanged)

    def test_parameter_selection_does_not_receive_later_seasons(self):
        train=[dict(date='2024-09-01',season=2024,week=1,x=[1.]+[i%3/10]*16,incumbent=20.,last3=20.,last6=20.,y=22+i%4,cap=100.) for i in range(240)]
        dev=[dict(train[i],date='2024-09-08',week=2,y=23.) for i in range(110)]
        later=[dict(train[0],date='2025-09-01',season=2025,week=1,y=99.) for _ in range(1000)]
        self.assertEqual(select_ridge(train+dev),select_ridge(train+dev+later))


if __name__=='__main__':unittest.main()
