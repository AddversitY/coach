/* Selection-specific explanation. No odds, alternate lines or skill are invented. */
export function selectionExplanation(report,row){
 if(!row||![row.win,row.push].every(Number.isFinite)||row.win<0||row.push<0||row.win+row.push>1||row.push>=1)return {judgment:null,priceBoundary:null};
 const conditional=row.win/(1-row.push),loss=1-row.win-row.push;
 const basis=row.forecastBasis||report.basis,anchored=basis==='market_anchored';
 const label=row.selection.market==='h2h'?`${row.selection.outcome} moneyline`:row.selection.market==='spreads'?`${row.selection.outcome} ${row.selection.point>=0?'+':''}${row.selection.point}`:`${row.selection.participant?row.selection.participant+' ':''}${row.selection.outcome.toLowerCase()} ${row.selection.point}`;
 const direction=Math.abs(conditional-.5)<.005?'balanced':conditional>.5?'favors_selection':'against_selection';
 const judgment={selection:row.selection,basis,conditionalChance:conditional,pushChance:row.push,direction,
  text:`${anchored?'Market-based outlook':'Experimental model outlook'}: ${Math.round(conditional*100)}% for ${label}, excluding pushes.${row.push>0?' Push chance '+Math.round(row.push*100)+'%.':''} ${direction==='balanced'?'Neither side has a clear modeled majority.':direction==='favors_selection'?'The estimate favors this outcome occurring.':'The estimate does not favor this outcome occurring.'} This does not establish value at the offered price.`,
  opposingCase:`${Math.round(loss/(1-row.push)*100)}% modeled chance of this selection losing, excluding pushes. ${anchored?'This outlook incorporates sportsbook prices; it is not independent evidence of a market mistake.':'This estimate remains unvalidated on future games.'}`};
 const threshold=row.win>0?(1-row.push)/row.win:null;
 const priceBoundary=threshold&&threshold>1&&Number.isFinite(threshold)?{selection:row.selection,minimumDecimal:threshold,observedDecimal:row.decimal,
  relation:Number.isFinite(row.decimal)?row.decimal<threshold-1e-8?'below_model_threshold':row.decimal>threshold+1e-8?'above_model_threshold':'at_model_threshold':'unknown',
  linePolicy:'This threshold applies only to this exact side and line. A different line requires a new calculation; no alternate-line cutoff has been established.',
  notice:'Experimental break-even threshold, not an acceptable-to-bet price. Better odds alone do not establish an edge.'}:null;
 return {judgment,priceBoundary};
}

export function answerFollowUps(report,row){
 const day=new Intl.DateTimeFormat('en-CA',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(report.event.startsAt));
 const game=`${report.event.away} at ${report.event.home}`,base=`Analyze ${game} on ${day}`;
 const s=row?.selection,market=s?.market;
 const selection=s?market==='h2h'?`${s.outcome} moneyline`:market==='spreads'?`${s.outcome} spread line ${s.point}`:`${s.participant||'game total'} ${market==='player_reception_yds'?'receiving yards':market==='player_pass_yds'?'passing yards':market==='player_rush_yds'?'rushing yards':market==='player_receptions'?'receptions':''} ${s.outcome.toLowerCase()} ${s.point}`:null;
 return [
  {label:market==='totals'?'Compare the spread':'Compare the total',query:`${base} ${market==='totals'?'spread':'game total'}`},
  ...(selection?[{label:'Show the opposing case',query:`${['h2h','spreads'].includes(market)?'Analyze '+selection+' on '+day:base+' '+selection}. What argues against it?`}]:[]),
  {label:'Show the matchup',query:`${base} quarterback roles and efficiency`},
 ];
}
