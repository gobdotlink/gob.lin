import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

// Exercise the shipped helper's ownership decisions, without controlling user playback.
const source = fs.readFileSync('Sources/GoblinApp/Assets/pause-media.js', 'utf8');
function scenario({ playing = true, endAt = 700, change, pauseDelay = 0, rejectPause = false, title = 'Fixture' } = {}) {
  let clock = 0, observer, sent = [], pausedAt;
  const path = { isNil: () => false, isLocal: true, client: { processIdentifier: 10 }, isEqual(other) { return this === other; } };
  const state = { path, playing, state: playing ? 1 : 2, identity: 'fixture-1', uniqueID: 'unique-1',
    elapsed: 4, lastPlaying: 1, title, artist: 'Artist', album: 'Album', duration: 120 };
  const request = {
    isNil: () => false,
    get localNowPlayingPlayerPath() { return state.path; },
    get localNowPlayingItem() { return { isNil: () => false, nowPlayingInfo: {
      kMRMediaRemoteNowPlayingInfoTitle: state.title,
      kMRMediaRemoteNowPlayingInfoArtist: state.artist,
      kMRMediaRemoteNowPlayingInfoAlbum: state.album,
      kMRMediaRemoteNowPlayingInfoDuration: state.duration,
      kMRMediaRemoteNowPlayingInfoContentItemIdentifier: state.identity,
      kMRMediaRemoteNowPlayingInfoUniqueIdentifier: state.uniqueID,
      kMRMediaRemoteNowPlayingInfoElapsedTime: state.elapsed,
    } }; },
    get localIsPlaying() { return state.playing; },
    get localPlaybackState() { return state.state; },
    get localLastPlayingDate() { return { isNil: () => false, timeIntervalSince1970: state.lastPlaying }; },
    alloc: { initWithPlayerPath(target) { return { sendCommandOptionsAppOptionsQueueCompletion(command) {
      sent.push({ command, target });
      if (command === 1) { pausedAt = clock + pauseDelay; }
      else { state.playing = true; state.state = 1; }
    } }; } },
  };
  const $ = Object.assign(x => x, {
    NSBundle: { bundleWithPath: () => ({ load: true }) },
    NSClassFromString: () => request,
    dispatch_get_global_queue: () => ({}),
    MRMediaRemoteRegisterForNowPlayingNotifications() {},
    GoblinMediaEndObserver: { alloc: { init: {} } },
    NSFileHandle: { fileHandleWithStandardInput: { waitForDataInBackgroundAndNotify: true } },
    NSNotificationCenter: { defaultCenter: { addObserverSelectorNameObject() {}, removeObserver() {} } },
    NSDate: { dateWithTimeIntervalSinceNow: () => 100 },
    NSRunLoop: { currentRunLoop: { runUntilDate() {
      clock += 100;
      if (pausedAt !== undefined && clock >= pausedAt && !rejectPause) { state.playing = false; state.state = 2; pausedAt = undefined; }
      change?.(state, clock, path);
      if (clock >= endAt) observer();
      assert(clock < 5000, 'Helper must settle bounded confirmation and EOF');
    } } },
  });
  const context = vm.createContext({ $, Date: { now: () => clock }, ObjC: {
    import() {}, bindFunction() {}, deepUnwrap: x => x,
    registerSubclass(definition) { observer = definition.methods['inputEnded:'].implementation; },
  } });
  const result = vm.runInContext(source + '\nrun()', context);
  assert(sent.every(command => command.target === path), 'Commands must retain the exact original target');
  return { commands: sent.map(x => x.command), result };
}

assert.deepEqual(scenario().commands, [1, 0]);
assert.deepEqual(scenario({ playing: false }).commands, []);
assert.deepEqual(scenario({ endAt: 0 }).commands, []);
assert.deepEqual(scenario({ title: '' }).commands, []);
assert.deepEqual(scenario({ rejectPause: true }).commands, [1]);
assert.deepEqual(scenario({ endAt: 200, pauseDelay: 400 }).commands, [1, 0]);
// The same item can acquire new system IDs on pause and later metadata refreshes.
for (const changeAt of [200, 400, 700]) {
  for (const contentIDPresent of [true, false]) {
    assert.deepEqual(scenario({ change: (state, clock) => {
      if (!contentIDPresent) state.identity = undefined;
      if (clock >= changeAt) {
        if (contentIDPresent) state.identity = `content-${clock}`;
        state.uniqueID = `unique-${clock}`;
      }
    } }), { commands: [1, 0], result: 'finished' });
  }
}
for (const field of ['title', 'artist', 'album', 'duration']) {
  for (const changeAt of [200, 400]) {
    assert.deepEqual(scenario({ change: (state, clock) => {
      if (clock === changeAt) state[field] = field === 'duration' ? 240 : 'Different';
    } }).commands, [1], `${field} change must prevent resuming`);
  }
}
for (const change of [
  s => { s.playing = true; s.state = 1; },
  s => { s.state = 3; },
  s => { s.lastPlaying += 1; },
  s => { s.elapsed = 9; },
  s => { s.path.client = { processIdentifier: 11 }; },
  s => { s.path = { ...s.path, isEqual: () => false }; },
]) {
  assert.deepEqual(scenario({ change: (state, clock) => { if (clock === 400) change(state); } }).commands, [1]);
}
console.log('Media ownership checks passed: explicit targeted pause/play, refreshed system IDs, idle/EOF guards, delayed confirmation cleanup, failed pause, user playback, stop, seek, item and target switch.');
