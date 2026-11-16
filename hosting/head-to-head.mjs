export const BENCHMARK_PROTOCOL='fair-source-context-v3';
export function benchmarkFacts(report,index,targets){
  const event=Object.fromEntries(['id','home','away','homeCode','awayCode','startsAt','listedQuarterbacks','restDays','roof','latitude','longitude'].filter(k=>report.event[k]!=null).map(k=>[k,report.event[k]]));
  const wanted=new Set(targets.map(r=>r.selection.participant).filter(Boolean));
  return {event,cutoff:index.cutoff,availability:report.availability||[],weather:report.weather||[],roleContext:report.contextFacts||null,
    recentGames:(index.results||[]).filter(g=>Date.parse(g.date+'T23:59:59Z')<Date.parse(report.createdAt)&&[g.home,g.away].some(n=>[event.home,event.away].includes(n))).slice(-16).map(g=>Object.fromEntries(['eventId','date','home','away','homeScore','awayScore'].filter(k=>g[k]!=null).map(k=>[k,g[k]]))),
    players:index.players.filter(p=>wanted.has(p.name)).map(p=>({id:p.id,name:p.name,team:p.team,games:p.games.filter(g=>Date.parse(g.date+'T23:59:59Z')<Date.parse(report.createdAt)).map(g=>({date:g.date,week:g.week,stats:Object.fromEntries(Object.entries(g.stats||{}).filter(([k,v])=>['passing_yards','rushing_yards','receiving_yards','attempts','carries','targets','receptions','passing_tds','rushing_tds','receiving_tds'].includes(k)&&Number.isFinite(v)))}))})),
    savedPrices:(report.frozenRows||[]).map(r=>Object.fromEntries(['selection','book','decimal','sourceAt','collectedAt'].filter(k=>r[k]!=null).map(k=>[k,r[k]]))),
    targets:targets.map((r,key)=>({key,selection:r.selection,decimal:r.decimal,threeWay:r.threeWay||false})),
    evaluationConvention:'Experimental full-game rules with overtime. Two-way moneyline ties push; three-way team selections lose on a tie. Missing player appearances remain unresolved.',
    notice:'Frozen public source context only; no Coach predictions, model coefficients, probabilities, ranks or decision brief. This is a controlled baseline, not every AI or identical model training data.'};
}
export function validPregameBenchmark(snapshot){
 return typeof snapshot.benchmarkModel==='string'&&snapshot.benchmarkModel.length>0&&snapshot.benchmarkPromptVersion===BENCHMARK_PROTOCOL&&/^[a-f0-9]{64}$/.test(snapshot.benchmarkFactsHash||'')&&Number.isFinite(Date.parse(snapshot.benchmarkCompletedAt))&&Date.parse(snapshot.benchmarkCompletedAt)>=Date.parse(snapshot.capturedAt)&&Date.parse(snapshot.benchmarkCompletedAt)<Date.parse(snapshot.event.startsAt);
}
export function headToHead(row){
 const games=row.headGames||0,models=Object.entries(row.headModels||{}).filter(([,n])=>n>0).map(([model,n])=>({model,games:n})),mixed=models.length>1;
 const metric=key=>games&&!mixed?row[key]/games:null;
 return {protocol:BENCHMARK_PROTOCOL,games,models,observations:row.headObservations||0,status:mixed?'mixed_models_not_comparable':games<1000?'collecting_evidence':'review_required',hasEdge:false,superiorityDemonstrated:false,
   coachBrier:metric('headCoachBrier'),aiBrier:metric('headAiBrier'),marketBrier:metric('headMarketBrier'),coachLogLoss:metric('headCoachLog'),aiLogLoss:metric('headAiLog'),marketLogLoss:metric('headMarketLog'),
   notice:'All three scores use the same priced, non-push selections, averaged within games. Only the v3 baseline completed before kickoff qualifies. Missing or late AI replies are excluded, never counted as wins. This tests the configured AI and supplied context only; no automatic superiority or adoption claim.'};
}
