import test from 'node:test';
import assert from 'node:assert/strict';
import {officialInjuryReports,collectOfficialInjuries} from './official-injuries.mjs';
const now=Date.UTC(2026,10,15,12),event={id:'nflverse:2026_11_BUF_KC',homeCode:'KC',awayCode:'BUF',startsAt:'2026-11-16T01:15:00Z'};
const index={events:[event],players:[{id:'p',name:'Recorded Player',position:'WR',team:'BUF',events:[event.id]}]};
const table=rows=>'<table><thead>Player Position Injuries Practice Status Game Status</thead><tbody>'+rows+'</tbody></table>';
const row=(name,status)=>`<tr><td>${name}</td><td>WR</td><td>Knee</td><td>Limited Participation in Practice</td><td>${status}</td></tr>`;
const html=()=>`2026 NFL Injury Report Injuries - WEEK 11<h2 class="d3-o-section-title">SUNDAY, NOVEMBER 15TH</h2><section class="nfl-o-injury-report__unit"><span class="nfl-c-matchup-strip__team-abbreviation">BUF</span><span class="nfl-c-matchup-strip__team-abbreviation">KC</span>${table(row('Recorded Player','Out'))}${table('')}</section>`;
test('official designations require exact season/week/matchup/day/name and retain unknown publication time',()=>{
 const found=officialInjuryReports(html(),index,now);assert.equal(found.observations.length,1);const o=found.observations[0];assert.equal(o.confirmed,true);assert.equal(o.value.status,'Out');assert.equal(o.value.publishedAt,null);assert.equal(o.value.reportedUpdatedAt,null);
 for(const text of [html().replace('WEEK 11','WEEK 10'),html().replace('2026 NFL','2025 NFL'),html().replace('NOVEMBER 15TH','NOVEMBER 16TH'),html().replace('>BUF<','>DAL<'),html().replace('Recorded Player','Other Player'),html().replace('>Out<','><')])assert.equal(officialInjuryReports(text,index,now).observations.length,0);
 assert.equal(officialInjuryReports(html(),{...index,contextPlayers:[{...index.players[0],id:'duplicate'}]},now).observations.length,0);
});
test('official injury refresh stays bounded and an unavailable source cannot become confirmation',async()=>{
 let calls=0;const fetch=async()=>{calls++;return html();};const first=await collectOfficialInjuries(index,null,now,fetch);
 assert.equal(first.source.state,'official_designations');assert.equal(calls,1);
 const previous={sources:[first.source],observations:first.observations};await collectOfficialInjuries(index,previous,now+60000,fetch);assert.equal(calls,1);
 const failed=await collectOfficialInjuries(index,previous,now+13*60000,async()=>{throw Error('offline');});assert.equal(failed.observations.length,0);assert.equal(failed.source.state,'unavailable');
});
