/* Dated observations for charts. Never turn missing records into zeroes. */
import {spreadHandicap} from './selection-focus.mjs';
const norm=s=>String(s||'').toLowerCase().replace(/[^a-z0-9 ]/g,'').replace(/\s+/g,' ').trim();
const METRICS={passing_yards:'Passing yards',rushing_yards:'Rushing yards',receiving_yards:'Receiving yards',receptions:'Receptions',attempts:'Pass attempts',carries:'Carries',targets:'Targets'};
const marketMetric={player_pass_yds:'passing_yards',player_rush_yds:'rushing_yards',player_reception_yds:'receiving_yards',player_receptions:'receptions'};
export function visualEvidence(source,event,report,question,now,quotes=[]){
 const cutoff=source.index.cutoff||report.cutoff;
 const earlier=r=>typeof r.date==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(r.date)&&r.date<=cutoff&&Date.parse(r.date+'T00:00:00Z')<now;
 const q=' '+norm(question)+' ';
 const selected=(source.index.players||[]).filter(p=>p.events.includes(event.id)&&q.includes(' '+norm(p.name)+' '));
 const selection=report.decision?.price?.selection;
 const explicitMetric=/\breceptions\b/i.test(question)?'receptions':/\breceiving\b/i.test(question)?'receiving_yards':/\bpassing\b/i.test(question)?'passing_yards':/\brushing\b/i.test(question)?'rushing_yards':null;
 const explicit=question.match(/\b(over|under)\s+(\d+(?:\.\d+)?)/i);
 const players=selected.length===1?selected.map(p=>{
  const metric=explicitMetric||marketMetric[selection?.market]||({QB:'passing_yards',RB:'rushing_yards',WR:'receiving_yards',TE:'receiving_yards'})[p.position];
  const rows=[...new Map(p.games.filter(earlier).sort((a,b)=>b.date.localeCompare(a.date)).map(g=>[g.date,g])).values()].slice(0,10).reverse();
  const relevant=({QB:['passing_yards','attempts','rushing_yards','carries'],RB:['rushing_yards','carries','receiving_yards','receptions','targets'],WR:['receiving_yards','receptions','targets'],TE:['receiving_yards','receptions','targets']})[p.position]||[];
  const series=Object.entries(METRICS).filter(([key])=>(relevant.includes(key)||key===metric)&&rows.some(g=>Number.isFinite(g.stats?.[key]))).map(([key,label])=>({metric:key,label,samples:rows.map(g=>({date:g.date,label:'W'+g.week,value:Number.isFinite(g.stats?.[key])?g.stats[key]:null}))}));
  const line=explicit?Number(explicit[2]):selection?.participant===p.name&&marketMetric[selection.market]===metric?selection.point:null;
  return {id:p.id,name:p.name,team:p.team,position:p.position,metric,line:Number.isFinite(line)?line:null,side:explicit?.[1].toLowerCase()||selection?.outcome?.toLowerCase()||null,lineSource:explicit?'Requested line':Number.isFinite(line)?'Saved quote line':null,series,workloadMetrics:{passing_yards:'attempts',rushing_yards:'carries',receiving_yards:'targets',receptions:'targets'}};
 }):[];
 const teams=['away','home'].map(side=>{
  const name=event[side];
  const games=[...new Map((source.index.results||[]).filter(r=>r.eventId!==event.id&&earlier(r)&&[r.home,r.away].includes(name)&&Number.isFinite(r.homeScore)&&Number.isFinite(r.awayScore)).sort((a,b)=>b.date.localeCompare(a.date)).map(r=>[r.eventId,r])).values()].slice(0,6).reverse();
  return {name,code:event[side+'Code'],samples:games.map(g=>({date:g.date,label:g.date.slice(5),opponent:g.home===name?g.away:g.home,value:g.home===name?g.homeScore:g.awayScore,secondary:g.home===name?g.awayScore:g.homeScore}))};
 });
 const named=teams.filter(t=>[t.name,t.name.split(' ').at(-1),t.code].filter(Boolean).some(alias=>q.includes(' '+norm(alias)+' ')));
 const selectedTeam=named.length===1?named[0].name:selection?.market==='spreads'?selection.outcome:event.home;
 const mode=!players.length&&/\b(spread|cover)\b/i.test(question)?'margin':!players.length&&/\btotal\b|over.?under/i.test(question)?'total':'scoring';
 const handicap=mode==='margin'?spreadHandicap(question):null;
 const spread=handicap??(mode==='margin'&&selection?.market==='spreads'?selection.point:null);
 const totalText=question.replace(/\b20\d{2}-\d{2}-\d{2}\b/g,'').match(/(?:total|line)\s*(?:of\s+|at\s+)?(\d+(?:\.\d+)?)/i)?.[1];
 const totalLine=mode==='total'?(explicit?Number(explicit[2]):totalText!=null?Number(totalText):selection?.market==='totals'?selection.point:null):null;
 for(const team of teams){
  const threshold=team.name===selectedTeam&&Number.isFinite(spread)?(spread===0?0:-spread):null;
  team.series=[{metric:'scoring',label:'Points scored & allowed',paired:true,samples:team.samples},
   {metric:'margin',label:'Winning / losing margin',line:threshold,lineSource:'Margin needed',comparisonNote:threshold==null?null:`${team.name} ${spread>=0?'+':''}${spread}: the margin must exceed ${threshold}. Equal to the threshold is a push in this comparison.`,samples:team.samples.map(s=>({...s,value:s.value-s.secondary,secondary:null}))},
   {metric:'total',label:'Combined game score',line:Number.isFinite(totalLine)?totalLine:null,lineSource:'Comparison total',samples:team.samples.map(s=>({...s,value:s.value+s.secondary,secondary:null}))}];
 }
 const same=(a,b)=>['eventId','market','participant','outcome','point','period','rules'].every(k=>(a[k]??null)===(b[k]??null));
 const observed=quotes.length?quotes:(report.categories||[]).flatMap(c=>c.rows||[]);
 const priceSelection=report.decision?.focus==='game'?null:selection;
 const offers=priceSelection?[...new Map(observed.filter(r=>r.selection&&same(r.selection,priceSelection)&&r.blocked!==true&&Number.isFinite(r.decimal)&&r.decimal>1&&Date.parse(r.sourceAt)<=now&&now-Date.parse(r.sourceAt)<=18*3600000&&Date.parse(r.collectedAt||r.sourceAt)<=now&&Date.parse(r.collectedAt||r.sourceAt)>=Date.parse(r.sourceAt)).sort((a,b)=>Date.parse(a.sourceAt)-Date.parse(b.sourceAt)||Date.parse(a.collectedAt||a.sourceAt)-Date.parse(b.collectedAt||b.sourceAt)).map(r=>[r.bookId||r.book,r])).values()].map(r=>({bookId:r.bookId,book:r.book,decimal:r.decimal,sourceAt:r.sourceAt,collectedAt:r.collectedAt||r.sourceAt})).sort((a,b)=>b.decimal-a.decimal||a.book.localeCompare(b.book)):[];
 return {schemaVersion:1,focus:players.length?'player':'team',selectedTeam,teamMetric:mode,cutoff,source:'nflverse recorded box scores',sourceUrl:'https://github.com/nflverse/nflverse-data',teams,players,priceComparison:{selection:priceSelection||null,checkedAt:new Date(now).toISOString(),offers:offers.slice(0,12),status:offers.length?'saved_exact_selection':'missing_exact_selection',notice:'Saved observations only. A higher price is a better payout for this identical selection, not proof of value. Recheck availability and rules at the sportsbook.'},notice:'Recorded results only, not a forecast. Prior games use their actual opponents; the displayed line is today’s comparison threshold, not those games’ historical sportsbook lines.'};
}
