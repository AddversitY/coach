import {attachCalibration} from './calibration-trial.mjs';
/* Joint empirical workload/efficiency replay. Research only; never ranked as a pick. */
import {workloadFeatures,trialHistory} from './workload-forecast.mjs';
export const PRODUCTION_VERSION='production-joint-v1';
const MARKETS={passing_yards:'player_pass_yds',rushing_yards:'player_rush_yds',receiving_yards:'player_reception_yds',receptions:'player_receptions'};
const finite=n=>typeof n==='number'&&Number.isFinite(n);
const fresh=(s,now,age)=>Number.isFinite(Date.parse(s))&&Date.parse(s)<=now&&now-Date.parse(s)<=age;
const clip=(v,lo,hi)=>Math.max(lo,Math.min(hi,v));
const quantile=(v,q)=>{const p=(v.length-1)*q,i=Math.floor(p);return v[i]+(v[Math.min(i+1,v.length-1)]-v[i])*(p-i);};
const dayOf=e=>{const p=Object.fromEntries(new Intl.DateTimeFormat('en-US',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date(e.startsAt)).map(p=>[p.type,p.value]));return `${p.year}-${p.month}-${p.day}`;};
const code=s=>({LA:'LAR',WSH:'WAS',OAK:'LV',SD:'LAC',STL:'LAR'})[s]||s;
const mean=a=>a.length?a.reduce((a,b)=>a+b,0)/a.length:0;

export function productionRatePack(history,ownGames,otherGames,day,stat,metric){
  const rows=history.filter(r=>r.date<day&&(Date.parse(day+'T00:00:00Z')-Date.parse(r.date+'T00:00:00Z'))/86400000<=730&&finite(r.stats?.[stat])&&finite(r.stats?.[metric])&&r.stats[metric]>=0).sort((a,b)=>b.date.localeCompare(a.date)).slice(0,10);
  if(rows.length<6)return null;
  const weights=rows.map((_,i)=>.5**(i/4)),counts=rows.map(r=>r.stats[metric]),values=rows.map(r=>r.stats[stat]);
  const denominator=counts.reduce((a,v,i)=>a+weights[i]*v,0);if(!denominator)return null;
  const baseline=rows.filter(r=>r.stats[stat]>=0);if(baseline.length<6)return null;
  const bw=baseline.map((_,i)=>.5**(i/4)),bs=baseline.map(r=>r.stats[stat]),bc=baseline.map(r=>r.stats[metric]),sum=bw.reduce((a,b)=>a+b,0);
  const usage=bc.reduce((a,v,i)=>a+bw[i]*v,0)/sum;if(usage<=0)return null;
  const volume=Math.min(usage*1.25,Math.max(usage*.75,.65*mean(bc.slice(0,3))+.35*usage));
  const baselineMean=volume*bs.reduce((a,v,i)=>a+bw[i]*v,0)/bc.reduce((a,v,i)=>a+bw[i]*v,0);
  const observed=bs.reduce((a,v,i)=>a+bw[i]*v,0)/sum,variance=bs.reduce((a,v,i)=>a+bw[i]*(v-observed)**2,0)/sum;
  const baselineSd=Math.sqrt(Math.max(1,baselineMean*.15)**2+variance*(1+1/baseline.length));
  const rate=values.reduce((a,v,i)=>a+weights[i]*v,0)/denominator;
  const recentDen=counts.slice(0,3).reduce((a,b)=>a+b,0),priorDen=counts.slice(3,6).reduce((a,b)=>a+b,0);
  const recent=recentDen?values.slice(0,3).reduce((a,b)=>a+b,0)/recentDen:rate,prior=priorDen?values.slice(3,6).reduce((a,b)=>a+b,0)/priorDen:rate;
  const own=ownGames.filter(g=>g.date<day).sort((a,b)=>b.date.localeCompare(a.date)).slice(0,6),other=otherGames.filter(g=>g.date<day).sort((a,b)=>b.date.localeCompare(a.date)).slice(0,3);
  const passingRates=own.slice(0,3).filter(g=>g.attempts>0).map(g=>(g.passing_yards??g.passYards)/g.attempts),delta=passingRates.length>1?(passingRates[0]-mean(passingRates.slice(1)))/10:0;
  const leaders=own.slice(0,3).map(g=>g.leader||g.passers?.[0]?.id).filter(Boolean),changed=Number(new Set(leaders).size>1);
  const paired=other.filter(g=>finite(g['allowed_'+metric])&&finite(g['allowed_'+stat])),oppDen=paired.reduce((n,g)=>n+g['allowed_'+metric],0),opp=oppDen?paired.reduce((n,g)=>n+g['allowed_'+stat],0)/oppDen:0,scale=stat==='receptions'?1:10;
  const extra=[rate/scale,recent/scale,prior/scale,opp/scale,Number(!oppDen),delta,changed*rate/scale];
  if(!extra.every(finite))return null;
  return {rate,extra,baselineMean,baselineSd,last3:mean(values.slice(0,3)),last6:mean(values.slice(0,6))};
}

export function productionSamples(volume,rate,pairs,stat,cap){
  if(pairs.length<120)return null;
  const v=mean(pairs.map(p=>p[0])),e=mean(pairs.map(p=>p[1]));
  return pairs.map(pair=>{const count=clip(Math.floor(volume+pair[0]-v+.5),0,cap),efficiency=clip(rate+pair[1]-e,stat==='receptions'?0:-20,stat==='receptions'?1:60);return clip(Math.floor(count*efficiency+.5),stat==='receptions'?0:-999,stat==='receptions'?count:999);});
}

export function productionForecasts(source,event,{now=Date.now(),workloadTrial=null,observations=[]}={}){
  const model=source.index.productionModel,data=source.index.roleContext,volumeModel=source.index.workloadModel;
  const missing={available:false,version:PRODUCTION_VERSION,forecasts:[],rows:[],hasEdge:false};
  if(!model||model.schemaVersion!==1||model.version!==PRODUCTION_VERSION||model.adopted!==false||model.hasEdge!==false||model.volumeModelVersion!==volumeModel?.version||model.cutoff>source.index.cutoff||!fresh(model.trainedAt,now,22*86400000)||!fresh(model.cutoff+'T00:00:00Z',now,22*86400000)||!data||!fresh(data.retrievedAt,now,22*86400000)||!fresh(data.cutoff+'T00:00:00Z',now,22*86400000)||!workloadTrial?.available||Date.parse(event.startsAt)<=now)return missing;
  const day=dayOf(event),forecasts=[],rows=[],games=data.teamGames.filter(g=>g.date<=data.cutoff),residuals=new Map();
  for(const player of source.index.players.filter(p=>p.events.includes(event.id))){
    const team=code(player.team),opponent=team===event.homeCode?event.awayCode:team===event.awayCode?event.homeCode:null;if(!opponent)continue;
    const history=[];for(const r of trialHistory(player).filter(g=>g.date<=data.cutoff&&g.date<=source.index.cutoff).sort((a,b)=>b.date.localeCompare(a.date))){if(r.position&&r.position!==player.position)break;history.push(r);}
    const own=games.filter(g=>g.team===team),other=games.filter(g=>g.team===opponent);
    for(const [group,spec] of Object.entries(model.models||{})){
      if(!group.startsWith(player.position+'_')||!MARKETS[spec.stat]||spec.trainingRows<200||!Array.isArray(spec.coefficients)||spec.coefficients.length!==24||!spec.coefficients.every(finite))continue;
      const volume=workloadTrial.forecasts.find(f=>f.playerId===player.id&&f.group===spec.volumeGroup);if(!volume)continue;
      const pack=productionRatePack(history,own,other,day,spec.stat,volume.metric),work=workloadFeatures(history,own,other,day,spec.volumeGroup,team===event.homeCode);if(!pack||!work)continue;
      const x=[...work.x,...pack.extra],rate=clip(pack.rate+x.reduce((n,v,i)=>n+v*spec.coefficients[i],0),spec.stat==='receptions'?0:-20,spec.stat==='receptions'?1:60);
      if(!residuals.has(group))residuals.set(group,(spec.residualPairs||[]).filter(p=>Array.isArray(p)&&p.length===2&&p.every(finite)).slice(-512));
      const samples=productionSamples(volume.prediction,rate,residuals.get(group),spec.stat,work.cap);if(!samples)continue;
      const sorted=[...samples].sort((a,b)=>a-b),prediction=mean(samples),interval=[quantile(sorted,.1),quantile(sorted,.9)];
      forecasts.push({playerId:player.id,name:player.name,team,group,metric:spec.stat,prediction,incumbent:pack.baselineMean,last3:pack.last3,last6:pack.last6,interval,volume:volume.prediction,volumeMetric:volume.metric,efficiency:rate,records:work.records,reviewReasons:volume.reviewReasons,conditionalOnRecordedAppearance:true,
        historicalCoverage:model.validation?.[group]?.interval80Coverage??null});
      for(const observed of observations.filter(r=>r.playerId===player.id&&r.selection.eventId===event.id&&r.selection.participant===player.name&&r.selection.market===MARKETS[spec.stat]&&r.selection.period==='full_game'&&r.selection.rules==='player_prop_unverified'&&finite(r.decimal)&&r.decimal>1&&fresh(r.sourceAt,now,18*3600000)&&fresh(r.collectedAt,now,18*3600000)&&Date.parse(r.sourceAt)<=Date.parse(r.collectedAt))){
        const point=observed.selection.point,difference=v=>(v-point)*(observed.selection.outcome==='Over'?1:-1),win=samples.filter(v=>difference(v)>0).length/samples.length,push=samples.filter(v=>difference(v)===0).length/samples.length;
        rows.push({...observed,team,servingWin:observed.win,servingPush:observed.push,productionGroup:group,win,push,loss:Math.max(0,1-win-push),minimumDecimal:win>0?(1-push)/win:null,conditionalEv:win*observed.decimal-(1-push),forecastBasis:'experimental_joint_workload_efficiency',modelValidated:false,hasEdge:false,blocked:observed.blocked||volume.reviewReasons.length>0});
      }
    }
  }
  return {available:true,eventId:event.id,startsAt:event.startsAt,version:model.version,cutoff:model.cutoff,inputCutoff:data.cutoff,createdAt:new Date(now).toISOString(),forecasts:forecasts.slice(0,80),rows:rows.slice(0,150),status:'shadow_only',adopted:false,hasEdge:false,
    notice:'Joint workload/efficiency research, conditional on a recorded appearance. Ranges and exact-line probabilities remain unvalidated; some ranges were too wide historically. No serving prop forecast, recommendation or betting edge is promoted.'};
}

export function productionSnapshot(trial,event){
  const captured=Date.parse(trial?.createdAt),kick=Date.parse(event.startsAt);
  if(!trial?.available||trial.eventId!==event.id||trial.startsAt!==event.startsAt||!Number.isFinite(captured)||captured>=kick||kick-captured>24*3600000||!trial.forecasts.length)return null;
  return attachCalibration({schemaVersion:1,id:`${trial.version}:${event.id}:${trial.rows.length?'priced':'unpriced'}`,modelVersion:trial.version,cutoff:trial.cutoff,event,capturedAt:trial.createdAt,rows:trial.rows.slice(0,54),workloads:trial.forecasts,priced:!!trial.rows.length,benchmarkState:'not_applicable',notice:trial.notice});
}
