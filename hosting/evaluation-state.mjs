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
export async function evaluationState(state,path,request){
  const storage=state.storage;
  if(path==='/evaluation')return storage.transaction(async txn=>{
    const versions=await txn.get('evaluation-versions')||[];
    const selected=new URL(request.url).searchParams.get('modelVersion')||versions[0]||null;
    const models=[];
    for(const version of versions){const scoped=await modelState(txn,version);models.push({...evaluationReport(scoped.aggregate,scoped.counts),modelVersion:version,role:version===selected?'serving':'shadow'});}
    const current=models.find(m=>m.modelVersion===selected)||{...evaluationReport({},emptyCounts()),modelVersion:selected,role:'serving'};
    return response({...current,models});
  });
  if(path==='/forecast-capture'){
    const snapshot=await request.json();
    if(!snapshot?.id||snapshot.id.length>300||!snapshot.event?.id||!Array.isArray(snapshot.rows)||snapshot.rows.length>60||(snapshot.workloads!=null&&(!Array.isArray(snapshot.workloads)||snapshot.workloads.length>80))||JSON.stringify(snapshot).length>100000||Date.parse(snapshot.capturedAt)>=Date.parse(snapshot.event.startsAt))return response({error:'Invalid forecast'},400);
    return storage.transaction(async txn=>{
      const key='forecast:'+snapshot.id,existing=await txn.get(key);
      if(existing)return response(existing);
      const counts=await txn.get('evaluation-counts')||{capturedGames:0,snapshots:0,gradedGames:0,pendingGames:0,unresolved:0};
      if(counts.capturedGames>=5000)return response({error:'Research storage limit'},409);
      const versions=await txn.get('evaluation-versions')||[];
      for(const version of versions)await modelState(txn,version);
      const scoped=await modelState(txn,snapshot.modelVersion);
      const gameKey=`captured-game:${snapshot.modelVersion}:${snapshot.event.id}`;
      if(!await txn.get(gameKey)){await txn.put(gameKey,true);counts.capturedGames++;counts.pendingGames++;scoped.counts.capturedGames++;scoped.counts.pendingGames++;}
      counts.snapshots++;scoped.counts.snapshots++;await txn.put('evaluation-model:'+snapshot.modelVersion,scoped);await txn.put(key,snapshot);await txn.put('evaluation-counts',counts);
      if(!versions.includes(snapshot.modelVersion)){versions.push(snapshot.modelVersion);await txn.put('evaluation-versions',versions.slice(-8));}
      return response(snapshot);
    });
  }
  if(path==='/benchmark-reserve'){
    const {id}=await request.json();
    return storage.transaction(async txn=>{
      const snapshot=await txn.get('forecast:'+id);
      if(!snapshot||snapshot.benchmarkState!=='not_requested')return response({reserved:false});
      snapshot.benchmarkState='started';await txn.put('forecast:'+id,snapshot);return response({reserved:true,snapshot});
    });
  }
  if(path==='/benchmark-save'){
    const {id,result}=await request.json();
    return storage.transaction(async txn=>{
      const snapshot=await txn.get('forecast:'+id);if(!snapshot)return response({error:'Unknown forecast'},404);
      if(result){snapshot.benchmark=validateBenchmark(result,snapshot);snapshot.benchmarkState=snapshot.benchmark.length===benchmarkTargets(snapshot).length?'available':'partial';}
      else snapshot.benchmarkState='unavailable';
      await txn.put('forecast:'+id,snapshot);return response({ok:true});
    });
  }
  if(path==='/grade-batch'){
    const body=await request.json();
    if(!Array.isArray(body.results)||body.results.length>400||typeof body.hash!=='string')return response({error:'Invalid result batch'},400);
    if(await storage.get('evaluation-grading-version')==='accuracy-audit-calibration-v2'&&await storage.get('evaluation-results-hash')===body.hash)return response({unchanged:true});
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
    await storage.put('evaluation-results-hash',body.hash);await storage.put('evaluation-grading-version','accuracy-audit-calibration-v2');return response({ok:true});
  }
  return null;
}
