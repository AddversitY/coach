const HUB='https://www.nfl.com/inactives/';
const SOURCE='NFL.com official inactive report';
const day=t=>new Intl.DateTimeFormat('en-CA',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(t));
const clean=s=>String(s).replace(/<[^>]*>/g,' ').replace(/&amp;/g,'&').replace(/&#39;|&apos;/g,"'").replace(/&nbsp;/g,' ').replace(/\s+/g,' ').trim();
const norm=s=>clean(s).toLowerCase().replace(/[^a-z0-9]/g,'');
const fresh=(t,n,age)=>Number.isFinite(Date.parse(t))&&Date.parse(t)<=n&&n-Date.parse(t)<=age;
export function inactiveArticle(html,url,index,clock){
 const u=new URL(url);
 if(u.origin!=='https://www.nfl.com'||!/^\/news\/[a-z0-9-]*inactiv[a-z0-9-]*$/.test(u.pathname)||u.search||u.hash||html.length>2000000)throw new Error('Invalid official source');
 const metadata=[...html.matchAll(/<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)].map(m=>{try{return JSON.parse(m[1]);}catch{return null;}}).find(m=>m?.['@type']==='NewsArticle'&&/inactiv/i.test(m.headline||''));
 if(!metadata||!fresh(metadata.datePublished,clock,18*3600000)||metadata.dateModified&&!fresh(metadata.dateModified,clock,18*3600000))return [];
 const blocks=[...html.matchAll(/<div class="story-part-rich-text-editor-wrapper">([\s\S]*?)<\/div>/g)].map(m=>m[1]);
 const observations=[];
 for(const event of index.events.filter(e=>Date.parse(e.startsAt)>clock&&Date.parse(e.startsAt)-clock<=3*3600000)){
   const id=event.id.match(/^nflverse:(20\d{2})_(\d{2})_/);
   if(!id||!new RegExp('week-'+Number(id[2])+'(?:-|$)').test(u.pathname)||!new RegExp('week[ -]'+Number(id[2])+'\\b','i').test(metadata.headline)||!u.pathname.includes(id[1])||day(metadata.datePublished)!==day(event.startsAt))continue;
   const names=[event.away,event.home].map(n=>n.split(' ').at(-1));
   for(const block of blocks){
     const sections=[...block.matchAll(/<h[23][^>]*>([\s\S]*?)<\/h[23]>\s*<ul[^>]*>([\s\S]*?)<\/ul>/g)];
     if(!names.every(n=>sections.some(s=>norm(s[1])===norm(n))))continue;
     for(const section of sections){
       const side=names.findIndex(n=>norm(n)===norm(section[1]));if(side<0)continue;
       const code=event[side===0?'awayCode':'homeCode'];
       for(const item of section[2].matchAll(/<li[^>]*>([\s\S]*?)<\/li>/g)){
         const text=clean(item[1]);if(/emergency|third quarterback|3rd qb/i.test(text))continue;
         const matches=[...(index.players||[]),...(index.contextPlayers||[])].filter(p=>p.team===code&&p.events?.includes(event.id)&&norm(text.replace(/^[A-Z/]+\s+/,''))===norm(p.name));
         const unique=[...new Map(matches.map(p=>[p.id,p])).values()];if(unique.length!==1)continue;
         const p=unique[0];observations.push({id:`nfl-inactive:${event.id}:${p.id}`,kind:'injury',eventId:event.id,playerId:p.id,source:SOURCE,observedAt:new Date(clock).toISOString(),confirmed:true,
           value:{status:'Inactive',playerName:p.name,team:p.team,position:p.position||null,reportedUpdatedAt:metadata.dateModified||metadata.datePublished,publishedAt:metadata.datePublished,url,notice:'Named on the NFL.com inactive list for this exact matchup and game day. Omitted players are not confirmed active or starting; emergency third quarterbacks are excluded.'}});
       }
     }
   }
 }
 return [...new Map(observations.map(o=>[o.id,o])).values()];
}
export async function collectOfficialInactives(index,previous,clock,fetchText){
 const base={id:'official_inactives',url:HUB,refreshMinutes:10,expiresAfterMinutes:12,notice:'Exact-game NFL.com inactive reports only. No active-player or starting-role inference from omissions.'};
 const nearby=index.events.filter(e=>Date.parse(e.startsAt)>clock&&Date.parse(e.startsAt)-clock<=3*3600000);
 if(!nearby.length)return {observations:[],source:{...base,state:'outside_game_day_window',checkedAt:null}};
 const before=previous?.sources?.find(s=>s.id===base.id),old=(previous?.observations||[]).filter(o=>o.source===SOURCE&&fresh(o.observedAt,clock,12*60000)&&nearby.some(e=>e.id===o.eventId));
 if(fresh(before?.attemptedAt||before?.checkedAt,clock,10*60000))return {observations:old,source:before};
 try{
   const hub=await fetchText(HUB,1000000),links=[...hub.matchAll(/href=["']((?:https:\/\/www\.nfl\.com)?\/news\/[a-z0-9-]*inactiv[a-z0-9-]*)["']/g)].map(m=>new URL(m[1],HUB).href);
   const candidates=[...new Set(links)].filter(url=>nearby.some(e=>{const m=e.id.match(/^nflverse:(20\d{2})_(\d{2})_/);return m&&url.includes(m[1])&&new RegExp('week-'+Number(m[2])+'(?:-|$)').test(url);})).slice(0,2);
   const observations=[];
   for(const url of candidates)observations.push(...inactiveArticle(await fetchText(url,2000000),url,index,clock));
   return {observations,source:{...base,state:observations.length?'named_inactives_found':'awaiting_matching_report',checkedAt:new Date(clock).toISOString()}};
 }catch{return {observations:old,source:{...base,state:'unavailable',checkedAt:before?.checkedAt||null,attemptedAt:new Date(clock).toISOString()}};}
}
