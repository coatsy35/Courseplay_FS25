const assert = require("node:assert/strict");
const { chromium } = require(
  process.argv[3] || process.env.PLAYWRIGHT_MODULE || "playwright",
);
(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ["--disable-gpu"],
  });
  try {
    const page = await browser.newPage({
      viewport: { width: 1440, height: 1050 },
    });
    page.setDefaultTimeout(120000);
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(process.argv[2] || "http://127.0.0.1:8765");
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    assert.equal(await page.locator(".settings-group[open]").count(), 1);
    for (let i = 0; i < 6; i++) {
      const g = page.locator(".settings-group").nth(i);
      await g.locator(":scope > summary").click();
      assert.equal(await page.locator(".settings-group[open]").count(), 1);
    }
    await page
      .locator(".settings-group")
      .nth(1)
      .locator(":scope > summary")
      .click();
    await page.locator("#fieldShape").selectOption("sloping");
    assert.equal(await page.locator("#rowAngle").inputValue(), "0");
    assert(!(await page.locator("#autoRowAngle").isChecked()));
    await page.locator("#pattern").selectOption("layout");
    await page.locator("#fieldWidth").fill("400");
    await page.locator("#fieldLength").fill("300");
    await page.locator("#headlandRows").fill("4");
    async function run() {
      const response = page.waitForResponse((r) =>
        r.url().endsWith("/api/simulate"),
      );
      await page.locator("#run").click();
      assert.equal((await response).status(), 200);
      await page.waitForFunction(
        () => !document.getElementById("run").disabled,
      );
      return page.evaluate(() => ({
        scenario: result.baseline.scenario,
        rows: result.baseline.layout.rows,
      }));
    }
    let r = await run();
    assert.equal(r.scenario.rowAngle, 90);
    assert(r.rows.length > 4);
    for (const row of r.rows)
      assert(Math.abs(row[0][0] - row.at(-1)[0]) < 0.01);
    await page.locator("#rotateRows").click();
    assert.equal(await page.locator("#rowAngle").inputValue(), "90");
    r = await run();
    assert.equal(r.scenario.rowAngle, 0);
    for (const row of r.rows)
      assert(Math.abs(row[0][1] - row.at(-1)[1]) < 0.01);
    await page.locator("#autoRowAngle").check();
    assert((await run()).scenario.autoRowAngle);
    await page.locator("#useBaseline").check();
    assert(await page.locator("#rowAngle").isDisabled());
    assert(await page.locator("#autoRowAngle").isDisabled());
    assert((await run()).scenario.useBaseline);
    await page.locator("#useBaseline").uncheck();
    await page.locator("#autoRowAngle").uncheck();
    r = await run();
    const pending = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page
      .locator("#setup-file")
      .setInputFiles({
        name: "angles.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify({ scenario: r.scenario })),
      });
    assert.equal((await pending).status(), 200);
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    assert.equal(await page.locator("#rowAngle").inputValue(), "90");
    const width = await page
      .locator(".settings-scroll")
      .evaluate((e) => [e.scrollWidth, e.clientWidth]);
    assert(width[0] <= width[1] + 1, JSON.stringify(width));
    assert.deepEqual(errors, []);
    await page.screenshot({ path: "out/turnbench-direction-accordion.png" });
    console.log(
      "PASS exclusive accordion, vertical/horizontal CP angles, automatic and baseline overrides, saved-angle round trip and no sideways overflow",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
