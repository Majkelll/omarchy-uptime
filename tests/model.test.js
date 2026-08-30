const assert = require("assert")
const Model = require("../Model.js")

// ------------------------------------------------------------------ address

assert.deepStrictEqual(Model.parseAddress("example.com"), {
  origin: "https://example.com",
  path: ""
})
assert.deepStrictEqual(Model.parseAddress("example.com/hc"), {
  origin: "https://example.com",
  path: "/hc"
})
assert.deepStrictEqual(Model.parseAddress("http://localhost:3000/up?full=1"), {
  origin: "http://localhost:3000",
  path: "/up?full=1"
})
// A bare host keeps its port, and the scheme is lower-cased along with it
assert.deepStrictEqual(Model.parseAddress("HTTPS://Example.COM/HC"), {
  origin: "https://example.com",
  path: "/HC"
})
assert.deepStrictEqual(Model.parseAddress("   "), { origin: "", path: "" })

assert.strictEqual(Model.normalizePath("hc"), "/hc")
assert.strictEqual(Model.normalizePath("/hc/"), "/hc")
assert.strictEqual(Model.normalizePath("/"), "")
assert.strictEqual(Model.normalizePath(""), "")
assert.strictEqual(Model.normalizePath("?probe=1"), "?probe=1")

assert.strictEqual(Model.isPlausibleHost("example.com"), true)
assert.strictEqual(Model.isPlausibleHost("localhost:3000"), true)
assert.strictEqual(Model.isPlausibleHost("127.0.0.1"), true)
assert.strictEqual(Model.isPlausibleHost("not a host"), false)
assert.strictEqual(Model.isPlausibleHost("nodots"), false)

// -------------------------------------------------------------------- sites

const site = Model.normalizeSite({ origin: "example.com/hc" }, [])
assert.strictEqual(site.origin, "https://example.com")
assert.strictEqual(site.path, "/hc")
assert.strictEqual(site.id, "example-com-hc")
assert.strictEqual(site.intervalSeconds, Model.DEFAULT_INTERVAL)
assert.strictEqual(site.failuresBeforeAlert, Model.DEFAULT_FAILURES)
assert.strictEqual(site.enabled, true)
assert.strictEqual(Model.targetUrl(site), "https://example.com/hc")
assert.strictEqual(Model.addressLabel(site), "example.com/hc")
assert.strictEqual(Model.labelFor(site), "example.com")

// An explicit path field wins over one carried by the address
const split = Model.normalizeSite({ origin: "example.com/ignored", path: "/hc" }, [])
assert.strictEqual(split.path, "/hc")

// Out-of-range numbers are clamped rather than rejected: a hand-edited file
// should not be able to schedule a check every millisecond
const clamped = Model.normalizeSite({ origin: "a.test", intervalSeconds: 1, timeoutSeconds: 999 }, [])
assert.strictEqual(clamped.intervalSeconds, Model.MIN_INTERVAL)
assert.strictEqual(clamped.timeoutSeconds, 60)

// Two rows that normalize to the same id still get distinct ones
const twins = Model.normalizeSites([{ origin: "a.test" }, { origin: "a.test" }])
assert.deepStrictEqual(twins.map(row => row.id), ["a-test", "a-test-2"])

// Rows without a host are dropped: they can never be checked
assert.deepStrictEqual(Model.normalizeSites([{ name: "nothing" }, { origin: "a.test" }]).length, 1)

// ------------------------------------------------------------------- config

assert.deepStrictEqual(Model.parseConfig(""), { sites: [], error: "" })
assert.strictEqual(Model.parseConfig("{ nope").error, "sites.json is not valid JSON")
assert.strictEqual(Model.parseConfig('{"version":1}').error, "sites.json has no sites array")

// A bare array is accepted too, so a hand-written file does not need the wrapper
assert.strictEqual(Model.parseConfig('[{"origin":"a.test"}]').sites.length, 1)

const roundTripped = Model.parseConfig(Model.serializeConfig(twins)).sites
assert.deepStrictEqual(roundTripped, twins)

// ---------------------------------------------------------------- validation

const existing = Model.normalizeSites([{ origin: "example.com", path: "/hc" }])
assert.strictEqual(Model.validate("example.com", "/hc", 60, existing, ""), "That address is already on the list")
assert.strictEqual(Model.validate("example.com", "/other", 60, existing, ""), "")
// The row being edited does not count as its own duplicate
assert.strictEqual(Model.validate("example.com", "/hc", 60, existing, existing[0].id), "")
assert.strictEqual(Model.validate("", "", 60, existing, ""), "Enter a site address")
assert.strictEqual(Model.validate("nodots", "", 60, existing, ""), "That does not look like a host name")
assert.strictEqual(Model.validate("fine.test", "", 2, existing, ""),
  "Check no more often than every " + Model.MIN_INTERVAL + " seconds")

// --------------------------------------------------------------------- edits

const edited = Model.updateSite(existing, existing[0].id, { intervalSeconds: 300, path: "/healthz" })
assert.strictEqual(edited[0].intervalSeconds, 300)
assert.strictEqual(edited[0].path, "/healthz")
// The id is the join with the outage history, so an edit must not change it
assert.strictEqual(edited[0].id, existing[0].id)
assert.deepStrictEqual(Model.withoutSite(existing, existing[0].id), [])
assert.strictEqual(Model.findSite(existing, existing[0].id), existing[0])
assert.strictEqual(Model.findSite(existing, "missing"), null)

// ---------------------------------------------------------------- scheduling

const scheduled = Model.normalizeSites([
  { id: "fast", origin: "a.test", intervalSeconds: 10 },
  { id: "slow", origin: "b.test", intervalSeconds: 600 },
  { id: "off", origin: "c.test", enabled: false }
])
const now = 1_800_000_000_000

// Never checked means due, whatever the interval
assert.deepStrictEqual(Model.dueSites(scheduled, {}, now).map(s => s.id), ["fast", "slow"])

const checkedRecently = {
  fast: Object.assign(Model.emptyRecord(), { checkedAt: now - 11_000 }),
  slow: Object.assign(Model.emptyRecord(), { checkedAt: now - 11_000 })
}
assert.deepStrictEqual(Model.dueSites(scheduled, checkedRecently, now).map(s => s.id), ["fast"])

assert.strictEqual(Model.checkArgs(scheduled[0]), "fast\thttps://a.test\t5\t0")

// ------------------------------------------------------------------- results

const results = Model.parseResults([
  "fast\tok\t200\t84\t",
  "slow\tfail\t000\t0\ttimeout",
  "",
  "garbage"
].join("\n"))
assert.deepStrictEqual(results, [
  { id: "fast", ok: true, code: "200", latencyMs: 84, reason: "" },
  { id: "slow", ok: false, code: "000", latencyMs: 0, reason: "timeout" }
])

// -------------------------------------------------------------- state machine

const target = Model.normalizeSite({ id: "t", origin: "a.test", failuresBeforeAlert: 2 }, [])
const fail = { id: "t", ok: false, code: "000", latencyMs: 0, reason: "timeout" }
const ok = { id: "t", ok: true, code: "200", latencyMs: 12, reason: "" }

// First answer is a transition into "up", but nothing worth a notification
let step = Model.applyResult(null, target, ok, 1000)
assert.strictEqual(step.record.state, "up")
assert.strictEqual(step.transition, "")

// One failure is not an outage yet - that is the whole point of the threshold
step = Model.applyResult(step.record, target, fail, 2000)
assert.strictEqual(step.record.state, "up")
assert.strictEqual(step.record.failures, 1)
assert.strictEqual(step.transition, "")
assert.deepStrictEqual(step.record.outages, [])

// The second consecutive failure opens an outage and alerts once
step = Model.applyResult(step.record, target, fail, 3000)
assert.strictEqual(step.record.state, "down")
assert.strictEqual(step.transition, "down")
assert.deepStrictEqual(step.record.outages, [
  { startedAt: 3000, endedAt: 0, code: "000", reason: "timeout" }
])

// Staying down does not alert again, and does not open a second outage
step = Model.applyResult(step.record, target, fail, 4000)
assert.strictEqual(step.transition, "")
assert.strictEqual(step.record.outages.length, 1)

// Recovery closes the open outage and alerts once
step = Model.applyResult(step.record, target, ok, 9000)
assert.strictEqual(step.record.state, "up")
assert.strictEqual(step.transition, "up")
assert.strictEqual(step.record.failures, 0)
assert.deepStrictEqual(step.record.outages, [
  { startedAt: 3000, endedAt: 9000, code: "000", reason: "timeout" }
])

// A second outage stacks on top, newest first
step = Model.applyResult(step.record, target, fail, 10_000)
step = Model.applyResult(step.record, target, fail, 11_000)
assert.strictEqual(step.record.outages.length, 2)
assert.strictEqual(step.record.outages[0].startedAt, 11_000)
assert.strictEqual(step.record.outages[1].endedAt, 9000)

// A site alerting on the first failure skips the grace period entirely
const touchy = Model.normalizeSite({ id: "t", origin: "a.test", failuresBeforeAlert: 1 }, [])
assert.strictEqual(Model.applyResult(null, touchy, fail, 1000).transition, "down")

// History is capped, oldest dropped first
let capped = Model.emptyRecord()
for (let i = 0; i < Model.MAX_OUTAGES + 5; i++) {
  capped = Model.applyResult(capped, touchy, fail, 1000 + i * 2000).record
  capped = Model.applyResult(capped, touchy, ok, 2000 + i * 2000).record
}
assert.strictEqual(capped.outages.length, Model.MAX_OUTAGES)

// --------------------------------------------------------------------- state

const persisted = { t: step.record }
const revived = Model.parseState(Model.serializeState(persisted, [target]))
assert.deepStrictEqual(revived.t, step.record)
// A record whose site is gone is not carried forward
assert.deepStrictEqual(Model.parseState(Model.serializeState(persisted, [])), {})
assert.deepStrictEqual(Model.parseState("not json"), {})
assert.strictEqual(Model.recordFor({}, "missing").state, "unknown")

// ------------------------------------------------------------------- summary

const watched = Model.normalizeSites([
  { id: "up1", origin: "a.test" },
  { id: "up2", origin: "b.test" },
  { id: "bad", origin: "c.test", name: "myapp" },
  { id: "off", origin: "d.test", enabled: false }
])
const mixed = {
  up1: Object.assign(Model.emptyRecord(), { state: "up" }),
  up2: Object.assign(Model.emptyRecord(), { state: "up" }),
  bad: Object.assign(Model.emptyRecord(), { state: "down" })
}
const mixedSummary = Model.summary(watched, mixed)
assert.strictEqual(mixedSummary.state, "down")
assert.strictEqual(mixedSummary.total, 3)
assert.strictEqual(mixedSummary.disabled, 1)
assert.strictEqual(mixedSummary.text, "2 of 3 up - myapp is down, 1 paused")

const healthy = Model.summary(watched, {
  up1: mixed.up1,
  up2: mixed.up2,
  bad: Object.assign(Model.emptyRecord(), { state: "up" })
})
assert.strictEqual(healthy.state, "up")
assert.strictEqual(healthy.text, "All 3 up, 1 paused")

// More than one outage counts them rather than picking a name to lead with
const twoDown = Model.summary(watched, {
  up1: Object.assign(Model.emptyRecord(), { state: "down" }),
  up2: mixed.up2,
  bad: mixed.bad
})
assert.strictEqual(twoDown.text, "1 of 3 up - 2 sites down, 1 paused")

assert.strictEqual(Model.summary([], {}).text, "No sites watched")
// Every site paused is not the same as no sites at all
assert.strictEqual(Model.summary(Model.normalizeSites([{ origin: "a.test", enabled: false }]), {}).text,
  "1 site paused")
assert.strictEqual(Model.summary(watched, {}).text, "Checking 3 sites...")

// Nothing down but not everything answered yet is not "all up"
const partial = Model.summary(watched, { up1: mixed.up1 })
assert.strictEqual(partial.state, "up")
assert.strictEqual(partial.text, "1 of 3 up, 2 still checking, 1 paused")

// ---------------------------------------------------------------- formatting

assert.strictEqual(Model.formatDuration(900), "1s")
assert.strictEqual(Model.formatDuration(59_000), "59s")
assert.strictEqual(Model.formatDuration(90_000), "1m")
assert.strictEqual(Model.formatDuration(3_600_000), "1h")
assert.strictEqual(Model.formatDuration(5_400_000), "1h 30m")
assert.strictEqual(Model.formatDuration(86_400_000), "1d")
assert.strictEqual(Model.formatDuration(90_000_000), "1d 1h")

// Built from local-time parts so the assertion holds in any timezone
const stampAt = new Date(2026, 7, 28, 9, 5).getTime()
assert.strictEqual(Model.formatStamp(stampAt), "28 Aug 09:05")
assert.strictEqual(Model.formatStamp(0), "")

assert.strictEqual(Model.formatAgo(0, now), "never")
assert.strictEqual(Model.formatAgo(now - 5000, now), "just now")
assert.strictEqual(Model.formatAgo(now - 300_000, now), "5m ago")

assert.strictEqual(Model.latencyLabel({ latencyMs: 84 }), "84 ms")
assert.strictEqual(Model.latencyLabel({ latencyMs: 2400 }), "2.4 s")
assert.strictEqual(Model.latencyLabel({ latencyMs: 0 }), "")

assert.strictEqual(Model.failureLabel({ code: "503", reason: "" }), "HTTP 503")
assert.strictEqual(Model.failureLabel({ code: "000", reason: "timeout" }), "timeout")
assert.strictEqual(Model.failureLabel({ code: "000", reason: "" }), "no answer")

const downRecord = Object.assign(Model.emptyRecord(), {
  state: "down", since: now - 300_000, code: "503", checkedAt: now - 8000
})
assert.strictEqual(Model.statusLine(watched[0], downRecord, now),
  "Down 5m - HTTP 503 - checked just now")

const upRecord = Object.assign(Model.emptyRecord(), {
  state: "up", since: now - 7_200_000, latencyMs: 84, checkedAt: now - 120_000
})
assert.strictEqual(Model.statusLine(watched[0], upRecord, now), "Up 2h - 84 ms - checked 2m ago")

// A record with no check behind it says nothing about when it was read
assert.strictEqual(
  Model.statusLine(watched[0], Object.assign({}, upRecord, { checkedAt: 0 }), now),
  "Up 2h - 84 ms")

// A site that is failing but not yet down says so, so the next alert is no surprise
assert.strictEqual(
  Model.statusLine(watched[0], Object.assign({}, upRecord, { failures: 1 }), now),
  "Up 2h - 84 ms - 1 failing check - checked 2m ago")

assert.strictEqual(Model.statusLine(watched[0], Model.emptyRecord(), now), "Not checked yet")
assert.strictEqual(Model.statusLine(watched[3], Model.emptyRecord(), now), "Paused")

assert.strictEqual(Model.scheduleLine(watched[0]),
  "Every 1m - expects any 2xx/3xx - alerts after 2 failures")
assert.strictEqual(
  Model.scheduleLine(Model.normalizeSite(
    { origin: "a.test", intervalSeconds: 30, expectedStatus: 204, failuresBeforeAlert: 1, enabled: false }, [])),
  "Every 30s - expects 204 - alerts after 1 failure - paused")

assert.strictEqual(Model.outageLabel({ startedAt: stampAt, endedAt: stampAt + 840_000 }, now),
  "28 Aug 09:05 - 14m")
assert.strictEqual(Model.outageLabel({ startedAt: stampAt, endedAt: 0 }, now), "28 Aug 09:05 - ongoing")
assert.strictEqual(Model.outageDetail({ code: "500" }), "HTTP 500")
assert.strictEqual(Model.outageDetail({ code: "000", reason: "dns failure" }), "dns failure")
assert.strictEqual(Model.outageSummary(Model.emptyRecord()), "No outages recorded")
assert.strictEqual(Model.outageSummary(step.record), "2 outages")

console.log("model tests passed")
