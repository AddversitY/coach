/* Independent conditional workload trial. Does not replace serving prop means. */
export const WORKLOAD_VERSION='workload-ridge-v1';
const GROUPS={QB_attempts:['QB','attempts',40,40,100],QB_carries:['QB','carries',8,35,60],RB_carries:['RB','carries',20,35,60],RB_targets:['RB','targets',4,35,40],WR_targets:['WR','targets',8,35,40],TE_targets:['TE','targets',6,35,40]};
const finite=n=>typeof n==='number'&&Number.isFinite(n);
const code=s=>({LA:'LAR',OAK:'LV',SD:'LAC',STL:'LAR',WSH:'WAS'})[s]||s;
const days=(a,b)=>(Date.parse(a+'T00:00:00Z')-Date.parse(b+'T00:00:00Z'))/86400000;
const fresh=(at,now,age)=>Number.isFinite(Date.parse(at))&&Date.parse(at)<=now&&now-Date.parse(at)<=age;
const gameDay=event=>{const parts=Object.fromEntries(new Intl.DateTimeFormat('en-US',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date(event.startsAt)).map(p=>[p.type,p.value]));return `${parts.year}-${parts.month}-${parts.day}`;};
const clip=(n,cap)=>Math.max(0,Math.min(cap,n));
const quantile=(a,q)=>{const p=(a.length-1)*q,i=Math.floor(p);return a[i]+(a[Math.min(i+1,a.length-1)]-a[i])*(p-i);};

export function trialHistory(player){
  const keys=['attempts','carries','targets','passing_yards','rushing_yards','receiving_yards','receptions'];
  const prior=(player.priorTrialGames||[]).map(r=>Array.isArray(r)?{date:r[0],week:r[1],position:r[2],stats:Object.fromEntries(keys.map((key,i)=>[key,r[i+3]]))}:r);
  return [...player.games,...prior];
}

export function workloadFeatures(history,teamGames,opponentGames,day,group,home){
  const spec=GROUPS[group];if(!spec)return null;
  const [position,metric,scale,teamScale,cap]=spec;
  const rows=[...history].filter(r=>r.date<day&&days(day,r.date)>0&&days(day,r.date)<=730&&finite(r.stats?.[metric])&&r.stats[metric]>=0).sort((a,b)=>b.date.localeCompare(a.date)).slice(0,10);
  if(rows.length<6||days(day,rows[0].date)>35)return null;
  const values=rows.map(r=>r.stats[metric]),weights=rows.map((_,i)=>.5**(i/4));
  const weighted=values.reduce((a,v,i)=>a+v*weights[i],0)/weights.reduce((a,b)=>a+b,0);if(weighted<=0)return null;
  const recent=values.slice(0,3).reduce((a,b)=>a+b,0)/3,prior=values.slice(3,6).reduce((a,b)=>a+b,0)/3;
  const incumbent=Math.min(weighted*1.25,Math.max(weighted*.75,.65*recent+.35*weighted));
  const team=[...teamGames].filter(g=>g.date<day).sort((a,b)=>b.date.localeCompare(a.date)).slice(0,6),other=[...opponentGames].filter(g=>g.date<day).sort((a,b)=>b.date.localeCompare(a.date)).slice(0,3),latest=team.slice(0,3);
  const teamVolume=latest.length?latest.reduce((a,g)=>a+g[metric],0)/latest.length:0;
  const paired=rows.slice(0,3).map(r=>[r,team.find(g=>g.date===r.date&&g.week===r.week)]),denominator=paired.reduce((a,[,g])=>a+(g?.[metric]||0),0);
  const share=denominator?paired.reduce((a,[r,g])=>a+(g?r.stats[metric]:0),0)/denominator:0;
  const dates=new Set(rows.map(r=>r.date)),missing=latest.length?latest.filter(g=>!dates.has(g.date)).length/latest.length:0;
  const mu=values.reduce((a,b)=>a+b,0)/values.length,variation=Math.min(3,Math.sqrt(values.reduce((a,v)=>a+(v-mu)**2,0)/values.length)/(mu+.1));
  const leaders=latest.map(g=>g.leader||g.passers?.[0]?.id).filter(Boolean),changed=Number(new Set(leaders).size>1);
  const opp=other.map(g=>g['allowed_'+metric]).filter(finite),opponentVolume=opp.length?opp.reduce((a,b)=>a+b,0)/opp.length:0;
  const x=[1,recent/scale,prior/scale,weighted/scale,values[0]/scale,(recent-prior)/scale,teamVolume/teamScale,share*teamVolume/scale,share,days(day,rows[0].date)/7,missing,variation,Number(home),team.length?Math.min(21,days(day,team[0].date))/7:0,changed,opponentVolume/teamScale,Number(!denominator||!opp.length)];
  if(!x.every(finite))return null;
  return {x,incumbent,last3:recent,last6:values.slice(0,6).reduce((a,b)=>a+b,0)/6,records:rows.length,latestDate:rows[0].date,metric,position,cap};
}

export function workloadForecasts(source,event,{now=Date.now(),context=null}={}){
  const model=source.index.workloadModel,data=source.index.roleContext;
  const unavailable={available:false,version:WORKLOAD_VERSION,forecasts:[],hasEdge:false};
  if(!model||model.schemaVersion!==1||model.version!==WORKLOAD_VERSION||model.adopted!==false||model.hasEdge!==false||!fresh(model.trainedAt,now,22*86400000)||!fresh(model.cutoff+'T00:00:00Z',now,22*86400000)||model.cutoff>source.index.cutoff||!data||!fresh(data.retrievedAt,now,22*86400000)||!fresh(data.cutoff+'T00:00:00Z',now,22*86400000)||Date.parse(event.startsAt)<=now)return unavailable;
  const day=gameDay(event),forecasts=[],intervals=new Map();
  const teamGames=(data.teamGames||[]).filter(g=>g.date<=data.cutoff&&g.date<day);
  for(const p of source.index.players.filter(p=>p.events.includes(event.id))){
    const team=code(p.team),other=team===event.homeCode?event.awayCode:team===event.awayCode?event.homeCode:null;if(!other)continue;
    const history=[];for(const row of trialHistory(p).filter(g=>g.date<=data.cutoff&&g.date<=source.index.cutoff).sort((a,b)=>b.date.localeCompare(a.date))){if(row.position&&row.position!==p.position)break;history.push(row);}
    for(const [group,[position]] of Object.entries(GROUPS)){
      const candidate=model.models?.[group];if(position!==p.position||!candidate||!Array.isArray(candidate.coefficients)||candidate.coefficients.length!==17||!candidate.coefficients.every(finite)||candidate.trainingRows<200)continue;
      const pack=workloadFeatures(history,teamGames.filter(g=>g.team===team),teamGames.filter(g=>g.team===other),day,group,team===event.homeCode);if(!pack)continue;
      const prediction=clip(pack.incumbent+pack.x.reduce((a,x,i)=>a+x*candidate.coefficients[i],0),pack.cap);
      if(!intervals.has(group)){const errors=(candidate.residuals||[]).filter(finite).sort((a,b)=>a-b);intervals.set(group,errors.length>=120?[quantile(errors,.1),quantile(errors,.9)]:null);}
      const range=intervals.get(group),interval=range?range.map(e=>clip(prediction+e,pack.cap)):null;
      const teamContext=context?.teams.find(t=>t.code===team),usage=teamContext?.usage.find(u=>u.playerId===p.id);
      const reviewReasons=[...(teamContext?.availability.some(o=>o.playerId===p.id)?['Reported availability concern']:[]),...(usage?.latestTeamGameMissing?['No appearance recorded in latest team game']:[]),...(['reported_concern','change_requires_review'].includes(teamContext?.quarterback.status)?['Quarterback continuity requires review']:[])];
      forecasts.push({playerId:p.id,name:p.name,team,group,metric:pack.metric,prediction,incumbent:pack.incumbent,last3:pack.last3,last6:pack.last6,interval,records:pack.records,latestDate:pack.latestDate,reviewReasons,conditionalOnRecordedAppearance:true});
    }
  }
  return {available:true,version:model.version,cutoff:model.cutoff,inputCutoff:data.cutoff,createdAt:new Date(now).toISOString(),forecasts:forecasts.slice(0,80),status:'shadow_only',adopted:false,hasEdge:false,
    notice:'Conditional workload trial, not a participation forecast or replacement for serving prop estimates. Intervals use earlier forecast errors; model and role uncertainty remain. No odds/ROI or betting advantage is established.'};
}

export function workloadSnapshot(source,event,options={}){
  const now=options.now??Date.now(),kick=Date.parse(event.startsAt);
  if(kick<=now||kick-now>24*3600000)return null;
  const trial=workloadForecasts(source,event,options);if(!trial.available||!trial.forecasts.length)return null;
  return {schemaVersion:1,id:`${trial.version}:${event.id}:unpriced`,modelVersion:trial.version,cutoff:trial.cutoff,event,capturedAt:trial.createdAt,
    rows:[],workloads:trial.forecasts,priced:false,benchmarkState:'not_applicable',notice:trial.notice};
}
