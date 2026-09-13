/* Real browser matrix: field controls must stay usable when shape changes. */
const assert = require("node:assert/strict");
const path = require("node:path");
const { chromium } = require(
  process.argv[3] || process.env.PLAYWRIGHT_MODULE || "playwright",
);
const url = process.argv[2] || "http://127.0.0.1:8765";
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
    page.setDefaultTimeout(120000);
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(url);
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
    await page
      .locator(".settings-body details")
      .evaluateAll((ns) =>
        ns.forEach((n) => (n.removeAttribute("name"), (n.open = true))),
      );
    async function prepare() {
      const pending = page.waitForResponse((r) =>
        r.url().endsWith("/api/simulate"),
      );
      await page.locator("#run").click();
      const response = await pending;
      const data = await response.json();
      assert.equal(response.status(), 200, JSON.stringify(data));
      await page.waitForFunction(
        () => !document.getElementById("run").disabled,
      );
      return data;
    }
    async function playToEnd(passes) {
      assert(await page.locator("#play").isEnabled());
      await page.locator("#play").click();
      await page.waitForFunction(
        () => document.getElementById("time").textContent !== "0.0 s",
      );
      await page.locator("#play").click();
      await page.locator("#step").click();
      await page.locator("#timeline").evaluate((el) => {
        el.value = el.max;
        el.dispatchEvent(new Event("input"));
      });
      assert.match(
        await page.locator("#state").textContent(),
        new RegExp(`Pass ${passes}/${passes}.*Finished`),
      );
      await page.locator("#restart").click();
      assert.equal(await page.locator("#time").textContent(), "0.0 s");
    }
    for (const shape of ["rectangle", "irregular"]) {
      for (const [preset, width, heads, mounted] of [
        ["plough", 5.6, 10, false],
        ["drill4", 4, 14, false],
        ["drill", 6, 10, false],
        ["drill12", 12, 6, false],
        ["custom", 7, 10, false],
        ["custom", 7, 10, true],
      ]) {
        await page.locator("#preset").selectOption(preset);
        await page.locator("#pattern").selectOption("field");
        await page.locator("#fieldShape").selectOption(shape);
        if (shape === "irregular")
          await page.locator("#irregularInset").fill("23");
        assert.equal(await page.locator("#pattern").inputValue(), "field");
        if (preset === "custom")
          await page
            .locator("#attachment")
            .selectOption(mounted ? "mounted" : "trailed");
        for (const [id, value] of Object.entries({
          width,
          headlandRows: heads,
          passes: 4,
          fieldWidth: 400,
          fieldLength: 400,
          extension: 0,
        }))
          await page.locator("#" + id).fill(String(value));
        await page.locator("#enforceBoundary").check();
        if (shape === "irregular") {
          await page.locator("#roundHeadlands").fill("1");
          if (preset === "drill4") {
            const pending = page.waitForResponse((r) =>
              r.url().endsWith("/api/simulate"),
            );
            await page.locator("#run").click();
            const failure = await pending;
            assert.equal(failure.status(), 400);
            assert.match((await failure.json()).error, /CP generated only/);
            await page.waitForFunction(
              () => !document.getElementById("run").disabled,
            );
            assert(await page.locator("#play").isDisabled());
            await page.locator("#roundHeadlands").fill("0");
          }
        }
        for (const id of [
          "passes",
          "fieldWidth",
          "fieldLength",
          "rowPattern",
          "headlandRows",
          "raiseLate",
          "raiseSeconds",
          "lowerEarly",
          "lowerSeconds",
          "lookahead",
          "tight",
          "tightDistance",
          "extension",
          "side",
          "speed",
          "steering",
        ])
          assert(await page.locator("#" + id).isEnabled(), `${shape}: ${id}`);
        const data = await prepare();
        assert(
          data.baseline.metrics.complete,
          `${shape} ${preset}: ${data.baseline.reason}`,
        );
        assert.equal(data.baseline.scenario.mounted, mounted);
        assert.equal(data.baseline.scenario.width, width);
        assert.equal(data.baseline.field.rows.length, 4);
        await playToEnd(4);
        console.log(
          `PASS ${shape}: ${preset} ${width} m ${mounted ? "mounted" : "trailed"}`,
        );
      }
      await page.locator("#pattern").selectOption("field");
      await page.locator("#preset").selectOption("drill");
      await page.locator("#headlandRows").fill("10");
      await page.locator("#passes").fill("6");
      for (const pattern of ["alternating", "lands", "racetrack"]) {
        await page.locator("#rowPattern").selectOption(pattern);
        assert.equal(
          await page.locator("#rowsPerLand").isEnabled(),
          pattern === "lands",
        );
        assert.equal(
          await page.locator("#circles").isEnabled(),
          pattern === "racetrack",
        );
        if (pattern === "lands") await page.locator("#rowsPerLand").fill("4");
        if (pattern === "racetrack") await page.locator("#circles").fill("2");
        const data = await prepare();
        assert(
          data.baseline.metrics.complete,
          `${shape} ${pattern}: ${data.baseline.reason}`,
        );
        await playToEnd(6);
        console.log(`PASS ${shape}: ${pattern}, six passes`);
      }
      await page.locator("#rowPattern").selectOption("alternating");
    }
    // Exercise the irregular-specific angle and comparison controls together.
    await page.locator("#passes").fill("3");
    await page.locator("#rowAngle").fill("25");
    await page.locator("#side").selectOption("-1");
    await page.locator("#raiseLate").uncheck();
    await page.locator("#raiseSeconds").fill("0.5");
    await page.locator("#lowerEarly").uncheck();
    await page.locator("#lowerSeconds").fill("1");
    await page.locator("#tight").uncheck();
    await page.locator("#extension").fill("2");
    const comparison = await prepare();
    assert(comparison.experiment);
    for (const view of ["baseline", "experiment", "overlay"]) {
      await page.locator(`[data-view="${view}"]`).click();
      await playToEnd(3);
    }
    await page.screenshot({
      path: path.resolve(__dirname, "../../out/turnbench-irregular-motion.png"),
    });
    await page.locator("#play").click();
    await page.locator("#passes").fill("4");
    assert(await page.locator("#play").isDisabled());
    assert.match(
      await page.locator("#configuration-status").textContent(),
      /Settings changed/,
    );
    assert.deepEqual(errors, []);
    console.log("All field control and playback checks passed.");
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
