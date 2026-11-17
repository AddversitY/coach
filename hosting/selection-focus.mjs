export function spreadHandicap(question){
 const q=question.replace(/\b20\d{2}-\d{2}-\d{2}\b/g,'');
 const direct=q.match(/(?:spread|line|cover)\s*(?:at\s*)?([+-]?\d+(?:\.\d+)?)/i)?.[1];
 const signed=(q.match(/[+-]\d+(?:\.\d+)?/g)||[]).find(n=>Math.abs(Number(n))<100);
 const value=direct!=null&&Math.abs(Number(direct))<100?direct:signed;
 return value==null?null:Number(value);
}

export function requestedMarket(question,{hasPlayer=false,hasTeam=false}={}){
 const q=question.toLowerCase();
 if(/\bmoneyline\b|\bml\b|win outright/.test(q))return 'h2h';
 if(/\bspreads?\b|\bcover\b/.test(q))return 'spreads';
 if(/\breceiving\b|\brec\.?\s+(?:yards?|yds?)\b/.test(q))return 'player_reception_yds';
 if(/\breceptions\b/.test(q))return 'player_receptions';
 if(/\bpassing\b|\bpass\s+(?:yards?|yds?)\b/.test(q))return 'player_pass_yds';
 if(/\brushing\b|\brush\s+(?:yards?|yds?)\b/.test(q))return 'player_rush_yds';
 if(/\btotals?\b|over.?under/.test(q))return 'totals';
 const side=/\b(?:over|under)\s+-?\d/.test(q);
 if(!hasPlayer&&side)return 'totals';
 if(hasTeam&&!hasPlayer&&!side&&spreadHandicap(question)!==null)return 'spreads';
 return null;
}

export function unsupportedScope(question){
 if(/\bregulation[- ](?:only|time)\b|\b(?:excluding|without|no)\s+(?:overtime|ot)\b/i.test(question))return 'settlement_rules';
 if(/\bteam\s*totals?\b/i.test(question))return 'team_total';
 if(/\b(?:(?:first|second|third|fourth|1st|2nd|3rd|4th)[-\s]*(?:half|quarter)|[12]h|[1-4]q|[1-4]\s*(?:half|quarter)|half[- ]time)\b/i.test(question))return 'partial_game';
 if(/\blive\s+(?:bet|odds|line|spread|total|prop|moneyline)s?\b|\bin[- ]play\b/i.test(question))return 'in_play';
 return null;
}
