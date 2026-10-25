// Public Worker entry points only. All HTTP and KV operations are local mocks.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// Load the exact ES module without adding a package.json or changing worker.js.
const source = await readFile(new URL("./worker.js", import.meta.url), "utf8");
const { default: worker } = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
);
const API = "https://api.github.com/repos/frewily/Free-From-RainClassroom/actions/workflows/python-app.yml/dispatches";
const RAW = "https://raw.githubusercontent.com/frewily/Free-From-RainClassroom/main/data/course_schedule.json";
const DAY = "2026-10-20";
const KEY = `rainclassroom:${DAY}:08:00`;
const course = (overrides = {}) => ({
  course: "示例课程", date: DAY, start: "08:00", end: "09:40", ...overrides
});

function harness(t, options = {}) {
  const calls = [], writes = [], reads = [], logs = [];
  const records = new Map(options.records);
  const env = {
    GITHUB_TOKEN: "fake-local-github-token",
    TEST_TRIGGER_KEY: "fake-local-test-key",
    TRIGGER_KV: {
      async get(key) {
        reads.push(key);
        return options.get ? options.get(key) : (records.get(key) ?? null);
      },
      async put(key, value, settings) {
        if (options.putError) throw new Error("mock KV write failure");
        writes.push({ key, value: JSON.parse(value), settings });
        records.set(key, value);
      }
    }
  };
  t.mock.method(console, "log", (...args) => logs.push(args.join(" ")));
  t.mock.method(console, "error", (...args) => logs.push(args.join(" ")));
  t.mock.method(globalThis, "fetch", async (url, init) => {
    calls.push({ url, init });
    if (url === RAW) {
      if (options.schedule) return options.schedule(init);
      if (options.scheduleError) throw new Error("mock schedule network failure");
      if (options.invalidJSON) return new Response("not JSON");
      return Response.json(options.payload ?? { classes: options.classes ?? [course()] }, {
        status: options.scheduleStatus ?? 200
      });
    }
    if (url === API) {
      if (options.dispatch) return options.dispatch(init);
      return new Response(null, { status: options.dispatchStatus ?? 204 });
    }
    throw new Error(`Unexpected outbound request blocked: ${url}`);
  });
  return { env, calls, writes, reads, logs, records,
    dispatches: () => calls.filter(call => call.url === API) };
}

function request(path = "/preview", body = { at: `${DAY}T08:00` }, overrides = {}) {
  return new Request(`https://scheduler.invalid${path}`, {
    method: "POST",
    headers: { Authorization: "Bearer fake-local-test-key", "Content-Type": "application/json" },
    body: JSON.stringify(body),
    ...overrides
  });
}

function clock(t, at) {
  t.mock.timers.enable({ apis: ["Date"], now: new Date(at) });
}

for (const [at, matched] of [
  ["07:59", false], ["08:00", true], ["08:05", true],
  ["08:14", true], ["08:15", false], ["09:40", false]
]) {
  test(`preview window ${at}: ${matched ? "match" : "skip"}`, async t => {
    const h = harness(t);
    const response = await worker.fetch(request("/preview", { at: `${DAY}T${at}` }), h.env);
    assert.equal(response.status, 200);
    const result = await response.json();
    assert.equal(result.results.length, Number(matched));
    if (matched) assert.equal(result.results[0].status, "would_dispatch");
    assert.equal(result.dispatchEnabled, false);
    assert.equal(h.dispatches().length, 0);
    assert.equal(h.writes.length, 0);
  });
}

for (const [utc, localDay, localTime] of [
  ["2026-10-19T23:59:00Z", DAY, "07:59"],
  ["2026-10-20T00:00:00Z", DAY, "08:00"],
  ["2026-12-31T16:00:00Z", "2027-01-01", "00:00"]
]) {
  test(`Cron UTC+8 date conversion: ${utc}`, async t => {
    const h = harness(t, { classes: [course({ date: localDay, start: localTime, end: "23:59" })] });
    clock(t, utc);
    await worker.scheduled({}, h.env, {});
    assert.equal(h.writes[0].key, `rainclassroom:${localDay}:${localTime}`);
  });
}

test("14:59 after start is allowed, but class end is exclusive", async t => {
  const h = harness(t, { classes: [course(), course({ start: "08:10", end: "08:14" })] });
  clock(t, "2026-10-20T00:14:59Z");
  await worker.scheduled({}, h.env, {});
  assert.equal(h.dispatches().length, 1);
  assert.deepEqual(h.writes[0].value.courses, ["示例课程"]);
});

test("same date/start merges courses, with expected API and 14-day KV TTL", async t => {
  const h = harness(t, { classes: [course(), course({ course: "第二门课" }), course({ date: "2026-10-21" })] });
  clock(t, "2026-10-20T00:00:00Z");
  await worker.scheduled({}, h.env, {});
  assert.equal(h.dispatches().length, 1);
  const call = h.dispatches()[0];
  assert.equal(call.init.method, "POST");
  assert.deepEqual(JSON.parse(call.init.body), { ref: "main" });
  assert.equal(call.init.headers.Authorization, `Bearer ${h.env.GITHUB_TOKEN}`);
  assert.equal(call.init.headers["X-GitHub-Api-Version"], "2022-11-28");
  assert.equal(h.calls[0].url, RAW);
  assert.equal(h.calls[0].init.headers.Authorization, undefined);
  assert.equal(h.writes[0].key, KEY);
  assert.equal(h.writes[0].settings.expirationTtl, 1209600);
  assert.deepEqual(h.writes[0].value.courses, ["示例课程", "第二门课"]);
  assert.equal(h.writes[0].value.status, "dispatched");
  assert.ok(h.logs.every(line => !line.includes(h.env.GITHUB_TOKEN) && !line.includes(h.env.TEST_TRIGGER_KEY)));
});

test("distinct starts within the window dispatch separately", async t => {
  const h = harness(t, { classes: [course(), course({ start: "08:05" })] });
  clock(t, "2026-10-20T00:05:00Z");
  await worker.scheduled({}, h.env, {});
  assert.equal(h.dispatches().length, 2);
});

test("Cron ignores env.AUTO_DISPATCH=false: switch is the source constant", async t => {
  const h = harness(t);
  h.env.AUTO_DISPATCH = "false";
  clock(t, "2026-10-20T00:00:00Z");
  await worker.scheduled({}, h.env, {});
  assert.equal(h.dispatches().length, 1);
});

test("existing KV key skips Cron and is visible to preview without writes", async t => {
  const h = harness(t, { records: [[KEY, "accepted"]] });
  clock(t, "2026-10-20T00:00:00Z");
  await worker.scheduled({}, h.env, {});
  const result = await (await worker.fetch(request(), h.env)).json();
  assert.equal(result.results[0].status, "already_dispatched");
  assert.equal(h.dispatches().length, 0);
  assert.equal(h.writes.length, 0);
});

test("sequential Cron calls skip after a successful write", async t => {
  const h = harness(t);
  clock(t, "2026-10-20T00:00:00Z");
  await worker.scheduled({}, h.env, {});
  await worker.scheduled({}, h.env, {});
  assert.equal(h.dispatches().length, 1);
});

for (const status of [200, 401, 403, 404, 422, 500]) {
  test(`dispatch HTTP ${status} is rejected and does not write KV`, async t => {
    const h = harness(t, { dispatchStatus: status });
    clock(t, "2026-10-20T00:00:00Z");
    await assert.rejects(worker.scheduled({}, h.env, {}), /GitHub dispatch failed/);
    assert.equal(h.writes.length, 0);
  });
}

test("known limitation: accepted dispatch + KV failure can dispatch again", async t => {
  const h = harness(t, { putError: true });
  clock(t, "2026-10-20T00:00:00Z");
  await assert.rejects(worker.scheduled({}, h.env, {}), /KV write failure/);
  await assert.rejects(worker.scheduled({}, h.env, {}), /KV write failure/);
  assert.equal(h.dispatches().length, 2);
});

test("known limitation: overlapping KV misses both dispatch", async t => {
  let release;
  const barrier = new Promise(resolve => { release = resolve; });
  let readers = 0;
  const h = harness(t, { get: async () => {
    if (++readers === 2) release();
    await barrier;
    return null;
  } });
  clock(t, "2026-10-20T00:00:00Z");
  await Promise.all([worker.scheduled({}, h.env, {}), worker.scheduled({}, h.env, {})]);
  assert.equal(h.dispatches().length, 2);
});

test("known limitation: lost dispatch response leaves no KV and later retries", async t => {
  let received = 0;
  const h = harness(t, { dispatch: async () => {
    received++; // The mock server receives it, then the response is lost.
    throw new Error("mock response lost after acceptance");
  } });
  clock(t, "2026-10-20T00:00:00Z");
  await assert.rejects(worker.scheduled({}, h.env, {}), /response lost/);
  await assert.rejects(worker.scheduled({}, h.env, {}), /response lost/);
  assert.equal(received, 2);
  assert.equal(h.writes.length, 0);
  assert.ok(h.dispatches().every(call => call.init.signal === undefined));
});

test("health, unknown path, and wrong method never contact GitHub", async t => {
  const h = harness(t);
  for (const [path, status] of [["/", 200], ["/unknown", 404], ["/test", 405], ["/preview", 405]]) {
    const response = await worker.fetch(new Request(`https://scheduler.invalid${path}`), {});
    assert.equal(response.status, status);
  }
  assert.equal(h.calls.length, 0);
});

for (const path of ["/test", "/preview"]) {
  test(`${path} requires exact Bearer key and both configured Secrets`, async t => {
    const h = harness(t);
    for (const authorization of [null, "Bearer wrong", "fake-local-test-key"]) {
      const headers = authorization ? { Authorization: authorization } : {};
      assert.equal((await worker.fetch(request(path, {}, { headers }), h.env)).status, 401);
    }
    assert.equal((await worker.fetch(request(path), { TEST_TRIGGER_KEY: "fake-local-test-key" })).status, 500);
    assert.equal((await worker.fetch(request(path), { GITHUB_TOKEN: "fake-local-github-token" })).status, 500);
    assert.equal(h.calls.length, 0);
  });
}

test("/test dispatches every call without schedule/KV, even with env switch false", async t => {
  const h = harness(t);
  delete h.env.TRIGGER_KV;
  h.env.AUTO_DISPATCH = false;
  for (let i = 0; i < 2; i++) assert.equal((await worker.fetch(request("/test", {}), h.env)).status, 200);
  assert.equal(h.calls.length, 2);
  assert.equal(h.dispatches().length, 2);
  assert.equal(h.reads.length, 0);
});

test("/test reports upstream failure as HTTP 500", async t => {
  const h = harness(t, { dispatchStatus: 403 });
  assert.equal((await worker.fetch(request("/test", {}), h.env)).status, 500);
});

for (const body of [{}, { at: 123 }, { at: "2026-10-20T08:00Z" }, { at: "2026-13-20T08:00" }]) {
  test(`preview rejects invalid at: ${JSON.stringify(body)}`, async t => {
    const h = harness(t);
    assert.equal((await worker.fetch(request("/preview", body), h.env)).status, 400);
    assert.equal(h.calls.length, 0);
  });
}

test("known limitation: invalid JSON and null preview bodies return 500", async t => {
  const h = harness(t);
  assert.equal((await worker.fetch(request("/preview", {}, { body: "not JSON" }), h.env)).status, 500);
  assert.equal((await worker.fetch(request("/preview", null), h.env)).status, 500);
  assert.equal(h.calls.length, 0);
});

test("known limitation: JS normalizes impossible calendar dates", async t => {
  const h = harness(t, { classes: [] });
  const response = await worker.fetch(request("/preview", { at: "2026-02-30T08:00" }), h.env);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).date, "2026-03-02");
  assert.equal(h.dispatches().length, 0);
});

for (const options of [
  { scheduleStatus: 503 }, { invalidJSON: true },
  { payload: { classes: "invalid" } }, { classes: [null] },
  { classes: [course({ start: undefined })] }, { scheduleError: true }
]) {
  test(`schedule error stops before dispatch: ${JSON.stringify(options)}`, async t => {
    const h = harness(t, options);
    clock(t, "2026-10-20T00:00:00Z");
    await assert.rejects(worker.scheduled({}, h.env, {}));
    assert.equal(h.dispatches().length, 0);
    assert.equal(h.writes.length, 0);
  });
}

test("missing KV fails before reading schedule", async t => {
  const h = harness(t);
  delete h.env.TRIGGER_KV;
  assert.equal((await worker.fetch(request(), h.env)).status, 500);
  assert.equal(h.calls.length, 0);
});

for (const phase of ["response", "body"]) {
  for (const entry of ["cron", "preview"]) {
    test(`schedule download timeout during ${phase} via ${entry}`, async t => {
      const controller = new AbortController();
      t.mock.method(AbortSignal, "timeout", milliseconds => {
        assert.equal(milliseconds, 10_000);
        return controller.signal;
      });
      let started;
      const reading = new Promise(resolve => { started = resolve; });
      const stalled = signal => {
        started();
        assert.ok(signal instanceof AbortSignal);
        return new Promise((_, reject) => {
          signal.addEventListener("abort", () => reject(signal.reason), { once: true });
        });
      };
      const h = harness(t, { schedule: ({ signal }) => phase === "response"
        ? stalled(signal) : { ok: true, json: () => stalled(signal) } });
      const pending = entry === "cron"
        ? worker.scheduled({}, h.env, {}) : worker.fetch(request(), h.env);
      const checked = entry === "cron"
        ? assert.rejects(pending, /获取课表超时/)
        : pending.then(response => {
          assert.equal(response.status, 500);
          assert.match(h.logs.join("\n"), /获取课表超时/);
        });
      await reading;
      controller.abort(new DOMException("private-timeout-detail", "TimeoutError"));
      await checked;
      assert.equal(h.calls.length, 1);
      assert.equal(h.dispatches().length, 0);
      assert.equal(h.reads.length, 0);
      assert.equal(h.writes.length, 0);
      assert.ok(h.logs.every(line => !line.includes("private-timeout-detail")));
    });
  }
}

for (const invalid of [
  { start: "bad", end: "bad" }, { start: "8:00" },
  { start: "08:60" }, { start: "24:00" }, { start: "08:00\n" },
  { start: null }, { start: 800 }, { end: undefined },
  { end: "08:00" }, { end: "07:59" },
  { date: "2026-10-21", start: "bad" },
]) {
  test(`invalid timetable time rejected before any dispatch: ${JSON.stringify(invalid)}`, async t => {
    const h = harness(t, { classes: [course(), course(invalid)] });
    clock(t, "2026-10-20T00:00:00Z");
    await assert.rejects(worker.scheduled({}, h.env, {}), /课表.*时间/);
    assert.equal(h.dispatches().length, 0);
    assert.equal(h.reads.length, 0);
    assert.equal(h.writes.length, 0);
  });
}

test("preview reports invalid timetable time without exposing its contents", async t => {
  const h = harness(t, { classes: [course({ end: "private-invalid-time" })] });
  const response = await worker.fetch(request(), h.env);
  assert.equal(response.status, 500);
  assert.equal(h.dispatches().length, 0);
  assert.equal(h.reads.length, 0);
  assert.equal(h.writes.length, 0);
  assert.ok(h.logs.every(line => !line.includes("private-invalid-time")));
});

test("known limitation: Worker does not filter selected_courses or semester", async t => {
  const h = harness(t, { payload: { semester: 0, selected_courses: [], classes: [course()] } });
  clock(t, "2026-10-20T00:00:00Z");
  await worker.scheduled({}, h.env, {});
  assert.equal(h.dispatches().length, 1);
});
