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
