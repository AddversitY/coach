/* Free scoreboard finals grade game markets only; absent box scores remain absent. */
export const FINAL_INTERVAL=15*60000;
const club=s=>({WSH:'WAS',LA:'LAR',OAK:'LV',SD:'LAC'})[s]||s;
export const easternDate=t=>new Intl.DateTimeFormat('en-CA',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(t));
export function scoreboardFinals(raw,targets,now,url){
 if(!Array.isArray(raw?.events)||raw.events.length>40)throw new Error('Invalid scoreboard');
 const results=[];
 for(const event of targets){
  const id=event.id.match(/^nflverse:(20\d{2})_\d{2}_([A-Z]+)_([A-Z]+)$/);if(!id)continue;
  const candidates=raw.events.filter(r=>Number(r.season?.year)===Number(id[1])&&r.competitions?.length===1&&Math.abs(Date.parse(r.date)-Date.parse(event.startsAt))<=5*60000);
  const matching=candidates.filter(r=>{const c=r.competitions[0];return c.status?.type?.completed===true&&c.status.type.state==='post'&&c.competitors?.length===2&&c.competitors.some(t=>t.homeAway==='home'&&club(t.team?.abbreviation)===id[3])&&c.competitors.some(t=>t.homeAway==='away'&&club(t.team?.abbreviation)===id[2]);});
  if(matching.length!==1)continue;
  const c=matching[0].competitions[0],score=side=>Number(c.competitors.find(t=>t.homeAway===side).score),homeScore=score('home'),awayScore=score('away');
  if(![homeScore,awayScore].every(n=>Number.isInteger(n)&&n>=0&&n<=100)||c.competitors.some(t=>t.score==null||t.score==='')||now<Date.parse(event.startsAt))continue;
  results.push({eventId:event.id,homeScore,awayScore,playerStats:{},playerTeams:{},evidence:{source:'ESPN final scoreboard',url,providerEventId:matching[0].id,checkedAt:new Date(now).toISOString(),state:'final',scope:'Game scores only. Player outcomes await recorded box scores.'}});
 }
 return results;
}
export async function collectFinals(targets,previous,now,fetchJson){
 const relevant=targets.filter(e=>Date.parse(e.startsAt)<=now&&now-Date.parse(e.startsAt)<72*3600000).slice(0,48);
 if(!relevant.length)return {results:[],source:{state:'no_recent_captured_games',checkedAt:new Date(now).toISOString()}};
 const signature=relevant.map(e=>e.id).sort().join('|');
 const age=now-Date.parse(previous?.source?.attemptedAt||previous?.source?.checkedAt);
 if(previous?.source?.signature===signature&&age>=0&&age<FINAL_INTERVAL)return previous;
 const results=[],dates=[...new Set(relevant.map(e=>easternDate(Date.parse(e.startsAt))))].slice(0,3);
 try{
  for(const date of dates){
   const url='https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard?dates='+date.replaceAll('-','')+'&limit=40';
   results.push(...scoreboardFinals(await fetchJson(url,2_000_000),relevant.filter(e=>easternDate(Date.parse(e.startsAt))===date),now,url));
  }
  return {results,source:{state:results.length?'final_scores_available':'awaiting_final',signature,checkedAt:new Date(now).toISOString(),refreshMinutes:15}};
 }catch{return {results:previous?.results||[],source:{...previous?.source,state:'unavailable',signature,attemptedAt:new Date(now).toISOString(),refreshMinutes:15}};}
}
