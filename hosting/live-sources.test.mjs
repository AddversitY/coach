import test from 'node:test';
import assert from 'node:assert/strict';
import {injuryReports,collectInjuries,newsReports,collectNews,marketMovements,marketSplitReports} from './live-sources.mjs';

const clock=Date.UTC(2026,10,16,12),at=new Date(clock).toISOString();
const e={id:'game',home:'Buffalo Bills',away:'Kansas City Chiefs',startsAt:new Date(clock+3_600_000).toISOString()};
const index={events:[e,{...e,id:'next-week',startsAt:new Date(clock+8*86400000).toISOString()}],players:[{id:'p',name:'Recorded Player',team:'BUF',events:['game','next-week']}]};
const raw={timestamp:at,season:{year:2026},injuries:[{injuries:[{date:at,status:'Out',athlete:{displayName:'Recorded Player',team:{abbreviation:'BUF'}}}]}]};
const rss=(items,ttl=30)=>`<rss xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><ttl>${ttl}</ttl>${items}</channel></rss>`;
const item=(title='Bills injury update',url='https://www.espn.com/nfl/story/_/id/123/example',date=at)=>`<item><title>${title}</title><link>${url}</link><pubDate>${date}</pubDate><dc:creator>Test Reporter</dc:creator></item>`;

test('injury scope is the next game only, with original report time and no participation guarantee',()=>{
  const rows=injuryReports(raw,index,at);
  assert.equal(rows.length,1);assert.equal(rows[0].eventId,'game');assert.equal(rows[0].confirmed,false);
  assert.equal(rows[0].value.reportedUpdatedAt,at);assert.match(rows[0].value.notice,/not confirmation/);
  const wrong=structuredClone(raw);wrong.season.year=2025;assert.equal(injuryReports(wrong,index,at).length,0);
  const future=structuredClone(raw);future.injuries[0].injuries[0].date=new Date(clock+1000).toISOString();assert.equal(injuryReports(future,index,at).length,0);
  assert.throws(()=>injuryReports({...raw,timestamp:new Date(clock-3*3600000).toISOString()},index,at),/Stale/);
});

test('injury polling permits the large feed but caches it; failure preserves timestamps and retries with backoff',async()=>{
  let calls=0;
  const fetch=async(_,limit)=>{calls++;assert.equal(limit,16_000_000);return raw;};
  const first=await collectInjuries(index,null,clock,fetch);
  const saved={observations:first.observations,sources:[first.source]};
  await collectInjuries(index,saved,clock+60000,fetch);assert.equal(calls,1);
  const failed=await collectInjuries(index,saved,clock+11*60000,async()=>{throw Error('offline');});
  assert.equal(failed.source.state,'unavailable');assert.equal(failed.source.checkedAt,at);assert.equal(failed.observations[0].observedAt,at);
  const stale=await collectInjuries(index,{observations:failed.observations,sources:[failed.source]},clock+14*60000,async()=>{assert.fail('Backoff prevents another download');});
  // Source failure cannot turn an older status into a fresh report.
  assert.equal(stale.source.checkedAt,at);assert.equal(stale.observations.length,0);
});

test('RSS retains author, original link/date, refuses external URLs, entities and future stories',()=>{
  const result=newsReports(rss(item('Recorded Player &amp; the Bills')),index,clock);
  assert.equal(result.ttlMinutes,30);assert.equal(result.observations[0].value.author,'Test Reporter');
  assert.equal(result.observations[0].playerId,'p');assert.equal(result.observations[0].value.title,'Recorded Player & the Bills');
  assert.equal(result.observations[0].confirmed,false);
  assert.equal(newsReports(rss(item('Bills','https://evil.example/nfl/report')),index,clock).observations.length,0);
  assert.equal(newsReports(rss(item('Bills',undefined,new Date(clock+1).toISOString())),index,clock).observations.length,0);
  assert.throws(()=>newsReports('<!DOCTYPE rss [<!ENTITY x "bad">]>'+rss(item()),index,clock),/Invalid RSS/);
  assert.throws(()=>newsReports('<rss><channel><item>',index,clock),/Invalid RSS/);
});

test('news respects publisher TTL and preserves league-wide scope rather than assigning an unrelated player',async()=>{
  let calls=0;const pull=async()=>{calls++;return rss(item('League-wide update'),60);};
  const first=await collectNews(index,null,clock,pull);
  assert.equal(first.observations[0].eventId,'nfl');assert.equal(first.observations[0].playerId,undefined);
  assert.equal(first.source.refreshMinutes,60);
  await collectNews(index,{observations:first.observations,sources:[first.source]},clock+31*60000,pull);
  assert.equal(calls,1);
});

const snapshot=(price=1.91,line=65.5,time=clock)=>({odds:{},props:{fetchedAt:new Date(time).toISOString(),quotes:[{selection:{eventId:'game',market:'player_pass_yds',participant:'Recorded Player',outcome:'Over',point:line},bookId:'b',book:'Book',provider:'test',status:'open',demo:false,decimal:price,sourceAt:new Date(time).toISOString(),collectedAt:new Date(time).toISOString()}]}});
test('market history compares matching observations and never manufactures movement from a re-read',()=>{
  const first=marketMovements(snapshot(),index,[],clock);assert.equal(first.observations.length,0);
  assert.equal(marketMovements(snapshot(),index,first.state,clock+1000).observations.length,0);
  const next=marketMovements(snapshot(1.85,66.5,clock+60000),index,first.state,clock+60000);
  assert.equal(next.observations.length,1);assert.equal(next.observations[0].value.fromLine,65.5);assert.equal(next.observations[0].value.toLine,66.5);
  assert.equal(next.observations[0].value.fromSourceAt,at);assert.match(next.observations[0].value.notice,/not a verified/);
  const repeated=marketMovements(snapshot(1.85,66.5,clock+60000),index,next.state,clock+120000);
  assert.deepEqual(repeated.observations,next.observations);
  const other=snapshot(1.85,66.5,clock+60000);other.props.quotes[0].bookId='different';
  assert.equal(marketMovements(other,index,first.state,clock+60000).observations.length,0);
});

test('ambiguous alternate lines, future quotes and fixtures cannot become signals',()=>{
  const multi=snapshot();multi.props.quotes.push({...multi.props.quotes[0],selection:{...multi.props.quotes[0].selection,point:75.5}});
  assert.equal(marketMovements(multi,index,[],clock).coverage,0);
  assert.equal(marketMovements(snapshot(1.91,65.5,clock+1),index,[],clock).coverage,0);
  const fake=snapshot();fake.odds.testFixture=true;assert.equal(marketMovements(fake,index,[],clock).coverage,0);
});

test('an early total survives a missed snapshot and compares with the next fresh quote',()=>{
  const later=clock+27*3600000;
  const slate={...index,events:[{...e,startsAt:new Date(later+3600000).toISOString()}]};
  const total=(line,time,rules='game_market_unverified')=>{
    const data=snapshot(1.91,line,time);
    data.props.quotes[0].selection={eventId:'game',market:'totals',outcome:'Under',point:line,period:'full_game',rules};
    return data;
  };
  const first=marketMovements(total(43,clock),slate,[],clock);
  const gap=marketMovements({},slate,first.state,later);
  assert.equal(gap.coverage,0);
  assert.deepEqual(gap.state,first.state);
  const next=marketMovements(total(38,later),slate,gap.state,later);
  assert.equal(next.observations.length,1);
  assert.equal(next.observations[0].value.fromLine,43);
  assert.equal(next.observations[0].value.toLine,38);
  const crossBook = total(38,later);
  for (const [bookId,point,decimal] of [['close',42,1.91],['worse-payout',43,1.87],['close2',40,1.94]]) {
    const original = crossBook.props.quotes[0];
    crossBook.props.quotes.push({...original,bookId,book:bookId,decimal,selection:{...original.selection,point}});
  }
  assert.equal(marketMovements(crossBook,slate,gap.state,later).observations[0].value.alternative?.line,42);
  assert.equal(marketMovements(total(38,later,'other'),slate,gap.state,later).observations.length,0);
  assert.equal(marketMovements({},slate,next.state,later+3600000).state.length,0);
});

test('provider adapter validates attribution, times, percentages and exact upcoming games',()=>{
  const body={kind:'market_splits',provider:'Test provider',sourceUrl:'https://provider.example/public',publishedAt:at,records:[{eventId:'game',market:'spreads',outcome:'Buffalo Bills',line:-3.5,betPercent:40,moneyPercent:60}]};
  const result=marketSplitReports(body,index,clock,['provider.example']);
  assert.equal(result.observations[0].value.moneyPercent,60);assert.equal(result.observations[0].confirmed,false);
  assert.match(result.observations[0].value.notice,/Not proof of sharp/);
  for(const changed of [{...body,sourceUrl:'https://evil.example/public'},{...body,sourceUrl:'https://provider.example/public?token=private'},{...body,publishedAt:new Date(clock+1).toISOString()},{...body,records:[{...body.records[0],moneyPercent:101}]}])assert.throws(()=>marketSplitReports(changed,index,clock,['provider.example']));
});
