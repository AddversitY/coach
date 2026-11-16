import test from 'node:test';
import assert from 'node:assert/strict';
import {attachCalibration,CALIBRATION_VERSION} from './calibration-trial.mjs';
import {gradeForecast,addGrade,evaluationReport} from './forecast-evaluation.mjs';
import {accuracyAudit} from './accuracy-audit.mjs';
const snapshot={event:{id:'g',home:'Home',away:'Away'},modelVersion:'test',capturedAt:'2026-11-16T12:00:00Z',rows:[{selection:{eventId:'g',market:'h2h',outcome:'Home'},win:.72,push:.1,baseline:.7,decimal:2}],priced:true};
test('fixed calibration preserves push and conditional ordering without replacing serving values',()=>{
 const trial=attachCalibration(snapshot),r=trial.rows[0];
 assert.equal(trial.calibrationVersion,CALIBRATION_VERSION);assert.equal(r.win,.72);assert.equal(r.push,.1);assert.equal(r.calibrationPush,.1);
 assert.ok(r.calibrationWin<.72&&r.calibrationWin>.45);assert.equal(snapshot.rows[0].calibrationWin,undefined);
 const complement=attachCalibration({...snapshot,rows:[{...snapshot.rows[0],win:.18}]}).rows[0];
 assert.ok(Math.abs(r.calibrationWin+complement.calibrationWin-.9)<1e-12);
 for(const p of [0,1]){const r=attachCalibration({...snapshot,rows:[{win:p,push:0}]}).rows[0];assert.equal(r.calibrationWin,p);}
});
test('calibration is scored only from captured trial fields and corrections undo paired game contributions',()=>{
 const result={eventId:'g',homeScore:20,awayScore:10};
 const legacy=gradeForecast(snapshot,result);assert.equal(legacy.markets.h2h.calibrationPairs,0);
 const trial=attachCalibration(snapshot),won=gradeForecast(trial,result),lost=gradeForecast(trial,{...result,awayScore:30});
 assert.ok(won.markets.h2h.calibrationBrierDelta>0);assert.ok(lost.markets.h2h.calibrationBrierDelta<0);
 const aggregate=addGrade({},won);addGrade(aggregate,won,-1);addGrade(aggregate,lost);
 const report=evaluationReport(aggregate,{}).markets[0].calibrationTrial;
 assert.equal(report.games,1);assert.equal(report.adopted,false);assert.equal(report.brierDifference,lost.markets.h2h.calibrationBrierDelta);
});
test('pushes and missing appearances cannot fabricate calibration wins',()=>{
 const tie=gradeForecast(attachCalibration(snapshot),{eventId:'g',homeScore:20,awayScore:20});assert.equal(tie.markets.h2h.calibrationPairs,0);
 const prop=attachCalibration({...snapshot,rows:[{...snapshot.rows[0],playerId:'p',selection:{market:'player_receptions',outcome:'Over',point:4.5}}]});
 const grade=gradeForecast(prop,{eventId:'g',homeScore:20,awayScore:10});assert.equal(grade.unresolved,1);assert.equal(grade.markets.props,undefined);
});
test('audit distinguishes empty prospective evidence from a losing historical challenger',()=>{
 const report=accuracyAudit({capturedGames:1,gradedGames:0,pendingGames:1,markets:[]},{markets:{moneyline:{games:407,brier:.23,marketBrier:.21,logLoss:.64,marketLogLoss:.61}}},{validation:{QB_passing_yards:{recorded:624,mae:61.6,baselineMae:64.7,interval80Coverage:.81}}},0);
 assert.equal(report.status,'awaiting_results');assert.equal(report.markets[0].matchedPricedGames,0);assert.equal(report.markets[0].historical.status,'not_better_on_both');assert.equal(report.markets[3].historical,null);assert.equal(report.playerFindings[0].status,'lower_historical_point_error');assert.equal(report.hasEdge,false);
});
