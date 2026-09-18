const assert = require("node:assert/strict");
const path = require("node:path");
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
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(process.argv[2] || "http://127.0.0.1:8765");
    await page.waitForFunction(
      () =>
        document.getElementById("configuration-status").textContent !==
          "Preparing configuration…" &&
        !document.getElementById("run").disabled,
    );
    await page
      .locator(".settings-group")
      .evaluateAll((ns) =>
        ns.forEach((n) => (n.removeAttribute("name"), (n.open = true))),
      );
    await page.locator("#pattern").selectOption("field");
    await page.locator("#preset").selectOption("drill");
    await page.locator("#fieldShape").selectOption("sloping");
    assert.equal(await page.locator("#pattern").inputValue(), "field");
    assert(await page.locator("#edgeAngle").isVisible());
    for (const [id, v] of Object.entries({
      fieldWidth: 400,
      fieldLength: 300,
      passes: 6,
      headlandRows: 10,
      roundHeadlands: 1,
    }))
      await page.locator("#" + id).fill(String(v));
    assert.equal(await page.locator("#rowAngle").inputValue(), "0");
    await page.locator("#rowAngle").fill("90"); // Horizontal fixture in CP compass degrees.
    let last;
    for (const side of ["left", "right"])
      for (const angle of [20, 30])
        for (const pattern of ["alternating", "lands", "racetrack"]) {
          await page.locator("#slopeSide").selectOption(side);
          await page.locator("#edgeAngle").fill(String(angle));
          await page.locator("#rowPattern").selectOption(pattern);
          const pending = page.waitForResponse((r) =>
            r.url().endsWith("/api/simulate"),
          );
          await page.locator("#run").click();
          const response = await pending;
          assert.equal(response.status(), 200);
          last = await response.json();
          assert(last.baseline.metrics.complete, last.baseline.reason);
          assert.equal(last.baseline.scenario.edgeAngle, angle);
          assert.equal(last.baseline.scenario.slopeSide, side);
          assert.equal(last.baseline.scenario.rowAngle, 0);
          await page.waitForFunction(
            () => !document.getElementById("run").disabled,
          );
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
          assert.match(
            await page.locator("#state").textContent(),
            /Pass 6\/6.*Finished/,
          );
          console.log(`PASS sloping ${side} ${angle} degrees: ${pattern}`);
        }
    await page.screenshot({
      path: path.resolve(__dirname, "../../out/turnbench-sloping-field.png"),
    });
    const imported = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#setup-file").setInputFiles({
      name: "sloping.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(last)),
    });
    assert.equal((await imported).status(), 200);
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    assert.equal(await page.locator("#fieldShape").inputValue(), "sloping");
    assert.equal(await page.locator("#edgeAngle").inputValue(), "30");
    assert.equal(await page.locator("#slopeSide").inputValue(), "right");
    assert.equal(await page.locator("#rowAngle").inputValue(), "90");
    await page.locator("#pattern").selectOption("layout");
    const layout = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#run").click();
    const response = await layout;
    assert.equal(response.status(), 200);
    assert.equal((await response.json()).baseline.layout.boundary.length, 4);
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    await page.locator("#fieldShape").selectOption("rectangle");
    assert(await page.locator("#edge-angle-label").isHidden());
    assert.deepEqual(errors, []);
    console.log("PASS sloping field layout, saved setup and shape switching");
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
