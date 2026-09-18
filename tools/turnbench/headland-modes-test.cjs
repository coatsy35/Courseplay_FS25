const assert=require('node:assert/strict');
const {chromium}=require('C:/Users/danco/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
(async()=>{const browser=await chromium.launch({headless:true,args:['--disable-gpu']});try {
 const page=await browser.newPage({viewport:{width:1600,height:1000}});page.setDefaultTimeout(180000);
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('http://127.0.0.1:56514');await page.waitForFunction(()=>result&&!document.getElementById('run').disabled);
 assert.equal(await page.locator('#generatorRadius').inputValue(),'5');assert.equal(await page.locator('#radius').inputValue(),'9');
 for(const [name,values] of [['rounded',{roundHeadlands:9,loopTurnsOnHeadland:false}],['loop',{roundHeadlands:1,loopTurnsOnHeadland:true}],['sloping-loop',{fieldShape:'sloping',roundHeadlands:1,loopTurnsOnHeadland:true}],['drill12-loop',{preset:'drill12',fieldShape:'rectangle',fieldWidth:400,fieldLength:400,roundHeadlands:1,loopTurnsOnHeadland:true}]]) {
  await page.evaluate(values=>{for(const [id,v] of Object.entries(values)){const el=document.getElementById(id);if(typeof v==='boolean')el.checked=v;else el.value=v;el.dispatchEvent(new Event('change',{bubbles:true}));}},values);
  const response=page.waitForResponse(r=>r.url().endsWith('/api/simulate'));await page.locator('#run').click();assert.equal((await response).status(),200);
  await page.waitForFunction(()=>!document.getElementById('run').disabled);
  const state=await page.evaluate(()=>({end:result.baseline.frames.at(-1).state,headlandReverse:result.baseline.path.some(w=>w.phase==='Headland corner'&&w.reverse),headlandTurns:result.baseline.events.filter(e=>e.kind==='Headland turn started').length,offset:Math.max(...result.baseline.frames.filter(f=>f.phase==='Headland').map(f=>Math.abs(f.offset))),rows:result.baseline.frames.some(f=>f.phase==='Central row'),scenario:result.baseline.scenario.loopTurnsOnHeadland}));
  console.log(name,JSON.stringify(state));assert.equal(state.end,'Finished');assert(!state.headlandReverse);assert(state.rows);
  if(name==='rounded'){assert.equal(state.headlandTurns,0);assert(state.offset>.5);}else{assert(state.headlandTurns>0);assert(state.scenario);}
  assert(await page.locator('#play').isEnabled());await page.locator('#play').click();await page.waitForFunction(()=>frame>0);await page.locator('#play').click();
  await page.locator('#show-turns').check();await page.screenshot({path:'out/turnbench-'+name+'.png'});
 }
 await page.evaluate(()=>{result.baseline.metrics.complete=false;updateMetrics();});
 assert.match(await page.locator('#shortfall').textContent(),/Run incomplete/);
 await page.evaluate(()=>{result.baseline.metrics.complete=true;updateMetrics();});
 assert.equal(await page.locator('#shortfall').textContent(),'');
 assert.deepEqual(errors,[]);console.log('PASS rounded tracking and full-course headland loop playback');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exit(1);});
