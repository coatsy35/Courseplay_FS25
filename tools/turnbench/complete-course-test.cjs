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
      viewport: { width: 1440, height: 1000 },
    });
    page.setDefaultTimeout(120000);
    const errors = [];
    const inspector = await page.context().newCDPSession(page);
    await inspector.send("Network.enable", {
      maxTotalBufferSize: 256 * 1024 * 1024,
      maxResourceBufferSize: 128 * 1024 * 1024,
    });
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(process.argv[2] || "http://127.0.0.1:8765");
    await page.waitForFunction(
      () =>
        document.getElementById("configuration-status").textContent !==
          "Preparing configuration…" &&
        !document.getElementById("run").disabled,
    );
    await page
      .locator("details")
      .evaluateAll((ns) =>
        ns.forEach((n) => (n.removeAttribute("name"), (n.open = true))),
      );
    await page.locator("#pattern").selectOption("course");
    await page.locator("#preset").selectOption("custom");
    await page.locator("#attachment").selectOption("mounted");
    for (const [id, value] of Object.entries({
      width: 6,
      radius: 9,
      front: 3,
      back: 4,
      clearance: 5,
      fieldWidth: 220,
      fieldLength: 300,
      headlandRows: 8,
      roundHeadlands: 8,
      fieldMargin: 6,
      extension: 0,
    }))
      await page.locator("#" + id).fill(String(value));
    async function run() {
      const pending = page.waitForResponse((r) =>
        r.url().endsWith("/api/simulate"),
      );
      await page.locator("#run").click();
      const response = await pending;
      assert.equal(response.status(), 200);
      await page.waitForFunction(
        () => !document.getElementById("run").disabled,
      );
      return page.evaluate(() => ({
        baseline: {
          scenario: result.baseline.scenario,
          metrics: result.baseline.metrics,
          blocked: result.baseline.blocked,
          field: { islands: result.baseline.field.islands },
          fleet: result.baseline.fleet.map((v) => ({
            metrics: v.metrics,
            blocked: v.blocked,
          })),
        },
      }));
    }
    let data = await run();
    assert(!data.baseline.blocked);
    assert(data.baseline.metrics.complete);
    assert(await page.locator("#play").isEnabled());
    await page.locator("#rate").selectOption("4");
    await page.locator("#play").click();
    await page.waitForTimeout(1500);
    await page.locator("#play").click();
    const seconds = parseFloat(await page.locator("#time").textContent());
    assert(
      seconds >= 3 && seconds < 10,
      `Playback time ${seconds} s should follow 4× real time`,
    );
    await page.screenshot({ path: "out/turnbench-complete-course.png" });
    // Inspect diagnostic courses without suppressing the boundary setting implicitly.
    await page.locator("#enforceBoundary").uncheck();
    await page.locator("#headlandRows").fill("3");
    await page.locator("#vehicles").fill("2");
    await page.locator("#vehicleIndex").fill("2");
    await page.locator("#headlandFirst").selectOption("centre");
    data = await run();
    assert.equal(data.baseline.fleet.length, 2);
    assert(data.baseline.fleet.every((v) => v.metrics.complete));
    assert(
      (await page.locator("#course-status").textContent()).includes(
        "Vehicle 2: route completed",
      ),
    );
    const imported = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#setup-file").setInputFiles({
      name: "fleet.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(data)),
    });
    assert.equal((await imported).status(), 200);
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    assert.equal(await page.locator("#pattern").inputValue(), "course");
    assert.equal(await page.locator("#vehicleIndex").inputValue(), "2");
    await page.locator("#vehicles").fill("1");
    await page.locator("#islandCount").fill("1");
    await page.locator("#islandSize").fill("35");
    await page.locator("#rowPattern").selectOption("spiral");
    await page.locator("#spiralFromInside").check();
    data = await run();
    assert.equal(data.baseline.field.islands.length, 1);
    assert(data.baseline.metrics.complete);
    await page.locator("#rowPattern").selectOption("alternating");
    await page.locator("#rowsToSkip").fill("2");
    data = await run();
    assert.equal(data.baseline.scenario.rowsToSkip, 2);
    assert(data.baseline.metrics.complete);
    await page.screenshot({ path: "out/turnbench-island-course.png" });
    assert.deepEqual(errors, []);
    console.log(
      "Complete-course browser checks passed: safe headland playback, elapsed time, fleet, saved setup, islands, spirals and skipped rows.",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
