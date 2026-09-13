const assert = require("node:assert/strict");
const { chromium } = require(process.argv[3] || "playwright");
(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ["--disable-gpu"],
  });
  try {
    const page = await browser.newPage({
      viewport: { width: 1600, height: 1100 },
    });
    page.setDefaultTimeout(120000);
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(process.argv[2]);
    await page.waitForFunction(
      () =>
        typeof result !== "undefined" &&
        !document.getElementById("run").disabled,
    );
    assert.equal(await page.locator("#pattern").inputValue(), "course");
    assert.equal(await page.locator("#roundHeadlands").inputValue(), "0");
    assert(await page.locator("#passes-label").isHidden());
    await page
      .locator("details")
      .evaluateAll((ns) =>
        ns.forEach((n) => (n.removeAttribute("name"), (n.open = true))),
      );
    await page.locator("#preset").selectOption("custom");
    await page.locator("#attachment").selectOption("mounted");
    await page.locator("#enforceBoundary").uncheck(); // Isolate course ordering from footprint calibration.
    for (const [id, value] of Object.entries({
      width: 6,
      radius: 9,
      front: 3,
      back: 4,
      clearance: 5,
      fieldWidth: 300,
      fieldLength: 240,
      headlandRows: 4,
      fieldMargin: 3,
    }))
      await page.locator("#" + id).fill(String(value));
    async function run() {
      const pending = page.waitForResponse((r) =>
        r.url().endsWith("/api/simulate"),
      );
      await page.locator("#run").click();
      assert.equal((await pending).status(), 200);
      await page.waitForFunction(
        () => !document.getElementById("run").disabled,
      );
      return page.evaluate(() => ({
        complete: result.baseline.metrics.complete,
        firstHeadland: !!result.baseline.path[0]?.headland,
        scenario: result.baseline.scenario,
      }));
    }
    for (const shape of ["rectangle", "irregular", "sloping"]) {
      await page.locator("#fieldShape").selectOption(shape);
      for (const first of ["headland", "centre"]) {
        await page.locator("#headlandFirst").selectOption(first);
        for (const direction of ["start", "end"]) {
          await page.locator("#courseDirection").selectOption(direction);
          const r = await run();
          assert(r.complete, `${shape} ${first} ${direction} incomplete`);
          assert.equal(
            r.firstHeadland,
            (first === "headland") !== (direction === "end"),
          );
          assert.equal(r.scenario.roundHeadlands, 0);
          assert(await page.locator("#play").isEnabled());
          await page.locator("#play").click();
          await page.waitForFunction(
            () => document.getElementById("time").textContent !== "0.0 s",
          );
          await page.locator("#play").click();
          await page.locator("#timeline").evaluate((el) => {
            el.value = el.max;
            el.dispatchEvent(new Event("input"));
          });
          assert.match(await page.locator("#state").textContent(), /Finished/);
          console.log(
            `PASS full field ${shape}, ${first} first, from ${direction}, zero rounded headlands`,
          );
        }
      }
    }
    await page.locator("#fieldShape").selectOption("irregular");
    await page.locator("#irregularInset").fill("42");
    await page.locator("#courseDirection").selectOption("start");
    await page.locator("#headlandFirst").selectOption("centre");
    assert((await run()).complete);
    const saved = await page.evaluate(() => ({
      scenario: result.baseline.scenario,
    }));
    const pending = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#setup-file").setInputFiles({
      name: "full-field.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(saved)),
    });
    assert.equal((await pending).status(), 200);
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    assert.equal(await page.locator("#irregularInset").inputValue(), "42");
    assert.equal(await page.locator("#headlandFirst").inputValue(), "centre");
    await page
      .locator(".settings-group")
      .evaluateAll((ns) => ns.forEach((n, i) => (n.open = i === 1)));
    await page.locator(".settings-scroll").evaluate((el) => (el.scrollTop = 0));
    await page.screenshot({ path: "out/turnbench-full-field-controls.png" });
    await page.locator("#pattern").selectOption("field");
    assert(await page.locator("#passes").isVisible());
    assert(await page.locator("#passes").isEnabled());
    assert(await page.locator("#course-direction-label").isHidden());
    assert.deepEqual(errors, []);
    console.log(
      "PASS inset adjustment, saved settings and separate pass-test controls",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
