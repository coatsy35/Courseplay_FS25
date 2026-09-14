const assert=require('node:assert/strict');
const fs=require('node:fs');
const {chromium}=require('C:/Users/danco/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
(async()=>{
  const browser=await chromium.launch({headless:true,args:['--disable-gpu']});
  try {
    const page=await browser.newPage({viewport:{width:1600,height:1000}});
    page.setDefaultTimeout(240000);
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto('http://127.0.0.1:56514/?mode=aligned&case=long-pike-12m');
    await page.waitForFunction(()=>result&&!document.getElementById('run').disabled);
    assert.equal(await page.locator('#fieldLength').inputValue(),'500');
    assert.equal(await page.locator('#fieldLength').isEnabled(),true);
    assert.equal(await page.locator('#width').inputValue(),'12');
    assert.equal(await page.locator('#entryRows').inputValue(),'7');
    await page.screenshot({path:'out/long-pike-500m-whole-field.png'});
    await page.locator('#whole-field').uncheck();
    const summaries=[];
    for(const [angle,side] of [[25,1],[10,1],[20,1],[30,1],[35,1],[40,1],[45,1],[45,-1]]) {
      if(angle!==25||side!==1) {
        await page.evaluate(({angle,side})=>{
          for(const [id,value] of [['edgeAngle',angle],['side',side]]) {
            document.getElementById(id).value=String(value);
            document.getElementById(id).dispatchEvent(new Event('change',{bubbles:true}));
          }
        },{angle,side});
        const response=page.waitForResponse(r=>r.url().endsWith('/api/simulate')&&r.request().method()==='POST');
        await page.locator('#run').click();
        assert.equal((await response).status(),200);
        await page.waitForFunction(()=>!document.getElementById('run').disabled);
      }
      const data=await page.evaluate(()=>({planner:result.planner,metrics:result.experiment?.metrics,
        skips:result.experiment?.field.skippedRowSegments.length,scenario:result.scenario}));
      assert.equal(data.planner.feasible,true,JSON.stringify({angle,side,...data}));
      assert.equal(data.skips,6);
      assert.equal(data.scenario.headlandRows,6);
      assert.equal(data.metrics.complete,true);
      assert.equal(data.metrics.entry.aligned,true);
      assert.equal(data.metrics.entry.lowered,true);
      assert.equal(data.metrics.headlandShortfall,0);
      assert.equal(data.metrics.missedArea,0);
      assert.equal(await page.locator('#error').isVisible(),false);
      assert.equal(await page.locator('#shortfall').textContent(),'');
      await page.locator('#play').click();await page.waitForFunction(()=>frame>5);await page.locator('#play').click();
      await page.evaluate(()=>{frame=selected().frames.findIndex(f=>f.phase!=='exit'&&f.lowered);draw();});
      await page.screenshot({path:`out/long-pike-${angle}-${side===1?'short-to-long':'long-to-short'}.png`});
      await page.evaluate(()=>{frame=selected().frames.length-1;document.getElementById('gaps').checked=true;draw();});
      await page.screenshot({path:`out/long-pike-${angle}-${side===1?'short-to-long':'long-to-short'}-worked.png`});
      assert.deepEqual(errors,[]);
      const summary={angle,direction:side===1?'short-to-long':'long-to-short',...data.planner,...data.metrics};
      summaries.push(summary);console.log(JSON.stringify(summary));
      fs.writeFileSync('out/long-pike-browser-results.json',JSON.stringify(summaries,null,2));
    }
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
