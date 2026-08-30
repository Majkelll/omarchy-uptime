import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.majkelll.omarchy-uptime"

  // The service is the single instance of this plugin the shell mounts; every
  // bar surface reads the same sites, records, and schedule off it.
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(root.moduleName) : null
  readonly property var summary: service ? service.summary : ({ state: "empty", down: 0, text: "No sites watched" })

  readonly property bool hideWhenHealthy: setting("hideWhenHealthy", false) === true

  // The service this surface last registered itself with, so a service that
  // arrives or is swapped out cannot leave a stale registration behind.
  property var registeredService: null
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("service" in target) target.service = root.service
  }

  // The service is injected by the host after this widget is constructed, so
  // registration happens on every change to it rather than once at completion.
  function syncRegistration() {
    if (root.registeredService === root.service) return
    if (root.registeredService) root.registeredService.unregisterSurface(root)
    root.registeredService = root.service
    if (root.registeredService) root.registeredService.registerSurface(root)
  }

  onBarChanged: root.injectPanel()
  onSettingsChanged: root.injectPanel()
  onServiceChanged: {
    root.injectPanel()
    root.syncRegistration()
  }

  Component.onCompleted: root.syncRegistration()
  Component.onDestruction: if (root.registeredService) root.registeredService.unregisterSurface(root)

  // A watched site that has never answered is not the same as one that is
  // down, so the icon dims while the first round of checks is still out.
  readonly property bool alerting: summary.state === "down"
  readonly property bool waiting: summary.state === "pending" || summary.state === "empty"

  readonly property string tooltip: {
    if (!service) return "Uptime"
    if (service.configError !== "") return service.configError
    return summary.text
  }

  visible: !hideWhenHealthy || alerting
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      // A second pass after the first layout: `bar` and `settings` are
      // injected into this widget by the host and can land after onLoaded.
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐰"
    fontSize: Style.font.icon
    active: root.alerting
    dimmed: root.waiting && !root.alerting
    tooltipText: root.tooltip
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) {
        if (root.service) root.service.checkNow("")
        return
      }
      root.toggle()
    }
  }
}
