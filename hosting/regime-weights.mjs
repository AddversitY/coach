export function regimeWeights(contexts,means){
 const n=contexts.length;if(n<120||!contexts.every(c=>Array.isArray(c)&&c.length===2&&c.every(Number.isFinite)))return null;
 const total=means[0]+means[1],margin=Math.abs(means[0]-means[1]);
 const log=contexts.map(c=>-.5*(((c[0]-total)/10)**2+((c[1]-margin)/7)**2)),maximum=Math.max(...log);
 const kernel=log.map(v=>Math.exp(v-maximum)),sum=kernel.reduce((a,b)=>a+b,0),weights=kernel.map(v=>.5/n+.5*v/sum);
 if(1/weights.reduce((a,v)=>a+v*v,0)<120)return contexts.map(()=>1/n);
 return weights;
}
