import {addGrade,evaluationReport,gradeForecast,validateBenchmark,benchmarkTargets} from './forecast-evaluation.mjs';

const response=(data,status=200)=>Response.json(data,{status});
const emptyCounts=()=>({capturedGames:0,snapshots:0,gradedGames:0,pendingGames:0,unresolved:0});
async function modelState(txn,version){
  let scoped=await txn.get('evaluation-model:'+version);
  if(!scoped){
    const versions=await txn.get('evaluation-versions')||[];
    // The original deployment had only one serving version. Preserve its
    // observations when introducing separate challenger cohorts.
    const legacy=versions.length===1&&versions[0]===version;
    scoped={counts:legacy?(await txn.get('evaluation-counts')||emptyCounts()):emptyCounts(),aggregate:legacy?(await txn.get('evaluation-aggregate')||{}):{}};
    await txn.put('evaluation-model:'+version,scoped);
  }
  return scoped;
}
async function trackBenchmark(txn,snapshot){
  if(!snapshot.benchmarkFacts)return;
  const key=`benchmark-event:${snapshot.modelVersion}:${snapshot.event.id}`,old=await txn.get(key);
  if(old?.priced&&!snapshot.priced)return;
  const value={id:snapshot.id,priced:snapshot.priced,state:snapshot.benchmarkState,protocol:snapshot.benchmarkPromptVersion||'legacy',reason:snapshot.benchmarkReason||null};
  if(old&&JSON.stringify(old)===JSON.stringify(value))return;
  const scoped=await modelState(txn,snapshot.modelVersion);scoped.benchmarkCoverage ||= {};scoped.benchmarkFailureReasons ||= {};
  if(old?.reason)scoped.benchmarkFailureReasons[old.reason]=Math.max(0,(scoped.benchmarkFailureReasons[old.reason]||0)-1);
  if(value.reason)scoped.benchmarkFailureReasons[value.reason]=(scoped.benchmarkFailureReasons[value.reason]||0)+1;
  const counter=v=>(v.protocol==='fair-source-context-v3'?'fair_':'legacy_')+v.state;
  if(old)scoped.benchmarkCoverage[counter(old)]=Math.max(0,(scoped.benchmarkCoverage[counter(old)]||0)-1);
  scoped.benchmarkCoverage[counter(value)]=(scoped.benchmarkCoverage[counter(value)]||0)+1;
  await txn.put(key,value);await txn.put('evaluation-model:'+snapshot.modelVersion,scoped);
}
export async function evaluationState(state,path,request,clock=Date.now()){

  const storage=state.storage;
  if(path==='/evaluation')return storage.transaction(async txn=>{
    const versions=await txn.get('evaluation-versions')||[];
    const selected=new URL(request.url).searchParams.get('modelVersion')||versions[0]||null;
    const models=[];
    for(const version of versions){const scoped=await modelState(txn,version);models.push({...evaluationReport(scoped.aggregate,scoped.counts),modelVersion:version,benchmarkCoverage:scoped.benchmarkCoverage||{},benchmarkFailureReasons:scoped.benchmarkFailureReasons||{},role:version===selected?'serving':'shadow'});}
    const current=models.find(m=>m.modelVersion===selected)||{...evaluationReport({},emptyCounts()),modelVersion:selected,role:'serving'};
    return response({...current,models,aiProvider:await txn.get('ai-provider-status')||null});
  });
  if(path==='/forecast-capture'){
    const snapshot=await request.json();
    if(!snapshot?.id||snapshot.id.length>300||!snapshot.event?.id||!Array.isArray(snapshot.rows)||snapshot.rows.length>60||(snapshot.workloads!=null&&(!Array.isArray(snapshot.workloads)||snapshot.workloads.length>80))||JSON.stringify(snapshot).length>100000||Date.parse(snapshot.capturedAt)>=Date.parse(snapshot.event.startsAt))return response({error:'Invalid forecast'},400);
    return storage.transaction(async txn=>{
      const key='forecast:'+snapshot.id,existing=await txn.get(key);
      if(existing){await trackBenchmark(txn,existing);return response(existing);}
      const counts=await txn.get('evaluation-counts')||{capturedGames:0,snapshots:0,gradedGames:0,pendingGames:0,unresolved:0};
      if(counts.capturedGames>=5000)return response({error:'Research storage limit'},409);
      const versions=await txn.get('evaluation-versions')||[];
      for(const version of versions)await modelState(txn,version);
      const scoped=await modelState(txn,snapshot.modelVersion);
      const gameKey=`captured-game:${snapshot.modelVersion}:${snapshot.event.id}`;
      if(!await txn.get(gameKey)){await txn.put(gameKey,true);counts.capturedGames++;counts.pendingGames++;scoped.counts.capturedGames++;scoped.counts.pendingGames++;}
      counts.snapshots++;scoped.counts.snapshots++;await txn.put('evaluation-model:'+snapshot.modelVersion,scoped);await txn.put(key,snapshot);await txn.put('evaluation-counts',counts);
      if(!versions.includes(snapshot.modelVersion)){versions.push(snapshot.modelVersion);await txn.put('evaluation-versions',versions.slice(-8));}
      await trackBenchmark(txn,snapshot);return response(snapshot);
    });
  }
  if(path==='/benchmark-auto-reserve'){
    const {id,limit}=await request.json();
    return storage.transaction(async txn=>{
      const snapshot=await txn.get('forecast:'+id);
      const provider=await txn.get('ai-provider-status');if(provider&&Date.parse(provider.blockedUntil)>clock)return response({reserved:false,reason:'provider_daily_limit'});
      if(!snapshot?.priced||snapshot.benchmarkPromptVersion!=='fair-source-context-v3'||!['not_requested','waiting_for_quota'].includes(snapshot.benchmarkState)||clock>=Date.parse(snapshot.event.startsAt))return response({reserved:false});
      const day=new Date(clock).toISOString().slice(0,10),budget=await txn.get('automatic-benchmark-budget');
      const next=budget?.day===day?budget:{day,count:0,ids:[]};
      const cap=Number.isInteger(limit)?Math.min(2,Math.max(0,limit)):0;
      if(next.count>=cap||next.ids.includes(id))return response({reserved:false});
      next.count++;next.ids.push(id);await txn.put('automatic-benchmark-budget',next);return response({reserved:true});
    });
  }
  if(path==='/benchmark-reserve'){
    const {id}=await request.json();
    return storage.transaction(async txn=>{
      const snapshot=await txn.get('forecast:'+id);
      if(!snapshot||!['not_requested','waiting_for_quota'].includes(snapshot.benchmarkState))return response({reserved:false});
      if(!Number.isFinite(Date.parse(snapshot.event.startsAt))||clock>=Date.parse(snapshot.event.startsAt)){snapshot.benchmarkState='expired';await txn.put('forecast:'+id,snapshot);await trackBenchmark(txn,snapshot);return response({reserved:false,reason:'kickoff_passed'});}
      snapshot.benchmarkState='started';snapshot.benchmarkStartedAt=new Date(clock).toISOString();await txn.put('forecast:'+id,snapshot);await trackBenchmark(txn,snapshot);return response({reserved:true,snapshot});
    });
  }
  if(path==='/benchmark-save'){
    const {id,result,reason}=await request.json();
    return storage.transaction(async txn=>{
      const snapshot=await txn.get('forecast:'+id);if(!snapshot)return response({error:'Unknown forecast'},404);
      if(snapshot.benchmarkState!=='started')return response({error:'No pending benchmark'},409);
      snapshot.benchmarkCompletedAt=new Date(clock).toISOString();
      if(clock>=Date.parse(snapshot.event.startsAt)){snapshot.benchmarkState='late';snapshot.benchmarkReason='completed_after_kickoff';}
      else if(result){snapshot.benchmark=validateBenchmark(result,snapshot);snapshot.benchmarkState=snapshot.benchmark.length===benchmarkTargets(snapshot).length?'available':'partial';}
      else {snapshot.benchmarkState=['quota_deferred','provider_daily_limit'].includes(reason)?'waiting_for_quota':'unavailable';snapshot.benchmarkReason=['quota_deferred','provider_daily_limit','provider_capacity','model_requires_paid_plan','invalid_model_request','invalid_model_reply','provider_timeout','provider_access','provider_unavailable'].includes(reason)?reason:'model_unavailable';}
      await txn.put('forecast:'+id,snapshot);await trackBenchmark(txn,snapshot);return response({ok:true});
    });
  }
  if(path==='/grade-batch'){
    const body=await request.json();
    if(!Array.isArray(body.results)||body.results.length>400||typeof body.hash!=='string')return response({error:'Invalid result batch'},400);
    if(await storage.get('evaluation-grading-version')==='fair-head-to-head-v3'&&await storage.get('evaluation-results-hash')===body.hash)return response({unchanged:true});
    const versions=await storage.get('evaluation-versions')||[];
    for(const result of body.results)for(const version of versions){
      if(typeof result.eventId!=='string'||!Number.isInteger(result.homeScore)||!Number.isInteger(result.awayScore))continue;
      const priced=await storage.get(`forecast:${version}:${result.eventId}:priced`);
      const snapshot=priced||await storage.get(`forecast:${version}:${result.eventId}:unpriced`);
      if(!snapshot)continue;
      const grade=gradeForecast(snapshot,result);
      await storage.transaction(async txn=>{
        const key=`grade:${version}:${result.eventId}`,old=await txn.get(key),aggregate=await txn.get('evaluation-aggregate')||{};
        const counts=await txn.get('evaluation-counts'),scoped=await modelState(txn,version);
        if(old){addGrade(aggregate,old,-1);addGrade(scoped.aggregate,old,-1);counts.unresolved-=old.unresolved;scoped.counts.unresolved-=old.unresolved;}
        else{counts.gradedGames++;counts.pendingGames--;scoped.counts.gradedGames++;scoped.counts.pendingGames--;}
        addGrade(aggregate,grade);addGrade(scoped.aggregate,grade);counts.unresolved+=grade.unresolved;scoped.counts.unresolved+=grade.unresolved;
        await txn.put('evaluation-model:'+version,scoped);
        await txn.put(key,grade);await txn.put('evaluation-aggregate',aggregate);await txn.put('evaluation-counts',counts);
      });
    }
    await storage.put('evaluation-results-hash',body.hash);await storage.put('evaluation-grading-version','fair-head-to-head-v3');return response({ok:true});
  }
  return null;
}
