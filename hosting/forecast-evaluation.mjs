import {outcome} from './game-analysis.mjs';

const logLoss=(p,y)=>-Math.log(Math.max(1e-6,Math.min(1-1e-6,y?p:1-p)));
const mean=a=>a.length?a.reduce((sum,x)=>sum+x,0)/a.length:null;
export function forecastSnapshot(report){
  const kick=Date.parse(report.event.startsAt),captured=Date.parse(report.createdAt);
  if(!Number.isFinite(kick)||!Number.isFinite(captured)||captured>=kick||kick-captured>24*3600000)return null;
  const priced=report.categories.flatMap(c=>c.rows.slice(0,c.market==='props'?18:12));
  const rows=priced.length?priced.map(r=>({id:r.id,playerId:r.playerId,threeWay:r.threeWay,selection:r.selection,decimal:r.decimal,win:r.win,push:r.push,baseline:r.baseline,sourceAt:r.sourceAt,collectedAt:r.collectedAt,book:r.book,rulesVerified:false,forecastBasis:r.forecastBasis})):[{
    id:'home-moneyline-no-price',selection:{eventId:report.event.id,market:'h2h',outcome:report.event.home,participant:'',point:null,period:'full_game',rules:'unpriced_research'},decimal:null,win:report.score.homeWin,push:report.score.tie,baseline:report.baselineHomeWin??null,forecastBasis:report.basis,rulesVerified:false,
  }];
  return {schemaVersion:1,id:`${report.modelVersion}:${report.event.id}:${priced.length?'priced':'unpriced'}`,modelVersion:report.modelVersion,cutoff:report.cutoff,event:report.event,capturedAt:report.createdAt,rows,priced:!!priced.length,benchmarkState:'not_requested',notice:'Automatic model research; no user identity, question, stake or personal bet history is stored.'};
}

export function gradeForecast(snapshot,result){
  if(snapshot.event.id!==result.eventId||!Number.isInteger(result.homeScore)||!Number.isInteger(result.awayScore)||result.homeScore<0||result.awayScore<0)throw new Error('Invalid exact result');
  const results=[];let unresolved=0;
  for(const row of snapshot.rows){
    const s=row.selection;
    const metric={player_pass_yds:'passing_yards',player_rush_yds:'rushing_yards',player_reception_yds:'receiving_yards',player_receptions:'receptions'}[s.market];
    // No recorded appearance is not a zero and is not an invented void.
    const value=metric?result.playerStats?.[row.playerId]?.[metric]:null;
    if(metric&&!Number.isFinite(value)){unresolved++;continue;}
    const grade=outcome({...s,homeTeam:snapshot.event.home},result.homeScore,result.awayScore,value,row.threeWay);
    if(grade===null){unresolved++;continue;}
    const market=metric?'props':s.market;
    if(grade===0){results.push({market,push:true,priced:!!row.decimal});continue;}
    const y=grade===1?1:0,p=row.win/Math.max(1e-9,1-row.push),baseline=row.baseline;
    const ai=snapshot.benchmark?.find(item=>item.id===row.id),aiP=ai?ai.win/Math.max(1e-9,1-ai.push):null;
    results.push({market,push:false,priced:!!row.decimal,brier:(p-y)**2,logLoss:logLoss(p,y),
      baselineBrier:Number.isFinite(baseline)?(baseline-y)**2:null,baselineLogLoss:Number.isFinite(baseline)?logLoss(baseline,y):null,
      aiBrier:Number.isFinite(aiP)?(aiP-y)**2:null,aiLogLoss:Number.isFinite(aiP)?logLoss(aiP,y):null,
      hypotheticalReturn:row.decimal?(y?row.decimal-1:-1):null});
  }
  const markets={};
  for(const market of ['h2h','spreads','totals','props']){
    const all=results.filter(r=>r.market===market),decided=all.filter(r=>!r.push),paired=decided.filter(r=>r.baselineBrier!=null),ai=decided.filter(r=>r.aiBrier!=null);
    if(!all.length)continue;
    markets[market]={observations:all.length,decided:decided.length,pushes:all.length-decided.length,brier:mean(decided.map(r=>r.brier)),logLoss:mean(decided.map(r=>r.logLoss)),
      baselinePairs:paired.length,pairedBrier:mean(paired.map(r=>r.brier)),baselineBrier:mean(paired.map(r=>r.baselineBrier)),pairedLogLoss:mean(paired.map(r=>r.logLoss)),baselineLogLoss:mean(paired.map(r=>r.baselineLogLoss)),
      aiPairs:ai.length,aiPairedBrier:mean(ai.map(r=>r.brier)),aiBrier:mean(ai.map(r=>r.aiBrier)),aiPairedLogLoss:mean(ai.map(r=>r.logLoss)),aiLogLoss:mean(ai.map(r=>r.aiLogLoss)),
      hypotheticalReturn:mean(decided.filter(r=>r.hypotheticalReturn!=null).map(r=>r.hypotheticalReturn))};
  }
  return {eventId:result.eventId,modelVersion:snapshot.modelVersion,capturedAt:snapshot.capturedAt,priced:snapshot.priced,unresolved,markets,hasEdge:false};
}

export function addGrade(aggregate,grade,direction=1){
  for(const [market,row] of Object.entries(grade.markets)){
    const current=aggregate[market]||{games:0,observations:0,pushes:0,probabilityGames:0,baselineGames:0,aiGames:0};
    current.games+=direction;current.observations+=direction*row.observations;current.pushes+=direction*row.pushes;
    if(row.brier!=null){current.probabilityGames+=direction;for(const k of ['brier','logLoss'])current[k]=(current[k]||0)+direction*row[k];}
    if(row.baselinePairs){current.baselineGames+=direction;for(const k of ['pairedBrier','baselineBrier','pairedLogLoss','baselineLogLoss'])current[k]=(current[k]||0)+direction*row[k];}
    if(row.aiPairs){current.aiGames+=direction;for(const k of ['aiPairedBrier','aiBrier','aiPairedLogLoss','aiLogLoss'])current[k]=(current[k]||0)+direction*row[k];}
    aggregate[market]=current;
  }
  return aggregate;
}

export function evaluationReport(aggregate,counts){
  return {schemaVersion:1,mode:'prospective_research',...counts,hasEdge:false,markets:Object.entries(aggregate).map(([market,row])=>({market,games:row.games,observations:row.observations,pushes:row.pushes,
    brier:row.probabilityGames?row.brier/row.probabilityGames:null,logLoss:row.probabilityGames?row.logLoss/row.probabilityGames:null,
    baselineGames:row.baselineGames,pairedBrier:row.baselineGames?row.pairedBrier/row.baselineGames:null,baselineBrier:row.baselineGames?row.baselineBrier/row.baselineGames:null,
    pairedLogLoss:row.baselineGames?row.pairedLogLoss/row.baselineGames:null,baselineLogLoss:row.baselineGames?row.baselineLogLoss/row.baselineGames:null,
    aiGames:row.aiGames,aiPairedBrier:row.aiGames?row.aiPairedBrier/row.aiGames:null,aiBrier:row.aiGames?row.aiBrier/row.aiGames:null,
    aiPairedLogLoss:row.aiGames?row.aiPairedLogLoss/row.aiGames:null,aiLogLoss:row.aiGames?row.aiLogLoss/row.aiGames:null})),
    notice:'First captured forecasts within 24 hours of kickoff. One priced cohort per game/model takes precedence over unpriced research. Errors are averaged within each game before averaging games. Baseline/AI comparisons use matched observations only. Pushes are excluded from probability scores. No verified profit or superiority is claimed; settlement rules and participation gaps remain explicit.'};
}

export function benchmarkTargets(snapshot){
  const chosen=[],seen=new Set();
  const take=row=>{const identity=JSON.stringify(row.selection);if(!seen.has(identity)){seen.add(identity);chosen.push(row);}};
  for(const market of ['spreads','totals','h2h','props']){
    const row=snapshot.rows.find(r=>market==='props'?r.selection.market.startsWith('player_'):r.selection.market===market);if(row)take(row);
  }
  for(const row of snapshot.rows){if(chosen.length>=6)break;take(row);}
  return chosen.slice(0,6);
}

export function validateBenchmark(raw,snapshot){
  if(!Array.isArray(raw?.probabilities)||raw.probabilities.length<1||raw.probabilities.length>6)throw new Error('Invalid benchmark');
  const targets=benchmarkTargets(snapshot),seen=new Set();
  return raw.probabilities.map(row=>{
    if(!Number.isInteger(row.key)||row.key<0||row.key>=targets.length||seen.has(row.key)||!Number.isFinite(row.win)||!Number.isFinite(row.push)||row.win<0||row.push<0||row.win+row.push>1)throw new Error('Invalid benchmark probability');
    seen.add(row.key);return {id:targets[row.key].id,win:row.win,push:row.push};
  });
}
