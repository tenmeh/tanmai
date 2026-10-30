// Unit checks for shared board callbacks with a small DOM double, not a browser.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const chess = {exports:{}};
vm.runInNewContext(fs.readFileSync(path.join(root,'inst/js/chess.js'),'utf8'), {module:chess,exports:chess.exports});
const Chess = chess.exports.Chess;
const handlers = {}, states = [], timeouts = [], configs = {};
let reduced = false, animationCount = 0;
function classes(host=false) {
  const values = new Set();
  return {add(...xs) {xs.forEach(x=>{values.add(x);if(host && x==='cv-checkmate') animationCount++;});},
    remove(...xs) {xs.forEach(x=>values.delete(x));}, contains:x=>values.has(x)};
}
const cells = {};
for (const f of 'abcdefgh') for (let r=1;r<=8;r++) cells[f+r] = {
  classList:classes(), getAttribute:name=>name==='data-square'?f+r:null
};
const host = {clientWidth:400, classList:classes(true), attrs:{}, children:[],
  querySelector(sel) {const m=sel.match(/data-square="([a-h][1-8])"/);return m?cells[m[1]]:null;},
  querySelectorAll(sel) {return Object.values(cells).filter(c=>sel==='[data-square]' || sel.split(',').some(x=>c.classList.contains(x.trim().slice(1))));},
  setAttribute(k,v) {this.attrs[k]=v;}, addEventListener(){}, appendChild(x){this.children.push(x);},
  getBoundingClientRect:()=>({top:0,bottom:400})};
const document = {getElementById:()=>host, addEventListener(){},
  createElement:()=>({setAttribute(){},textContent:''})};
const window = {ChessCtor:Chess, innerHeight:800, addEventListener(){},
  matchMedia:()=>({matches:reduced}),
  Chessboard:(id,config)=>{configs[id]=config;let orientation='white';return {
    position(){}, resize(){}, flip(){orientation=orientation==='white'?'black':'white';},
    orientation(value){if(value)orientation=value;return orientation;}
  };}};
const context = {window,document,Shiny:{addCustomMessageHandler:(k,v)=>handlers[k]=v,
  setInputValue:(k,v)=>states.push(v)},setInterval:()=>1,clearInterval(){},
  setTimeout:fn=>{timeouts.push(fn);return timeouts.length;},clearTimeout(){},
  ResizeObserver:class {constructor(fn){this.fn=fn;}observe(){this.fn();}}};
vm.runInNewContext(fs.readFileSync(path.join(root,'inst/app/www/board.js'),'utf8'),context);
handlers['tanmai-board-create']({container:'test',stateInput:'state',fen:new Chess().fen()});
const config=configs.test, set=(msg)=>handlers['tanmai-board-set']({container:'test',...msg});
const state=()=>states.at(-1);
config.onDragStart('e2','wP'); config.onDrop('e2','e2');
assert.equal(cells.e2.classList.contains('cv-sq-selected'),true);
config.onDragStart('e2','wP'); config.onDrop('e2','e2');
assert.equal(cells.e2.classList.contains('cv-sq-selected'),false);
assert.equal(config.onDragStart('e2','wP'),true);
assert.equal(cells.e3.classList.contains('cv-sq-target'),true);
assert.equal(cells.e4.classList.contains('cv-sq-target'),true);
assert.equal(cells.e5.classList.contains('cv-sq-target'),false);
config.onDrop('e2','e4');config.onSnapEnd();
assert.equal(state().last_uci,'e2e4');
assert.equal(cells.e4.classList.contains('cv-sq-last'),true);
assert.equal(Object.values(cells).some(c=>c.classList.contains('cv-sq-target')),false);
set({fen:'7k/8/8/8/8/p7/8/R6K w - - 0 1'});
config.onDragStart('a1','wR');
assert.equal(cells.a3.classList.contains('cv-sq-capture'),true);
assert.equal(cells.a3.classList.contains('cv-sq-target'),false);
handlers['tanmai-board-flip']({container:'test'});
assert.equal(cells.a3.classList.contains('cv-sq-capture'),false);
set({fen:'k3r3/8/8/8/8/8/8/4K3 w - - 0 1'});
assert.equal(cells.e1.classList.contains('cv-sq-check'),true);
handlers['tanmai-board-flip']({container:'test'});
assert.equal(cells.e1.classList.contains('cv-sq-check'),true);
const game=new Chess();game.loadPgn('1. e4 e5 2. Nf3 Nc6');
set({fen:game.fen(),pgn:game.pgn(),orientation:'black'});
assert.equal(state().plies,4);
handlers['tanmai-board-nav']({container:'test',to:'back'});
assert.equal(state().ply,3);
game.undo();assert.equal(state().fen,game.fen());
handlers['tanmai-board-nav']({container:'test',to:'last'});
assert.equal(state().plies,4);
const mate='7k/8/6K1/6Q1/8/8/8/8 w - - 0 1';
set({fen:mate});handlers['tanmai-board-move']({container:'test',uci:'g5d8'});
assert.equal(state().checkmate,true);assert.equal(animationCount,1);
assert.equal(cells.h8.classList.contains('cv-sq-check'),true);
handlers['tanmai-board-sync']({container:'test'});
assert.equal(animationCount,1);
handlers['tanmai-board-nav']({container:'test',to:'first'});
assert.equal(Object.values(cells).some(c=>c.classList.contains('cv-sq-check')),false);
handlers['tanmai-board-nav']({container:'test',to:'last'});
assert.equal(animationCount,1);
reduced=true;set({fen:mate});handlers['tanmai-board-move']({container:'test',uci:'g5d8'});
assert.equal(state().checkmate,true);assert.equal(animationCount,1);
set({fen:'7k/5Q2/6K1/8/8/8/8/8 b - - 0 1'});
assert.equal(state().game_over,true);assert.equal(state().checkmate,false);
assert.equal(host.classList.contains('cv-checkmate'),false);
console.log('Shared board callbacks passed: drag/capture/clear, check/flip, PGN replay, mate once, reduced motion, stalemate.');
