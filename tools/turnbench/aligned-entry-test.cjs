const assert = require('node:assert/strict');
const {chromium} = require('C:/Users/danco/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');

(async () => {
  const browser = await chromium.launch({headless: true, args: ['--disable-gpu']});
  try {
    const page = await browser.newPage({viewport: {width: 1600, height: 1000}});
    page.setDefaultTimeout(180000);
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.goto('http://127.0.0.1:56514');
    await page.waitForFunction(() => result && !document.getElementById('run').disabled);
    const results = {};
    for (const [name, values] of [
      ['straight', {pattern:'aligned',fieldShape:'rectangle',headlandRows:9}],
      ['pike', {fieldShape:'sloping',edgeAngle:25,slopeSide:'left'}],
      ['short-to-long-pike', {entryRows:12}],
      ['large', {fieldShape:'rectangle',headlandRows:18,entryRows:1}],
      ['mounted-pike', {preset:'custom',attachment:'mounted',width:6,front:3,back:5,clearance:8,headlandRows:9,fieldShape:'sloping'}],
      ['drill-pike', {preset:'drill12',fieldWidth:400,headlandRows:6,fieldShape:'sloping'}],
    ]) {
      await page.evaluate(values => {
        for (const [id,value] of Object.entries(values)) {
          const el=document.getElementById(id); el.value=String(value);
          el.dispatchEvent(new Event('change',{bubbles:true}));
        }
      }, values);
      const response=page.waitForResponse(r=>r.url().endsWith('/api/simulate')&&r.request().method()==='POST');
      await page.locator('#run').click();
      assert.equal((await response).status(),200,name);
      await page.waitForFunction(()=>!document.getElementById('run').disabled);
      assert.equal(await page.locator('#error').isVisible(),false,await page.locator('#error').textContent());
      const data=await page.evaluate(()=>({planner:result.planner, metrics:result.experiment?.metrics,
        selected:view,scenario:result.baseline.scenario,blocked:result.experiment?.blocked,frames:result.experiment?.frames.length}));
      assert.equal(data.planner.feasible,true,JSON.stringify({name,...data}));
      assert.equal(data.selected,'experiment');
      assert.equal(data.metrics.entry.aligned,true);
      assert.equal(data.metrics.entry.lowered,true);
      assert.equal(data.metrics.headlandShortfall,0);
      assert.notEqual(data.blocked,true);
      assert.equal(await page.locator('#error').isVisible(),false);
      assert.equal(await page.locator('#shortfall').textContent(),'');
      assert.equal(await page.locator('#play').isEnabled(),true);
      await page.locator('#play').click();
      await page.waitForFunction(()=>frame>5);
      await page.locator('#play').click();
      await page.screenshot({path:`out/turnbench-aligned-${name}.png`});
      // Scrub to first working entry and inspect the visibly active implement.
      await page.evaluate(()=>{
        frame=selected().frames.findIndex(f=>f.phase!=='exit'&&f.lowered);
        draw();
      });
      await page.screenshot({path:`out/turnbench-aligned-${name}-entry.png`});
      results[name]=data.planner;
      assert.deepEqual(errors,[]);
    }
    assert.ok(results.large.approachLength>results.straight.approachLength);
    assert.ok(results.large.outgoingExtension>results.straight.outgoingExtension);
    console.log(JSON.stringify(results));
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exit(1);});
