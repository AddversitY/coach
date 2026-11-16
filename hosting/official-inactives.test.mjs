import test from 'node:test';
import assert from 'node:assert/strict';
import {inactiveArticle,collectOfficialInactives} from './official-inactives.mjs';
const now=Date.UTC(2026,10,16,23),url='https://www.nfl.com/news/week-10-monday-inactives-2026';
const index={events:[{id:'nflverse:2026_10_LAC_BAL',home:'Baltimore Ravens',away:'Los Angeles Chargers',homeCode:'BAL',awayCode:'LAC',startsAt:new Date(now+3600000).toISOString()}],players:[{id:'p',name:'Recorded Player',team:'LAC',position:'WR',events:['nflverse:2026_10_LAC_BAL']},{id:'q',name:'Emergency Player',team:'BAL',position:'QB',events:['nflverse:2026_10_LAC_BAL']}]};
const article=(date=new Date(now-60000).toISOString())=>`<script type="application/ld+json">${JSON.stringify({'@type':'NewsArticle',headline:'Week 10 Monday inactives',datePublished:date})}</script><div class="story-part-rich-text-editor-wrapper"><h3>CHARGERS</h3><ul><li>WR Recorded Player</li></ul><h3>RAVENS</h3><ul><li>QB Emergency Player (emergency third QB)</li></ul></div>`;
test('official names require exact game day, week, team and identity; no active or emergency inference',()=>{
 const rows=inactiveArticle(article(),url,index,now);assert.equal(rows.length,1);assert.equal(rows[0].confirmed,true);assert.equal(rows[0].value.status,'Inactive');assert.equal(rows[0].playerId,'p');
 assert.equal(inactiveArticle(article(new Date(now-86400000).toISOString()),url,index,now).length,0);
 assert.equal(inactiveArticle(article(),url.replace('10','11'),index,now).length,0);
 assert.equal(inactiveArticle(article().replace('RAVENS','BILLS'),url,index,now).length,0);
 assert.throws(()=>inactiveArticle(article(),'https://example.com/news/week-10-inactives-2026',index,now));
});
test('official polling caches checks, preserves failure timestamps and makes no distant-game calls',async()=>{
 let calls=0;const fetch=async u=>{calls++;return u.endsWith('/inactives/')?`<a href="${url}">Report</a>`:article();};
 const result=await collectOfficialInactives(index,null,now,fetch);assert.equal(calls,2);assert.equal(result.observations.length,1);
 const previous={sources:[result.source],observations:result.observations};await collectOfficialInactives(index,previous,now+60000,fetch);assert.equal(calls,2);
 const failed=await collectOfficialInactives(index,previous,now+11*60000,async()=>{throw Error('offline');});assert.equal(failed.source.state,'unavailable');assert.equal(failed.observations[0].observedAt,result.observations[0].observedAt);
 calls=0;await collectOfficialInactives({...index,events:index.events.map(e=>({...e,startsAt:new Date(now+86400000).toISOString()}))},null,now,fetch);assert.equal(calls,0);
});
