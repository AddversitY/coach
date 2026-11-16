export function accuracyAudit(report,historical=null,production=null,now=Date.now()){
  const labels={h2h:'Moneyline',spreads:'Spread',totals:'Game total',props:'Player props'};
  return {version:'accuracy-audit-v1',checkedAt:new Date(now).toISOString(),status:report.gradedGames?'collecting_evidence':'awaiting_results',hasEdge:false,
    capturedGames:report.capturedGames||0,gradedGames:report.gradedGames||0,pendingGames:report.pendingGames||0,
    markets:Object.entries(labels).map(([market,label])=>{
      const live=report.markets?.find(r=>r.market===market),past=historical?.markets?.[market==='h2h'?'moneyline':market];
      const comparable=past&&Number.isFinite(past.brier)&&Number.isFinite(past.marketBrier)&&Number.isFinite(past.logLoss)&&Number.isFinite(past.marketLogLoss);
      return {market,label,prospectiveGames:live?.games||0,matchedPricedGames:live?.priceComparison?.games||0,
        prospectiveStatus:live?.priceComparison?.games?'collecting_evidence':'no_matched_price_results',
        historical:comparable?{games:past.games,brierDifference:past.brier-past.marketBrier,logLossDifference:past.logLoss-past.marketLogLoss,status:past.brier<past.marketBrier&&past.logLoss<past.marketLogLoss?'lower_historical_error':'not_better_on_both',scope:'Retrospective game-model challenger versus market reference; not current serving performance.'}:null};
    }),
    playerFindings:Object.entries(production?.validation||{}).filter(([,r])=>Number.isFinite(r.mae)&&Number.isFinite(r.baselineMae)).map(([group,r])=>({group,recorded:r.recorded,mae:r.mae,baselineMae:r.baselineMae,difference:r.mae-r.baselineMae,coverage80:r.interval80Coverage,status:r.mae<r.baselineMae?'lower_historical_point_error':'baseline_not_beaten'})),
    nextStep:report.gradedGames?'Review matched market and calibration errors as more games finish.':'Wait for captured games to finish and published final outcomes to arrive. No forecast is graded from an invented outcome.',
    notice:'Historical point accuracy, prospective probability accuracy and betting profitability are different tests. No demonstrated betting edge or superiority to every AI.'};
}
