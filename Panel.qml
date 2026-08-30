import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.majkelll.omarchy-uptime"
  // The service owns the plugin's IPC target; a bar surface exists per monitor
  // and registering the same target from each of them would collide.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  readonly property var barIdentity: hostWidget || root

  // Everything shown here is read straight off the service. `revision` moves
  // whenever a check lands or a minute passes, which is what re-evaluates the
  // relative times ("Down 5m") the rows are built from.
  readonly property var sites: service ? service.sites : []
  readonly property var records: service ? service.records : ({})
  readonly property int revision: service ? service.revision : 0
  readonly property bool checking: service ? service.checking : false
  readonly property string configError: service ? service.configError : ""
  readonly property bool paused: service ? service.paused : false
  readonly property bool networkOffline: !paused && (service ? service.networkOffline : false)
  // Both states mean the same thing to every number below: it is the last
  // thing that was known, not the current state.
  readonly property bool stale: paused || networkOffline
  readonly property string networkDetail: service ? service.networkDetail : ""
  readonly property color warningColor: service ? service.warningColor : Model.DEFAULT_WARNING
  readonly property string browserCommand: service && service.browserCommand !== ""
    ? service.browserCommand : "omarchy-launch-browser"

  readonly property var summary: service
    ? service.summary
    : ({ state: "empty", total: 0, down: 0, text: "No sites watched" })

  // A row is in exactly one of three states. Expanded shows its outage
  // history, editing shows its form; the two never overlap, so opening one
  // closes the other.
  property string expandedId: ""
  property string editingId: ""

  // Edit drafts live here rather than on the delegate: a delegate is rebuilt
  // whenever the site list is replaced, which would drop half-typed input.
  property string draftName: ""
  property string draftAddress: ""
  property string draftPath: ""
  property int draftInterval: Model.DEFAULT_INTERVAL
  property int draftTimeout: Model.DEFAULT_TIMEOUT
  property int draftExpected: 0
  property int draftFailures: Model.DEFAULT_FAILURES
  property bool draftEnabled: true
  property string draftError: ""

  property string addressText: ""
  property string pathText: ""
  property int intervalValue: Model.DEFAULT_INTERVAL
  property string errorText: ""

  // Single cursor shared by keyboard and mouse, in the order the sections are
  // drawn: the add form first, then one row per watched site.
  property string focusSection: "add"
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color faint: Qt.darker(foreground, 1.7)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property real labelColumn: Style.space(64)

  // Row content starts one dot column in from the row padding; the history and
  // edit blocks use the same offset so they hang under the site name.
  readonly property real dotColumn: Style.space(18)
  readonly property real detailIndent: Style.spacing.rowPaddingX + dotColumn

  // One clock the whole panel shares. `revision` alone is not enough to drive
  // it: sites are checked in one batch, so every moment the panel re-rendered
  // was a moment every site had just been checked, and every row claimed to be
  // "updated just now" however stale the reading really was. `tick` advances on
  // its own while the panel is open, so the ages on screen actually age.
  property int tick: 0
  readonly property double nowMs: {
    root.revision
    root.tick
    return Date.now()
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.opened
    onTriggered: root.tick = root.tick + 1
  }

  function colorForState(state) {
    if (state === "down") return Color.urgent
    if (state === "up") return Color.accent
    return root.faint
  }

  // Opening deliberately does not force a round of checks. It used to, which
  // made "updated just now" true by construction every time anyone looked -
  // exactly the staleness the line exists to report. The schedule keeps the
  // rows fresh; the refresh button and `r` are there for when you want it now.
  function open() {
    root.controller.show()
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.controller.hide()
    root.cursorActive = false
    root.errorText = ""
    root.editingId = ""
    root.draftError = ""
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // ------------------------------------------------------------------ adding

  function addSite() {
    var problem = Model.validate(root.addressText, root.pathText, root.intervalValue, root.sites, "")
    if (problem !== "") {
      root.errorText = problem
      return
    }
    var site = Model.buildSite(root.addressText, root.pathText, root.intervalValue, root.sites)
    if (!service) return
    service.saveSites(root.sites.concat([site]))
    root.addressText = ""
    root.pathText = ""
    root.errorText = ""
    // Land the cursor on the row that was just added, at the end of the list.
    root.takeCursor("sites", Math.max(0, root.sites.length - 1))
    service.checkNow(site.id)
  }

  // ----------------------------------------------------------------- editing

  function startEdit(site) {
    if (!site) return
    root.expandedId = ""
    root.editingId = site.id
    root.draftName = site.name
    // The scheme is shown rather than stripped: editing "example.com" back
    // into an http-only site would silently upgrade it to https.
    root.draftAddress = site.origin
    root.draftPath = site.path
    root.draftInterval = site.intervalSeconds
    root.draftTimeout = site.timeoutSeconds
    root.draftExpected = site.expectedStatus
    root.draftFailures = site.failuresBeforeAlert
    root.draftEnabled = site.enabled !== false
    root.draftError = ""
  }

  function cancelEdit() {
    root.editingId = ""
    root.draftError = ""
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function commitEdit() {
    var id = root.editingId
    if (id === "") return
    var problem = Model.validate(root.draftAddress, root.draftPath, root.draftInterval, root.sites, id)
    if (problem !== "") {
      root.draftError = problem
      return
    }
    root.patchSite(id, {
      name: root.draftName,
      origin: root.draftAddress,
      path: root.draftPath,
      intervalSeconds: root.draftInterval,
      timeoutSeconds: root.draftTimeout,
      expectedStatus: root.draftExpected,
      failuresBeforeAlert: root.draftFailures,
      enabled: root.draftEnabled
    })
    root.cancelEdit()
    if (service) service.checkNow(id)
  }

  function patchSite(id, patch) {
    if (!service) return
    service.saveSites(Model.updateSite(root.sites, id, patch))
  }

  function removeSite(id) {
    if (!service) return
    if (root.expandedId === id) root.expandedId = ""
    if (root.editingId === id) root.cancelEdit()
    service.saveSites(Model.withoutSite(root.sites, id))
  }

  function openSite(site) {
    if (!site) return
    Quickshell.execDetached([root.browserCommand, Model.targetUrl(site)])
  }

  // While a row is being edited it owns the panel; expanding another row would
  // leave a half-typed form open somewhere off screen.
  function toggleExpanded(id) {
    if (root.editingId !== "") return
    root.expandedId = root.expandedId === id ? "" : id
  }

  function refresh(id) {
    if (service) service.checkNow(id === undefined ? "" : id)
  }

  function togglePaused() {
    if (service) service.setPaused(!root.paused)
  }

  // A site can vanish from under an open block - sites.json is a file people
  // edit by hand. Without this the panel would keep an editingId nothing
  // renders, and every row would refuse to expand for the rest of the session.
  onSitesChanged: {
    if (root.editingId !== "" && !Model.findSite(root.sites, root.editingId)) root.cancelEdit()
    if (root.expandedId !== "" && !Model.findSite(root.sites, root.expandedId)) root.expandedId = ""
  }

  // ----------------------------------------------------------------- cursor

  function sectionCount(section) {
    if (section === "add") return 1
    if (section === "sites") return root.sites.length
    return 0
  }

  readonly property var cursorRows: {
    var sections = ["add", "sites"]
    var rows = []
    for (var i = 0; i < sections.length; i++) {
      var count = root.sectionCount(sections[i])
      for (var j = 0; j < count; j++) rows.push({ section: sections[i], index: j })
    }
    return rows
  }

  function hasCursorAt(section, index) {
    return root.cursorActive && root.focusSection === section && root.selectedIndex === index
  }

  function takeCursor(section, index) {
    root.cursorActive = true
    root.focusSection = section
    root.selectedIndex = index
  }

  function moveCursor(delta) {
    var rows = root.cursorRows
    if (rows.length === 0) return

    var at = -1
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].section === root.focusSection && rows[i].index === root.selectedIndex) {
        at = i
        break
      }
    }

    var next = at === -1 ? (delta > 0 ? 0 : rows.length - 1) : (at + delta + rows.length) % rows.length
    root.takeCursor(rows[next].section, rows[next].index)
  }

  function selectedSite() {
    if (!root.cursorActive || root.focusSection !== "sites") return null
    return root.sites[root.selectedIndex] || null
  }

  function activateCursor() {
    if (!root.cursorActive) return
    if (root.focusSection === "add") {
      addressField.forceActiveFocus()
      return
    }
    var site = root.selectedSite()
    if (site) root.toggleExpanded(site.id)
  }

  function removeSelected() {
    var site = root.selectedSite()
    if (site) root.removeSite(site.id)
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // One row of the panel's single cursor model. Visuals come from `hasCursor`
  // only - never from containsMouse - so mouse and keyboard can never light up
  // two rows at once.
  component PanelRow: CursorSurface {
    id: rowSurface

    required property string section
    required property int rowIndex
    property bool activeRow: false

    readonly property bool selected: root.hasCursorAt(section, rowIndex)

    signal activated()

    width: parent ? parent.width : 0
    hasCursor: selected
    current: activeRow
    foreground: root.foreground
    accent: Color.accent

    onSelectedChanged: if (selected) scrollArea.ensureVisible(rowSurface)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.takeCursor(rowSurface.section, rowSurface.rowIndex)
      onClicked: rowSurface.activated()
    }
  }

  // A labelled field in the edit form. Every row shares one label column, so
  // the inputs line up down the form instead of stepping with their labels.
  component FormRow: Item {
    id: formRow

    property string label: ""
    default property alias content: formHolder.children

    width: parent ? parent.width : 0
    implicitHeight: Math.max(labelText.implicitHeight, formHolder.childrenRect.height)

    Text {
      id: labelText
      text: formRow.label
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      width: root.labelColumn
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Item {
      id: formHolder
      anchors.left: labelText.right
      anchors.leftMargin: Style.spacing.controlGap
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: childrenRect.height
    }
  }

  // The one loud thing in the panel. Used for the two states where every
  // number below it is a memory rather than a reading.
  component StateBanner: BorderSurface {
    id: banner

    property color tone: root.foreground
    property string glyph: ""
    property string title: ""
    property string detail: ""

    width: parent ? parent.width : 0
    implicitHeight: bannerRow.implicitHeight + Style.spacing.xxl
    radius: Style.cornerRadius
    color: Style.hoverFillFor(banner.tone, banner.tone)
    borderSpec: Border.controlSpec("selected", banner.tone, banner.tone)

    Row {
      id: bannerRow
      anchors.centerIn: parent
      width: parent.width - Style.spacing.huge * 2
      spacing: Style.spacing.controlGap

      Text {
        text: banner.glyph
        color: banner.tone
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - Style.space(28)
        spacing: Style.spacing.xxs
        anchors.verticalCenter: parent.verticalCenter

        Text {
          width: parent.width
          text: banner.title
          color: banner.tone
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: banner.detail
          color: banner.tone
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The catcher claims plain letters (j/k navigate, x deletes, e edits), so
      // it stands down whenever a text field owns the keyboard — including the
      // edit form, which is only ever open for one row at a time.
      blocked: addressField.activeFocus || pathField.activeFocus || root.editingId !== ""
      onMoveRequested: function(dx, dy) { root.moveCursor(dx !== 0 ? dx : dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.removeSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "/") addressField.forceActiveFocus()
        else if (text === "r" || text === "R") root.refresh()
        else if (text === "o" || text === "O") root.openSite(root.selectedSite())
        else if (text === "e" || text === "E") root.startEdit(root.selectedSite())
        else if (text === "p" || text === "P") root.togglePaused()
      }

      Flickable {
        id: scrollArea
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        function ensureVisible(item) {
          if (!item || contentHeight <= height) return
          var top = item.mapToItem(contentColumn, 0, 0).y
          var margin = Style.spacing.lg
          if (top - margin < contentY) contentY = Math.max(0, top - margin)
          else if (top + item.height + margin > contentY + height)
            contentY = Math.min(contentHeight - height, top + item.height + margin - height)
        }

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: scrollArea.width
          spacing: Style.spacing.panelGap

          PanelHero {
            title: "Uptime"
            // Stopped or offline, the summary is the last thing that was
            // known rather than the current state, and it has to say so.
            meta: root.stale ? "Last known - " + root.summary.text : root.summary.text
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: root.paused ? "󰏤" : "󰐰"
                color: root.paused
                  ? root.faint
                  : (root.networkOffline
                    ? root.warningColor
                    : (root.summary.state === "down" ? Color.urgent : root.foreground))
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.xs

                PanelActionButton {
                  iconText: root.paused ? "󰐊" : "󰏤"
                  tooltipText: root.paused ? "Start checking again" : "Stop checking"
                  foreground: root.foreground
                  hoverColor: Color.accent
                  fontFamily: root.fontFamily
                  enabled: root.sites.length > 0
                  opacity: enabled ? 1 : 0.4
                  onClicked: root.togglePaused()
                }

                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: "Check every site now"
                  foreground: root.foreground
                  hoverColor: Color.accent
                  fontFamily: root.fontFamily
                  enabled: !root.checking && !root.paused && root.sites.length > 0
                  opacity: enabled ? 1 : 0.4
                  onClicked: root.refresh()
                }
              }
            }
          }

          StateBanner {
            visible: root.paused
            tone: root.foreground
            glyph: "󰏤"
            title: "Checks stopped"
            detail: "Nothing is being checked - press play above to start again"
          }

          // Unmissable on purpose: while the machine is offline, every line
          // below it is the last thing that was known, not the current state.
          StateBanner {
            visible: root.networkOffline
            tone: root.warningColor
            glyph: "󰖪"
            title: "No internet connection"
            detail: root.networkDetail === ""
              ? "Checks are paused until it comes back"
              : "Checks are paused - " + root.networkDetail
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------------ add a site

          PanelSectionHeader {
            text: "ADD A SITE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.spacing.lg

            Row {
              width: parent.width
              spacing: Style.spacing.controlGap

              TextField {
                id: addressField
                width: parent.width - pathField.width - Style.spacing.controlGap
                placeholderText: "example.com"
                text: root.addressText
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onTextChanged: root.addressText = text
                onAccepted: root.addSite()
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }

              TextField {
                id: pathField
                width: Style.space(120)
                placeholderText: "/hc"
                text: root.pathText
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onTextChanged: root.pathText = text
                onAccepted: root.addSite()
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }
            }

            // One line, one centre line. The interval label sits beside its
            // input instead of above it, so nothing on this row has a
            // different height to align against - a labelled field next to a
            // bare button can only ever agree on one edge. The row reads as a
            // sentence, and its two ends line up with the two fields above:
            // the label with the address field, the button with the path.
            Item {
              width: parent.width
              implicitHeight: Math.max(addInterval.implicitHeight, addButton.implicitHeight)

              Text {
                id: intervalLabel
                text: "Check every"
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              NumberField {
                id: addInterval
                value: root.intervalValue
                from: Model.MIN_INTERVAL
                to: Model.MAX_INTERVAL
                stepSize: 10
                fieldWidth: Style.space(110)
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: intervalLabel.right
                anchors.leftMargin: Style.spacing.controlGap
                anchors.verticalCenter: parent.verticalCenter
                onModified: function(next) { root.intervalValue = next }
              }

              Text {
                text: "seconds"
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.left: addInterval.right
                anchors.leftMargin: Style.spacing.controlGap
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: addButton
                text: "Add site"
                iconText: "󰐕"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.hasCursorAt("add", 0)
                // The icon makes the button's natural height overshoot the
                // spinbox by a few pixels; pinning it keeps the two boxes the
                // same size rather than almost the same size.
                height: addInterval.height
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onHasCursorChanged: if (hasCursor) scrollArea.ensureVisible(this)
                onHovered: function(isHovered) { if (isHovered) root.takeCursor("add", 0) }
                onClicked: root.addSite()
              }
            }

            Text {
              visible: text !== ""
              width: parent.width
              text: root.errorText
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------- watched sites

          PanelSectionHeader {
            text: "WATCHED SITES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: text !== ""
            text: root.configError
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.sites.length === 0 && root.configError === ""
            text: "Nothing watched yet. Add a site above."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Repeater {
              model: root.sites

              // Each entry is the row itself plus whichever block it has been
              // asked for: the outage history, or the edit form. Neither is
              // built until the row is opened.
              delegate: Column {
                id: siteEntry
                required property var modelData
                required property int index

                readonly property var record: Model.recordFor(root.records, modelData.id)
                readonly property bool editing: root.editingId === modelData.id
                readonly property bool expanded: root.expandedId === modelData.id && !editing
                readonly property string state: modelData.enabled === false ? "paused" : record.state

                width: parent.width
                spacing: Style.spacing.sm

                onEditingChanged: if (editing) Qt.callLater(function() { scrollArea.ensureVisible(siteEntry) })
                onExpandedChanged: if (expanded) Qt.callLater(function() { scrollArea.ensureVisible(siteEntry) })

                PanelRow {
                  id: siteRow
                  section: "sites"
                  rowIndex: siteEntry.index
                  activeRow: siteEntry.expanded || siteEntry.editing
                  implicitHeight: rowContent.implicitHeight + Style.spacing.xl
                  onActivated: root.toggleExpanded(siteEntry.modelData.id)

                  Item {
                    id: rowContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Style.spacing.rowPaddingX
                    anchors.rightMargin: Style.spacing.rowPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    implicitHeight: labels.implicitHeight

                    // Centred on the title, not on the row: against a
                    // three-line stack a vertically centred marker lands
                    // beside the address and reads as belonging to it.
                    Text {
                      id: dot
                      text: siteEntry.editing ? "󰏫" : (siteEntry.expanded ? "󰅀" : "●")
                      color: siteEntry.state === "paused" ? root.faint : root.colorForState(siteEntry.state)
                      font.family: root.fontFamily
                      font.pixelSize: siteEntry.expanded || siteEntry.editing
                        ? Style.font.caption : Style.font.bodySmall
                      anchors.left: parent.left
                      anchors.top: labels.top
                      anchors.topMargin: Math.max(0, Math.round((titleText.implicitHeight - implicitHeight) / 2))
                      width: root.dotColumn
                    }

                    Column {
                      id: labels
                      anchors.left: dot.right
                      anchors.right: actions.left
                      anchors.rightMargin: Style.spacing.lg
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.xxs

                      Text {
                        id: titleText
                        width: parent.width
                        text: Model.labelFor(siteEntry.modelData)
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        // An unnamed site with no path is titled by its host
                        // already; printing the same string twice is noise.
                        visible: text !== titleText.text
                        text: Model.addressLabel(siteEntry.modelData)
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideMiddle
                      }

                      Text {
                        width: parent.width
                        text: Model.statusLine(siteEntry.modelData, siteEntry.record, root.nowMs)
                        color: siteEntry.state === "down" ? Color.urgent : root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    Row {
                      id: actions
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.xs
                      // The form carries its own Save and Cancel; leaving the
                      // row actions live beside them invites a stray click to
                      // throw away a half-typed edit.
                      visible: !siteEntry.editing

                      PanelActionButton {
                        iconText: "󰏫"
                        tooltipText: "Edit " + Model.labelFor(siteEntry.modelData)
                        foreground: root.foreground
                        hoverColor: Color.accent
                        fontFamily: root.fontFamily
                        onClicked: root.startEdit(siteEntry.modelData)
                      }

                      PanelActionButton {
                        iconText: "󰏌"
                        tooltipText: "Open " + Model.targetUrl(siteEntry.modelData)
                        foreground: root.foreground
                        hoverColor: Color.accent
                        fontFamily: root.fontFamily
                        onClicked: root.openSite(siteEntry.modelData)
                      }

                      PanelActionButton {
                        visible: siteRow.selected || siteEntry.expanded
                        iconText: "󰅙"
                        tooltipText: "Stop watching"
                        foreground: root.foreground
                        hoverColor: Color.urgent
                        fontFamily: root.fontFamily
                        onClicked: root.removeSite(siteEntry.modelData.id)
                      }
                    }
                  }
                }

                // -------------------------------------------- outage history
                Column {
                  visible: siteEntry.expanded
                  width: parent.width - root.detailIndent - Style.spacing.rowPaddingX
                  x: root.detailIndent
                  spacing: Style.spacing.sm

                  Text {
                    width: parent.width
                    text: Model.scheduleLine(siteEntry.modelData)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  PanelSectionHeader {
                    text: Model.outageSummary(siteEntry.record).toUpperCase()
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs

                    Repeater {
                      model: siteEntry.record.outages

                      delegate: Item {
                        required property var modelData

                        width: parent.width
                        implicitHeight: Style.spacing.controlHeight - Style.spacing.sm

                        Text {
                          anchors.left: parent.left
                          anchors.verticalCenter: parent.verticalCenter
                          text: Model.outageLabel(modelData, root.nowMs)
                          color: modelData.endedAt <= 0 ? Color.urgent : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }

                        Text {
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          text: Model.outageDetail(modelData)
                          color: root.faint
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }
                }

                // ------------------------------------------------ edit form
                Column {
                  visible: siteEntry.editing
                  width: parent.width - root.detailIndent - Style.spacing.rowPaddingX
                  x: root.detailIndent
                  spacing: Style.spacing.md

                  FormRow {
                    label: "Name"

                    TextField {
                      width: parent.width
                      text: root.draftName
                      placeholderText: Model.hostOf(siteEntry.modelData.origin)
                      foreground: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      verticalPadding: Style.spacing.xs
                      onTextChanged: root.draftName = text
                      onAccepted: root.commitEdit()
                      Keys.onEscapePressed: root.cancelEdit()
                    }
                  }

                  FormRow {
                    label: "Address"

                    TextField {
                      width: parent.width
                      text: root.draftAddress
                      placeholderText: "https://example.com"
                      foreground: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      verticalPadding: Style.spacing.xs
                      onTextChanged: root.draftAddress = text
                      onAccepted: root.commitEdit()
                      Keys.onEscapePressed: root.cancelEdit()
                    }
                  }

                  FormRow {
                    label: "Path"

                    TextField {
                      width: parent.width
                      text: root.draftPath
                      placeholderText: "/hc, or empty for the site itself"
                      foreground: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      verticalPadding: Style.spacing.xs
                      onTextChanged: root.draftPath = text
                      onAccepted: root.commitEdit()
                      Keys.onEscapePressed: root.cancelEdit()
                    }
                  }

                  // Two columns rather than four across: every field a site
                  // has is editable here, and half the popup width leaves the
                  // labels room to say what they mean. The grid ends on the
                  // same vertical as the text fields above it.
                  Grid {
                    id: numberGrid
                    width: parent.width
                    columns: 2
                    columnSpacing: Style.spacing.controlGap
                    rowSpacing: Style.spacing.md

                    readonly property real cellWidth:
                      (width - columnSpacing) / 2

                    NumberField {
                      id: intervalField
                      label: "Check every (s)"
                      value: root.draftInterval
                      from: Model.MIN_INTERVAL
                      to: Model.MAX_INTERVAL
                      stepSize: 10
                      fieldWidth: numberGrid.cellWidth
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function(next) { root.draftInterval = next }
                    }

                    NumberField {
                      label: "Give up after (s)"
                      value: root.draftTimeout
                      from: Model.MIN_TIMEOUT
                      to: Model.MAX_TIMEOUT
                      stepSize: 1
                      fieldWidth: numberGrid.cellWidth
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function(next) { root.draftTimeout = next }
                    }

                    NumberField {
                      label: "Expect (0 = any 2xx/3xx)"
                      value: root.draftExpected
                      from: 0
                      to: 599
                      stepSize: 1
                      fieldWidth: numberGrid.cellWidth
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function(next) { root.draftExpected = next }
                    }

                    NumberField {
                      label: "Alert after failures"
                      value: root.draftFailures
                      from: 1
                      to: Model.MAX_FAILURES
                      stepSize: 1
                      fieldWidth: numberGrid.cellWidth
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function(next) { root.draftFailures = next }
                    }
                  }

                  Item {
                    width: parent.width
                    implicitHeight: Math.max(saveButton.implicitHeight, watchToggle.implicitHeight)

                    Text {
                      id: watchLabel
                      text: root.draftEnabled ? "Watching" : "Paused"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      width: root.labelColumn
                    }

                    ToggleSwitch {
                      id: watchToggle
                      checked: root.draftEnabled
                      foreground: root.foreground
                      anchors.left: watchLabel.right
                      anchors.leftMargin: Style.spacing.controlGap
                      anchors.verticalCenter: parent.verticalCenter
                      onToggled: root.draftEnabled = !root.draftEnabled
                    }

                    // Pinned to an input's height: a button sizes itself off
                    // its icon and would otherwise stand a few pixels taller
                    // than every field above it.
                    Button {
                      text: "Cancel"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      height: intervalField.field.height
                      anchors.right: saveButton.left
                      anchors.rightMargin: Style.spacing.xs
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.cancelEdit()
                    }

                    Button {
                      id: saveButton
                      text: "Save"
                      iconText: "󰄬"
                      bordered: true
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      height: intervalField.field.height
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.commitEdit()
                    }
                  }

                  Text {
                    visible: text !== ""
                    text: root.draftError
                    color: Color.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    width: parent.width
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }
          }

          Text {
            text: "Enter history - e edit - o open - x stop watching - / add - r check now - p pause"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
