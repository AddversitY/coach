/* Coverage selects research priorities; forecast optimism never enters the ranking. */
const labels={spreads:'Spread',totals:'Game total',h2h:'Moneyline',props:'Player props'};
const key=s=>JSON.stringify(['eventId','market','participant','outcome','point','period','rules'].map(k=>s?.[k]??null));
const unique=values=>[...new Set(values.filter(Boolean))];
function evidence(report,row,market,age,books){
 const paired=Number.isFinite(row.baseline),teams=report.visualEvidence?.teams||[];
 const projection=report.projections?.find(p=>p.playerId===row.playerId&&p.market===row.selection.market);
 const team=report.context?.teams?.find(t=>t.usage?.some(p=>p.playerId===row.playerId));
 const usage=team?.usage?.find(p=>p.playerId===row.playerId);
 const history=market==='props'?(projection?.records||0)>=5:teams.length===2&&teams.every(t=>t.samples?.length>=3);
 const workload=market==='props'&&(usage?.appearances||0)>=3&&Number.isFinite(usage?.recentMean);
 const alerts=(report.context?.alerts||[]).filter(a=>market!=='props'||!team||a.team===team.code);
 const contextReview=alerts.length>0||row.contextWarnings?.length>0;
 const confirmed=market==='props'?team?.lineupReview?.starterConfirmed===true:report.context?.participation?.confirmedStartersAvailable===true;
 const criteria=[
  {id:'paired',label:'Opposing price',state:paired?'present':'missing'},
  {id:'books',label:'Multiple books',state:books>=2?'present':'missing'},
  {id:'fresh',label:'Within two hours',state:age<=120?'present':'review'},
  {id:'history',label:'Recorded history',state:history?'present':'missing'},
  {id:'context',label:'Lineup clarity',state:contextReview?'review':confirmed?'present':'unknown'},
  ...(market==='props'?[{id:'workload',label:'Workload records',state:workload?'present':'missing'}]:[]),
 ];
 const facts=[];
 if(history&&market!=='props'){
  if(market==='totals')for(const t of teams)facts.push(`${t.name}: ${(t.samples.reduce((n,s)=>n+s.value+s.secondary,0)/t.samples.length).toFixed(1)} combined points on average across ${t.samples.length} prior games against different opponents.`);
  else{const t=teams.find(t=>t.name===row.selection.outcome);if(t){const wins=t.samples.filter(s=>s.value>s.secondary).length,losses=t.samples.filter(s=>s.value<s.secondary).length;
   facts.push(market==='spreads'?`${t.name}: ${(t.samples.reduce((n,s)=>n+s.value-s.secondary,0)/t.samples.length).toFixed(1)} average prior margin across ${t.samples.length} games.`:`${t.name}: ${wins} wins, ${losses} losses and ${t.samples.length-wins-losses} ties in the displayed history.`);}}
 }
 if(market==='props'&&projection)facts.push(`${projection.records} recorded appearances support this player's production history.`);
 if(workload)facts.push(`Recorded ${usage.metric}: ${usage.recentMean.toFixed(1)} per game in the latest window${Number.isFinite(usage.priorMean)?', versus '+usage.priorMean.toFixed(1)+' in the preceding window':''}. This is not expected playing time.`);
 const risks=unique([
  !paired?'An opposing quote is missing; the market reference is incomplete.':null,
  age>120?`The selected quote is ${Math.max(2,Math.round(age/60))} hours old. Refresh the exact line and price.`:null,
  !history?'The recorded-history coverage needed for this comparison is missing.':null,
  ...alerts.map(a=>a.text),...(row.contextWarnings||[]),
  !confirmed?'Upcoming starters or player participation remain unconfirmed.':null,
  market==='props'&&!workload?'Current workload context is incomplete.':null,
 ]);
 return {criteria,facts,risks,history,workload,contextReview,paired,
  quality:(paired?4:0)+(books>=2?2:0)+(age<=120?1:0)+(history?2:0)+(workload?1:0)+(confirmed&&!contextReview?1:0),
  reviewable:paired&&history&&age<=120&&!contextReview};
}
export function compareResearch(report){
 const now=Date.parse(report.createdAt);
 const options=report.categories.map(category=>{
  const rows=category.rows.filter(r=>!r.blocked&&r.selection&&Number.isFinite(r.decimal)&&r.decimal>1&&Date.parse(r.sourceAt)<=now&&now-Date.parse(r.sourceAt)<=18*3600000);
  const candidates=rows.map(row=>{const books=new Set(rows.filter(r=>key(r.selection)===key(row.selection)).map(r=>r.bookId||r.book)).size,age=(now-Date.parse(row.sourceAt))/60000;
   return {row,books,age,...evidence(report,row,category.market,age,books)};});
  candidates.sort((a,b)=>Number(b.reviewable)-Number(a.reviewable)||b.quality-a.quality||a.age-b.age||key(a.row.selection).localeCompare(key(b.row.selection))||b.row.decimal-a.row.decimal||String(a.row.id).localeCompare(String(b.row.id)));
  const best=candidates[0];
  if(!best)return {market:category.market,label:labels[category.market],status:category.rows.some(r=>r.blocked)?'blocked':'missing_price',selection:null,reason:category.rows.some(r=>r.blocked)?'Available selections have unresolved player-role or availability concerns.':'A saved price in this market is unavailable.',priority:null,criteria:[],facts:[],risks:['A usable exact-selection quote is required.'],researchState:'unavailable',coverage:{present:0,total:0}};
  const alternatives=new Set(candidates.filter(c=>c.quality===best.quality&&c.reviewable===best.reviewable).map(c=>key(c.row.selection))).size;
  return {market:category.market,label:labels[category.market],status:'research_only',selection:best.row.selection,book:best.row.book,decimal:best.row.decimal,sourceAt:best.row.sourceAt,
   pairedMarket:best.paired,books:best.books,priority:best.quality,criteria:best.criteria,facts:best.facts,risks:best.risks,
   equivalentSelections:alternatives,researchState:best.reviewable?'reviewable':best.contextReview?'review_lineup':best.age>120?'refresh_prices':'incomplete_evidence',
   coverage:{present:best.criteria.filter(c=>c.state==='present').length,total:best.criteria.length},
   reason:`${best.paired?'A same-book opposing price supports a market baseline.':'An opposing price is missing; no paired market baseline.'} ${best.books} books have this exact selection. ${best.age>120?'The observation is over two hours old.':'The observation is within two hours.'}`};
 });
 const ranked=options.filter(o=>o.selection).sort((a,b)=>Number(b.researchState==='reviewable')-Number(a.researchState==='reviewable')||b.priority-a.priority||a.market.localeCompare(b.market));
 const top=ranked[0],tied=top?ranked.filter(o=>o.priority===top.priority&&(o.researchState==='reviewable')===(top.researchState==='reviewable')):[];
 const reviewable=tied.length>0&&tied.every(o=>o.researchState==='reviewable');
 const expired=report.priceCoverage?.savedQuotesExpired===true;
 const availability=report.priceCoverage?.availability?.message;
 const headline=!top?'Pass — no supported priced comparison':!reviewable?'Pass for now — key inputs need review':tied.length>1?'Several markets have comparable evidence':'One market has clearer research support';
 let followUps=[];
 if(report.event?.startsAt&&Number.isFinite(Date.parse(report.event.startsAt))){const date=new Intl.DateTimeFormat('en-CA',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(report.event.startsAt));
  followUps=tied.slice(0,3).map(o=>({label:`Inspect ${o.label.toLowerCase()}`,query:`Analyze ${report.event.away} at ${report.event.home} on ${date} ${o.market==='spreads'?'spread':o.market==='totals'?'game total':o.market==='h2h'?'moneyline':o.selection.participant+' '+({player_receptions:'receptions',player_reception_yds:'receiving yards',player_pass_yds:'passing yards',player_rush_yds:'rushing yards'})[o.selection.market]+' '+o.selection.outcome.toLowerCase()+' '+o.selection.point}`}));}
 return {version:'research-comparison-v2',basis:'evidence_completeness',action:'pass',hasEdge:false,recommendationsReady:false,
  headline:!top?'No supported priced comparison':tied.length>1?'Several markets have comparable evidence':'The clearest price comparison to inspect',leadingMarket:tied.length===1?top.market:null,options,
  summary:{version:'research-summary-v1',primary:report.decision?.focus==='game',action:'pass',hasEdge:false,headline,
   state:!top?'insufficient_support':reviewable?tied.length>1?'comparable':'clearer_option':'review_inputs',
   leadingMarkets:tied.map(o=>o.market),text:!top?availability?`${availability} Recorded performance charts remain available; no priced betting comparison is supported.`:expired?'Saved sportsbook quotes have expired, so no priced market comparison is available. The recorded charts below remain available.':'No market has enough usable price evidence to prioritize. Pass until matching quotes arrive.':!reviewable?`No option clears the research checks yet. ${tied.map(o=>o.label).join(', ')} ${tied.length>1?'share the most complete saved coverage; no single winner is forced':'has the most complete saved coverage'}, but unresolved inputs need attention first.`:tied.length>1?`${tied.map(o=>o.label).join(', ')} have equal coverage scores. There is no evidence-based reason to force a single winner.`:`${top.label} has the most complete observed evidence to inspect first. This is a research priority, not a recommendation to bet.`,
   reasons:unique([...(tied.length===1?top.facts.slice(0,2).map(f=>'Recorded context · '+f):[]),tied.some(o=>o.pairedMarket)?'Two-sided prices support a market reference.':null,tied.some(o=>o.books>=2)?'Multiple books cover identical selections.':null,tied.some(o=>o.criteria.some(c=>c.id==='history'&&c.state==='present'))?'Dated performance records are available for review.':null]).slice(0,3),
   blockers:unique([...(!top&&expired?['The saved price snapshot is outside the 18-hour usable window. A new provider observation is needed; re-reading this report does not refresh the quotes.']:[]),...tied.flatMap(o=>o.risks)]).slice(0,3),followUps,
   notice:'Coverage checks measure available evidence, not win probability, predicted profit or model skill. Every model remains unvalidated for a betting edge.'},
  notice:'Priority reflects price coverage, freshness and recorded context, not a stronger bet. Lineup concerns, settlement rules and source age still require review.'};
}
