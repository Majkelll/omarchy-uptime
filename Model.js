// Pure configuration, scheduling, and outage-history logic for the Uptime
// plugin. Deliberately free of Qt so the same file backs the QML plugin and
// the Node tests in tests/.

var DEFAULT_INTERVAL = 60
var DEFAULT_TIMEOUT = 5
var DEFAULT_FAILURES = 2

// A ten second floor keeps a fat-fingered interval from turning the plugin
// into a load generator; a day is as coarse as a check can get and still be
// worth a bar widget.
var MIN_INTERVAL = 10
var MAX_INTERVAL = 86400
var MIN_TIMEOUT = 1
var MAX_TIMEOUT = 60
var MAX_FAILURES = 10
var MAX_OUTAGES = 50

// Shown wherever the summary would otherwise claim to know something.
var OFFLINE_TEXT = "No connection - checks paused"

// The whole plugin stopped on purpose, which is a different thing from a site
// being paused and a different thing again from having no connection.
var PAUSED_TEXT = "Checks paused"

// Used only when the active theme carries neither an orange nor a yellow.
var DEFAULT_WARNING = "#e0a458"

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function clean(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

function toInt(value, fallback) {
  var parsed = parseInt(value, 10)
  return isFinite(parsed) ? parsed : fallback
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

function pad(value) {
  return value < 10 ? "0" + value : String(value)
}

// ------------------------------------------------------------------ address

// A path is stored separately from the origin so the row can show "/hc" as its
// own field and an empty path means "just the site". Anything the user types
// is coerced into that shape: leading slash added, trailing slash dropped,
// query and fragment preserved.
function normalizePath(raw) {
  var text = clean(raw)
  if (text === "" || text === "/") return ""
  var first = text.charAt(0)
  if (first !== "/" && first !== "?" && first !== "#") text = "/" + text
  while (text.length > 1 && text.charAt(text.length - 1) === "/") text = text.slice(0, -1)
  return text
}

// Splits whatever the user pasted into an origin and a path. A missing scheme
// becomes https, since that is what anyone typing "example.com" means.
function parseAddress(raw) {
  var text = clean(raw)
  if (text === "") return { origin: "", path: "" }

  var scheme = "https://"
  var rest = text
  var schemed = /^([a-zA-Z][a-zA-Z0-9+.-]*:\/\/)([\s\S]*)$/.exec(text)
  if (schemed) {
    scheme = schemed[1].toLowerCase()
    rest = schemed[2]
  }

  var cut = rest.search(/[\/?#]/)
  var host = cut === -1 ? rest : rest.slice(0, cut)
  var path = cut === -1 ? "" : rest.slice(cut)
  if (clean(host) === "") return { origin: "", path: "" }
  return { origin: scheme + host.toLowerCase(), path: normalizePath(path) }
}

function hostOf(origin) {
  return clean(origin).replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, "")
}

function targetUrl(site) {
  if (!site) return ""
  return clean(site.origin) + clean(site.path)
}

function addressLabel(site) {
  if (!site) return ""
  return hostOf(site.origin) + clean(site.path)
}

function labelFor(site) {
  if (!site) return ""
  var name = clean(site.name)
  return name !== "" ? name : hostOf(site.origin)
}

function isPlausibleHost(host) {
  var text = clean(host).toLowerCase()
  if (text === "") return false
  if (text.indexOf(" ") !== -1) return false
  // A bracketed IPv6 literal carries colons of its own, so it is judged whole
  // rather than split on the first colon the way a host:port pair is.
  if (text.charAt(0) === "[") return text.indexOf("]") > 1
  var bare = text.split(":")[0]
  return bare.indexOf(".") !== -1 || bare === "localhost" || /^\d+(\.\d+){3}$/.test(bare)
}

// --------------------------------------------------------------------- sites

function slug(text) {
  var base = clean(text).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
  return base === "" ? "site" : base
}

function uniqueId(seed, taken) {
  var used = taken || []
  var base = slug(seed)
  var id = base
  var suffix = 2
  while (used.indexOf(id) !== -1) {
    id = base + "-" + suffix
    suffix++
  }
  return id
}

function expectedStatusOf(value) {
  var status = toInt(value, 0)
  return status >= 100 && status <= 599 ? status : 0
}

// Fills in every field the rest of the plugin assumes is present, from either
// a hand-edited sites.json row or the panel's add form.
function normalizeSite(raw, taken) {
  var source = raw || {}
  var parsed = parseAddress(source.origin !== undefined ? source.origin : source.url)
  var explicitPath = clean(source.path)
  var site = {
    id: clean(source.id),
    name: clean(source.name),
    origin: parsed.origin,
    path: explicitPath !== "" ? normalizePath(explicitPath) : parsed.path,
    intervalSeconds: clamp(toInt(source.intervalSeconds, DEFAULT_INTERVAL), MIN_INTERVAL, MAX_INTERVAL),
    timeoutSeconds: clamp(toInt(source.timeoutSeconds, DEFAULT_TIMEOUT), MIN_TIMEOUT, MAX_TIMEOUT),
    expectedStatus: expectedStatusOf(source.expectedStatus),
    failuresBeforeAlert: clamp(toInt(source.failuresBeforeAlert, DEFAULT_FAILURES), 1, MAX_FAILURES),
    enabled: source.enabled !== false
  }
  if (site.id === "" || (taken && taken.indexOf(site.id) !== -1))
    site.id = uniqueId(addressLabel(site), taken || [])
  return site
}

function normalizeSites(list) {
  var rows = Array.isArray(list) ? list : []
  var taken = []
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var site = normalizeSite(rows[i], taken)
    // A row without a host can never be checked; dropping it here keeps every
    // later stage from having to ask.
    if (site.origin === "") continue
    taken.push(site.id)
    out.push(site)
  }
  return out
}

// Tolerant on purpose: sites.json is a file people edit by hand, and a broken
// one should surface as a message in the panel rather than an empty plugin
// that silently forgot every site.
function parseConfig(text) {
  var raw = clean(text)
  if (raw === "") return { sites: [], paused: false, error: "" }

  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (error) {
    return { sites: [], paused: false, error: "sites.json is not valid JSON" }
  }

  var list = Array.isArray(parsed)
    ? parsed
    : (parsed && Array.isArray(parsed.sites) ? parsed.sites : null)
  if (list === null) return { sites: [], paused: false, error: "sites.json has no sites array" }
  // Stopping the plugin outlives a restart: it lives in the file, next to the
  // sites it stops.
  var paused = !Array.isArray(parsed) && parsed.paused === true
  return { sites: normalizeSites(list), paused: paused, error: "" }
}

function serializeConfig(sites, paused) {
  var rows = []
  var list = Array.isArray(sites) ? sites : []
  for (var i = 0; i < list.length; i++) {
    var site = list[i]
    rows.push({
      id: site.id,
      name: site.name,
      origin: site.origin,
      path: site.path,
      intervalSeconds: site.intervalSeconds,
      timeoutSeconds: site.timeoutSeconds,
      expectedStatus: site.expectedStatus,
      failuresBeforeAlert: site.failuresBeforeAlert,
      enabled: site.enabled !== false
    })
  }
  return JSON.stringify({ version: 1, paused: paused === true, sites: rows }, null, 2) + "\n"
}

function buildSite(addressRaw, pathRaw, intervalRaw, sites) {
  var parsed = parseAddress(addressRaw)
  var explicitPath = clean(pathRaw)
  var taken = []
  var list = Array.isArray(sites) ? sites : []
  for (var i = 0; i < list.length; i++) taken.push(list[i].id)
  return normalizeSite({
    origin: parsed.origin,
    path: explicitPath !== "" ? explicitPath : parsed.path,
    intervalSeconds: toInt(intervalRaw, DEFAULT_INTERVAL)
  }, taken)
}

// Returns "" when the address can be added, or the reason it cannot. `ignoreId`
// exempts the row being edited from the duplicate check.
function validate(addressRaw, pathRaw, intervalRaw, sites, ignoreId) {
  var parsed = parseAddress(addressRaw)
  if (parsed.origin === "") return "Enter a site address"
  if (!isPlausibleHost(hostOf(parsed.origin))) return "That does not look like a host name"

  var interval = toInt(intervalRaw, DEFAULT_INTERVAL)
  if (interval < MIN_INTERVAL) return "Check no more often than every " + MIN_INTERVAL + " seconds"
  if (interval > MAX_INTERVAL) return "Check at least once a day"

  var explicitPath = clean(pathRaw)
  var url = parsed.origin + (explicitPath !== "" ? normalizePath(explicitPath) : parsed.path)
  var list = Array.isArray(sites) ? sites : []
  for (var i = 0; i < list.length; i++) {
    if (list[i].id === ignoreId) continue
    if (targetUrl(list[i]) === url) return "That address is already on the list"
  }
  return ""
}

function updateSite(sites, id, patch) {
  var list = Array.isArray(sites) ? sites : []
  var out = []
  var taken = []
  for (var i = 0; i < list.length; i++) {
    if (list[i].id !== id) {
      out.push(list[i])
      taken.push(list[i].id)
      continue
    }
    var merged = {}
    for (var key in list[i]) merged[key] = list[i][key]
    for (var change in (patch || {})) merged[change] = patch[change]
    // The id is the join with the history, so an edit keeps it even when the
    // address it was derived from changes.
    merged.id = list[i].id
    out.push(normalizeSite(merged, taken))
    taken.push(list[i].id)
  }
  return out
}

function withoutSite(sites, id) {
  var list = Array.isArray(sites) ? sites : []
  var out = []
  for (var i = 0; i < list.length; i++) if (list[i].id !== id) out.push(list[i])
  return out
}

function findSite(sites, id) {
  var list = Array.isArray(sites) ? sites : []
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
  return null
}

// --------------------------------------------------------------------- state

function emptyRecord() {
  return {
    state: "unknown",
    failures: 0,
    code: "",
    reason: "",
    latencyMs: 0,
    checkedAt: 0,
    since: 0,
    outages: []
  }
}

function normalizeOutage(raw) {
  var source = raw || {}
  return {
    startedAt: toInt(source.startedAt, 0),
    endedAt: toInt(source.endedAt, 0),
    code: clean(source.code),
    reason: clean(source.reason)
  }
}

function normalizeRecord(raw) {
  var source = raw || {}
  var record = emptyRecord()
  var state = clean(source.state)
  record.state = state === "up" || state === "down" ? state : "unknown"
  record.failures = Math.max(0, toInt(source.failures, 0))
  record.code = clean(source.code)
  record.reason = clean(source.reason)
  record.latencyMs = Math.max(0, toInt(source.latencyMs, 0))
  record.checkedAt = toInt(source.checkedAt, 0)
  record.since = toInt(source.since, 0)

  var outages = Array.isArray(source.outages) ? source.outages : []
  for (var i = 0; i < outages.length && i < MAX_OUTAGES; i++) {
    var outage = normalizeOutage(outages[i])
    if (outage.startedAt > 0) record.outages.push(outage)
  }
  return record
}

function parseState(text) {
  var raw = clean(text)
  if (raw === "") return {}
  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (error) {
    return {}
  }
  var sites = parsed && parsed.sites ? parsed.sites : {}
  var out = {}
  for (var id in sites) out[clean(id)] = normalizeRecord(sites[id])
  return out
}

// Records for sites that are no longer configured are dropped rather than
// carried forever; removing a site is the user saying they are done with it.
function serializeState(records, sites) {
  var kept = {}
  var list = Array.isArray(sites) ? sites : []
  for (var i = 0; i < list.length; i++) {
    var record = records ? records[list[i].id] : null
    if (record) kept[list[i].id] = record
  }
  return JSON.stringify({ version: 1, sites: kept }, null, 2) + "\n"
}

function recordFor(records, id) {
  var record = records ? records[id] : null
  return record ? record : emptyRecord()
}

// ---------------------------------------------------------------- scheduling

function dueSites(sites, records, nowMs) {
  var list = Array.isArray(sites) ? sites : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var site = list[i]
    if (site.enabled === false) continue
    var checkedAt = recordFor(records, site.id).checkedAt
    if (checkedAt <= 0 || nowMs - checkedAt >= site.intervalSeconds * 1000) out.push(site)
  }
  return out
}

// One tab-separated argument per target. Tabs are safe as the separator: none
// of the four fields can contain one.
function checkArgs(site) {
  return [site.id, targetUrl(site), site.timeoutSeconds, site.expectedStatus].join("\t")
}

// The connectivity line the check script emits before it probes anything.
// Absent or unreadable means "assume online": a probe that could not run must
// never be the reason a real outage goes unreported.
function parseNetwork(text) {
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (clean(parts[0]) !== "#network") continue
    var state = clean(parts[1])
    return {
      known: state === "online" || state === "offline",
      online: state !== "offline",
      detail: clean(parts.length > 2 ? parts[2] : "")
    }
  }
  return { known: false, online: true, detail: "" }
}

function parseResults(text) {
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    if (clean(lines[i]) === "") continue
    var parts = lines[i].split("\t")
    if (parts.length < 4) continue
    out.push({
      id: clean(parts[0]),
      ok: clean(parts[1]) === "ok",
      code: clean(parts[2]),
      latencyMs: Math.max(0, toInt(parts[3], 0)),
      reason: clean(parts.length > 4 ? parts[4] : "")
    })
  }
  return out
}

function openOutage(outages, outage) {
  var next = [outage]
  var list = Array.isArray(outages) ? outages : []
  for (var i = 0; i < list.length && next.length < MAX_OUTAGES; i++) next.push(list[i])
  return next
}

function closeOutage(outages, endedAt) {
  var list = Array.isArray(outages) ? outages : []
  if (list.length === 0 || list[0].endedAt > 0) return list
  var head = normalizeOutage(list[0])
  head.endedAt = endedAt
  return [head].concat(list.slice(1))
}

// The state machine, and the only place that decides a site is down. Returns
// the next record plus the transition worth telling the user about: "down"
// once a site has failed often enough to count as an outage, "up" when it
// answers again after one, "" for everything in between.
function applyResult(record, site, result, nowMs) {
  var next = normalizeRecord(record)
  next.checkedAt = nowMs
  next.code = result.code
  next.latencyMs = result.latencyMs
  next.reason = result.ok ? "" : result.reason

  if (result.ok) {
    next.failures = 0
    if (next.state === "down") {
      next.outages = closeOutage(next.outages, nowMs)
      next.state = "up"
      next.since = nowMs
      return { record: next, transition: "up" }
    }
    if (next.state !== "up") {
      next.state = "up"
      next.since = nowMs
    }
    return { record: next, transition: "" }
  }

  next.failures = next.failures + 1
  // Already down, or not yet failed often enough: no second alert either way.
  if (next.state === "down" || next.failures < site.failuresBeforeAlert)
    return { record: next, transition: "" }

  next.state = "down"
  next.since = nowMs
  next.outages = openOutage(next.outages, {
    startedAt: nowMs,
    endedAt: 0,
    code: result.code,
    reason: result.reason
  })
  return { record: next, transition: "down" }
}

// The probe can be wrong: plenty of networks answer HTTP while dropping ICMP,
// and a captive portal answers everything. A site that replied is proof the
// machine is online, so a success anywhere in the batch overrules the probe.
function batchWasOffline(network, results) {
  if (!network || !network.known || network.online) return false
  var list = Array.isArray(results) ? results : []
  for (var i = 0; i < list.length; i++) if (list[i].ok) return false
  return true
}

// ------------------------------------------------------------------- theme

function matchColorKey(raw, key) {
  var lines = String(raw === undefined || raw === null ? "" : raw).split("\n")
  var pattern = new RegExp("^\\s*" + key + "\\s*=\\s*[\"']?(#[0-9A-Fa-f]{6})")
  for (var i = 0; i < lines.length; i++) {
    var found = pattern.exec(lines[i])
    if (found) return found[1]
  }
  return ""
}

// "Offline" is a third state, and the palette the shell exposes only has an
// accent and an urgent. Themes carry an orange of their own; the handful that
// do not carry a yellow, which is the same fallback Omarchy's own
// `omarchy-theme-color` applies - so a warning here is the hue every other
// Omarchy surface would have picked.
function parseWarningColor(raw, fallback) {
  var orange = matchColorKey(raw, "orange")
  if (orange !== "") return orange
  var yellow = matchColorKey(raw, "yellow")
  if (yellow !== "") return yellow
  return clean(fallback) !== "" ? fallback : DEFAULT_WARNING
}

// ------------------------------------------------------------------- summary

function summary(sites, records) {
  var list = Array.isArray(sites) ? sites : []
  var counts = { total: 0, up: 0, down: 0, pending: 0, disabled: 0 }
  var downNames = []

  for (var i = 0; i < list.length; i++) {
    var site = list[i]
    if (site.enabled === false) {
      counts.disabled++
      continue
    }
    counts.total++
    var state = recordFor(records, site.id).state
    if (state === "down") {
      counts.down++
      downNames.push(labelFor(site))
    } else if (state === "up") {
      counts.up++
    } else {
      counts.pending++
    }
  }

  var state = "up"
  if (counts.total === 0) state = "empty"
  else if (counts.down > 0) state = "down"
  else if (counts.up === 0) state = "pending"

  return {
    total: counts.total,
    up: counts.up,
    down: counts.down,
    pending: counts.pending,
    disabled: counts.disabled,
    downNames: downNames,
    state: state,
    text: summaryText(counts, downNames, state)
  }
}

function summaryText(counts, downNames, state) {
  // Paused sites are not counted anywhere else, so "All 2 up" beside a list of
  // three needs saying where the third went.
  var paused = counts.disabled > 0 ? ", " + counts.disabled + " paused" : ""

  if (state === "empty") {
    if (counts.disabled === 0) return "No sites watched"
    return counts.disabled === 1 ? "1 site paused" : counts.disabled + " sites paused"
  }
  if (state === "pending") return counts.total === 1 ? "Checking..." : "Checking " + counts.total + " sites..."

  // Every remaining state leads with the count, so "how many are up" is
  // answered before the list underneath is read at all.
  var line = counts.up === counts.total
    ? (counts.total === 1 ? "1 site up" : "All " + counts.total + " up")
    : counts.up + " of " + counts.total + " up"

  if (counts.down === 1) line += " - " + downNames[0] + " is down"
  else if (counts.down > 1) line += " - " + counts.down + " sites down"
  else if (counts.pending > 0) line += ", " + counts.pending + " still checking"
  return line + paused
}

// ---------------------------------------------------------------- formatting

function formatDuration(ms) {
  var seconds = Math.max(0, Math.round((Number(ms) || 0) / 1000))
  if (seconds < 60) return seconds + "s"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return minutes % 60 === 0 ? hours + "h" : hours + "h " + (minutes % 60) + "m"
  var days = Math.floor(hours / 24)
  return hours % 24 === 0 ? days + "d" : days + "d " + (hours % 24) + "h"
}

function formatStamp(epochMs) {
  var value = toInt(epochMs, 0)
  if (value <= 0) return ""
  var at = new Date(value)
  return pad(at.getDate()) + " " + MONTHS[at.getMonth()] + " " + pad(at.getHours()) + ":" + pad(at.getMinutes())
}

// "just now" covers ten seconds, not the three quarters of a minute a rounder
// threshold would: sites are commonly checked every 60s, and a window that
// wide would label almost every reading's whole life "just now" - which is
// precisely the staleness this is here to expose.
function formatAgo(epochMs, nowMs) {
  var value = toInt(epochMs, 0)
  if (value <= 0) return "never"
  var elapsed = Math.max(0, nowMs - value)
  if (elapsed < 10000) return "just now"
  return formatDuration(elapsed) + " ago"
}

function latencyLabel(record) {
  if (!record || record.latencyMs <= 0) return ""
  if (record.latencyMs < 1000) return record.latencyMs + " ms"
  return (record.latencyMs / 1000).toFixed(1) + " s"
}

// What went wrong, in the shape a person reads: a status code when the server
// answered, the transport failure when it did not.
function failureLabel(record) {
  if (!record) return ""
  var code = clean(record.code)
  if (code !== "" && code !== "000") return "HTTP " + code
  var reason = clean(record.reason)
  return reason === "" ? "no answer" : reason
}

// Three labelled parts, so a row says what each number means instead of
// leaving the reader to work out which duration is which:
//   Up 5m | replied in 200 ms | updated 2m ago
function statusLine(site, record, nowMs) {
  if (site && site.enabled === false) return "Paused"
  var current = normalizeRecord(record)
  if (current.state === "unknown") return current.checkedAt > 0 ? "Checking..." : "Not checked yet"

  var parts = []

  if (current.state === "down") {
    parts.push(current.since > 0 ? "Down " + formatDuration(nowMs - current.since) : "Down")
    parts.push(failureLabel(current))
  } else {
    parts.push(current.since > 0 ? "Up " + formatDuration(nowMs - current.since) : "Up")
    // A site failing right now without having crossed its threshold is worth
    // more than how fast the last good answer came back.
    if (current.failures > 0) {
      parts.push(current.failures + " failing check" + (current.failures === 1 ? "" : "s"))
    } else {
      var latency = latencyLabel(current)
      if (latency !== "") parts.push("replied in " + latency)
    }
  }

  // How old the reading is belongs on every line: "Up 2h" from a check that
  // last ran an hour ago is a different claim from the same line a second old.
  if (current.checkedAt > 0) parts.push("updated " + formatAgo(current.checkedAt, nowMs))
  return parts.join(" | ")
}

// The one-line summary of how a site is checked, shown where the settings used
// to sit: the expanded row is history now, and this says what produced it.
function scheduleLine(site) {
  if (!site) return ""
  var parts = ["Every " + formatDuration(site.intervalSeconds * 1000)]
  parts.push(site.expectedStatus > 0 ? "expects " + site.expectedStatus : "expects any 2xx/3xx")
  parts.push("alerts after " + site.failuresBeforeAlert +
    (site.failuresBeforeAlert === 1 ? " failure" : " failures"))
  if (site.enabled === false) parts.push("paused")
  return parts.join(" - ")
}

function outageLabel(outage, nowMs) {
  var current = normalizeOutage(outage)
  if (current.startedAt <= 0) return ""
  var stamp = formatStamp(current.startedAt)
  if (current.endedAt <= 0) return stamp + " - ongoing"
  return stamp + " - " + formatDuration(current.endedAt - current.startedAt)
}

function outageDetail(outage) {
  var current = normalizeOutage(outage)
  var code = clean(current.code)
  if (code !== "" && code !== "000") return "HTTP " + code
  return clean(current.reason)
}

function outageSummary(record) {
  var current = normalizeRecord(record)
  var count = current.outages.length
  if (count === 0) return "No outages recorded"
  return count === 1 ? "1 outage" : count + " outages"
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_INTERVAL: DEFAULT_INTERVAL,
    DEFAULT_TIMEOUT: DEFAULT_TIMEOUT,
    DEFAULT_FAILURES: DEFAULT_FAILURES,
    MIN_INTERVAL: MIN_INTERVAL,
    MAX_INTERVAL: MAX_INTERVAL,
    MIN_TIMEOUT: MIN_TIMEOUT,
    MAX_TIMEOUT: MAX_TIMEOUT,
    MAX_FAILURES: MAX_FAILURES,
    MAX_OUTAGES: MAX_OUTAGES,
    OFFLINE_TEXT: OFFLINE_TEXT,
    PAUSED_TEXT: PAUSED_TEXT,
    DEFAULT_WARNING: DEFAULT_WARNING,
    clean: clean,
    normalizePath: normalizePath,
    parseAddress: parseAddress,
    hostOf: hostOf,
    targetUrl: targetUrl,
    addressLabel: addressLabel,
    labelFor: labelFor,
    isPlausibleHost: isPlausibleHost,
    uniqueId: uniqueId,
    normalizeSite: normalizeSite,
    normalizeSites: normalizeSites,
    parseConfig: parseConfig,
    serializeConfig: serializeConfig,
    buildSite: buildSite,
    validate: validate,
    updateSite: updateSite,
    withoutSite: withoutSite,
    findSite: findSite,
    emptyRecord: emptyRecord,
    normalizeRecord: normalizeRecord,
    parseState: parseState,
    serializeState: serializeState,
    recordFor: recordFor,
    dueSites: dueSites,
    checkArgs: checkArgs,
    parseResults: parseResults,
    parseNetwork: parseNetwork,
    matchColorKey: matchColorKey,
    parseWarningColor: parseWarningColor,
    batchWasOffline: batchWasOffline,
    applyResult: applyResult,
    summary: summary,
    formatDuration: formatDuration,
    formatStamp: formatStamp,
    formatAgo: formatAgo,
    latencyLabel: latencyLabel,
    failureLabel: failureLabel,
    statusLine: statusLine,
    scheduleLine: scheduleLine,
    outageLabel: outageLabel,
    outageDetail: outageDetail,
    outageSummary: outageSummary
  }
}
