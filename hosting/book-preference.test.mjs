import test from 'node:test';
import assert from 'node:assert/strict';
import {requestedBookIds,requestedBook,bookIds} from './book-preference.mjs';
import {validatePlan} from './worker.mjs';
test('all books clears a previous preference and named books form the exact requested set',()=>{
 const previous={bookId:'betmgm'};
 assert.equal(requestedBookIds('Compare all books',previous),null);
 assert.deepEqual(requestedBookIds('Compare DraftKings and FanDuel',previous),['draftkings','fanduel']);
 assert.equal(requestedBook('Compare DraftKings and FanDuel',previous),null);
 assert.deepEqual(requestedBookIds('Why?',{bookIds:['fanduel','draftkings']}),['draftkings','fanduel']);
 assert.deepEqual(requestedBookIds('At Caesars?',{bookIds:['fanduel','draftkings']}),['williamhill_us']);
 assert.equal(requestedBookIds('Why?',{bookIds:null,bookId:'betmgm'}),null);
 for(const value of [['made_up'],['fanduel','fanduel'],[], 'fanduel'])assert.throws(()=>bookIds(value));
});
test('a planner cannot change or drop an explicit book set',()=>{
 const index={events:[],players:[]};
 assert.throws(()=>validatePlan({tool:'market_status',query:'Compare FanDuel'},'Compare DraftKings and FanDuel',index,{}),/selected books/);
 assert.throws(()=>validatePlan({tool:'market_status',query:'Compare prices'},'Compare all books',index,{bookId:'betmgm'}),/selected books/);
});
