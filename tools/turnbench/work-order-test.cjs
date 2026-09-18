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
    const page = await browser.newPage();
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
    await page.locator("#pattern").selectOption("layout");
    await page.locator("#headlandRows").fill("3");
    for (const shape of ["rectangle", "irregular"]) {
      await page.locator("#fieldShape").selectOption(shape);
      const starts = [];
      for (const order of ["headland", "centre"]) {
        await page.locator("#headlandFirst").selectOption(order);
        const pending = page.waitForResponse((r) =>
          r.url().endsWith("/api/simulate"),
        );
        await page.locator("#run").click();
        const response = await pending;
        assert.equal(response.status(), 200);
        const data = await response.json();
        assert.equal(
          data.baseline.scenario.headlandFirst,
          order === "headland",
        );
        starts.push(data.baseline.paths[0][0]);
        await page.waitForFunction(
          () => !document.getElementById("run").disabled,
        );
        const imported = page.waitForResponse((r) =>
          r.url().endsWith("/api/simulate"),
        );
        await page.locator("#setup-file").setInputFiles({
          name: "order.json",
          mimeType: "application/json",
          buffer: Buffer.from(JSON.stringify(data)),
        });
        assert.equal((await imported).status(), 200);
        await page.waitForFunction(
          () => !document.getElementById("run").disabled,
        );
        assert.equal(await page.locator("#headlandFirst").inputValue(), order);
      }
      assert.notDeepEqual(starts[0], starts[1]);
      console.log(
        `PASS ${shape}: both work orders and saved-setup restoration`,
      );
    }
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
