#!/usr/bin/env node
// The Hoard's treasures. Edit a drawing, then run: node design/hoard/draw.js
//
// Each treasure is drawn on a 24 x 26 pixel grid: the object in rows 0 to 19, standing on a plinth in rows 21 to 24.
// Fills are drawn without edges and outline() rings every shape in ink, so only interior lines are drawn by hand.
// d.f() draws glow (flames, sparks, runes) that stays unoutlined. The palette is sampled from the goblin sprites.
// Writes Sources/GoblinApp/Assets/hoard/<id>.png at 1x; the app scales them by whole numbers.
// Ids, names, lines and plinths come from Sources/GoblinCore/Hoard.swift; keep each shelf here in the same order.
'use strict';
const fs = require('fs'), path = require('path'), zlib = require('zlib');

// ---------- palette (from the goblin sprites) ----------
const O='#061412', K0='#0d0810', K1='#211b2e', K2='#3a3150', K3='#4c4366';
const g1='#ee8000', g2='#ffb713', g3='#ffe86e', g4='#fff7d3';
const p1='#b99356', p2='#e9d19c', p3='#fff7d3';
const e0='#184b2e', e1='#326c36', e2='#5d9f3d', e3='#a2dc55', e4='#dff8a1', ne='#57e68f';
const w0='#3b2217', w1='#5e3a24', w2='#8a5a36', w3='#b9834f';
const s0='#2e353d', s1='#55606b', s2='#8794a0', s3='#bfcad2', s4='#eef3f5', WH='#ffffff';
const c0='#5a2412', c1='#94431f', c2='#cf6f38', c3='#f2a56c';
const r0='#5c1424', r1='#a32639', r2='#e04f5f', r3='#ff9a9a';
const b0='#15284f', b1='#24509a', b2='#3f8ad6', b3='#9fd3f7';
const v0='#25184a', v1='#4b3394', v2='#7d62d6', v3='#c3b4f7';
const gl='#cfeaf2', glh='#f4fcfe';

const MATS = {
  wood:{name:'Wood', c:[w0,w1,w2,w3]}, tin:{name:'Tin', c:[s1,s2,s3,s4]}, copper:{name:'Copper', c:[c0,c1,c2,c3]},
  silver:{name:'Silver', c:[s2,s3,s4,WH]}, gold:{name:'Gold', c:[g1,g2,g3,g4]}, emerald:{name:'Emerald', c:[e0,e1,ne,e4]},
  goblinite:{name:'Goblinite', c:[K0,K1,K2,ne]}, amethyst:{name:'Amethyst', c:[v0,v1,v2,v3]},
};
const LADDER = ['wood','tin','copper','silver','gold','emerald','goblinite'];

// ---------- pixel grid ----------
const W=24, H=26;
const FONT = {
  X:['101','101','010','101','101'], A:['010','101','111','101','101'],
  Q:['010','101','101','110','011'], W:['101','101','111','111','101'], E:['111','100','110','100','111'],
  R:['110','101','110','101','101'], I:['111','010','010','010','111'], P:['110','101','110','100','100'],
  H:['101','101','111','101','101'], T:['111','010','010','010','010'], Y:['101','101','010','010','010'],
};
function grid() {
  const a = new Array(W*H).fill(null), fx = new Array(W*H).fill(null);
  let clip = 19;
  const d = {
    a, fx,
    unclip(){ clip = 99; },
    p(x,y,c){ x=Math.round(x); y=Math.round(y); if (x>=0&&x<W&&y>=0&&y<H&&y<=clip) a[y*W+x]=c; },
    f(x,y,c){ x=Math.round(x); y=Math.round(y); if (x>=0&&x<W&&y>=0&&y<H) fx[y*W+x]=c; },
    r(x,y,w,h,c){ for(let j=0;j<h;j++) for(let i=0;i<w;i++) d.p(x+i,y+j,c); },
    h(x,y,n,c){ d.r(x,y,n,1,c); }, v(x,y,n,c){ d.r(x,y,1,n,c); },
    box(x,y,w,h,c){ d.r(x,y,w,h,O); d.r(x+1,y+1,w-2,h-2,c); },
    e(cx,cy,rx,ry,c,yMin=-99,yMax=99){ for(let y=0;y<H;y++) for(let x=0;x<W;x++){ const dx=(x-cx)/(rx+.5), dy=(y-cy)/(ry+.5); if(dx*dx+dy*dy<=1 && y>=yMin && y<=yMax) d.p(x,y,c); } },
    ef(cx,cy,rx,ry,c){ for(let y=0;y<H;y++) for(let x=0;x<W;x++){ const dx=(x-cx)/(rx+.5), dy=(y-cy)/(ry+.5); if(dx*dx+dy*dy<=1) d.f(x,y,c); } },
    l(x0,y0,x1,y1,c,fxl){ const n=Math.max(Math.abs(x1-x0),Math.abs(y1-y0))||1; for(let i=0;i<=n;i++){ const x=x0+(x1-x0)*i/n, y=y0+(y1-y0)*i/n; fxl? d.f(x,y,c) : d.p(x,y,c); } },
    row(cx,y,hw,c){ for(let x=Math.ceil(cx-hw-1e-9); x<=Math.floor(cx+hw+1e-9); x++) d.p(x,y,c); },
    map(x,y,rows,pal,asFx){ rows.forEach((row,j)=>[...row].forEach((ch,i)=>{ if(ch!=='.' && pal[ch]!==undefined) (asFx?d.f:d.p)(x+i,y+j,pal[ch]); })); },
    spark(x,y,c=g3,hi=g4){ d.f(x,y,hi); d.f(x-1,y,c); d.f(x+1,y,c); d.f(x,y-1,c); d.f(x,y+1,c); },
    twinkle(x,y,c=g4){ d.f(x,y,c); },
    txt2(x,y,ch,c){ (FONT[ch]||[]).forEach((row,j)=>[...row].forEach((b,i)=>{ if(b==='1') d.r(x+i*2,y+j*2,2,2,c); })); },
    txt(x,y,s,c){ [...s].forEach((ch,k)=>{ const gl=FONT[ch]; if(!gl) return; gl.forEach((row,j)=>[...row].forEach((b,i)=>{ if(b==='1') d.p(x+k*4+i,y+j,c); })); }); },
  };
  return d;
}
function outline(d) {
  const src = d.a.slice();
  for (let y=0;y<H;y++) for (let x=0;x<W;x++) {
    if (src[y*W+x]) continue;
    const n = [[1,0],[-1,0],[0,1],[0,-1]].some(([dx,dy])=>{ const X=x+dx, Y=y+dy; if(X<0||X>=W||Y<0||Y>=H) return false; const c=src[Y*W+X]; return c && c!==O; });
    if (n) d.a[y*W+x] = O;
  }
  // A fill on the canvas edge has no room for its ring outside, so its edge pixel becomes the ring.
  for (let y=0;y<H;y++) for (let x=0;x<W;x++) {
    const c = d.a[y*W+x];
    if (c && c!==O && (x===0 || x===W-1 || y===0)) d.a[y*W+x] = O;
  }
}
function plinth(d, m) {
  const [m0,m1,m2,m3] = MATS[m].c;
  d.r(4,21,16,1,m2); d.h(5,21,14,m3);
  d.r(5,22,14,2,m1); d.r(10,22,4,1,m3); d.h(5,23,14,m0===K0?K1:m1);
  d.r(3,24,18,1,m0);
}

// ---------- shared pieces ----------
function coin(d,cx,cy,r,pal=[g1,g2,g3,g4]) {
  d.e(cx,cy,r,r,O); d.e(cx,cy,r-1,r-1,pal[1]);
  if (r>=3) d.e(cx,cy,r-2,r-2,pal[2]);
  if (r>=4) { d.e(cx,cy,r-3,r-3,pal[1]); d.v(cx,cy-1,3,pal[0]); }
  if (r>=3) d.p(cx-r+2,cy-r+2,pal[3]);
}
function stack(d,x,bottom,n,w=7) {
  for (let i=0;i<n;i++){ const y=bottom-1-2*i; d.h(x,y,w,g2); d.h(x,y+1,w,g1); d.p(x+1,y,g3); d.p(x+w-2,y+1,g2); }
  d.h(x+1,bottom-2*n,w-2,g3);
}
function flame(d,cx,wy) {
  d.f(cx,wy-4,g3); d.f(cx-1,wy-3,g3); d.f(cx,wy-3,g2); d.f(cx+1,wy-3,g3);
  d.f(cx-1,wy-2,g2); d.f(cx,wy-2,g1); d.f(cx+1,wy-2,g2); d.f(cx,wy-1,g2);
}
function candle(d,x,top,base,w=3,col=p3,shade=p2) {
  d.r(x,top,w,base-top+1,col); d.v(x+w-1,top,base-top+1,shade);
  if (base-top>2) d.p(x,top+1,shade);
  const cx = x+Math.floor(w/2); d.p(cx,top-1,O); flame(d,cx,top-1);
}
function keycap(d,x,y,w,h,letter,top=s4,body=s3) {
  d.box(x,y,w,h,body); d.r(x+1,y+1,w-2,h-3,top);
  if (letter) d.txt(x+Math.floor((w-3)/2),y+1+Math.max(0,Math.floor((h-3-5)/2)),letter,s1);
}
function mush(d,cx,base,stemH,rx,ry,col,gill,spots=[],stem=p3,stemShade=p2) {
  const top = base-stemH+1, sw = Math.max(1,Math.floor(rx/3));
  d.r(cx-sw,top,2*sw+1,stemH,stem); d.v(cx+sw,top,stemH,stemShade);
  for (let y=top-ry; y<=top; y++){ const dy=top-y; const hw=rx*Math.sqrt(Math.max(0,1-(dy/(ry+.5))**2)); d.row(cx,y,hw,y===top?gill:col); }
  spots.forEach(([dx,dy,s=1])=>d.r(cx+dx,top-ry+dy,s,s,p3));
}
function feather(d,x0,y0,x1,y1,maxW) {
  const dx=x1-x0, dy=y1-y0, len=Math.hypot(dx,dy), px=-dy/len, py=dx/len;
  for (let i=0;i<=60;i++){ const t=i/60; if(t<.16) continue; const w=maxW*Math.sin(Math.PI*Math.min(1,(t-.16)/.84)); const cx=x0+dx*t, cy=y0+dy*t;
    for (let k=0;k<=w;k+=.5){ d.p(cx+px*k,cy+py*k,p3); d.p(cx-px*k,cy-py*k,p2); } }
  d.l(x0,y0,x1,y1,p1); d.p(x0,y0,O);
}
function goblet(d,x,y,col=g2,shade=g1,hi=g3) { // cup 7 wide at x..x+6, top y
  d.r(x,y,7,2,col); d.r(x+1,y+2,5,1,col); d.r(x+2,y+3,3,1,col); d.h(x,y,7,hi);
  d.v(x+3,y+4,3,shade); d.r(x+1,y+7,5,1,col);
}
function bottleFill(d,cx,cy,rx,ry,glass,liquid,fromY,surf) {
  d.e(cx,cy,rx,ry,glass); d.e(cx,cy,rx,ry,liquid,fromY); if (surf) d.e(cx,cy,rx,ry,surf,fromY,fromY);
}
function face(d,x,y,col) { d.box(x,y,5,5,col); d.p(x,y,null); d.p(x+4,y,null); d.p(x,y+4,null); d.p(x+4,y+4,null); d.p(x+1,y+2,O); d.p(x+3,y+2,O); }

// ---------- the treasures, shelf by shelf, lowest first ----------

const TRACKS = [
 { key:'words', items:[
  [100, d=>{ d.r(5,7,14,7,p3); [[5,7],[18,7],[5,13],[18,13]].forEach(([x,y])=>d.p(x,y,null)); d.h(6,13,12,p2); d.r(7,14,3,1,p3); d.p(7,15,p3); d.p(6,16,p3); d.r(8,9,2,2,p1); d.r(11,9,2,2,p1); d.r(14,9,2,2,p1); d.spark(20,4); }],
  [1000, d=>{ [[2,9],[6,7],[10,5],[14,3]].forEach(([x,y],i)=>{ d.box(x,y,9,11,p3); d.v(x+7,y+1,9,p2); d.h(x+2,y+3,5,p1); d.h(x+2,y+5,5,p1); d.h(x+2,y+7,3,p1); }); d.p(22,3,null); d.p(21,3,O); d.p(22,4,O); }],
  [5000, d=>{ d.r(6,5,12,11,p3); d.v(16,5,11,p2); [7,9,11,13].forEach((y,i)=>d.h(8,y,[7,8,6,7][i],p1)); d.box(5,2,14,3,p2); d.h(6,3,12,p3); d.r(3,2,2,3,w1); d.r(19,2,2,3,w1); d.box(5,16,14,3,p2); d.h(6,17,12,p3); d.r(3,16,2,3,w1); d.r(19,16,2,3,w1); d.r(15,19,2,1,r1); }],
  [10000, d=>{ d.r(2,8,20,9,p3); d.p(2,8,null); d.p(21,8,null); d.r(11,8,2,2,null); d.v(11,10,7,p2); d.v(12,10,7,p2); [[4,11,6],[4,13,6],[4,15,4],[14,11,6],[14,13,6],[14,15,5]].forEach(([x,y,n])=>d.h(x,y,n,p1)); d.r(1,17,22,3,r1); d.h(1,19,22,r0); d.v(17,8,5,r2); d.p(17,13,null); }],
  [25000, d=>{ d.box(6,3,12,17,b1); d.v(7,4,15,b0); d.v(16,4,15,b2); d.box(9,6,7,4,g2); d.h(10,7,5,g3); d.p(12,13,g2); d.p(11,14,g2); d.p(13,14,g2); d.p(12,15,g2); d.v(14,1,2,r2); }],
  [50000, d=>{ d.box(2,13,20,7,r1); d.r(3,15,18,3,p3); d.h(3,16,18,p2); d.h(3,18,18,r0); d.v(21,14,5,r0); feather(d,13,12,20,1,2.6); d.f(12,13,b2); }],
  [100000, d=>{ d.box(3,2,18,18,w1); d.h(4,3,16,w2); d.v(4,3,16,w2); [[4,3,1,1],[19,3,-1,1],[4,18,1,-1],[19,18,-1,-1]].forEach(([x,y,sx,sy])=>{ d.p(x,y,g2); d.p(x+sx,y,g2); d.p(x+2*sx,y,g2); d.p(x,y+sy,g2); d.p(x,y+2*sy,g2); }); d.e(12,10,3,3,g1); d.e(12,10,2,2,K1); d.v(12,8,5,ne); d.r(20,9,2,3,g2); d.p(22,10,g1); }],
  [250000, d=>{ d.r(1,8,3,12,s2); d.v(1,8,12,s3); d.r(20,8,3,12,s2); d.v(22,8,12,s1); [[4,4,r1,1],[9,2,b1,2],[14,5,e1,3]].forEach(([x,y,c,n])=>{ d.box(x,y,6,20-y,c); d.h(x+1,y+2,4,g2); d.h(x+1,16,4,g2); for(let k=0;k<n;k++) d.p(x+3,y+5+k*2,g3); }); }],
  [500000, d=>{ [[2,16,20,r1],[4,13,17,b1],[3,10,16,e1],[6,7,14,v1]].forEach(([x,y,w,c])=>{ d.box(x,y,w,4,c); d.r(x+w-4,y+1,2,2,p3); d.h(x+2,y+1,3,g2); }); candle(d,11,5,6); }],
  [1000000, d=>{ d.box(4,8,15,12,g2); d.v(5,9,10,g1); d.h(5,18,13,g1); d.r(19,9,2,10,p3); d.v(20,9,10,p2); d.h(19,8,2,O); d.h(19,19,2,O); d.p(21,9,O); d.p(21,18,O); d.v(21,10,8,O); d.v(9,11,2,O); d.e(14,12,2,2,O); d.r(13,11,3,3,b3); d.p(13,11,WH); d.l(16,14,17,17,g1); d.h(9,15,6,O); d.p(8,14,O); d.p(15,14,O); d.r(7,1,10,5,K1); d.v(8,1,4,K2); d.h(7,4,10,r1); d.r(4,6,16,2,K1); d.h(4,6,16,K2); d.spark(22,3); d.twinkle(2,11); }],
  [2500000, d=>{ for(let x=1;x<=10;x++){ const top=Math.round(4+(x-1)*.45), bot=Math.round(9+(x-1)*.4)+[2,1,0][(x-1)%3]; for(let y=top;y<=bot;y++){ d.p(x,y,e1); d.p(23-x,y,e1); } d.p(x,top,e2); d.p(23-x,top,e2); } [[1,11],[4,12],[7,13]].forEach(([x,y])=>{ d.l(10,8,x,y,e0); d.l(13,8,23-x,y,e0); }); d.r(10,6,4,8,K1); d.p(10,5,K1); d.p(13,5,K1); d.v(11,7,6,K2); d.p(10,9,g3); d.p(11,10,g3); d.p(13,9,g3); d.p(12,10,g3); d.r(10,14,1,2,s1); d.r(13,14,1,2,s1); [[10,16,e4],[10,17,ne],[10,18,e2],[13,16,e4],[13,17,ne],[13,18,e2],[9,17,ne],[14,17,ne]].forEach(([x,y,c])=>d.f(x,y,c)); d.spark(3,1,ne,e4); d.twinkle(20,1,e4); }],
  [5000000, d=>{ for(let x=1;x<=5;x++){ const top=Math.round(2+(x-1)*1.2), bot=Math.round(9+(x-1)*1.1)+[3,0,2,0,1][x-1]; for(let y=top;y<=bot;y++){ d.p(x,y,v1); d.p(23-x,y,v1); } d.p(x,top,v2); d.p(23-x,top,v2); d.p(x,top+1,v2); d.p(23-x,top+1,v2); } [[1,12],[3,13]].forEach(([x,y])=>{ d.l(6,8,x,y,v0); d.l(17,8,23-x,y,v0); }); d.r(6,7,12,7,p3); d.r(6,6,3,1,p3); d.r(15,6,3,1,p3); d.p(11,7,null); d.p(12,7,null); d.v(11,8,6,p2); d.v(12,8,6,p2); [[7,8],[9,8],[8,9],[10,10],[7,11],[9,12],[14,8],[16,8],[15,9],[13,10],[16,11],[14,12]].forEach(([x,y])=>d.p(x,y,ne)); d.r(5,14,14,2,K1); d.h(5,14,14,K2); d.r(4,14,1,2,g2); d.r(19,14,1,2,g2); d.r(10,14,4,2,g2); d.v(11,14,2,K0); d.v(12,14,2,ne); d.v(15,16,3,r1); d.p(15,19,r2); d.map(4,0,['.......aa.......','...a...ab....a..','..ab..abba..ab..','..abbbbccbbbba..','.abcccccccccccba','.bcccccccccccccb'],{a:e2,b:ne,c:e4},true); d.f(10,2,g3); d.f(11,2,g3); d.f(12,2,g3); d.f(13,2,g3); for(let x=9;x<=14;x++) d.f(x,3,g3); d.f(10,4,g3); d.f(13,4,g3); [2,3,4].forEach(y=>{ d.f(11,y,K0); d.f(12,y,K0); }); [[1,0],[22,0],[0,16],[23,16],[8,18],[17,18],[11,19]].forEach(([x,y],i)=>d.f(x,y,i%2?e4:ne)); }],
 ]},
 { key:'dictations', items:[
  [1, d=>{ coin(d,12,10,6,[c0,c1,c2,c3]); d.r(10,17,4,1,w1); d.r(8,18,8,2,w1); d.h(9,18,6,w2); d.spark(20,3); }],
  [10, d=>{ stack(d,8,19,4,8); d.twinkle(17,9); }],
  [50, d=>{ stack(d,2,19,5,7); stack(d,10,19,3,7); coin(d,18,15,4); }],
  [100, d=>{ d.e(12,14,7,5,w2); d.e(9,12,2,1,w3); d.r(10,7,5,2,w1); d.h(10,8,5,r1); d.p(15,9,r1); d.p(16,10,r1); d.r(8,5,9,2,w2); d.e(12,15,2,2,g2); d.p(12,15,g1); coin(d,12,3,2); }],
  [250, d=>{ d.e(7,14,6,5,w2); d.e(5,12,2,1,w3); d.r(13,12,2,5,w1); d.v(14,12,5,O); coin(d,17,17,2); coin(d,20,15,2); coin(d,17,11,2); stack(d,19,19,1,4); d.spark(21,9); }],
  [500, d=>{ d.e(12,12,9,7,p1); [[7,9],[9,8],[6,12],[16,8],[18,11]].forEach(([x,y])=>d.p(x,y,p2)); d.e(14,16,6,2,p1); d.h(6,18,12,w3); d.r(10,3,5,3,p1); d.h(9,5,7,w1); d.r(8,1,9,2,p1); d.e(12,13,3,3,w1); d.e(12,13,2,2,p1); d.r(14,12,2,1,p1); d.v(12,9,9,w1); }],
  [1000, d=>{ d.box(2,10,20,10,w2); d.box(2,4,20,7,w2); d.p(2,4,null); d.p(21,4,null); d.h(3,5,18,w3); d.h(3,7,18,w1); d.h(3,14,18,w1); d.v(6,5,14,s1); d.v(17,5,14,s1); [[6,12],[17,12],[6,17],[17,17]].forEach(([x,y])=>d.p(x,y,s3)); d.box(10,8,5,5,g2); d.v(12,10,2,O); }],
  [2500, d=>{ d.box(3,1,18,7,w1); d.r(4,2,16,5,w0); d.v(6,1,7,s1); d.v(17,1,7,s1); d.e(12,10,9,3,g2); [[6,9],[9,8],[13,8],[17,9],[11,10]].forEach(([x,y])=>d.p(x,y,g3)); d.p(15,9,r2); d.box(2,11,20,9,w2); d.h(3,12,18,w3); d.v(6,12,7,s1); d.v(17,12,7,s1); d.box(10,11,5,4,g2); d.v(12,12,2,O); d.spark(19,4); d.twinkle(8,6); }],
  [5000, d=>{ d.box(3,1,18,6,w1); d.r(4,2,16,4,w0); d.e(12,9,10,4,g2); [[5,8],[8,7],[13,6],[17,8],[11,9],[19,10]].forEach(([x,y])=>d.p(x,y,g3)); d.p(8,6,r2); d.p(14,5,b2); d.p(17,7,ne); d.p(11,8,v2); d.box(2,11,20,9,w2); d.h(3,12,18,w3); d.v(6,12,7,s1); d.v(17,12,7,s1); d.box(10,11,5,4,g2); [[15,12],[16,13],[16,14],[17,15],[18,16]].forEach(([x,y])=>d.p(x,y,p3)); d.p(18,17,r2); coin(d,21,18,1); d.spark(20,2); d.spark(3,4); }],
  [10000, d=>{ d.e(12,20,11,9,g2); [[4,17],[7,14],[10,13],[15,14],[18,16],[12,16],[6,18],[20,18],[9,17],[15,18]].forEach(([x,y],i)=>d.p(x,y,i%2?g3:g1)); goblet(d,9,3); d.p(12,4,r2); d.spark(4,7); d.spark(20,5); }],
  [25000, d=>{ d.e(12,20,11,8,g2); [[4,17],[7,15],[10,13],[15,15],[18,16],[12,17],[20,18]].forEach(([x,y],i)=>d.p(x,y,i%2?g3:g1)); d.r(6,5,2,8,s4); d.v(7,5,8,s3); d.r(3,4,8,1,g2); d.r(6,1,2,3,w1); d.r(6,0,2,1,g2); d.r(13,10,8,3,g2); d.h(13,10,8,g3); d.v(13,7,3,g2); d.v(16,6,4,g2); d.v(17,6,4,g2); d.v(20,7,3,g2); d.p(15,11,r2); d.p(18,11,b2); d.p(9,16,r2); d.p(15,17,b2); d.p(5,18,ne); d.p(18,18,v2); d.spark(21,3); d.spark(11,2); }],
 ]},
 { key:'talk', items:[
  [10, d=>{ d.r(6,18,12,2,c2); d.h(6,18,12,c3); d.h(8,17,8,p2); candle(d,10,13,17); d.r(13,15,1,2,p3); }],
  [30, d=>{ d.r(8,18,8,2,s2); d.h(8,18,8,s3); candle(d,10,5,17); d.p(9,8,p3); d.p(9,9,p3); }],
  [60, d=>{ d.r(4,18,14,2,c2); d.h(4,18,14,c3); d.e(19,16,2,2,c2); d.p(19,16,O); d.r(8,16,5,2,c2); candle(d,9,9,15); }],
  [180, d=>{ d.r(3,18,18,2,w2); d.h(3,18,18,w3); candle(d,5,11,17); candle(d,10,6,17); candle(d,15,9,17); }],
  [600, d=>{ const hw=[4,4,4,3,3,2,1,0,1,2,3,3,4,4]; hw.forEach((w,i)=>{ const y=4+i; d.row(11.5,y,w===0?0.5:w,gl); }); [9,10,11].forEach(y=>d.row(11.5,y-2,hw[y-6]-1.2,g2)); d.p(11,11,g2); d.p(12,13,g2); for(let y=14;y<=17;y++) d.row(11.5,y,Math.min(hw[y-4],y-12),g2); d.p(9,5,glh); d.p(9,6,glh); d.r(5,2,14,2,w2); d.h(5,2,14,w3); d.r(5,18,14,2,w2); d.h(5,18,14,w3); d.v(6,4,14,w1); d.v(17,4,14,w1); }],
  [1440, d=>{ d.e(12,2,2,2,s1); d.p(12,2,O); d.r(9,4,7,2,s1); d.r(8,6,9,1,s1); d.box(8,7,9,10,s1); d.r(9,8,7,8,g3); d.p(12,9,g2); d.p(11,10,g2); d.p(12,10,g1); d.p(13,10,g2); d.p(12,11,g1); d.p(12,12,O); d.r(11,13,3,3,p3); d.v(10,8,8,g4); d.r(7,17,11,2,s1); d.h(7,17,11,s2); d.r(8,19,9,1,s0); }],
  [3000, d=>{ d.r(8,18,8,2,g1); d.h(8,18,8,g2); d.r(10,17,4,1,g1); d.r(11,11,2,6,g2); d.r(2,10,20,2,g2); d.h(2,10,20,g3); [2,6,10,14,18].forEach(x=>{ d.r(x-1,8,5,2,g2); candle(d,x,5,7); }); }],
  [6000, d=>{ d.v(12,0,4,s1); d.p(12,1,s2); d.p(12,3,s2); d.l(12,4,5,9,O); d.l(12,4,19,9,O); d.e(12,10,8,2,g2); d.e(12,10,6,0.6,null); d.h(5,9,15,g3); [5,9,15,19].forEach(x=>candle(d,x-1,6,8,2)); d.r(11,13,3,2,g2); d.p(12,15,r2); }],
  [15000, d=>{ d.l(6,19,9,13,s1); d.l(18,19,15,13,s1); d.v(12,14,6,s1); d.e(12,9,8,4,g2,9); d.h(3,9,19,g3); d.e(12,9,8,4,g1,12); d.map(5,0,['......a......','.....aa......','.....ab..a...','....abb..aa..','...abbba.ab..','..abbcbbabb..','..abccccbbba.','.abbccccccbba','.abccccccccba'],{a:e2,b:ne,c:e4},true); d.f(4,3,ne); d.f(19,1,e4); }],
 ]},
 { key:'saved', items:[
  [1, d=>{ d.r(1,2,22,18,p3); d.v(21,3,16,p2); d.v(22,2,18,p2); d.txt(3,3,'EXTRA',O); d.h(2,9,20,O); d.box(3,11,8,7,s3); d.e(7,15,2,2,e2); d.p(4,13,e2); d.p(5,14,e2); d.p(10,13,e2); d.p(9,14,e2); d.p(6,15,g3); d.p(8,15,g3); d.h(6,17,3,e1); [[12,11,9],[12,13,8],[12,15,9],[12,17,6]].forEach(([x,y,n])=>d.h(x,y,n,s2)); d.h(2,19,20,p2); d.spark(21,1); }],
  [4, d=>{ d.v(12,1,19,w3); d.p(12,0,s3); const cap=(y,top,side,dark)=>{ d.box(7,y,11,5,side); d.r(8,y+1,9,2,top); d.h(8,y+3,9,dark); }; cap(2,p3,p2,p1); d.box(8,7,9,3,e2); d.h(9,8,7,e3); cap(10,r3,r2,r1); d.e(12,16.5,3,1,r1); d.e(12,16.5,2,0.4,r2); d.r(10,19,5,1,w1); d.v(12,14,1,w3); }],
  [8, d=>{ d.r(7,1,10,6,p3); d.h(8,3,7,p1); d.h(8,5,5,p1); d.box(4,6,16,3,s0); d.r(2,6,2,3,s1); d.r(20,6,2,3,s1); d.box(2,9,20,10,K1); d.h(3,10,18,K2); d.h(10,10,4,g2); for(let y of [12,14]) for(let x=(y===12?4:5);x<=19;x+=2) d.p(x,y,s3); d.h(7,16,10,s3); d.p(3,19,K1); d.p(20,19,K1); d.l(22,0,17,0,s4,1); d.l(22,0,22,5,s4,1); d.l(22,0,18,4,s4,1); d.f(19,1,s4); d.f(20,2,s4); d.f(21,3,s4); d.f(21,1,s4); d.f(18,1,s4); d.f(17,5,s4); d.f(17,6,K0); }],
  [24, d=>{ d.r(5,8,14,12,s2); d.e(11.5,8,6.5,5,s2); d.v(17,8,11,s1); d.v(18,8,11,s1); d.v(6,6,12,s3); d.txt(7,7,'RIP',s0); d.h(8,13,8,s1); d.h(9,15,6,s1); d.r(3,18,18,2,e2); [4,7,10,15,19].forEach(x=>d.p(x,17,e3)); d.p(4,16,r2); d.p(19,16,b3); d.p(20,16,b3); }],
  [40, d=>{ const cols=[s3,b3,r3,e3,v3,c3,p2]; let k=0; [[16,[2,5,8,11,14,17]],[13,[4,7,10,13,16]],[10,[6,9,12,15]],[7,[8,11,14]]].forEach(([y,xs])=>xs.forEach(x=>{ const c=cols[k++%cols.length]; d.box(x,y,4,4,c); d.p(x+1,y+1,WH); })); d.box(10,3,5,5,g2); d.p(11,4,g4); d.v(12,4,3,g1); d.spark(19,4); }],
  [100, d=>{ d.r(8,4,3,6,e2); d.h(8,4,3,s3); d.v(8,5,5,e3); d.r(7,9,9,6,e2); d.h(7,9,9,e3); d.p(11,9,O); d.p(13,9,O); d.h(11,11,5,e1); d.h(11,13,5,e1); d.r(4,10,4,2,e2); d.h(4,10,4,e3); d.r(6,15,11,3,v1); d.h(6,15,11,v2); [8,11,14].forEach(x=>d.p(x,16,g2)); d.r(8,18,7,2,v0); [[9,3],[10,2],[11,2],[12,1],[13,1],[14,0],[12,3],[13,3],[14,2],[15,2],[16,1],[17,1],[18,0],[7,2],[6,1],[16,4],[17,5],[19,3]].forEach(([x,y],i)=>d.f(x,y,i%4===3?e4:i%2?ne:g3)); }],
  [250, d=>{ d.box(9,6,6,9,s3); d.r(10,7,4,7,s4); d.r(5,4,14,2,g2); d.h(5,4,14,g3); d.r(11,1,2,3,w1); d.r(10,0,4,1,g2); d.e(12,17,9,4,s2); d.e(14,18,6,2,s1); d.h(6,14,4,s3); d.p(7,15,s3); d.p(5,17,e2); d.p(6,16,e2); d.p(19,16,e2); d.spark(3,1); d.spark(21,2); }],
  [500, d=>{ d.r(3,2,18,12,w2); for(let y=14;y<=17;y++){ const k=y-13; d.h(3+2*k,y,18-4*k,w2); } d.h(4,3,16,w3); d.v(4,3,10,w3); d.box(5,6,14,6,s1); for(let x=6;x<=17;x+=2) d.p(x,7,s3); for(let x=7;x<=16;x+=2) d.p(x,8,s3); d.h(8,10,8,s3); d.box(9,13,6,3,g2); d.p(5,4,g3); d.p(18,4,g3); d.l(7,5,5,1,s2); d.l(16,5,18,1,s2); d.p(4,2,s2); d.p(19,2,s2); }],
  [1000, d=>{ d.r(9,15,6,5,g1); d.v(10,15,5,g2); d.r(8,14,8,1,g2); d.r(10,12,4,2,g1); d.e(11.5,8,5,5,g2); d.r(1,4,2,1,g2); d.r(2,5,4,1,g2); d.r(3,6,4,1,g2); d.r(5,7,2,1,g2); d.r(21,4,2,1,g2); d.r(18,5,4,1,g2); d.r(17,6,4,1,g2); d.r(17,7,2,1,g2); d.v(9,7,2,O); d.v(14,7,2,O); d.h(9,11,6,O); d.p(8,10,O); d.p(15,10,O); d.p(10,11,g4); d.p(13,11,g4); d.p(8,5,g3); d.p(9,4,g4); d.v(16,6,4,g1); d.spark(21,12); d.spark(2,14); }],
 ]},
 { key:'meetings', items:[
  [1, d=>{ for(let x=3;x<=16;x++){ const hh=Math.round(1+(x-3)*.25); d.v(x,9-hh,2*hh+1,c2); d.p(x,9-hh,c3); } d.e(18,9,3,6,c2); d.e(19,9,1,4,c0); d.v(16,4,3,c3); d.r(1,8,2,3,c1); d.r(10,13,2,5,w1); d.r(6,18,10,2,w1); d.h(7,18,8,w2); }],
  [5, d=>{ d.l(6,11,4,19,w1); d.l(12,12,12,19,w1); d.l(18,11,20,19,w1); d.h(6,15,12,w1); d.e(12,9,8,2,w2); d.e(12,8,7,1,w3); }],
  [10, d=>{ d.r(5,1,14,2,w2); d.h(5,1,14,w3); d.v(5,1,10,w1); d.v(18,1,10,w1); [9,12,15].forEach(x=>d.v(x,3,8,w2)); d.r(4,11,16,3,w2); d.h(5,11,14,r2); d.h(4,13,16,w1); d.r(5,14,2,6,w1); d.r(17,14,2,6,w1); }],
  [25, d=>{ d.r(10,0,4,2,w2); d.r(11,2,2,3,w1); d.e(11.5,9,5,4,g2); for(let y=9;y<=15;y++) d.row(11.5,y,5+(y-9)*.5,g2); d.h(3,16,18,g1); d.v(8,7,8,g3); d.v(9,6,2,g4); d.e(11.5,18,1,1,s1); d.f(2,6,g3); d.f(1,8,g3); d.f(21,6,g3); d.f(22,8,g3); }],
  [50, d=>{ d.e(11.5,11,10,3,w2); d.e(11.5,10,9,1.6,w3); d.r(10,15,4,3,w1); d.r(7,18,10,2,w1); goblet(d,2,3); goblet(d,15,3,s3,s2,s4); candle(d,10,5,8); }],
  [100, d=>{ d.box(2,15,12,5,w2); d.h(3,16,10,w3); d.l(10,9,18,17,w1); d.l(11,9,19,17,w1); d.box(4,3,12,6,w2); d.h(5,4,10,w3); d.v(6,4,4,g2); d.v(13,4,4,g2); d.f(1,12,g3); d.f(3,11,g3); d.f(15,12,g3); }],
  [250, d=>{ [[3,5],[13,5]].forEach(([x,y])=>{ d.r(x,y,7,2,g2); d.h(x,y,7,r1); d.r(x+1,y+2,5,1,g2); d.r(x+2,y+3,3,1,g2); d.v(x+3,y+4,9,g1); d.r(x,18,7,2,g2); d.h(x,18,7,g3); }); [[11,1],[10,2],[12,2],[9,3],[13,3],[11,3]].forEach(([x,y],i)=>d.f(x,y,i%2?r2:r3)); d.spark(11,1); }],
  [500, d=>{ const P=[[4,17],[3,4],[18,6]]; for(let i=0;i<=70;i++){ const t=i/70, u=1-t; const x=u*u*P[0][0]+2*u*t*P[1][0]+t*t*P[2][0], y=u*u*P[0][1]+2*u*t*P[1][1]+t*t*P[2][1]; const r=0.6+2.9*Math.pow(t,1.4); const band=(t>.42&&t<.46)||(t>.72&&t<.76)||t<.07; d.e(x,y,r,r,band?g2:p2); if(!band && r>1.2) d.p(x-r*.4,y-r*.6,p3); } d.e(21,6,0,2.5,w0); d.r(9,15,2,3,w1); d.r(6,18,8,2,w1); d.h(7,18,6,w2); }],
  [1000, d=>{ d.map(6,0,['1..........1','11..1..1..11','111111111111'],{1:g2}); d.r(5,3,14,10,g2); d.r(7,5,10,7,v1); d.v(8,6,5,v2); d.h(10,8,4,g3); d.h(11,7,2,g3); d.h(11,9,2,g3); d.v(11,7,3,K0); d.r(4,12,16,3,e2); d.h(4,12,16,e3); d.r(4,15,16,2,g2); d.h(4,16,16,g1); d.r(4,17,2,3,g1); d.r(18,17,2,3,g1); d.r(2,10,3,5,g2); d.r(19,10,3,5,g2); d.e(3,8,1.5,1.2,c2); d.p(3,6,e1); d.e(20,8,1.5,1.2,c2); d.p(20,6,e1); }],
 ]},
 { key:'meetingTime', items:[
  [1, d=>{ d.r(10,5,4,12,gl); d.r(11,17,2,1,gl); d.r(10,10,4,7,ne); d.r(11,17,2,1,ne); d.h(10,10,4,e4); d.v(10,5,5,glh); d.r(10,2,4,3,w3); d.v(13,2,3,w2); d.r(7,18,10,2,w1); d.h(8,18,8,w2); }],
  [5, d=>{ bottleFill(d,11.5,13,6,6,gl,v2,12,v3); d.p(8,10,glh); d.p(8,11,glh); d.p(9,9,glh); d.r(10,3,4,5,gl); d.r(10,0,4,3,w3); d.v(13,0,3,w2); d.p(13,15,v3); d.p(10,17,v3); d.f(15,5,v3); d.f(16,3,v3); }],
  [10, d=>{ d.r(10,3,4,5,gl); for(let y=8;y<=19;y++) d.row(11.5,y,2+(y-8)*.6,y>=13?e2:gl); for(let y=13;y<=13;y++) d.row(11.5,y,2+(y-8)*.6,ne); d.p(9,16,e4); d.p(14,17,e4); d.p(12,15,e3); d.v(10,4,3,glh); d.f(12,1,e4); d.f(11,0,ne); d.f(13,2,ne); d.f(10,1,e3); }],
  [24, d=>{ d.r(5,18,2,2,K1); d.r(17,18,2,2,K1); d.e(11.5,12,9,5.5,K1); d.v(5,11,3,K2); d.e(11.5,6,8,1,ne); d.r(2,7,20,2,K2); d.h(3,7,18,K3); d.p(8,5,e4); d.p(14,5,e4); d.f(10,3,ne); d.f(13,2,e4); d.f(9,1,ne); d.f(15,0,e3); }],
  [50, d=>{ d.e(11.5,9,7,4.5,K1); d.v(6,8,3,K2); d.e(11.5,3.5,6,1,ne); d.r(4,4,16,2,K2); d.h(5,4,14,K3); d.r(4,18,16,2,w2); d.p(4,18,w3); d.p(19,18,w3); d.map(6,14,['..a...a..a..','.aba.aba.aba','abcbabcbabcb','bcccbcccbccb'],{a:g3,b:g2,c:g1},true); d.f(10,1,ne); d.f(13,0,e4); d.f(15,2,ne); }],
  [100, d=>{ d.r(2,15,20,2,w2); d.h(2,15,20,w3); d.r(3,17,2,3,w1); d.r(19,17,2,3,w1); d.r(2,8,6,7,r2); d.v(3,9,4,r3); d.v(7,8,7,r1); d.r(4,5,2,3,gl); d.r(4,3,2,2,w3); d.e(11.5,11,2.5,3,b2); d.p(10,10,b3); d.r(11,5,2,3,gl); d.r(11,3,2,2,w3); for(let y=7;y<=14;y++) d.row(19,y,.5+(y-7)*.35,v2); d.p(18,11,v3); d.r(18,4,2,3,gl); d.r(18,2,2,2,w3); d.r(4,11,2,2,p2); }],
  [250, d=>{ bottleFill(d,6,12,4,4,gl,r2,13); d.r(5,4,2,4,gl); d.l(6,3,13,3,gl); d.l(13,3,17,9,gl); d.r(3,17,1,3,s1); d.r(9,17,1,3,s1); d.r(5,19,3,1,s1); d.f(6,17,b3); d.f(6,18,b2); d.f(5,18,b2); d.f(7,18,b2); bottleFill(d,18,15,4,4,gl,ne,16,e4); d.f(17,10,ne); d.p(4,10,glh); d.p(16,13,glh); }],
  [500, d=>{ d.v(6,3,13,s1); d.v(17,3,13,s1); d.r(7,4,10,12,gl); d.r(7,6,10,10,ne); d.h(7,6,10,e4); d.v(8,7,8,e4); [[12,9],[14,12],[10,13],[13,7],[11,11],[15,9]].forEach(([x,y])=>d.p(x,y,e4)); d.r(5,1,14,3,s2); d.h(5,1,14,s3); d.r(9,0,6,1,s1); d.r(5,16,14,4,s2); d.h(5,16,14,s3); for(let x=5;x<=18;x++) d.p(x,18,(x>>1)%2?g2:K1); d.f(3,6,ne); d.f(21,10,e4); d.f(2,12,ne); d.f(20,4,ne); }],
 ]},
 { key:'streak', items:[
  [3, d=>{ d.e(11.5,19,6,2,w1); d.h(8,17,8,w2); d.v(12,12,5,e2); d.h(8,11,4,e3); d.h(9,10,3,e3); d.p(11,12,e2); d.h(13,9,4,e3); d.h(13,10,5,e3); d.f(17,5,b3); d.f(17,6,b2); }],
  [7, d=>{ mush(d,12,19,5,7,6,r2,p2,[[-4,2],[1,1,2],[4,3]]); d.p(9,19,e2); d.p(16,19,e3); d.p(17,18,e2); }],
  [14, d=>{ mush(d,17,19,4,4,3,c2,p2,[[0,1]]); mush(d,8,19,6,6,5,r2,p2,[[-3,2],[1,1,2],[4,3]]); }],
  [30, d=>{ mush(d,20,19,3,2,2,p1,p2); mush(d,5,19,4,4,3,c3,c2); mush(d,16,19,5,5,3,c2,c3); mush(d,10,19,7,5,4,w3,p1,[[-2,1],[2,2]]); }],
  [50, d=>{ d.e(11.5,16,10,3.5,e1); d.e(11.5,16,8,2.5,e2); [[2,15],[5,13],[9,12],[14,12],[18,13],[21,15],[17,18],[6,18],[11,19]].forEach(([x,y])=>mush(d,x,y,2,2,1,r2,p2)); d.f(10,8,g4); d.f(13,6,e4); d.f(12,10,g3); d.f(8,5,e4); }],
  [100, d=>{ mush(d,11,19,9,10,6,r2,p2,[[-7,4,2],[-2,1,2],[4,2,2],[7,5],[1,4]]); d.h(8,14,7,p2); d.e(19,17,1.5,1.5,c2); d.p(19,17,c3); d.h(16,19,5,p1); d.p(16,18,p1); d.p(3,19,e2); d.p(4,18,e3); }],
  [200, d=>{ mush(d,6,19,5,4,3,ne,e1,[[-1,1]],e4,e3); mush(d,17,19,4,4,3,e3,e1,[[0,1]],e4,e3); mush(d,11,19,8,6,5,ne,e1,[[-3,2],[2,1],[3,3]],e4,e3); [[4,5],[19,7],[9,2],[15,4],[21,12]].forEach(([x,y])=>d.f(x,y,ne)); d.f(13,1,e4); }],
  [365, d=>{ mush(d,12,19,10,10,6,r1,p2,[[-6,4,2],[0,1,2],[5,3,2]],p2,p1); d.box(10,14,4,6,w1); d.p(12,17,g2); d.box(14,11,3,3,g3); d.r(16,1,2,3,s2); d.f(17,0,s3); d.f(18,0,s4); }],
  [730, d=>{ d.e(11.5,20,11,11,s1); [[5,12],[8,10],[15,10],[18,13],[4,16],[19,17],[12,9]].forEach(([x,y])=>d.p(x,y,s2)); d.e(11.5,17,4,5,K0); d.h(9,15,2,ne); d.h(13,15,2,ne); d.p(10,15,K0); d.p(13,15,K0); d.e(19,18,2,1.5,c2); d.p(18,18,g3); d.p(20,18,g3); d.p(19,16,e1); mush(d,4,13,2,2,1,r2,p2); mush(d,16,10,2,2,1,ne,e1); d.l(7,9,6,13,e1); d.l(17,12,18,15,e1); d.map(3,1,['1...1','11111','.1.1.'],{1:K1}); d.map(16,3,['1...1','11111','.1.1.'],{1:K1}); }],
 ]},
 { key:'bigDay', items:[
  [1000, d=>{ d.r(11,9,2,11,w3); d.v(12,9,11,w2); d.e(11.5,7,1.5,2,r1); d.p(11,6,r2); flame(d,12,5); d.f(12,0,g4); d.f(8,3,g3); d.f(16,2,g3); d.f(15,5,g2); }],
  [2500, d=>{ d.r(11,10,3,10,w1); d.v(11,10,10,w2); d.h(10,12,5,p1); d.h(10,15,5,p1); d.r(9,8,7,2,s1); d.h(9,8,7,s2); d.map(8,0,['....a....','...aa....','...aba.a.','..abba.a.','.abbbbaa.','.abccbba.','abcccccba','abcccccba'],{a:g1,b:g2,c:g3},true); }],
  [5000, d=>{ [[2,17],[6,18],[10,17],[14,18],[18,17]].forEach(([x,y],i)=>{ d.e(x+1.5,y+1,1.5,1,i%2?s1:s2); d.p(x+1,y,s3); }); d.l(5,16,16,11,w2); d.l(5,15,16,10,w2); d.l(18,16,7,11,w2); d.l(18,15,7,10,w2); d.p(5,15,w3); d.p(18,15,w3); d.map(5,0,['......a......','.....aa......','.....aba..a..','....abba..aa.','...abbba.aba.','..abbcbbaabba','..abccccbbba.','.abcccccccba.','.abccccccccba','abccccccccccb','.abccccccccb.'],{a:g1,b:g2,c:g3},true); }],
  [10000, d=>{ for(let y=6;y<=19;y++){ const hw=Math.min(10.5,2+(y-6)*.75); d.row(11.5,y,hw,w0); d.row(11.5-hw*.6,y,hw*.25,s0); } d.row(11.5,6,2,r2); d.row(11.5,7,2.5,g2); [[11,8],[11,9],[10,10],[10,11],[9,12],[9,13],[8,14],[13,8],[14,9],[14,10],[15,11],[16,12],[16,13],[17,14],[17,15]].forEach(([x,y],i)=>d.p(x,y,i%3?r2:g2)); [[11,4],[12,3],[10,2],[13,1],[8,3],[15,2],[11,0],[17,4],[6,5]].forEach(([x,y],i)=>d.f(x,y,i%2?g2:r2)); d.f(12,5,g3); }],
  [20000, d=>{ d.e(11.5,12,7,6,c2); d.e(11.5,12,4,6,c1); d.e(11.5,12,3,5.4,c2); d.e(8,9,1,1,c3); d.p(7,10,g3); d.h(6,11,3,g3); d.p(16,10,g3); d.h(15,11,3,g3); d.h(7,14,10,g3); d.h(8,15,8,g3); d.p(9,14,c1); d.p(14,14,c1); d.p(11,15,c1); d.p(12,13,g3); d.r(10,4,4,2,s1); d.h(10,4,4,s2); d.l(13,3,16,2,w3); d.spark(17,1); d.f(19,2,g2); d.f(15,0,g1); }],
 ]},
 { key:'apps', items:[
  [3, d=>{ d.e(6,9,4,4,s2); d.e(6,9,1,1,null); d.p(4,7,s3); d.r(10,8,10,3,s2); d.h(10,8,10,s3); d.r(15,11,2,3,s2); d.r(18,11,2,4,s2); d.l(5,13,6,15,O); d.box(4,15,5,4,p2); }],
  [5, d=>{ d.e(11.5,5,4,3,s2); d.e(11.5,5,3,2,null); [[7,s2,s3],[12,c2,c3],[17,g2,g3]].forEach(([cx,c,hi],i)=>{ const top=8+(i===1?0:1); d.e(cx,top+2,2,2,c); d.p(cx,top+2,null); d.v(cx,top+5,6,c); d.p(cx+1,top+8,c); d.p(cx+1,top+10,c); d.p(cx-1,top+1,hi); }); }],
  [10, d=>{ d.e(5,6,2,2,g2); d.e(3,9,2,2,g2); d.e(5,12,2,2,g2); d.e(6,9,2,2,g2); d.p(6,9,r2); d.p(4,5,g3); d.r(8,8,12,2,g2); d.h(8,8,12,g3); d.r(9,7,2,4,g1); d.r(16,10,2,4,g2); d.r(19,10,2,3,g2); d.p(18,13,g2); d.spark(14,4); }],
  [25, d=>{ d.r(5,6,14,14,w2); d.e(11.5,6,6.5,5,w2); d.v(9,3,17,w1); d.v(14,3,17,w1); d.r(5,8,5,1,s1); d.r(5,15,5,1,s1); d.e(11.5,12,1.5,1.5,g2); d.p(11,12,null); d.p(12,12,null); d.p(16,11,ne); d.v(16,12,2,ne); d.f(18,10,ne); d.f(20,9,ne); d.f(19,12,e4); d.f(21,11,ne); d.f(18,14,ne); }],
 ]},
 { key:'dictionary', items:[
  [1, d=>{ d.r(10,5,4,7,e2); d.v(12,5,7,ne); d.v(13,5,7,e3); d.h(11,4,2,e3); d.r(15,8,2,4,e2); d.p(16,7,e3); d.e(11.5,15,8,4.5,s2); d.e(13,16,5,2.5,s1); d.h(6,12,5,s3); }],
  [10, d=>{ [[4,8,15],[5,7,16],[6,6,17],[7,5,18]].forEach(([y,a,b])=>{ for(let x=a;x<=b;x++) d.p(x,y,x<a+3?e2:x>b-3?e1:ne); }); for(let y=8;y<=17;y++){ const hw=6.5-(y-8)*.7; d.row(11.5,y,hw,ne); d.row(11.5-hw*.6,y,hw*.35,e2); d.row(11.5+hw*.6,y,hw*.35,e1); } d.h(8,4,8,e4); d.h(5,7,14,e0); d.spark(19,3); d.twinkle(9,10,WH); }],
  [50, d=>{ d.e(11.5,12,9,7,s1); d.e(11.5,12,8,6,s3); d.e(11.5,12,7,5,v1); [[6,10],[7,13],[9,8],[14,8],[16,11],[15,15],[9,16],[12,16],[5,12],[17,13]].forEach(([x,y],i)=>{ d.p(x,y,v3); d.p(x+(x<12?1:-1),y,v2); }); d.p(11,12,WH); d.p(12,11,v3); d.f(20,4,v3); }],
  [100, d=>{ for(let x=3;x<=20;x++){ const y=Math.round(10-9*((x-11.5)/8.5)**2); d.f(x,y,x%2?g2:g1); } d.r(11,9,2,2,g1); d.e(11.5,14,4,4,g2); d.e(11.5,14,2.5,2.5,r1); d.e(11,13,1,1,r2); d.p(10,12,r3); d.p(8,12,g3); }],
  [250, d=>{ d.r(5,8,14,5,r1); [3,7.5,11.5,15.5,20].forEach((cx,i)=>{ const top=i===2?3:i%2?5:6; for(let y=top;y<=12;y++) d.row(cx,y,(y-top)*.45,g2); d.p(Math.round(cx),top-1,p3); }); d.r(3,13,18,5,g2); d.h(3,13,18,g3); d.r(6,14,2,2,r2); d.r(11,14,2,2,b2); d.r(16,14,2,2,ne); d.h(3,18,18,g1); d.spark(21,2); }],
 ]},
 { key:'people', items:[
  [1, d=>{ d.r(10,3,4,3,s2); d.box(3,6,18,12,p3); d.r(4,7,16,5,r1); d.txt(8,7,'HI',p3); [[7,14],[8,13],[9,14],[10,15],[11,14],[12,13],[13,14],[14,14],[15,13],[16,14]].forEach(([x,y])=>d.p(x,y,O)); d.h(4,16,16,r1); }],
  [5, d=>{ d.l(8,2,11,0,O); d.l(12,0,15,2,O); d.r(4,3,16,16,g2); d.h(4,3,16,g3); d.v(19,3,16,g1); d.box(6,5,12,12,b3); d.e(11.5,16,4,3,v1,6,15); d.e(11.5,10,2,2.5,c3); d.h(10,7,4,w1); d.p(4,3,g4); }],
  [10, d=>{ d.r(2,2,10,12,g2); d.box(3,3,8,10,v3); d.e(7,12,2.5,2,v1,4,11); d.e(7,8,1.5,1.5,c3); d.r(11,7,10,12,c2); d.h(11,7,10,c3); d.box(12,8,8,10,b3); d.e(16,17,2.5,2,b1,9,16); d.e(16,13,1.5,1.5,c3); d.h(15,11,3,K1); }],
  [25, d=>{ d.r(4,2,16,17,p2); [5,8,11,14,17].forEach(x=>d.p(x,18,null)); d.p(11,2,s1); d.h(7,4,10,w1); d.h(7,5,10,w1); d.box(7,7,10,7,p1); d.map(10,8,['.11.','1..1','..1.','.1..','....','.1..'],{1:w0}); d.h(6,16,6,w1); coin(d,16,16,2); }],
  [50, d=>{ d.e(8,9,5,6,p3); d.h(5,8,2,O); d.h(9,8,2,O); d.p(5,11,O); d.h(6,12,4,O); d.p(10,11,O); d.p(4,10,r3); d.p(11,10,r3); d.e(15,11,6,7,O); d.e(15,11,5,6,v3); d.h(12,10,2,O); d.h(16,10,2,O); d.p(12,9,O); d.p(17,9,O); d.p(12,15,O); d.h(13,14,4,O); d.p(17,15,O); d.p(17,12,b3); d.l(3,9,1,14,r2); d.l(3,10,2,15,r2); }],
  [100, d=>{ d.r(10,14,4,4,w1); d.v(10,14,4,w2); d.r(7,18,10,2,w1); d.h(8,18,8,w2); d.e(11.5,8,5,5.5,e2); [[2,5,3],[3,6,4],[5,7,2]].forEach(([x,y,n])=>{ d.h(x,y,n,e2); d.h(23-x-n,y,n,e2); }); d.p(2,4,e3); d.p(21,4,e3); d.e(11.5,5,3,1.5,e3); d.l(7,5,10,6,e0); d.l(16,5,13,6,e0); d.h(8,7,3,g3); d.h(13,7,3,g3); d.p(9,7,K0); d.p(14,7,K0); d.v(11,7,3,e1); d.v(12,7,3,e1); d.h(8,11,8,O); d.p(7,10,O); d.p(16,10,O); [9,11,12,14].forEach(x=>d.p(x,11,g4)); d.v(16,8,4,e1); d.r(1,18,4,2,s2); d.h(1,18,4,s3); candle(d,2,14,17,2); d.r(19,18,4,2,s2); d.h(19,18,4,s3); candle(d,20,14,17,2); }],
 ]},
 { key:'marks', items:[
  [1, d=>{ feather(d,5,19,19,1,3.6); d.f(4,19,b1); d.f(3,19,b0); }],
  [25, d=>{ feather(d,10,10,20,0,2.8); d.e(9,15,6,4.5,K1); d.r(6,9,7,2,K1); d.r(5,8,9,1,K2); d.box(5,13,8,4,p2); d.h(6,14,6,b1); d.p(6,12,K2); d.f(15,19,b1); d.f(16,19,b0); }],
  [100, d=>{ d.r(4,9,16,7,p2); d.h(4,9,16,p3); d.e(4,12,1.5,3.5,p3); d.p(4,12,O); d.e(19,12,1.5,3.5,p1); d.p(19,12,O); d.v(11,9,7,r1); d.v(12,9,7,r1); d.l(10,15,8,19,r1); d.l(13,15,15,19,r1); d.e(11.5,12,3,3,r1); d.e(11.5,12,2,2,r2); d.v(11,11,3,r0); d.v(12,11,3,r0); }],
  [250, d=>{ const bat=['1..1.1..1','11.111.11','111111111','.1.....1.']; [[1,3],[13,1],[7,11]].forEach(([x,y])=>{ d.map(x,y,bat,{1:s3}); d.h(x+1,y+2,7,s4); d.p(x+3,y+1,ne); d.p(x+5,y+1,ne); }); [[0,9],[1,9],[11,7],[12,7],[5,16],[6,16]].forEach(([x,y])=>d.f(x,y,s3)); d.spark(21,7,WH,s4); }],
 ]},
 { key:'secrets', secret:true, items:[
  ['night', d=>{ d.e(10,10,7,7,g3); d.e(13.5,8,6,6,null); d.v(4,8,5,g2); d.e(18,16,2,3,w2); d.p(16,13,w2); d.p(20,13,w2); d.p(17,15,g3); d.p(19,15,g3); d.p(18,16,c2); d.v(18,17,2,w3); d.spark(18,3); d.twinkle(21,8); d.twinkle(14,1); }],
  ['early', d=>{ d.e(9,11,6,6,g2); d.e(9,11,4,4,g3); [[9,2],[2,6],[16,5],[1,12],[3,3]].forEach(([x,y])=>d.f(x,y,g3)); d.e(9,22,12,6,e2); d.box(13,12,7,8,r1); d.h(14,13,5,w0); d.e(20.5,15.5,1.5,2,r1); d.p(21,15,O); d.p(21,16,O); d.f(15,10,s4); d.f(16,9,s4); d.f(15,8,s4); d.f(18,10,s4); d.f(17,9,s4); d.f(18,8,s4); }],
  ['monologue', d=>{ d.box(4,12,16,8,w2); d.h(5,13,14,w3); d.h(5,16,14,w1); d.v(11,13,6,w1); for(let x=7;x<=16;x++){ const hh=Math.round(1+(x-7)*.45); d.v(x,8-hh,2*hh+1,r2); d.p(x,8-hh,r3); } d.v(17,2,13,r1); d.r(9,9,2,3,s1); d.v(18,3,11,O); [[19,5],[20,6],[20,7],[20,8],[19,9],[21,3],[22,5],[22,6],[22,7],[22,8],[22,9],[21,11]].forEach(([x,y])=>d.f(x,y,g3)); }],
  ['marathon', d=>{ d.r(6,4,6,9,c2); d.v(6,4,9,c3); d.r(6,12,11,5,c2); d.e(16,14,3,2.5,c2); d.r(5,17,15,2,w0); d.r(5,3,8,2,c3); [[11,6],[11,8],[11,10]].forEach(([x,y])=>{ d.p(x,y,O); d.p(x-1,y+1,O); }); d.h(1,5,5,p3); d.h(2,7,4,p3); d.h(3,9,3,p2); d.p(1,4,p3); d.f(1,13,s3); d.f(2,13,s3); d.f(0,15,s3); d.f(1,15,s3); d.f(2,15,s3); }],
  ['feast', d=>{ d.e(11.5,16,10,3,s4); d.e(11.5,16,7,2,s3); d.e(10,11,5,3.5,c2); d.e(9,10,3,2,c3); d.r(15,8,4,2,p3); d.e(19,7,1.5,1.5,p3); d.e(19,9,1,1,p3); d.p(4,14,e3); d.p(5,13,e2); d.f(8,4,s4); d.f(9,3,s4); d.f(12,4,s4); d.f(13,3,s4); }],
  ['pocket', d=>{ d.box(7,1,10,19,K1); d.r(8,3,8,14,e0); d.r(10,2,4,1,O); d.e(11.5,9,2.5,2.5,e2); d.h(8,8,2,e2); d.h(14,8,2,e2); d.p(10,9,g3); d.p(13,9,g3); d.h(11,11,2,O); d.p(11,12,e4); d.h(10,18,4,s2); d.p(17,5,K2); d.p(17,7,K2); d.spark(20,4); d.twinkle(4,8); }],
  ['weekend', d=>{ d.l(3,18,20,1,s4); d.l(4,18,21,1,s3); d.l(2,14,7,19,g2); d.l(1,19,3,17,w1); d.e(13,11,7,7,g2); d.e(13,11,6,6,b1); d.e(11,9,3,2,b2); d.e(13,11,1.5,1.5,s3); d.p(13,11,WH); }],
  ['fullweek', d=>{ d.box(3,4,18,15,p3); d.r(4,5,16,3,r1); d.r(7,2,2,4,s2); d.r(15,2,2,4,s2); [4,7,10,13,16].forEach(x=>{ d.p(x,11,e1); d.p(x+1,12,e1); d.p(x+2,10,e1); d.p(x+2,9,e1); }); [5,8,11,14,17].forEach(x=>d.p(x,15,s3)); d.p(5,17,s3); d.p(8,17,s3); }],
  ['juggler', d=>{ [[5,13,r2,r3],[11.5,5,b2,b3],[18,11,g2,g3]].forEach(([x,y,c,hi])=>{ d.e(x,y,2.5,2.5,c); d.p(Math.round(x)-1,y-1,hi); }); [[7,9],[8,7],[15,6],[17,8],[6,17],[10,18],[14,18],[17,15]].forEach(([x,y])=>d.f(x,y,s3)); }],
  ['newyear', d=>{ const cx=13, cy=7; [[1,0],[-1,0],[0,1],[0,-1],[1,1],[-1,-1],[1,-1],[-1,1]].forEach(([dx,dy],i)=>{ for(let k=2;k<=5;k++) d.f(cx+dx*k,cy+dy*k,[r2,g3,b3,ne][i%4]); }); d.f(cx,cy,g4); d.r(5,13,3,5,r1); d.p(6,12,r2); d.v(6,18,2,w3); d.f(6,11,g2); d.f(7,10,g2); d.f(19,15,v3); d.f(20,14,v3); d.f(21,15,v3); d.f(20,16,v3); }],
  ['anniversary', d=>{ d.h(2,19,20,s3); d.r(4,13,16,6,p2); d.r(4,12,16,2,r3); [6,10,14,17].forEach(x=>d.p(x,14,r3)); d.r(7,8,10,4,p2); d.r(7,8,10,2,r3); [9,13].forEach(x=>d.p(x,10,r3)); d.r(11,5,2,3,b3); d.p(11,5,WH); d.p(12,7,WH); d.p(12,4,O); flame(d,12,4); [[6,16,b2],[12,17,g2],[16,15,ne],[9,16,v2]].forEach(([x,y,c])=>d.p(x,y,c)); }],
  ['halloween', d=>{ d.l(5,10,8,4,O); d.l(8,4,15,4,O); d.l(15,4,18,10,O); d.e(11.5,14,7,5,c2); d.e(11.5,14,3,5,c3,10); [[6,9,r2],[8,8,b2],[10,8,ne],[12,7,v2],[14,8,g2],[16,9,r3],[9,9,g3],[13,9,b3]].forEach(([x,y,c])=>d.r(x,y,2,2,c)); d.p(8,13,K1); d.h(7,14,3,K1); d.p(15,13,K1); d.h(14,14,3,K1); d.h(8,17,8,K1); d.p(8,16,K1); d.p(15,16,K1); }],
  ['split', d=>{ d.e(11.5,8,6,7,g2); d.e(11.5,8,5,6,b3); d.p(15,3,s4); d.p(16,4,s4); d.p(16,5,s4); d.e(11.5,9,3.5,4,c3); for(let y=0;y<20;y++) for(let x=0;x<=11;x++) if(d.a[y*W+x]===c3) d.a[y*W+x]=e2; d.r(6,7,2,1,e2); d.p(6,6,e2); d.r(12,5,4,2,w1); d.p(15,7,w1); d.p(9,8,g3); d.p(10,8,O); d.p(9,7,e1); d.p(10,7,e1); d.p(13,8,O); d.p(14,8,WH); d.h(13,7,2,w1); d.p(9,11,O); d.h(10,12,2,O); d.p(10,11,e4); d.h(12,12,2,O); d.r(11,15,2,3,g1); d.r(8,18,8,2,g1); d.h(8,18,8,g2); }],
  ['cackle', d=>{ d.box(6,12,12,8,v1); d.h(7,13,10,v2); [[9,16],[12,15],[15,16]].forEach(([x,y])=>{ d.p(x,y-1,g2); d.p(x-1,y,g2); d.p(x+1,y,g2); d.p(x,y+1,g2); d.p(x,y,g3); }); d.r(18,15,2,1,s2); d.v(20,13,3,s2); d.l(11,11,13,10,s3); d.l(13,10,11,9,s3); d.e(11.5,5,3,3,e2); d.r(5,3,3,1,e2); d.r(6,4,2,1,e2); d.r(16,3,3,1,e2); d.r(16,4,2,1,e2); d.p(10,4,g3); d.p(13,4,g3); d.r(10,6,4,2,O); d.p(10,6,g4); d.p(13,6,g4); d.f(3,8,g3); d.f(2,7,g3); d.f(20,8,g3); d.f(21,7,g3); d.f(4,1,g3); }],
  ['lurker', d=>{ for(let y=10;y<=19;y++) d.row(11.5,y,4+(y-10)*.65,v1); [7,16].forEach(x=>d.v(x,13,6,v0)); d.v(11,12,8,v0); [3,6,9,12,15,18].forEach(x=>d.p(x,19,null)); d.e(11.5,6,5,5,v1); d.e(10,4,2,2,v2); d.e(11.5,7,3,3.5,K0); d.p(10,7,ne); d.p(13,7,ne); d.p(10,8,e2); d.p(13,8,e2); }],
  ['swarm', d=>{ const big=['1..1.1..1','11.111.11','111111111','.1.....1.'], small=['1...1','11111','.1.1.']; [[2,2,big],[13,5,big],[6,12,big]].forEach(([x,y,m])=>{ d.map(x,y,m,{1:v1}); d.p(x+3,y+1,ne); d.p(x+5,y+1,ne); }); [[15,0],[1,9],[17,13],[11,9],[19,17]].forEach(([x,y])=>d.map(x,y,small,{1:K1})); d.f(9,8,v3); d.f(21,10,v3); }],
 ]},
];


// ---------- write ----------
function png(width, height, rgba) {
  const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = buf => { let c = 0xffffffff; for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const body = Buffer.concat([Buffer.from(type), data]); const sum = Buffer.alloc(4); sum.writeUInt32BE(crc(body)); return Buffer.concat([len, body, sum]); };
  const header = Buffer.alloc(13); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 6;
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

const out = path.resolve(__dirname, '../../Sources/GoblinApp/Assets/hoard');
fs.mkdirSync(out, { recursive: true });
let written = 0;
for (const shelf of TRACKS) {
  shelf.items.forEach(([key, draw], i) => {
    const id = shelf.secret ? `secret-${key}` : `${shelf.key}-${key}`;
    const mat = shelf.secret ? 'amethyst' : LADDER[Math.round(i * (LADDER.length - 1) / Math.max(1, shelf.items.length - 1))];
    const d = grid(); draw(d); d.unclip(); plinth(d, mat); outline(d);
    const rgba = Buffer.alloc(W * H * 4);
    [d.a, d.fx].forEach(layer => layer.forEach((c, k) => {
      if (!c) return;
      rgba[k * 4] = parseInt(c.slice(1, 3), 16); rgba[k * 4 + 1] = parseInt(c.slice(3, 5), 16); rgba[k * 4 + 2] = parseInt(c.slice(5, 7), 16); rgba[k * 4 + 3] = 255;
    }));
    fs.writeFileSync(path.join(out, id + '.png'), png(W, H, rgba));
    written++;
  });
}
console.log(`Wrote ${written} treasures to ${path.relative(process.cwd(), out)}`);
