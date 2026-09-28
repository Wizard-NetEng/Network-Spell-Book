import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Network Spell Book: a reference grimoire for network engineering tools.
// One icon, one popup: your tools grouped by purpose, what each one does, and
// a starter command you can copy.
//
// Read-only by design. The popup can copy a command to your clipboard; it
// cannot run one. There is no execution path for a catalogued tool anywhere in
// this plugin.
Panel {
  id: root
  moduleName: "spellbook"
  ipcTarget: "spellbook"

  // ---- theme tokens (all from the active Omarchy theme) ------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color muted: Qt.darker(foreground, 1.45)
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  // Installed/missing is a semantic distinction, so it cannot ride on theme
  // tokens: many Omarchy themes set `accent` to a red/coral, which would make
  // "have it" and "don't" render identically. Derive both, tinted toward the
  // theme foreground so they still sit inside the palette.
  readonly property color okColor: Qt.tint(foreground, Qt.rgba(0.36, 0.72, 0.36, 0.82))
  readonly property color warnColor: Qt.tint(foreground, Qt.rgba(0.85, 0.62, 0.20, 0.82))
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- local UI state ----------------------------------------------------
  property string filterText: ""
  property int selectedIndex: -1
  property var rows: []              // flattened: {type:"section"|"tool", ...}
  property bool showSettings: false

  Service {
    id: svc
    settings: root.settings
  }

  // ---- row flattening ----------------------------------------------------
  function rebuild(resetToTop) {
    var term = filterText.toLowerCase().trim()
    var searching = term.length > 0
    var out = []

    for (var c = 0; c < svc.categories.length; c++) {
      var cat = svc.categories[c]
      var matched = []

      for (var t = 0; t < cat.tools.length; t++) {
        var tool = cat.tools[t]
        if (!svc.showMissing && !tool.installed) continue
        if (searching) {
          var hay = (tool.bin + " " + tool.pkg + " " + tool.what + " " +
                     tool.cmd + " " + tool.note + " " + cat.name).toLowerCase()
          if (hay.indexOf(term) === -1) continue
        }
        matched.push(tool)
      }

      if (matched.length === 0) continue

      var have = 0
      for (var h = 0; h < matched.length; h++) if (matched[h].installed) have++

      // While filtering, force every section open. Hiding a search match
      // behind a collapsed header is the one thing a filter must never do.
      var isCollapsed = !searching && svc.isCollapsed(cat.name)

      // Build the bulk install command from the MATCHED tools, not from the
      // scan's whole-category version. When a filter is active the header
      // shows a subset, and a button that copies packages the user cannot
      // currently see is dishonest. Package names were whitelisted by the
      // scan helper, so joining them here is safe.
      var bulkRepo = [], bulkAur = []
      for (var b = 0; b < matched.length; b++) {
        var bt = matched[b]
        if (bt.installed || !bt.install || !bt.pkg) continue
        if (bt.repo === "aur") {
          if (bulkAur.indexOf(bt.pkg) === -1) bulkAur.push(bt.pkg)
        } else {
          if (bulkRepo.indexOf(bt.pkg) === -1) bulkRepo.push(bt.pkg)
        }
      }
      var bulkLines = []
      if (bulkRepo.length > 0)
        bulkLines.push("sudo pacman -S --needed " + bulkRepo.sort().join(" "))
      if (bulkAur.length > 0)
        bulkLines.push("yay -S " + bulkAur.sort().join(" "))

      out.push({ type: "section", name: cat.name, blurb: cat.blurb,
                 count: matched.length, have: have, collapsed: isCollapsed,
                 installAll: bulkLines.join("\n"),
                 missingCount: bulkRepo.length + bulkAur.length })

      if (isCollapsed) continue
      for (var m = 0; m < matched.length; m++) {
        out.push({ type: "tool", tool: matched[m], section: cat.name })
      }
    }

    rows = out
    if (resetToTop || selectedIndex < 0 || selectedIndex >= rows.length) {
      selectedIndex = firstToolIndex()
    }
    scrollToSelected()
  }

  // Default the selection to the first TOOL, not the first section header.
  // Enter is "copy this command" — the overwhelmingly common intent — and a
  // header landing under the cursor turns the first Enter after a filter into
  // an accidental fold instead.
  function firstToolIndex() {
    for (var i = 0; i < rows.length; i++) if (rows[i].type === "tool") return i
    return rows.length > 0 ? 0 : -1
  }

  function step(dir) {
    if (rows.length === 0) return
    var i = selectedIndex
    if (i < 0) i = dir > 0 ? -1 : rows.length
    i += dir
    if (i < 0) i = rows.length - 1
    if (i >= rows.length) i = 0
    selectedIndex = i
    scrollToSelected()
  }

  function selectedRow() {
    if (selectedIndex < 0 || selectedIndex >= rows.length) return null
    return rows[selectedIndex]
  }

  // Enter copies on a tool, folds/unfolds on a section header.
  function activateSelected() {
    var r = selectedRow()
    if (!r) return
    if (r.type === "section") {
      // While a filter is active every section is force-opened, so toggling
      // one here would mutate fold state invisibly and surprise you after the
      // filter clears. Copy is the only sensible action mid-search.
      if (filterText.trim().length > 0) return
      svc.toggleSection(r.name)
      rebuild(false)
    } else if (r.type === "tool") {
      svc.copyCommand(r.tool.cmd, r.tool.bin)
    }
  }

  // "Add Spell to Book": copy the install incantation for the selected tool.
  // Only meaningful when the tool is actually missing — copying an install
  // command for something already present is a silent no-op that looks like
  // a success, so say so instead.
  function addSpellSelected() {
    var r = selectedRow()
    if (!r) return
    if (r.type === "section") {
      if (r.installAll && r.installAll !== "") {
        svc.copyCommand(r.installAll, r.missingCount + " missing in " + r.name)
      } else {
        svc.flashStatus("Nothing missing in " + r.name)
      }
      return
    }
    if (r.type !== "tool") return
    if (r.tool.installed) {
      svc.flashStatus(r.tool.bin + " is already installed")
      return
    }
    if (r.tool.install === "") {
      svc.flashStatus("No install command for " + r.tool.bin)
      return
    }
    svc.copyCommand(r.tool.install, "install " + r.tool.bin)
  }

  function collapseCurrent() {
    if (filterText.trim().length > 0) return
    var r = selectedRow()
    if (!r) return
    var name = r.type === "section" ? r.name : r.section
    if (!svc.isCollapsed(name)) { svc.toggleSection(name); rebuild(false) }
  }

  function expandCurrent() {
    if (filterText.trim().length > 0) return
    var r = selectedRow()
    if (!r || r.type !== "section") return
    if (svc.isCollapsed(r.name)) { svc.toggleSection(r.name); rebuild(false) }
  }

  function allCollapsed() {
    if (svc.categories.length === 0) return false
    for (var i = 0; i < svc.categories.length; i++)
      if (!svc.isCollapsed(svc.categories[i].name)) return false
    return true
  }

  function scrollToSelected() {
    if (selectedIndex < 0) return
    scrollTimer.restart()
  }

  Timer {
    id: scrollTimer
    interval: 16
    onTriggered: {
      if (root.selectedIndex < 0 || root.selectedIndex >= rowRepeater.count) return
      var item = rowRepeater.itemAt(root.selectedIndex)
      if (!item) return
      var top = item.y
      var bottom = item.y + item.height
      if (top < listFlick.contentY) listFlick.contentY = top
      else if (bottom > listFlick.contentY + listFlick.height)
        listFlick.contentY = bottom - listFlick.height
    }
  }

  Connections {
    target: svc
    function onCategoriesChanged() { root.rebuild(true) }
    function onCollapsedChanged()  { root.rebuild(false) }
    function onShowMissingChanged() { root.rebuild(true) }
  }

  onOpenedChanged: {
    if (opened) {
      svc.notifyOpened()
      filterText = ""
      showSettings = false
      rebuild(true)
      keyCatcher.forceActiveFocus()
    }
  }

  // ---- bar icon ----------------------------------------------------------
  implicitWidth: button.item ? button.item.implicitWidth : 0
  implicitHeight: button.item ? button.item.implicitHeight : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  Loader {
    id: button
    anchors.fill: parent
    sourceComponent: BarIconButton {
      id: barBtn
      bar: root.bar
      // Drawn rather than a font glyph: no Nerd Font glyph reads as
      // "reference grimoire", and a colour emoji cannot follow the theme.
      iconComponent: Component {
        BookIcon {
          anchors.fill: parent
          strokeColor: barBtn.active && barBtn.useActiveColor
                       ? barBtn.activeColor : barBtn.foreground
          backgroundColor: Color.background
        }
      }
      tooltipText: svc.loaded
        ? "Network Spell Book — " + svc.installed + " of " + svc.total + " tools installed"
        : "Network Spell Book"
      active: svc.scanning
      onPressed: function(code) {
        if (code === Qt.RightButton) svc.scan()
        else root.toggle()
      }
    }
  }

  // ---- popup -------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus

      onCloseRequested: root.close()
      Keys.onUpPressed: root.step(-1)
      Keys.onDownPressed: root.step(1)
      Keys.onLeftPressed: root.collapseCurrent()
      Keys.onRightPressed: root.expandCurrent()
      Keys.onReturnPressed: root.activateSelected()
      Keys.onEnterPressed: root.activateSelected()
      Keys.onEscapePressed: root.close()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Slash) {
          searchField.forceActiveFocus(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Space) {
          var r = root.selectedRow()
          if (r && r.type === "section") {
            svc.toggleSection(r.name); root.rebuild(false)
            event.accepted = true; return
          }
        }
        var k = event.text
        if (k === "a") { root.addSpellSelected(); event.accepted = true }
        else if (k === "c") { svc.setAllCollapsed(true); root.rebuild(false); event.accepted = true }
        else if (k === "e") { svc.setAllCollapsed(false); root.rebuild(false); event.accepted = true }
        else if (k === "r") { svc.scan(); event.accepted = true }
        else if (k === ",") { root.showSettings = !root.showSettings; event.accepted = true }
      }

      ColumnLayout {
        id: column
        anchors.fill: parent
        spacing: Style.space(10)

        PanelHero {
          Layout.fillWidth: true
          title: "Network Spell Book"
          meta: {
            if (!svc.loaded) return "Reading the grimoire…"
            if (svc.lastError !== "") return "Scan error"
            var shown = 0
            for (var i = 0; i < root.rows.length; i++)
              if (root.rows[i].type === "tool") shown++
            var s = svc.installed + " of " + svc.total + " installed"
            // Only report a "showing" count when the list is genuinely
            // narrowed by a filter. Collapsed sections hide rows without
            // excluding anything, so "showing 0" there is a lie.
            if (root.filterText.trim().length > 0) s += " · showing " + shown
            else if (!svc.showMissing) s += " · installed only"
            if (svc.scanning) s += " · scanning…"
            return s
          }
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            BookIcon {
              implicitWidth: Style.font.display
              implicitHeight: Style.font.display
              strokeColor: root.foreground
              backgroundColor: Color.background
            }
          }
          trailingControl: Component {
            RowLayout {
              spacing: Style.space(6)
              PanelActionButton {
                iconText: root.allCollapsed() ? "\uf0fe" : "\uf146"
                tooltipText: root.allCollapsed() ? "Expand all sections" : "Collapse all sections"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  svc.setAllCollapsed(!root.allCollapsed())
                  root.rebuild(false)
                }
              }
              PanelActionButton {
                iconText: "\uf013"
                tooltipText: root.showSettings ? "Hide settings" : "Settings"
                foreground: root.showSettings ? root.okColor : root.foreground
                fontFamily: root.fontFamily
                onClicked: root.showSettings = !root.showSettings
              }
              PanelActionButton {
                iconText: "\uf021"
                tooltipText: "Re-scan installed tools"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !svc.scanning
                onClicked: svc.scan()
              }
            }
          }
        }

        // Scan errors are shown, never swallowed.
        Text {
          textFormat: Text.PlainText
          visible: svc.lastError !== ""
          Layout.fillWidth: true
          text: svc.lastError
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Transient confirmation after a copy.
        Text {
          textFormat: Text.PlainText
          visible: svc.copyStatus !== ""
          Layout.fillWidth: true
          text: svc.copyStatus
          color: svc.copyStatus.indexOf("failed") >= 0 ? Color.urgent : root.okColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        // --- settings -------------------------------------------------
        Rectangle {
          Layout.fillWidth: true
          visible: root.showSettings
          implicitHeight: settingsColumn.implicitHeight + Style.space(16)
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
          radius: Style.space(6)

          ColumnLayout {
            id: settingsColumn
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: "This plugin is read-only. It reports which tools are present and "
                  + "copies reference commands to your clipboard. It never runs a network "
                  + "tool, never installs anything, and makes no network connections. "
                  + "“Add Spell to Book” copies an install command for you to review and "
                  + "run yourself — it does not elevate or install on its own."
              color: root.foreground
              opacity: 0.65
              Layout.fillWidth: true
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              text: "Keys:  / filter · ↑↓ move · Enter copy · a (or Ctrl+A while "
                  + "filtering) add spell · ←→ fold · Space fold section "
                  + "· c collapse all · e expand all · r re-scan · Esc close"
              color: root.foreground
              opacity: 0.55
              Layout.fillWidth: true
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              text: "Show missing tools, re-scan interval and initial fold state are in "
                  + "the bar widget settings."
              color: root.foreground
              opacity: 0.55
              Layout.fillWidth: true
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }
        }

        TextField {
          id: searchField
          Layout.fillWidth: true
          placeholderText: "Filter by tool, purpose, command…"
          text: root.filterText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          leftPadding: Style.space(8)
          rightPadding: Style.space(8)
          onTextChanged: {
            root.filterText = text
            root.rebuild(true)
          }
          Keys.onUpPressed: root.step(-1)
          Keys.onDownPressed: root.step(1)
          Keys.onReturnPressed: root.activateSelected()
          Keys.onEnterPressed: root.activateSelected()
          // Ctrl+A copies the install command without leaving the filter.
          // A bare "a" cannot be a shortcut here — it is a letter the user is
          // typing — so the add-spell action needs a modifier while the search
          // field has focus.
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)) {
              root.addSpellSelected()
              event.accepted = true
            }
          }
          Keys.onEscapePressed: {
            if (text.length > 0) text = ""
            else keyCatcher.forceActiveFocus()
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: svc.loaded && root.rows.length === 0
          Layout.fillWidth: true
          text: root.filterText.length > 0
            ? "No tool matches “" + root.filterText + "”."
            : "No tools to show. Enable “Show tools that are not installed” in settings."
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Flickable {
          id: listFlick
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredHeight: Math.min(listColumn.implicitHeight, Style.space(440))
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: listColumn
            width: listFlick.width
            spacing: Style.space(2)

            Repeater {
              id: rowRepeater
              model: root.rows

              delegate: Item {
                id: row
                required property var modelData
                required property int index
                width: parent.width
                implicitHeight: modelData.type === "section"
                  ? sectionLoader.implicitHeight
                  : toolLoader.implicitHeight

                property bool isSelected: root.selectedIndex === index

                Rectangle {
                  anchors.fill: parent
                  color: root.selectedBackground
                  visible: row.isSelected
                  radius: Style.space(4)
                  z: -1
                }

                // --- section header ---
                Loader {
                  id: sectionLoader
                  width: parent.width
                  active: row.modelData.type === "section"
                  visible: active

                  sourceComponent: Item {
                    implicitHeight: sectionRow.implicitHeight + Style.space(10)

                    RowLayout {
                      id: sectionRow
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(6)
                      anchors.rightMargin: Style.space(8)
                      spacing: Style.space(6)

                      Text {
                        textFormat: Text.PlainText
                        text: row.modelData.collapsed ? "\uf105" : "\uf107"  // chevron r/d
                        color: row.isSelected ? root.selectedText : root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: row.modelData.name
                        color: row.isSelected ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                      }

                      Item { Layout.fillWidth: true }

                      // Bulk "Add Spell to Book" for everything missing in
                      // this section. Copies the install line(s); never runs
                      // them.
                      PanelActionButton {
                        iconText: "\uf0c5"
                        tooltipText: "Add Spell to Book — copy install for "
                                     + row.modelData.missingCount + " missing in "
                                     + row.modelData.name
                        foreground: root.warnColor
                        fontFamily: root.fontFamily
                        visible: row.modelData.missingCount > 0
                                 && row.modelData.installAll !== ""
                        onClicked: {
                          root.selectedIndex = row.index
                          svc.copyCommand(row.modelData.installAll,
                                          row.modelData.missingCount
                                            + " missing in " + row.modelData.name)
                        }
                      }

                      // A fold that hides information is a regression; a fold
                      // that summarises it is an upgrade. Both the text and
                      // its colour derive from the SAME denominator.
                      Text {
                        textFormat: Text.PlainText
                        text: row.modelData.have + "/" + row.modelData.count
                        color: row.modelData.have === row.modelData.count
                                 ? root.okColor
                                 : (row.modelData.have === 0 ? root.muted : root.warnColor)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.selectedIndex = row.index
                        svc.toggleSection(row.modelData.name)
                        root.rebuild(false)
                      }
                    }
                  }
                }

                // --- tool row ---
                Loader {
                  id: toolLoader
                  width: parent.width
                  active: row.modelData.type === "tool"
                  visible: active

                  sourceComponent: Item {
                    implicitHeight: toolColumn.implicitHeight + Style.space(10)

                    ColumnLayout {
                      id: toolColumn
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(18)
                      anchors.rightMargin: Style.space(8)
                      spacing: Style.space(3)

                      RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(6)

                        // Installed state is encoded in SHAPE as well as
                        // colour: filled disc = present, hollow ring =
                        // absent. Colour alone fails for colour-blind users
                        // and on themes with unusual palettes.
                        Canvas {
                          implicitWidth: Style.font.bodySmall
                          implicitHeight: Style.font.bodySmall
                          property bool on: row.modelData.tool.installed
                          property color dotColor: on ? root.okColor : root.muted
                          onDotColorChanged: requestPaint()
                          onOnChanged: requestPaint()
                          onPaint: {
                            var ctx = getContext("2d")
                            ctx.reset()
                            ctx.clearRect(0, 0, width, height)
                            var cx = width / 2, cy = height / 2
                            var rr = Math.min(width, height) * 0.28
                            ctx.beginPath()
                            ctx.arc(cx, cy, rr, 0, Math.PI * 2)
                            if (on) {
                              ctx.fillStyle = dotColor
                              ctx.fill()
                            } else {
                              ctx.lineWidth = Math.max(1, rr * 0.5)
                              ctx.strokeStyle = dotColor
                              ctx.stroke()
                            }
                          }
                        }

                        Text {
                          textFormat: Text.PlainText
                          text: row.modelData.tool.bin
                          color: row.isSelected ? root.selectedText : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.bold: true
                        }

                        Text {
                          textFormat: Text.PlainText
                          visible: !row.modelData.tool.installed
                          text: "not installed"
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          opacity: 0.85
                        }

                        Item { Layout.fillWidth: true }

                        Text {
                          textFormat: Text.PlainText
                          visible: row.modelData.tool.pkg !== ""
                          text: row.modelData.tool.pkg
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          opacity: 0.7
                        }
                      }

                      Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: row.modelData.tool.what
                        color: row.isSelected ? root.selectedText : root.foreground
                        opacity: 0.78
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                      }

                      // Starter command + copy. This is reference text, shown
                      // for you to read and copy — it is never executed here.
                      RowLayout {
                        Layout.fillWidth: true
                        visible: row.modelData.tool.cmd !== ""
                        spacing: Style.space(6)

                        Rectangle {
                          Layout.fillWidth: true
                          implicitHeight: cmdText.implicitHeight + Style.space(6)
                          color: Qt.rgba(root.foreground.r, root.foreground.g,
                                         root.foreground.b, 0.07)
                          radius: Style.space(4)

                          Text {
                            id: cmdText
                            textFormat: Text.PlainText
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Style.space(6)
                            anchors.rightMargin: Style.space(6)
                            text: row.modelData.tool.cmd
                            color: row.isSelected ? root.selectedText : root.foreground
                            opacity: 0.92
                            font.family: "monospace"
                            font.pixelSize: Style.font.bodySmall
                            elide: Text.ElideRight
                          }
                        }

                        PanelActionButton {
                          iconText: "\uf0c5"   // copy
                          tooltipText: "Copy command to clipboard"
                          foreground: root.foreground
                          fontFamily: root.fontFamily
                          onClicked: {
                            root.selectedIndex = row.index
                            svc.copyCommand(row.modelData.tool.cmd, row.modelData.tool.bin)
                          }
                        }
                      }

                      // "Add Spell to Book" — the install incantation for a
                      // tool you don't have yet. Shown only when the tool is
                      // missing AND the package name passed the whitelist.
                      //
                      // This copies the command. It does NOT run it: installing
                      // software needs a human who has read what they are about
                      // to elevate, and a bar widget is the wrong place to hide
                      // that decision behind one click.
                      RowLayout {
                        Layout.fillWidth: true
                        visible: !row.modelData.tool.installed
                                 && row.modelData.tool.install !== ""
                        spacing: Style.space(6)

                        Rectangle {
                          Layout.fillWidth: true
                          implicitHeight: installText.implicitHeight + Style.space(6)
                          color: Qt.rgba(root.warnColor.r, root.warnColor.g,
                                         root.warnColor.b, 0.12)
                          radius: Style.space(4)
                          border.width: 1
                          border.color: Qt.rgba(root.warnColor.r, root.warnColor.g,
                                                root.warnColor.b, 0.35)

                          RowLayout {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Style.space(6)
                            anchors.rightMargin: Style.space(6)
                            spacing: Style.space(6)

                            Text {
                              textFormat: Text.PlainText
                              text: "\uf02d"   // book
                              color: root.warnColor
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.bodySmall
                            }

                            Text {
                              id: installText
                              textFormat: Text.PlainText
                              Layout.fillWidth: true
                              text: row.modelData.tool.install
                              color: row.isSelected ? root.selectedText : root.foreground
                              opacity: 0.92
                              font.family: "monospace"
                              font.pixelSize: Style.font.bodySmall
                              elide: Text.ElideRight
                            }

                            Text {
                              textFormat: Text.PlainText
                              visible: row.modelData.tool.repo === "aur"
                              text: "AUR"
                              color: root.warnColor
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.bodySmall
                              opacity: 0.9
                            }
                          }
                        }

                        PanelActionButton {
                          iconText: "\uf0c5"   // copy
                          tooltipText: "Add Spell to Book — copy the install command"
                          foreground: root.warnColor
                          fontFamily: root.fontFamily
                          onClicked: {
                            root.selectedIndex = row.index
                            svc.copyCommand(row.modelData.tool.install,
                                            "install " + row.modelData.tool.bin)
                          }
                        }
                      }

                      Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        visible: row.modelData.tool.note !== ""
                        text: row.modelData.tool.note
                        color: row.isSelected ? root.selectedText : root.muted
                        opacity: 0.8
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      acceptedButtons: Qt.LeftButton
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.selectedIndex = row.index
                      z: -1
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
