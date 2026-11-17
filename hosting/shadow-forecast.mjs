/* Derive research-only event means without changing the serving source. */
export function shadowGame(source,event){
  const model=source.index.shadowScoreModel,c=model?.coefficients;
  if(!model||model.schemaVersion!==1||model.validation?.adopted!==false||model.validation?.hasEdge!==false||model.cutoff!==source.index.scoreModel?.cutoff||!Array.isArray(c)||c.length!==66||!c.every(Number.isFinite)||!Array.isArray(model.teams)||model.teams.length!==32)return null;
  const h=model.teams.indexOf(event.homeCode),a=model.teams.indexOf(event.awayCode);
  if(h<0||a<0)return null;
  const clip=n=>Math.max(0,Math.min(65,n));
  const forecast={homeMean:clip(c[0]+(event.neutral?0:c[1])+c[2+h]+c[34+a]),awayMean:clip(c[0]+c[2+a]+c[34+h]),modelVersion:model.version,cutoff:model.cutoff};
  const shadowEvent={...event,forecast};
  return {source:{...source,index:{...source.index,scoreModel:model}},event:shadowEvent};
}

export function regimeShadowGame(source,event){
  const model=source.index.regimeScoreModel;
  if(model?.version!=='score-regime-kernel-v1'||!Array.isArray(model.residualContexts)||model.residualContexts.length!==model.residuals?.length)return null;
  return shadowGame({...source,index:{...source.index,shadowScoreModel:model}},event);
}

export function footballShadowGame(source,event){
  const f=source.index.footballScoreModel,record=f?.events?.[event.id],b=f?.blocks?.[record?.block];
  if(f?.version!=='score-football-features-v1'||f.validation?.adopted!==false||f.validation?.hasEdge!==false||f.cutoff!==source.index.scoreModel?.cutoff||!Array.isArray(f.teams)||f.teams.length!==32||!Array.isArray(f.residuals)||!record||!b||typeof b.fitDate!=='string'||record.inputCutoff!==b.inputCutoff||b.inputCutoff>=b.fitDate||Date.parse(record.startsAt)!==Date.parse(event.startsAt)||record.inputCutoff>=event.startsAt.slice(0,10))return null;
  const x=record.x,c=b.featureCoefficients,base=b.baseCoefficients;
  if(!Array.isArray(c)||c.length!==16||!c.every(Number.isFinite)||!Array.isArray(base)||base.length!==66||!base.every(Number.isFinite)||!Array.isArray(x)||x.length!==2||!x.every(row=>Array.isArray(row)&&row.length===16&&row.every(Number.isFinite)))return null;
  const h=f.teams.indexOf(event.homeCode),a=f.teams.indexOf(event.awayCode);if(h<0||a<0)return null;
  const clip=(v,low,high)=>Math.max(low,Math.min(high,v));
  const means=[clip(base[0]+(event.neutral?0:base[1])+base[2+h]+base[34+a],0,65),clip(base[0]+base[2+a]+base[34+h],0,65)].map((v,i)=>clip(v+clip(x[i].reduce((sum,n,j)=>sum+n*c[j],0),-7,7),0,65));
  const match=record.block.match(/^(\d{4})_(\d{2})$/);if(!match)return null;
  const residuals=f.residuals.filter(r=>Array.isArray(r)&&r.length===5&&r.slice(0,4).every(Number.isFinite)&&typeof r[4]==='string'&&r[4]<b.fitDate&&(r[2]<Number(match[1])||r[2]===Number(match[1])&&r[3]<Number(match[2]))).map(r=>r.slice(0,2));if(residuals.length<120)return null;
  const model={...f,coefficients:base,residuals};
  return {source:{...source,index:{...source.index,scoreModel:model}},event:{...event,forecast:{homeMean:means[0],awayMean:means[1],modelVersion:f.version,cutoff:f.cutoff}}};
}
