export function spreadHandicap(question){
 const q=question.replace(/\b20\d{2}-\d{2}-\d{2}\b/g,'');
 const direct=q.match(/(?:spread|line|cover)\s*(?:at\s*)?([+-]?\d+(?:\.\d+)?)/i)?.[1];
 const signed=(q.match(/[+-]\d+(?:\.\d+)?/g)||[]).find(n=>Math.abs(Number(n))<100);
 const value=direct!=null&&Math.abs(Number(direct))<100?direct:signed;
 return value==null?null:Number(value);
}
