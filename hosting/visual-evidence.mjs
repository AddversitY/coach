/* Dated observations for charts. Never turn missing records into zeroes. */
const norm=s=>String(s||'').toLowerCase().replace(/[^a-z0-9 ]/g,'').replace(/\s+/g,' ').trim();
const METRICS={passing_yards:'Passing yards',rushing_yards:'Rushing yards',receiving_yards:'Receiving yards',receptions:'Receptions',attempts:'Pass attempts',carries:'Carries',targets:'Targets'};
const marketMetric={player_pass_yds:'passing_yards',player_rush_yds:'rushing_yards',player_reception_yds:'receiving_yards',player_receptions:'receptions'};
export function visualEvidence(source,event,report,question,now){
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
  return {id:p.id,name:p.name,team:p.team,position:p.position,metric,line:Number.isFinite(line)?line:null,side:explicit?.[1].toLowerCase()||selection?.outcome?.toLowerCase()||null,lineSource:explicit?'Requested line':Number.isFinite(line)?'Saved quote line':null,series};
 }):[];
 const teams=['away','home'].map(side=>{
  const name=event[side];
  const games=[...new Map((source.index.results||[]).filter(r=>r.eventId!==event.id&&earlier(r)&&[r.home,r.away].includes(name)&&Number.isFinite(r.homeScore)&&Number.isFinite(r.awayScore)).sort((a,b)=>b.date.localeCompare(a.date)).map(r=>[r.eventId,r])).values()].slice(0,6).reverse();
  return {name,code:event[side+'Code'],samples:games.map(g=>({date:g.date,label:g.date.slice(5),opponent:g.home===name?g.away:g.home,value:g.home===name?g.homeScore:g.awayScore,secondary:g.home===name?g.awayScore:g.homeScore}))};
 });
 const named=teams.filter(t=>[t.name,t.name.split(' ').at(-1),t.code].filter(Boolean).some(alias=>q.includes(' '+norm(alias)+' ')));
 return {schemaVersion:1,focus:players.length?'player':'team',selectedTeam:named.length===1?named[0].name:event.home,cutoff,source:'nflverse recorded box scores',sourceUrl:'https://github.com/nflverse/nflverse-data',teams,players,notice:'Recorded results only, not a forecast. Prior games use their actual opponents; the displayed line is today’s comparison threshold, not those games’ historical sportsbook lines.'};
}
