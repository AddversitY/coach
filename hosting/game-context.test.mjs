import test from 'node:test';
import assert from 'node:assert/strict';
import {gameContext,projectionWarnings,decisionBrief,contextEvidence} from './game-context.mjs';
import {injuryReports} from './live-sources.mjs';

const now=Date.UTC(2026,10,16,12),at=new Date(now).toISOString();
const event={id:'g',home:'Buffalo Bills',away:'Miami Dolphins',homeCode:'BUF',awayCode:'MIA',startsAt:new Date(now+3600000).toISOString(),listedQuarterbacks:{home:'New Quarterback',away:null},restDays:{home:7,away:6},scheduleEvidence:{sourceUrl:'https://github.com/nflverse/nfldata',retrievedAt:at}};
const games=Array.from({length:6},(_,i)=>({date:`2026-11-${String(12-i).padStart(2,'0')}`,week:10-i,stats:{targets:i<3?4:10}}));
function source(){return {index:{events:[event],players:[{id:'p',name:'Receiver',position:'WR',team:'BUF',events:['g'],games}],contextPlayers:[{id:'ol',name:'Recorded Tackle',position:'T',team:'BUF',events:['g']}],roleContext:{schemaVersion:1,source:'nflverse',sourceUrl:'https://github.com/nflverse/nflverse-data',cutoff:'2026-11-12',retrievedAt:at,teamGames:games.map((g,i)=>({team:'BUF',date:g.date,week:g.week,targets:30,attempts:32,passers:[{id:'old',name:'Old Quarterback',attempts:30}]})),snapSource:{cutoff:'2026-11-12',retrievedAt:at},snaps:[{team:'BUF',date:games[0].date,week:10,name:'Receiver',position:'WR',offenseShare:.75},{team:'BUF',date:games[0].date,week:10,name:'Recorded Tackle',position:'T',offenseShare:1}]}}};}

test('quarterback listings, workload and snaps remain descriptive and dated',()=>{
  const context=gameContext(source(),event,{now}),home=context.teams.find(t=>t.code==='BUF');
  assert.equal(home.quarterback.listingDiffersFromLastObserved,true);assert.equal(home.quarterback.status,'change_requires_review');
  assert.equal(home.usage[0].recentMean,4);assert.equal(home.usage[0].priorMean,10);assert.equal(home.usage[0].trend,'decreased');
  assert.equal(home.usage[0].recentShare,4/30);assert.equal(home.usage[0].recentSnapShare,.75);
  assert.equal(context.adjustmentsApplied,false);assert.equal(home.restDays,7);assert.equal(home.offensiveLine.lastObserved.length,1);
  assert.ok(projectionWarnings({playerId:'p',market:'player_reception_yds'},context).some(w=>w.includes('Quarterback')));
});

test('stale and future context cannot masquerade as current role evidence',()=>{
  for(const cutoff of ['2026-10-01','2026-11-20']){
    const data=source();data.index.roleContext.cutoff=cutoff;
    const context=gameContext(data,event,{now});assert.equal(context.readiness,'context_unavailable');assert.equal(context.teams[1].usage.length,0);
  }
  const data=source();data.index.roleContext.snapSource.retrievedAt=new Date(now+1000).toISOString();
  assert.equal(gameContext(data,event,{now}).teams[1].usage[0].recentSnapShare,null);
});

test('missing player appearances stay missing and trigger a role review',()=>{
  const data=source();data.index.players[0].games=games.slice(1);
  const context=gameContext(data,event,{now}),usage=context.teams[1].usage[0];
  assert.equal(usage.appearances,5);assert.equal(usage.latestTeamGameMissing,true);assert.equal(usage.observations.some(r=>r.workload===0),false);
  assert.ok(projectionWarnings({playerId:'p',market:'player_receptions'},context).some(w=>w.includes('not a zero')));
});

test('offensive-line injuries require exact name/team and preserve report dates',()=>{
  const data=source(),raw={timestamp:at,season:{year:2026},injuries:[{injuries:[{status:'Questionable',date:at,athlete:{displayName:'Recorded Tackle',position:{abbreviation:'OT'},team:{abbreviation:'BUF'}}}]}]};
  const rows=injuryReports(raw,data.index,at);assert.equal(rows.length,1);assert.equal(rows[0].playerId,'ol');assert.equal(rows[0].value.position,'T');
  const context=gameContext(data,event,{now,telemetry:{checkedAt:at,observations:rows}});assert.equal(context.teams[1].offensiveLine.reports.length,1);
  assert.equal(context.teams[1].offensiveLine.reports[0].value.reportedUpdatedAt,at);
  const wrong=structuredClone(raw);wrong.injuries[0].injuries[0].athlete.team.abbreviation='MIA';assert.equal(injuryReports(wrong,data.index,at).length,0);
  assert.equal(gameContext(data,event,{now,telemetry:{checkedAt:new Date(now-13*60000).toISOString(),observations:rows}}).teams[1].offensiveLine.reports.length,0);
});

test('decision brief never fabricates a price or promotes a contextual lean to an edge',()=>{
  const context=gameContext(source(),event,{now});
  const report={event,ranked:[],categories:[{rows:[]}],score:{homeWin:.6,tie:.02},basis:'experimental_score_candidate'};
  const brief=decisionBrief(report,context);assert.equal(brief.price,null);assert.equal(brief.status,'wait_for_context');assert.equal(brief.lean.team,event.home);
  assert.equal(brief.hasEdge,false);assert.equal(brief.recommendationsReady,false);assert.match(brief.counterargument,/schedule lists/);
});


test('the requested market, side and line cannot inherit an unrelated price',()=>{
  const context=gameContext(source(),event,{now});
  const prop={blocked:false,selection:{market:'player_reception_yds',participant:'Receiver',outcome:'Over',point:65.5},book:'Test',minimumDecimal:2,decimal:2.1};
  const spread={...prop,selection:{market:'spreads',participant:'',outcome:event.home,point:-3.5}};
  const report={event,ranked:[spread,prop],categories:[{rows:[spread,prop]}],score:{homeWin:.6,tie:.02},basis:'experimental_score_candidate'};
  assert.equal(decisionBrief(report,context,{question:'Receiver receiving yards under 65.5'}).price,null);
  assert.equal(decisionBrief(report,context,{question:'Bills spread line -2.5'}).price,null);
  assert.equal(decisionBrief(report,context,{question:'Receiver receiving yards over 65.5'}).price.selection.market,'player_reception_yds');
  const frozen=contextEvidence(context);assert.equal(frozen.teams[1].usage[0].observations,undefined);
  assert.equal(frozen.cutoff,'2026-11-12');assert.equal(frozen.adjustmentsApplied,false);
  assert.equal(context.teams[1].usage[0].observations.length,6);
});


test('decision stays on the requested team and does not substitute a winner for a prop or total',()=>{
  const context=gameContext(source(),event,{now});
  const row={blocked:false,selection:{market:'spreads',participant:'',outcome:event.home,point:-3.5},book:'Test',minimumDecimal:2,decimal:2.1};
  const report={event,ranked:[row],categories:[{rows:[row]}],score:{homeWin:.6,tie:.02},basis:'experimental_score_candidate'};
  assert.equal(decisionBrief(report,context,{question:'Dolphins spread'}).price,null);
  assert.equal(decisionBrief(report,context,{question:'Receiver receiving yards over 65.5'}).lean,null);
  assert.equal(decisionBrief(report,context,{question:'Game total over 45.5'}).lean,null);
  const emptyContext={...context,alerts:[]};
  const brief=decisionBrief(report,emptyContext,{question:'Game total over 45.5'});
  assert.equal(brief.reason,'matching_price_missing');assert.equal(brief.action,'pass');assert.match(brief.priceNotice,/matches this question/);
});


test('participation and reassessment conditions never infer official availability or promise an edge',()=>{
  const context=gameContext(source(),event,{now});
  assert.equal(context.participation.officialActiveListAvailable,false);assert.equal(context.participation.confirmedStartersAvailable,false);assert.equal(context.participation.state,'unconfirmed');
  const report={event,ranked:[],categories:[{rows:[]}],score:{homeWin:.6,tie:.02},basis:'experimental_score_candidate'};
  const brief=decisionBrief(report,context,{question:'Receiver receiving yards over 65.5'});
  assert.deepEqual(brief.whatWouldChange.map(c=>c.kind),['price','availability','validation']);
  assert.equal(brief.whatWouldChange[0].state,'missing_exact_quote');assert.equal(brief.whatWouldChange[0].selection,null);
  assert.match(brief.whatWouldChange[1].text,/official source/);assert.match(brief.whatWouldChange[2].text,/alone does not establish an edge/);assert.equal(brief.action,'pass');
});

test('official absences produce a focused pass, uncertain designations wait, and neither invents playing time',()=>{
 const data=source(),observation={id:'official',eventId:event.id,kind:'injury',playerId:'p',source:'NFL.com official injury report',confirmed:true,observedAt:at,value:{status:'Out',team:'BUF',playerName:'Receiver',position:'WR',url:'https://www.nfl.com/injuries/',reportedUpdatedAt:null}};
 const telemetry={checkedAt:at,observations:[observation]},context=gameContext(data,event,{now,telemetry});
 const report={event,ranked:[],categories:[{rows:[]}],score:{homeWin:.6,tie:.02},basis:'experimental_score_candidate'};
 let brief=decisionBrief(report,context,{question:'Receiver receiving yards over 65.5'});
 assert.equal(brief.reason,'officially_unavailable');assert.equal(brief.decisionLabel,'Pass');assert.equal(brief.price,null);
 const team=context.teams.find(t=>t.code==='BUF');assert.equal(team.lineupReview.expectedPlayingTime,null);assert.equal(team.lineupReview.keyAbsences[0].priorRole.recentMean,4);
 assert.ok(context.sources.some(s=>s.source===observation.source));assert.equal(contextEvidence(context).teams.find(t=>t.code==='BUF').availability[0].reportedAt,null);
 assert.equal(contextEvidence(context).teams.find(t=>t.code==='BUF').lineupReview.keyAbsences[0].priorRole.observations,undefined);
 observation.value.status='Questionable';brief=decisionBrief(report,gameContext(data,event,{now,telemetry}),{question:'Receiver receiving yards over 65.5'});assert.equal(brief.decisionLabel,'Wait');assert.equal(brief.recommendationsReady,false);
 telemetry.checkedAt=new Date(now-13*60000).toISOString();assert.equal(gameContext(data,event,{now,telemetry}).teams.find(t=>t.code==='BUF').lineupReview.keyAbsences.length,0);
});
