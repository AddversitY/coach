import unittest
from datetime import date,timedelta

import numpy as np
from game_forecast import before,chances,fit,project

class GameForecastTests(unittest.TestCase):
    def test_future_scores_cannot_change_a_fit(self):
        now=date(2026,11,16)
        rows=[{'date':str(now-timedelta(days=1+i%90)),'home':'BUF','away':'KC','homeScore':20+i%14,'awayScore':17+i%10} for i in range(320)]
        coefficients,n=fit(rows,now)
        other,m=fit(rows+[{'date':str(now+timedelta(days=1)),'home':'BUF','away':'KC','homeScore':999,'awayScore':0}],now)
        np.testing.assert_allclose(coefficients,other);self.assertEqual(n,m)
        self.assertTrue(all(0<=x<=65 for x in project(coefficients,'BUF','KC')))

    def test_entire_test_week_is_excluded_and_pushes_have_mass(self):
        self.assertFalse(before({'season':2026,'week':11},2026,11))
        self.assertTrue(before({'season':2026,'week':10},2026,11))
        scores=[(24,21),(21,24),(28,21),(24,24)]
        win,push=chances(scores,'spreads',-3)
        self.assertEqual(win,.25);self.assertEqual(push,.25)
        win,push=chances(scores,'totals',45)
        self.assertEqual(win,.5);self.assertEqual(push,.5)

    def test_insufficient_prior_evidence_does_not_produce_a_model(self):
        with self.assertRaises(ValueError):fit([],date(2026,11,16))

if __name__=='__main__':unittest.main()
