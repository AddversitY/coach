import {regimeWeights} from './regime-weights.mjs';
import {compareResearch} from './research-comparison.mjs';
import {productionForecasts} from './production-forecast.mjs';
import {workloadForecasts} from './workload-forecast.mjs';
import {gameContext,projectionWarnings,decisionBrief} from './game-context.mjs';
/* Deterministic pregame analysis. The score candidate failed the historical
 * market comparison, so available market probabilities anchor pricing. No AI
 * prose can promote these research estimates into a validated betting edge. */
export const GAME_VERSION='game-analysis-v1';
const GAME_MARKETS=new Set(['h2h','spreads','totals']);
const PROP_KEYS={player_pass_yds:['passing_yards','attempts','Pass yards'],player_rush_yds:['rushing_yards','carries','Rush yards'],player_reception_yds:['receiving_yards','targets','Receiving yards'],player_receptions:['receptions','targets','Receptions']};
const BOOKS={draftkings:'DraftKings',fanduel:'FanDuel',betmgm:'BetMGM',williamhill_us:'Caesars',espnbet:'ESPN BET',fanatics:'Fanatics',betrivers:'BetRivers',hardrockbet:'Hard Rock Bet',ballybet:'Bally Bet',fliff:'Fliff'};
const normalize=s=>String(s||'').toLowerCase().replace(/[^a-z0-9 ]/g,'').replace(/\s+/g,' ').trim();
const finite=n=>typeof n==='number'&&Number.isFinite(n);
const fresh=(time,now,age)=>Number.isFinite(Date.parse(time))&&Date.parse(time)<=now&&now-Date.parse(time)<=age;
export function requestedBook(question,context={}){const matched=Object.entries(BOOKS).filter(([,name])=>normalize(question).includes(normalize(name)));return matched.length===1?matched[0][0]:typeof context.bookId==='string'?context.bookId:null;}
export function quoteId(q){return JSON.stringify([q.bookId,q.selection]);}

export function resolveGame(index,question,context={},now=Date.now()){
  const day=value=>{const p=Object.fromEntries(new Intl.DateTimeFormat('en-US',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date(value)).map(x=>[x.type,x.value]));return Date.UTC(Number(p.year),Number(p.month)-1,Number(p.day));};
  const today=day(now),monday=today-((new Date(today).getUTCDay()+6)%7)*86400000;
  const dateText=question.match(/\b(20\d{2}-\d{2}-\d{2})\b/)?.[1];
  const exact=dateText?Date.parse(dateText+'T00:00:00Z'):/\btomorrow\b/i.test(question)?today+86400000:/\btoday\b/i.test(question)?today:null;
  const start=/\bnext week\b/i.test(question)?monday+7*86400000:/\bthis week\b/i.test(question)?monday:null;
  const future=index.events.filter(e=>Date.parse(e.startsAt)>now&&(exact==null||day(e.startsAt)===exact)&&(start==null||day(e.startsAt)>=start&&day(e.startsAt)<start+7*86400000)).sort((a,b)=>Date.parse(a.startsAt)-Date.parse(b.startsAt));
  const q=normalize(question),names=[...new Set([...Object.values(index.clubs||{}),...future.flatMap(e=>[e.home,e.away])])];
  const matched=names.filter(name=>(' '+q+' ').includes(' '+normalize(name)+' ')||(' '+q+' ').includes(' '+normalize(name.split(' ').at(-1))+' ')||future.some(e=>{const code=e.home===name?e.homeCode:e.awayCode;return [e.home,e.away].includes(name)&&typeof code==='string'&&new RegExp('\\b'+code+'\\b').test(question);}));
  if(matched.length){const options=future.filter(e=>matched.every(name=>[e.home,e.away].includes(name)));return options[0]||null;}
  return future.find(e=>e.id===context.eventId)||null;
}

export function validQuotes(source,event,now){
  const {snapshot,index}=source;
  if(snapshot.odds?.testFixture||snapshot.props?.demo||!fresh(snapshot.props?.fetchedAt,now,18*3600000))return [];
  const identities=snapshot.odds?.coverage?.players||[];
  const latest=new Map();
  for(const q of snapshot.props?.quotes||[]){
    const s=q.selection;
    if(!s||s.eventId!==event.id||q.provider!=='the-odds-api'||BOOKS[q.bookId]!==q.book||q.demo||q.status!=='open'||!finite(q.decimal)||q.decimal<=1||q.decimal>1001||s.period!=='full_game'||!fresh(q.sourceAt,now,18*3600000)||!fresh(q.collectedAt,now,18*3600000)||Date.parse(q.sourceAt)>Date.parse(q.collectedAt)||Date.parse(q.collectedAt)>Date.parse(snapshot.props.fetchedAt))continue;
    if(GAME_MARKETS.has(s.market)){
      if(s.participant!==''||s.rules!=='game_market_unverified')continue;
      if(s.market==='h2h'){if(s.point!=null||![event.home,event.away,'Draw'].includes(s.outcome))continue;}
      else if(!finite(s.point)||Math.abs(s.point)>1000||s.point*2!==Math.round(s.point*2)||s.market==='spreads'&&![event.home,event.away].includes(s.outcome)||s.market==='totals'&&(!['Over','Under'].includes(s.outcome)||s.point<0))continue;
    }else{
      const identity=identities.find(p=>p.name===s.participant);
      if(!PROP_KEYS[s.market]||s.rules!=='player_prop_unverified'||!identity||!index.players.some(p=>p.id===identity.playerId&&p.name===s.participant&&p.events.includes(event.id))||!['Over','Under'].includes(s.outcome)||!finite(s.point)||s.point<0||s.point>1000||s.point*2!==Math.round(s.point*2))continue;
    }
    const key=quoteId(q),prior=latest.get(key);
    if(!prior||Date.parse(q.sourceAt)>Date.parse(prior.sourceAt)||q.sourceAt===prior.sourceAt&&Date.parse(q.collectedAt)>Date.parse(prior.collectedAt))latest.set(key,q);
  }
  return [...latest.values()];
}

export function outcome(selection,home,away,playerValue=null,threeWay=false){
  let difference;
  if(selection.market==='h2h'){
    if(selection.outcome==='Draw')return home===away?1:-1;
    difference=selection.outcome===selection.homeTeam?home-away:away-home;
    if(threeWay&&difference===0)return -1;
  }else if(selection.market==='spreads')difference=(selection.outcome===selection.homeTeam?home-away:away-home)+selection.point;
  else if(selection.market==='totals')difference=(home+away-selection.point)*(selection.outcome==='Over'?1:-1);
  else if(finite(playerValue))difference=(playerValue-selection.point)*(selection.outcome==='Over'?1:-1);
  else return null;
  return difference>1e-9?1:difference< -1e-9?-1:0;
}

function pairFor(q,quotes,event){
  const s=q.selection;
  const paired=quotes.filter(other=>other.bookId===q.bookId&&other.selection.market===s.market&&other.selection.participant===s.participant&&other.selection.outcome!==s.outcome&&other.sourceAt===q.sourceAt&&other.selection.rules===s.rules&&(s.market==='h2h'||s.market==='spreads'?s.market==='h2h'||other.selection.point===-s.point:other.selection.point===s.point));
  if(s.market==='h2h'){
    const group=[q,...paired];if(!group.some(x=>x.selection.outcome===event.home)||!group.some(x=>x.selection.outcome===event.away)||new Set(group.map(x=>x.selection.outcome)).size!==group.length)return null;
    return {chance:(1/q.decimal)/group.reduce((a,x)=>a+1/x.decimal,0),threeWay:group.some(x=>x.selection.outcome==='Draw')};
  }
  return paired.length===1?{chance:(1/q.decimal)/(1/q.decimal+1/paired[0].decimal),threeWay:false}:null;
}

function summarize(samples,selection,event,threeWay=false){
  let win=0,push=0,total=0;
  for(const [home,away,weight] of samples){const result=outcome({...selection,homeTeam:event.home},home,away,null,threeWay);if(result===1)win+=weight;else if(result===0)push+=weight;total+=weight;}
  return {win:win/total,push:push/total,loss:Math.max(0,(total-win-push)/total)};
}
const median=values=>{const a=[...values].sort((a,b)=>a-b);return a[Math.floor(a.length/2)];};
function scoreSamples(source,event,quotes){
  const model=source.index.scoreModel,forecast=event.forecast;
  if(!model||!forecast||!Array.isArray(model.residuals)||model.residuals.length<120||model.version!==forecast.modelVersion||!finite(forecast.homeMean)||!finite(forecast.awayMean))return null;
  const constraints=[];
  for(const market of ['spreads','totals','h2h']){
    const options=quotes.filter(q=>q.selection.market===market&&(market==='spreads'||market==='h2h'?q.selection.outcome===event.home:q.selection.outcome==='Over')).map(q=>({q,pair:pairFor(q,quotes,event)})).filter(x=>x.pair);
    if(!options.length)continue;
    const line=market==='h2h'?null:median(options.map(x=>x.q.selection.point));
    const same=options.filter(x=>market==='h2h'||x.q.selection.point===line);
    constraints.push({selection:same[0].q.selection,chance:median(same.map(x=>x.pair.chance)),threeWay:same[0].pair.threeWay});
  }
  const spread=constraints.find(c=>c.selection.market==='spreads'),total=constraints.find(c=>c.selection.market==='totals');
  let homeMean=forecast.homeMean,awayMean=forecast.awayMean;
  if(spread||total){const margin=spread?-spread.selection.point:homeMean-awayMean,sum=total?total.selection.point:homeMean+awayMean;homeMean=Math.max(0,(sum+margin)/2);awayMean=Math.max(0,(sum-margin)/2);}
  const errors=model.residuals.filter(e=>Array.isArray(e)&&e.length===2&&e.every(finite));
  if(errors.length<120)return null;
  const centers=[0,1].map(i=>constraints.length?errors.reduce((a,e)=>a+e[i],0)/errors.length:0);
  const researchWeights=model.version==='score-regime-kernel-v1'&&!constraints.length?regimeWeights(model.residualContexts||[],[homeMean,awayMean]):null;
  if(model.version==='score-regime-kernel-v1'&&(!researchWeights||researchWeights.length!==errors.length))return null;
  const sample=errors.map((e,i)=>[Math.max(0,Math.min(90,Math.round(homeMean+e[0]-centers[0]))),Math.max(0,Math.min(90,Math.round(awayMean+e[1]-centers[1]))),researchWeights?researchWeights[i]:1/errors.length]);
  // Fit market constraints jointly, preserving a single coherent distribution.
  // This is a market benchmark, not an independent claim of predictive edge.
  for(let step=0;step<24&&constraints.length;step++)for(const constraint of constraints){
    const p=summarize(sample,constraint.selection,event,constraint.threeWay),decided=1-p.push;
    if(p.win<1e-9||p.loss<1e-9||decided<1e-9)continue;
    const winScale=constraint.chance*decided/p.win,loseScale=(1-constraint.chance)*decided/p.loss;
    for(const row of sample){const result=outcome({...constraint.selection,homeTeam:event.home},row[0],row[1],null,constraint.threeWay);if(result===1)row[2]*=winScale;else if(result===-1)row[2]*=loseScale;}
  }
  const sum=sample.reduce((a,r)=>a+r[2],0);for(const row of sample)row[2]/=sum;
  return {sample,basis:constraints.length?'market_anchored':'experimental_score_candidate',independentScore:{home:forecast.homeMean,away:forecast.awayMean},anchorCount:constraints.length};
}

function cdf(x){if(x>8)return 1;if(x< -8)return 0;const z=Math.abs(x),t=1/(1+.2316419*z),tail=.3989422804014327*Math.exp(-z*z/2)*t*(.319381530+t*(-.356563782+t*(1.781477937+t*(-1.821255978+t*1.330274429))));return x>=0?1-tail:tail;}
export function playerProjection(player,market){
  const spec=PROP_KEYS[market];if(!spec)return null;
  const rows=player.games.slice(0,10).filter(g=>finite(g.stats?.[spec[0]])&&g.stats[spec[0]]>=0&&finite(g.stats?.[spec[1]])&&g.stats[spec[1]]>=0);
  if(rows.length<6)return null;
  const weights=rows.map((_,i)=>.5**(i/4)),sum=weights.reduce((a,b)=>a+b,0);
  const weighted=key=>rows.reduce((a,r,i)=>a+r.stats[key]*weights[i],0)/sum;
  const usage=weighted(spec[1]);if(usage<=0)return null;
  const rate=weighted(spec[0])/usage,recent=rows.slice(0,3).reduce((a,r)=>a+r.stats[spec[1]],0)/3;
  const volume=Math.min(usage*1.25,Math.max(usage*.75,.65*recent+.35*usage));
  const mean=volume*rate,observedMean=weighted(spec[0]);
  const variance=rows.reduce((a,r,i)=>a+weights[i]*(r.stats[spec[0]]-observedMean)**2,0)/sum;
  const sd=Math.sqrt(Math.max(1,mean*.15)**2+variance*(1+1/rows.length));
  return {playerId:player.id,name:player.name,market,metric:spec[0],label:spec[2],mean,sd,expectedWorkload:volume,workload:spec[1],efficiency:rate,records:rows.length,participation:'Conditional on the recorded role; current participation unconfirmed',opponentAdjustment:'Not modeled; forecast remains experimental',hasEdge:false};
}
function propChance(projection,selection){
  const below=k=>k<0?0:cdf((k+.5-projection.mean)/projection.sd);
  const line=selection.point,above=1-below(Math.floor(line)),under=below(Math.ceil(line)-1),push=Number.isInteger(line)?Math.max(0,1-above-under):0;
  const win=selection.outcome==='Over'?above:under;return {win,push,loss:Math.max(0,1-win-push)};
}
function percentile(samples,key,p){const rows=samples.map(r=>[key(r),r[2]]).sort((a,b)=>a[0]-b[0]);let total=0;for(const row of rows){total+=row[1];if(total>=p)return row[0];}return rows.at(-1)[0];}

export function analyzeGame(source,event,{now=Date.now(),telemetry=null,bookId=null,anchorMarket=true,question='',includeProduction=true}={}){
  if(!event||Date.parse(event.startsAt)<=now)throw new Error('Upcoming game required');
  const model=source.index.scoreModel;
  if(!model||!fresh(model.trainedAt,now,22*86400000)||!fresh(model.cutoff+'T00:00:00Z',now,22*86400000))throw new Error('Forecast model unavailable');
  const quotes=validQuotes(source,event,now),distribution=scoreSamples(source,event,anchorMarket?quotes:[]);
  if(!distribution)throw new Error('Score forecast unavailable');
  const live=telemetry&&fresh(telemetry.checkedAt,now,5*60000)?telemetry:null;
  const injury=live?.observations.filter(o=>o.eventId===event.id&&o.kind==='injury'&&fresh(o.observedAt,now,12*60000))||[];
  const players=source.index.players.filter(p=>p.events.includes(event.id));
  const context=gameContext(source,event,{now,telemetry:live});
  const projections=players.flatMap(p=>Object.keys(PROP_KEYS).map(m=>playerProjection(p,m)).filter(Boolean)).map(p=>{const warnings=projectionWarnings(p,context);return {...p,contextWarnings:warnings,roleReviewRequired:warnings.length>0};});
  const rows=[];
  for(const q of quotes){
    if(bookId&&q.bookId!==bookId)continue;
    const s=q.selection,paired=pairFor(q,quotes,event);
    let probabilities,projection;
    if(GAME_MARKETS.has(s.market))probabilities=summarize(distribution.sample,s,event,paired?.threeWay);
    else{projection=projections.find(p=>p.name===s.participant&&p.market===s.market);if(!projection)continue;probabilities=propChance(projection,s);}
    const {win,push}=probabilities;
    const blocked=!!projection&&(projection.roleReviewRequired||injury.some(o=>o.playerId===projection.playerId&&['out','doubtful','inactive','injured reserve'].includes(String(o.value?.status).toLowerCase())));
    const same=quotes.filter(other=>JSON.stringify(other.selection)===JSON.stringify(s));
    const best=Math.max(...same.map(other=>other.decimal));
    rows.push({id:quoteId(q),selection:s,bookId:q.bookId,book:q.book,decimal:q.decimal,sourceAt:q.sourceAt,collectedAt:q.collectedAt,...probabilities,
      baseline:paired?.chance??null,minimumDecimal:win>0?(1-push)/win:null,conditionalEv:win*q.decimal-(1-push),priceStatus:fresh(q.sourceAt,now,120000)&&fresh(q.collectedAt,now,120000)?'recent_observation':'saved_snapshot',
      bestObservedPrice:q.decimal===best,blocked,reason:blocked?(projection.contextWarnings[0]||'Reported availability concern; check the original source before using this projection.'):null,contextWarnings:projection?.contextWarnings||[],
      playerId:projection?.playerId||null,threeWay:paired?.threeWay||false,forecastBasis:projection?'experimental_workload_rate':distribution.basis,modelValidated:false,hasEdge:false,rulesVerified:false});
  }
  rows.sort((a,b)=>Number(a.blocked)-Number(b.blocked)||Number(b.bestObservedPrice)-Number(a.bestObservedPrice)||b.conditionalEv-a.conditionalEv);
  const sample=distribution.sample,homeChance=summarize(sample,{market:'h2h',outcome:event.home},event);
  const categories=['spreads','totals','h2h','props'].map(market=>({market,label:{spreads:'Spread',totals:'Game total',h2h:'Moneyline',props:'Player props'}[market],rows:rows.filter(r=>market==='props'?PROP_KEYS[r.selection.market]:r.selection.market===market),status:rows.some(r=>market==='props'?PROP_KEYS[r.selection.market]:r.selection.market===market)?'priced_research':'prices_unavailable'}));
  const score={home:sample.reduce((a,r)=>a+r[0]*r[2],0),away:sample.reduce((a,r)=>a+r[1]*r[2],0),homeWin:homeChance.win,tie:homeChance.push,
    marginMedian:percentile(sample,r=>r[0]-r[1],.5),totalMedian:percentile(sample,r=>r[0]+r[1],.5),marginRange:[percentile(sample,r=>r[0]-r[1],.1),percentile(sample,r=>r[0]-r[1],.9)],totalRange:[percentile(sample,r=>r[0]+r[1],.1),percentile(sample,r=>r[0]+r[1],.9)]};
  const report={schemaVersion:1,version:GAME_VERSION,event,createdAt:new Date(now).toISOString(),cutoff:model.cutoff,modelVersion:model.version+'/'+GAME_VERSION,basis:distribution.basis,score,independentScore:distribution.independentScore,
    baselineHomeWin:source.index.scoreModel.baselineHomeWin??null,bookId,books:[...new Map(quotes.map(q=>[q.bookId,{id:q.bookId,name:q.book}])).values()],marketAsOf:quotes.filter(q=>GAME_MARKETS.has(q.selection.market)).map(q=>q.sourceAt).sort()[0]||null,availability:injury,weather:live?.observations.filter(o=>o.eventId===event.id&&o.kind==='weather')||[],categories:categories.map(c=>({...c,totalRows:c.rows.length,rows:c.rows.slice(0,150)})),projections:projections.slice(0,60),ranked:rows.filter(r=>!r.blocked).slice(0,12),validation:model.validation,legacyAudit:model.legacyAudit,hasEdge:false,recommendationsReady:false,
    summary:rows.length?'Game forecasts and exact-price comparisons are available. These are research estimates; no validated betting edge has been established.':'The score outlook and player workload projections are available. Current sportsbook prices are missing for this game, so I cannot identify a priced betting opportunity.',
    limits:['The score-only candidate did not beat historical market baselines; pricing stays market-anchored when two-sided quotes exist.','All displayed prices are observations, not guaranteed obtainable offers. Settlement rules are unverified.','Player projections condition on recorded appearances and do not establish availability. Opponent/role-change adjustments are not validated.','The score model is not a possession simulator; key-number and tail calibration remain unproven.'],
    sourceFingerprint:JSON.stringify([model.version,model.cutoff,event.id,...quotes.map(q=>[quoteId(q),q.sourceAt,q.decimal])])};
  report.workloadTrial=workloadForecasts(source,event,{now,context});
  report.productionTrial=includeProduction?productionForecasts(source,event,{now,workloadTrial:report.workloadTrial,observations:rows}):{available:false,forecasts:[],rows:[],hasEdge:false};
  report.priceCoverage={checkedAt:report.createdAt,provider:'The Odds API',mode:'limited_saved_snapshots',markets:categories.map(c=>({market:c.market,quotes:c.rows.length,books:[...new Set(c.rows.map(r=>r.book))],newestAt:c.rows.map(r=>r.sourceAt).sort().at(-1)||null,oldestAt:c.rows.map(r=>r.sourceAt).sort()[0]||null})),notice:'Only listed exact selections are covered. Saved prices are not live or guaranteed available.'};
  report.comparison=compareResearch(report);
  report.context=context;report.decision=decisionBrief(report,context,{question});return report;
}
