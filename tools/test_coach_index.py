import unittest
from datetime import datetime,timezone
from build_coach_index import build_index
from publish_snapshot import build_snapshot

class CoachIndexTests(unittest.TestCase):
    def test_exact_venue_and_packed_stats_are_published_without_future_or_traded_rows(self):
        now=datetime(2026,11,15,12,tzinfo=timezone.utc)
        rows=[dict(game_id='2026_11_BUF_KC',gameday='2026-11-16',gametime='13:00',away_team='BUF',home_team='KC',home_score='',away_score='',stadium='Known',roof='outdoors')]
        data={'currentSeason':2026,'cutoff':'2026-11-12','retrievedAt':'2026-11-15T10:00:00Z','statKeys':['passing_yards','attempts'],'rows':[
            dict(playerId='p',name='Player',team='BUF',position='QB',season=2026,seasonType='REG',date='2026-11-08',week=10,stats=[250,30]),
            dict(playerId='p',name='Player',team='DAL',position='QB',season=2026,seasonType='REG',date='2026-11-22',week=12,stats=[999,99]),
        ]}
        result=build_index(build_snapshot(rows,now),data,rows,now,{'Known':(1.0,2.0)})
        self.assertEqual(result['events'][0]['latitude'],1.0)
        self.assertEqual(result['players'][0]['games'][0]['stats']['passing_yards'],250)
        self.assertEqual(len(result['players'][0]['games']),1)
        data['retrievedAt']='2026-11-20T00:00:00Z'
        with self.assertRaises(ValueError):build_index(build_snapshot(rows,now),data,rows,now,{})
