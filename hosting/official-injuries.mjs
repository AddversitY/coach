const URL='https://www.nfl.com/injuries/';
export const OFFICIAL_INJURY_SOURCE='NFL.com official injury report';
const clean=s=>String(s||'').replace(/<[^>]*>/g,' ').replace(/&amp;/g,'&').replace(/&#39;|&apos;/g,"'").replace(/&nbsp;/g,' ').replace(/\s+/g,' ').trim();
const norm=s=>clean(s).toLowerCase().replace(/[^a-z0-9]/g,'');
const day=t=>new Intl.DateTimeFormat('en-US',{timeZone:'America/New_York',month:'long',day:'numeric'}).format(new Date(t)).toUpperCase();
export function officialInjuryReports(html,index,clock){
 if(typeof html!=='string'||html.length>2_000_000)throw new Error('Invalid official injury page');
 const year=html.match(/(20\d{2}) NFL Injury Report/)?.[1],week=html.match(/Injuries\s*-\s*WEEK\s+(\d+)/i)?.[1];
 if(!year||!week)throw new Error('Official injury week unavailable');
 const observations=[],matchedEvents=[];
 const sections=html.split('<h2 class="d3-o-section-title">').slice(1);
 for(const section of sections){
  const heading=clean(section.split('</h2>')[0]).replace(/(\d+)(?:ST|ND|RD|TH)\b/g,'$1');
  for(const unit of section.split('<section class="nfl-o-injury-report__unit">').slice(1)){
   const codes=[...unit.matchAll(/class="nfl-c-matchup-strip__team-abbreviation">([\s\S]*?)<\/span>/g)].map(m=>clean(m[1]));
   if(codes.length!==2)continue;
   const events=index.events.filter(e=>{const m=e.id.match(/^nflverse:(20\d{2})_(\d{2})_/);return m&&m[1]===year&&Number(m[2])===Number(week)&&e.awayCode===codes[0]&&e.homeCode===codes[1]&&heading.endsWith(day(Date.parse(e.startsAt)))&&Date.parse(e.startsAt)>clock&&Date.parse(e.startsAt)-clock<=7*86400000;});
   if(events.length!==1)continue;
   const event=events[0],tables=[...unit.matchAll(/<table[^>]*>([\s\S]*?)<\/table>/g)];if(tables.length!==2)continue;
   if(!tables.every(t=>/Player[\s\S]*Position[\s\S]*Injuries[\s\S]*Practice Status[\s\S]*Game Status/.test(clean(t[1]))))continue;
   matchedEvents.push(event.id);
   tables.forEach((table,side)=>{
    for(const row of table[1].matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/g)){
     const cells=[...row[1].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map(m=>clean(m[1]));
     if(cells.length!==5||!['Out','Doubtful','Questionable'].includes(cells[4]))continue;
     const matches=[...(index.players||[]),...(index.contextPlayers||[])].filter(p=>p.team===codes[side]&&p.events?.includes(event.id)&&norm(p.name)===norm(cells[0]));
     const unique=[...new Map(matches.map(p=>[p.id,p])).values()];if(unique.length!==1)continue;
     const p=unique[0];if(p.position!==cells[1]&&!(['T','G','C','OT','OG','OL'].includes(p.position)&&['T','G','C','OT','OG','OL'].includes(cells[1])))continue;
     observations.push({id:`nfl-status:${event.id}:${p.id}`,kind:'injury',eventId:event.id,playerId:p.id,source:OFFICIAL_INJURY_SOURCE,observedAt:new Date(clock).toISOString(),confirmed:true,value:{status:cells[4],playerName:p.name,team:p.team,position:p.position,injury:cells[2],practiceStatus:cells[3],gameDate:new Date(event.startsAt).toISOString().slice(0,10),url:URL,publishedAt:null,reportedUpdatedAt:null,notice:'Official game designation retrieved for the exact season, week, matchup and date. Publication timestamp is unavailable. Practice participation and report omissions do not confirm playing or starting.'}});
    }
   });
  }
 }
 return {observations,matchedEvents:[...new Set(matchedEvents)],season:Number(year),week:Number(week)};
}
export async function collectOfficialInjuries(index,previous,clock,fetchText){
 const base={id:'official_injuries',url:URL,refreshMinutes:10,expiresAfterMinutes:12};
 const before=previous?.sources?.find(s=>s.id===base.id),age=clock-Date.parse(before?.attemptedAt||before?.checkedAt);
 const old=(previous?.observations||[]).filter(o=>o.source===OFFICIAL_INJURY_SOURCE&&clock-Date.parse(o.observedAt)>=0&&clock-Date.parse(o.observedAt)<12*60000);
 if(age>=0&&age<10*60000)return {observations:old,source:before};
 if(!index.events.some(e=>Date.parse(e.startsAt)>clock&&Date.parse(e.startsAt)-clock<=7*86400000))return {observations:[],source:{...base,state:'outside_pregame_window'}};
 try{const parsed=officialInjuryReports(await fetchText(URL,2_000_000),index,clock);return {observations:parsed.observations,source:{...base,state:parsed.matchedEvents.length?'official_designations':'awaiting_matching_report',matchedEvents:parsed.matchedEvents,season:parsed.season,week:parsed.week,checkedAt:new Date(clock).toISOString(),notice:'Checked time is retrieval time; the page does not supply individual report publication timestamps.'}};}
 catch{return {observations:old,source:{...base,state:'unavailable',checkedAt:before?.checkedAt||null,attemptedAt:new Date(clock).toISOString()}};}
}
