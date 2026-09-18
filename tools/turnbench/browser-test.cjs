/* Visual and interaction checks against a running loopback server. */
const assert = require("node:assert/strict");
const path = require("node:path");
const { chromium } = require(
  process.argv[3] || process.env.PLAYWRIGHT_MODULE || "playwright",
);
const url = process.argv[2] || "http://127.0.0.1:8765";
const out = path.resolve(__dirname, "../../out");

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ["--disable-gpu"],
  });
  try {
    const errors = [];
    const page = await browser.newPage({
      viewport: { width: 1440, height: 1050 },
    });
    page.on("pageerror", (e) => errors.push(e.message));
    const fieldResponse = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.goto(url);
    await page.waitForFunction(
      () =>
        document.getElementById("configuration-status").textContent !==
          "Preparing configuration…" &&
        !document.getElementById("run").disabled,
    );
    assert.equal(await page.locator("#error").isVisible(), false);
    assert.equal(await page.locator(".settings-group").count(), 6);
    assert.equal(await page.locator(".settings-group[open]").count(), 1);
    assert.equal(
      await page
        .locator("#run")
        .textContent()
        .then((t) => t.trim()),
      "Set configuration",
    );
    await page.screenshot({ path: path.join(out, "turnbench-settings.png") });
    await page
      .locator(".settings-group")
      .evaluateAll((nodes) =>
        nodes.forEach((n) => (n.removeAttribute("name"), (n.open = true))),
      );
    const footerBefore = await page.locator("#run").boundingBox();
    await page
      .locator(".settings-scroll")
      .evaluate((el) => (el.scrollTop = el.scrollHeight));
    const footerAfter = await page.locator("#run").boundingBox();
    assert.equal(footerBefore.y, footerAfter.y);
    assert(footerAfter.y + footerAfter.height <= 1050);
    await page.locator(".settings-scroll").evaluate((el) => (el.scrollTop = 0));
    const fieldRun = await (await fieldResponse).json();
    assert.equal(fieldRun.baseline.completeCourse, true);
    assert.equal(fieldRun.baseline.scenario.roundHeadlands, 0);
    assert(await page.locator("#passes-label").isHidden());
    assert.equal(fieldRun.baseline.scenario.headland, 50.4);
    assert.equal(fieldRun.baseline.scenario.width, 5.6);
    assert(await page.locator("#fieldWidth").isEnabled());
    await page.waitForFunction(
      () => document.querySelectorAll("#config-implement option").length > 100,
    );
    assert(await page.locator("#config-search").isHidden());
    const extraTab = page.locator('[data-view="experiment"]');
    assert(await extraTab.isDisabled());
    assert.match(await extraTab.getAttribute("title"), /above 0 m/);
    assert.equal(
      await extraTab.evaluate((el) => getComputedStyle(el).cursor),
      "not-allowed",
    );
    await page.locator("#pattern").selectOption("field");
    await page.locator("#extension").fill("20");
    const rejectedResponse = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#run").click();
    const rejected = (await (await rejectedResponse).json()).experiment;
    assert(rejected.blocked);
    assert(rejected.rejectedPath.length > 100);
    assert(rejected.rejectedEnvelopes.length > 0);
    assert(rejected.boundaryClearanceNeeded > 0);
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    await extraTab.click();
    assert(await page.locator("#play").isDisabled());
    assert.match(
      await page.locator("#shortfall").textContent(),
      /more boundary clearance/,
    );
    await page.locator('[data-view="overlay"]').click();
    assert(await page.locator("#play").isEnabled());
    assert.match(
      await page.locator("#shortfall").textContent(),
      /Extra clearance: Turn rejected/,
    );
    await page.screenshot({
      path: path.join(out, "turnbench-rejected-clearance.png"),
    });
    await page.locator('[data-view="baseline"]').click();
    await page.locator("#extension").fill("0");
    const resetResponse = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#run").click();
    await resetResponse;
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    await page.locator("#config-toggle").click();
    assert(await page.locator("#config-search").isVisible());
    const names = await page
      .locator("#config-implement option")
      .evaluateAll((nodes) =>
        nodes.slice(1).map((n) => n.textContent.split(" / ")[0]),
      );
    const sorter = new Intl.Collator("en-GB", {
      sensitivity: "base",
      numeric: true,
    });
    assert.deepEqual(names, [...names].sort(sorter.compare));
    await page.locator("#config-search").fill("PW100");
    assert.equal(await page.locator("#config-implement option").count(), 2);
    await page.locator("#config-search").press("Escape");
    assert(await page.locator("#config-search").isHidden());
    assert.match(await page.locator("#state").textContent(), /Pass 1\/4/);
    await page.locator("#timeline").evaluate((el) => {
      el.value = el.max;
      el.dispatchEvent(new Event("input"));
    });
    assert.match(await page.locator("#state").textContent(), /Pass 4\/4/);
    await page.screenshot({
      path: path.join(out, "turnbench-field-pattern.png"),
    });
    if (fieldRun.experiment)
      await page.locator('[data-view="overlay"]').click();
    await page.screenshot({
      path: path.join(out, "turnbench-field-overlay.png"),
    });
    // Saved field settings must restore pass count and both headlands.
    const fieldImported = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#setup-file").setInputFiles({
      name: "field.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(fieldRun)),
    });
    assert.equal((await fieldImported).status(), 200);
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    assert.equal(await page.locator("#pattern").inputValue(), "field");
    assert.equal(await page.locator("#passes").inputValue(), "4");
    await page.locator("#passes").fill("6");
    assert(await page.locator("#play").isDisabled());
    assert.match(
      await page.locator("#configuration-status").textContent(),
      /Settings changed/,
    );
    const sixResponse = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#run").click();
    assert.equal((await (await sixResponse).json()).baseline.turns.length, 5);
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    await page.locator("#pattern").selectOption("single");
    await page.locator("#pattern").selectOption("field");
    await page.locator("#preset").selectOption("drill");
    await page.locator("#headlandRows").fill("6");
    await page.locator("#extension").fill("15");
    await page.locator("#enforceBoundary").uncheck();
    // Retain the original forward-only comparison fixture explicitly.
    await page.locator("#allowReverse").uncheck();
    const singleResponse = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#run").click();
    await singleResponse;
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    await page.locator('[data-view="baseline"]').click();
    assert.equal(await page.locator("#state").textContent(), "Exit working");
    assert(await page.locator("#raiseLate").isChecked());
    assert.match(await page.locator("#events").innerText(), /Raise requested/);
    const pixels = await page.locator("canvas").evaluate((c) => {
      const data = c
        .getContext("2d")
        .getImageData(0, 0, c.width, c.height).data;
      let green = 0,
        red = 0;
      for (let i = 0; i < data.length; i += 4) {
        if (data[i + 1] > data[i] + 25) green++;
        if (data[i] > data[i + 1] + 25) red++;
      }
      return { green, red };
    });
    assert(pixels.green > 100 && pixels.red > 100, JSON.stringify(pixels));
    await page.getByRole("button", { name: "Restart", exact: true }).click();
    const image0 = await page.locator("canvas").evaluate((c) => c.toDataURL());
    await page
      .getByRole("button", { name: "Step forward", exact: true })
      .click();
    assert(
      (await page.locator("canvas").evaluate((c) => c.toDataURL())) !== image0,
      "Moving step must change canvas pixels",
    );
    await page.getByRole("button", { name: "Start run", exact: true }).click();
    const time0 = await page.locator("#time").textContent();
    await page.waitForFunction(
      (t) => document.getElementById("time").textContent !== t,
      time0,
    );
    await page.getByRole("button", { name: "Pause", exact: true }).click();
    await page.locator('[data-view="experiment"]').click();
    assert.equal(
      await page.locator("#metric-gap").textContent(),
      "0.00 m\u00b2",
    );
    assert.match(
      await page.locator("#shortfall").textContent(),
      /beyond headland/,
    );
    await page.locator('[data-view="overlay"]').click();
    await page.screenshot({ path: path.join(out, "turnbench-overlay.png") });
    await page.locator("#info").click();
    assert(await page.locator("#provenance").isVisible());
    assert.match(
      await page.locator("#hashes").textContent(),
      /WorkStartHandler/,
    );
    await page.locator("#close-info").click();
    const download = page.waitForEvent("download");
    await page.locator("#download").click();
    assert.equal(
      (await download).suggestedFilename(),
      "courseplay-turnbench-run.json",
    );
    await page.locator("#raiseLate").uncheck();
    await page.locator("#raiseSeconds").fill("0");
    const earlyRun = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#run").click();
    const earlyResult = await (await earlyRun).json();
    assert.equal(earlyResult.baseline.scenario.raiseLate, false);
    assert.equal(earlyResult.baseline.scenario.raiseSeconds, 0);
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    for (const type of ["reedsShepp", "headlandLoop"]) {
      await page.locator("#turnType").selectOption(type);
      assert(await page.locator("#raiseLate").isEnabled());
      const previewRun = page.waitForResponse((r) =>
        r.url().endsWith("/api/simulate"),
      );
      await page.locator("#run").click();
      const preview = await (await previewRun).json();
      assert.equal(preview.baseline.preview, false);
      assert.equal(preview.baseline.metrics.complete, true);
      if (type === "reedsShepp")
        assert(preview.baseline.path.some((w) => w.reverse));
      await page.waitForFunction(
        () => !document.getElementById("run").disabled,
      );
      await page.locator('[data-view="baseline"]').click();
      assert.equal(await page.locator("#metric-gap").textContent(), "--");
      assert(await page.locator("#play").isEnabled());
      await page.screenshot({ path: path.join(out, `turnbench-${type}.png`) });
    }
    await page.locator("#turnType").selectOption("dubins");
    assert(await page.locator("#raiseLate").isEnabled());
    await page.locator("#raiseLate").check();
    await page.locator("#raiseSeconds").fill("1");
    await page.locator("#preset").selectOption("entry");
    assert(await page.locator("#turnType").isDisabled());
    assert(await page.locator("#raiseLate").isDisabled());
    const rerun = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#run").click();
    assert.equal((await rerun).status(), 200);
    await page.waitForFunction(() =>
      document.getElementById("metric-gap").textContent.startsWith("41."),
    );
    assert(await page.locator('[data-view="experiment"]').isDisabled());
    assert.match(await page.locator("#events").innerText(), /45.0/);
    const saved = await page.request.post(url + "/api/simulate", {
      data: { extension: 10, width: 7 },
    });
    const imported = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#setup-file").setInputFiles({
      name: "saved-run.json",
      mimeType: "application/json",
      buffer: await saved.body(),
    });
    assert.equal((await imported).status(), 200);
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    assert.equal(await page.locator("#width").inputValue(), "7");
    assert.equal(await page.locator("#extension").inputValue(), "10");
    await page.locator("#preset").selectOption("entry");
    const entryAgain = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#run").click();
    await entryAgain;
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    await page.screenshot({ path: path.join(out, "turnbench-entry.png") });
    const blocked = await page.request.post(url + "/api/simulate", {
      headers: { Origin: "https://example.invalid" },
      data: {},
    });
    assert.equal(blocked.status(), 403);
    const invalid = await page.request.post(url + "/api/simulate", {
      data: { length: 0 },
    });
    assert.equal(invalid.status(), 400);
    // The real field generator handles the concave outline and each row pattern.
    await page.locator("#preset").selectOption("plough");
    assert.match(await page.locator("#implement-width").textContent(), /5.6 m/);
    await page.locator("#fieldShape").selectOption("irregular");
    assert.equal(await page.locator("#pattern").inputValue(), "single");
    await page.locator("#pattern").selectOption("layout");
    await page.locator("#headlandRows").fill("4");
    await page.locator("#fieldLength").fill("300");
    await page.locator("#fieldWidth").fill("250");
    for (const pattern of ["alternating", "lands", "racetrack"]) {
      await page.locator("#rowPattern").selectOption(pattern);
      const layoutResponse = page.waitForResponse((r) =>
        r.url().endsWith("/api/simulate"),
      );
      await page.locator("#run").click();
      const layout = await (await layoutResponse).json();
      assert.equal(layout.baseline.layout.headlands.length, 4);
      await page.waitForFunction(
        () => !document.getElementById("run").disabled,
      );
      assert(await page.locator("#play").isDisabled());
      assert.equal(await page.locator("#error").isVisible(), false);
      await page.screenshot({
        path: path.join(out, `turnbench-irregular-${pattern}.png`),
      });
    }
    const options = await page.locator("#config-implement option").count();
    assert(options > 100);
    await page.locator("#preset").selectOption("drill4");
    assert.match(await page.locator("#implement-width").textContent(), /4.0 m/);
    await page.locator("#preset").selectOption("drill12");
    assert.match(
      await page.locator("#implement-width").textContent(),
      /12.0 m/,
    );
    // A rejected request must clear the old image and measurements.
    await page.locator("#fieldShape").selectOption("rectangle");
    await page.locator("#pattern").selectOption("field");
    await page.locator("#preset").selectOption("custom");
    await page.locator("#attachment").selectOption("mounted");
    await page.locator("#width").fill("7");
    await page.locator("#fieldWidth").fill("400");
    const customResponse = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#run").click();
    const custom = (await (await customResponse).json()).baseline;
    assert.equal(custom.scenario.mounted, true);
    assert.equal(custom.scenario.width, 7);
    assert.equal(custom.field.east - custom.field.west, 400);
    assert.equal(custom.metrics.maxArticulation, 0);
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    // Exercise actual prepared runs, not just the preset labels.
    for (const [preset, width, headlands] of [
      ["drill4", 4, 14],
      ["drill12", 12, 9],
      ["custom", 6, 9],
    ]) {
      await page.locator("#preset").selectOption(preset);
      await page.locator("#headlandRows").fill(String(headlands));
      await page.locator("#fieldLength").fill("400");
      await page.locator("#passes").fill("6");
      await page.locator("#extension").fill("0");
      await page.locator("#enforceBoundary").check();
      const responsePromise = page.waitForResponse((r) =>
        r.url().endsWith("/api/simulate"),
      );
      await page.locator("#run").click();
      const response = await responsePromise;
      assert.equal(response.status(), 200);
      const run = (await response.json()).baseline;
      assert.equal(run.scenario.width, width);
      assert.equal(run.scenario.mounted, false);
      assert(!run.blocked, `${preset}: boundary rejected`);
      assert(run.metrics.complete, `${preset}: incomplete simulation`);
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
      assert.match(await page.locator("#state").textContent(), /Pass 6\/6/);
    }
    await page.locator("#headlandRows").fill("9");
    await page.locator("#fieldLength").fill("100");
    const failed = page.waitForResponse((r) =>
      r.url().endsWith("/api/simulate"),
    );
    await page.locator("#run").click();
    assert.equal((await failed).status(), 400);
    await page.waitForFunction(() => !document.getElementById("run").disabled);
    assert.equal(await page.locator("#metric-error").textContent(), "--");
    assert(await page.locator("#download").isDisabled());
    const mobile = await browser.newPage({
      viewport: { width: 390, height: 844 },
      deviceScaleFactor: 1,
    });
    mobile.on("pageerror", (e) => errors.push(e.message));
    await mobile.goto(url);
    await mobile.waitForFunction(
      () =>
        document.getElementById("configuration-status").textContent !==
          "Preparing configuration…" &&
        !document.getElementById("run").disabled,
    );
    assert(
      await mobile.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    );
    await mobile.screenshot({ path: path.join(out, "turnbench-mobile.png") });
    await mobile.locator("#run").scrollIntoViewIfNeeded();
    await mobile.screenshot({
      path: path.join(out, "turnbench-mobile-controls.png"),
    });
    const clipped = await mobile
      .locator("button,label")
      .evaluateAll((nodes) =>
        nodes
          .filter(
            (n) =>
              n.getBoundingClientRect().width &&
              n.scrollWidth > n.clientWidth + 2,
          )
          .map((n) => n.textContent),
      );
    assert.deepEqual(clipped, []);
    assert.deepEqual(errors, []);
    console.log(
      "Browser checks passed: exit controls, turn previews, canvas pixels, motion, comparison, events, export, security and mobile layout.",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
