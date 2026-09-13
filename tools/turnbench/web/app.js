"use strict";
const $ = (id) => document.getElementById(id);
const canvas = $("canvas"),
  ctx = canvas.getContext("2d");
let result = null,
  view = "baseline",
  frame = 0,
  playing = false,
  lastTime = 0;
let camera = { x: 0, z: 0, scale: 5 },
  size = { w: 0, h: 0 },
  drag = null;
const numeric = [
  "width",
  "length",
  "radius",
  "generatorRadius",
  "hitch",
  "front",
  "back",
  "clearance",
  "headland",
  "lowerSeconds",
  "raiseSeconds",
  "lookahead",
  "extension",
  "entryAngle",
  "tightDistance",
  "passes",
  "fieldLength",
  "headlandRows",
  "fieldWidth",
  "rowsPerLand",
  "circles",
  "rowAngle",
  "edgeAngle",
  "irregularInset",
  "reverseSpeed",
  "rowsToSkip",
  "fieldMargin",
  "startX",
  "startZ",
  "vehicles",
  "vehicleIndex",
  "islandCount",
  "islandSize",
  "islandHeadlands",
  "headlandOverlap",
  "roundHeadlands",
];
const presets = {
  drill: {
    width: 6,
    length: 9,
    radius: 9,
    hitch: 2,
    front: 11,
    back: 12,
    clearance: 13,
    headland: 38,
    lowerSeconds: 2,
    tightDistance: 0,
  },
  plough: {
    width: 5.6,
    // CP log, 13 September 2026: Challenger 55 + PW 100-12.
    // Effective tractor-to-steering-node distance is 13 m. Subtract
    // the 1.9 m hitch setback for the bench's single-trailer model.
    // The turning radius is supplied by the selected CP configuration.
    length: 11.1,
    hitch: 1.9,
    front: 4.6,
    back: 18.3,
    clearance: 20.7,
    headland: 48,
    lowerSeconds: 2.5,
    tightDistance: 1,
  },
  entry: {
    width: 6,
    length: 9,
    radius: 9,
    hitch: 2,
    front: 11,
    back: 12,
    clearance: 13,
    headland: 38,
    lowerSeconds: 2,
    tightDistance: 0,
  },
};
presets.drill4 = { ...presets.drill, width: 4 };
presets.drill12 = { ...presets.drill, width: 12 };
presets.custom = { ...presets.drill };
let catalogue = [];
let preparedConfiguration = null;
$("show-turns").onchange = () => {
  fit();
  draw();
};
$("show-clearance").onchange = () => {
  if (result) updateMetrics();
  fit();
  draw();
};
let configuring = false;
function refreshConfiguration() {
  const dirty = JSON.stringify(scenario()) !== preparedConfiguration;
  if (dirty || configuring || selected()?.preview) setPlaying(false);
  for (const id of ["play", "step", "restart", "timeline", "rate"])
    $(id).disabled =
      !result || dirty || configuring || Boolean(selected()?.preview);
  $("configuration-status").textContent = configuring
    ? "Preparing configuration…"
    : !result
      ? "Set your configuration to prepare a run."
      : dirty
        ? "Settings changed — set configuration to apply."
        : selected()?.blocked
          ? selected()?.diagnosticPlayback
            ? "Footprint check failed — Play diagnostic to inspect the turn. This does not confirm that it fits."
            : selected()?.completeCourse
              ? "Offline footprint check failed. Review the model diagnostics; this is not a headland-size recommendation."
              : "Modelled route does not fit. Adjust field margin, headlands or turn settings, then set configuration."
          : selected()?.preview
            ? "Configuration set. This view is a static preview."
            : "Configuration ready — press Start run below the field.";
}
function icons() {
  lucide.createIcons({ attrs: { "stroke-width": 1.6 } });
}
function scenario() {
  const p = Object.fromEntries(numeric.map((id) => [id, Number($(id).value)]));
  p.rowAngle = (90 - p.rowAngle + 180) % 180; // CP compass UI to generator maths.
  if ($("fieldShape").value !== "sloping") p.edgeAngle = 25;
  if ($("pattern").value !== "field") p.passes = 4;
  if ($("fieldShape").value !== "irregular") p.irregularInset = 36;
  return {
    ...p,
    reverseSpeed: p.reverseSpeed / 3.6,
    allowReverse: $("allowReverse").checked,
    fullCourse: $("pattern").value === "course",
    reverseCourse:
      ["course", "layout"].includes($("pattern").value) &&
      $("courseDirection").value === "end",
    vehicles: ["course", "layout"].includes($("pattern").value)
      ? p.vehicles
      : 1,
    vehicleIndex: ["course", "layout"].includes($("pattern").value)
      ? p.vehicleIndex
      : 1,
    islandCount: ["course", "layout"].includes($("pattern").value)
      ? p.islandCount
      : 0,
    centreClockwise: $("centreClockwise").checked,
    spiralFromInside: $("spiralFromInside").checked,
    sharpenCorners: $("sharpenCorners").checked,
    autoRowAngle: $("autoRowAngle").checked,
    evenRowWidth: $("evenRowWidth").checked,
    useBaseline: $("useBaseline").checked,
    sameTurnWidth: $("sameTurnWidth").checked,
    narrowField:
      ["course", "layout"].includes($("pattern").value) &&
      $("narrowField").checked,
    bypassIslands: $("bypassIslands").checked,
    islandClockwise: $("islandClockwise").checked,
    custom: $("preset").value === "custom",
    mounted:
      $("preset").value === "custom" && $("attachment").value === "mounted",
    rowPattern: $("rowPattern").value,
    fieldShape: $("fieldShape").value,
    slopeSide: $("slopeSide").value,
    courseLayout: ["course", "layout"].includes($("pattern").value),
    enforceBoundary: $("enforceBoundary").checked,
    headlandFirst: $("headlandFirst").value === "headland",
    clockwise: $("clockwise").checked,
    pattern:
      $("pattern").value === "field" &&
      $("preset").value !== "entry" &&
      $("turnType").value === "dubins",
    speed: Number($("speed").value) / 3.6,
    side: Number($("side").value),
    drill: ["drill", "drill4", "drill12", "entry"].includes($("preset").value),
    entry: $("preset").value === "entry",
    articulated: $("steering").value.startsWith("articulated"),
    lowerEarly: $("lowerEarly").checked,
    raiseLate: $("raiseLate").checked,
    loopTurnsOnHeadland: $("loopTurnsOnHeadland").checked,
    alignedPlanner: $("pattern").value === "aligned",
    rowSpacing: $("pattern").value === "aligned" ? p.width*Number($("entryRows").value) : 0,
    turnType: $("turnType").value,
    tight: $("tight").checked,
  };
}
function selected() {
  return view === "experiment" && result?.experiment
    ? result.experiment
    : result?.baseline;
}
function setPlaying(value) {
  playing = value;
  const startLabel = selected()?.diagnosticPlayback
    ? "Play diagnostic"
    : "Start run";
  $("play").innerHTML =
    `<i data-lucide="${playing ? "pause" : "play"}"></i><span>${playing ? "Pause" : startLabel}</span>`;
  $("play").title = playing ? "Pause" : startLabel;
  $("play").setAttribute("aria-label", $("play").title);
  icons();
}
function chooseView(next) {
  view = next;
  document
    .querySelectorAll("[data-view]")
    .forEach((b) =>
      b.setAttribute("aria-pressed", String(b.dataset.view === view)),
    );
  if (!result) return;
  refreshConfiguration();
  frame = Math.min(frame, selected().frames.length - 1);
  $("timeline").max = selected().frames.length - 1;
  $("run-label").textContent =
    view === "overlay"
      ? (result.planner ? "CP + aligned entry" : "Baseline + extra clearance")
      : view === "experiment"
        ? (result.planner ? "Aligned entry" : "Extra clearance")
        : "Baseline";
  updateMetrics();
  updateEvents();
  fit();
  draw();
}
async function run(event) {
  event?.preventDefault();
  for (const input of $("settings").querySelectorAll(":invalid")) {
    let parent = input.parentElement;
    while (parent && parent !== $("settings")) {
      if (parent.tagName === "DETAILS") parent.open = true;
      parent = parent.parentElement;
    }
  }
  if (!$("settings").reportValidity()) return;
  const configuration = JSON.stringify(scenario());
  configuring = true;
  refreshConfiguration();
  setPlaying(false);
  $("run").disabled = true;
  $("error").hidden = true;
  $("state").textContent = "Calculating";
  try {
    const response = await fetch("/api/simulate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: configuration,
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || "Simulation failed");
    result = data;
    document.querySelector('[data-view="experiment"]').textContent = data.planner ? "Aligned entry" : "Extra clearance";
    preparedConfiguration = configuration;
    document.querySelectorAll("[data-view]").forEach((b) => {
      b.disabled = b.dataset.view !== "baseline" && !data.experiment;
      b.title = b.disabled
        ? "Set extra clearance above 0 m in Comparison, then Set configuration. Available for movement tests."
        : b.dataset.view === "overlay"
          ? "Compare the baseline and extra-clearance routes"
          : "";
    });
    frame = 0;
    for (const id of ["play", "step", "restart", "timeline", "rate"])
      $(id).disabled = data.baseline.preview;
    $("hashes").textContent = Object.entries(data.sources)
      .map(([file, hash]) => `${file}\n${hash}`)
      .join("\n\n");
    chooseView(data.planner && data.experiment ? "experiment" : data.experiment ? view : "baseline");
  } catch (error) {
    result = null;
    ctx.clearRect(0, 0, size.w, size.h);
    $("events").replaceChildren();
    for (const id of [
      "metric-error",
      "metric-angle",
      "metric-gap",
      "metric-depth",
      "metric-exit-gap",
      "metric-exit-over",
    ])
      $(id).textContent = "--";
    for (const id of ["play", "step", "restart", "timeline", "download"])
      $(id).disabled = true;
    $("error").textContent = error.message;
    $("error").hidden = false;
    $("state").textContent = "Run failed";
  } finally {
    configuring = false;
    refreshConfiguration();
    $("run").disabled = false;
    $("download").disabled = !result;
  }
}
function updateMetrics() {
  const fleet = selected().fleet;
  $("course-status").hidden = !fleet && !result.planner;
  $("course-status").textContent = fleet
    ? "Playback check: " +
      fleet
        .map(
          (vehicle, i) =>
            `Vehicle ${i + 1}: ${vehicle.blocked ? "boundary clearance rejected" : vehicle.metrics.complete ? "route completed" : "tracking incomplete"}${vehicle.boundaryWarning ? " · boundary estimate available under Clearance details" : ""}`,
        )
        .join(" · ") +
      (selected().generatorErrors.length
        ? ` · CP: ${selected().generatorErrors.join("; ")}`
        : "")
    : result.planner
      ? result.planner.feasible
        ? `${result.planner.manoeuvre} verified in the model · ${result.planner.finalStraight} m final straight · ${Math.abs(result.planner.turnBias)} m pull-in offset · ${result.planner.rowEndDifference} m between row ends · ${result.planner.attempted} candidates checked`
        : result.planner.message
      : "";
  const m = selected().metrics;
  const field = Boolean(selected().field);
  $("error-label").textContent = field
    ? "Worst entry lateral error"
    : "Entry lateral error";
  $("angle-label").textContent = field ? "Worst entry angle" : "Entry angle";
  $("gap-label").textContent = field
    ? "Missed entry area / all turns"
    : "Missed area / first 20 m";
  $("metric-error").textContent = m.entry
    ? `${Math.abs(m.entry.lateral).toFixed(2)} m`
    : selected().preview
      ? "--"
      : field && selected().scenario.passes === 1
        ? "No turn"
        : "Not reached";
  $("metric-angle").textContent = m.entry
    ? `${Math.abs(m.entry.angle).toFixed(1)}\u00b0`
    : "--";
  $("metric-gap").textContent =
    m.missedArea == null ? "--" : `${m.missedArea.toFixed(2)} m\u00b2`;
  $("metric-gap").classList.toggle("bad", m.missedArea > 0);
  $("metric-depth").textContent =
    m.envelopeDepth == null ? "--" : `${m.envelopeDepth.toFixed(1)} m`;
  $("metric-exit-gap").textContent =
    m.exitMissedArea == null ? "--" : `${m.exitMissedArea.toFixed(2)} m\u00b2`;
  $("metric-exit-over").textContent =
    m.exitOvershoot == null ? "--" : `${m.exitOvershoot.toFixed(2)} m`;
  $("shortfall").style.color =
    selected().boundaryWarning && m.complete ? "#826016" : "";
  $("shortfall").textContent =
    selected().completeCourse && !m.complete
      ? "Run incomplete — the simulated machine did not finish tracking this course."
      : selected().boundaryWarning
        ? $("show-clearance").checked
          ? selected().boundaryWarning
          : ""
        : selected().blocked
          ? selected().reason
          : selected().layout
            ? `CP course layout · ${selected().layout.headlands.length} headlands · ${selected().layout.errors.join("; ")}`
            : selected().preview
              ? selected().scenario.turnType === "reedsShepp" &&
                !selected().path.some((w) => w.reverse)
                ? "Route only / CP forward fallback"
                : "Route preview only"
              : !m.complete
                ? "Run incomplete"
                : m.headlandShortfall
                  ? `${m.headlandShortfall.toFixed(1)} m beyond headland`
                  : "";
}
function updateEvents() {
  $("events").replaceChildren();
  for (const event of selected().events) {
    const row = document.createElement("tr");
    for (const value of [
      `${event.time.toFixed(2)} s`,
      event.pass
        ? `Pass ${event.pass} / ${event.end}: ${event.kind}`
        : event.kind,
      `${event.angle.toFixed(1)}\u00b0`,
      `${event.error.toFixed(2)} m`,
    ]) {
      const cell = document.createElement("td");
      cell.textContent = value;
      row.append(cell);
    }
    row.tabIndex = 0;
    row.title = "Jump to event";
    row.dataset.time = event.time;
    const jump = () => {
      setPlaying(false);
      frame = frameAtTime(selected(), event.time);
      draw();
    };
    row.onclick = jump;
    row.onkeydown = (e) => {
      if (e.key === "Enter") jump();
    };
    $("events").append(row);
  }
}
function toScreen(x, z) {
  return [
    (x - camera.x) * camera.scale + size.w / 2,
    size.h / 2 - (z - camera.z) * camera.scale,
  ];
}
function toWorld(x, y) {
  return [
    (x - size.w / 2) / camera.scale + camera.x,
    (size.h / 2 - y) / camera.scale + camera.z,
  ];
}
function polygon(points, fill, stroke, width = 1) {
  ctx.beginPath();
  points.forEach((p, i) => {
    const s = toScreen(...p);
    i ? ctx.lineTo(...s) : ctx.moveTo(...s);
  });
  ctx.closePath();
  if (fill) {
    ctx.fillStyle = fill;
    ctx.fill();
  }
  if (stroke) {
    ctx.strokeStyle = stroke;
    ctx.lineWidth = width;
    ctx.stroke();
  }
}
function line(points, colour, width = 1, dash = []) {
  ctx.beginPath();
  points.forEach((p, i) => {
    const s = toScreen(...p);
    i ? ctx.lineTo(...s) : ctx.moveTo(...s);
  });
  ctx.strokeStyle = colour;
  ctx.lineWidth = width;
  ctx.setLineDash(dash);
  ctx.stroke();
  ctx.setLineDash([]);
}
function label(text, x, z, colour = "#7c939c", align = "left") {
  ctx.fillStyle = colour;
  ctx.font = "11px Segoe UI";
  ctx.textAlign = align;
  const s = toScreen(x, z);
  ctx.fillText(text, ...s);
}
function point(x, z, t, across = 0, along = 0) {
  return [
    x + across * Math.cos(t) + along * Math.sin(t),
    z - across * Math.sin(t) + along * Math.cos(t),
  ];
}
function body(x, z, t, width, front, back, fill, stroke) {
  polygon(
    [
      point(x, z, t, -width / 2, front),
      point(x, z, t, width / 2, front),
      point(x, z, t, width / 2, back),
      point(x, z, t, -width / 2, back),
    ],
    fill,
    stroke,
    1.6,
  );
}
function fit() {
  if (!result) return;
  const runs =
    view === "overlay" && result.experiment
      ? [result.baseline, result.experiment]
      : [selected()];
  const points = runs.flatMap((r) =>
    r.frames.flatMap((f) => [
      [f.x, f.z],
      f.left,
      f.right,
      f.rearLeft,
      f.rearRight,
    ]),
  );
  const addPoints = (vertices) => {
    for (const v of vertices) points.push(v);
  };
  for (const r of runs) if (r.preview) addPoints(r.path.map((w) => [w.x, w.z]));
  for (const r of runs)
    if (r.layout) {
      addPoints(r.layout.boundary);
      addPoints(r.paths.flat());
    }
  for (const r of runs)
    if (r.rejectedPath && $("show-turns").checked) {
      addPoints(r.rejectedPath);
      addPoints((r.rejectedEnvelopes || []).flat());
    }
  for (const r of runs)
    for (const vehicle of r.fleet || []) addPoints(vehicle.paths.flat());
  const p = selected().scenario;
  if (selected().layout) {
    // Bounds already include the entire generated course and polygon.
  } else if (selected().field?.boundary) {
    if (result.planner) {
      const r=selected(), xs=r.frames.map(f=>f.x);
      const west=Math.max(r.field.west,Math.min(...xs)-12);
      const east=Math.min(r.field.east,Math.max(...xs)+12);
      const slope=p.boundarySlope || 0;
      addPoints([[west,slope*west+p.headland*Math.hypot(1,slope)],
                 [east,slope*east+p.headland*Math.hypot(1,slope)]]);
    } else addPoints(selected().field.boundary);
    addPoints(selected().paths.flat());
  } else if (selected().field) {
    points.push(
      [selected().field.west, 0],
      [selected().field.east, -p.fieldLength],
    );
    for (const x of selected().field.rows)
      points.push([x - p.width / 2, 0], [x + p.width / 2, -p.fieldLength]);
  } else points.push([-p.width, -22], [p.width * 2, p.headland + 2]);
  // Avoid argument-count limits on long field runs.
  const bounds = points.reduce(
    (b, [x, z]) => [
      Math.min(b[0], x),
      Math.max(b[1], x),
      Math.min(b[2], z),
      Math.max(b[3], z),
    ],
    [Infinity, -Infinity, Infinity, -Infinity],
  );
  const x0 = bounds[0] - 5,
    x1 = bounds[1] + 5,
    z0 = bounds[2] - 3,
    z1 = bounds[3] + 6;
  camera = {
    x: (x0 + x1) / 2,
    z: (z0 + z1) / 2,
    scale: Math.min(size.w / (x1 - x0), size.h / (z1 - z0)),
  };
}
function drawRig(f, colour, ghost = false) {
  ctx.globalAlpha = ghost ? 0.65 : 1;
  line([[f.x, f.z], f.hitch, f.axle], colour, 1.7);
  body(f.x, f.z, f.theta, 3, 4, -2, ghost ? "#fffaf0" : "#edf6f1", colour);
  body(
    ...point(f.x, f.z, f.theta, 0, 1),
    f.theta,
    1.8,
    1.2,
    -1.2,
    null,
    colour,
  );
  for (const a of [-1.65, 1.65])
    for (const b of [-1.3, 2.5])
      body(
        ...point(f.x, f.z, f.theta, a, b),
        f.theta,
        0.45,
        0.65,
        -0.65,
        colour,
        colour,
      );
  polygon(
    [f.left, f.right, f.rearRight, f.rearLeft],
    f.lowered ? (ghost ? "#e7d5a433" : "#b2556322") : null,
    ghost ? colour : "#a74755",
    1.8,
  );
  line([f.left, f.right], ghost ? colour : "#a74755", 3);
  if (!selected().scenario.mounted)
    line([point(...f.axle, f.phi, -1), point(...f.axle, f.phi, 1)], colour, 3);
  ctx.globalAlpha = 1;
}
function draw() {
  ctx.clearRect(0, 0, size.w, size.h);
  if (!result) return;
  const run = selected(),
    p = run.scenario;
  frame = Math.max(0, Math.min(frame, run.frames.length - 1));
  const f = run.frames[Math.floor(frame)];
  const [x0, z1] = toWorld(0, 0),
    [x1, z0] = toWorld(size.w, size.h);
  if (run.layout) {
    polygon(run.layout.boundary, "#eef3ee", "#a25760", 2);
    for (const island of run.layout.islands || [])
      polygon(island, "#e5ddc9", "#987a54", 1.5);
    for (const h of run.layout.headlands) line([...h, h[0]], "#9bae9c", 1);
    for (const path of run.paths) line(path, "#4c91ad", 1.2);
    $("state").textContent = f.state;
    $("time").textContent = "--";
    for (const id of ["live-error", "live-angle", "live-offset", "live-ix"])
      $(id).textContent = "--";
    return;
  }
  if (run.field?.boundary) {
    polygon(run.field.boundary, "#eef3ee", "#a25760", 2);
    for (const island of run.field.islands || [])
      polygon(island, "#e5ddc9", "#987a54", 1.5);
    for (const h of run.field.headlands) line([...h, h[0]], "#bdcec2", 1);
    for (const row of run.field.rowSegments) line(row, "#899e95", 1, [4, 5]);
  } else if (run.field) {
    const field = run.field;
    polygon(
      [
        [field.west, field.north],
        [field.east, field.north],
        [field.east, field.south],
        [field.west, field.south],
      ],
      "#eef3ee",
      "#a25760",
      2,
    );
    for (const [outer, inner] of [
      [field.north, field.northWork],
      [field.south, field.southWork],
    ])
      polygon(
        [
          [field.west, outer],
          [field.east, outer],
          [field.east, inner],
          [field.west, inner],
        ],
        "#e4ece5",
      );
    polygon(
      [
        [field.west + p.headland, field.northWork],
        [field.east - p.headland, field.northWork],
        [field.east - p.headland, field.southWork],
        [field.west + p.headland, field.southWork],
      ],
      "#f8fbfc",
    );
    for (let i = 0; i < field.rows.length; i++) {
      const x = field.rows[i];
      line(
        [
          [x, field.northWork],
          [x, field.southWork],
        ],
        "#77998c",
        1,
        [3, 4],
      );
    }
  } else
    polygon(
      [
        [x0, 0],
        [x1, 0],
        [x1, p.headland],
        [x0, p.headland],
      ],
      "#f1f5f3",
    );
  if (p.entry || run.preview)
    polygon(
      [
        [-p.width / 2, 0],
        [p.width / 2, 0],
        [p.width / 2, z0],
        [-p.width / 2, z0],
      ],
      "#d7e4dc",
    );
  const step = camera.scale < 4 ? 10 : 5;
  for (let x = Math.ceil(x0 / step) * step; x < x1; x += step) {
    line(
      [
        [x, z0],
        [x, z1],
      ],
      "#e2e9e9",
      0.7,
    );
    if (toScreen(x, z0)[0] < size.w - 160) label(String(x), x, z0 + 2);
  }
  for (let z = Math.ceil(z0 / step) * step; z < z1; z += step) {
    line(
      [
        [x0, z],
        [x1, z],
      ],
      "#e2e9e9",
      0.7,
    );
    if (z !== 0 && toScreen(x0, z)[1] > 44) label(String(z), x0 + 1, z + 0.4);
  }
  for (let i = 0; i <= Math.floor(frame); i++) {
    const s = run.frames[i];
    if (!s.lowered) continue;
    polygon([s.left, s.right, s.rearRight, s.rearLeft], "#bfd9cc");
    if (i && run.frames[i - 1].lowered)
      polygon(
        [run.frames[i - 1].left, run.frames[i - 1].right, s.right, s.left],
        "#bfd9cc",
      );
  }
  if ($("gaps").checked) {
    ctx.fillStyle = "#e89ba5aa";
    for (const [x, z] of [...run.gaps, ...run.exitGaps]) {
      const s = toScreen(x - run.resolution / 2, z + run.resolution / 2);
      ctx.fillRect(
        ...s,
        Math.max(1, run.resolution * camera.scale),
        Math.max(1, run.resolution * camera.scale),
      );
    }
  }
  if (run.field) {
    const field = run.field;
    if (!field.boundary) {
      for (const [name, outer, inner] of [
        ["North", field.north, field.northWork],
        ["South", field.south, field.southWork],
      ]) {
        line(
          [
            [field.west, outer],
            [field.east, outer],
          ],
          "#b95c63",
          2,
        );
        line(
          [
            [field.west + p.headland, inner],
            [field.east - p.headland, inner],
          ],
          "#899e95",
          1.1,
        );
        const inset = 28 / camera.scale;
        label(
          `${name} boundary`,
          x1 - 2,
          outer + (name === "North" ? -inset : inset),
          "#a25760",
          "right",
        );
        label(
          `${p.headlandRows ? p.headlandRows + " rows / " : ""}${p.headland.toFixed(1)} m headland`,
          x1 - 2,
          (outer + inner) / 2,
          "#658074",
          "right",
        );
        for (let n = 1; n < p.headlandRows; n++) {
          const z = outer + ((inner - outer) * n) / p.headlandRows;
          line(
            [
              [field.west + n * p.width, z],
              [field.east - n * p.width, z],
            ],
            "#bdcec2",
            0.8,
            [4, 5],
          );
        }
      }
      for (let n = 0; n <= p.headlandRows; n++) {
        const inset = n * p.width;
        for (const x of [field.west + inset, field.east - inset])
          line(
            [
              [x, field.south + inset],
              [x, field.north - inset],
            ],
            n === 0 ? "#a25760" : "#bdcec2",
            n === 0 ? 2 : 0.8,
            n === 0 ? [] : [4, 5],
          );
      }
    }
    if (run.coursePath) line(run.coursePath, "#4c91ad", 1.4);
    if (!run.completeCourse || $("show-turns").checked)
      for (const path of run.paths) line(path, "#4c91ad", 1.4, [5, 4]);
  } else {
    line(
      [
        [x0, p.headland],
        [x1, p.headland],
      ],
      "#b95c63",
      1.3,
      [7, 4],
    );
    label(
      "Headland boundary",
      x1 - 2,
      Math.min(p.headland - 2, toWorld(0, 56)[1]),
      "#a25760",
      "right",
    );
    line(
      [
        [x0, 0],
        [x1, 0],
      ],
      "#899e95",
      1.1,
    );
    label("Work boundary", x1 - 2, 1, "#658074", "right");
    const target = run.target;
    line(
      [point(target.x, target.z, target.t, 0, 25), [target.x, target.z]],
      "#77998c",
      1,
      [3, 4],
    );
    line(
      run.path.map((s) => [s.x, s.z]),
      "#4c91ad",
      1.4,
      [5, 4],
    );
    for (let i = 1; i < run.path.length; i++)
      if (run.path[i - 1].reverse)
        line(
          [
            [run.path[i - 1].x, run.path[i - 1].z],
            [run.path[i].x, run.path[i].z],
          ],
          "#99498d",
          2.5,
        );
  }
  if (!run.completeCourse || $("show-turns").checked) {
    line(
      run.frames.slice(0, Math.floor(frame) + 1).map((s) => [s.x, s.z]),
      "#39785f",
      1.1,
    );
    line(
      run.frames.slice(0, Math.floor(frame) + 1).map((s) => s.work),
      "#b15a68",
      1.1,
    );
  }
  if (view === "overlay" && result.experiment) {
    const other = result.experiment;
    if (other.field)
      for (const path of other.paths) line(path, "#b5862d", 1.6, [7, 4]);
    else
      line(
        other.path.map((s) => [s.x, s.z]),
        "#b5862d",
        1.6,
        [7, 4],
      );
    drawRig(other.frames[frameAtTime(other, f.time)], "#ad7b25", true);
  }
  if (run.field) {
    const field = run.field;
    const stride = Math.max(1, Math.ceil(14 / (p.width * camera.scale)));
    for (let i = 0; i < field.rows.length; i += stride) {
      const row = field.rowSegments?.[i];
      const middle = row
        ? (row[0][1] + row[1][1]) / 2
        : (field.northWork + field.southWork) / 2;
      const rowX = row ? (row[0][0] + row[1][0]) / 2 : field.rows[i];
      const pass = field.order ? field.order.indexOf(i + 1) : i;
      label(String(pass + 1), rowX, middle, "#365449", "center");
      label(
        pass % 2 ? "↓" : "↑",
        rowX,
        middle - 14 / camera.scale,
        "#365449",
        "center",
      );
    }
  }
  drawRig(f, "#247752");
  if (run.completeCourse && $("show-turns").checked) {
    for (let i = 1; i < run.path.length; i++)
      if (run.path[i - 1].reverse)
        line(
          [
            [run.path[i - 1].x, run.path[i - 1].z],
            [run.path[i].x, run.path[i].z],
          ],
          "#a64999",
          2,
        );
  }
  if (run.fleet) {
    const colours = ["#247752", "#456bb0", "#a86a27", "#965aa4", "#3d8e96"];
    run.fleet.forEach((vehicle, i) => {
      if (i + 1 === p.vehicleIndex) return;
      for (const path of vehicle.paths || []) line(path, colours[i] + "55", 1);
      const other = vehicle.frames[frameAtTime(vehicle, f.time)];
      drawRig(other, colours[i], true);
      label(`V${i + 1}`, other.x, other.z + 3, colours[i], "center");
    });
  }
  const diagnosticRuns =
    view === "overlay" && result.experiment ? [run, result.experiment] : [run];
  for (const candidate of diagnosticRuns) {
    if (!candidate.rejectedPath || !$("show-clearance").checked) continue;
    for (const envelope of candidate.rejectedEnvelopes || [])
      polygon(envelope, "#e9b85d25", "#b7803433", 0.6);
    if (candidate.rejectedSegments?.length) {
      for (const segment of candidate.rejectedSegments)
        line(
          segment.points,
          segment.reverse ? "#a64999" : "#ad7b25",
          segment.reverse ? 2 : 1.6,
          segment.reverse ? [] : [6, 5],
        );
    } else {
      line(candidate.rejectedPath, "#ad7b25", 1.6, [6, 5]);
    }
  }
  if (view === "overlay" && result.experiment?.blocked)
    $("shortfall").textContent = `Extra clearance: ${result.experiment.reason}`;
  $("timeline").value = Math.floor(frame);
  $("time").textContent = `${f.time.toFixed(1)} s`;
  $("state").textContent = run.completeCourse
    ? `Vehicle ${p.vehicleIndex}/${p.vehicles} · ${f.state}${f.headland ? " " + f.headland : f.row ? " " + f.row : ""}`
    : f.pass
      ? `Pass ${f.pass}/${p.passes} · ${f.state}`
      : f.state;
  $("live-error").textContent = run.preview ? "--" : `${f.error.toFixed(2)} m`;
  $("live-angle").textContent = run.preview
    ? "--"
    : `${f.angle.toFixed(1)}\u00b0`;
  $("live-offset").textContent = run.preview
    ? "--"
    : `${f.offset.toFixed(2)} m`;
  $("live-ix").textContent = f.ix;
  $("events")
    .querySelectorAll("tr")
    .forEach((row) =>
      row.classList.toggle(
        "active",
        Math.abs(Number(row.dataset.time) - f.time) < 0.11,
      ),
    );
}
new ResizeObserver(() => {
  const rect = canvas.getBoundingClientRect(),
    dpr = window.devicePixelRatio || 1;
  size = { w: rect.width, h: rect.height };
  canvas.width = Math.round(rect.width * dpr);
  canvas.height = Math.round(rect.height * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  fit();
  draw();
}).observe($("stage"));
canvas.addEventListener(
  "wheel",
  (e) => {
    e.preventDefault();
    const r = canvas.getBoundingClientRect(),
      mx = e.clientX - r.left,
      my = e.clientY - r.top;
    const before = toWorld(mx, my);
    camera.scale = Math.max(
      1,
      Math.min(50, camera.scale * Math.exp(-e.deltaY * 0.001)),
    );
    const after = toWorld(mx, my);
    camera.x += before[0] - after[0];
    camera.z += before[1] - after[1];
    draw();
  },
  { passive: false },
);
canvas.addEventListener("pointerdown", (e) => {
  drag = { x: e.clientX, y: e.clientY, cx: camera.x, cz: camera.z };
  canvas.setPointerCapture(e.pointerId);
});
canvas.addEventListener("pointermove", (e) => {
  if (!drag) return;
  camera.x = drag.cx - (e.clientX - drag.x) / camera.scale;
  camera.z = drag.cz + (e.clientY - drag.y) / camera.scale;
  draw();
});
canvas.addEventListener("pointerup", () => (drag = null));
canvas.addEventListener("pointercancel", () => (drag = null));
$("settings").onsubmit = run;
$("settings").addEventListener("input", refreshConfiguration);
$("settings").addEventListener("change", refreshConfiguration);
function updateControls() {
  $("edge-angle-label").hidden = $("fieldShape").value !== "sloping";
  $("edgeAngle").disabled = $("fieldShape").value !== "sloping";
  $("slope-side-label").hidden = $("fieldShape").value !== "sloping";
  $("slopeSide").disabled = $("fieldShape").value !== "sloping";
  $("attachment-label").hidden = $("preset").value !== "custom";
  $("length").disabled =
    $("preset").value === "custom" && $("attachment").value === "mounted";
  const entry = $("preset").value === "entry";
  const preview = $("pattern").value === "layout";
  const layout = $("pattern").value === "layout";
  const complete = $("pattern").value === "course";
  const aligned = $("pattern").value === "aligned";
  $("entry-rows-label").hidden = !aligned;
  $("entryRows").disabled = !aligned;
  const generated =
    layout ||
    complete ||
    ($("pattern").value === "field" && $("fieldShape").value !== "rectangle");
  $("turnType").disabled = entry || layout || aligned;
  $("side").disabled = layout || complete;
  $("raiseLate").disabled = entry || preview;
  $("raiseSeconds").disabled = entry || preview;
  for (const id of [
    "lowerSeconds",
    "lowerEarly",
    "lookahead",
    "tight",
    "tightDistance",
  ])
    $(id).disabled = preview;
  $("extension").disabled = entry || aligned;
  $("pattern").disabled = entry;
  const field = !entry && !preview && $("pattern").value === "field";
  $("passes").disabled = !field;
  $("passes-label").hidden = !field;
  $("course-direction-label").hidden = !(layout || complete);
  $("courseDirection").disabled = !(layout || complete);
  $("irregular-inset-label").hidden = $("fieldShape").value !== "irregular";
  $("irregularInset").disabled = $("fieldShape").value !== "irregular";
  $("run-mode-note").textContent = aligned
    ? "Experimental row-end comparison: rectangle for straight work, sloping for pikes. Increase headland rows to test more space. Searches for an aligned entry inside the modelled field; maximum model articulation is 85°, pending actual joint limits. Does not run a full field."
    : complete
    ? "Drives the whole CP-generated field, including short rows and connections between sections. No pass count is needed. Set configuration, then press Start run."
    : field
      ? "Turn test only: drives the requested number of usable rows. Choose Full field to work every section in CP’s generated order."
      : layout
        ? "Complete CP course preview; choose Full field for playback."
        : "One isolated turn for geometry testing.";
  $("fieldLength").disabled = !field;
  if (layout || complete) $("fieldLength").disabled = false;
  $("fieldWidth").disabled = !(layout || field || complete || aligned);
  $("enforceBoundary").disabled = layout;
  for (const id of [
    "rowAngle",
    "headlandOverlap",
    "roundHeadlands",
    "headlandFirst",
    "clockwise",
  ])
    $(id).disabled = !generated;
  for (const id of [
    "fieldMargin",
    "generatorRadius",
    "autoRowAngle",
    "evenRowWidth",
    "useBaseline",
    "sharpenCorners",
    "startX",
    "startZ",
  ])
    $(id).disabled = !generated;
  for (const id of [
    "vehicles",
    "vehicleIndex",
    "sameTurnWidth",
    "islandCount",
    "islandSize",
    "bypassIslands",
    "islandHeadlands",
    "islandClockwise",
    "narrowField",
  ])
    $(id).disabled = !(layout || complete);
  $("rowAngle").disabled =
    !generated || $("autoRowAngle").checked || $("useBaseline").checked;
  $("autoRowAngle").disabled = !generated || $("useBaseline").checked;
  $("rotateRows").disabled = !generated;
  $("rowsToSkip").disabled = $("rowPattern").value !== "alternating";
  $("spiralFromInside").disabled = $("rowPattern").value !== "spiral";
  $("centreClockwise").disabled = !["spiral", "lands"].includes(
    $("rowPattern").value,
  );
  $("reverseSpeed").disabled =
    !$("allowReverse").checked && $("turnType").value !== "reedsShepp";
  if (layout)
    for (const id of [
      "extension",
      "raiseLate",
      "raiseSeconds",
      "lowerEarly",
      "lowerSeconds",
      "lookahead",
      "tight",
      "tightDistance",
      "enforceBoundary",
    ])
      $(id).disabled = true;
  $("rowsPerLand").disabled = $("rowPattern").value !== "lands";
  $("circles").disabled = $("rowPattern").value !== "racetrack";
  updateFieldSize();
}
function updateFieldSize() {
  const rows = Number($("headlandRows").value),
    width = Number($("width").value);
  if (rows || $("pattern").value !== "single")
    $("headland").value = (rows * width).toFixed(3);
  $("implement-width").textContent = `Working width: ${width.toFixed(1)} m`;
  const complete = ["course", "layout"].includes($("pattern").value);
  const reversed = complete && $("courseDirection").value === "end";
  const first =
    $("headlandFirst").value === "headland" ? "headlands" : "centre rows";
  $("work-order-note").textContent = complete
    ? reversed
      ? `CP generates ${first} first, then reverses that exact course. Playback starts at its original end; work order is therefore reversed too.`
      : `CP generates and drives ${first} first, then the remaining sections in its generated order.`
    : "Full field uses this work order. Selected-pass tests drive central rows only.";
  $("field-size").textContent = complete
    ? `${rows} headland rows per vehicle × ${width.toFixed(1)} m working width × ${$("vehicles").value} vehicle(s). CP generates the complete selected course; overlap and field margin affect the usable centre.`
    : $("fieldShape").value !== "rectangle"
      ? `${Number($("headland").value).toFixed(1)} m nominal headland depth. CP generates varying row lengths; playback selects the requested number of usable rows. One pass is one row.`
      : `${Number($("headland").value).toFixed(1)} m at each end · ${(Number($("fieldLength").value) - 2 * Number($("headland").value)).toFixed(1)} m working rows. One pass is one row.`;
}
$("pattern").onchange = () => {
  if (
    $("pattern").value === "field" ||
    ($("pattern").value === "course" && $("turnType").value === "headlandLoop")
  )
    $("turnType").value = "dubins";
  updateControls();
};
$("fieldShape").onchange = () => {
  // This deliberate angled-entry fixture uses vertical rows (CP 0 degrees). Other shapes
  // preserve the user's automatic/manual selection rather than resetting it.
  if ($("fieldShape").value === "sloping") {
    $("rowAngle").value = 0;
    $("autoRowAngle").checked = false;
  }
  updateControls();
};
$("rowPattern").onchange = updateControls;
$("headlandFirst").onchange = updateControls;
$("courseDirection").onchange = updateControls;
$("autoRowAngle").onchange = updateControls;
$("useBaseline").onchange = updateControls;
$("rotateRows").onclick = () => {
  let angle = Number($("rowAngle").value);
  if (
    $("autoRowAngle").checked &&
    result &&
    JSON.stringify(scenario()) === preparedConfiguration
  ) {
    const run = selected();
    const row = run.layout?.rows?.[0] || run.field?.rowSegments?.[0];
    const i = run.path?.findIndex((p) => p.phase === "Central row");
    const a = row?.[0] || (i >= 0 ? [run.path[i].x, run.path[i].z] : null);
    const b =
      row?.at(-1) ||
      (i >= 0 && i + 1 < run.path.length
        ? [run.path[i + 1].x, run.path[i + 1].z]
        : null);
    if (a && b)
      angle =
        (90 - (Math.atan2(b[1] - a[1], b[0] - a[0]) * 180) / Math.PI + 360) %
        180;
  }
  $("rowAngle").value = (Math.round(angle / 5) * 5 + 90) % 180;
  $("autoRowAngle").checked = false;
  $("useBaseline").checked = false;
  updateControls();
  refreshConfiguration();
};
$("allowReverse").onchange = updateControls;
$("vehicles").oninput = () => {
  $("vehicleIndex").max = $("vehicles").value;
  $("vehicleIndex").value = Math.min(
    Number($("vehicleIndex").value),
    Number($("vehicles").value),
  );
};
$("attachment").onchange = () => {
  const mounted = $("attachment").value === "mounted";
  $("front").value = mounted ? 3 : 11;
  $("back").value = mounted ? 4 : 12;
  $("clearance").value = mounted ? 5 : 13;
  $("config-note").textContent = mounted
    ? "Custom rigid mounted implement. Set its width and front/rear work-marker setbacks."
    : "Custom trailed implement. Set its width, hitch-to-axle distance and work-marker setbacks.";
  updateControls();
};
for (const id of ["headlandRows", "width", "fieldLength"])
  $(id).addEventListener("input", updateFieldSize);
$("turnType").onchange = () => {
  if (
    $("turnType").value === "headlandLoop" ||
    ($("turnType").value !== "dubins" && $("pattern").value === "field")
  )
    $("pattern").value = "single";
  updateControls();
};
$("preset").onchange = () => {
  const name = $("preset").value;
  $("attachment").value = "trailed";
  Object.entries(presets[name]).forEach(([id, v]) => ($(id).value = v));
  $("steering").value = "normal";
  $("config-implement").value = "";
  $("config-search").value = "";
  filterConfigurations();
  $("config-toggle").textContent = "Preset / no additional override ▾";
  $("config-note").textContent =
    name === "plough"
      ? "PW 100-12: logged Challenger 55 geometry; 13 m effective steering length, markers 4.6/18.3 m behind the tractor, 2.5 s lowering. Radius comes from the CP override. Trailer geometry remains simplified."
      : name === "custom"
        ? "Custom implement: set the working width and choose mounted or trailed. Adjust the geometry below to suit."
        : "Generic drill: width as selected; remaining geometry is illustrative.";
  $("raiseLate").checked = true;
  $("lowerEarly").checked = true;
  if (name === "plough") $("headlandRows").value = 9;
  $("fieldLength").value = Math.max(
    Number($("fieldLength").value),
    2 * Number($("headlandRows").value) * presets[name].width + 80,
  );
  $("entry-angle-label").hidden = name !== "entry";
  if (name === "entry") $("turnType").value = "dubins";
  updateControls();
  if (name === "plough") selectDefaultPwOverride();
};
$("steering").onchange = () => {
  const profiles = {
    normal: [9, 2],
    four: [6, 2],
    twin: [4, 2],
    articulated: [7, 3],
    articulatedTrack: [6, 3],
  };
  const [radius, hitch] = profiles[$("steering").value];
  $("radius").value = radius;
  $("hitch").value = hitch;
};
$("extension").oninput = () =>
  ($("extension-value").textContent = `${$("extension").value} m`);
document
  .querySelectorAll("[data-view]")
  .forEach((b) => (b.onclick = () => chooseView(b.dataset.view)));
$("play").onclick = () => {
  if (!result) return;
  if (frame >= selected().frames.length - 1) frame = 0;
  setPlaying(!playing);
};
$("restart").onclick = () => {
  setPlaying(false);
  frame = 0;
  draw();
};
$("step").onclick = () => {
  setPlaying(false);
  frame = Math.floor(frame) + 1;
  draw();
};
$("timeline").oninput = () => {
  setPlaying(false);
  frame = Number($("timeline").value);
  draw();
};
$("fit").onclick = () => {
  fit();
  draw();
};
$("gaps").onchange = draw;
$("info").onclick = () => $("provenance").showModal();
$("close-info").onclick = () => $("provenance").close();
$("load").onclick = () => $("setup-file").click();
$("setup-file").onchange = async () => {
  const file = $("setup-file").files[0];
  if (!file) return;
  try {
    if (file.size > 64 * 1024 * 1024)
      throw new Error("Saved setup exceeds 64 MB");
    const saved = JSON.parse(await file.text());
    const source =
      saved.scenario || saved.experiment?.scenario || saved.baseline?.scenario;
    const p = source && {
      raiseLate: true,
      raiseSeconds: 1,
      turnType: "dubins",
      pattern: false,
      passes: 4,
      fieldLength: 160,
      headlandRows: 0,
      fieldWidth: 220,
      rowsPerLand: 6,
      circles: 3,
      rowPattern: "alternating",
      fieldShape: "rectangle",
      slopeSide: "left",
      irregularInset: 23,
      reverseCourse: false,
      courseLayout: false,
      enforceBoundary: false,
      rowAngle: 90,
      edgeAngle: 25,
      reverseSpeed: 1.5,
      rowsToSkip: 0,
      fieldMargin: 0,
      startX: 5,
      startZ: 5,
      vehicles: 1,
      vehicleIndex: 1,
      islandCount: 0,
      islandSize: 15,
      islandHeadlands: 1,
      allowReverse: false,
      fullCourse: false,
      centreClockwise: false,
      spiralFromInside: false,
      sharpenCorners: true,
      loopTurnsOnHeadland: false,
      generatorRadius: source.radius ?? 5,
      autoRowAngle: false,
      evenRowWidth: false,
      useBaseline: false,
      sameTurnWidth: false,
      narrowField: false,
      bypassIslands: true,
      islandClockwise: true,
      headlandOverlap: 5,
      roundHeadlands: 1,
      headlandFirst: true,
      clockwise: true,
      custom: false,
      mounted: false,
      ...source,
    };
    if (p && p.fieldShape === "sloping" && !source.slopeSide) {
      p.rowAngle = 0;
      p.autoRowAngle = false;
    }
    if (
      !p ||
      !["left", "right"].includes(p.slopeSide) ||
      typeof p.reverseCourse !== "boolean" ||
      numeric.some((k) => typeof p[k] !== "number" || !Number.isFinite(p[k])) ||
      ![-1, 1].includes(p.side) ||
      typeof p.drill !== "boolean" ||
      typeof p.entry !== "boolean" ||
      typeof p.articulated !== "boolean" ||
      typeof p.speed !== "number" ||
      !Number.isFinite(p.speed) ||
      ["lowerEarly", "raiseLate", "tight"].some(
        (k) => typeof p[k] !== "boolean",
      ) ||
      !["dubins", "reedsShepp", "headlandLoop"].includes(p.turnType) ||
      (p.entry && p.turnType !== "dubins")
    )
      throw new Error("Not a turn-bench setup");
    $("preset").value =
      p.custom || p.mounted
        ? "custom"
        : p.entry
          ? "entry"
          : p.drill
            ? "drill"
            : "plough";
    $("preset").dispatchEvent(new Event("change"));
    $("attachment").value = p.mounted ? "mounted" : "trailed";
    numeric.forEach((k) => ($(k).value = p[k]));
    $("rowAngle").value = (90 - p.rowAngle + 180) % 180;
    // Preserve exact depths in older exported single-turn setups.
    $("headlandRows").min = p.headlandRows === 0 ? "0" : "1";
    $("pattern").value = p.pattern ? "field" : "single";
    if (p.courseLayout) $("pattern").value = p.fullCourse ? "course" : "layout";
    if (p.alignedPlanner) $("pattern").value = "aligned";
    $("entryRows").value = p.rowSpacing ? p.rowSpacing/p.width : 1;
    $("fieldShape").value = p.fieldShape;
    $("slopeSide").value = p.slopeSide;
    $("courseDirection").value = p.reverseCourse ? "end" : "start";
    $("rowPattern").value = p.rowPattern;
    $("enforceBoundary").checked = p.enforceBoundary;
    $("headlandFirst").value = p.headlandFirst ? "headland" : "centre";
    $("clockwise").checked = p.clockwise;
    $("reverseSpeed").value = p.reverseSpeed * 3.6;
    for (const id of [
      "allowReverse",
      "centreClockwise",
      "spiralFromInside",
      "sharpenCorners",
      "loopTurnsOnHeadland",
      "autoRowAngle",
      "evenRowWidth",
      "useBaseline",
      "sameTurnWidth",
      "narrowField",
      "bypassIslands",
      "islandClockwise",
    ])
      $(id).checked = p[id];
    $("speed").value = p.speed * 3.6;
    $("side").value = p.side;
    $("steering").value = p.articulated ? "articulated" : "normal";
    $("lowerEarly").checked = p.lowerEarly;
    $("raiseLate").checked = p.raiseLate;
    $("turnType").value = p.turnType;
    updateControls();
    $("tight").checked = p.tight;
    $("extension").dispatchEvent(new Event("input"));
    await run();
  } catch (e) {
    $("error").textContent = e.message;
    $("error").hidden = false;
  } finally {
    $("setup-file").value = "";
  }
};
$("download").onclick = () => {
  if (!result) return;
  const url = URL.createObjectURL(
    new Blob([JSON.stringify(result)], { type: "application/json" }),
  );
  const a = document.createElement("a");
  a.href = url;
  a.download = "courseplay-turnbench-run.json";
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
};
function animate(now) {
  const elapsed = Math.min((now - lastTime) / 1000, 0.1);
  lastTime = now;
  if (playing && result) {
    const run = selected();
    const index = Math.min(Math.floor(frame), run.frames.length - 1);
    const next = Math.min(index + 1, run.frames.length - 1);
    const time =
      run.frames[index].time +
      (run.frames[next].time - run.frames[index].time) * (frame - index) +
      elapsed * Number($("rate").value);
    const low = frameAtTime(run, time);
    const high = Math.min(low + 1, run.frames.length - 1);
    frame =
      low +
      (high > low
        ? Math.min(
            1,
            (time - run.frames[low].time) /
              (run.frames[high].time - run.frames[low].time),
          )
        : 0);
    if (frame >= selected().frames.length - 1) setPlaying(false);
    draw();
  }
  requestAnimationFrame(animate);
}
function frameAtTime(run, time) {
  let lo = 0,
    hi = run.frames.length - 1;
  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2);
    if (run.frames[mid].time <= time) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}
$("preset").dispatchEvent(new Event("change"));
icons();
updateControls();
requestAnimationFrame(animate);
function selectDefaultPwOverride() {
  const item = catalogue.find((v) => v.name.toLowerCase() === "pw10012.xml");
  if (!item) return;
  $("config-implement").value = item.id;
  $("config-implement").dispatchEvent(new Event("change"));
}
function filterConfigurations() {
  const select = $("config-implement");
  const selected = select.value;
  const query = $("config-search").value.trim().toLocaleLowerCase("en-GB");
  const matches = catalogue.filter((item) =>
    item.name.toLocaleLowerCase("en-GB").includes(query),
  );
  select.replaceChildren(new Option("Preset / no additional override", ""));
  for (const item of catalogue) {
    if (!matches.includes(item) && item.id !== selected) continue;
    const label =
      item.name +
      (item.overrides.workingWidth
        ? ` / ${item.overrides.workingWidth} m`
        : " / width not supplied");
    select.add(new Option(label, item.id));
  }
  select.value = selected;
  const retained = selected && !matches.some((item) => item.id === selected);
  $("config-count").textContent =
    `${matches.length} matching configurations${retained ? " · current selection retained" : ""}`;
}
function setConfigOpen(open, restoreFocus = false) {
  $("config-popup").hidden = !open;
  $("config-toggle").setAttribute("aria-expanded", String(open));
  if (open) $("config-search").focus();
  else if (restoreFocus) $("config-toggle").focus();
}
$("config-toggle").onclick = () => setConfigOpen($("config-popup").hidden);
document.addEventListener("pointerdown", (event) => {
  if (!$("config-picker").contains(event.target)) setConfigOpen(false);
});
$("config-picker").addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault();
    setConfigOpen(false, true);
  }
});
$("config-picker").addEventListener("focusout", (event) => {
  if (!$("config-picker").contains(event.relatedTarget)) setConfigOpen(false);
});
$("config-search").addEventListener("input", filterConfigurations);
$("config-search").addEventListener("keydown", (event) => {
  if (event.key === "Enter") event.preventDefault();
  if (event.key === "ArrowDown") {
    event.preventDefault();
    $("config-implement").focus();
  }
});
if (new URLSearchParams(location.search).get("mode") === "aligned") {
  $("pattern").value = "aligned";
  updateControls();
}
fetch("/api/implements")
  .then((r) => r.json())
  .then((data) => {
    const collator = new Intl.Collator("en-GB", {
      sensitivity: "base",
      numeric: true,
    });
    catalogue = data.implements.sort((a, b) =>
      collator.compare(a.name, b.name),
    );
    filterConfigurations();
    if ($("preset").value === "plough" && !$("config-implement").value)
      selectDefaultPwOverride();
    run();
  })
  .catch(() => {
    $("config-note").textContent =
      "Could not load the CP configuration catalogue.";
    run();
  });
$("config-implement").onchange = () => {
  const item = catalogue.find((v) => v.id === $("config-implement").value);
  filterConfigurations();
  $("config-toggle").textContent =
    (item ? item.name : "Preset / no additional override") + " ▾";
  setConfigOpen(false, true);
  if (!item) return;
  const mapping = {
    workingWidth: "width",
    turnRadius: "radius",
    tightTurnOffsetDistanceInTurns: "tightDistance",
  };
  for (const [key, id] of Object.entries(mapping))
    if (item.overrides[key] !== undefined)
      $(id).value = Number(item.overrides[key]);
  for (const key of ["raiseLate", "lowerEarly"])
    if (item.overrides[key] !== undefined)
      $(key).checked = item.overrides[key] === "true";
  $("config-note").textContent =
    `${item.name}: ${JSON.stringify(item.overrides)}. Only width, radius, correction distance and lift/lower overrides are applied. Missing dimensions retain the current test geometry; configuration variants are not auto-selected.` +
    ($("preset").value === "plough"
      ? " PW geometry is initialised from the Challenger 55 + PW log: 13 m effective steering length, 4.6/18.3 m front/rear marker setbacks and 2.5 s lowering. The single-trailer model remains approximate."
      : "");
  updateControls();
};
