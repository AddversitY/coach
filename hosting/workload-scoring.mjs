const mean=a=>a.length?a.reduce((a,b)=>a+b,0)/a.length:null;
const GROUPS={QB_attempts:'attempts',QB_carries:'carries',RB_carries:'carries',RB_targets:'targets',WR_targets:'targets',TE_targets:'targets'};

export function gradeWorkloads(snapshot,result){
  const groups={};let unresolved=0;
  for(const row of snapshot.workloads||[]){
    const actual=result.playerStats?.[row.playerId]?.[row.metric];
    if(GROUPS[row.group]!==row.metric||result.playerTeams?.[row.playerId]!==row.team||!Number.isInteger(actual)||actual<0){unresolved++;continue;}
    if(!['prediction','incumbent','last3','last6'].every(k=>Number.isFinite(row[k])&&row[k]>=0)){unresolved++;continue;}
    (groups[row.group]??=[]).push({candidateAbsolute:Math.abs(row.prediction-actual),incumbentAbsolute:Math.abs(row.incumbent-actual),last3Absolute:Math.abs(row.last3-actual),last6Absolute:Math.abs(row.last6-actual),squaredError:(row.prediction-actual)**2,incumbentSquaredError:(row.incumbent-actual)**2,
      intervalCoverage:Array.isArray(row.interval)&&row.interval.length===2&&row.interval.every(Number.isFinite)&&row.interval[0]>=0&&row.interval[1]>=row.interval[0]?Number(row.interval[0]<=actual&&actual<=row.interval[1]):null});
  }
  return {unresolved,groups:Object.fromEntries(Object.entries(groups).map(([group,rows])=>[group,{observations:rows.length,...Object.fromEntries(['candidateAbsolute','incumbentAbsolute','last3Absolute','last6Absolute','squaredError','incumbentSquaredError'].map(k=>[k,mean(rows.map(r=>r[k]))])),intervalObservations:rows.filter(r=>r.intervalCoverage!=null).length,intervalCoverage:mean(rows.filter(r=>r.intervalCoverage!=null).map(r=>r.intervalCoverage))}]))};
}

export function addWorkloadGrade(aggregate,groups={},direction=1){
  for(const [group,row] of Object.entries(groups)){
    const key='workload:'+group,current=aggregate[key]||{kind:'workload',group,games:0,observations:0,intervalGames:0};
    current.games+=direction;current.observations+=direction*row.observations;
    for(const k of ['candidateAbsolute','incumbentAbsolute','last3Absolute','last6Absolute','squaredError','incumbentSquaredError'])current[k]=(current[k]||0)+direction*row[k];
    if(row.intervalObservations){current.intervalGames+=direction;current.intervalCoverage=(current.intervalCoverage||0)+direction*row.intervalCoverage;}
    aggregate[key]=current;
  }
}

export function workloadReport(aggregate){
  return Object.values(aggregate).filter(r=>r.kind==='workload'&&r.games>0).map(r=>({group:r.group,games:r.games,observations:r.observations,mae:r.candidateAbsolute/r.games,incumbentMae:r.incumbentAbsolute/r.games,last3Mae:r.last3Absolute/r.games,last6Mae:r.last6Absolute/r.games,rmse:Math.sqrt(Math.max(0,r.squaredError/r.games)),incumbentRmse:Math.sqrt(Math.max(0,r.incumbentSquaredError/r.games)),intervalGames:r.intervalGames,interval80Coverage:r.intervalGames?r.intervalCoverage/r.intervalGames:null,hasEdge:false}));
}
