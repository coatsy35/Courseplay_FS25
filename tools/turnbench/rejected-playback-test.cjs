const assert=require('node:assert/strict');
const {chromium}=require('C:/Users/danco/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
(async()=>{const browser=await chromium.launch({headless:true,args:['--disable-gpu']});try{
const page=await browser.newPage({viewport:{width:1600,height:1000}});page.setDefaultTimeout(120000);const errors=[];page.on('pageerror',e=>errors.push(e.message));
await page.goto('http://127.0.0.1:56514');await page.waitForFunction(()=>!document.getElementById('run').disabled);
assert.match(await page.locator('#config-toggle').textContent(),/pw10012.xml/);
for (const [id,value] of Object.entries({width:5.6,length:11.1,hitch:1.9,front:4.6,back:18.3,lowerSeconds:2.5,radius:9})) {
  assert.equal(Number(await page.locator('#'+id).inputValue()),value,id);
}
assert.equal(await page.evaluate(()=>presets.plough.radius),undefined,'PW radius must come from CP override');
assert.equal(await page.evaluate(()=>Number(document.getElementById('hitch').value)+Number(document.getElementById('length').value)),13);
assert.equal(await page.locator('#show-turns').isChecked(),false);
assert(await page.evaluate(()=>result.baseline.coursePath.length>100));
await page.screenshot({path:'out/turnbench-course-only.png'});
await page.locator('#show-turns').check();
assert(await page.locator('#play').isEnabled(),'Display filter must not invalidate configuration');
await page.locator('#show-turns').uncheck();
assert(await page.locator('#play').isEnabled());
assert.match(await page.locator('#play').textContent(),/Start run/);
assert.equal(await page.locator('#shortfall').textContent(),'');
await page.locator('#show-clearance').check();
assert.match(await page.locator('#shortfall').textContent(),/Estimated footprint/);
await page.locator('#show-clearance').uncheck();
assert(await page.locator('#error').isHidden());
await page.locator('#play').click();
await page.waitForFunction(()=>frame>0);
await page.locator('#play').click();
const verdict=await page.evaluate(()=>({blocked:result.baseline.blocked,complete:result.baseline.metrics.complete,segments:result.baseline.rejectedSegments.some(s=>s.reverse)}));
assert(!verdict.blocked);assert(verdict.complete);assert(verdict.segments);
// Test rejected sloping-field playback with rounding disabled, too.
await page.locator('#fieldShape').selectOption('sloping');
const response=page.waitForResponse(r=>r.url().endsWith('/api/simulate'));
await page.locator('#run').click();assert.equal((await response).status(),200);
await page.waitForFunction(()=>!document.getElementById('run').disabled);
assert.equal(await page.locator('#roundHeadlands').inputValue(),'0');
assert(await page.locator('#play').isEnabled());
await page.locator('#play').click();await page.waitForFunction(()=>frame>0);await page.locator('#play').click();
const state=await page.evaluate(()=>{const r=result.baseline;const ix=r.frames.findIndex(f=>f.phase==='Headland corner'&&f.reverse);return {complete:r.metrics.complete,ix,reverse:r.path.some(w=>w.phase==='Headland corner'&&w.reverse),forward:r.path.some(w=>w.phase==='Headland corner'&&!w.reverse),controls:r.path.some(w=>w.changeWhenAligned),turnRequests:r.events.filter(e=>e.kind==='Reverse selected').length,finishes:r.events.filter(e=>e.kind==='Headland turn started').length,finishingRaises:r.events.filter(e=>e.kind==='Raise requested'&&e.phase==='Finishing headland').length,articulation:r.metrics.maxArticulation,connectorArticulation:Math.max(...r.frames.filter(f=>f.phase==='Connecting turn').map(f=>Math.abs(Math.atan2(Math.sin(f.theta-f.phi),Math.cos(f.theta-f.phi))*180/Math.PI))),connectorReverses:r.frames.some(f=>f.phase==='Connecting turn'&&f.reverse)};});
assert(state.complete);assert(state.connectorArticulation<90);assert(!state.connectorReverses);assert(state.ix>0);assert(state.reverse&&state.forward&&state.controls);assert(state.turnRequests>8);assert(state.finishes>8);assert.equal(state.finishes,state.finishingRaises);console.log(JSON.stringify(state));assert(await page.locator('#play').isEnabled());
await page.locator('#timeline').evaluate((el,ix)=>{el.value=ix;el.dispatchEvent(new Event('input'));},state.ix);
assert.match(await page.locator('#state').textContent(),/Reversing/);
await page.screenshot({path:'out/turnbench-sloping-course-only.png'});
await page.locator('#show-turns').check();
await page.screenshot({path:'out/turnbench-rejected-playback.png'});
await page.locator('#info').click();assert.match(await page.locator('#provenance').textContent(),/Runtime parity is incomplete/);assert.deepEqual(errors,[]);
console.log('PASS default PW override, rejected rectangle/sloping playback, zero rounded headlands, reverse display, separate boundary diagnostics and no browser errors.');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exit(1);});
