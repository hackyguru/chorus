// Chorus — serverless voice rooms on Logos. A room name is a content topic:
// everyone who joins the same name is on the same call, with no host, no
// registry and no signalling server in between.
//
// Visuals follow the Basecamp design system (Logos.Theme + Logos.Controls),
// with the same building blocks as Persona (cards with a coral tick title,
// gradient CTA, status pills), so the two read as one product family.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore

import Logos.Theme
import Logos.Controls

Rectangle {
    id: root
    width: 960
    height: 720
    color: Theme.palette.background

    // The whole call, refreshed from the core. Polled fast because the level
    // meters are the thing that tells you the call is alive.
    property var st: ({})
    readonly property bool inRoom: st.inRoom === true
    readonly property int netStatus: st.status || 0
    readonly property bool wide: width >= 860

    property bool joining: false
    property string pendingRoom: ""
    property double callStartMs: 0
    property int callSeconds: 0
    property string copied: ""
    property string lastError: ""

    // Connection quality, from the fraction of mixer frames that went missing
    // over the last couple of seconds (see qualityTimer).
    property int quality: -1                // -1 n/a · 0 poor · 1 fair · 2 good
    property double gapRate: 0
    property var _prevStats: null

    // Remembered across sessions: your display name and recent rooms.
    Settings {
        id: prefs
        category: "chorus"
        property string displayName: ""
        property string recentJson: "[]"
        property bool pushToTalk: false
    }
    readonly property bool ptt: prefs.pushToTalk
    property bool pttHeld: false
    readonly property var recentRooms: {
        try {
            var v = JSON.parse(prefs.recentJson);
            return Array.isArray(v) ? v : [];
        } catch (e) {
            return [];
        }
    }
    function rememberRoom(r) {
        var list = recentRooms.filter(function (x) {
            return x !== r;
        });
        list.unshift(r);
        prefs.recentJson = JSON.stringify(list.slice(0, 6));
    }
    function forgetRooms() {
        prefs.recentJson = "[]";
    }

    // ── Logos bridge ─────────────────────────────────────────────────
    //
    //   logos.callModule(id, method, [])            — synchronous, no-arg only
    //   logos.callModuleAsync(id, method, args, cb) — anything with arguments
    function callVoice(method) {
        if (typeof logos === "undefined" || !logos.callModule)
            return null;
        return logos.callModule("chorus_core", method, []);
    }
    function callVoiceArgs(method, args, cb) {
        if (typeof logos === "undefined" || !logos.callModuleAsync) {
            lastError = "The Logos bridge is unavailable.";
            if (cb)
                cb(null);
            return;
        }
        logos.callModuleAsync("chorus_core", method, args, function (raw) {
            refresh();
            if (cb)
                cb(unwrap(raw, null));
        });
    }
    // The bridge JSON-encodes whatever the module returned, so a method whose
    // own return value is already a JSON document arrives double-encoded.
    // Keep parsing while the result is still a string; stop when a parse fails.
    function unwrap(raw, def) {
        if (raw === null || raw === undefined)
            return def;
        var v = raw;
        for (var i = 0; i < 3 && typeof v === "string"; ++i) {
            try {
                v = JSON.parse(v);
            } catch (e) {
                return (i === 0) ? def : v;
            }
        }
        return v;
    }
    function refresh() {
        var s = unwrap(callVoice("roomState"), null);
        if (s && typeof s === "object")
            st = s;
    }

    // ── Actions ──────────────────────────────────────────────────────
    function normalizeRoom(t) {
        return (t || "").trim().replace(/^#+/, "").replace(/\s+/g, "-").toLowerCase();
    }
    function join(roomText) {
        var r = normalizeRoom(roomText);
        if (!r.length || joining)
            return;
        var name = nameField.text.trim();
        prefs.displayName = name;
        lastError = "";
        joining = true;
        pendingRoom = r;
        if (ptt)
            setMic(false);
        callVoiceArgs("joinRoom", [r, name], function (res) {
            joining = false;
            if (res && typeof res === "object" && res.success === false)
                lastError = res.error || "Could not join the room.";
            else
                rememberRoom(r);
        });
    }
    function leave() {
        callVoiceArgs("leaveRoom", []);
    }
    function toggleMute() {
        callVoiceArgs("setMuted", [!(st.muted === true)]);
    }
    function setMic(on) {
        callVoiceArgs("setMuted", [!on]);
    }
    // Push to talk is a UI mode over setMuted: muted at rest, live while held.
    function setPtt(v) {
        prefs.pushToTalk = v;
        pttHeld = false;
        if (inRoom)
            setMic(!v);
    }
    function pttDown() {
        if (!ptt || pttHeld)
            return;
        pttHeld = true;
        setMic(true);
    }
    function pttUp() {
        if (!pttHeld)
            return;
        pttHeld = false;
        setMic(false);
    }

    readonly property var _adj: ["amber", "brisk", "cedar", "coral", "dusky", "ember", "fable", "gentle", "hollow", "ivory", "jolly", "lunar", "misty", "noble", "opal", "quiet", "rustic", "silver", "tidal", "velvet", "wild", "zesty"]
    readonly property var _noun: ["otter", "falcon", "harbor", "meadow", "comet", "lantern", "willow", "canyon", "pebble", "heron", "summit", "orchid", "badger", "glacier", "maple", "raven", "delta", "fjord", "thistle", "marten"]
    function randomRoom() {
        function pick(a) {
            return a[Math.floor(Math.random() * a.length)];
        }
        return pick(_adj) + "-" + pick(_noun) + "-" + (1000 + Math.floor(Math.random() * 9000));
    }

    // ── Helpers ──────────────────────────────────────────────────────
    function statusLabel(s) {
        return s === 2 ? "Online" : s === 1 ? "Connecting" : s === 3 ? "Network error" : "Offline";
    }
    function statusColor(s) {
        return s === 2 ? Theme.palette.success : s === 1 ? Theme.palette.warning : s === 3 ? Theme.palette.error : Theme.palette.textTertiary;
    }
    function statusTip(s) {
        if (s === 2)
            return "Connected to Logos, peer to peer";
        if (s === 1)
            return "Finding peers…";
        if (s === 3)
            return st.netError || "Node failed to start";
        return "Join a room to go online";
    }
    function initials(name) {
        var n = (name || "").trim();
        if (!n.length)
            return "?";
        var parts = n.split(/\s+/);
        return (parts.length > 1 ? parts[0].charAt(0) + parts[1].charAt(0) : n.substring(0, 2)).toUpperCase();
    }
    function hueFor(seed) {
        var h = 0;
        var s = seed || "";
        for (var i = 0; i < s.length; i++)
            h = (h * 31 + s.charCodeAt(i)) >>> 0;
        return (h % 360) / 360;
    }
    function everyone() {
        var out = [{
                id: st.myId || "me",
                name: (st.myName && st.myName.length) ? st.myName : "You",
                level: (st.muted ? 0 : (st.myLevel || 0)),
                me: true
            }];
        var ps = st.peers ? st.peers : [];
        for (var i = 0; i < ps.length; ++i)
            out.push({
                id: ps[i].id,
                name: (ps[i].name && ps[i].name.length) ? ps[i].name : "Guest " + String(ps[i].id).substring(0, 4),
                level: ps[i].level || 0,
                me: false
            });
        return out;
    }
    function clock(sec) {
        var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
        var mm = (m < 10 ? "0" : "") + m, ss = (s < 10 ? "0" : "") + s;
        return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss;
    }
    function qualityLabel(q) {
        return q === 2 ? "Good" : q === 1 ? "Unstable" : q === 0 ? "Poor connection" : ((st.peers || []).length ? "Checking…" : "Just you");
    }
    function qualityColor(q) {
        return q === 2 ? Theme.palette.success : q === 1 ? Theme.palette.warning : q === 0 ? Theme.palette.error : Theme.palette.textTertiary;
    }

    TextEdit {
        id: clip
        visible: false
    }
    function copy(t, key) {
        clip.text = t;
        clip.selectAll();
        clip.copy();
        copied = key;
        copyTimer.restart();
    }
    Timer {
        id: copyTimer
        interval: 1600
        onTriggered: root.copied = ""
    }

    onInRoomChanged: {
        if (inRoom) {
            callStartMs = Date.now();
            callSeconds = 0;
            quality = -1;
            _prevStats = null;
            pttHeld = false;
            // Deferred: setMic refreshes st, which inRoom is bound to.
            if (ptt)
                Qt.callLater(setMic, false);
            callView.forceActiveFocus();
        } else {
            callStartMs = 0;
        }
    }

    // 10 Hz: fast enough that the meters look continuous, cheap enough that
    // the poll is not the reason the call stutters.
    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: root.refresh()
    }
    Timer {
        id: qualityTimer
        interval: 2000
        running: root.inRoom
        repeat: true
        onTriggered: {
            var s = root.st.stats || {};
            var cur = {
                recv: s.recv || 0,
                gaps: s.underruns || 0
            };
            var peers = (root.st.peers || []).length;
            if (root._prevStats && peers > 0) {
                var dRecv = cur.recv - root._prevStats.recv;
                var dGaps = cur.gaps - root._prevStats.gaps;
                var total = dRecv + dGaps;
                if (total <= 0) {
                    root.quality = 0;
                    root.gapRate = 1;
                } else {
                    root.gapRate = dGaps / total;
                    root.quality = root.gapRate < 0.03 ? 2 : root.gapRate < 0.12 ? 1 : 0;
                }
            } else if (peers === 0) {
                root.quality = -1;
            }
            root._prevStats = cur;
        }
    }
    Timer {
        interval: 1000
        running: root.inRoom
        repeat: true
        onTriggered: root.callSeconds = Math.floor((Date.now() - root.callStartMs) / 1000)
    }
    Component.onCompleted: {
        nameField.text = prefs.displayName;
        refresh();
    }

    // Brand coral gradient (same ramp as Persona and the plugin icon).
    Gradient {
        id: accentGrad
        GradientStop {
            position: 0.0
            color: "#F28E6B"
        }
        GradientStop {
            position: 1.0
            color: "#E1613A"
        }
    }

    // ── Design-system building blocks (shared with Persona) ──────────

    component Card: Rectangle {
        id: cardRoot
        default property alias content: cardCol.data
        property string title: ""
        property bool glow: false
        property int pad: Theme.spacing.large
        Layout.fillWidth: true
        color: Theme.palette.backgroundTertiary
        border.color: Theme.palette.borderSubtle
        border.width: 1
        radius: Theme.spacing.radiusLarge
        implicitHeight: cardCol.implicitHeight + pad * 2
        clip: true

        Rectangle {
            visible: cardRoot.glow
            anchors.fill: parent
            radius: cardRoot.radius
            gradient: Gradient {
                GradientStop {
                    position: 0.0
                    color: Theme.colors.getColor(Theme.palette.primary, 0.10)
                }
                GradientStop {
                    position: 0.6
                    color: "transparent"
                }
            }
        }
        // Concentric rings — a sound wave echoing the circular Logos mark.
        Repeater {
            model: cardRoot.glow ? 3 : 0
            Rectangle {
                width: 90 + index * 70
                height: width
                radius: width / 2
                x: cardRoot.width - 95 - width / 2
                y: 85 - height / 2
                color: "transparent"
                border.width: 1.5
                border.color: Theme.colors.getColor(Theme.palette.primary, 0.22 - index * 0.06)
            }
        }

        ColumnLayout {
            id: cardCol
            anchors {
                fill: parent
                margins: cardRoot.pad
            }
            spacing: Theme.spacing.medium
            RowLayout {
                visible: cardRoot.title.length > 0
                spacing: Theme.spacing.small
                Rectangle {
                    implicitWidth: 4
                    implicitHeight: 12
                    radius: 2
                    color: Theme.palette.primary
                }
                LogosText {
                    text: cardRoot.title
                    color: Theme.palette.textSecondary
                    font.pixelSize: 11
                    font.weight: Theme.typography.weightMedium
                    font.letterSpacing: 0.8
                    font.capitalization: Font.AllUppercase
                }
            }
        }
    }

    component ActionButton: Control {
        id: btn
        property string text: ""
        property string tip: ""
        property bool accent: false
        property bool danger: false
        property bool busy: false
        signal clicked
        hoverEnabled: true
        implicitHeight: 40
        implicitWidth: btnRow.implicitWidth + 36
        readonly property bool isActive: btnMa.pressed || btn.hovered
        scale: (btnMa.pressed && btn.enabled) ? 0.96 : 1.0
        Behavior on scale {
            NumberAnimation {
                duration: 90
                easing.type: Easing.OutQuad
            }
        }
        Tip {
            text: btn.tip
            visible: btn.hovered && btn.tip.length > 0
        }
        background: Rectangle {
            radius: Theme.spacing.radiusXlarge
            gradient: (btn.accent && btn.enabled) ? accentGrad : null
            color: !btn.enabled ? Theme.palette.backgroundMuted : btn.danger ? Theme.colors.getColor(Theme.palette.error, btn.isActive ? 0.85 : 0.72) : (btn.isActive ? Theme.palette.backgroundMuted : Theme.palette.backgroundSecondary)
            border.width: (btn.accent || btn.danger) && btn.enabled ? 0 : 1
            border.color: !btn.enabled ? Theme.palette.border : (btn.isActive ? Theme.palette.overlayOrange : Theme.palette.border)
            Behavior on color {
                ColorAnimation {
                    duration: 120
                }
            }
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: "#FFFFFF"
                opacity: (btn.accent && btn.enabled && btn.isActive) ? 0.14 : 0
                Behavior on opacity {
                    NumberAnimation {
                        duration: 120
                    }
                }
            }
        }
        contentItem: Item {
            RowLayout {
                id: btnRow
                anchors.centerIn: parent
                spacing: Theme.spacing.small
                LogosSpinner {
                    visible: btn.busy
                    Layout.preferredWidth: 14
                    Layout.preferredHeight: 14
                }
                LogosText {
                    text: btn.text
                    font.pixelSize: Theme.typography.secondaryText
                    font.weight: (btn.accent || btn.danger) ? Theme.typography.weightBold : Theme.typography.weightMedium
                    color: !btn.enabled ? Theme.palette.textMuted : btn.accent ? "#241511" : btn.danger ? "#FFFFFF" : Theme.palette.text
                }
            }
        }
        MouseArea {
            id: btnMa
            anchors.fill: parent
            enabled: btn.enabled
            cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: btn.clicked()
        }
    }

    component MiniButton: Control {
        id: mb
        property string label: ""
        property string tip: ""
        signal clicked
        hoverEnabled: true
        implicitHeight: 26
        implicitWidth: mbLabel.implicitWidth + 20
        scale: mbMa.pressed ? 0.94 : 1.0
        Behavior on scale {
            NumberAnimation {
                duration: 90
                easing.type: Easing.OutQuad
            }
        }
        Tip {
            text: mb.tip
            visible: mb.hovered && mb.tip.length > 0
        }
        background: Rectangle {
            radius: Theme.spacing.radiusPill
            color: mb.hovered ? Theme.palette.backgroundMuted : "transparent"
            border.width: 1
            border.color: mb.hovered ? Theme.palette.overlayOrange : Theme.palette.borderSubtle
            Behavior on border.color {
                ColorAnimation {
                    duration: 120
                }
            }
        }
        contentItem: LogosText {
            id: mbLabel
            text: mb.label
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: 11
            font.weight: Theme.typography.weightMedium
            color: mb.hovered ? Theme.palette.text : Theme.palette.textSecondary
        }
        MouseArea {
            id: mbMa
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: mb.clicked()
        }
    }

    component StatusDot: Item {
        id: sdot
        property color c: Theme.palette.textTertiary
        property bool pulsing: false
        implicitWidth: 16
        implicitHeight: 16
        onPulsingChanged: if (!pulsing)
            halo.opacity = 1
        Rectangle {
            id: halo
            anchors.fill: parent
            radius: width / 2
            color: Theme.colors.getColor(sdot.c, 0.22)
            SequentialAnimation on opacity {
                running: sdot.pulsing
                loops: Animation.Infinite
                NumberAnimation {
                    from: 1
                    to: 0.25
                    duration: 700
                    easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    from: 0.25
                    to: 1
                    duration: 700
                    easing.type: Easing.InOutQuad
                }
            }
        }
        Rectangle {
            anchors.centerIn: parent
            width: 8
            height: 8
            radius: 4
            color: sdot.c
        }
    }

    component StatusPill: Rectangle {
        id: spill
        property color c: Theme.palette.success
        property bool pulsing: false
        property string label: ""
        property string tip: ""
        HoverHandler {
            id: spillHover
        }
        Tip {
            text: spill.tip
            visible: spillHover.hovered && spill.tip.length > 0
        }
        radius: Theme.spacing.radiusPill
        color: Theme.palette.backgroundInset
        border.width: 1
        border.color: Theme.palette.borderHairline
        implicitHeight: 30
        implicitWidth: spillRow.implicitWidth + 24
        RowLayout {
            id: spillRow
            anchors.centerIn: parent
            spacing: 6
            StatusDot {
                c: spill.c
                pulsing: spill.pulsing
            }
            LogosText {
                text: spill.label
                font.pixelSize: Theme.typography.secondaryText
                font.weight: Theme.typography.weightMedium
                color: Theme.palette.text
            }
        }
    }

    component Chip: Rectangle {
        id: chip
        property string label: ""
        property color tint: Theme.palette.primary
        property bool clickable: false
        signal clicked
        radius: Theme.spacing.radiusPill
        color: Theme.colors.getColor(chip.tint, chipMa.containsMouse ? 0.22 : 0.13)
        border.width: 1
        border.color: Theme.colors.getColor(chip.tint, 0.45)
        implicitHeight: 26
        implicitWidth: chipLabel.implicitWidth + 22
        Behavior on color {
            ColorAnimation {
                duration: 120
            }
        }
        LogosText {
            id: chipLabel
            anchors.centerIn: parent
            text: chip.label
            font.pixelSize: 12
            font.weight: Theme.typography.weightMedium
            color: chip.tint
        }
        MouseArea {
            id: chipMa
            anchors.fill: parent
            enabled: chip.clickable
            hoverEnabled: chip.clickable
            cursorShape: chip.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: chip.clicked()
        }
    }

    component NoticeBanner: Rectangle {
        id: nb
        property color tint: Theme.palette.info
        property string text: ""
        Layout.fillWidth: true
        color: Theme.colors.getColor(nb.tint, 0.10)
        border.color: Theme.colors.getColor(nb.tint, 0.40)
        border.width: 1
        radius: Theme.spacing.radiusMedium
        implicitHeight: nbText.implicitHeight + Theme.spacing.medium * 2
        LogosText {
            id: nbText
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                leftMargin: Theme.spacing.medium
                rightMargin: Theme.spacing.medium
            }
            text: nb.text
            wrapMode: Text.Wrap
            color: Theme.palette.text
            font.pixelSize: Theme.typography.secondaryText
        }
    }

    // Two-way pill switch in the Basecamp idiom.
    component Segmented: Rectangle {
        id: segRoot
        property var options: []
        property int current: 0
        signal picked(int index)
        radius: Theme.spacing.radiusPill
        color: Theme.palette.backgroundInset
        border.width: 1
        border.color: Theme.palette.borderHairline
        implicitHeight: 32
        implicitWidth: segRow.implicitWidth + 6
        Row {
            id: segRow
            anchors.centerIn: parent
            spacing: 2
            Repeater {
                model: segRoot.options
                Rectangle {
                    readonly property bool on: segRoot.current === index
                    implicitHeight: 26
                    width: segLabel.implicitWidth + 22
                    height: 26
                    radius: Theme.spacing.radiusPill
                    color: on ? Theme.colors.getColor(Theme.palette.primary, 0.16) : (segMa.containsMouse ? Theme.palette.backgroundMuted : "transparent")
                    border.width: on ? 1 : 0
                    border.color: Theme.colors.getColor(Theme.palette.primary, 0.55)
                    Behavior on color {
                        ColorAnimation {
                            duration: 120
                        }
                    }
                    LogosText {
                        id: segLabel
                        anchors.centerIn: parent
                        text: modelData
                        font.pixelSize: 12
                        font.weight: Theme.typography.weightMedium
                        color: parent.on ? Theme.palette.primary : Theme.palette.textSecondary
                    }
                    MouseArea {
                        id: segMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: segRoot.picked(index)
                    }
                }
            }
        }
    }

    component FieldLabel: LogosText {
        color: Theme.palette.textSecondary
        font.pixelSize: 11
        font.weight: Theme.typography.weightMedium
        font.letterSpacing: 0.8
        font.capitalization: Font.AllUppercase
    }

    component Tip: LogosToolTip {
        timeout: -1
        delay: 150
        placement: LogosToolTip.Top
        width: Math.min(implicitWidth, 320)
        height: labelItem.implicitHeight + verticalPadding * 2 + 4
        horizontalPadding: Theme.spacing.small
        verticalPadding: Theme.spacing.tiny
        Component.onCompleted: labelItem.wrapMode = Text.Wrap
    }

    // Microphone glyph drawn from primitives; `off` adds the strike-through.
    component MicGlyph: Item {
        id: mic
        property color c: Theme.palette.text
        property bool off: false
        implicitWidth: 22
        implicitHeight: 22
        onCChanged: micArc.requestPaint()
        Rectangle {
            x: parent.width * 0.33
            y: 0
            width: parent.width * 0.34
            height: parent.height * 0.58
            radius: width / 2
            color: mic.c
        }
        Canvas {
            id: micArc
            anchors.fill: parent
            onPaint: {
                var g = getContext("2d");
                g.reset();
                g.strokeStyle = mic.c;
                g.lineWidth = Math.max(1.6, width * 0.09);
                g.lineCap = "round";
                g.beginPath();
                g.arc(width / 2, height * 0.40, width * 0.30, 0, Math.PI, false);
                g.stroke();
                g.beginPath();
                g.moveTo(width / 2, height * 0.72);
                g.lineTo(width / 2, height * 0.92);
                g.moveTo(width * 0.34, height * 0.94);
                g.lineTo(width * 0.66, height * 0.94);
                g.stroke();
            }
        }
        Rectangle {
            visible: mic.off
            anchors.centerIn: parent
            width: parent.width * 1.15
            height: Math.max(2, parent.width * 0.09)
            radius: height / 2
            rotation: 45
            color: mic.c
            border.width: 1
            border.color: Theme.palette.backgroundTertiary
        }
    }

    // Five-bar level meter.
    component LevelBars: Row {
        id: lb
        property real level: 0
        property color c: Theme.palette.primary
        spacing: 3
        Repeater {
            model: 5
            Rectangle {
                width: 4
                height: 6 + index * 3
                radius: 2
                anchors.bottom: parent ? parent.bottom : undefined
                color: lb.level * 5.5 > index + 0.3 ? lb.c : Theme.palette.backgroundButton
                Behavior on color {
                    ColorAnimation {
                        duration: 80
                    }
                }
            }
        }
    }

    // Signal-strength style quality indicator.
    component QualityBars: Row {
        id: qb
        property int q: -1
        spacing: 2
        Repeater {
            model: 3
            Rectangle {
                width: 4
                height: 6 + index * 4
                radius: 1.5
                anchors.bottom: parent ? parent.bottom : undefined
                color: (qb.q >= 0 && index <= qb.q) ? root.qualityColor(qb.q) : Theme.palette.backgroundButton
            }
        }
    }

    // Participant avatar: tinted circle with initials and a speaking ring.
    component Avatar: Item {
        id: av
        property string seed: ""
        property string name: ""
        property real level: 0
        property int size: 84
        readonly property bool speaking: level > 0.08
        implicitWidth: size + 28
        implicitHeight: size + 28
        property real lvl: 0
        onLevelChanged: lvl = Math.max(level, lvl * 0.6)
        Behavior on lvl {
            NumberAnimation {
                duration: 90
            }
        }
        Rectangle {
            anchors.centerIn: parent
            width: av.size + 6 + 22 * Math.min(1, av.lvl * 1.8)
            height: width
            radius: width / 2
            color: Theme.colors.getColor(Theme.palette.primary, 0.10 * Math.min(1, av.lvl * 2.5))
            border.width: 2
            border.color: Theme.palette.primary
            opacity: av.lvl < 0.04 ? 0 : Math.min(1, av.lvl * 3)
        }
        Rectangle {
            anchors.centerIn: parent
            width: av.size
            height: av.size
            radius: av.size / 2
            color: Qt.hsla(root.hueFor(av.seed), 0.42, 0.34, 1)
            border.width: 1
            border.color: Theme.palette.borderHairline
            LogosText {
                anchors.centerIn: parent
                text: root.initials(av.name)
                color: "#FFFFFF"
                font.pixelSize: av.size * 0.34
                font.weight: Theme.typography.weightBold
            }
        }
    }

    // ── Layout ───────────────────────────────────────────────────────
    ColumnLayout {
        anchors {
            top: parent.top
            bottom: parent.bottom
            topMargin: Theme.spacing.xlarge
            bottomMargin: Theme.spacing.xlarge
            horizontalCenter: parent.horizontalCenter
        }
        width: Math.min(root.width - Theme.spacing.xlarge * 2, 1180)
        spacing: Theme.spacing.large

        // Header — plugin mark, product name, network status
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.medium
            Image {
                source: "icons/chorus.png"
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
                sourceSize: Qt.size(128, 128)
                smooth: true
            }
            LogosText {
                text: "Chorus"
                color: Theme.palette.text
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
            }
            Item {
                Layout.fillWidth: true
            }
            StatusPill {
                c: root.statusColor(root.netStatus)
                pulsing: root.netStatus === 1 || root.joining
                label: root.joining && root.netStatus !== 2 ? "Connecting" : root.statusLabel(root.netStatus)
                tip: root.statusTip(root.netStatus)
            }
        }

        // Error banner
        Rectangle {
            id: errBanner
            Layout.fillWidth: true
            readonly property string msg: root.lastError.length ? root.lastError : (root.st.netError || "")
            visible: msg.length > 0
            color: Theme.colors.getColor(Theme.palette.error, 0.10)
            border.color: Theme.colors.getColor(Theme.palette.error, 0.45)
            border.width: 1
            radius: Theme.spacing.radiusLarge
            implicitHeight: errRow.implicitHeight + Theme.spacing.medium * 2
            RowLayout {
                id: errRow
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    margins: Theme.spacing.medium
                }
                spacing: Theme.spacing.small
                LogosText {
                    Layout.fillWidth: true
                    text: errBanner.msg
                    wrapMode: Text.Wrap
                    color: Theme.palette.error
                    font.pixelSize: Theme.typography.secondaryText
                }
                MiniButton {
                    visible: root.lastError.length > 0
                    label: "Dismiss"
                    onClicked: root.lastError = ""
                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // ── Lobby ────────────────────────────────────────────────
            Flickable {
                anchors.fill: parent
                visible: !root.inRoom
                contentHeight: Math.max(height, lobbyCard.implicitHeight)
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Card {
                    id: lobbyCard
                    glow: true
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -Theme.spacing.xlarge
                    width: Math.min(parent.width, 520)
                    pad: Theme.spacing.xlarge

                    LogosText {
                        Layout.bottomMargin: Theme.spacing.small
                        text: "Join a room"
                        color: Theme.palette.text
                        font.pixelSize: 28
                        font.weight: Theme.typography.weightBold
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        RowLayout {
                            Layout.fillWidth: true
                            FieldLabel {
                                text: "Room"
                                Layout.fillWidth: true
                            }
                            MiniButton {
                                label: "Random"
                                tip: "Hard to guess — only people you share it with can find it."
                                onClicked: roomField.text = root.randomRoom()
                            }
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 44
                            radius: Theme.spacing.radiusSmall
                            color: Theme.palette.backgroundSecondary
                            border.width: 1
                            border.color: roomField.textInput.activeFocus ? Theme.palette.overlayOrange : Theme.palette.backgroundElevated
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                spacing: 2
                                LogosText {
                                    text: "#"
                                    color: Theme.palette.primary
                                    font.pixelSize: Theme.typography.primaryText
                                    font.weight: Theme.typography.weightBold
                                }
                                LogosTextField {
                                    id: roomField
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    leftPadding: 2
                                    placeholderText: "standup"
                                    background: Item {}
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        FieldLabel {
                            text: "Name"
                        }
                        LogosTextField {
                            id: nameField
                            Layout.fillWidth: true
                            implicitHeight: 44
                            placeholderText: "Optional"
                        }
                    }

                    Connections {
                        target: roomField.textInput
                        function onAccepted() {
                            root.join(roomField.text);
                        }
                    }
                    Connections {
                        target: nameField.textInput
                        function onAccepted() {
                            root.join(roomField.text);
                        }
                    }

                    ActionButton {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.spacing.small
                        implicitHeight: 46
                        accent: true
                        busy: root.joining
                        enabled: root.normalizeRoom(roomField.text).length > 0 && !root.joining
                        text: root.joining ? "Joining…" : "Join"
                        onClicked: root.join(roomField.text)
                    }

                    // Honest, one line: topics are public and audio is plaintext.
                    LogosText {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: "Open room · anyone with the name can listen"
                        color: Theme.palette.textTertiary
                        font.pixelSize: 11
                    }

                    Flow {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.spacing.small
                        visible: root.recentRooms.length > 0
                        spacing: Theme.spacing.small
                        Repeater {
                            model: root.recentRooms
                            Chip {
                                label: "#" + modelData
                                clickable: true
                                onClicked: {
                                    roomField.text = modelData;
                                    root.join(modelData);
                                }
                            }
                        }
                    }
                }
            }

            // ── In a call ────────────────────────────────────────────
            ColumnLayout {
                id: callView
                anchors.fill: parent
                visible: root.inRoom
                focus: root.inRoom
                Keys.onPressed: function (e) {
                    if (e.isAutoRepeat)
                        return;
                    if (e.key === Qt.Key_Space && root.ptt) {
                        root.pttDown();
                        e.accepted = true;
                    } else if (e.key === Qt.Key_M && !root.ptt) {
                        root.toggleMute();
                        e.accepted = true;
                    }
                }
                Keys.onReleased: function (e) {
                    if (e.isAutoRepeat)
                        return;
                    if (e.key === Qt.Key_Space) {
                        root.pttUp();
                        e.accepted = true;
                    }
                }
                spacing: Theme.spacing.large

                // Call bar
                Card {
                    pad: Theme.spacing.medium
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.spacing.small
                        spacing: Theme.spacing.medium
                        LogosText {
                            text: "#" + (root.st.roomId || "")
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.subtitleText
                            font.weight: Theme.typography.weightBold
                            elide: Text.ElideRight
                            Layout.maximumWidth: 360
                        }
                        Chip {
                            readonly property int n: root.everyone().length
                            label: n + (n === 1 ? " voice" : " voices")
                        }
                        LogosText {
                            text: root.clock(root.callSeconds)
                            color: Theme.palette.textSecondary
                            font.family: "Menlo"
                            font.pixelSize: Theme.typography.secondaryText
                        }
                        Item {
                            Layout.fillWidth: true
                        }
                        MiniButton {
                            visible: (root.st.peers || []).length > 0
                            label: root.copied === "room" ? "✓ Copied" : "Copy name"
                            onClicked: root.copy(root.st.roomId || "", "room")
                        }
                    }
                }

                NoticeBanner {
                    visible: (root.st.micError || "") !== ""
                    tint: Theme.palette.warning
                    text: "Microphone unavailable — listening only"
                }

                // Participants
                Item {
                    id: stage
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    readonly property var people: root.everyone()
                    readonly property bool alone: people.length === 1
                    readonly property int tiles: people.length + (alone ? 1 : 0)
                    readonly property int cols: tiles <= 1 ? 1 : tiles <= 4 ? 2 : tiles <= 9 ? 3 : 4
                    readonly property int rows: Math.ceil(tiles / cols)

                    GridLayout {
                        id: tileGrid
                        anchors.fill: parent
                        columns: stage.cols
                        columnSpacing: Theme.spacing.medium
                        rowSpacing: Theme.spacing.medium

                        // Keyed on the count, not the array: st refreshes at
                        // 10 Hz and an array model would rebuild every tile
                        // (and reset its animations) on each poll.
                        Repeater {
                            model: stage.people.length
                            Rectangle {
                                readonly property var p: stage.people[index] || ({})
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.preferredWidth: 100
                                Layout.preferredHeight: 100
                                Layout.minimumHeight: 160
                                readonly property bool talking: p.level > 0.08
                                radius: Theme.spacing.radiusLarge
                                color: Theme.palette.backgroundTertiary
                                border.width: talking ? 2 : 1
                                border.color: talking ? Theme.palette.primary : Theme.palette.borderSubtle
                                Behavior on border.color {
                                    ColorAnimation {
                                        duration: 150
                                    }
                                }

                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: Theme.spacing.small
                                    Avatar {
                                        Layout.alignment: Qt.AlignHCenter
                                        seed: p.id
                                        name: p.name
                                        level: p.level
                                        size: Math.max(56, Math.min(96, parent.parent.height * 0.36))
                                    }
                                    LogosText {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: p.name
                                        color: Theme.palette.text
                                        font.pixelSize: Theme.typography.primaryText
                                        font.weight: Theme.typography.weightMedium
                                    }
                                }

                                // Corner badges: "You" and muted state
                                Row {
                                    anchors {
                                        left: parent.left
                                        bottom: parent.bottom
                                        margins: Theme.spacing.medium
                                    }
                                    spacing: Theme.spacing.small
                                    Chip {
                                        visible: p.me
                                        label: "You"
                                        tint: Theme.palette.textSecondary
                                        implicitHeight: 22
                                    }
                                }
                                Rectangle {
                                    visible: p.me && root.st.muted === true
                                    anchors {
                                        right: parent.right
                                        bottom: parent.bottom
                                        margins: Theme.spacing.medium
                                    }
                                    width: 28
                                    height: 28
                                    radius: 14
                                    color: Theme.colors.getColor(Theme.palette.error, 0.18)
                                    border.width: 1
                                    border.color: Theme.colors.getColor(Theme.palette.error, 0.5)
                                    MicGlyph {
                                        anchors.centerIn: parent
                                        width: 14
                                        height: 14
                                        c: Theme.palette.error
                                        off: true
                                    }
                                }
                            }
                        }

                        // Invite tile while you're the only one here
                        Rectangle {
                            visible: stage.alone
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.preferredWidth: 100
                            Layout.preferredHeight: 100
                            Layout.minimumHeight: 160
                            radius: Theme.spacing.radiusLarge
                            color: "transparent"
                            border.width: 1
                            border.color: Theme.palette.borderStrong

                            ColumnLayout {
                                anchors.centerIn: parent
                                width: Math.min(parent.width - 48, 300)
                                spacing: Theme.spacing.small
                                Rectangle {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.bottomMargin: Theme.spacing.small
                                    width: 44
                                    height: 44
                                    radius: 22
                                    color: Theme.colors.getColor(Theme.palette.primary, 0.16)
                                    border.width: 1
                                    border.color: Theme.palette.primary
                                    Repeater {
                                        model: 3
                                        Rectangle {
                                            id: ripple
                                            anchors.centerIn: parent
                                            width: 44
                                            height: width
                                            radius: width / 2
                                            color: "transparent"
                                            border.width: 1.5
                                            border.color: Theme.palette.primary
                                            opacity: 0
                                            SequentialAnimation {
                                                running: stage.alone && root.inRoom
                                                loops: Animation.Infinite
                                                PauseAnimation {
                                                    duration: index * 700
                                                }
                                                ParallelAnimation {
                                                    NumberAnimation {
                                                        target: ripple
                                                        property: "width"
                                                        from: 44
                                                        to: 130
                                                        duration: 2100
                                                        easing.type: Easing.OutCubic
                                                    }
                                                    NumberAnimation {
                                                        target: ripple
                                                        property: "opacity"
                                                        from: 0.6
                                                        to: 0
                                                        duration: 2100
                                                        easing.type: Easing.OutCubic
                                                    }
                                                }
                                                PauseAnimation {
                                                    duration: (2 - index) * 700
                                                }
                                            }
                                        }
                                    }
                                    LogosText {
                                        anchors.centerIn: parent
                                        text: "+"
                                        color: Theme.palette.primary
                                        font.pixelSize: 22
                                        font.weight: Theme.typography.weightBold
                                    }
                                }
                                LogosText {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: "Waiting for others"
                                    color: Theme.palette.text
                                    font.pixelSize: Theme.typography.primaryText
                                    font.weight: Theme.typography.weightMedium
                                }
                                ActionButton {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.topMargin: Theme.spacing.small
                                    text: root.copied === "invite" ? "✓ Copied" : "Copy room name"
                                    onClicked: root.copy(root.st.roomId || "", "invite")
                                }
                            }
                        }
                    }
                }

                // Control dock — mic controls left, call controls right
                Card {
                    pad: Theme.spacing.medium
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.medium

                        // Mic: toggle (open mic) or hold-to-talk pill (PTT)
                        Control {
                            id: micBtn
                            hoverEnabled: true
                            readonly property bool muted: root.st.muted === true
                            readonly property bool live: root.ptt ? root.pttHeld : !muted
                            implicitWidth: root.ptt ? 150 : 52
                            implicitHeight: 52
                            Behavior on implicitWidth {
                                NumberAnimation {
                                    duration: 160
                                    easing.type: Easing.OutCubic
                                }
                            }
                            scale: micMa.pressed ? 0.95 : 1.0
                            Behavior on scale {
                                NumberAnimation {
                                    duration: 90
                                }
                            }
                            Tip {
                                visible: micBtn.hovered && !micMa.pressed
                                text: root.ptt ? "Hold, or hold Space" : (micBtn.muted ? "Unmute (M)" : "Mute (M)")
                            }
                            background: Rectangle {
                                radius: height / 2
                                gradient: (root.ptt && root.pttHeld) ? accentGrad : null
                                color: root.ptt ? (micBtn.hovered ? Theme.palette.backgroundMuted : Theme.palette.backgroundSecondary) : micBtn.muted ? Theme.colors.getColor(Theme.palette.error, micBtn.hovered ? 0.28 : 0.18) : (micBtn.hovered ? Theme.palette.backgroundMuted : Theme.palette.backgroundSecondary)
                                border.width: (root.ptt && root.pttHeld) ? 0 : 1
                                border.color: (!root.ptt && micBtn.muted) ? Theme.colors.getColor(Theme.palette.error, 0.6) : (micBtn.hovered ? Theme.palette.overlayOrange : Theme.palette.border)
                                Behavior on color {
                                    ColorAnimation {
                                        duration: 120
                                    }
                                }
                            }
                            contentItem: Item {
                                RowLayout {
                                    anchors.centerIn: parent
                                    spacing: Theme.spacing.small
                                    MicGlyph {
                                        Layout.preferredWidth: 20
                                        Layout.preferredHeight: 20
                                        c: root.ptt ? (root.pttHeld ? "#241511" : Theme.palette.text) : (micBtn.muted ? Theme.palette.error : Theme.palette.text)
                                        off: !root.ptt && micBtn.muted
                                    }
                                    LogosText {
                                        visible: root.ptt
                                        text: root.pttHeld ? "Talking" : "Hold to talk"
                                        font.pixelSize: Theme.typography.secondaryText
                                        font.weight: Theme.typography.weightBold
                                        color: root.pttHeld ? "#241511" : Theme.palette.text
                                    }
                                }
                            }
                            MouseArea {
                                id: micMa
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onPressed: {
                                    callView.forceActiveFocus();
                                    if (root.ptt)
                                        root.pttDown();
                                }
                                onReleased: if (root.ptt)
                                    root.pttUp()
                                onCanceled: root.pttUp()
                                onClicked: if (!root.ptt)
                                    root.toggleMute()
                            }
                        }

                        ColumnLayout {
                            spacing: 4
                            Layout.preferredWidth: 64
                            LogosText {
                                text: root.st.micOk === false ? "No mic" : micBtn.live ? "Live" : "Muted"
                                color: micBtn.live ? Theme.palette.text : Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.secondaryText
                                font.weight: Theme.typography.weightMedium
                            }
                            LevelBars {
                                level: micBtn.live ? (root.st.myLevel || 0) : 0
                            }
                        }

                        Segmented {
                            options: ["Open mic", "Push to talk"]
                            current: root.ptt ? 1 : 0
                            onPicked: function (i) {
                                root.setPtt(i === 1);
                                callView.forceActiveFocus();
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        // Connection quality (details on hover)
                        Item {
                            implicitWidth: qualRow.implicitWidth
                            implicitHeight: qualRow.implicitHeight
                            visible: (root.st.peers || []).length > 0
                            HoverHandler {
                                id: qualHover
                            }
                            Tip {
                                visible: qualHover.hovered
                                text: {
                                    var s = root.st.stats || {};
                                    return "Frames sent " + (s.sent || 0) + " · received " + (s.recv || 0) + "\nMissed " + (s.underruns || 0) + " · arrived late " + (s.discards || 0) + (root.quality >= 0 ? "\nMissing right now: " + Math.round(root.gapRate * 100) + "%" : "");
                                }
                            }
                            RowLayout {
                                id: qualRow
                                spacing: Theme.spacing.small
                                QualityBars {
                                    q: root.quality
                                    Layout.alignment: Qt.AlignVCenter
                                }
                                LogosText {
                                    text: root.qualityLabel(root.quality)
                                    color: Theme.palette.textSecondary
                                    font.pixelSize: Theme.typography.secondaryText
                                }
                            }
                        }

                        ActionButton {
                            danger: true
                            text: "Leave"
                            onClicked: root.leave()
                        }
                    }
                }
            }
        }
    }
}
