import unittest
from datetime import datetime,timezone
from build_coach_index import build_index
from publish_snapshot import build_snapshot

class CoachIndexTests(unittest.TestCase):
    def test_football_trial_requires_matching_sources_and_earlier_week_inputs(self):
        import copy,hashlib,json
        from pathlib import Path
        from publish_snapshot import TEAMS
        now=datetime(2026,11,17,12,tzinfo=timezone.utc)
        rows=[dict(game_id='2026_11_BUF_KC',gameday='2026-11-18',gametime='13:00',away_team='BUF',home_team='KC',home_score='',away_score='',stadium='Known',roof='outdoors')]
        data={'currentSeason':2026,'cutoff':'2026-11-12','retrievedAt':'2026-11-15T10:00:00Z','rows':[]}
        history={'cutoff':'2026-11-12','retrievedAt':'2026-11-15T10:00:00Z','games':[dict(id='2026_10_BUF_KC',season=2026,week=10,date='2026-11-08',home='KC',away='BUF',homeScore=27,awayScore=24)]}
        digest=lambda value:hashlib.sha256(json.dumps(value,sort_keys=True).encode()).hexdigest()
        model={'schemaVersion':1,'version':'test','cutoff':'2026-11-12','trainedAt':'2026-11-15T10:00:00Z','teams':list(TEAMS),'coefficients':[20,3]+[0]*64,'residuals':[[0,0]]*120}
        sample=json.loads(Path('hosting/fixtures/football-parity.json').read_text())[0]['source']['index']['footballScoreModel']
        evidence={'historyHash':digest(history),'sourceUrl':'https://github.com/nflverse/nflverse-data','retrievedAt':'2026-11-15T10:00:00Z','rows':[],'sources':[]}
        f=copy.deepcopy(sample);f.update(trainedAt='2026-11-16T12:00:00Z',historyHash=digest(history),evidenceHash=digest(evidence),teams=list(TEAMS),development={},retrospectiveLater={},protocol={},residuals=sample['residuals'][:120])
        block=next(iter(f['blocks'].values()));block.update(inputCutoff='2026-11-08',fitDate='2026-11-12')
        record=next(iter(f['events'].values()));record.update(block='2026_11',inputCutoff='2026-11-08',startsAt='2026-11-18T18:00:00Z',roles={})
        f.update(blocks={'2026_11':block},events={'nflverse:2026_11_BUF_KC':record})
        def build(candidate):return build_index(build_snapshot(rows,now),data,rows,now,{},model,history,football_research=candidate,team_efficiency=evidence)
        self.assertEqual(len(build(f)['footballScoreModel']['events']),1)
        for change in [lambda c:c.update(historyHash='wrong'),lambda c:c['validation'].update(adopted=True),lambda c:c['blocks']['2026_11'].update(inputCutoff='2026-11-16'),lambda c:c['events']['nflverse:2026_11_BUF_KC']['roles'].update(home={'lastGame':'2026-11-16'})]:
            bad=copy.deepcopy(f);change(bad)
            with self.assertRaises(ValueError):build(bad)

    def test_trial_history_can_reach_prior_seasons_without_crossing_a_trade(self):
        now=datetime(2026,11,15,12,tzinfo=timezone.utc)
        rows=[dict(game_id='2026_11_BUF_KC',gameday='2026-11-16',gametime='13:00',away_team='BUF',home_team='KC',home_score='',away_score='',stadium='Known',roof='outdoors')]
        stats={'attempts':30,'carries':4,'targets':0,'passing_yards':220,'rushing_yards':20,'receiving_yards':0,'receptions':0}
        current=[dict(playerId='p',name='QB',position='QB',team='BUF',season=2026,seasonType='REG',date=f'2026-11-0{i}',week=i,stats=stats) for i in range(1,7)]
        older=[dict(current[0],season=2025,date=f'2025-12-0{i}') for i in range(1,5)]
        data={'currentSeason':2026,'cutoff':'2026-11-12','retrievedAt':'2026-11-15T10:00:00Z','rows':current+older}
        result=build_index(build_snapshot(rows,now),data,rows,now,{})
        self.assertEqual(len(result['players'][0]['games']),6)
        self.assertEqual(len(result['players'][0]['priorTrialGames']),4)
        self.assertEqual(result['players'][0]['priorTrialGames'][0][:3],['2025-12-04',1,'QB'])
        data['rows'].append(dict(current[0],season=2025,team='DAL',date='2025-12-05'))
        traded=build_index(build_snapshot(rows,now),data,rows,now,{})
        self.assertEqual(traded['players'][0]['priorTrialGames'],[])

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

    def test_game_model_and_final_results_preserve_provenance_and_exact_player_outcomes(self):
        from publish_snapshot import TEAMS
        now=datetime(2026,11,15,12,tzinfo=timezone.utc)
        rows=[dict(game_id='2026_11_BUF_KC',gameday='2026-11-16',gametime='13:00',away_team='BUF',home_team='KC',home_score='',away_score='',stadium='Known',roof='outdoors')]
        data={'currentSeason':2026,'cutoff':'2026-11-12','retrievedAt':'2026-11-15T10:00:00Z','rows':[dict(playerId='p',name='Player',team='BUF',position='QB',season=2026,seasonType='REG',date='2026-11-08',week=10,stats={'passing_yards':250,'attempts':30})]}
        model={'schemaVersion':1,'version':'test','cutoff':'2026-11-12','trainedAt':'2026-11-15T10:00:00Z','teams':list(TEAMS),'coefficients':[20,3]+[0]*64,'residuals':[[0,0]]*120}
        history={'cutoff':'2026-11-12','retrievedAt':'2026-11-15T10:00:00Z','games':[dict(id='2026_10_BUF_KC',season=2026,week=10,date='2026-11-08',home='KC',away='BUF',homeScore=27,awayScore=24),dict(id='future',season=2026,week=12,date='2026-11-22',home='KC',away='BUF',homeScore=99,awayScore=0)]}
        result=build_index(build_snapshot(rows,now),data,rows,now,{},model,history)
        self.assertEqual(result['events'][0]['forecast']['homeMean'],23)
        self.assertEqual(result['events'][0]['homeCode'],'KC')
        self.assertEqual(len(result['results']),1)
        self.assertEqual(result['results'][0]['playerStats']['p']['passing_yards'],250)
        import hashlib,json
        shadow=dict(model,teams=sorted(TEAMS),validation={'adopted':False,'hasEdge':False})
        lab={'schemaVersion':1,'generatedAt':'2026-11-15T10:00:00Z','cutoff':history['cutoff'],
             'sourceHash':hashlib.sha256(json.dumps(history,sort_keys=True).encode()).hexdigest(),
             'challengerModel':shadow,'decision':{'adopted':False,'hasEdge':False}}
        indexed=build_index(build_snapshot(rows,now),data,rows,now,{},model,history,lab)
        self.assertEqual(indexed['shadowScoreModel']['teams'],sorted(TEAMS))
        self.assertNotIn('challengerModel',indexed['forecastLab'])
        self.assertTrue(indexed['forecastLab']['matchesLatestHistory'])
        lab['sourceHash']='0'*64
        newer=build_index(build_snapshot(rows,now),data,rows,now,{},model,history,lab)
        self.assertFalse(newer['forecastLab']['matchesLatestHistory'])
        self.assertIsNotNone(newer['shadowScoreModel'])
        lab['sourceHash']='wrong'
        with self.assertRaises(ValueError):build_index(build_snapshot(rows,now),data,rows,now,{},model,history,lab)
        workload={'schemaVersion':1,'version':'workload-ridge-v1','trainedAt':'2026-11-15T10:00:00Z','cutoff':'2026-11-12','adopted':False,'hasEdge':False,'featureNames':list(range(17)),'models':{'QB_attempts':{'coefficients':[0]*17,'residuals':[0]*120,'trainingRows':200}}}
        updated=build_index(build_snapshot(rows,now),data,rows,now,{},model,history,workload_model=workload)
        self.assertEqual(updated['results'][0]['playerStats']['p']['attempts'],30)
        self.assertEqual(updated['results'][0]['playerTeams']['p'],'BUF')
        self.assertEqual(updated['players'][0]['games'][0]['position'],'QB')
        production={'schemaVersion':1,'version':'production-joint-v1','trainedAt':'2026-11-15T10:00:00Z','cutoff':'2026-11-12','adopted':False,'hasEdge':False,'featureNames':list(range(24)),
            'volumeModelHash':hashlib.sha256(json.dumps(workload,sort_keys=True).encode()).hexdigest(),
            'models':{'QB_passing_yards':{'coefficients':[0]*24,'residualPairs':[[0,0]]*120,'trainingRows':200}}}
        joint=build_index(build_snapshot(rows,now),data,rows,now,{},model,history,workload_model=workload,production_model=production)
        self.assertEqual(joint['productionModel']['version'],'production-joint-v1')
        production['volumeModelHash']='wrong'
        with self.assertRaises(ValueError):build_index(build_snapshot(rows,now),data,rows,now,{},model,history,workload_model=workload,production_model=production)
        regime={'schemaVersion':1,'version':'regime-research-v1','sourceHash':hashlib.sha256(json.dumps(history,sort_keys=True).encode()).hexdigest(),'model':dict(model,version='score-regime-kernel-v1',sourceHash=hashlib.sha256(json.dumps(history,sort_keys=True).encode()).hexdigest(),residualContexts=[[46,3]]*120,validation={'adopted':False,'hasEdge':False},specification={'totalBandwidth':10.,'marginBandwidth':7.,'uniformMixture':.5,'minimumEffectiveErrors':120,'ridge':40.,'halfLifeDays':180.})}
        checked=build_index(build_snapshot(rows,now),data,rows,now,{},model,history,regime_research=regime)
        self.assertEqual(checked['regimeScoreModel']['version'],'score-regime-kernel-v1')
        self.assertNotIn('model',checked['regimeResearch'])
        regime['model']['validation']['adopted']=True
        with self.assertRaises(ValueError):build_index(build_snapshot(rows,now),data,rows,now,{},model,history,regime_research=regime)
        regime['model']['validation']['adopted']=False
        regime['model']['residualContexts']=[[float('nan'),3]]*120
        with self.assertRaises(ValueError):build_index(build_snapshot(rows,now),data,rows,now,{},model,history,regime_research=regime)
        workload['trainedAt']='2026-11-20T00:00:00Z'
        with self.assertRaises(ValueError):build_index(build_snapshot(rows,now),data,rows,now,{},model,history,workload_model=workload)
        model['trainedAt']='2026-11-20T00:00:00Z'
        with self.assertRaises(ValueError):build_index(build_snapshot(rows,now),data,rows,now,{},model,history)
