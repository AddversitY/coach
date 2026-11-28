export function spreadHandicap(question){
 const q=question.replace(/\b20\d{2}-\d{2}-\d{2}\b/g,'');
 const direct=q.match(/(?:spread|line|cover)\s*(?:at\s*)?([+-]?\d+(?:\.\d+)?)/i)?.[1];
 const signed=(q.match(/[+-]\d+(?:\.\d+)?/g)||[]).find(n=>Math.abs(Number(n))<100);
 const value=direct!=null&&Math.abs(Number(direct))<100?direct:signed;
 return value==null?null:Number(value);
}

/* "over/under" and "o/u" name a total. They are not a chosen Under. */
export function questionWithoutTotalPhrase(question){
 return String(question||'').replace(/\bover[\s./-]*under\b|\bo\/u\b/gi,' ');
}
export function explicitTotalSide(question){
 const side=questionWithoutTotalPhrase(question).match(/\b(over|under)\s+(-?\d+(?:\.\d+)?)/i);
 return side?{word:side[1].toLowerCase(),point:Number(side[2])}:null;
}
export function namedTotalLine(question){
 const side=explicitTotalSide(question);
 if(side&&side.point>=0&&side.point<100)return side.point;
 const phrase=String(question||'').match(/\b(?:over[\s./-]*under|o\/u)\s+(-?\d+(?:\.\d+)?)/i);
 const point=phrase?Number(phrase[1]):null;
 return point!=null&&point>=0&&point<100?point:null;
}

export function requestedMarket(question,{hasPlayer=false,hasTeam=false}={}){
 const q=question.toLowerCase();
 if(/\bmoney\s*lines?\b|\bml\b|win outright|\bto win\b(?!\s+by\b)/.test(q))return 'h2h';
 if(/\bspreads?\b|\bcover\b/.test(q))return 'spreads';
 if(/\breceiving\b|\brec\.?\s+(?:yards?|yds?)\b/.test(q))return 'player_reception_yds';
 if(/\breceptions\b/.test(q))return 'player_receptions';
 if(/\bpassing\b|\bpass\s+(?:yards?|yds?)\b/.test(q))return 'player_pass_yds';
 if(/\brushing\b|\brush\s+(?:yards?|yds?)\b/.test(q))return 'player_rush_yds';
 if(!hasPlayer&&/\btotals?\b|\bover.?under\b|\bo\/u\b/.test(q))return 'totals';
 const side=/\b(?:over|under)\b/.test(questionWithoutTotalPhrase(q));
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
