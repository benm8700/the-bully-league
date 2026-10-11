const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {isSubscriber, isInTrial, readMonetizationConfig} = require("./entitlement");

/**
 * Match ABILITIES (power-ups) for the regular/qualifier mode - a paid, fun edge
 * layer that drives subscriptions and the points economy. Developer's design
 * (2026-10-11):
 *   - ONLY in regular/qualifier play, NEVER in the Main Stage finals (those stay
 *     pure skill).
 *   - Every ability only DISRUPTS or DEFENDS (throws the opponent off / protects
 *     you) - never adds score - and both players can buy the same things, so it
 *     stays fair-enough while being a real monetization surface.
 *   - Hybrid acquisition: subscribers get a small FREE allowance per match;
 *     anyone can BUY more with points. Committed PRE-match (a loadout on the
 *     ready-up screen); tapped to deploy in-match.
 *
 * THIS LAYER IS THE ECONOMY ONLY and is FORMAT-INDEPENDENT. The catalog's
 * economy (cost / free allowance / cap / enabled) is live config
 * (config/abilities, bounds-checked, PLACEHOLDER numbers for the advisor
 * review). Each ability's in-match EFFECT is applied client/match-side and is
 * format-specific (see the round-times note) - add it there, not here.
 *
 * Points are spent exactly like the day pass / clip grant / emoji scrub:
 * pointsBalance (spendable, never the career total) + an idempotent ledger
 * entry. The per-match loadout is server-only and each player sees only THEIR
 * own (the opponent's is a surprise).
 */

// The catalog. `deploy` says WHERE the ability is used, so the client knows
// which surface shows it: "controls" = the chess-clock Interrupt button;
// "bar" = the mid-match tap-to-deploy bar (tomato/extend); "prematch" = decided
// at battle start from the loadout (go-first), never tapped mid-match. Adding a
// new entry here (plus a DEFAULTS row) wires it through the whole economy -
// resolveAbilityConfig / boughtOf / getLoadout all iterate the catalog.
const ABILITY_CATALOG = {
  interrupt: {
    id: "interrupt",
    name: "Interrupt",
    description:
      "Cut into your opponent while they hold the floor and steal it.",
    deploy: "controls",
  },
  tomato: {
    id: "tomato",
    name: "Tomato",
    description: "Splat a tomato across your opponent's screen to rattle them.",
    deploy: "bar",
  },
  extend: {
    id: "extend",
    name: "+5 Seconds",
    description:
      "Add 5 seconds to your clock - even to buy time against an interrupt.",
    deploy: "bar",
  },
  goFirst: {
    id: "goFirst",
    name: "Go First",
    description: "Take the floor first. If you both bring it, it's a coin flip.",
    deploy: "prematch",
  },
};

// Per-ability economy defaults, overridable per field from config/abilities.
// PLACEHOLDERS (advisor review): interrupt is the priciest (biggest edge);
// go-first is capped at one (you either lead or you don't).
const DEFAULTS = {
  interrupt: {cost: 500, subFree: 1, maxPerMatch: 3, enabled: true},
  tomato: {cost: 150, subFree: 2, maxPerMatch: 5, enabled: true},
  extend: {cost: 250, subFree: 1, maxPerMatch: 3, enabled: true},
  goFirst: {cost: 300, subFree: 1, maxPerMatch: 1, enabled: true},
};
const ABILITY_FALLBACK = {cost: 500, subFree: 0, maxPerMatch: 3, enabled: true};

function clampInt(v, min, max, fallback) {
  const n = Math.floor(Number(v));
  return Number.isFinite(n) && n >= min && n <= max ? n : fallback;
}

/** Merge config/abilities over DEFAULTS, bounds-checked per field. Pure. */
function resolveAbilityConfig(doc) {
  const d = doc || {};
  const out = {enabled: d.enabled !== false};
  for (const id of Object.keys(ABILITY_CATALOG)) {
    const base = DEFAULTS[id] || ABILITY_FALLBACK;
    const cfg = (d[id] && typeof d[id] === "object") ? d[id] : {};
    out[id] = {
      cost: clampInt(cfg.cost, 0, 100000, base.cost),
      subFree: clampInt(cfg.subFree, 0, 10, base.subFree),
      maxPerMatch: clampInt(cfg.maxPerMatch, 0, 20, base.maxPerMatch),
      enabled: cfg.enabled !== undefined ? cfg.enabled !== false : base.enabled,
    };
  }
  return out;
}

async function abilityConfig(db = getFirestore()) {
  const snap = await db.collection("config").doc("abilities").get();
  return resolveAbilityConfig(snap.data());
}

/** Spendable balance - a legacy account with no balance field inherits its
 * career total (reading a missing balance as zero would confiscate everything
 * earned before spending existed). Matches dayPass/clipGrants/emojiScrub. */
function spendableBalance(user) {
  const raw = Number(user && user.pointsBalance);
  return Number.isFinite(raw) ?
    Math.max(0, raw) : Math.max(0, Number((user && user.points) || 0));
}

/** The FREE per-match allowance for an ability (a subscriber/trial perk). */
function freeAllowance(user, nowMs, abilityCfg, trialDays) {
  const entitled = isSubscriber(user, nowMs) || isInTrial(user, nowMs, trialDays);
  return entitled ? abilityCfg.subFree : 0;
}

/**
 * PURE. Whether one more of an ability can be bought, and the cost. Clamped by
 * the per-match cap (free + bought) and the balance.
 */
function purchasePlan({free, bought, maxPerMatch, cost, balance}) {
  const total = Math.max(0, free) + Math.max(0, bought);
  if (total >= maxPerMatch) return {ok: false, reason: "max"};
  if (balance < cost) return {ok: false, reason: "insufficient"};
  return {ok: true, cost, newBought: Math.max(0, bought) + 1};
}

/** The caller's bought counts for a match (0s if none). */
function boughtOf(loadoutDoc) {
  const b = loadoutDoc && loadoutDoc.bought;
  const out = {};
  for (const id of Object.keys(ABILITY_CATALOG)) {
    out[id] = Math.max(0, Math.floor(Number(b && b[id]) || 0));
  }
  return out;
}

async function requireParticipant(db, matchId, uid) {
  const snap = await db.collection("matches").doc(matchId).get();
  if (!snap.exists) throw new HttpsError("not-found", "Match not found.");
  const m = snap.data();
  if (m.player1Id !== uid && m.player2Id !== uid) {
    throw new HttpsError("permission-denied", "You're not in this match.");
  }
  // Abilities are a regular/qualifier thing - never the Main Stage finals.
  if (m.mainStage) {
    throw new HttpsError("failed-precondition",
        "Abilities aren't allowed in the finals.");
  }
  if (m.status === "completed" || m.status === "abandoned") {
    throw new HttpsError("failed-precondition", "This match is over.");
  }
  return m;
}

/** What the client needs to render the pre-match loadout. */
async function getLoadout(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const matchId = data && data.matchId;
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  const db = getFirestore();
  await requireParticipant(db, matchId, auth.uid);
  const nowMs = Date.now();
  const [cfg, mon, userSnap, loadoutSnap] = await Promise.all([
    abilityConfig(db),
    readMonetizationConfig(db),
    db.collection("users").doc(auth.uid).get(),
    db.collection("matchLoadouts").doc(matchId)
        .collection("players").doc(auth.uid).get(),
  ]);
  const user = userSnap.data() || {};
  const balance = spendableBalance(user);
  const bought = boughtOf(loadoutSnap.data());
  const abilities = Object.values(ABILITY_CATALOG)
      .filter((a) => cfg.enabled && cfg[a.id].enabled)
      .map((a) => {
        const c = cfg[a.id];
        const free = freeAllowance(user, nowMs, c, mon.trialDays);
        const b = bought[a.id];
        return {
          id: a.id, name: a.name, description: a.description, deploy: a.deploy,
          cost: c.cost, free, bought: b, total: free + b, max: c.maxPerMatch,
          canBuy: free + b < c.maxPerMatch && balance >= c.cost,
        };
      });
  return {enabled: cfg.enabled, balance, matchId, abilities};
}

/**
 * Buy ONE of an ability for a match (adds to the per-match loadout, spends
 * points for anything beyond the free allowance). Idempotent on `requestId`.
 */
async function purchaseAbility(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {matchId, abilityId, requestId} = data || {};
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  if (!ABILITY_CATALOG[abilityId]) {
    throw new HttpsError("invalid-argument", "Unknown ability.");
  }
  const db = getFirestore();
  await requireParticipant(db, matchId, auth.uid);
  const [cfg, mon] = await Promise.all([abilityConfig(db), readMonetizationConfig(db)]);
  if (!cfg.enabled || !cfg[abilityId].enabled) {
    throw new HttpsError("failed-precondition", "That ability isn't available.");
  }
  const c = cfg[abilityId];
  const nowMs = Date.now();

  const rid = (typeof requestId === "string" && requestId.length > 0 &&
      requestId.length <= 128) ?
    requestId :
    `auto_${Date.now()}_${Math.random().toString(36).slice(2)}`;

  const userRef = db.collection("users").doc(auth.uid);
  const loadoutRef = db.collection("matchLoadouts").doc(matchId)
      .collection("players").doc(auth.uid);
  const entryRef = userRef.collection("pointsLedger")
      .doc(`ability_${matchId}_${rid}`);

  const result = await db.runTransaction(async (tx) => {
    const [entrySnap, userSnap, loadoutSnap] = await Promise.all([
      tx.get(entryRef), tx.get(userRef), tx.get(loadoutRef),
    ]);
    const user = userSnap.data() || {};
    const bought = boughtOf(loadoutSnap.data());
    if (entrySnap.exists) {
      return {ok: true, duplicate: true, abilityId,
        bought: bought[abilityId], balance: spendableBalance(user)};
    }
    const free = freeAllowance(user, nowMs, c, mon.trialDays);
    const balance = spendableBalance(user);
    const plan = purchasePlan({
      free, bought: bought[abilityId], maxPerMatch: c.maxPerMatch,
      cost: c.cost, balance,
    });
    if (!plan.ok) return {ok: false, reason: plan.reason, balance, cost: c.cost};

    tx.set(entryRef, {
      reason: "ability", sourceId: rid, abilityId, matchId,
      amount: -plan.cost, createdAt: FieldValue.serverTimestamp(),
    });
    tx.set(userRef, {pointsBalance: balance - plan.cost}, {merge: true});
    tx.set(loadoutRef, {
      bought: {[abilityId]: plan.newBought},
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    return {ok: true, abilityId, bought: plan.newBought, cost: plan.cost,
      balance: balance - plan.cost};
  });

  if (!result.ok) {
    const messages = {
      max: "You've brought the max of this one.",
      insufficient: `That costs ${c.cost} points - you don't have enough.`,
    };
    throw new HttpsError("failed-precondition",
        messages[result.reason] || "Couldn't buy that.", {reason: result.reason});
  }
  return result;
}

/**
 * Resolve BOTH players' ability counts for a match, server-authoritatively.
 * The chess-clock battle is host-driven peer-to-peer, and the host needs each
 * player's real interrupt/extend/go-first counts to seed the engine - but a
 * player's loadout is server-only (matchLoadouts is closed to client reads), so
 * the host cannot read the opponent's. This callable does it with the Admin
 * SDK: a participant asks, and gets the resolved {free+bought} per ability for
 * both sides. It is the honest-path source of truth for seeding (a modified
 * host can cheat its own engine regardless - the same limit as all the P2P turn
 * state; this at least means the counts come from real purchases).
 */
async function getMatchAbilities(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const matchId = data && data.matchId;
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  const db = getFirestore();
  const m = await requireParticipant(db, matchId, auth.uid);
  const nowMs = Date.now();
  const [cfg, mon] = await Promise.all([abilityConfig(db), readMonetizationConfig(db)]);
  const uids = [m.player1Id, m.player2Id];
  const [users, loadouts] = await Promise.all([
    Promise.all(uids.map((u) => db.collection("users").doc(u).get())),
    Promise.all(uids.map((u) => db.collection("matchLoadouts").doc(matchId)
        .collection("players").doc(u).get())),
  ]);
  const players = {};
  uids.forEach((uid, i) => {
    const user = users[i].data() || {};
    const bought = boughtOf(loadouts[i].data());
    const counts = {};
    for (const id of Object.keys(ABILITY_CATALOG)) {
      if (!cfg.enabled || !cfg[id].enabled) {
        counts[id] = 0;
        continue;
      }
      const free = freeAllowance(user, nowMs, cfg[id], mon.trialDays);
      counts[id] = Math.min(free + bought[id], cfg[id].maxPerMatch);
    }
    players[uid] = counts;
  });
  return {enabled: cfg.enabled, players};
}

module.exports = {
  getLoadout,
  purchaseAbility,
  getMatchAbilities,
  resolveAbilityConfig,
  purchasePlan,
  freeAllowance,
  boughtOf,
  ABILITY_CATALOG,
  DEFAULTS,
};
