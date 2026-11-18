export const BOOKS={draftkings:'DraftKings',fanduel:'FanDuel',betmgm:'BetMGM',williamhill_us:'Caesars',espnbet:'ESPN BET',fanatics:'Fanatics',betrivers:'BetRivers',hardrockbet:'Hard Rock Bet',ballybet:'Bally Bet',fliff:'Fliff'};
const normalize=s=>String(s||'').toLowerCase().replace(/[^a-z0-9 ]/g,'').replace(/\s+/g,' ').trim();
const allBooks=q=>/\b(?:all|every|any)\s+(?:sportsbooks?|books?|prices)\b|\bacross books\b|\bcompare books\b/i.test(q);
export function bookIds(value){
 if(value==null)return null;
 if(!Array.isArray(value)||!value.length||value.length>10||value.some(id=>typeof id!=='string'||!Object.hasOwn(BOOKS,id))||new Set(value).size!==value.length)throw new Error('Invalid book preference');
 return [...value].sort();
}
export function requestedBookIds(question,context={}){
 if(allBooks(question))return null;
 const q=' '+normalize(question)+' ',matched=Object.entries(BOOKS).filter(([,name])=>q.includes(' '+normalize(name)+' ')).map(([id])=>id);
 if(matched.length)return bookIds(matched);
 if(Object.hasOwn(context,'bookIds'))return bookIds(context.bookIds);
 return typeof context.bookId==='string'?bookIds([context.bookId]):null;
}
export function requestedBook(question,context={}){const ids=requestedBookIds(question,context);return ids?.length===1?ids[0]:null;}
