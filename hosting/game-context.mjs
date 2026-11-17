/* Descriptive context never silently becomes an injury/quarterback point model. */
const LINE=new Set(['C','G','T','OT','OG','OL','LT','RT','LG','RG']);
const CONCERN=new Set(['questionable','out','doubtful','inactive','injured reserve']);
const finite=n=>typeof n==='number'&&Number.isFinite(n);
const name=s=>String(s||'').toLowerCase().replace(/[^a-z0-9 ]/g,'').trim();
const fresh=(s,now,age)=>Number.isFinite(Date.parse(s))&&Date.parse(s)<=now&&now-Date.parse(s)<=age;
const mean=a=>a.length?a.reduce((a,b)=>a+b,0)/a.length:null;

export function gameContext(source,event,{now=Date.now(),telemetry=null}={}){
  const data=source.index.roleContext;
  const football=source.index.footballScoreModel,footballRecord=football?.events?.[event.id];
  const footballUsable=football?.version==='score-football-features-v1'&&fresh(football.cutoff+'T00:00:00Z',now,22*86400000)&&fresh(football.sourceRetrievedAt,now,22*86400000)&&footballRecord&&Date.parse(footballRecord.startsAt)===Date.parse(event.startsAt)&&footballRecord.inputCutoff<event.startsAt.slice(0,10);
  const usable=data?.schemaVersion===1&&fresh(data.cutoff+'T00:00:00Z',now,22*86400000)&&fresh(data.retrievedAt,now,22*86400000);
  const observations=telemetry&&fresh(telemetry.checkedAt,now,5*60000)?telemetry.observations||[]:[];
  const injuries=observations.filter(o=>o.eventId===event.id&&o.kind==='injury'&&fresh(o.observedAt,now,12*60000));
  const identity=o=>source.index.players.find(p=>p.id===o.playerId)||(source.index.contextPlayers||[]).find(p=>p.id===o.playerId);
  const reports=injuries.map(o=>{const p=identity(o);return {...o,playerName:p?.name||o.value?.playerName||null,team:p?.team||o.value?.team||null,position:p?.position||o.value?.position||null};});
  const snaps=usable&&data.snapSource&&fresh(data.snapSource.cutoff+'T00:00:00Z',now,22*86400000)&&fresh(data.snapSource.retrievedAt,now,22*86400000)?data.snaps||[]:[];
  const alerts=[],teams=[];
  for(const side of ['away','home']){
    const code=event[side+'Code'];
    const games=usable?(data.teamGames||[]).filter(g=>g.team===code&&Date.parse(g.date+'T00:00:00Z')<now&&g.date<=data.cutoff).sort((a,b)=>b.date.localeCompare(a.date)):[];
    const latest=games[0],leader=latest?.passers?.[0]||null;
    const tied=leader&&latest.passers.filter(p=>p.attempts===leader.attempts).length>1;
    const listed=event.listedQuarterbacks?.[side]||null;
    const qbReports=reports.filter(o=>o.team===code&&o.position==='QB');
    const previous=games.slice(1,4).map(g=>g.passers?.[0]).filter(Boolean);
    const changed=!!(listed&&leader&&!tied&&name(listed)!==name(leader.name));
    const recentChange=!!leader&&!tied&&previous.some(p=>p.id!==leader.id);
    const qbConcern=qbReports.some(o=>[listed,leader?.name].filter(Boolean).some(n=>name(n)===name(o.playerName))&&CONCERN.has(String(o.value?.status).toLowerCase()));
    const quarterback={listed,listedSource:event.scheduleEvidence||null,lastObserved:leader&&!tied?{...leader,date:latest.date,teamAttempts:latest.attempts}:null,
      listingDiffersFromLastObserved:changed,recentObservedLeaderChanged:recentChange,reports:qbReports,
      status:qbConcern?'reported_concern':changed||recentChange?'change_requires_review':'starter_unconfirmed',
      notice:'Schedule listing and recorded passing leader are not a confirmed starter or projected playing time.'};
    if(changed)alerts.push({kind:'quarterback',team:code,severity:'review',text:`${code}: schedule lists ${listed}; the last recorded passing leader was ${leader.name}. Confirm the starter and receiving roles.`});
    if(recentChange&&!changed)alerts.push({kind:'quarterback',team:code,severity:'review',text:`${code}: the recorded passing leader changed within the last four team games. Verify quarterback continuity rather than assuming the older role.`});
    if(qbConcern)alerts.push({kind:'quarterback',team:code,severity:'review',text:`${code}: a relevant quarterback has a reported availability concern. Do not assume a replacement or apply an automatic point deduction.`});
    const latestSnaps=snaps.filter(s=>s.team===code&&s.date===latest?.date);
    const lineObserved=latestSnaps.filter(s=>LINE.has(s.position)&&s.offenseShare>=.5).sort((a,b)=>b.offenseShare-a.offenseShare).slice(0,5);
    const lineReports=reports.filter(o=>o.team===code&&LINE.has(o.position));
    if(lineReports.length)alerts.push({kind:'offensive_line',team:code,severity:'review',text:`${code}: ${lineReports.length} recorded offensive linemen have reported availability concerns; current starters and protection impact are unconfirmed.`});
    const players=source.index.players.filter(p=>p.team===code&&p.events.includes(event.id));
    const usage=players.map(p=>{
      const metric=p.position==='QB'?'attempts':p.position==='RB'?'carries':'targets';
      const rows=usable?p.games.filter(g=>g.date<=data?.cutoff&&Date.parse(g.date+'T00:00:00Z')<now&&finite(g.stats?.[metric])).sort((a,b)=>b.date.localeCompare(a.date)).slice(0,6):[];
      const observations=rows.map(g=>{const tg=games.find(x=>x.date===g.date&&x.week===g.week),snap=snaps.find(x=>x.team===code&&x.week===g.week&&x.date===g.date&&name(x.name)===name(p.name));return {date:g.date,week:g.week,workload:g.stats[metric],teamWorkload:tg?.[metric]??null,share:tg?.[metric]>0?g.stats[metric]/tg[metric]:null,snapShare:snap?.offenseShare??null};});
      const recent=observations.slice(0,3),prior=observations.slice(3,6),recentMean=mean(recent.map(g=>g.workload)),priorMean=mean(prior.map(g=>g.workload));
      const delta=recent.length===3&&prior.length===3&&priorMean>0?(recentMean-priorMean)/priorMean:null;
      const missing=!!latest&&observations[0]?.date!==latest.date;
      const shares=recent.filter(r=>r.teamWorkload>0),denominator=shares.reduce((n,g)=>n+g.teamWorkload,0);
      return {playerId:p.id,name:p.name,team:code,position:p.position,metric,appearances:observations.length,recentMean,priorMean,
        recentShare:denominator?shares.reduce((n,g)=>n+g.workload,0)/denominator:null,changeFraction:delta,
        recentSnapShare:mean(recent.filter(g=>finite(g.snapShare)).map(g=>g.snapShare)),latestTeamGameMissing:missing,
        trend:missing?'participation_gap':delta!=null&&delta<=-.3?'decreased':delta!=null&&delta>=.3?'increased':'insufficient_change_evidence',observations,
        notice:'Recorded appearances only. Missing appearances are not zeros. Shares use recorded team opportunities; snap share is not route participation or an expected workload.'};
    }).filter(p=>p.appearances).sort((a,b)=>(b.recentShare??0)-(a.recentShare??0)).slice(0,18);
    const otherCode=event[(side==='home'?'away':'home')+'Code'];
    const opponentGames=usable?(data.teamGames||[]).filter(g=>g.team===otherCode&&finite(g.passingYardsAllowed)&&finite(g.rushingYardsAllowed)&&g.date<=data.cutoff&&Date.parse(g.date+'T00:00:00Z')<now).slice(0,6):[];
    teams.push({side,team:event[side],code,footballEvidence:footballUsable?footballRecord.roles?.[side]||null:null,quarterback,availability:reports.filter(o=>o.team===code),
      opponentRecentAllowance:{team:otherCode,games:opponentGames.length,passingYards:mean(opponentGames.map(g=>g.passingYardsAllowed)),rushingYards:mean(opponentGames.map(g=>g.rushingYardsAllowed)),notice:'Recorded opposing offense production; not adjusted for opponents, pace or game script and not a probability adjustment.'},offensiveLine:{lastObserved:lineObserved,reports:lineReports,asOf:latestSnaps.length?latest.date:null,coverage:lineObserved.length===5?'five_high_snap_players_observed':'incomplete',notice:'Previous high-snap linemen are not confirmed starters. No report does not establish a healthy line.'},usage,
      restDays:event.restDays?.[side]??null,latestRecordedGame:latest?.date||null});
  }
  const weather=observations.filter(o=>o.eventId===event.id&&o.kind==='weather'&&fresh(o.observedAt,now,35*60000));
  const sources=[...(footballUsable?[{id:'football_features',source:'nflverse play-by-play / earlier-week summaries',url:source.index.footballScoreModel.sourceUrl,cutoff:source.index.footballScoreModel.cutoff,retrievedAt:source.index.footballScoreModel.sourceRetrievedAt}]:[]),...(usable?[{id:'workload',source:data.source,url:data.sourceUrl,cutoff:data.cutoff,retrievedAt:data.retrievedAt}]:[]),...(snaps.length?[{id:'snaps',...data.snapSource,url:data.snapSource.sourceUrl}]:[]),{id:'schedule',source:'nflverse schedule',...event.scheduleEvidence},...(reports.length?[{id:'availability',source:'ESPN injury feed (unofficial)',url:'https://www.espn.com/nfl/injuries',checkedAt:telemetry.checkedAt}]:[])];
  return {schemaVersion:1,version:footballUsable?'role-context-football-v2':'role-context-v1',eventId:event.id,createdAt:new Date(now).toISOString(),cutoff:usable?data.cutoff:null,teams,alerts,weather,sources,
    readiness:usable?'descriptive_context':'context_unavailable',adjustmentsApplied:false,
    participation:{state:'unconfirmed',officialActiveListAvailable:false,confirmedStartersAvailable:false,officialNamedInactives:injuries.filter(o=>o.confirmed===true&&o.source==='NFL.com official inactive report').length,reportedConcerns:reports.filter(o=>CONCERN.has(String(o.value?.status).toLowerCase())).length,checkedAt:injuries.map(o=>o.observedAt).sort().at(-1)||null,notice:'Official NFL.com named inactive reports are checked near kickoff when available; other listings remain unofficial. Missing names or an Active label do not confirm participation or a starting role.'},
    unknowns:['Confirmed starting quarterbacks, active lists and expected snap counts require a current game-specific source.','Recorded workload and snap share do not measure routes, coaching plans or recovery.','No validated quarterback, injury, offensive-line or weather probability adjustment is applied.']};
}

export function projectionWarnings(projection,context){
  const team=context.teams.find(t=>t.usage.some(p=>p.playerId===projection.playerId));
  if(!team)return [];
  const usage=team.usage.find(p=>p.playerId===projection.playerId),warnings=[];
  if(team.availability?.some(o=>o.playerId===projection.playerId))warnings.push('A reported availability concern applies to this player; confirm current game participation before using the historical role.');
  if(usage.latestTeamGameMissing)warnings.push('No recorded appearance in the latest team game; the absence is not a zero and current participation needs checking.');
  if(usage.trend==='decreased')warnings.push('Recorded workload in the last three appearances is at least 30% below the preceding three; do not assume the earlier role.');
  if(['reported_concern','change_requires_review'].includes(team.quarterback.status)&&['player_reception_yds','player_receptions','player_pass_yds'].includes(projection.market))warnings.push('Quarterback continuity is unresolved; the recorded passing/receiving role may not transfer to this game.');
  if(team.offensiveLine.reports.length)warnings.push('Reported offensive-line concerns need review; protection and run-blocking effects are not quantified.');
  return warnings;
}

export function contextEvidence(context){
  const report=o=>({playerName:o.playerName,position:o.position,status:o.value?.status,reportedAt:o.value?.reportedUpdatedAt,source:o.source,url:o.value?.url,confirmed:o.confirmed===true&&o.source==='NFL.com official inactive report'});
  return {...context,teams:context.teams.map(t=>({...t,
    quarterback:{...t.quarterback,reports:t.quarterback.reports.map(report)},
    availability:t.availability.map(report),
    offensiveLine:{...t.offensiveLine,reports:t.offensiveLine.reports.map(report)},
    usage:t.usage.slice(0,10).map(({observations,notice,...p})=>p),
  }))};
}

export function decisionBrief(report,context,{question=''}={}){
  const q=question.toLowerCase(),names=context.teams.flatMap(t=>t.usage).filter(p=>(' '+name(q)+' ').includes(' '+name(p.name)+' ')).map(p=>p.name);
  const requested=/moneyline|win outright/.test(q)?'h2h':/spread|cover/.test(q)?'spreads':/receiv|rec\. yards/.test(q)?'player_reception_yds':/receptions/.test(q)?'player_receptions':/passing|pass yards/.test(q)?'player_pass_yds':/rushing|rush yards/.test(q)?'player_rush_yds':/total|over.?under/.test(q)?'totals':null;
  const side=q.match(/\b(over|under)\s+(-?\d+(?:\.\d+)?)/);
  const spreadText=q.match(/(?:spread|line|cover)\s*(?:at\s*)?([+-]?\d+(?:\.\d+)?)/)?.[1];
  const spreadLine=requested==='spreads'&&spreadText!=null&&Math.abs(Number(spreadText))<100?Number(spreadText):null;
  const rows=requested||names.length||side?report.categories.flatMap(c=>c.rows):report.ranked;
  const mentionedTeams=[report.event.home,report.event.away].filter(team=>(' '+name(q)+' ').includes(' '+name(team)+' ')||(' '+name(q)+' ').includes(' '+name(team.split(' ').at(-1))+' '));
  const selectedTeam=mentionedTeams.length===1?mentionedTeams[0]:null;
  const ranked=rows.filter(r=>!r.blocked&&(!requested||r.selection.market===requested)&&(!selectedTeam||!['spreads','h2h'].includes(r.selection.market)||r.selection.outcome===selectedTeam)&&(!names.length||names.includes(r.selection.participant))&&(!side||r.selection.outcome.toLowerCase()===side[1]&&r.selection.point===Number(side[2]))&&(spreadLine==null||r.selection.point===spreadLine)),best=ranked[0];
  const home=report.event.home,away=report.event.away;
  const lean=report.score.homeWin>(1-report.score.homeWin-report.score.tie)?home:away;
  const priced=!!best;
  const focusedPlayer=names.length>0||requested?.startsWith('player_');
  const focus=requested||focusedPlayer?'selection':'game';
  const focusTeam=context.teams.find(t=>t.usage.some(p=>names.includes(p.name)))?.code;
  const alerts=focusedPlayer&&focusTeam?context.alerts.filter(a=>a.team===focusTeam):context.alerts;
  const risk=(alerts.find(a=>a.team===focusTeam&&a.kind==='quarterback')||alerts.find(a=>a.team===focusTeam)||alerts.find(a=>a.kind==='quarterback')||alerts[0])?.text||(focusedPlayer?'Player forecasts are conditional on a recorded appearance; exact-line probabilities and future calibration remain unvalidated.':'The independent score model has not beaten the historical market benchmark; the displayed lean is not a validated betting advantage.');
  return {status:alerts.length?'wait_for_context':priced?'research_only':'wait_for_prices',
    headline:alerts.length?'Wait for lineup clarity':priced?'Compare the price. Keep this in research.':'Pass for now — the matching price is missing',
    whatWouldChange:[
      {kind:'price',state:best?'recheck_saved_quote':'missing_exact_quote',selection:best?.selection||null,text:best?'Refresh this exact selection at the sportsbook. A saved price may no longer be obtainable; the research break-even price is not an approval to bet.':'Provide a fresh sportsbook price matching the requested game, player, side and line; unrelated prices cannot fill the gap.'},
      {kind:'availability',state:'official_confirmation_needed',text:focusedPlayer?'Confirm this player is active and verify the expected role using a current game-specific official source. Historical appearances and unofficial reports do not establish participation.':'Confirm the game’s starting quarterbacks and relevant active players using a current official source. Resolve conflicting listings before reassessing.'},
      {kind:'validation',state:'not_demonstrated',text:'The model needs better probability accuracy than matched market baselines on future games. A lineup update or a more attractive price alone does not establish an edge.'},
    ],
    action:'pass',focus,reason:alerts.length?'context_unresolved':priced?'model_unvalidated':'matching_price_missing',
    lean:focusedPlayer||requested==='totals'?null:{team:lean,notice:report.basis==='market_anchored'?'Market-anchored outlook, not an independent edge.':'Experimental score-model lean; not a recommendation.'},
    price:best?{selection:best.selection,book:best.book,observedDecimal:best.decimal,minimumDecimal:best.minimumDecimal,sourceAt:best.sourceAt,notice:'Model break-even price only; a larger price does not establish a real betting edge.'}:null,
    priceNotice:best?'Saved observation only. Recheck this exact line at the sportsbook; the model break-even price is unvalidated.':'No usable saved price matches this question. Other games, players or lines cannot supply its price.',
    counterargument:risk,recheck:alerts.length?'Confirm the listed quarterbacks, relevant availability reports and player roles; then refresh the exact line and price.':'Recheck active players, quarterback continuity, weather at kickoff and the exact sportsbook line and price.',
    hasEdge:false,recommendationsReady:false};
}
