import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "turntable"

  readonly property string pluginDir: {
    var path = Qt.resolvedUrl(".").toString()
    if (path.indexOf("file://") === 0) path = path.slice(7)
    if (path.length > 1 && path.charAt(path.length - 1) === "/")
      path = path.slice(0, path.length - 1)
    return path
  }
  readonly property string backendBinPath: pluginDir + "/bin/turntable"
  readonly property string setupPath: pluginDir + "/setup"
  property bool bootstrapped: false
  property bool backendReady: false

  readonly property var mediaService: {
    if (!bar || !bar.shell) return null
    if (typeof bar.shell.serviceFor === "function") {
      var s = bar.shell.serviceFor("turntable") || bar.shell.serviceFor("omarchy.media")
      if (s) return s
    }
    if (typeof bar.shell.firstPartyServiceFor === "function") {
      var s1 = bar.shell.firstPartyServiceFor("omarchy.media")
      if (s1) return s1
    }
    if (bar.shell._services) {
      return bar.shell._services["turntable"] || bar.shell._services["omarchy.media"] || null
    }
    return null
  }

  readonly property var mprisPlayerList: Mpris.players ? Mpris.players.values : []

  function findActiveMprisPlayer() {
    if (!mprisPlayerList || mprisPlayerList.length === 0) return null
    for (var i = 0; i < mprisPlayerList.length; i++) {
      var p = mprisPlayerList[i]
      if (p && p.isPlaying && (p.trackTitle || p.trackArtist)) return p
    }
    for (var j = 0; j < mprisPlayerList.length; j++) {
      var q = mprisPlayerList[j]
      if (q && (q.trackTitle || q.trackArtist)) return q
    }
    return null
  }

  readonly property var activePlayer: (mediaService && mediaService.activePlayer) ? mediaService.activePlayer : findActiveMprisPlayer()
  readonly property var sourcePlayers: (mediaService && mediaService.sourcePlayers) ? mediaService.sourcePlayers : mprisPlayerList

  readonly property bool hasMedia: activePlayer !== null && (activePlayer.trackTitle || activePlayer.trackArtist)
  readonly property bool isPlaying: activePlayer !== null && activePlayer.isPlaying
  readonly property string title: activePlayer ? (activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? (activePlayer.trackArtist || "") : ""
  readonly property string album: activePlayer && activePlayer.trackAlbum ? activePlayer.trackAlbum : ""
  readonly property string artUrl: activePlayer && activePlayer.trackArtUrl ? activePlayer.trackArtUrl : ""

  property bool popupOpen: false
  function open() {
    popupOpen = true
    triggerQueueFetch()
  }
  function close() { popupOpen = false }
  function toggle() {
    popupOpen = !popupOpen
    if (popupOpen) triggerQueueFetch()
  }

  IpcHandler {
    target: "turntable"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function shiftNext(): void { root.animateShiftToSlot(1) }
    function shiftPrev(): void { root.animateShiftToSlot(-1) }
    function like(): void { root.doToggleLike() }
    function dislike(): void { root.doToggleDislike() }
  }

  property real maxLabelWidth: 260
  readonly property color barFg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string barFontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  visible: hasMedia
  implicitWidth: hasMedia ? contentRow.implicitWidth + Style.space(16) : 0
  implicitHeight: barSize

  Behavior on implicitWidth {
    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
  }

  // -------------------------------------------------------------
  // Playback, YouTube Music & Queue State Management
  // -------------------------------------------------------------
  property bool ytmAvailable: true
  property string currentRating: "NONE"
  property real lastRatingActionMs: 0
  property bool ytmShuffleActive: false
  property int ytmRepeatMode: 0
  property string pendingYtmAction: ""
  property string pendingYtmTitle: ""
  property string pendingYtmArtist: ""

  property bool queueInitialized: false
  property var prevQueue: []
  property var nextQueue: []
  property var overflowPrev: []
  property var overflowNext: []
  property var catalogPool: []
  property int poolCursor: 0
  property bool awaitingMprisSettle: false
  property string lastConfirmedTitleKey: ""
  property var displayedCenterTrack: ({
    title: root.title || "",
    artist: root.artist || "",
    album: root.album || "",
    artUrl: "",
    remoteArtUrl: "",
    rating: "NONE"
  })

  property real carouselShift: 0.0
  property real vinylAngle: 0.0
  property real lastManualShiftMs: 0
  property int pendingSkipSteps: 0
  property int pendingSkipDir: 0
  property string lastObservedSignature: ""

  property string queryTitle: ""
  property string queryArtist: ""
  property string queryAlbum: ""
  property string queryArt: ""

  // Live playback progress state
  property real livePosition: activePlayer && activePlayer.positionSupported ? Number(activePlayer.position || 0) : 0
  property real lastMprisReportedPos: -1.0
  property real lastStageTickMs: 0
  readonly property real trackLength: activePlayer && activePlayer.lengthSupported && activePlayer.length > 0
    ? Number(activePlayer.length)
    : (displayedCenterTrack && displayedCenterTrack.duration > 0 ? Number(displayedCenterTrack.duration) : 0)
  property bool isDraggingProgress: false
  property real dragProgressRatio: 0.0

  readonly property real effectiveProgressRatio: {
    if (isDraggingProgress) return Math.max(0.0, Math.min(1.0, dragProgressRatio))
    if (trackLength <= 0) return 0.0
    return Math.max(0.0, Math.min(1.0, livePosition / trackLength))
  }

  function formatSeconds(sec) {
    var s = Math.max(0, Math.floor(Number(sec) || 0))
    var m = Math.floor(s / 60)
    var rem = s % 60
    return (m < 10 ? "0" + m : "" + m) + ":" + (rem < 10 ? "0" + rem : "" + rem)
  }

  function normTitleKey(t) {
    if (!t || !t.title || t.title === "Nothing playing") return ""
    var cleanT = String(t.title).replace(/\s*[\(\[][^)\]]*(remaster|edition|version|deluxe|exclusive|live|audio|video|official|feat\.?|ft\.?|with\s)[^)\]]*[\)\]]/gi, "")
    return String(cleanT).toLowerCase().replace(/[^a-z0-9]+/g, "")
  }

  function normTrackKey(t) {
    if (!t || !t.title || t.title === "Nothing playing") return ""
    var cleanT = String(t.title).replace(/\s*[\(\[][^)\]]*(remaster|edition|version|deluxe|exclusive|live|audio|video|official|feat\.?|ft\.?|with\s)[^)\]]*[\)\]]/gi, "")
    var primaryA = String(t.artist || "").split(/\s*(?:,|&|and|feat\.?|ft\.?)\s*/i)[0] || ""
    return String(cleanT + "|" + primaryA).toLowerCase().replace(/[^a-z0-9|]+/g, "")
  }

  function isValidHistoryTrack(t) {
    if (!t || !t.title) return false
    var titleStr = String(t.title).trim()
    var artistStr = String(t.artist || "").trim()
    if (!titleStr || titleStr === "Nothing playing" || !artistStr) return false
    if (titleStr.indexOf("Previous Track ") === 0 || titleStr.indexOf("Up Next ") === 0) return false
    return true
  }

  function cloneTrackObj(t, fallbackArtUrl) {
    if (!t) return makeFallbackTrack(1)
    var art = sanitizeArtUrl(t.artUrl, t.remoteArtUrl || fallbackArtUrl || "")
    return {
      title: String(t.title || ""),
      artist: String(t.artist || ""),
      album: String(t.album || ""),
      artUrl: art,
      remoteArtUrl: String(t.remoteArtUrl || art),
      duration: Number(t.duration || 0),
      rating: String(t.rating || "NONE"),
      needsFill: !!t.needsFill
    }
  }

  function buildUsedMap(centerT, prevArr, nextArr) {
    var used = {}
    function mark(item) {
      if (!item || !isValidHistoryTrack(item) || item.needsFill) return
      var tk = normTitleKey(item)
      var fk = normTrackKey(item)
      if (tk) used[tk] = true
      if (fk) used[fk] = true
    }
    mark(centerT)
    if (Array.isArray(prevArr)) {
      for (var i = 0; i < prevArr.length; i++) mark(prevArr[i])
    }
    if (Array.isArray(nextArr)) {
      for (var j = 0; j < nextArr.length; j++) mark(nextArr[j])
    }
    return used
  }

  function pickFreshEdgeTrack(fallbackOffset, usedMap) {
    var fallbackArt = (displayedCenterTrack && displayedCenterTrack.remoteArtUrl)
      ? displayedCenterTrack.remoteArtUrl
      : ((displayedCenterTrack && displayedCenterTrack.artUrl) ? displayedCenterTrack.artUrl : "")
    if (catalogPool && catalogPool.length > 0) {
      for (var attempt = 0; attempt < catalogPool.length; attempt++) {
        var idx = (root.poolCursor + attempt) % catalogPool.length
        var cand = catalogPool[idx]
        if (!isValidHistoryTrack(cand)) continue
        var tk = normTitleKey(cand)
        var fk = normTrackKey(cand)
        if ((tk && usedMap[tk]) || (fk && usedMap[fk])) continue
        root.poolCursor = (idx + 1) % catalogPool.length
        if (tk) usedMap[tk] = true
        if (fk) usedMap[fk] = true
        var picked = cloneTrackObj(cand, fallbackArt)
        picked.needsFill = false
        return picked
      }
    }
    var placeholder = makeFallbackTrack(fallbackOffset)
    placeholder.needsFill = true
    return placeholder
  }

  function sanitizeArtUrl(url, fallbackUrl) {
    var s = String(url || "")
    // Avoid binding directly to transient /tmp/.com.google.Chrome.* files that Chrome deletes on track change
    if (s.indexOf("file:///tmp/.com.google.Chrome") === 0) {
      return String(fallbackUrl || "")
    }
    return s || String(fallbackUrl || "")
  }

  function makeFallbackTrack(offsetIndex) {
    var isPrev = offsetIndex < 0
    var idx = Math.abs(offsetIndex)
    return {
      title: isPrev ? ("Previous Track " + idx) : ("Up Next " + idx),
      artist: root.artist || "Queue",
      album: root.album || "",
      artUrl: (displayedCenterTrack && displayedCenterTrack.remoteArtUrl)
        ? displayedCenterTrack.remoteArtUrl
        : ((displayedCenterTrack && displayedCenterTrack.artUrl) ? displayedCenterTrack.artUrl : ""),
      duration: 0
    }
  }

  function ensureFivePerSide() {
    var p = prevQueue ? prevQueue.slice(0, 5) : []
    var n = nextQueue ? nextQueue.slice(0, 5) : []
    while (p.length < 5) p.push(makeFallbackTrack(-(p.length + 1)))
    while (n.length < 5) n.push(makeFallbackTrack(n.length + 1))
    prevQueue = p
    nextQueue = n
  }

  function triggerQueueFetch() {
    if (!root.title && !root.artist) return
    queryTitle = root.title
    queryArtist = root.artist
    queryAlbum = root.album
    queryArt = root.artUrl
    if (!queueFetchProcess.running) {
      queueFetchProcess.running = true
    } else {
      refetchTimer.restart()
    }
  }

  Timer {
    id: refetchTimer
    interval: 350
    repeat: false
    onTriggered: root.triggerQueueFetch()
  }

  Process {
    id: bootstrapProcess
    command: [root.setupPath]
    running: false
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.backendReady = true
        root.triggerQueueFetch()
        if (root.isPlaying && !spectrumProcess.running) {
          spectrumProcess.running = true
        }
      }
    }
  }

  Process {
    id: queueFetchProcess
    running: false
    command: [
      root.backendBinPath,
      "--title", root.queryTitle,
      "--artist", root.queryArtist,
      "--album", root.queryAlbum,
      "--art", root.queryArt
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim().length > 0) root.backendReady = true
        root.applyFetchedQueue(text)
      }
    }
    onExited: function(exitCode) {
      if (!root.backendReady && !root.bootstrapped && exitCode !== 0) {
        root.bootstrapped = true
        bootstrapProcess.running = true
      }
    }
  }

  // Real-time 48-band PipeWire/PulseAudio FFT spectrum streamer (Rust)
  property var liveSpectrumBands: []
  property var liveSpectrumPeaks: []

  Process {
    id: spectrumProcess
    running: root.isPlaying && !bootstrapProcess.running
    command: [root.backendBinPath, "--spectrum"]
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var obj = JSON.parse(String(line || "").trim())
          if (obj) {
            root.backendReady = true
            if (Array.isArray(obj.b)) root.liveSpectrumBands = obj.b
            if (Array.isArray(obj.p)) root.liveSpectrumPeaks = obj.p
          }
        } catch (e) {}
      }
    }
    onExited: function(exitCode) {
      if (!root.backendReady && !root.bootstrapped && exitCode !== 0) {
        root.bootstrapped = true
        bootstrapProcess.running = true
      }
    }
  }

  function spectrumBandAt(barIndex, totalBars) {
    if (!root.isPlaying || !root.liveSpectrumBands || root.liveSpectrumBands.length === 0) return 0.14
    var n = root.liveSpectrumBands.length
    var idx = Math.min(n - 1, Math.max(0, Math.round((barIndex / Math.max(1, totalBars - 1)) * (n - 1))))
    return Number(root.liveSpectrumBands[idx]) || 0.14
  }

  function spectrumPeakAt(barIndex, totalBars) {
    if (!root.isPlaying || !root.liveSpectrumPeaks || root.liveSpectrumPeaks.length === 0) return 0.18
    var n = root.liveSpectrumPeaks.length
    var idx = Math.min(n - 1, Math.max(0, Math.round((barIndex / Math.max(1, totalBars - 1)) * (n - 1))))
    return Number(root.liveSpectrumPeaks[idx]) || 0.18
  }

  Process {
    id: ytmActionProcess
    running: false
    command: [
      root.backendBinPath,
      "--action", root.pendingYtmAction,
      "--title", root.pendingYtmTitle,
      "--artist", root.pendingYtmArtist
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var res = JSON.parse(String(text || "").trim())
          if (res && (res.action === "like" || res.action === "dislike") && res.rating) {
            root.currentRating = res.rating
          }
        } catch (e) {}
      }
    }
  }

  function runYtmAction(actionName) {
    var t = (displayedCenterTrack && displayedCenterTrack.title) ? displayedCenterTrack.title : root.title
    var a = (displayedCenterTrack && displayedCenterTrack.artist) ? displayedCenterTrack.artist : root.artist
    root.pendingYtmAction = actionName
    root.pendingYtmTitle = t || ""
    root.pendingYtmArtist = a || ""
    if (!ytmActionProcess.running) {
      ytmActionProcess.running = true
    }
  }

  function applyFetchedQueue(rawText) {
    var parsed = null
    try {
      parsed = JSON.parse(String(rawText || "").trim())
    } catch (e) {
      parsed = null
    }
    if (!parsed) {
      ensureFivePerSide()
      return
    }

    if (parsed.ytmAvailable !== undefined) {
      root.ytmAvailable = !!parsed.ytmAvailable
    }

    var cur = parsed.current || {}
    var safeCenterArt = sanitizeArtUrl(cur.artUrl, cur.remoteArtUrl)
    var fetchedRating = String(cur.rating || "NONE")
    if (Date.now() - root.lastRatingActionMs > 2500) {
      root.currentRating = fetchedRating
    } else {
      fetchedRating = root.currentRating
    }

    // Update displayedCenterTrack artwork/metadata in place without disturbing shifted queue slots
    var curNorm = normTitleKey(cur)
    var dispNorm = normTitleKey(displayedCenterTrack)
    if (!root.awaitingMprisSettle || curNorm === dispNorm || !displayedCenterTrack.artUrl) {
      displayedCenterTrack = {
        title: root.title || displayedCenterTrack.title || cur.title || "Nothing playing",
        artist: root.artist || displayedCenterTrack.artist || cur.artist || "",
        album: root.album || displayedCenterTrack.album || cur.album || "",
        artUrl: (curNorm === dispNorm || !displayedCenterTrack.artUrl)
          ? (safeCenterArt || displayedCenterTrack.artUrl || "")
          : displayedCenterTrack.artUrl,
        remoteArtUrl: cur.remoteArtUrl || safeCenterArt || displayedCenterTrack.remoteArtUrl || "",
        duration: cur.duration || displayedCenterTrack.duration || 0,
        rating: fetchedRating
      }
    }

    // If a recently shifted slot in prevQueue matches `cur` and was waiting for its cached artUrl, update its artUrl in place
    if (safeCenterArt && curNorm && prevQueue && prevQueue.length === 5) {
      var pUpdated = false
      var pCopy = prevQueue.slice(0, 5)
      for (var pi = 0; pi < 5; pi++) {
        if (normTitleKey(pCopy[pi]) === curNorm && (!pCopy[pi].artUrl || pCopy[pi].artUrl.indexOf("file:///tmp/.com.google") === 0)) {
          pCopy[pi] = cloneTrackObj(pCopy[pi], safeCenterArt)
          pCopy[pi].artUrl = safeCenterArt
          pCopy[pi].remoteArtUrl = safeCenterArt
          pUpdated = true
        }
      }
      if (pUpdated) prevQueue = pCopy
    }

    var fetchedPrev = Array.isArray(parsed.previous) ? parsed.previous : []
    var fetchedNext = Array.isArray(parsed.next) ? parsed.next : []

    // Append fresh tracks into catalogPool without wiping existing pool tracks
    var mergedPool = []
    var poolSeen = {}
    function addPoolCandidate(item) {
      if (!isValidHistoryTrack(item)) return
      var tk = normTitleKey(item)
      if (!tk || poolSeen[tk]) return
      poolSeen[tk] = true
      mergedPool.push(cloneTrackObj(item, safeCenterArt))
    }
    for (var i = 0; i < fetchedNext.length; i++) addPoolCandidate(fetchedNext[i])
    for (var j = 0; j < fetchedPrev.length; j++) addPoolCandidate(fetchedPrev[j])
    for (var k = 0; k < catalogPool.length && mergedPool.length < 40; k++) addPoolCandidate(catalogPool[k])
    catalogPool = mergedPool

    // INITIAL SEED ONLY: populate all 5 prev and 5 next slots once on startup
    if (!root.queueInitialized) {
      var initUsed = buildUsedMap(displayedCenterTrack, [], [])
      var initPrev = []
      var initNext = []
      for (var nIdx = 0; nIdx < 5; nIdx++) {
        if (nIdx < fetchedNext.length && isValidHistoryTrack(fetchedNext[nIdx])) {
          var nt = cloneTrackObj(fetchedNext[nIdx], safeCenterArt)
          nt.needsFill = false
          initUsed[normTitleKey(nt)] = true
          initUsed[normTrackKey(nt)] = true
          initNext.push(nt)
        } else {
          initNext.push(pickFreshEdgeTrack(nIdx + 1, initUsed))
        }
      }
      for (var pIdx = 0; pIdx < 5; pIdx++) {
        if (pIdx < fetchedPrev.length && isValidHistoryTrack(fetchedPrev[pIdx])) {
          var pt = cloneTrackObj(fetchedPrev[pIdx], safeCenterArt)
          pt.needsFill = false
          initUsed[normTitleKey(pt)] = true
          initUsed[normTrackKey(pt)] = true
          initPrev.push(pt)
        } else {
          initPrev.push(pickFreshEdgeTrack(-(pIdx + 1), initUsed))
        }
      }
      prevQueue = initPrev
      nextQueue = initNext
      root.queueInitialized = true
      return
    }

    // SUBSEQUENT FETCHES: NEVER overwrite valid shifted tracks in prevQueue or nextQueue!
    // Only fill slots that were marked `needsFill` or are fallback placeholders.
    ensureFivePerSide()
    var usedNow = buildUsedMap(displayedCenterTrack, prevQueue, nextQueue)
    var nextChanged = false
    var nextCopy = nextQueue.slice(0, 5)
    for (var ni = 0; ni < 5; ni++) {
      if (!isValidHistoryTrack(nextCopy[ni]) || nextCopy[ni].needsFill) {
        nextCopy[ni] = pickFreshEdgeTrack(ni + 1, usedNow)
        nextChanged = true
      }
    }
    if (nextChanged) nextQueue = nextCopy

    var prevChanged = false
    var prevCopy = prevQueue.slice(0, 5)
    for (var pvi = 0; pvi < 5; pvi++) {
      if (!isValidHistoryTrack(prevCopy[pvi]) || prevCopy[pvi].needsFill) {
        prevCopy[pvi] = pickFreshEdgeTrack(-(pvi + 1), usedNow)
        prevChanged = true
      }
    }
    if (prevChanged) prevQueue = prevCopy
  }

  // Shift the 11-slot conveyor belt by `steps` (+1..+5 forward, -1..-5 backward)
  // Every existing track in `prevQueue` and `nextQueue` shifts position; only the newly
  // vacated outer edge slot(s) get filled!
  function shiftBeltBySteps(steps, explicitNewCenter) {
    var s = Math.round(Number(steps) || 0)
    if (s === 0) return
    s = Math.max(-5, Math.min(5, s))
    ensureFivePerSide()

    var fallbackArt = (displayedCenterTrack && displayedCenterTrack.remoteArtUrl)
      ? displayedCenterTrack.remoteArtUrl
      : ((displayedCenterTrack && displayedCenterTrack.artUrl) ? displayedCenterTrack.artUrl : "")

    // 11-slot belt before shift:
    // index:   0             1             2             3             4             5                     6             7             8             9             10
    // offset: -5 (PREV 5)   -4 (PREV 4)   -3 (PREV 3)   -2 (PREV 2)   -1 (PREV 1)    0 (CENTER)           +1 (NEXT +1)  +2 (NEXT +2)  +3 (NEXT +3)  +4 (NEXT +4)  +5 (NEXT +5)
    var line = [
      cloneTrackObj(prevQueue[4], fallbackArt),
      cloneTrackObj(prevQueue[3], fallbackArt),
      cloneTrackObj(prevQueue[2], fallbackArt),
      cloneTrackObj(prevQueue[1], fallbackArt),
      cloneTrackObj(prevQueue[0], fallbackArt),
      cloneTrackObj(displayedCenterTrack, fallbackArt),
      cloneTrackObj(nextQueue[0], fallbackArt),
      cloneTrackObj(nextQueue[1], fallbackArt),
      cloneTrackObj(nextQueue[2], fallbackArt),
      cloneTrackObj(nextQueue[3], fallbackArt),
      cloneTrackObj(nextQueue[4], fallbackArt)
    ]

    var newCenterIdx = 5 + s
    var targetSlotTrack = line[newCenterIdx] || line[5]
    var chosenCenter = explicitNewCenter ? cloneTrackObj(explicitNewCenter, targetSlotTrack.artUrl || fallbackArt) : targetSlotTrack
    if (explicitNewCenter && (!chosenCenter.artUrl || chosenCenter.artUrl === fallbackArt) && normTitleKey(chosenCenter) === normTitleKey(targetSlotTrack)) {
      chosenCenter.artUrl = targetSlotTrack.artUrl
      chosenCenter.remoteArtUrl = targetSlotTrack.remoteArtUrl
    }

    if (s > 0) {
      // Save tracks that drop off the far-left edge (past PREV 5) onto overflowPrev
      var ovPrev = overflowPrev ? overflowPrev.slice(0, 25) : []
      for (var dropL = s - 1; dropL >= 0; dropL--) {
        if (isValidHistoryTrack(line[dropL]) && !line[dropL].needsFill) {
          ovPrev.unshift(line[dropL])
        }
      }
      overflowPrev = ovPrev.slice(0, 25)
    } else if (s < 0) {
      // Save tracks that drop off the far-right edge (past NEXT +5) onto overflowNext
      var ovNext = overflowNext ? overflowNext.slice(0, 25) : []
      var absS = Math.abs(s)
      for (var dropR = 11 - absS; dropR <= 10; dropR++) {
        if (isValidHistoryTrack(line[dropR]) && !line[dropR].needsFill) {
          ovNext.unshift(line[dropR])
        }
      }
      overflowNext = ovNext.slice(0, 25)
    }

    var updatedPrev = []
    for (var i = 1; i <= 5; i++) {
      var lIdx = newCenterIdx - i
      if (lIdx >= 0 && lIdx < line.length && isValidHistoryTrack(line[lIdx])) {
        updatedPrev.push(line[lIdx])
      } else {
        updatedPrev.push( null )
      }
    }

    var updatedNext = []
    for (var j = 1; j <= 5; j++) {
      var rIdx = newCenterIdx + j
      if (rIdx >= 0 && rIdx < line.length && isValidHistoryTrack(line[rIdx])) {
        updatedNext.push(line[rIdx])
      } else {
        updatedNext.push( null )
      }
    }

    var usedMap = buildUsedMap(chosenCenter, updatedPrev, updatedNext)

    // Fill ONLY the newly vacated outer edge slot(s)
    var ovP = overflowPrev ? overflowPrev.slice() : []
    for (var pi = 0; pi < 5; pi++) {
      if (!updatedPrev[pi]) {
        var restoredP = null
        while (ovP.length > 0) {
          var candP = ovP.shift()
          if (isValidHistoryTrack(candP) && !usedMap[normTitleKey(candP)]) {
            restoredP = candP
            usedMap[normTitleKey(candP)] = true
            break
          }
        }
        updatedPrev[pi] = restoredP ? restoredP : pickFreshEdgeTrack(-(pi + 1), usedMap)
      }
    }
    overflowPrev = ovP

    var ovN = overflowNext ? overflowNext.slice() : []
    for (var ni = 0; ni < 5; ni++) {
      if (!updatedNext[ni]) {
        var restoredN = null
        while (ovN.length > 0) {
          var candN = ovN.shift()
          if (isValidHistoryTrack(candN) && !usedMap[normTitleKey(candN)]) {
            restoredN = candN
            usedMap[normTitleKey(candN)] = true
            break
          }
        }
        updatedNext[ni] = restoredN ? restoredN : pickFreshEdgeTrack(ni + 1, usedMap)
      }
    }
    overflowNext = ovN

    displayedCenterTrack = chosenCenter
    prevQueue = updatedPrev
    nextQueue = updatedNext
  }

  Timer {
    id: trackChangeDebounceTimer
    interval: 45
    repeat: false
    onTriggered: root.processDebouncedTrackChange()
  }

  Timer {
    id: mprisSettleTimer
    interval: 2400
    repeat: false
    onTriggered: {
      root.awaitingMprisSettle = false
    }
  }

  function handleExternalTrackChange() {
    trackChangeDebounceTimer.restart()
  }

  function processDebouncedTrackChange() {
    if (!root.title && !root.artist) return

    var newTrack = {
      title: root.title || "",
      artist: root.artist || "",
      album: root.album || "",
      artUrl: sanitizeArtUrl(root.artUrl, ""),
      remoteArtUrl: "",
      duration: 0,
      rating: "NONE"
    }
    var newTitleKey = normTitleKey(newTrack)
    if (!newTitleKey) return

    // Cold start when first player attaches: record initial title key without shifting belt
    if (!root.lastConfirmedTitleKey) {
      root.lastConfirmedTitleKey = newTitleKey
      displayedCenterTrack = newTrack
      triggerQueueFetch()
      return
    }

    // Same song (only album/art/artist metadata refined): update center in place, do NOT shift queue
    if (newTitleKey === root.lastConfirmedTitleKey) {
      if (!root.awaitingMprisSettle) {
        displayedCenterTrack = {
          title: root.title || displayedCenterTrack.title,
          artist: root.artist || displayedCenterTrack.artist,
          album: root.album || displayedCenterTrack.album,
          artUrl: displayedCenterTrack.artUrl || newTrack.artUrl || "",
          remoteArtUrl: displayedCenterTrack.remoteArtUrl || "",
          duration: displayedCenterTrack.duration || 0,
          rating: root.currentRating
        }
      }
      triggerQueueFetch()
      return
    }

    root.lastConfirmedTitleKey = newTitleKey

    // If we ALREADY shifted the conveyor belt via `animateShiftToSlot`, do NOT shift a second time!
    // Simply update the center record's title/artist to match the settled MPRIS track.
    if (root.awaitingMprisSettle) {
      if (root.pendingSkipSteps <= 0) {
        root.awaitingMprisSettle = false
        mprisSettleTimer.stop()
      }
      var keepArt = (normTitleKey(displayedCenterTrack) === newTitleKey) ? (displayedCenterTrack.artUrl || "") : ""
      displayedCenterTrack = {
        title: root.title,
        artist: root.artist,
        album: root.album,
        artUrl: keepArt,
        remoteArtUrl: keepArt,
        duration: 0,
        rating: "NONE"
      }
      triggerQueueFetch()
      return
    }

    // Natural / external track change: determine direction (-1 if matches PREV 1, otherwise +1 forward)
    var dir = 1
    if (prevQueue && prevQueue.length > 0 && normTitleKey(prevQueue[0]) === newTitleKey) {
      dir = -1
    }

    shiftBeltBySteps(dir, newTrack)
    root.livePosition = 0

    if (root.popupOpen) {
      carouselShiftAnim.stop()
      root.carouselShift = dir
      carouselShiftAnim.start()
    }
    triggerQueueFetch()
  }

  onTitleChanged: handleExternalTrackChange()
  onArtistChanged: handleExternalTrackChange()
  onArtUrlChanged: handleExternalTrackChange()

  Component.onCompleted: {
    ensureFivePerSide()
    if (root.hasMedia) {
      displayedCenterTrack = {
        title: root.title,
        artist: root.artist,
        album: root.album,
        artUrl: "",
        remoteArtUrl: "",
        duration: 0
      }
      root.lastConfirmedTitleKey = normTitleKey(displayedCenterTrack)
      triggerQueueFetch()
    }
  }

  NumberAnimation {
    id: carouselShiftAnim
    target: root
    property: "carouselShift"
    to: 0.0
    duration: 440
    easing.type: Easing.OutCubic
  }

  // Multi-step MPRIS skip dispatcher when clicking a queue song >1 slot away
  Timer {
    id: multiSkipTimer
    interval: 150
    repeat: true
    onTriggered: {
      if (root.pendingSkipSteps <= 0) {
        stop()
        return
      }
      root.pendingSkipSteps -= 1
      if (root.pendingSkipDir > 0) root.sendMprisNext()
      else if (root.pendingSkipDir < 0) root.sendMprisPrevious()
      if (root.pendingSkipSteps <= 0) stop()
    }
  }

  function trackForSlot(slotOffset) {
    if (slotOffset === 0) return displayedCenterTrack
    if (slotOffset < 0) {
      var pIdx = Math.min(4, Math.max(0, Math.abs(slotOffset) - 1))
      return (prevQueue && prevQueue[pIdx]) ? prevQueue[pIdx] : makeFallbackTrack(slotOffset)
    } else {
      var nIdx = Math.min(4, Math.max(0, slotOffset - 1))
      return (nextQueue && nextQueue[nIdx]) ? nextQueue[nIdx] : makeFallbackTrack(slotOffset)
    }
  }

  function animateShiftToSlot(delta) {
    var steps = Math.round(Number(delta) || 0)
    if (steps === 0) return
    steps = Math.max(-5, Math.min(5, steps))

    root.lastManualShiftMs = Date.now()
    root.awaitingMprisSettle = true
    mprisSettleTimer.restart()

    shiftBeltBySteps(steps, null)
    root.livePosition = 0

    // Set initial shift offset to `steps` and smoothly animate to 0.0
    if (root.popupOpen) {
      carouselShiftAnim.stop()
      root.carouselShift = steps
      carouselShiftAnim.start()
    }

    // Dispatch actual MPRIS track changes
    var absSteps = Math.abs(steps)
    var dir = steps > 0 ? 1 : -1
    if (dir > 0) sendMprisNext()
    else sendMprisPrevious()

    if (absSteps > 1) {
      root.pendingSkipDir = dir
      root.pendingSkipSteps = absSteps - 1
      multiSkipTimer.restart()
    } else {
      root.pendingSkipSteps = 0
      multiSkipTimer.stop()
    }
  }

  function sendMprisPrevious() {
    if (mediaService && typeof mediaService.runAction === "function") {
      mediaService.runAction("previous", false, mediaService.playerKey ? mediaService.playerKey(activePlayer) : undefined)
    } else if (activePlayer && activePlayer.canGoPrevious && typeof activePlayer.previous === "function") {
      activePlayer.previous()
    } else if (root.bar) {
      root.bar.run("omarchy-shell -q media previous")
    }
  }

  function sendMprisNext() {
    if (mediaService && typeof mediaService.runAction === "function") {
      mediaService.runAction("next", false, mediaService.playerKey ? mediaService.playerKey(activePlayer) : undefined)
    } else if (activePlayer && activePlayer.canGoNext && typeof activePlayer.next === "function") {
      activePlayer.next()
    } else if (root.bar) {
      root.bar.run("omarchy-shell -q media next")
    }
  }

  function doPrevious() {
    if (root.popupOpen) {
      animateShiftToSlot(-1)
    } else {
      sendMprisPrevious()
    }
  }

  function doPlayPause() {
    if (mediaService && typeof mediaService.runAction === "function") {
      mediaService.runAction("playPause", false, mediaService.playerKey ? mediaService.playerKey(activePlayer) : undefined)
    } else if (activePlayer) {
      if (activePlayer.isPlaying && activePlayer.canPause && typeof activePlayer.pause === "function") {
        activePlayer.pause()
      } else if (!activePlayer.isPlaying && activePlayer.canPlay && typeof activePlayer.play === "function") {
        activePlayer.play()
      } else if (activePlayer.canTogglePlaying && typeof activePlayer.togglePlaying === "function") {
        activePlayer.togglePlaying()
      } else if (typeof activePlayer.togglePlaying === "function") {
        activePlayer.togglePlaying()
      } else if (typeof activePlayer.pause === "function" && activePlayer.isPlaying) {
        activePlayer.pause()
      } else if (typeof activePlayer.play === "function") {
        activePlayer.play()
      } else if (root.bar) {
        root.bar.run("omarchy-shell -q media playPause")
      }
    } else if (root.bar) {
      root.bar.run("omarchy-shell -q media playPause")
    }
  }

  function doNext() {
    if (root.popupOpen) {
      animateShiftToSlot(1)
    } else {
      sendMprisNext()
    }
  }

  function doSeekRatio(ratio) {
    var clamped = Math.max(0.0, Math.min(1.0, Number(ratio) || 0.0))
    if (trackLength <= 0 || !activePlayer) return
    var targetSec = clamped * trackLength
    livePosition = targetSec
    if (activePlayer.positionSupported) {
      activePlayer.position = targetSec
    } else if (activePlayer.canSeek && typeof activePlayer.seek === "function") {
      activePlayer.seek(targetSec - Number(activePlayer.position || 0))
    }
  }

  function doSeekRelative(deltaSeconds) {
    if (!activePlayer) return
    var d = Number(deltaSeconds) || 0
    var nextPos = Math.max(0, Math.min(trackLength > 0 ? trackLength : 99999, livePosition + d))
    livePosition = nextPos
    if (activePlayer.canSeek && typeof activePlayer.seek === "function") {
      activePlayer.seek(d)
    } else if (activePlayer.positionSupported) {
      activePlayer.position = nextPos
    } else if (root.ytmAvailable) {
      root.runYtmAction(d >= 0 ? "seek-forward" : "seek-backward")
    }
  }

  function doToggleShuffle() {
    if (activePlayer && activePlayer.shuffleSupported) {
      activePlayer.shuffle = !activePlayer.shuffle
    } else if (root.ytmAvailable) {
      root.ytmShuffleActive = !root.ytmShuffleActive
      root.runYtmAction("shuffle")
      if (!root.popupOpen && mediaService && typeof mediaService.showOsd === "function") {
        mediaService.showOsd("YouTube Music Shuffle", "media")
      }
    }
  }

  function doCycleLoop() {
    if (activePlayer && activePlayer.loopSupported) {
      if (activePlayer.loopState === MprisLoopState.None) {
        activePlayer.loopState = MprisLoopState.Playlist
      } else if (activePlayer.loopState === MprisLoopState.Playlist) {
        activePlayer.loopState = MprisLoopState.Track
      } else {
        activePlayer.loopState = MprisLoopState.None
      }
    } else if (root.ytmAvailable) {
      root.ytmRepeatMode = (root.ytmRepeatMode + 1) % 3
      root.runYtmAction("repeat")
      if (!root.popupOpen && mediaService && typeof mediaService.showOsd === "function") {
        var rLabel = root.ytmRepeatMode === 1 ? "Repeat All" : (root.ytmRepeatMode === 2 ? "Repeat One" : "Repeat Off")
        mediaService.showOsd(rLabel, "media")
      }
    }
  }

  function doToggleLike() {
    root.lastRatingActionMs = Date.now()
    var nextState = root.currentRating === "LIKE" ? "NONE" : "LIKE"
    root.currentRating = nextState
    if (displayedCenterTrack) {
      displayedCenterTrack = {
        title: displayedCenterTrack.title,
        artist: displayedCenterTrack.artist,
        album: displayedCenterTrack.album,
        artUrl: displayedCenterTrack.artUrl,
        remoteArtUrl: displayedCenterTrack.remoteArtUrl,
        duration: displayedCenterTrack.duration,
        rating: nextState
      }
    }
    root.runYtmAction("like")
    if (!root.popupOpen && mediaService && typeof mediaService.showOsd === "function") {
      mediaService.showOsd(nextState === "LIKE" ? "Liked on YouTube Music" : "Removed Like", "media")
    }
  }

  function doToggleDislike() {
    root.lastRatingActionMs = Date.now()
    var nextState = root.currentRating === "DISLIKE" ? "NONE" : "DISLIKE"
    root.currentRating = nextState
    if (displayedCenterTrack) {
      displayedCenterTrack = {
        title: displayedCenterTrack.title,
        artist: displayedCenterTrack.artist,
        album: displayedCenterTrack.album,
        artUrl: displayedCenterTrack.artUrl,
        remoteArtUrl: displayedCenterTrack.remoteArtUrl,
        duration: displayedCenterTrack.duration,
        rating: nextState
      }
    }
    root.runYtmAction("dislike")
    if (!root.popupOpen && mediaService && typeof mediaService.showOsd === "function") {
      mediaService.showOsd(nextState === "DISLIKE" ? "Disliked on YouTube Music" : "Removed Dislike", "media")
    }
  }

  function doOpenYtm() {
    root.runYtmAction("open-ytm")
    root.close()
  }

  // Live 60 FPS position & vinyl rotation timer when overlay is open
  Timer {
    id: stageTickTimer
    interval: 16
    running: root.popupOpen && (root.isPlaying || Math.abs(root.carouselShift) > 0.01)
    repeat: true
    onRunningChanged: {
      root.lastStageTickMs = running ? Date.now() : 0
    }
    onTriggered: {
      var now = Date.now()
      var dt = root.lastStageTickMs > 0 ? Math.min(0.1, Math.max(0.0, (now - root.lastStageTickMs) / 1000.0)) : 0.016
      root.lastStageTickMs = now
      if (root.isPlaying) {
        var speedBoost = 1.0 + Math.min(2.5, Math.abs(root.carouselShift) * 1.4)
        root.vinylAngle = (root.vinylAngle + 33.75 * dt * speedBoost) % 360.0
        if (!root.isDraggingProgress) {
          var maxLen = root.trackLength > 0 ? root.trackLength : 99999
          root.livePosition = Math.min(maxLen, root.livePosition + dt)
        }
      }
    }
  }

  Timer {
    id: positionPollTimer
    interval: 250
    running: root.popupOpen && root.activePlayer !== null
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!root.activePlayer || root.isDraggingProgress) return
      if (typeof root.activePlayer.positionChanged === "function") {
        root.activePlayer.positionChanged()
      }
      if (root.activePlayer.positionSupported) {
        var reported = Number(root.activePlayer.position || 0)
        if (!root.isPlaying) {
          root.livePosition = reported
          root.lastMprisReportedPos = reported
        } else if (Math.abs(reported - root.lastMprisReportedPos) > 0.01) {
          root.lastMprisReportedPos = reported
          var drift = reported - root.livePosition
          if (Math.abs(drift) > 1.2 || reported < 0.5) {
            root.livePosition = reported
          } else {
            var nextPos = root.livePosition + drift * 0.25
            if (nextPos > root.livePosition) {
              root.livePosition = nextPos
            }
          }
        }
      }
    }
  }

  function iconOpticalDeltaX(glyph) {
    if (glyph === "󰒫" || glyph === "󰔒" || glyph === "󰔑" || glyph === "󰔔" || glyph === "󰔓" || glyph === "󰑖" || glyph === "󰑘" || glyph === "󰐊") {
      return 1
    }
    return 0
  }

  function iconOpticalDeltaY(glyph) {
    // Dislike (thumbs-down) has its heavy palm at the top: shift down (+2) so visual mass is centered
    if (glyph === "󰔒" || glyph === "󰔑") return 2
    // Like (thumbs-up) has its heavy palm at the bottom: shift up (-1) so it mirrors Dislike symmetrically
    if (glyph === "󰔔" || glyph === "󰔓") return -1
    // Previous and Next glyphs sit ~2px above the font box vertical center
    if (glyph === "󰒮" || glyph === "󰒭") return 2
    if (glyph === "󰒝" || glyph === "󰑖" || glyph === "󰑘" || glyph === "󰐊") return 1
    return 0
  }

  // -------------------------------------------------------------
  // Inline Media Button (TOP BAR)
  // -------------------------------------------------------------
  component MediaButton: Rectangle {
    id: btn
    property string iconText: ""
    property string tooltipText: ""
    property color iconColor: root.bar ? root.bar.barForeground : Color.foreground
    property bool activeState: false
    property color activeColor: Color.accent
    property bool enabled: true
    signal clicked()

    width: Style.space(24)
    height: Style.space(24)
    radius: Style.space(12)
    antialiasing: true
    color: {
      if (activeState) return Qt.rgba(activeColor.r, activeColor.g, activeColor.b, mouse.containsMouse ? 0.28 : 0.20)
      if (mouse.containsMouse) return Style.hoverFillFor(root.bar ? root.bar.barForeground : Color.foreground, activeColor)
      return "transparent"
    }
    border.width: activeState ? 1 : 0
    border.color: activeState ? activeColor : "transparent"
    anchors.verticalCenter: parent.verticalCenter

    TextMetrics {
      id: topBtnMetrics
      font: topBtnTxt.font
      text: btn.iconText
    }

    Text {
      id: topBtnTxt
      textFormat: Text.PlainText
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: (topBtnMetrics.tightBoundingRect.width > 0
        ? Math.round((topBtnMetrics.boundingRect.x + topBtnMetrics.boundingRect.width / 2.0) - (topBtnMetrics.tightBoundingRect.x + topBtnMetrics.tightBoundingRect.width / 2.0))
        : 0) + root.iconOpticalDeltaX(btn.iconText)
      anchors.verticalCenterOffset: (topBtnMetrics.tightBoundingRect.height > 0
        ? Math.round((topBtnMetrics.boundingRect.y + topBtnMetrics.boundingRect.height / 2.0) - (topBtnMetrics.tightBoundingRect.y + topBtnMetrics.tightBoundingRect.height / 2.0))
        : 0) + Math.round(root.iconOpticalDeltaY(btn.iconText) * 0.6)
      text: btn.iconText
      color: btn.activeState ? btn.activeColor : btn.iconColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Math.round(Style.font.body * 1.38)
      font.bold: true
      opacity: btn.enabled ? (mouse.containsMouse || btn.activeState ? 1.0 : 0.88) : 0.35

      Behavior on color {
        ColorAnimation { duration: 120 }
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (btn.enabled) btn.clicked()
      onEntered: if (root.bar && btn.tooltipText) root.bar.showTooltip(btn, btn.tooltipText)
      onExited: if (root.bar) root.bar.hideTooltip(btn)
    }
  }

  // -------------------------------------------------------------
  // Live Audio-Reactive Spectrum Visualizer (TOP BAR - Click Opens Overlay)
  // -------------------------------------------------------------
  component CliampVisualizer: Item {
    id: eq
    readonly property int barCount: 16
    readonly property int barWidthPx: Style.space(3)
    readonly property int barSpacingPx: Style.space(2)
    width: barCount * barWidthPx + (barCount - 1) * barSpacingPx
    height: Style.space(16)
    anchors.verticalCenter: parent.verticalCenter

    readonly property bool active: root.isPlaying

    Row {
      anchors.fill: parent
      spacing: eq.barSpacingPx

      Repeater {
        model: eq.barCount

        Item {
          id: barCol
          required property int index
          width: eq.barWidthPx
          height: eq.height

          property real level: root.spectrumBandAt(index, eq.barCount)
          property real peak: root.spectrumPeakAt(index, eq.barCount)

          Behavior on level {
            NumberAnimation { duration: 45; easing.type: Easing.OutQuad }
          }

          Behavior on peak {
            NumberAnimation { duration: 45; easing.type: Easing.OutQuad }
          }

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
          }

          Rectangle {
            width: parent.width
            height: Math.max(parent.width, Math.round(parent.height * barCol.level))
            anchors.bottom: parent.bottom
            radius: width / 2
            gradient: Gradient {
              GradientStop { position: 0.0; color: Color.flatColor("cyan") || Qt.lighter(Color.accent, 1.55) }
              GradientStop { position: 0.45; color: Qt.lighter(Color.accent, 1.2) }
              GradientStop { position: 1.0; color: Color.accent }
            }
          }

          Rectangle {
            width: parent.width
            height: Math.max(1, Style.space(2))
            radius: width / 2
            y: Math.max(0, parent.height - Math.round(parent.height * barCol.peak) - height)
            color: Color.flatColor("cyan") || Qt.lighter(Color.accent, 1.7)
            opacity: eq.active ? 0.95 : 0.25
          }
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.popupOpen = !root.popupOpen
        if (root.popupOpen) root.triggerQueueFetch()
      }
      onEntered: if (root.bar) root.bar.showTooltip(eq, root.popupOpen ? "Close Turntable Overlay" : "Open Turntable Overlay")
      onExited: if (root.bar) root.bar.hideTooltip(eq)
    }
  }

  // -------------------------------------------------------------
  // Main Content Row (TOP BAR - KEPT AS IS)
  // -------------------------------------------------------------
  Row {
    id: contentRow
    height: parent.height
    anchors.centerIn: parent
    spacing: Style.space(8)

    CliampVisualizer {
      id: visualizer
    }

    Row {
      height: Style.space(24)
      spacing: Style.space(3)
      anchors.verticalCenter: parent.verticalCenter

      MediaButton {
        iconText: "󰒮"
        tooltipText: "Previous"
        enabled: root.activePlayer && root.activePlayer.canGoPrevious
        onClicked: root.animateShiftToSlot(-1)
      }

      MediaButton {
        iconText: root.isPlaying ? "󰏤" : "󰐊"
        tooltipText: root.isPlaying ? "Pause" : "Play"
        iconColor: Color.accent
        enabled: root.activePlayer !== null
        onClicked: root.doPlayPause()
      }

      MediaButton {
        iconText: "󰒭"
        tooltipText: "Skip"
        enabled: root.activePlayer && root.activePlayer.canGoNext
        onClicked: root.animateShiftToSlot(1)
      }
    }

    Rectangle {
      width: Style.space(1)
      height: Style.space(12)
      color: Color.muted
      opacity: 0.35
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.bar.vertical && (root.title !== "" || root.artist !== "")
    }

    Item {
      id: labelClip
      width: Math.min(root.maxLabelWidth, labelInnerRow.implicitWidth)
      height: Style.space(20)
      clip: true
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.bar.vertical && (root.title !== "" || root.artist !== "")

      Row {
        id: labelInnerRow
        height: parent.height
        spacing: Style.space(5)
        anchors.verticalCenter: parent.verticalCenter

        property bool needsScroll: implicitWidth > labelClip.width

        NumberAnimation on x {
          id: scrollAnim
          running: labelInnerRow.needsScroll && !root.bar.vertical && root.isPlaying
          loops: Animation.Infinite
          duration: Math.max(6000, labelInnerRow.implicitWidth * 25)
          from: labelClip.width
          to: -labelInnerRow.implicitWidth
          easing.type: Easing.Linear
        }

        states: [
          State {
            when: !labelInnerRow.needsScroll || (!root.isPlaying && !scrollAnim.running)
            PropertyChanges { target: labelInnerRow; x: 0 }
          }
        ]

        Text {
          textFormat: Text.PlainText
          text: root.title || "Nothing playing"
          color: root.bar ? root.bar.barForeground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          text: "·"
          color: Color.muted
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          visible: root.artist !== "" && root.title !== ""
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          text: root.artist
          color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.25)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          visible: root.artist !== ""
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

        onClicked: function(mouse) {
          if (mouse.button === Qt.MiddleButton) {
            root.animateShiftToSlot(1)
          } else {
            root.popupOpen = !root.popupOpen
            if (root.popupOpen) root.triggerQueueFetch()
          }
        }
        onWheel: function(wheel) {
          if (wheel.angleDelta.y > 0) root.animateShiftToSlot(-1)
          else if (wheel.angleDelta.y < 0) root.animateShiftToSlot(1)
        }
        onEntered: {
          if (root.bar) {
            var fullText = root.title + (root.artist ? " — " + root.artist : "")
            if (root.activePlayer && root.activePlayer.trackAlbum) {
              fullText += " (" + root.activePlayer.trackAlbum + ")"
            }
            root.bar.showTooltip(labelClip, fullText)
          }
        }
        onExited: if (root.bar) root.bar.hideTooltip(labelClip)
      }
    }
  }

  // -------------------------------------------------------------
  // Expanded Stage Spectrum Visualizer Component (Live Audio-Reactive)
  // -------------------------------------------------------------
  component StageSpectrumVisualizer: Item {
    id: stageEq
    property int barCount: 44
    property int barWidthPx: Style.space(5)
    property int barSpacingPx: Style.space(3)
    property real maxBarOpacity: 0.85
    readonly property bool active: root.isPlaying && root.popupOpen

    width: barCount * barWidthPx + (barCount - 1) * barSpacingPx
    height: Style.space(34)

    Row {
      anchors.fill: parent
      spacing: stageEq.barSpacingPx

      Repeater {
        model: stageEq.barCount

        Item {
          id: sCol
          required property int index
          width: stageEq.barWidthPx
          height: stageEq.height

          property real level: stageEq.active ? root.spectrumBandAt(index, stageEq.barCount) : 0.14
          property real peak: stageEq.active ? root.spectrumPeakAt(index, stageEq.barCount) : 0.18

          Behavior on level {
            NumberAnimation { duration: 45; easing.type: Easing.OutQuad }
          }

          Behavior on peak {
            NumberAnimation { duration: 45; easing.type: Easing.OutQuad }
          }

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
          }

          Rectangle {
            width: parent.width
            height: Math.max(parent.width, Math.round(parent.height * sCol.level))
            anchors.bottom: parent.bottom
            radius: width / 2
            opacity: stageEq.maxBarOpacity
            gradient: Gradient {
              GradientStop { position: 0.0; color: Color.flatColor("cyan") || Qt.lighter(Color.accent, 1.55) }
              GradientStop { position: 0.45; color: Qt.lighter(Color.accent, 1.2) }
              GradientStop { position: 1.0; color: Color.accent }
            }
          }

          Rectangle {
            width: parent.width
            height: Math.max(2, Style.space(2))
            radius: 1
            y: Math.max(0, parent.height - Math.round(parent.height * sCol.peak) - height)
            color: Color.flatColor("cyan") || Qt.lighter(Color.accent, 1.7)
            opacity: stageEq.active ? 0.95 : 0.25
          }
        }
      }
    }
  }

  // -------------------------------------------------------------
  // Deck Control Button Component (Consistent Circular Icon Buttons)
  // -------------------------------------------------------------
  component DeckButton: Rectangle {
    id: dBtn
    property string iconText: ""
    property string labelText: ""
    property string tooltipText: ""
    property bool primary: false
    property bool activeState: false
    property color activeColor: Color.accent
    property bool enabled: true
    property int btnSize: primary ? Style.space(54) : Style.space(42)
    readonly property int evenSize: Math.round(btnSize / 2) * 2
    property int btnWidth: evenSize
    property int btnHeight: evenSize
    signal clicked()

    readonly property string effectiveTooltip: tooltipText !== "" ? tooltipText : labelText

    width: btnWidth
    height: btnHeight
    radius: height / 2
    antialiasing: true
    anchors.verticalCenter: parent.verticalCenter

    color: {
      if (!enabled) return Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.04)
      if (primary) {
        return dMouse.pressed
          ? Qt.darker(Color.accent, 1.15)
          : (dMouse.containsMouse ? Qt.lighter(Color.accent, 1.18) : Color.accent)
      }
      if (activeState) {
        return dMouse.pressed
          ? Qt.darker(activeColor, 1.15)
          : (dMouse.containsMouse ? Qt.lighter(activeColor, 1.16) : activeColor)
      }
      return dMouse.containsMouse
        ? Qt.rgba(activeColor.r, activeColor.g, activeColor.b, 0.25)
        : "#141820"
    }

    border.width: 2
    border.color: {
      if (!enabled) return Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.12)
      if (primary) return Qt.lighter(Color.accent, 1.30)
      if (activeState) return Qt.lighter(activeColor, 1.25)
      if (dMouse.containsMouse) return activeColor
      return Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.34)
    }

    Behavior on color { ColorAnimation { duration: 110 } }
    Behavior on border.color { ColorAnimation { duration: 110 } }

    TextMetrics {
      id: dGlyphMetrics
      font: dIconTxt.font
      text: dBtn.iconText
    }

    Text {
      id: dIconTxt
      visible: dBtn.iconText !== "󰏤"
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: (dGlyphMetrics.tightBoundingRect.width > 0
        ? Math.round((dGlyphMetrics.boundingRect.x + dGlyphMetrics.boundingRect.width / 2.0) - (dGlyphMetrics.tightBoundingRect.x + dGlyphMetrics.tightBoundingRect.width / 2.0))
        : 0) + root.iconOpticalDeltaX(dBtn.iconText)
      anchors.verticalCenterOffset: (dGlyphMetrics.tightBoundingRect.height > 0
        ? Math.round((dGlyphMetrics.boundingRect.y + dGlyphMetrics.boundingRect.height / 2.0) - (dGlyphMetrics.tightBoundingRect.y + dGlyphMetrics.tightBoundingRect.height / 2.0))
        : 0) + root.iconOpticalDeltaY(dBtn.iconText)
      textFormat: Text.PlainText
      text: dBtn.iconText
      color: (dBtn.primary || dBtn.activeState)
        ? Color.background
        : (dMouse.containsMouse && dBtn.enabled ? dBtn.activeColor : root.barFg)
      font.family: root.barFontFamily
      font.pixelSize: Math.round(dBtn.height * 0.56)
      font.bold: true
      opacity: dBtn.enabled ? 1.0 : 0.35
    }

    // Precision vector Pause bars with guaranteed even-pixel dimensions so left/right and top/bottom margins are 100% identical
    Row {
      visible: dBtn.iconText === "󰏤"
      anchors.centerIn: parent
      readonly property int barW: Math.max(4, Math.round((dBtn.height * 0.11) / 2) * 2)
      readonly property int barH: Math.max(12, Math.round((dBtn.height * 0.40) / 2) * 2)
      spacing: barW
      opacity: dBtn.enabled ? 1.0 : 0.35

      Rectangle {
        width: parent.barW
        height: parent.barH
        radius: width / 2
        antialiasing: true
        color: dIconTxt.color
      }

      Rectangle {
        width: parent.barW
        height: parent.barH
        radius: width / 2
        antialiasing: true
        color: dIconTxt.color
      }
    }

    // Sleek floating pill tooltip on hover so buttons remain uniform circles
    Rectangle {
      id: hoverPill
      visible: dMouse.containsMouse && dBtn.effectiveTooltip !== ""
      z: 100
      height: Style.space(22)
      width: Math.round(hoverPillTxt.implicitWidth + Style.space(14))
      radius: height / 2
      antialiasing: true
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.top
      anchors.bottomMargin: Style.space(6)
      color: "#11141b"
      border.width: 1
      border.color: dBtn.activeColor

      Text {
        id: hoverPillTxt
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: dBtn.effectiveTooltip
        color: root.barFg
        font.family: root.barFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    MouseArea {
      id: dMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: dBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (dBtn.enabled) dBtn.clicked()
    }
  }

  // -------------------------------------------------------------
  // Full-Width Top-Third Overlay PopupCard
  // -------------------------------------------------------------
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    centerOnBar: true
    margin: Style.gapsOut
    padding: Style.space(16)

    // Full width of the screen (inside gapsOut margins) and compact top-third height
    readonly property int targetFullWidth: popup.screenW > 0
      ? Math.max(Style.space(960), Math.round(popup.screenW - popup.margin * 2))
      : Style.space(1800)
    readonly property int targetTopThirdHeight: popup.screenH > 0
      ? Math.max(Style.space(348), Math.round(popup.screenH / 3.0) - Style.space(32))
      : Style.space(488)

    contentWidth: popup.fittedContentWidth(targetFullWidth)
    contentHeight: popup.cappedContentHeight(targetTopThirdHeight)

    Item {
      id: overlayRoot
      anchors.fill: parent
      clip: true
      focus: root.popupOpen

      Keys.onEscapePressed: root.close()
      Keys.onLeftPressed: root.animateShiftToSlot(-1)
      Keys.onRightPressed: root.animateShiftToSlot(1)
      Keys.onSpacePressed: root.doPlayPause()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) {
          root.doToggleLike()
          event.accepted = true
        } else if (event.key === Qt.Key_Minus || event.key === Qt.Key_Underscore) {
          root.doToggleDislike()
          event.accepted = true
        }
      }

      readonly property real stageW: width
      readonly property real stageH: height
      readonly property int topBarH: Math.max(Style.space(32), Math.round(stageH * 0.09))
      readonly property int bottomDeckH: Style.space(98)
      readonly property int carouselAreaH: Math.max(Style.space(180), stageH - topBarH - bottomDeckH - Style.space(6))

      // Ambient radial & equalizer backdrop
      Rectangle {
        anchors.fill: parent
        radius: Math.max(0, Style.cornerRadius - 2)
        gradient: Gradient {
          GradientStop { position: 0.0; color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.09) }
          GradientStop { position: 0.5; color: "transparent" }
          GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.28) }
        }
      }

      // Subtle wide background spectrum across the center stage
      StageSpectrumVisualizer {
        id: backdropSpectrum
        barCount: Math.max(28, Math.min(72, Math.floor(overlayRoot.stageW / Style.space(24))))
        barWidthPx: Style.space(8)
        barSpacingPx: Style.space(10)
        height: Math.round(overlayRoot.carouselAreaH * 0.64)
        maxBarOpacity: 0.14
        anchors.horizontalCenter: parent.horizontalCenter
        y: overlayRoot.topBarH + Math.round((overlayRoot.carouselAreaH - height) * 0.55)
      }

      // =============================================================
      // 1. TOP HEADER BAR (Visualizer + Source Switcher + Queue Status)
      // =============================================================
      Item {
        id: headerBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: overlayRoot.topBarH

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(12)

          Rectangle {
            height: Style.space(28)
            width: headerSpectrum.width + Style.space(20)
            radius: Style.space(14)
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
            border.width: 1
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.35)
            anchors.verticalCenter: parent.verticalCenter

            StageSpectrumVisualizer {
              id: headerSpectrum
              barCount: 16
              barWidthPx: Style.space(3)
              barSpacingPx: Style.space(2)
              height: Style.space(16)
              maxBarOpacity: 0.95
              anchors.centerIn: parent
            }
          }

          Text {
            textFormat: Text.PlainText
            text: root.isPlaying ? "TURNTABLE  ·  NOW SPINNING" : "TURNTABLE  ·  PAUSED"
            color: Color.accent
            font.family: root.barFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            anchors.verticalCenter: parent.verticalCenter
          }

          // YouTube Music Integration Pill
          Rectangle {
            id: ytmHeaderPill
            height: Style.space(24)
            width: ytmHeaderRow.implicitWidth + Style.space(16)
            radius: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            readonly property color ytmColor: Color.flatColor("red") || "#ff4e45"
            color: ytmPillMouse.containsMouse
              ? Qt.rgba(ytmColor.r, ytmColor.g, ytmColor.b, 0.24)
              : Qt.rgba(ytmColor.r, ytmColor.g, ytmColor.b, 0.14)
            border.width: 1
            border.color: Qt.rgba(ytmColor.r, ytmColor.g, ytmColor.b, 0.55)

            Row {
              id: ytmHeaderRow
              anchors.centerIn: parent
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "󰗃"
                color: ytmHeaderPill.ytmColor
                font.family: root.barFontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: root.ytmAvailable ? "YouTube Music" : "Open YT Music"
                color: root.barFg
                font.family: root.barFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              id: ytmPillMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.doOpenYtm()
            }
          }

          Row {
            spacing: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            visible: root.sourcePlayers && root.sourcePlayers.length > 0

            Repeater {
              model: root.sourcePlayers

              Rectangle {
                id: srcPill
                required property var modelData
                readonly property var player: modelData
                readonly property bool selected: root.activePlayer && player
                  && (root.mediaService ? (root.mediaService.playerKey(root.activePlayer) === root.mediaService.playerKey(player)) : (root.activePlayer === player))
                readonly property string label: player ? (player.identity || player.desktopEntry || "Player") : "Player"

                height: Style.space(24)
                width: pillRow.implicitWidth + Style.space(16)
                radius: Style.space(12)
                color: selected
                  ? Style.selectedFillFor(root.barFg, Color.accent)
                  : (pillMouse.containsMouse ? Style.hoverFillFor(root.barFg, Color.accent) : Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.05))
                border.width: 1
                border.color: selected ? Color.accent : Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.18)

                Row {
                  id: pillRow
                  anchors.centerIn: parent
                  spacing: Style.space(5)

                  Text {
                    textFormat: Text.PlainText
                    text: srcPill.player && srcPill.player.isPlaying ? "󰏤" : "󰐊"
                    color: srcPill.selected ? Color.accent : root.barFg
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: srcPill.label
                    color: srcPill.selected ? root.barFg : Qt.darker(root.barFg, 1.25)
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: srcPill.selected
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  id: pillMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.mediaService && srcPill.player) root.mediaService.selectPlayer(root.mediaService.playerKey(srcPill.player))
                }
              }
            }
          }
        }
      }

      // =============================================================
      // 2. CENTER 3D ANGLED QUEUE & FLAT VINYL RECORD STAGE
      //    (5 Previous Angled on Left, Flat Record in Middle, 5 Next Angled on Right)
      // =============================================================
      Item {
        id: carouselStage
        anchors.top: headerBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: overlayRoot.carouselAreaH

        readonly property real centerX: Math.round(width / 2.0)
        readonly property real centerY: Math.round(height / 2.0 - Style.space(12))

        // Generous even-integer sizing across the full-width overlay
        readonly property real recordDiameter: Math.round(Math.max(Style.space(160), Math.min(height * 0.80, width * 0.155)) / 2) * 2
        readonly property real sideCardSize: Math.round(recordDiameter * 0.72 / 2) * 2
        readonly property real centerGap: Math.round(recordDiameter * 1.05)
        readonly property real maxSideSpan: Math.max(Style.space(320), (width * 0.44) - centerGap - Style.space(76))
        readonly property real sideStep: Math.max(Style.space(66), Math.min(Math.round(sideCardSize * 0.96), Math.round(maxSideSpan / 4.0)))

        function offsetToX(eff) {
          var absE = Math.abs(eff)
          if (absE <= 1.0) {
            return eff * centerGap
          }
          var sign = eff < 0 ? -1.0 : 1.0
          return sign * (centerGap + (absE - 1.0) * sideStep)
        }

        // Ambient glow behind center vinyl record
        Rectangle {
          width: carouselStage.recordDiameter * 1.42
          height: width
          radius: width / 2
          x: carouselStage.centerX - width / 2
          y: carouselStage.centerY - height / 2
          color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, root.isPlaying ? 0.16 : 0.07)
          Behavior on color { ColorAnimation { duration: 300 } }
        }

        // Left Stage Change-Track Button (positioned right outside PREV 5)
        DeckButton {
          id: leftStageBtn
          z: 60
          iconText: "󰒮"
          tooltipText: "Previous Track"
          btnSize: Style.space(48)
          x: Math.max(Style.space(8), carouselStage.centerX + carouselStage.offsetToX(-5) - carouselStage.sideCardSize * 0.52 - width - Style.space(14))
          anchors.verticalCenter: parent.verticalCenter
          enabled: root.activePlayer !== null
          onClicked: root.animateShiftToSlot(-1)
        }

        // Right Stage Change-Track Button (positioned right outside NEXT +5)
        DeckButton {
          id: rightStageBtn
          z: 60
          iconText: "󰒭"
          tooltipText: "Next Track"
          btnSize: Style.space(48)
          x: Math.min(parent.width - width - Style.space(8), carouselStage.centerX + carouselStage.offsetToX(5) + carouselStage.sideCardSize * 0.52 + Style.space(14))
          anchors.verticalCenter: parent.verticalCenter
          enabled: root.activePlayer !== null
          onClicked: root.animateShiftToSlot(1)
        }

        // 11 Queue Slots: -5, -4, -3, -2, -1 (Left/Previous), 0 (Center/Current Record), +1, +2, +3, +4, +5 (Right/Next)
        Repeater {
          model: 11

          Item {
            id: slotItem
            required property int index
            readonly property int slotOffset: index - 5
            readonly property real eff: slotOffset + root.carouselShift
            readonly property real absEff: Math.abs(eff)

            // 1.0 when flat in center (eff == 0), 0.0 when at side queue (|eff| >= 1)
            readonly property real centerWeight: Math.max(0.0, Math.min(1.0, 1.0 - absEff))
            readonly property var trackData: root.trackForSlot(slotOffset)
            readonly property string trackTitle: trackData && trackData.title ? String(trackData.title) : ""
            readonly property string trackArtist: trackData && trackData.artist ? String(trackData.artist) : ""
            readonly property string trackAlbum: trackData && trackData.album ? String(trackData.album) : ""
            readonly property string trackArt: trackData && trackData.artUrl ? String(trackData.artUrl) : ""

            readonly property real itemSize: Math.round(carouselStage.sideCardSize + (carouselStage.recordDiameter - carouselStage.sideCardSize) * centerWeight)
            width: itemSize
            height: itemSize + Style.space(48)

            readonly property bool isHoveredSideSlot: slotMouse.containsMouse && slotOffset !== 0
            readonly property real hoverXShift: isHoveredSideSlot && absEff >= 4.2 ? (eff < 0 ? Style.space(22) : -Style.space(22)) : 0

            x: Math.round(carouselStage.centerX + carouselStage.offsetToX(eff) - width / 2 + hoverXShift)
            y: Math.round(carouselStage.centerY - itemSize / 2 + (isHoveredSideSlot ? -Style.space(4) : Math.min(4.0, absEff) * Style.space(3)))
            z: Math.round(30 - absEff * 4) + (slotMouse.containsMouse ? 50 : 0)

            Behavior on x { enabled: slotItem.slotOffset !== 0 && !carouselShiftAnim.running; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on y { enabled: slotItem.slotOffset !== 0 && !carouselShiftAnim.running; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            readonly property real depthScale: {
              if (absEff <= 1.0) return 1.0 - absEff * 0.06
              return Math.max(0.62, 0.94 - (absEff - 1.0) * 0.068)
            }
            // When any side record (-5..-1 or +1..+5) is hovered, grow it to full size (1.04) so even slot 5 is completely readable
            readonly property real targetScale: isHoveredSideSlot ? 1.04 : depthScale

            opacity: {
              if (isHoveredSideSlot || absEff <= 1.0) return 1.0
              return Math.max(0.48, 0.95 - (absEff - 1.0) * 0.10)
            }
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            // ---------------------------------------------------------
            // 3D Angle Calculation:
            // - Center (eff == 0) or Hovered Side Record: 0° (completely FLAT)
            // - Previous on Left (eff < 0): angled inward (+38° to +50° Y-rotation, -5° Z-tilt)
            // - Next on Right (eff > 0): angled inward (-38° to -50° Y-rotation, +5° Z-tilt)
            // ---------------------------------------------------------
            readonly property real yTiltAngle: {
              if (absEff < 0.001) return 0.0
              var sign = eff < 0 ? 1.0 : -1.0
              var baseAngle = 38.0 * Math.min(1.0, absEff)
              var extraAngle = Math.max(0.0, absEff - 1.0) * 3.0
              return sign * (baseAngle + extraAngle)
            }

            readonly property real zTiltAngle: {
              if (absEff < 0.001) return 0.0
              var sign = eff < 0 ? -1.0 : 1.0
              return sign * (5.0 * Math.min(1.0, absEff))
            }

            readonly property bool angledLeft: eff < -0.01
            readonly property bool angledRight: eff > 0.01

            Item {
              id: slotVisuals
              anchors.fill: parent

              transform: [
                Scale {
                  origin.x: slotItem.width / 2
                  origin.y: slotItem.itemSize / 2
                  xScale: slotItem.targetScale
                  yScale: slotItem.targetScale
                  Behavior on xScale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                  Behavior on yScale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                },
                Rotation {
                  origin.x: slotItem.width / 2
                  origin.y: slotItem.itemSize / 2
                  axis { x: 0; y: 1; z: 0 }
                  angle: slotItem.isHoveredSideSlot ? 0.0 : slotItem.yTiltAngle
                  Behavior on angle { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                },
                Rotation {
                  origin.x: slotItem.width / 2
                  origin.y: slotItem.itemSize / 2
                  axis { x: 0; y: 0; z: 1 }
                  angle: slotItem.isHoveredSideSlot ? 0.0 : slotItem.zTiltAngle
                  Behavior on angle { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                }
              ]

            // =========================================================
            // A. SIDE QUEUE CARD (Clean 3D Angled Album Sleeve)
            //    Rendered in a native-resolution 8x-MSAA FBO with a
            //    transparent interior border (`aaPad`) so 3D bilinear
            //    filtering anti-aliases all 4 tilted edges smoothly!
            // =========================================================
            Item {
              id: angledSleeveContainer
              readonly property int aaPad: Style.space(8)
              width: Math.round(slotItem.itemSize + aaPad * 2)
              height: Math.round(slotItem.itemSize + aaPad * 2)
              anchors.top: parent.top
              anchors.topMargin: -aaPad
              anchors.horizontalCenter: parent.horizontalCenter
              opacity: Math.max(0.0, Math.min(1.0, (1.0 - slotItem.centerWeight) * 1.15 - 0.15))
              visible: opacity > 0.01

              layer.enabled: true
              layer.smooth: true
              layer.samples: 8

              // Inset Sleeve Card with 8px transparent padding around all 4 edges
              Item {
                id: sleeveCard
                anchors.fill: parent
                anchors.margins: angledSleeveContainer.aaPad

                Item {
                  id: sideMaskShape
                  anchors.fill: parent
                  visible: false
                  layer.enabled: true
                  layer.smooth: true
                  layer.samples: 8

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.space(10)
                    antialiasing: true
                    color: "white"
                  }
                }

                Item {
                  anchors.fill: parent
                  layer.enabled: true
                  layer.smooth: true
                  layer.samples: 8
                  layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: sideMaskShape
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 0.85
                  }

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.space(10)
                    color: Qt.darker(Color.background, 1.2)
                  }

                  Image {
                    id: sideArtImg
                    anchors.fill: parent
                    source: slotItem.trackArt
                    sourceSize: Qt.size(600, 600)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                    smooth: true
                    mipmap: true
                    visible: source !== "" && status === Image.Ready
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: !sideArtImg.visible
                    text: "󰝚"
                    color: Color.accent
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.displayLarge
                    opacity: 0.55
                  }

                  // 3D directional lighting sheen across the angled cover (fades out when hovered flat)
                  Rectangle {
                    anchors.fill: parent
                    radius: Style.space(10)
                    opacity: slotItem.isHoveredSideSlot ? 0.0 : 1.0
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                    gradient: Gradient {
                      orientation: Gradient.Horizontal
                      GradientStop {
                        position: 0.0
                        color: slotItem.angledLeft
                          ? Qt.rgba(0, 0, 0, 0.34)
                          : Qt.rgba(1, 1, 1, 0.10)
                      }
                      GradientStop {
                        position: 0.5
                        color: "transparent"
                      }
                      GradientStop {
                        position: 1.0
                        color: slotItem.angledLeft
                          ? Qt.rgba(1, 1, 1, 0.10)
                          : Qt.rgba(0, 0, 0, 0.34)
                      }
                    }
                  }
                }

                // Crisp anti-aliased rounded outline
                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(10)
                  antialiasing: true
                  color: "transparent"
                  border.width: slotMouse.containsMouse ? 3 : 2
                  border.color: slotMouse.containsMouse
                    ? Color.accent
                    : Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.55)
                }

                // Queue Offset Pill Badge
                Rectangle {
                  height: Style.space(20)
                  width: Math.round(badgeTxt.implicitWidth + Style.space(12))
                  radius: Style.space(10)
                  antialiasing: true
                  anchors.top: parent.top
                  anchors.topMargin: Style.space(8)
                  anchors.horizontalCenter: parent.horizontalCenter
                  color: slotMouse.containsMouse ? Color.accent : Qt.rgba(0, 0, 0, 0.80)
                  border.width: 1
                  border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.65)

                  Text {
                    id: badgeTxt
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: slotItem.slotOffset < 0
                      ? ("PREV " + Math.abs(slotItem.slotOffset))
                      : ("NEXT +" + slotItem.slotOffset)
                    color: slotMouse.containsMouse ? Color.background : Color.accent
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }
            }

            // =========================================================
            // B. CENTER FLAT VINYL RECORD WITH CURRENT SONG ARTWORK
            //    Native SceneGraph vector rings + 2x supersampled artwork
            // =========================================================
            Item {
              id: centerVinylRecord
              readonly property int recordPad: Style.space(8)
              width: Math.round(slotItem.itemSize + recordPad * 2)
              height: Math.round(slotItem.itemSize + recordPad * 2)
              anchors.top: parent.top
              anchors.topMargin: -recordPad
              anchors.horizontalCenter: parent.horizontalCenter
              opacity: slotItem.centerWeight
              visible: opacity > 0.01

              // Crisp outer halo ring (native vector SceneGraph rectangle)
              Rectangle {
                anchors.fill: parent
                anchors.margins: Style.space(3)
                radius: width / 2
                antialiasing: true
                color: "transparent"
                border.width: 2
                border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)
              }

              Item {
                id: spinningPlatter
                anchors.fill: parent
                anchors.margins: centerVinylRecord.recordPad
                rotation: slotItem.slotOffset === 0 ? root.vinylAngle : 0

                Rectangle {
                  anchors.fill: parent
                  radius: width / 2
                  antialiasing: true
                  color: "#0b0d10"
                  border.width: 2
                  border.color: "#2b313b"
                }

                Rectangle {
                  width: Math.round(parent.width * 0.92)
                  height: Style.space(18)
                  anchors.centerIn: parent
                  rotation: 35
                  color: Qt.rgba(1, 1, 1, 0.045)
                  radius: height / 2
                  antialiasing: true
                }

                Rectangle {
                  width: Math.round(parent.width * 0.92)
                  height: Style.space(14)
                  anchors.centerIn: parent
                  rotation: 125
                  color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.05)
                  radius: height / 2
                  antialiasing: true
                }

                Repeater {
                  model: 7

                  Rectangle {
                    required property int index
                    readonly property real ratio: 0.95 - index * 0.042
                    width: Math.round(spinningPlatter.width * ratio)
                    height: width
                    radius: width / 2
                    antialiasing: true
                    anchors.centerIn: parent
                    color: "transparent"
                    border.width: 1
                    border.color: index % 2 === 0
                      ? Qt.rgba(1, 1, 1, 0.08)
                      : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
                  }
                }

                Item {
                  id: centerArtHolder
                  readonly property int artDiam: Math.round(parent.width * 0.62 / 2) * 2
                  width: artDiam
                  height: artDiam
                  anchors.centerIn: parent

                  Item {
                    id: roundArtMask
                    anchors.fill: parent
                    visible: false
                    layer.enabled: true
                    layer.smooth: true
                    layer.samples: 8

                    Rectangle {
                      anchors.fill: parent
                      radius: width / 2
                      antialiasing: true
                      color: "white"
                    }
                  }

                  Item {
                    anchors.fill: parent
                    layer.enabled: true
                    layer.smooth: true
                    layer.samples: 8
                    layer.effect: MultiEffect {
                      maskEnabled: true
                      maskSource: roundArtMask
                      maskThresholdMin: 0.5
                      maskSpreadAtMin: 0.85
                    }

                    Rectangle {
                      anchors.fill: parent
                      radius: width / 2
                      color: Qt.darker(Color.background, 1.3)
                    }

                    Image {
                      id: centerArtImg
                      anchors.fill: parent
                      source: slotItem.trackArt
                      sourceSize: Qt.size(600, 600)
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      cache: true
                      smooth: true
                      mipmap: true
                      visible: source !== "" && status === Image.Ready
                    }

                    Text {
                      anchors.centerIn: parent
                      visible: !centerArtImg.visible
                      text: "󰝚"
                      color: Color.accent
                      font.family: root.barFontFamily
                      font.pixelSize: Style.font.displayLarge
                    }
                  }
                }
              }

              // Stationary crisp circular label outline & center spindle hole
              Rectangle {
                width: centerArtHolder.artDiam + 2
                height: width
                radius: width / 2
                antialiasing: true
                anchors.centerIn: spinningPlatter
                color: "transparent"
                border.width: 3
                border.color: Color.accent
              }

              Rectangle {
                width: Style.space(22)
                height: width
                radius: width / 2
                antialiasing: true
                anchors.centerIn: spinningPlatter
                color: "#16191f"
                border.width: 2
                border.color: Color.accent

                Rectangle {
                  width: Style.space(8)
                  height: width
                  radius: width / 2
                  antialiasing: true
                  anchors.centerIn: parent
                  color: "#050608"
                }
              }

              // Turntable Tonearm Assembly
              Item {
                id: tonearmPivot
                width: Style.space(28)
                height: Style.space(28)
                x: parent.width - centerVinylRecord.recordPad - Style.space(18)
                y: centerVinylRecord.recordPad + Style.space(6)
                z: 10
                rotation: root.isPlaying ? 22 : 4
                Behavior on rotation { NumberAnimation { duration: 380; easing.type: Easing.InOutCubic } }

                Rectangle {
                  width: Style.space(18)
                  height: Style.space(18)
                  radius: width / 2
                  antialiasing: true
                  anchors.centerIn: parent
                  color: "#222730"
                  border.width: 2
                  border.color: Color.accent
                }

                Rectangle {
                  width: Style.space(3)
                  height: Math.round(spinningPlatter.height * 0.56)
                  x: Math.round(parent.width / 2 - width / 2)
                  y: Math.round(parent.height / 2)
                  radius: 1.5
                  antialiasing: true
                  color: "#d0d6e0"

                  Rectangle {
                    width: Style.space(8)
                    height: Style.space(14)
                    radius: Style.space(2)
                    antialiasing: true
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    rotation: 18
                    color: Color.accent
                  }
                }
              }
            }

            // =========================================================
            // C1. ANGLED TRACK LABEL (Only visible when side card is angled)
            // =========================================================
            Item {
              visible: slotItem.slotOffset !== 0 && !slotItem.isHoveredSideSlot
              width: Math.round(slotItem.itemSize)
              height: angledLabelCol.implicitHeight
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.top: parent.top
              anchors.topMargin: Math.round(slotItem.itemSize + Style.space(6))

              Column {
                id: angledLabelCol
                width: parent.width
                anchors.centerIn: parent
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: slotItem.trackTitle || "Queue Track"
                  color: Qt.darker(root.barFg, 1.18)
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: slotItem.trackArtist
                  color: Qt.darker(root.barFg, 1.50)
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  visible: text !== ""
                }
              }
            }
            }

            // =========================================================
            // C2. CRISP 2D NATIVE-RENDERED LABEL PILL
            //     (Used for the Center Spinning Record & Hovered Side Cards:
            //      Outside 3D/Scale transforms so FreeType renders 1:1 sharp glyphs!)
            // =========================================================
            Rectangle {
              id: flatCrispLabelPill
              visible: slotItem.slotOffset === 0 || slotItem.isHoveredSideSlot
              z: 35
              width: Math.round(slotItem.itemSize * (slotItem.isHoveredSideSlot ? slotItem.targetScale : 1.0))
              height: Math.round(flatLabelCol.implicitHeight + Style.space(10))
              radius: Style.space(8)
              antialiasing: true
              x: Math.round((slotItem.width - width) / 2)
              y: Math.round(slotItem.itemSize / 2 + (slotItem.itemSize * (slotItem.isHoveredSideSlot ? slotItem.targetScale : 1.0)) / 2 + Style.space(6))
              color: Qt.rgba(0.06, 0.07, 0.10, 0.92)
              border.width: 1
              border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.58)

              Column {
                id: flatLabelCol
                width: parent.width - Style.space(12)
                anchors.centerIn: parent
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  renderType: Text.NativeRendering
                  textFormat: Text.PlainText
                  text: slotItem.trackTitle || (slotItem.slotOffset === 0 ? "Nothing playing" : "Queue Track")
                  color: root.barFg
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  renderType: Text.NativeRendering
                  textFormat: Text.PlainText
                  text: slotItem.trackArtist
                  color: Color.accent
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                  visible: text !== ""
                }
              }
            }

            MouseArea {
              id: slotMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              z: 20
              onClicked: {
                if (slotItem.slotOffset === 0) {
                  root.doPlayPause()
                } else {
                  root.animateShiftToSlot(slotItem.slotOffset)
                }
              }
            }
          }
        }
      }

      // =============================================================
      // 3. BOTTOM CONTROL DECK (Metadata + Progress Bar + All Controls)
      // =============================================================
      Item {
        id: bottomDeck
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: overlayRoot.bottomDeckH

        Rectangle {
          anchors.fill: parent
          radius: Style.space(12)
          color: Qt.rgba(0, 0, 0, 0.26)
          border.width: 1
          border.color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.12)
        }

        Column {
          width: parent.width - Style.space(24)
          anchors.centerIn: parent
          spacing: Style.space(8)

          // Row 1: Interactive Progress / Seek Bar with Elapsed & Total Time
          Row {
            id: progressRow
            width: Math.min(parent.width - Style.space(40), Style.space(980))
            height: Style.space(20)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(12)

            Text {
              width: Style.space(46)
              horizontalAlignment: Text.AlignRight
              textFormat: Text.PlainText
                    text: root.formatSeconds(root.isDraggingProgress ? (root.dragProgressRatio * root.trackLength) : root.livePosition)
              color: root.barFg
              font.family: root.barFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Item {
              id: seekBarContainer
              width: progressRow.width - Style.space(120)
              height: Style.space(20)
              anchors.verticalCenter: parent.verticalCenter

              Rectangle {
                id: seekTrack
                width: parent.width
                height: seekMouse.containsMouse || root.isDraggingProgress ? Style.space(8) : Style.space(6)
                radius: height / 2
                antialiasing: true
                anchors.verticalCenter: parent.verticalCenter
                color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.16)
                Behavior on height { NumberAnimation { duration: 120 } }

                Rectangle {
                  width: Math.max(height, parent.width * root.effectiveProgressRatio)
                  height: parent.height
                  radius: height / 2
                  antialiasing: true
                  gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Color.accent }
                    GradientStop { position: 1.0; color: Color.flatColor("cyan") || Qt.lighter(Color.accent, 1.45) }
                  }
                }
              }

              Rectangle {
                id: seekHandle
                width: seekMouse.containsMouse || root.isDraggingProgress ? Style.space(16) : Style.space(12)
                height: width
                radius: width / 2
                antialiasing: true
                anchors.verticalCenter: parent.verticalCenter
                x: Math.max(0, Math.min(parent.width - width, parent.width * root.effectiveProgressRatio - width / 2.0))
                color: Color.flatColor("cyan") || Qt.lighter(Color.accent, 1.5)
                border.width: 2
                border.color: Color.background
                Behavior on width { NumberAnimation { duration: 120 } }
              }

              MouseArea {
                id: seekMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPressed: function(mouse) {
                  root.isDraggingProgress = true
                  root.dragProgressRatio = Math.max(0.0, Math.min(1.0, mouse.x / width))
                }
                onPositionChanged: function(mouse) {
                  if (pressed) {
                    root.dragProgressRatio = Math.max(0.0, Math.min(1.0, mouse.x / width))
                  }
                }
                onReleased: function(mouse) {
                  var ratio = Math.max(0.0, Math.min(1.0, mouse.x / width))
                  root.isDraggingProgress = false
                  root.doSeekRatio(ratio)
                }
                onCanceled: {
                  root.isDraggingProgress = false
                }
              }
            }

            Text {
              width: Style.space(46)
              horizontalAlignment: Text.AlignLeft
              textFormat: Text.PlainText
                    text: root.trackLength > 0 ? root.formatSeconds(root.trackLength) : "--:--"
              color: Qt.darker(root.barFg, 1.35)
              font.family: root.barFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // Row 3: Centrally Aligned Symmetrical Control Deck (5 Left · Play/Pause · 5 Right)
          Item {
            width: parent.width - Style.space(24)
            height: Style.space(54)
            anchors.horizontalCenter: parent.horizontalCenter

            // Symmetrical 11-Button Row Centered Directly Under the Turntable
            Row {
              id: centeredControlsRow
              height: parent.height
              anchors.centerIn: parent
              spacing: Style.space(10)

              DeckButton {
                iconText: "󰒝"
                tooltipText: "Shuffle"
                activeState: (root.activePlayer && root.activePlayer.shuffleSupported && root.activePlayer.shuffle) || root.ytmShuffleActive
                enabled: (root.activePlayer && root.activePlayer.shuffleSupported) || root.ytmAvailable
                onClicked: root.doToggleShuffle()
              }

              DeckButton {
                iconText: "󰒫"
                tooltipText: "-2 Tracks"
                enabled: root.activePlayer !== null
                onClicked: root.animateShiftToSlot(-2)
              }

              DeckButton {
                iconText: "󰒮"
                tooltipText: "Previous Track"
                enabled: root.activePlayer !== null
                onClicked: root.animateShiftToSlot(-1)
              }

              DeckButton {
                iconText: "󰴪"
                tooltipText: "Rewind 10s"
                enabled: root.activePlayer !== null
                onClicked: root.doSeekRelative(-10)
              }

              DeckButton {
                iconText: root.currentRating === "DISLIKE" ? "󰔑" : "󰔒"
                tooltipText: root.currentRating === "DISLIKE" ? "Disliked" : "Dislike"
                activeState: root.currentRating === "DISLIKE"
                activeColor: Color.flatColor("red") || "#f7768e"
                enabled: root.activePlayer !== null
                onClicked: root.doToggleDislike()
              }

              DeckButton {
                primary: true
                iconText: root.isPlaying ? "󰏤" : "󰐊"
                tooltipText: root.isPlaying ? "Pause" : "Play"
                enabled: root.activePlayer !== null
                onClicked: root.doPlayPause()
              }

              DeckButton {
                iconText: root.currentRating === "LIKE" ? "󰔓" : "󰔔"
                tooltipText: root.currentRating === "LIKE" ? "Liked" : "Like"
                activeState: root.currentRating === "LIKE"
                activeColor: Color.flatColor("green") || Color.accent
                enabled: root.activePlayer !== null
                onClicked: root.doToggleLike()
              }

              DeckButton {
                iconText: "󰵱"
                tooltipText: "Forward 10s"
                enabled: root.activePlayer !== null
                onClicked: root.doSeekRelative(10)
              }

              DeckButton {
                iconText: "󰒭"
                tooltipText: "Next Track"
                enabled: root.activePlayer !== null
                onClicked: root.animateShiftToSlot(1)
              }

              DeckButton {
                iconText: "󰒬"
                tooltipText: "+2 Tracks"
                enabled: root.activePlayer !== null
                onClicked: root.animateShiftToSlot(2)
              }

              DeckButton {
                iconText: (root.activePlayer && root.activePlayer.loopState === MprisLoopState.Track) || root.ytmRepeatMode === 2 ? "󰑘" : "󰑖"
                tooltipText: {
                  if (root.activePlayer && root.activePlayer.loopSupported) {
                    if (root.activePlayer.loopState === MprisLoopState.Track) return "Loop 1"
                    if (root.activePlayer.loopState === MprisLoopState.Playlist) return "Loop All"
                    return "Loop"
                  }
                  if (root.ytmRepeatMode === 2) return "Repeat 1"
                  if (root.ytmRepeatMode === 1) return "Repeat All"
                  return "Repeat"
                }
                activeState: (root.activePlayer && root.activePlayer.loopSupported && root.activePlayer.loopState !== MprisLoopState.None) || root.ytmRepeatMode > 0
                enabled: (root.activePlayer && root.activePlayer.loopSupported) || root.ytmAvailable
                onClicked: root.doCycleLoop()
              }
            }
          }
        }
      }
    }
  }
}
