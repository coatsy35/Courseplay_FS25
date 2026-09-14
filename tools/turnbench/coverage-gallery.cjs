// Capture completed coverage for the long-pike comparison fixtures.
const fs = require('node:fs');
const {chromium} = require('C:/Users/danco/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const directory = 'out/turn-coverage-gallery';
fs.mkdirSync(directory, {recursive:true});
(async () => {
  const browser = await chromium.launch({headless:true,args:['--disable-gpu']});
  const records = fs.existsSync(`${directory}/results.json`) ? JSON.parse(fs.readFileSync(`${directory}/results.json`,'utf8')) : [];
  try {
    const page = await browser.newPage({viewport:{width:1600,height:1100}});
    page.setDefaultTimeout(240000);
    await page.goto('http://127.0.0.1:56514/?mode=aligned');
    await page.waitForFunction(() => result && !document.getElementById('run').disabled);
    for (const [preset,title,headlands] of [['drill12','12 m trailed drill',6],['plough','PW 100-12 / 5.6 m',9],['drill','6 m trailed drill',9]]) {
      await page.evaluate(preset=>{document.getElementById('preset').value=preset;document.getElementById('preset').dispatchEvent(new Event('change',{bubbles:true}));},preset);
      for (const [angle,side] of [[10,1],[20,1],[25,1],[30,1],[35,1],[40,1],[45,1],[45,-1]]) {
        if (records.some(r=>r.title===title && r.angle===angle && r.direction===(side===1?'short-to-long':'long-to-short'))) continue;
        await page.evaluate(({angle,side,headlands}) => {
          for (const [id,value] of Object.entries({pattern:'aligned',fieldLength:500,fieldWidth:400,headlandRows:headlands,fieldShape:'sloping',edgeAngle:angle,slopeSide:'left',side,entryRows:7})) {
            document.getElementById(id).value=String(value);
            document.getElementById(id).dispatchEvent(new Event('change',{bubbles:true}));
          }
          document.getElementById('whole-field').checked=true;
          document.getElementById('alignedPattern').checked=true;
          document.getElementById('gaps').checked=true;
          updateControls();
        },{angle,side,headlands});
        const response=page.waitForResponse(r=>r.url().endsWith('/api/simulate')&&r.request().method()==='POST');
        await page.locator('#run').click();
        if ((await response).status()!==200) throw new Error('Simulation request failed');
        await page.waitForFunction(()=>!document.getElementById('run').disabled);
        const data=await page.evaluate(()=> {
          chooseView(result.experiment?'experiment':'baseline');
          frame=selected().frames.length-1;fit();draw();
          return {feasible:result.planner.feasible,metrics:selected().metrics,scenario:result.scenario,
            planner:result.planner,frameCount:selected().frames.length,gapCount:selected().gaps.length};
        });
        const direction=side===1?'short-to-long':'long-to-short';
        const file=`${preset}-${angle}-${direction}.png`;
        await page.screenshot({path:`${directory}/${file}`});
        records.push({title,angle,direction,file,...data});
        fs.writeFileSync(`${directory}/results.json`,JSON.stringify(records,null,2));
        console.log(JSON.stringify({title,angle,direction,...data.metrics,feasible:data.feasible}));
      }
    }
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
