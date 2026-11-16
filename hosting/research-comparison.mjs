/* Evidence completeness ranks research comparisons, never bet profitability. */
const labels={spreads:'Spread',totals:'Game total',h2h:'Moneyline',props:'Player props'};
export function compareResearch(report){
  const now=Date.parse(report.createdAt);
  const options=report.categories.map(category=>{
    const rows=category.rows.filter(r=>!r.blocked);
    const candidates=rows.map(row=>{
      const same=rows.filter(r=>JSON.stringify(r.selection)===JSON.stringify(row.selection));
      const books=new Set(same.map(r=>r.bookId)).size;
      const age=Math.max(0,(now-Date.parse(row.sourceAt))/60000);
      const paired=Number.isFinite(row.baseline);
      // No EV, model probability or historical winning percentage enters priority.
      const quality=(paired?4:0)+(books>=2?2:0)+(age<=120?1:0);
      return {row,books,age,paired,quality};
    }).filter(c=>Number.isFinite(c.age));
    candidates.sort((a,b)=>b.quality-a.quality||a.age-b.age||b.row.decimal-a.row.decimal||a.row.id.localeCompare(b.row.id));
    const best=candidates[0];
    if(!best)return {market:category.market,label:labels[category.market],status:category.rows.length?'blocked':'missing_price',selection:null,reason:category.rows.length?'Available selections have unresolved player-role or availability concerns.':'No usable saved price in this market.',priority:null};
    return {market:category.market,label:labels[category.market],status:'research_only',selection:best.row.selection,book:best.row.book,decimal:best.row.decimal,sourceAt:best.row.sourceAt,
      pairedMarket:best.paired,books:best.books,priority:best.quality,
      reason:`${best.paired?'A same-book opposing price supports a market baseline.':'An opposing price is missing; no paired market baseline.'} ${best.books} books have this exact selection. ${best.age>120?'The observation is over two hours old.':'The observation is within two hours.'}`};
  });
  const ranked=options.filter(o=>o.selection).sort((a,b)=>b.priority-a.priority||a.market.localeCompare(b.market));
  const top=ranked[0],tied=top?ranked.filter(o=>o.priority===top.priority):[];
  return {version:'research-comparison-v1',basis:'evidence_completeness',action:'pass',hasEdge:false,recommendationsReady:false,
    headline:!top?'No supported priced comparison':tied.length>1?'Several markets have comparable evidence':'The clearest price comparison to inspect',
    leadingMarket:tied.length===1?top.market:null,options,
    notice:'Priority reflects price coverage and freshness, not a stronger bet. All models remain unvalidated for a betting edge. Lineup concerns, settlement rules and source age still require review.'};
}
