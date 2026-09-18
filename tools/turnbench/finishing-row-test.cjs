const assert=require('node:assert/strict');
const {chromium}=require('C:/Users/danco/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
(async()=>{const browser=await chromium.launch({headless:true,args:['--disable-gpu']});try{
const page=await browser.newPage({viewport:{width:1600,height:1000}});page.setDefaultTimeout(120000);const errors=[];page.on('pageerror',e=>errors.push(e.message));
await page.goto('http://127.0.0.1:56514');await page.waitForFunction(()=>!document.getElementById('run').disabled);
assert.match(await page.locator('#shortfall').textContent(),/not a required headland increase/);
await page.locator('#enforceBoundary').uncheck(); // Explicit diagnostic playback, not a safe-field assertion.
const response=page.waitForResponse(r=>r.url().endsWith('/api/simulate'));await page.locator('#run').click();assert.equal((await response).status(),200);await page.waitForFunction(()=>!document.getElementById('run').disabled);
const state=await page.evaluate(()=>{const r=result.baseline;const ix=r.frames.findIndex(f=>f.phase==='Headland corner'&&f.reverse);return {complete:r.metrics.complete,ix,reverse:r.path.some(w=>w.phase==='Headland corner'&&w.reverse),forward:r.path.some(w=>w.phase==='Headland corner'&&!w.reverse),controls:r.path.some(w=>w.changeWhenAligned),turnRequests:r.events.filter(e=>e.kind==='Reverse selected').length,finishes:r.events.filter(e=>e.kind==='Headland turn started').length,finishingRaises:r.events.filter(e=>e.kind==='Raise requested'&&e.phase==='Finishing headland').length,articulation:r.metrics.maxArticulation};});
assert(state.complete);assert(state.ix>0);assert(state.reverse&&state.forward&&state.controls);assert(state.turnRequests>8);assert(state.finishes>8);assert.equal(state.finishes,state.finishingRaises);console.log(JSON.stringify(state));assert(await page.locator('#play').isEnabled());
await page.locator('#timeline').evaluate((el,ix)=>{el.value=ix;el.dispatchEvent(new Event('input'));},state.ix);
assert.match(await page.locator('#state').textContent(),/Reversing/);
await page.screenshot({path:'out/turnbench-cp-finishing-row.png'});
await page.locator('#info').click();assert.match(await page.locator('#provenance').textContent(),/Runtime parity is incomplete/);assert.deepEqual(errors,[]);
console.log('PASS PW diagnostic playback executes sharp corner reverse/forward legs and runtime controls; default conservative boundary rejection and parity disclosure retained.');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exit(1);});
