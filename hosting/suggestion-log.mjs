// Log what Coach would suggest right now, so it can be graded by closing line value later.
//
// It runs the same analyzeGame the Worker uses for a game answer, on prices from
// assets/price-history.json, and keeps the top ranked rows for each upcoming game.
// A row's price, book and time are saved as they were. Nothing here is a pick.
import {analyzeGame} from './game-analysis.mjs';
import {BOOKS} from './book-preference.mjs';

const GAME_MARKETS=new Set(['h2h','spreads','totals']);
const PROP_MARKETS=new Set(['player_pass_yds','player_rush_yds','player_reception_yds','player_receptions']);
export const SUGGESTIONS_PER_GAME=3;

const minuteKey=t=>String(t||'').slice(0,16);

/** Match an index event to price-history rows by team codes and kickoff minute. */
export function eventRows(index,history,event){
  return (history.observations||[]).filter(r=>r.home===event.homeCode&&r.away===event.awayCode&&minuteKey(r.kickoff)===minuteKey(event.startsAt));
}

/** The newest snapshot (one `at`) of rows for an event, as published-snapshot quotes. */
export function snapshotFor(index,history,event){
  const rows=eventRows(index,history,event).filter(r=>BOOKS[r.book]&&(GAME_MARKETS.has(r.market)||PROP_MARKETS.has(r.market)));
  if(!rows.length)return null;
  const at=rows.map(r=>r.at).sort().at(-1);
  const latest=rows.filter(r=>r.at===at);
  const names={[event.homeCode]:event.home,[event.awayCode]:event.away};
  const players=new Map();
  for(const p of index.players||[])if(p.events?.includes(event.id))players.set(p.name,p.id);
  const quotes=[];
  for(const r of latest){
    const game=GAME_MARKETS.has(r.market);
    let outcome=r.outcome;
    if(game&&r.market!=='totals')outcome=names[r.outcome]||r.outcome;
    if(!game&&!players.has(r.player))continue;
    quotes.push({provider:'the-odds-api',bookId:r.book,book:BOOKS[r.book],status:'open',decimal:r.decimal,sourceAt:r.at,collectedAt:r.at,
      selection:{eventId:event.id,market:r.market,participant:game?'':r.player,outcome,point:r.market==='h2h'?null:r.line,period:'full_game',rules:game?'game_market_unverified':'player_prop_unverified'}});
  }
  if(!quotes.length)return null;
  const coverage=[...new Set(quotes.filter(q=>q.selection.participant).map(q=>q.selection.participant))].map(name=>({name,playerId:players.get(name)}));
  return {at,snapshot:{schemaVersion:1,odds:{status:'ok',provider:'the-odds-api',fetchedAt:at,coverage:{players:coverage}},props:{fetchedAt:at,quotes}}};
}

const side=(s,event)=>s.market==='totals'||PROP_MARKETS.has(s.market)?s.outcome.toLowerCase():s.outcome===event.home?'home':'away';

/** Coach's top ranked rows for every upcoming game with a fresh snapshot. */
export function suggestions(index,history,now=Date.now(),perGame=SUGGESTIONS_PER_GAME){
  const out=[],skipped=[];
  for(const event of index.events||[]){
    if(Date.parse(event.startsAt)<=now)continue;
    const built=snapshotFor(index,history,event);
    if(!built){skipped.push({event:event.id,reason:'no saved prices'});continue;}
    let report;
    try{report=analyzeGame({index,snapshot:built.snapshot},event,{now,includeProduction:false});}
    catch(error){skipped.push({event:event.id,reason:String(error.message||error)});continue;}
    const seen=new Set();
    const rows=(report.ranked||[]).filter(row=>{const key=JSON.stringify(row.selection);if(seen.has(key))return false;seen.add(key);return true;});
    for(const row of rows.slice(0,perGame)){
      const s=row.selection;
      out.push({at:built.at,loggedAt:new Date(now).toISOString(),eventId:event.id,away:event.awayCode,home:event.homeCode,kickoff:event.startsAt,
        market:s.market,player:s.participant||'',side:side(s,event),outcome:s.outcome,line:s.point??null,book:row.bookId,decimal:row.decimal,
        chance:Math.round(row.win*1e6)/1e6,push:Math.round((row.push||0)*1e6)/1e6,ev:Math.round(row.conditionalEv*1e4)/1e4,basis:row.forecastBasis});
    }
  }
  return {suggestions:out,skipped};
}

if(import.meta.url===`file://${process.argv[1]}`){
  const fs=await import('node:fs');
  const [indexPath,historyPath,outPath]=process.argv.slice(2).filter(a=>!a.startsWith('--'));
  const index=JSON.parse(fs.readFileSync(indexPath,'utf8'));
  const history=JSON.parse(fs.readFileSync(historyPath,'utf8'));
  let result;
  if(process.argv.includes('--backfill')){
    // Replay every saved snapshot as if Coach had answered one minute after it.
    // Only prices saved up to that moment are visible to the replay.
    result={suggestions:[],skipped:[]};
    for(const at of [...new Set((history.observations||[]).map(r=>r.at))].sort()){
      const now=Date.parse(at)+60000;
      const visible={...history,observations:history.observations.filter(r=>r.at<=at)};
      const part=suggestions(index,visible,now);
      result.suggestions.push(...part.suggestions.filter(s=>s.at===at));
    }
  }else result=suggestions(index,history,Date.now());
  fs.writeFileSync(outPath,JSON.stringify(result,null,1)+'\n');
  console.log(JSON.stringify({suggestions:result.suggestions.length,skipped:result.skipped.length}));
}
