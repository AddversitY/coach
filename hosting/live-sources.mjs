import {XMLParser, XMLValidator} from 'fast-xml-parser';

const MINUTE=60_000, HOUR=60*MINUTE;
export const INJURY_INTERVAL=10*MINUTE;
export const NEWS_INTERVAL=30*MINUTE; // The publisher's RSS ttl is 30 minutes.
const normalize=s=>String(s||'').normalize('NFKD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^a-z0-9 ]/g,'').replace(/\s+/g,' ').trim();
const teams={ARI:'Cardinals',ATL:'Falcons',BAL:'Ravens',BUF:'Bills',CAR:'Panthers',CHI:'Bears',CIN:'Bengals',CLE:'Browns',DAL:'Cowboys',DEN:'Broncos',DET:'Lions',GB:'Packers',HOU:'Texans',IND:'Colts',JAX:'Jaguars',KC:'Chiefs',LAC:'Chargers',LAR:'Rams',LV:'Raiders',MIA:'Dolphins',MIN:'Vikings',NE:'Patriots',NO:'Saints',NYG:'Giants',NYJ:'Jets',PHI:'Eagles',PIT:'Steelers',SEA:'Seahawks',SF:'49ers',TB:'Buccaneers',TEN:'Titans',WAS:'Commanders'};
const club=s=>({LA:'LAR',WSH:'WAS',OAK:'LV',SD:'LAC',STL:'LAR'})[String(s).toUpperCase()]||String(s).toUpperCase();
export const recent=(value,clock,age)=>Number.isFinite(Date.parse(value))&&Date.parse(value)<=clock&&clock-Date.parse(value)<=age;
const words=(text,needle)=>(' '+normalize(text)+' ').includes(' '+normalize(needle)+' ');
const nextEvent=(player,index,clock)=>index.events.filter(e=>player.events.includes(e.id)&&Date.parse(e.startsAt)>clock).sort((a,b)=>Date.parse(a.startsAt)-Date.parse(b.startsAt))[0];

export function injuryReports(raw,index,at){
  const clock=Date.parse(at);
  if(!Array.isArray(raw?.injuries)||raw.injuries.length>40)throw new Error('Invalid injury schema');
  if(raw.timestamp&&!recent(raw.timestamp,clock,2*HOUR))throw new Error('Stale injury publication');
  const found=new Map();
  for(const group of raw.injuries){
    if(!Array.isArray(group.injuries)||group.injuries.length>200)throw new Error('Incomplete injury schema');
    for(const row of group.injuries){
      const athlete=row.athlete,status=String(row.status||'').trim();
      if(!athlete||!['Out','Doubtful','Questionable','Injured Reserve','Inactive'].includes(status))continue;
      const reportedAt=row.date;
      if(!recent(reportedAt,clock,status==='Injured Reserve'?180*24*HOUR:14*24*HOUR))continue;
      const code=club(athlete.team?.abbreviation||group.team?.abbreviation||group.abbreviation||'');
      const known=index.players.filter(p=>normalize(p.name)===normalize(athlete.displayName)&&club(p.team)===code);
      const matches=known.length?known:(index.contextPlayers||[]).filter(p=>normalize(p.name)===normalize(athlete.displayName)&&club(p.team)===code);
      const reportedPosition=athlete.position?.abbreviation;
      if(reportedPosition&&matches.some(p=>p.position&&p.position!==reportedPosition&&!(['C','G','T','OT','OG','OL','LT','RT','LG','RG'].includes(p.position)&&['C','G','T','OT','OG','OL','LT','RT','LG','RG'].includes(reportedPosition))))continue;
      if(matches.length!==1)continue;
      const player=matches[0],event=nextEvent(player,index,clock);
      if(!event)continue;
      const season=new Date(event.startsAt).getUTCFullYear()-(new Date(event.startsAt).getUTCMonth()<2?1:0);
      if(raw.season?.year&&raw.season.year!==season)continue;
      const id=`espn:${event.id}:${player.id}`;
      const observation={id,kind:'injury',eventId:event.id,playerId:player.id,source:'ESPN injury feed (unofficial)',observedAt:at,confirmed:false,
        value:{status,playerName:player.name,team:player.team,position:player.position||null,identitySource:player.identitySource||'recorded_box_scores',reportedUpdatedAt:reportedAt,url:'https://www.espn.com/nfl/injuries',notice:'Unofficial status listing; not confirmation for this next game. Missing reports do not confirm health.'}};
      if(!found.has(id)||Date.parse(found.get(id).value.reportedUpdatedAt)<Date.parse(reportedAt))found.set(id,observation);
    }
  }
  if(found.size>450)throw new Error('Incomplete injury coverage');
  return [...found.values()];
}

export async function collectInjuries(index,previous,clock,fetchJson){
  const before=previous?.sources?.find(s=>s.id==='injuries');
  const old=(previous?.observations||[]).filter(o=>o.kind==='injury'&&o.source==='ESPN injury feed (unofficial)'&&index.events.some(e=>e.id===o.eventId&&Date.parse(e.startsAt)>clock));
  const scopeVersion=(index.contextPlayers||[]).length?'recorded-offense-v2':'recorded-skill-v1',scopeCutoff=index.roleContext?.cutoff||null,scopePlayers=(index.contextPlayers||[]).length;
  const sameScope=before?.scopeVersion===scopeVersion&&before?.scopeCutoff===scopeCutoff&&before?.scopePlayers===scopePlayers;
  const source={scopeVersion,scopeCutoff,scopePlayers,id:'injuries',attribution:'ESPN',url:'https://www.espn.com/nfl/injuries',refreshMinutes:10,expiresAfterMinutes:12,notice:'Exact-name/team matches to recorded offensive participants, recent QB/line snap records and unconfirmed schedule QB listings; not complete NFL roster coverage.'};
  if(sameScope&&(before?.state==='reported_unofficial'&&recent(before.checkedAt,clock,INJURY_INTERVAL)||before?.state==='unavailable'&&recent(before.attemptedAt,clock,INJURY_INTERVAL)))return {observations:old.filter(o=>recent(o.observedAt,clock,12*MINUTE)),source:before};
  try{
    // ESPN's expanded athlete data currently exceeds 8 MB. Bound it, then keep
    // only exact-name/team status facts. Never store the full provider response.
    const raw=await fetchJson('https://site.api.espn.com/apis/site/v2/sports/football/nfl/injuries',16_000_000);
    return {observations:injuryReports(raw,index,new Date(clock).toISOString()),source:{...source,state:'reported_unofficial',checkedAt:new Date(clock).toISOString(),publishedAt:raw.timestamp||null}};
  }catch{
    return {observations:old.filter(o=>recent(o.observedAt,clock,12*MINUTE)),source:{...source,state:'unavailable',checkedAt:before?.checkedAt||null,attemptedAt:new Date(clock).toISOString()}};
  }
}

function decode(value){
  return String(value||'').replace(/&#(x[0-9a-f]+|\d+);/gi,(_,n)=>{const code=n[0].toLowerCase()==='x'?parseInt(n.slice(1),16):Number(n);return code>0&&code<=0x10ffff?String.fromCodePoint(code):'';}).replace(/&(amp|lt|gt|quot|apos);/g,(_,n)=>({amp:'&',lt:'<',gt:'>',quot:'"',apos:"'"})[n]);
}
const text=value=>typeof value==='string'?decode(value).replace(/<[^>]*>/g,'').replace(/\s+/g,' ').trim():'';
export function newsReports(xml,index,clock){
  if(typeof xml!=='string'||xml.length>512_000||/<!\s*(?:DOCTYPE|ENTITY)/i.test(xml)||XMLValidator.validate(xml)!==true)throw new Error('Invalid RSS');
  const channel=new XMLParser({processEntities:false,parseTagValue:false,ignoreAttributes:true}).parse(xml)?.rss?.channel;
  if(!channel||!Array.isArray(channel.item)&&!channel.item)throw new Error('Invalid RSS channel');
  const items=Array.isArray(channel.item)?channel.item:[channel.item];
  if(items.length>100)throw new Error('RSS exceeds item limit');
  const observations=[],seen=new Set();
  for(const item of items){
    const title=text(item.title),author=text(item['dc:creator']||item.author),publishedAt=text(item.pubDate);
    if(!title||title.length>240||!recent(publishedAt,clock,48*HOUR))continue;
    let link;try{link=new URL(text(item.link));}catch{continue;}
    if(link.protocol!=='https:'||!['www.espn.com','espn.com'].includes(link.hostname)||link.username||link.password||!link.pathname.startsWith('/nfl/'))continue;
    link.search='';link.hash='';if(seen.has(link.href))continue;seen.add(link.href);
    const named=index.players.filter(p=>words(title,p.name));
    const clubs=Object.entries(teams).filter(([,name])=>words(title,name)).map(([code])=>code);
    const events=[...named.map(p=>nextEvent(p,index,clock)),...clubs.map(code=>index.events.filter(e=>Date.parse(e.startsAt)>clock&&[e.home,e.away].some(name=>name.endsWith(' '+teams[code]))).sort((a,b)=>Date.parse(a.startsAt)-Date.parse(b.startsAt))[0])].filter(Boolean);
    // League-wide headlines are visible as such; they never invalidate every
    // ticket or silently adopt the currently selected player's identity.
    const eventIds=events.length?[...new Set(events.map(e=>e.id))]:['nfl'];
    for(const eventId of eventIds){
      const playerId=named.length===1?named[0].id:undefined;
      observations.push({id:`news:${eventId}:${link.href}`,kind:'news',eventId,...(playerId?{playerId}:{}),source:'ESPN NFL RSS',observedAt:new Date(clock).toISOString(),confirmed:false,
        value:{title,url:link.href,author:author.slice(0,100)||null,publishedAt:new Date(publishedAt).toISOString(),notice:'Attributed published headline; not confirmed availability. Open the original report for context.'}});
    }
  }
  return {observations,ttlMinutes:Math.max(30,Math.min(1440,Number(channel.ttl)||30))};
}

export async function collectNews(index,previous,clock,fetchText){
  const before=previous?.sources?.find(s=>s.id==='beat_writers');
  const old=(previous?.observations||[]).filter(o=>o.kind==='news'&&o.source==='ESPN NFL RSS'&&recent(o.value?.publishedAt,clock,48*HOUR));
  const interval=Math.max(NEWS_INTERVAL,Math.min(1440*MINUTE,(before?.refreshMinutes||30)*MINUTE));
  if(before?.state==='attributed_headlines'&&recent(before.checkedAt,clock,interval)||before?.state==='unavailable'&&recent(before.attemptedAt,clock,interval))return {observations:old.filter(o=>recent(o.observedAt,clock,65*MINUTE)),source:before};
  const base={id:'beat_writers',attribution:'ESPN NFL RSS',url:'https://www.espn.com/espn/rss/nfl/news',refreshMinutes:30,expiresAfterMinutes:65};
  try{
    const parsed=newsReports(await fetchText(base.url,512_000),index,clock);
    return {observations:parsed.observations,source:{...base,state:'attributed_headlines',checkedAt:new Date(clock).toISOString(),refreshMinutes:parsed.ttlMinutes,expiresAfterMinutes:parsed.ttlMinutes*2+5,notice:'Publisher headlines and supplied author bylines; not a social stream or comprehensive beat coverage.'}};
  }catch{return {observations:old.filter(o=>recent(o.observedAt,clock,65*MINUTE)),source:{...base,state:'unavailable',checkedAt:before?.checkedAt||null,attemptedAt:new Date(clock).toISOString()}};}
}

// A price movement is an observed change, never proof of a professional bettor.
// Only compare the same book, market, participant and side. Ambiguous alt-line
// groups are excluded, and re-reading a snapshot never manufactures a new move.
export function marketMovements(snapshot,index,previous=[],clock=Date.now()){
  const groups=new Map();
  const quotes=snapshot.odds?.testFixture||snapshot.props?.demo||!recent(snapshot.props?.fetchedAt,clock,18*HOUR)?[]:snapshot.props?.quotes||[];
  for(const q of quotes){
    const s=q.selection;
    if(!s||q.demo||q.status!=='open'||!Number.isFinite(q.decimal)||q.decimal<=1||!recent(q.sourceAt,clock,18*HOUR)||!recent(q.collectedAt,clock,18*HOUR)||Date.parse(q.sourceAt)>Date.parse(q.collectedAt)||Date.parse(q.collectedAt)>Date.parse(snapshot.props.fetchedAt)||!index.events.some(e=>e.id===s.eventId&&Date.parse(e.startsAt)>clock))continue;
    const key=JSON.stringify([s.eventId,s.market,s.participant||'',s.outcome,q.bookId,q.provider||'']);
    if(!groups.has(key))groups.set(key,[]);groups.get(key).push(q);
  }
  const old=new Map(previous.map(row=>[row[0],row])),state=[],observations=[];
  for(const [key,rows] of groups){
    if(rows.length!==1)continue;
    const q=rows[0],s=q.selection;
    if(s.point!=null&&!Number.isFinite(s.point))continue;
    const current=[s.point??null,q.decimal,q.sourceAt,q.collectedAt];
    const prior=old.get(key);
    const baseline=prior&&recent(prior[1][2],clock,18*HOUR)&&Date.parse(prior[2][2])<=Date.parse(q.sourceAt)?prior[1]:current;
    const latest=prior&&Date.parse(prior[2][2])>=Date.parse(q.sourceAt)?prior[2]:current;
    state.push([key,baseline,latest]);
    if(baseline[0]===latest[0]&&baseline[1]===latest[1]||Date.parse(latest[2])<=Date.parse(baseline[2]))continue;
    const player=index.players.find(p=>p.name===s.participant&&p.events.includes(s.eventId));
    observations.push({id:`movement:${key}`,kind:'market',eventId:s.eventId,...(player?{playerId:player.id}:{}),source:'The Odds API / saved observations',observedAt:latest[3],confirmed:false,
      value:{market:s.market,participant:s.participant||null,outcome:s.outcome,book:q.book,fromLine:baseline[0],toLine:latest[0],fromDecimal:baseline[1],toDecimal:latest[1],fromSourceAt:baseline[2],toSourceAt:latest[2],notice:'Change between saved observations, not a verified opening line, steam or sharp-money flow. Settlement rules unverified.'}});
  }
  if(JSON.stringify(state).length>120000)throw new Error('Market history exceeds storage limit');
  return {state,observations,coverage:state.length};
}

// An authenticated adapter for a permitted provider. Aggregate bet/money shares
// never establish the identities or skill of the bettors behind them.
export function marketSplitReports(body,index,clock,allowedHosts=[]){
  if(!body||body.kind!=='market_splits'||typeof body.provider!=='string'||!body.provider.trim()||body.provider.length>80||!recent(body.publishedAt,clock,30*MINUTE)||!Array.isArray(body.records)||!body.records.length||body.records.length>100)throw new Error('Invalid splits feed');
  const link=new URL(body.sourceUrl);
  if(link.protocol!=='https:'||link.username||link.password||link.search||link.hash||link.href.length>1000||!allowedHosts.includes(link.hostname))throw new Error('Unapproved splits source');
  const seen=new Set(),observations=[];
  for(const row of body.records){
    if(!index.events.some(e=>e.id===row.eventId&&Date.parse(e.startsAt)>clock)||!['h2h','spreads','totals'].includes(row.market)||typeof row.outcome!=='string'||!row.outcome.trim()||row.outcome.length>100||!Number.isFinite(row.betPercent)||!Number.isFinite(row.moneyPercent)||row.betPercent<0||row.betPercent>100||row.moneyPercent<0||row.moneyPercent>100||row.line!=null&&(!Number.isFinite(row.line)||Math.abs(row.line)>1000))throw new Error('Invalid splits row');
    const event=index.events.find(e=>e.id===row.eventId);
    if(row.market==='totals' ? !['Over','Under'].includes(row.outcome)||!Number.isFinite(row.line)||row.line<0 : ![event.home,event.away].includes(row.outcome)||row.market==='h2h'&&row.line!=null||row.market==='spreads'&&!Number.isFinite(row.line))throw new Error('Invalid market outcome');
    const id=`splits:${JSON.stringify([link.hostname,row.eventId,row.market,row.outcome,row.line??null])}`;
    if(seen.has(id))throw new Error('Duplicate splits row');seen.add(id);
    observations.push({id,kind:'market',eventId:row.eventId,source:body.provider.trim(),observedAt:new Date(body.publishedAt).toISOString(),confirmed:false,
      value:{signalType:'betting_splits',market:row.market,outcome:row.outcome,line:row.line??null,betPercent:row.betPercent,moneyPercent:row.moneyPercent,url:link.href,publishedAt:new Date(body.publishedAt).toISOString(),notice:'Provider-reported aggregate shares; sample size and bettor identity unverified. Not proof of sharp-money activity.'}});
  }
  return {receivedAt:new Date(clock).toISOString(),publishedAt:new Date(body.publishedAt).toISOString(),provider:body.provider.trim(),observations};
}
