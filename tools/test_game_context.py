import unittest
from datetime import datetime, timezone
from build_game_context import build_context


class GameContextTests(unittest.TestCase):
    def setUp(self):
        self.now=datetime(2026,11,16,12,tzinfo=timezone.utc)
        self.events=[dict(id='g',homeCode='BUF',awayCode='MIA',listedQuarterbacks={'home':'New QB','away':None})]
        self.data={'currentSeason':2026,'cutoff':'2026-11-12','retrievedAt':'2026-11-15T12:00:00Z'}
        self.records=[dict(playerId='p',name='Receiver',position='WR',team='BUF',opponent='MIA',date='2026-11-12',week=10,stats={'targets':5,'rushing_yards':-3}),
                      dict(playerId='qb',name='Old QB',position='QB',team='BUF',opponent='MIA',date='2026-11-12',week=10,stats={'attempts':30,'passing_yards':250}),
                      dict(playerId='other',name='Other QB',position='QB',team='MIA',opponent='BUF',date='2026-11-12',week=10,stats={'attempts':32,'passing_yards':230})]
        self.matchup={'season':2026,'snapSource':'https://github.com/nflverse/nflverse-data','provenance':{'snaps':{'cutoff':'2026-11-12','retrievedAt':'2026-11-15T12:00:00Z','throughWeek':10}},'snaps':[
            dict(team='BUF',week=10,player='Tackle',position='T',offensePct=.95),
            dict(team='BUF',week=11,player='Future',position='T',offensePct=1.),
        ]}

    def test_denominators_snap_identity_and_opponent_allowance(self):
        context=build_context(self.events,self.data,self.records,self.matchup,self.now)
        home=next(g for g in context['teamGames'] if g['team']=='BUF')
        self.assertEqual(home['targets'],5)
        self.assertEqual(home['passers'][0]['name'],'Old QB')
        self.assertEqual(home['passingYardsAllowed'],230)
        self.assertEqual(home['rushYards'],-3)
        self.assertEqual(len(context['snaps']),1)
        self.assertTrue(any(p['name']=='Tackle' for p in context['contextPlayers']))
        self.assertTrue(any(p['name']=='New QB' and p['identitySource']=='schedule_listing_unconfirmed' for p in context['contextPlayers']))

    def test_future_snap_provenance_and_duplicate_workload_fail_closed(self):
        self.matchup['provenance']['snaps']['retrievedAt']='2026-11-20T00:00:00Z'
        with self.assertRaises(ValueError):build_context(self.events,self.data,self.records,self.matchup,self.now)
        with self.assertRaises(ValueError):build_context(self.events,self.data,self.records+[self.records[0]],None,self.now)

    def test_undated_snaps_are_not_given_a_fresh_date(self):
        self.matchup['provenance']['snaps']['cutoff']=None
        context=build_context(self.events,self.data,self.records,self.matchup,self.now)
        self.assertEqual(context['snaps'],[])
        self.assertIsNone(context['snapSource'])


if __name__=='__main__':unittest.main()
