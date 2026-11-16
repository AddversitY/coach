// Fixed before future outcomes; no fitting or automatic adoption.
export const CALIBRATION_VERSION='temperature-080-v1';
export function attachCalibration(snapshot){
  if(!snapshot)return snapshot;
  return {...snapshot,calibrationVersion:CALIBRATION_VERSION,rows:snapshot.rows.map(row=>{
    const {win,push}=row;
    if(!Number.isFinite(win)||!Number.isFinite(push)||win<0||push<0||win+push>1||push>=1)return row;
    const p=win/(1-push);
    const adjusted=p===0||p===1?p:1/(1+Math.exp(-.8*Math.log(p/(1-p))));
    return {...row,calibrationWin:adjusted*(1-push),calibrationPush:push};
  })};
}
export function calibrationSummary(row){
  const games=row.calibrationGames||0;
  return {version:CALIBRATION_VERSION,games,status:games<1000?'collecting_evidence':'review_required',adopted:false,hasEdge:false,
    brierDifference:games?row.calibrationBrierDelta/games:null,logLossDifference:games?row.calibrationLogDelta/games:null,
    notice:'Fixed log-odds multiplier 0.80, captured before outcomes. Negative differences favor the trial over the original forecast on matched selections. This may improve or worsen accuracy; it is not fitted or used in recommendations.'};
}
