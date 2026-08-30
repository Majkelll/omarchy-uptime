import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// The headless half of the plugin: it owns the watched sites, the schedule,
// the outage history, and the notifications. A bar surface exists per monitor,
// so the checking deliberately lives here — the shell mounts exactly one
// service per plugin, which is what keeps a three-monitor desktop from
// probing every site three times and alerting three times.
Item {
  id: service

  // Injected by the shell host; the notification and browser helpers are
  // resolved against it so the plugin works from a non-standard install path.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/omarchy-uptime"
  readonly property string configPath: configDir + "/sites.json"
  readonly property string stateDir: home + "/.local/state/omarchy-uptime"
  readonly property string statePath: stateDir + "/state.json"

  readonly property string checkScript: String(Qt.resolvedUrl("scripts/omarchy-uptime-check")).replace(/^file:\/\//, "")
  readonly property string notifyCommand: (omarchyPath === "" ? "" : omarchyPath + "/bin/") + "omarchy-notification-send"
  readonly property string browserCommand: (omarchyPath === "" ? "" : omarchyPath + "/bin/") + "omarchy-launch-browser"

  // Configured sites, in file order. Records are keyed by site id; both are
  // replaced wholesale rather than mutated so QML property bindings actually
  // see the change.
  property var sites: []
  property var records: ({})

  // Stopped by hand from the popup. Nothing is checked, nothing is recorded
  // and nobody is alerted until it is started again.
  property bool paused: false

  property bool configLoaded: false
  property bool stateLoaded: false
  property string configError: ""
  property bool checking: false

  // Set when the machine itself could not reach the internet during the last
  // batch. Nothing is recorded and nobody is alerted while this is true.
  property bool networkOffline: false
  property string networkDetail: ""

  // The theme's own orange, for the one state that is neither healthy nor an
  // outage. Re-read whenever the palette changes underneath us.
  property color warningColor: Model.DEFAULT_WARNING
  // Epoch milliseconds do not fit in QML's 32-bit int, so every timestamp the
  // plugin keeps is a double.
  property double lastCheckedAt: 0

  // Bumped on every applied result so panels can re-evaluate the relative
  // times they show ("Down 5m") without polling the clock themselves.
  property int revision: 0

  readonly property var summary: Model.summary(sites, records)

  // Bar surfaces that can show the popup. One exists per monitor, and they
  // register themselves here so the plugin's single IPC target can reach a
  // panel without every surface trying to claim a target of its own.
  property var surfaces: []

  // ------------------------------------------------------------ persistence

  function loadConfig(raw) {
    var parsed = Model.parseConfig(raw)
    service.configError = parsed.error
    // A file that fails to parse keeps the sites already in memory: dropping
    // them would also drop the schedule mid-edit, and the panel shows the
    // error instead.
    if (parsed.error === "" || !service.configLoaded) {
      service.sites = parsed.sites
      service.paused = parsed.paused
    }
    service.configLoaded = true
    Qt.callLater(service.runDueChecks)
  }

  function loadState(raw) {
    service.records = Model.parseState(raw)
    service.stateLoaded = true
  }

  // The single write path for the site list. Everything the panel edits ends
  // up here, and the file is the source of truth the service reloads from.
  function saveSites(next) {
    service.sites = Model.normalizeSites(next)
    service.configError = ""
    service.writeConfig()
    Qt.callLater(service.runDueChecks)
  }

  function setPaused(next) {
    service.paused = next === true
    service.writeConfig()
    // Resuming checks everything at once rather than waiting out the longest
    // interval: nothing moved while it was stopped, so everything is stale.
    if (!service.paused) Qt.callLater(function() { service.checkNow("") })
  }

  function writeConfig() {
    ensureDirsProc.running = true
    configFile.setText(Model.serializeConfig(service.sites, service.paused))
  }

  function saveState() {
    if (!service.stateLoaded) return
    ensureDirsProc.running = true
    stateFile.setText(Model.serializeState(service.records, service.sites))
  }

  // ---------------------------------------------------------------- checking

  function runDueChecks() {
    if (service.paused) return
    service.startChecks(Model.dueSites(service.sites, service.records, Date.now()))
  }

  // Force a check now, for one site or for every enabled one. Bound to the
  // panel's refresh button and to a right-click on the bar icon.
  function checkNow(id) {
    if (service.paused) return
    var due = []
    for (var i = 0; i < service.sites.length; i++) {
      var site = service.sites[i]
      if (site.enabled === false) continue
      if (id === undefined || id === "" || site.id === id) due.push(site)
    }
    service.startChecks(due)
  }

  function startChecks(due) {
    if (checkProc.running || due.length === 0) return
    var args = [service.checkScript]
    for (var i = 0; i < due.length; i++) args.push(Model.checkArgs(due[i]))
    service.checking = true
    checkProc.command = args
    checkProc.running = true
  }

  function applyResults(text) {
    var now = Date.now()
    var network = Model.parseNetwork(text)
    var results = Model.parseResults(text)

    // The machine is offline: every failure in this batch is ours, not theirs.
    // Records are deliberately left untouched, so `checkedAt` stays where it
    // was and every site is due again the moment the connection comes back.
    if (Model.batchWasOffline(network, results)) {
      service.networkOffline = true
      service.networkDetail = network.detail
      return
    }
    service.networkOffline = false
    service.networkDetail = ""
    if (results.length === 0) return

    var next = {}
    for (var key in service.records) next[key] = service.records[key]

    for (var i = 0; i < results.length; i++) {
      var result = results[i]
      var site = Model.findSite(service.sites, result.id)
      // A site removed while its check was in flight has no record to update.
      if (!site) continue
      var outcome = Model.applyResult(next[result.id], site, result, now)
      next[result.id] = outcome.record
      if (outcome.transition !== "") service.notify(site, outcome.record, outcome.transition)
    }

    service.records = next
    service.lastCheckedAt = now
    service.revision = service.revision + 1
    saveTimer.restart()
  }

  // ----------------------------------------------------------- notifications

  function notify(site, record, transition) {
    var down = transition === "down"
    var url = Model.targetUrl(site)
    var headline = Model.labelFor(site) + (down ? " is down" : " is back up")
    var detail = down
      ? Model.addressLabel(site) + " - " + Model.failureLabel(record)
      : "Answered again after " + service.outageLength(record)

    var command = [service.notifyCommand,
      "--app-name", "omarchy-uptime",
      "-g", down ? "󰅙" : "󰄬",
      "-u", down ? "critical" : "low",
      headline, detail]
    // --exec swallows the rest of the argv on purpose, so it comes last.
    command.push("--exec")
    command.push(service.browserCommand)
    command.push(url)
    Quickshell.execDetached(command)
  }

  function outageLength(record) {
    var outages = record && record.outages ? record.outages : []
    if (outages.length === 0 || outages[0].endedAt <= 0) return "a moment"
    return Model.formatDuration(outages[0].endedAt - outages[0].startedAt)
  }

  // ------------------------------------------------------------------- files

  FileView {
    id: configFile
    path: service.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    // `text()` is stale inside the change signal, so both paths route through
    // reload → onLoaded and always parse fresh content.
    onFileChanged: reload()
    onLoaded: service.loadConfig(text())
    // No file yet is the first-run state, not an error: start with no sites
    // and let the panel write one when the user adds it.
    onLoadFailed: service.loadConfig("")
  }

  FileView {
    id: themeColors
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: service.warningColor = Model.parseWarningColor(text(), Model.DEFAULT_WARNING)
    onLoadFailed: service.warningColor = Model.DEFAULT_WARNING
  }

  // Switching themes retargets the symlink the path above resolves through,
  // which a file watch does not necessarily see. The shell's own palette
  // changing is the reliable signal that a new theme has landed.
  Connections {
    target: Color
    function onAccentChanged() { themeColors.reload() }
    function onBackgroundChanged() { themeColors.reload() }
    function onForegroundChanged() { themeColors.reload() }
  }

  FileView {
    id: stateFile
    path: service.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: service.loadState(text())
    onLoadFailed: service.loadState("")
  }

  Process {
    id: ensureDirsProc
    command: ["mkdir", "-p", service.configDir, service.stateDir]
  }

  Process {
    id: checkProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.applyResults(text)
    }
    onExited: function(code) {
      service.checking = false
      if (code !== 0 && code !== 1) console.warn("omarchy-uptime: check script exited with", code)
    }
  }

  // One coarse tick drives everything. Per-site intervals are honoured by
  // dueSites(), so a 5s tick costs nothing when nothing is due and keeps a
  // 10s interval close enough to its promise.
  Timer {
    interval: 5000
    repeat: true
    running: true
    onTriggered: service.runDueChecks()
  }

  // Relative times in the panel ("Down 5m") are derived from `revision`, which
  // otherwise only moves when a check lands. A minute tick keeps them honest
  // while a panel sits open.
  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: service.revision = service.revision + 1
  }

  Timer {
    id: saveTimer
    interval: 300
    repeat: false
    onTriggered: service.saveState()
  }

  // ---------------------------------------------------------- bar surfaces

  function registerSurface(surface) {
    if (!surface || service.surfaces.indexOf(surface) !== -1) return
    service.surfaces = service.surfaces.concat([surface])
  }

  function unregisterSurface(surface) {
    var next = []
    for (var i = 0; i < service.surfaces.length; i++)
      if (service.surfaces[i] !== surface) next.push(service.surfaces[i])
    service.surfaces = next
  }

  // Opening goes to the first surface that registered - the popup belongs on
  // one screen, not on all of them. Closing goes to every surface, since any
  // of them may be the one holding a popup open.
  function callSurfaces(method, all) {
    for (var i = 0; i < service.surfaces.length; i++) {
      var surface = service.surfaces[i]
      if (!surface || typeof surface[method] !== "function") continue
      surface[method]()
      if (!all) return
    }
  }

  IpcHandler {
    target: "omarchy-uptime"

    function check(): void { service.checkNow("") }
    function status(): string {
      if (service.paused) return Model.PAUSED_TEXT
      return service.networkOffline ? Model.OFFLINE_TEXT : service.summary.text
    }
    function pause(): void { service.setPaused(true) }
    function resume(): void { service.setPaused(false) }
    function list(): string { return Model.serializeConfig(service.sites, service.paused) }
    function open(): void { service.callSurfaces("open", false) }
    function close(): void { service.callSurfaces("close", true) }
    function toggle(): void { service.callSurfaces("toggle", false) }
  }

  Component.onCompleted: {
    // Both directories are created up front, before anything is written to
    // them: a change watch can only be established inside a directory that
    // exists, and without one a sites.json written by hand on a fresh install
    // would never be noticed.
    ensureDirsProc.running = true
    // FileView reports a missing file through onLoadFailed, which is the
    // first-run path both loaders already handle.
    Qt.callLater(function() {
      configFile.reload()
      stateFile.reload()
      themeColors.reload()
    })
  }
}
