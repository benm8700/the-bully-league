const {getDatabase} = require("firebase-admin/database");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const {wantsCategory} = require("./notifications");
const {HttpsError} = require("firebase-functions/v2/https");
const {STARTING_RATING, RANK_TIERS, GOAT_TITLE, computeBaseRankTitle} = require("./rating");
const {getMatchSettings} = require("./matchSettings");
const {readEventWindowConfig, qualifiesForWindow} = require("./eventWindow");
const {stopRecording, writeRecordingState} = require("./cloudRecording");

/** CLAUDE.md's recording scope decision: only ranked and tournament
 * matches are recorded and eligible for the highlight pipeline.
 * Exhibition matches are casual, don't move rating, and are never posted,
 * so they're never recorded - which also keeps the per-match recording
 * cost off the mode people play most casually. */
const RECORDED_MODES = ["ranked", "tournament"];

/**
 * How many exhibition matches a player must finish before Ranked unlocks
 * (CLAUDE.md's Modes decision: "unlocked only after completing a few
 * exhibition matches first, exact number TBD, lets new users get
 * comfortable before results count").
 *
 * PLACEHOLDER VALUE - the decision says "a few" and explicitly leaves the
 * number open, so this wants tuning against real data like the rank
 * thresholds do.
 */
const EXHIBITION_MATCHES_TO_UNLOCK_RANKED = 3;

/**
 * Whether Ranked is available to this player yet, and how far off it is.
 *
 * Anyone who has already played a ranked match is grandfathered in
 * regardless of their exhibition count. Without that, introducing this
 * gate would retroactively lock out every existing account - their
 * exhibition counter has never been written, so it reads as zero even for
 * players who have been playing ranked for weeks. Same class of trap as
 * the missing-accountStatus bug this file already carries a fix for.
 */
function rankedUnlockState(user) {
  const played = user?.exhibitionMatchesPlayed ?? 0;
  const alreadyRanked = (user?.rankedMatchesPlayed ?? 0) > 0;
  const unlocked = alreadyRanked || played >= EXHIBITION_MATCHES_TO_UNLOCK_RANKED;
  return {
    unlocked,
    played,
    required: EXHIBITION_MATCHES_TO_UNLOCK_RANKED,
    remaining: unlocked ? 0 : EXHIBITION_MATCHES_TO_UNLOCK_RANKED - played,
  };
}

/**
 * Real matchmaking (Build Order step 4's missing half). Replaces the
 * hardcoded "test-channel" both devices used to join - see CLAUDE.md's
 * Build Order step 4 status note, which flagged "no real matchmaking
 * either" as the main gap.
 *
 * WHERE THE QUEUE LIVES: Firebase Realtime Database, per CLAUDE.md's
 * Matchmaking Queue Architecture decision (Firestore stays the store of
 * record for everything durable; RTDB holds only this ephemeral
 * "who's waiting right now" state).
 *
 * HOW CLIENTS INTERACT: only through the three callables below - clients
 * never read or write the queue directly, and RTDB rules deny all client
 * access to it (database.rules.json). That matters because a queue entry
 * carries the player's real rating and tier: if the client wrote its own
 * entry, a modified client could claim any rating it liked and hand-pick
 * its opponents. Same "sensitive writes go through Cloud Functions"
 * pattern as rating/points per CLAUDE.md's Security & Compliance Baseline.
 *
 * WHY POLLING, NOT AN RTDB LISTENER: the client calls pollMatchmaking on
 * an interval rather than subscribing to its own queue node. Two reasons:
 * (a) the tier-widening rule below is time-based, so *something* has to
 * re-attempt pairing periodically regardless - polling makes that the same
 * mechanism instead of a second one; (b) it keeps firebase_database off
 * the Flutter side entirely, which avoids adding another Android
 * dependency to a toolchain CLAUDE.md documents as fragile (the AGP pin,
 * the permission_handler/image_picker conflicts). The tradeoff is one
 * function invocation per waiting client every few seconds - fine at
 * private-beta volume, and the natural upgrade if that ever gets
 * expensive is an RTDB listener on the client's own node for the
 * *notification*, keeping these callables for the pairing itself.
 */

const MODES = ["exhibition", "ranked"];

/** Every 30s of waiting widens the acceptable tier gap by one, per
 * CLAUDE.md's matchmaking fallback decision ("gradually widen the tier
 * search range further over time... rather than waiting indefinitely or
 * falling back to a truly unrestricted match"). Band 0 = same tier only,
 * band 1 = ±1 tier, and so on - so it starts strict and eventually
 * matches anyone rather than leaving someone queued forever. */
const TIER_WIDEN_INTERVAL_MS = 30 * 1000;

/** CLAUDE.md's repeat-opponent cooldown: 1 day ideal, but "if no other
 * opponent is available, they can still be matched again sooner" -
 * availability takes priority over the cooldown when the pool is small.
 * Implemented as a preference below, not a hard filter. */
const REPEAT_OPPONENT_COOLDOWN_MS = 24 * 60 * 60 * 1000;

/** A client that crashes or is force-killed leaves its entry behind.
 * Anything older than this is treated as abandoned and pruned, so dead
 * entries can't be paired against (which would strand a live player in a
 * match nobody joins). */
const STALE_ENTRY_MS = 10 * 60 * 1000;

/**
 * Position on the 10-rank ladder, used for tier-proximity matchmaking.
 * GOAT sits one above the fixed-threshold ranks since it's a live top-5
 * leaderboard position rather than a threshold (CLAUDE.md's "IMPORTANT
 * EXCEPTION"), so a GOAT is one tier above a Hall of Famer for pairing.
 */
function tierIndexFor(user) {
  if (user.rankTitle === GOAT_TITLE) return RANK_TIERS.length;
  const title = user.rankTitle ??
    computeBaseRankTitle(user.rating ?? STARTING_RATING, user.rankedMatchesPlayed ?? 0);
  const idx = RANK_TIERS.findIndex((t) => t.title === title);
  return idx >= 0 ? idx : 0;
}

function queueRef(mode) {
  return getDatabase().ref(`matchmakingQueue/${mode}`);
}

/**
 * The earlier of the two players' queue-entry times, which is the one the
 * window determination should be judged against. Whoever was waiting first
 * is the one the pairing latency actually cost.
 *
 * Both players always get the same answer, since it's one field on one
 * shared document - a match where one side counted and the other didn't
 * would be indefensible.
 *
 * Pure and exported so the choice is testable without RTDB.
 */
function earliestQueuedAt(pairing) {
  // Only genuine numbers, and only positive ones. Number(null) is 0 and
  // Number("") is 0, both of which are finite - so a coercing filter would
  // let a MISSING opponent time win the Math.min as an epoch timestamp,
  // placing the match in 1970 and silently denying a bonus that was
  // legitimately earned. Caught by a test rather than in production.
  const times = [pairing?.joinedAt, pairing?.opponentJoinedAt]
      .filter((t) => typeof t === "number" && Number.isFinite(t) && t > 0);
  return times.length > 0 ? Math.min(...times) : NaN;
}

/**
 * The prime-time-window determination to stamp on a new match.
 *
 * Best-effort: if the config can't be read, the match proceeds as a
 * non-window match rather than failing the pairing. A missed bonus is a
 * disappointment; a failed pairing is a broken app.
 */
async function resolveEventWindow(pairedAtMs, queuedAtMs) {
  try {
    const snap = await getFirestore().collection("config").doc("eventWindow").get();
    const config = readEventWindowConfig(snap.data());
    const qualified = qualifiesForWindow({
      pairedAtMs,
      queuedAtMs,
      config,
    });
    return {qualified, name: config.name};
  } catch (e) {
    console.error("resolveEventWindow failed:", e.message);
    return {qualified: false, name: null};
  }
}

/**
 * The fixed Agora uid a player joins the match channel with: player1 is
 * always 1, player2 always 2.
 *
 * Clients used to join with the wildcard uid 0 and let Agora assign one
 * dynamically. That has to stop, because the recording layout has to name
 * each player's region by uid and the server has no way of learning a
 * dynamically-assigned one. Confirmed necessary by looking at real output:
 * Agora's "best fit" layout tiles participants side by side regardless of
 * canvas shape, which on a 9:16 canvas gives each player a narrow
 * half-width column instead of the stacked pair short-form video needs.
 *
 * The token is unaffected - it's minted against uid 0, which Agora treats
 * as a wildcard valid for any uid.
 */
const PLAYER1_AGORA_UID = 1;
const PLAYER2_AGORA_UID = 2;

function agoraUidFor(match, uid) {
  if (!match) return null;
  return uid === match.player1Id ? PLAYER1_AGORA_UID : PLAYER2_AGORA_UID;
}

function assertMode(mode) {
  if (!MODES.includes(mode)) {
    throw new HttpsError("invalid-argument", `mode must be one of: ${MODES.join(", ")}`);
  }
}

/**
 * Joins the queue. The entry is built here from the caller's REAL user
 * document rather than from anything the client sent, so rating, tier,
 * and block list can't be spoofed to farm favourable pairings.
 */
async function enterQueue(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const mode = data?.mode;
  assertMode(mode);

  const userSnap = await getFirestore().collection("users").doc(auth.uid).get();
  if (!userSnap.exists) {
    throw new HttpsError("failed-precondition", "No user profile found.");
  }
  const user = userSnap.data();
  // A banned account is already bounced to BannedScreen by the client-side
  // gate, but that gate is a UI convenience - this is the enforcement.
  //
  // An ABSENT accountStatus counts as active, deliberately. Accounts created
  // before Build Order step 9 introduced the field have no value at all, and
  // treating "missing" as "not active" locked those legacy accounts out of
  // matchmaking entirely - found live, with two real pre-step-9 test accounts
  // (PlayerOne/PlayerTwo) refused at the queue while a newer account sailed
  // through. This is the same trap firestore.rules already documents for
  // direct field access on legacy documents, and the same posture the app's
  // own gate takes (lib/app.dart checks `== 'banned'`, not `!= 'active'`):
  // only an explicit non-active value blocks.
  const accountStatus = user.accountStatus ?? "active";
  if (accountStatus !== "active") {
    throw new HttpsError("permission-denied", "This account can't join matches.");
  }

  // Ranked stays locked until a few exhibition matches are done, so a new
  // player's first experiences don't move their rating while they're still
  // working out the format. Enforced here rather than only in the UI - the
  // client's button state is a convenience, this is the actual gate.
  if (mode === "ranked") {
    const unlock = rankedUnlockState(user);
    if (!unlock.unlocked) {
      throw new HttpsError(
          "failed-precondition",
          `Play ${unlock.remaining} more exhibition match` +
        `${unlock.remaining === 1 ? "" : "es"} to unlock Ranked.`,
      );
    }
  }

  // recentOpponentIds is documented in CLAUDE.md's user schema as "[array
  // with timestamps]"; tolerate both a plain array of ids and a map of
  // id -> timestamp, since nothing writes it yet (see completeMatch, which
  // starts populating the map form).
  const recent = user.recentOpponentIds ?? {};

  await queueRef(mode).child(auth.uid).set({
    uid: auth.uid,
    username: user.username ?? "Roaster",
    rating: user.rating ?? STARTING_RATING,
    tierIndex: tierIndexFor(user),
    blockedUserIds: user.blockedUserIds ?? [],
    recentOpponentIds: recent,
    joinedAt: Date.now(),
    status: "waiting",
  });

  return {queued: true, mode};
}

/** Leaves the queue. Safe to call when not queued (idempotent) - the
 * client calls this on cancel, on dispose, and after collecting a match,
 * so it must never throw for an already-absent entry. */
async function leaveQueue(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const mode = data?.mode;
  assertMode(mode);
  await queueRef(mode).child(auth.uid).remove();
  return {left: true};
}

function lastPlayedAgainst(entry, opponentId) {
  const recent = entry.recentOpponentIds;
  if (!recent) return null;
  if (Array.isArray(recent)) return recent.includes(opponentId) ? Infinity : null;
  const ts = recent[opponentId];
  return typeof ts === "number" ? ts : null;
}

function isOnCooldown(a, b, now) {
  const t1 = lastPlayedAgainst(a, b.uid);
  const t2 = lastPlayedAgainst(b, a.uid);
  const mostRecent = Math.max(t1 ?? -Infinity, t2 ?? -Infinity);
  if (mostRecent === -Infinity) return false;
  if (mostRecent === Infinity) return true; // legacy array form: no timestamp, assume recent
  return now - mostRecent < REPEAT_OPPONENT_COOLDOWN_MS;
}

/**
 * The pairing DECISION, kept pure and separate from the transaction that
 * applies it so it can be exercised directly - see
 * test/matchmaking.test.js, which runs it over thousands of randomised
 * queues. That split is deliberate: this repo has already had one
 * matchmaking-adjacent bug (tournament byes) that a local simulation
 * caught before it reached a device, and the rules below - two-way
 * blocking, cooldown-as-preference, time-widening tiers - have exactly
 * the shape where an edge case hides.
 *
 * Mutates `queue` only by deleting stale entries. Returns the chosen
 * opponent, or null when nobody is currently compatible.
 */
function selectOpponent(queue, uid, now) {
  const me = queue[uid];
  if (!me || me.status !== "waiting") return null;

  // Prune abandoned entries in the same pass, so a crashed client's
  // leftover entry can't be paired against.
  for (const [id, entry] of Object.entries(queue)) {
    if (entry.status === "waiting" && now - entry.joinedAt > STALE_ENTRY_MS) {
      delete queue[id];
    }
  }
  // Note: when this call ends up returning null, the transaction aborts
  // and these deletions are discarded along with it. That's intentional -
  // committing on every unsuccessful poll would rewrite the whole queue
  // node constantly. Stale entries are excluded from candidacy on every
  // pass regardless, so leaving them physically present is harmless; they
  // get cleaned up by the next successful pairing, by leaveQueue, or by
  // being overwritten when that user queues again.
  if (!queue[uid]) return null; // our own entry was the stale one

  const band = Math.floor((now - me.joinedAt) / TIER_WIDEN_INTERVAL_MS);
  const myBlocked = me.blockedUserIds ?? [];

  const candidates = Object.values(queue).filter((o) =>
    o.uid !== uid &&
    o.status === "waiting" &&
    Math.abs((o.tierIndex ?? 0) - (me.tierIndex ?? 0)) <= band &&
    // Blocking is checked in BOTH directions - CLAUDE.md's blocking
    // decision is a personal preference tool, and it would be useless
    // if the blocked party could still be served the blocker.
    !myBlocked.includes(o.uid) &&
    !(o.blockedUserIds ?? []).includes(uid),
  );
  if (candidates.length === 0) return null;

  // Cooldown is a PREFERENCE, not a filter: prefer someone we haven't
  // just played, but fall back to a repeat rather than leaving both
  // players stuck when they're the only two in the queue.
  const fresh = candidates.filter((o) => !isOnCooldown(me, o, now));
  const pool = fresh.length > 0 ? fresh : candidates;

  // Closest rating first; ties broken by who has waited longest, so
  // nobody starves while equally-good pairings keep appearing.
  pool.sort((a, b) =>
    Math.abs(a.rating - me.rating) - Math.abs(b.rating - me.rating) ||
    a.joinedAt - b.joinedAt,
  );
  return pool[0];
}

/**
 * Applies a pairing to the queue. Split out alongside selectOpponent so
 * the test suite can drive the exact same mutation the transaction does.
 */
function applyPairing(queue, uid, opponentId, matchId, channelName) {
  queue[uid] = {...queue[uid], status: "matched", matchId, channelName, opponentId};
  queue[opponentId] = {
    ...queue[opponentId],
    status: "matched",
    matchId,
    channelName,
    opponentId: uid,
  };
  return queue;
}

/**
 * The pairing attempt. Runs as a single RTDB transaction over the whole
 * per-mode queue node so that two clients polling at the same instant
 * can't both claim the same opponent: the loser of the race re-runs
 * against the updated queue, sees its own entry already flipped to
 * "matched", and aborts without pairing again.
 *
 * Transacting on the parent node (rather than per-entry) is what makes
 * the two-sided claim atomic - two separate single-entry transactions
 * could interleave into A-claims-B while C-claims-A. The cost is that
 * every attempt reads and rewrites the whole queue for that mode, which
 * is fine at private-beta volume and is the documented scaling limit
 * here; sharding by tier band is the natural fix if it ever matters.
 */
async function attemptPairing(uid, mode, matchId, channelName, now) {
  const result = await queueRef(mode).transaction((queue) => {
    if (!queue) return queue;
    const opponent = selectOpponent(queue, uid, now);
    if (!opponent) return; // abort: not queued, already paired, or nobody compatible
    return applyPairing(queue, uid, opponent.uid, matchId, channelName);
  });

  if (!result.committed) return null;
  const queue = result.snapshot.val();
  const mine = queue?.[uid];
  // Only report a pairing if THIS attempt is the one that created it -
  // a commit that merely pruned stale entries also counts as committed.
  if (!mine || mine.status !== "matched" || mine.matchId !== matchId) return null;
  // Carried out so the prime-time-window determination can use the EARLIER
  // of the two players' queue times - see resolveEventWindow.
  return {...mine, opponentJoinedAt: queue?.[mine.opponentId]?.joinedAt ?? null};
}

/**
 * Tells a player they've been paired, via push.
 *
 * This exists because of how pairing is discovered: the client finds its
 * match by polling, and those timers stall once the app is backgrounded.
 * Whoever's poll made the pairing is demonstrably in the foreground and
 * already knows - it's the OTHER player who may have queued and switched
 * away, and without this they'd sit in a stalled queue entry indefinitely.
 * Their entry stays flagged "matched" server-side until collected, so
 * returning to the app at any point still lands them in the right match.
 *
 * Entirely best-effort: a failed send must never fail the pairing itself,
 * which has already been committed by the time this runs.
 */
async function notifyMatchFound(opponentId, matchId, fromUsername) {
  try {
    const db = getFirestore();
    const snap = await db.collection("users").doc(opponentId).get();
    const tokens = snap.data()?.fcmTokens ?? [];
    if (tokens.length === 0) return;
    // Honour the per-category mute toggle. Match-found is the most useful
    // notification in the app, but forcing it on someone who switched it
    // off is how an app earns a system-level block - which silences every
    // other category too.
    if (!wantsCategory(snap.data(), "match_found")) return;

    const response = await getMessaging().sendEachForMulticast({
      tokens,
      notification: {
        title: "Opponent found",
        body: `${fromUsername || "Someone"} is ready to battle. Tap to start.`,
      },
      // The category is in the payload so that per-category mute settings
      // (CLAUDE.md decides on those, they aren't built) can be honoured
      // here later without changing the client's message handling.
      data: {category: "match_found", matchId},
      android: {priority: "high"},
    });

    // FCM reports permanently-dead tokens (app uninstalled, token rotated
    // on another device). Left in place they accumulate forever and every
    // future send wastes work on them, so prune as we learn about them.
    const dead = [];
    response.responses.forEach((r, i) => {
      const code = r.error?.code;
      if (code === "messaging/registration-token-not-registered" ||
          code === "messaging/invalid-registration-token") {
        dead.push(tokens[i]);
      }
    });
    if (dead.length > 0) {
      await db.collection("users").doc(opponentId)
          .update({fcmTokens: FieldValue.arrayRemove(...dead)});
    }
  } catch (e) {
    console.error(`match-found push to ${opponentId} failed:`, e.message);
  }
}

/**
 * Called on an interval by a waiting client. Returns either the match it
 * has been paired into (whether this call made the pairing or the
 * opponent's poll did) or a "still searching" status carrying enough
 * information for the UI to explain what's happening.
 */
async function pollMatchmaking(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const mode = data?.mode;
  assertMode(mode);
  const uid = auth.uid;
  const db = getFirestore();

  const snap = await queueRef(mode).child(uid).get();
  const entry = snap.val();
  if (!entry) return {status: "not_queued"};

  // The opponent's poll may have already paired us. Settings come from the
  // match document rather than being re-resolved, so this side runs exactly
  // what was stamped when the pairing was made - re-reading config here
  // could hand the two players different numbers if it changed in between.
  if (entry.status === "matched") {
    const matchSnap = await db.collection("matches").doc(entry.matchId).get();
    const m = matchSnap.data();
    return {
      status: "matched",
      matchId: entry.matchId,
      channelName: entry.channelName,
      opponentId: entry.opponentId,
      mode,
      settings: m?.settings ?? null,
      agoraUid: agoraUidFor(m, uid),
    };
  }

  const now = Date.now();
  // Reserve the id before the transaction so both entries can carry it,
  // then only write the Firestore document if the pairing actually
  // committed. .doc() allocates an id client-side without a round trip.
  const matchRef = db.collection("matches").doc();
  const channelName = `match_${matchRef.id}`;

  const paired = await attemptPairing(uid, mode, matchRef.id, channelName, now);
  if (!paired) {
    return {
      status: "searching",
      waitedMs: now - entry.joinedAt,
      tierBand: Math.floor((now - entry.joinedAt) / TIER_WIDEN_INTERVAL_MS),
    };
  }

  // Resolved once, here, and stamped onto the match document - so both
  // players run identical timings for this match regardless of when
  // either device last read config. See functions/matchSettings.js.
  const settings = await getMatchSettings(mode);

  // Whether this counts as a prime-time-window match, decided ONCE here and
  // stamped on the document.
  //
  // Judged at the START of the match, never the end: a battle that kicks
  // off at 6:58 and runs past 7:00 qualifies in full. Judging on completion
  // would penalise a long match and, far worse, give players a reason to
  // rush or bail out to beat the clock - the exact opposite of what an hour
  // designed to get people battling should encourage.
  //
  // Stamped rather than recomputed later for the same reason match settings
  // and vote confidence are: the hours are hand-editable in the console, and
  // a match must be judged by the rules in force when it was played, not by
  // whatever the config says afterwards. It also means the answer survives
  // the window being renamed, retimed, or switched off entirely.
  const eventWindow = await resolveEventWindow(now, earliestQueuedAt(paired));

  try {
    await matchRef.set({
      player1Id: uid,
      player2Id: paired.opponentId,
      mode,
      settings,
      eventWindow,
      // Created at PAIRING time now, not at verdict time - the document is
      // what the two clients agree on (channel name, who the opponent is),
      // so it has to exist before the match rather than after it. Anything
      // downstream that only wants finished matches filters on this status:
      // see finalizeMatch, castVote, and the website feed.
      status: "pending",
      channelName,
      createdAt: FieldValue.serverTimestamp(),
      completedAt: null,
      voteFinalized: false,
      winnerId: null,
      voteCount: 0,
    });
  } catch (e) {
    // Both players are flagged "matched" against a match document that
    // doesn't exist - put them back in the queue rather than stranding
    // them on a channel with no match behind it.
    await Promise.all([
      queueRef(mode).child(uid).update({status: "waiting", matchId: null, channelName: null, opponentId: null}),
      queueRef(mode).child(paired.opponentId).update({status: "waiting", matchId: null, channelName: null, opponentId: null}),
    ]).catch(() => {});
    throw new HttpsError("internal", `Could not create the match: ${e.message}`);
  }

  // Awaited so the function doesn't return (and the instance potentially
  // freeze) mid-send, but it can never fail the call - see notifyMatchFound.
  await notifyMatchFound(paired.opponentId, matchRef.id, entry.username);

  return {
    status: "matched",
    matchId: matchRef.id,
    channelName,
    opponentId: paired.opponentId,
    mode,
    settings,
    // This caller created the match, so it is player1 by construction.
    agoraUid: PLAYER1_AGORA_UID,
  };
}

/**
 * Starts recording a match, called once by the host device as the match
 * actually begins (host election requires both players to be in the
 * channel, so this is the first moment there's anything worth recording).
 *
 * Recording only ever covers ranked and tournament matches, per
 * CLAUDE.md's recording scope decision - exhibition matches return
 * `skipped` rather than an error, since not recording them is correct
 * behaviour rather than a failure.
 *
 * Never throws for a recording problem. Two people are about to play a
 * match; losing the footage is bad, but blocking the match on a recording
 * vendor being unreachable is much worse.
 */
async function startMatchRecording(auth, data, creds) {
  const {matchRef, match} = await loadPendingMatch(auth, data?.matchId);
  const matchId = data.matchId;

  if (!RECORDED_MODES.includes(match.mode)) {
    return {started: false, reason: "mode-not-recorded"};
  }
  if (match.recording?.status === "recording") {
    // The other device raced us, or this is a retry. Not an error.
    return {started: false, reason: "already-recording"};
  }
  const {startRecording, isRecordingConfigured} = require("./cloudRecording");
  if (!isRecordingConfigured(creds)) {
    // Expected while the Agora RESTful credentials are still being set
    // up. Recorded on the document so it's visible that a match went
    // unrecorded for this reason rather than a failure.
    await writeRecordingState(matchId, {status: "unconfigured"});
    return {started: false, reason: "not-configured"};
  }

  const result = await startRecording(matchId, match.channelName, creds);
  if (!result.ok) {
    await writeRecordingState(matchId, {status: "start_failed", error: result.error});
    return {started: false, reason: "start-failed"};
  }

  await matchRef.set({
    recording: {
      status: "recording",
      resourceId: result.resourceId,
      sid: result.sid,
      startedAt: result.startedAt,
      // The human gate CLAUDE.md requires before anything is posted
      // publicly - covering both "is this fit for a public audience" and
      // the separate question of whether it would trip TikTok/Instagram/
      // YouTube's own rules, which are stricter than this app's internal
      // speech policy. Nothing in this pipeline publishes on its own.
      reviewStatus: "pending",
      published: false,
    },
  }, {merge: true});

  return {started: true};
}

/**
 * Finds a match the caller was paired into but never actually collected.
 *
 * This closes a real hole opened by the match-found push. A player can be
 * paired while the app is backgrounded, tap the notification (or just
 * reopen the app later) and — if the process had been killed in between —
 * land on Home with no route back: their queue entry is flagged "matched",
 * the match document is sitting there "pending", and nothing in the UI was
 * looking for either. Matched entries are deliberately never touched by
 * the stale-entry pruning, which is what makes them recoverable here.
 *
 * Checks every mode because the caller's own client no longer knows which
 * queue it was in after a cold start. Also self-heals: if the match has
 * since ended (the opponent skipped, or the sweep abandoned it), the dead
 * queue entry is cleared instead of being handed back.
 */
async function getActiveMatch(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();

  for (const mode of MODES) {
    const entry = (await queueRef(mode).child(auth.uid).get()).val();
    if (!entry || entry.status !== "matched" || !entry.matchId) continue;

    const snap = await db.collection("matches").doc(entry.matchId).get();
    if (!snap.exists || snap.data().status !== "pending") {
      await queueRef(mode).child(auth.uid).remove();
      continue;
    }

    return {
      found: true,
      matchId: entry.matchId,
      channelName: entry.channelName,
      opponentId: entry.opponentId,
      mode,
      settings: snap.data().settings ?? null,
      agoraUid: agoraUidFor(snap.data(), auth.uid),
    };
  }

  return {found: false};
}

/**
 * Marks a paired match finished. Server-side so a client can't mark a
 * match it isn't in as complete (which would push it into the voting
 * pipeline and, for ranked, eventually into real rating changes).
 *
 * outcome "abandoned" is used when the match ended without a real
 * contest - currently the live content-violation auto-end (Build Order
 * step 9a). Those are finalized immediately with no winner so the hourly
 * rating sweep never reconsiders them, matching the previous behaviour
 * where a violation-ended match was simply never written at all.
 */
async function completeMatch(auth, data, creds = null) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {matchId, outcome = "completed"} = data || {};
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  if (!["completed", "abandoned"].includes(outcome)) {
    throw new HttpsError("invalid-argument", "outcome must be 'completed' or 'abandoned'.");
  }

  const db = getFirestore();
  const matchRef = db.collection("matches").doc(matchId);
  const matchSnap = await matchRef.get();
  if (!matchSnap.exists) throw new HttpsError("not-found", "Match not found.");
  const match = matchSnap.data();

  if (auth.uid !== match.player1Id && auth.uid !== match.player2Id) {
    throw new HttpsError("permission-denied", "Only a participant can complete this match.");
  }

  // Claim the settle in a TRANSACTION, not a read-then-write. Both
  // clients call this when they reach the verdict, and a plain check
  // let both pass it before either wrote - so both went on to stop the
  // recording. One stop succeeded and one came back with Agora's "not
  // recording" error, and the loser's error overwrote the winner's file
  // list. Found on a real two-device match; the footage was fine but the
  // record of it wasn't.
  const claimed = await db.runTransaction(async (tx) => {
    const fresh = await tx.get(matchRef);
    if (fresh.data().status !== "pending") return false;
    tx.update(matchRef, {
      status: outcome,
      completedAt: FieldValue.serverTimestamp(),
      ...(outcome === "abandoned" ? {voteFinalized: true} : {}),
    });
    return true;
  });

  if (!claimed) {
    const current = (await matchRef.get()).data();
    return {status: current.status, alreadySettled: true};
  }

  // Stop the recording if one is running. Deliberately after the status
  // write, so a slow or failing Agora call can't leave the match stuck
  // "pending" - the match being settled matters more than the footage.
  // Agora's own maxIdleTime also stops the recording once both players
  // leave, so a failure here costs the file list, not the recording.
  const handle = match.recording;
  if (creds && handle?.resourceId && handle?.sid && handle.status === "recording") {
    const result = await stopRecording(matchId, match.channelName, handle, creds);
    await writeRecordingState(matchId, result.ok ?
      {status: "recorded", files: result.files, stoppedAt: Date.now()} :
      {status: "stop_failed", error: result.error});
  }

  if (outcome === "completed") {
    // Feeds the repeat-opponent cooldown on the next queue entry, and -
    // for exhibition matches - the counter that unlocks Ranked. Counted
    // on completion rather than on pairing so abandoning a match cannot
    // be used to speed-run the unlock.
    const now = Date.now();
    const countsTowardUnlock = match.mode === "exhibition";
    await Promise.all([match.player1Id, match.player2Id].map((uid, i) => {
      const opponent = i === 0 ? match.player2Id : match.player1Id;
      return db.collection("users").doc(uid).update({
        [`recentOpponentIds.${opponent}`]: now,
        ...(countsTowardUnlock ?
          {exhibitionMatchesPlayed: FieldValue.increment(1)} : {}),
      }).catch(() => {});
    }));
  }

  return {status: outcome};
}

/**
 * CLAUDE.md's skip/decline decision allows "2-3 skips per day" - enough of
 * an escape hatch for a genuinely bad pairing, few enough that nobody can
 * cherry-pick easy opponents all evening.
 */
const MAX_SKIPS_PER_DAY = 3;

/** UTC calendar day, used to reset the daily skip allowance. Deliberately
 * UTC rather than the player's local midnight: it needs to agree between
 * the server and every device, and a per-user timezone isn't stored. The
 * practical effect is that the allowance resets at 5pm Pacific rather than
 * local midnight - fine for V1, worth revisiting if players notice. */
function utcDayKey(nowMs) {
  return new Date(nowMs).toISOString().slice(0, 10);
}

async function loadPendingMatch(auth, matchId) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  const matchRef = getFirestore().collection("matches").doc(matchId);
  const snap = await matchRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "Match not found.");
  const match = snap.data();
  if (auth.uid !== match.player1Id && auth.uid !== match.player2Id) {
    throw new HttpsError("permission-denied", "Not a participant in this match.");
  }
  return {matchRef, match};
}

/**
 * Marks the caller ready during the pre-match bio reveal. Both clients
 * watch the match document, so this is how each learns the other is done
 * reading - the bio reveal ends as soon as both are ready, or when its
 * timer runs out, per CLAUDE.md ("up to 1 minute OR until both players tap
 * ready, whichever comes first").
 *
 * Server-side rather than a direct client write because clients can't
 * write the matches collection at all (firestore.rules), and because
 * readiness has to be attributable - a client shouldn't be able to mark
 * its opponent ready.
 */
async function setMatchReady(auth, data) {
  const {matchRef, match} = await loadPendingMatch(auth, data?.matchId);
  if (match.status !== "pending") {
    return {status: match.status, ready: match.readyPlayerIds ?? []};
  }
  await matchRef.update({readyPlayerIds: FieldValue.arrayUnion(auth.uid)});
  const after = (await matchRef.get()).data();
  return {status: "pending", ready: after.readyPlayerIds ?? []};
}

/**
 * Declines a proposed match after seeing the opponent's bio (CLAUDE.md's
 * skip/decline decision). Spends one of the caller's daily skips, settles
 * the match as abandoned so it never reaches voting or rating, and lets
 * the other player find out via their own listener on the document.
 *
 * The counter lives server-side and is protected in firestore.rules for
 * the same reason rating is: a client that could reset its own
 * skipsUsedToday would have unlimited skips, which defeats the entire
 * point of the limit (cherry-picking easy opponents).
 */
async function skipMatch(auth, data) {
  const {matchRef, match} = await loadPendingMatch(auth, data?.matchId);
  if (match.status !== "pending") {
    throw new HttpsError("failed-precondition", "This match can no longer be skipped.");
  }

  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);
  const now = Date.now();
  const today = utcDayKey(now);

  // Transaction so two rapid skips can't both read the same count and
  // each write count+1, spending only one of the allowance.
  const remaining = await db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const user = snap.data() ?? {};
    const sameDay = user.skipsResetDate === today;
    const used = sameDay ? (user.skipsUsedToday ?? 0) : 0;
    if (used >= MAX_SKIPS_PER_DAY) {
      throw new HttpsError(
          "resource-exhausted",
          `You've used all ${MAX_SKIPS_PER_DAY} of today's skips.`,
      );
    }
    tx.update(userRef, {skipsUsedToday: used + 1, skipsResetDate: today});
    return MAX_SKIPS_PER_DAY - (used + 1);
  });

  await matchRef.update({
    status: "abandoned",
    // Settled immediately so the hourly rating sweep never reconsiders it,
    // and so neither player takes a result from a match nobody played.
    voteFinalized: true,
    completedAt: FieldValue.serverTimestamp(),
    skippedByUserId: auth.uid,
  });

  return {skipped: true, skipsRemaining: remaining};
}

/** Read-only: how many skips the caller has left today, so the UI can show
 * it before they spend one (and hide the button at zero). */
async function getSkipAllowance(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const snap = await getFirestore().collection("users").doc(auth.uid).get();
  const user = snap.data() ?? {};
  const used = user.skipsResetDate === utcDayKey(Date.now()) ? (user.skipsUsedToday ?? 0) : 0;
  return {remaining: Math.max(0, MAX_SKIPS_PER_DAY - used), max: MAX_SKIPS_PER_DAY};
}

/**
 * Read-only: whether Ranked is unlocked for the caller and how far off it
 * is, so Home can show real progress ("2 matches until Ranked unlocks")
 * rather than a silent unlock - CLAUDE.md explicitly asks for the progress
 * to be visible.
 */
async function getRankedUnlock(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const snap = await getFirestore().collection("users").doc(auth.uid).get();
  return rankedUnlockState(snap.data() ?? {});
}

module.exports = {
  enterQueue,
  leaveQueue,
  pollMatchmaking,
  completeMatch,
  startMatchRecording,
  getActiveMatch,
  RECORDED_MODES,
  // Every queue that exists, so the online-count publisher (presence.js)
  // sweeps exactly the same set of modes matchmaking uses rather than
  // keeping its own list that could silently drift out of step.
  MODES,
  setMatchReady,
  skipMatch,
  getSkipAllowance,
  getRankedUnlock,
  rankedUnlockState,
  EXHIBITION_MATCHES_TO_UNLOCK_RANKED,
  utcDayKey,
  MAX_SKIPS_PER_DAY,
  tierIndexFor,
  // Exported for test/matchmaking.test.js - the pairing rules are the part
  // worth exercising directly, independently of RTDB.
  selectOpponent,
  applyPairing,
  isOnCooldown,
  TIER_WIDEN_INTERVAL_MS,
  REPEAT_OPPONENT_COOLDOWN_MS,
  STALE_ENTRY_MS,
  earliestQueuedAt,
};
