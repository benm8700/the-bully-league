/**
 * CLIP LIP-SYNC CORRECTION (2026-11-10).
 *
 * Measured with clap tests on real phones (release builds): in Agora's
 * individual-mode recording, an iPhone's AUDIO lands ~200ms AFTER its video
 * (the hands meet, then the clap is heard), while the Moto (Android) was in
 * sync to within a frame. The renderer aligns every file by the timestamp in
 * its filename, which is correct - the lag is baked into the phone's own
 * capture pipeline, so it has to be corrected per device platform.
 *
 * Each phone reports its platform with completeMatch (stored as
 * match.devicePlatform.{uid}). The renderer then starts that player's audio
 * earlier by the configured lead. The amounts live in config/clipSync so they
 * can be tuned from the console as more phones are measured, without an app
 * or server release. A missing platform means no shift (older clients, or a
 * player who never reached completeMatch) - the clip renders exactly as before.
 *
 * Battlers are always Agora uid "1" (player1) and "2" (player2).
 */

const DEFAULTS = Object.freeze({
  iosAudioLeadMs: 200,
  androidAudioLeadMs: 0,
});

const MAX_LEAD_MS = 1000;

/** Bounds-checks each field; a bad value falls back to its default. */
function resolveClipSync(raw) {
  const out = {...DEFAULTS};
  if (!raw || typeof raw !== "object") return out;
  for (const key of Object.keys(DEFAULTS)) {
    const v = Number(raw[key]);
    if (raw[key] !== undefined && raw[key] !== null &&
        Number.isFinite(v) && v >= 0 && v <= MAX_LEAD_MS) {
      out[key] = Math.round(v);
    }
  }
  return out;
}

/** Only these two values are ever stored. */
function sanitisePlatform(platform) {
  return platform === "ios" || platform === "android" ? platform : null;
}

/**
 * How many ms earlier to start each battler's audio, keyed by Agora uid.
 * Uids with no shift are omitted.
 */
function audioLeadByUid(match, config) {
  const cfg = resolveClipSync(config);
  const platforms = (match && match.devicePlatform) || {};
  const out = {};
  const players = [["1", match && match.player1Id], ["2", match && match.player2Id]];
  for (const [uid, playerId] of players) {
    if (!playerId) continue;
    const p = sanitisePlatform(platforms[playerId]);
    const lead = p === "ios" ? cfg.iosAudioLeadMs :
      p === "android" ? cfg.androidAudioLeadMs : 0;
    if (lead > 0) out[uid] = lead;
  }
  return out;
}

async function loadClipSync(db) {
  try {
    const snap = await db.doc("config/clipSync").get();
    return resolveClipSync(snap.exists ? snap.data() : null);
  } catch (e) {
    console.error("clipSync config read failed:", e.message);
    return {...DEFAULTS};
  }
}

module.exports = {
  DEFAULTS, MAX_LEAD_MS, resolveClipSync, sanitisePlatform, audioLeadByUid,
  loadClipSync,
};
