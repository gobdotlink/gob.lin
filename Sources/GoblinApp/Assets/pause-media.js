ObjC.import('Foundation');

// The system automation host can query Now Playing on macOS 26; an app binary cannot.
// Each command is addressed to a resolved player path, never the global transport.
function run() {
    const framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
    if (!framework.load) return 'unavailable';
    const Request = $.NSClassFromString('MRNowPlayingRequest');
    if (Request.isNil()) return 'unavailable';
    ObjC.bindFunction('dispatch_get_global_queue', ['id', ['long', 'unsigned long']]);
    ObjC.bindFunction('MRMediaRemoteRegisterForNowPlayingNotifications', ['void', ['id']]);
    $.MRMediaRemoteRegisterForNowPlayingNotifications($.dispatch_get_global_queue(0, 0));
    let ended = false;
    ObjC.registerSubclass({
        name: 'GoblinMediaEndObserver', superclass: 'NSObject', methods: {
            'inputEnded:': { types: ['void', ['id']], implementation: function () { ended = true; } }
        }
    });
    const input = $.NSFileHandle.fileHandleWithStandardInput;
    const observer = $.GoblinMediaEndObserver.alloc.init;
    const notifications = $.NSNotificationCenter.defaultCenter;
    notifications.addObserverSelectorNameObject(observer, 'inputEnded:', $.NSFileHandleDataAvailableNotification, input);
    input.waitForDataInBackgroundAndNotify;

    function tick() {
        $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));
    }
    function snapshot() {
        const path = Request.localNowPlayingPlayerPath;
        const item = Request.localNowPlayingItem;
        if (path.isNil() || item.isNil() || path.client.processIdentifier <= 0) return null;
        const info = ObjC.deepUnwrap(item.nowPlayingInfo);
        const identity = info.kMRMediaRemoteNowPlayingInfoContentItemIdentifier ||
            info.kMRMediaRemoteNowPlayingInfoUniqueIdentifier ||
            JSON.stringify([info.kMRMediaRemoteNowPlayingInfoTitle, info.kMRMediaRemoteNowPlayingInfoArtist,
                info.kMRMediaRemoteNowPlayingInfoAlbum, info.kMRMediaRemoteNowPlayingInfoDuration]);
        if (!info.kMRMediaRemoteNowPlayingInfoTitle || !Number.isFinite(info.kMRMediaRemoteNowPlayingInfoElapsedTime)) return null;
        const lastPlaying = Request.localLastPlayingDate;
        return { path: path, pid: path.client.processIdentifier, identity: identity, playing: Request.localIsPlaying,
            state: Request.localPlaybackState, elapsed: info.kMRMediaRemoteNowPlayingInfoElapsedTime,
            lastPlaying: lastPlaying.isNil() ? 0 : lastPlaying.timeIntervalSince1970 };
    }
    function samePlayer(a, b) { return b && a.pid === b.pid && a.path.isEqual(b.path) && a.identity === b.identity; }
    function unchangedPause(a, b) {
        // Repeated requests can vary slightly for the timestamp of the same playback transition.
        return samePlayer(a, b) && !b.playing && b.state === 2 &&
            Math.abs(b.lastPlaying - a.lastPlaying) <= 0.01 && Math.abs(b.elapsed - a.elapsed) <= 0.75;
    }
    function send(path, command) {
        const request = Request.alloc.initWithPlayerPath(path);
        request.sendCommandOptionsAppOptionsQueueCompletion(command, $({}), 0, $(), $());
    }

    let paused = null;
    try {
        tick();
        const initial = snapshot();
        if (ended || !initial || !initial.playing) return 'idle';
        const current = snapshot();
        if (!samePlayer(initial, current) || !current.playing || ended) return 'changed';
        send(initial.path, 1);
        const deadline = Date.now() + 2000;
        while (Date.now() < deadline) {
            tick();
            const state = snapshot();
            if (!samePlayer(initial, state)) return 'changed';
            if (!state.playing && state.state === 2) { paused = state; break; }
        }
        if (!paused) return 'pause-unconfirmed';
        while (!ended) {
            tick();
            const state = snapshot();
            if (!unchangedPause(paused, state)) {
                paused = null;
                return 'user-changed-playback';
            }
        }
        return 'finished';
    } finally {
        if (paused) {
            const state = snapshot();
            if (unchangedPause(paused, state)) send(paused.path, 0);
            tick();
        }
        notifications.removeObserver(observer);
    }
}
