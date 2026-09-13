const assert=require('node:assert/strict');
const {chromium}=require('C:/Users/danco/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
(async()=>{
  const browser=await chromium.launch({headless:true,args:['--disable-gpu']});
  try {
    const page=await browser.newPage(); page.setDefaultTimeout(180000);
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto('http://127.0.0.1:56514/?mode=aligned');
    await page.waitForFunction(()=>result&&!document.getElementById('run').disabled);
    assert.equal(await page.locator('#pattern').inputValue(),'aligned');
    assert.equal(await page.locator('#radius').inputValue(),'9');
    assert.equal(await page.evaluate(()=>result.planner.feasible),true);
    const saved=await page.evaluate(()=>JSON.stringify(result));
    await page.locator('#radius').evaluate(el=>{
      for(let node=el.parentElement;node;node=node.parentElement)
        if(node.tagName==='DETAILS')node.open=true;
    });
    await page.locator('#radius').fill('12');
    await page.locator('#setup-file').setInputFiles({name:'aligned-setup.json',mimeType:'application/json',buffer:Buffer.from(saved)});
    assert.equal(await page.locator('#error').isVisible(),false,await page.locator('#error').textContent());
    await page.waitForFunction(()=>!document.getElementById('run').disabled&&document.getElementById('radius').value==='9');
    assert.equal(await page.locator('#pattern').inputValue(),'aligned');
    assert.equal(await page.locator('#entryRows').inputValue(),'1');
    assert.equal(await page.locator('#error').isVisible(),false);
    assert.equal(await page.evaluate(()=>result.planner.feasible),true);
    assert.deepEqual(errors,[]);
    console.log('Aligned-mode link and setup round-trip passed');
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exit(1);});
