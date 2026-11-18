/**
 * THE CLIP STRIP (2026-11-15, approved mockups "Clip · ranked, reposted on
 * TikTok" + "Clip · Main Stage Final" in the Battle Screen Show Concepts
 * canvas). The watcher strip burned into the vertical highlight clip, on the
 * seam between the two stacked videos: the turn clock (left), the logo
 * (centre, overlaid by highlightRender.js as an image), the round (right),
 * and each player's name just above / below it, lit while they hold the mic.
 * It replaces the old corner watermark.
 *
 * Deliberately NOT in the clip: LIVE, the watcher count, Follow buttons and
 * the battle type (except the Main Stage, whose "MAIN STAGE · FINAL" tag is
 * part of the show).
 *
 * Everything sits in a CENTRE COLUMN (STRIP.colLeft..colRight). The sides of
 * the frame get cropped when the app cover-fits the clip on a tall phone, and
 * TikTok's like/comment buttons cover the right edge from mid-height down.
 *
 * WHERE THE CLOCK COMES FROM. The host phone logs every change of the battle
 * state (who holds the mic, which turn, each clock) with its wall-clock time
 * and sends the log with completeMatch (`turnLog`). The server shifts it onto
 * its own clock (the phone's clock can be off) and stores it on the match.
 * The recording's segment files are named with Agora's UTC timestamps, so the
 * renderer places each log entry at (entry time - recording start). A match
 * with no log (older matches, a host that never reported) still gets the
 * strip, the logo and the names - just no clock or round.
 *
 * PURE apart from nothing: no Firestore, no ffmpeg. Builds ASS subtitle
 * events that captions.js's buildAssFile writes into the same file the
 * captions use.
 */

const {formatAssTime, escapeAssText} = require("./captions");

/** How long the strip is held past the measured clip end (see buildStripAss). */
const STRIP_TAIL_PAD_SEC = 30;

/** Geometry on the 1080x1920 vertical canvas. */
const STRIP = {
  height: 110,
  colLeft: 268,
  colRight: 812,
  logoWidth: 160,
  // Pills keep 10px clear of the centred logo.
  logoClearLeft: 540 - 80 - 10,
  logoClearRight: 540 + 80 + 10,
  nameGap: 14,
  nameFont: 32,
  namePad: 14,
  // Player pictures (2026-11-17): a circle in each video's corner where it
  // meets the strip (developer: "an equal corner for both"). x = 124 sits
  // just inside the Judge feed's side crop (~108px each side on a 20:9
  // phone); TikTok/Reels/Shorts never cover the middle of the left edge.
  avatarD: 100,
  avatarLeft: 124,
  avatarGap: 10,
  ring: 8,
  pillH: 64,
  pillR: 18,
  clockFont: 50,
  barH: 6,
};

// ASS colours are &HBBGGRR&.
const C = {
  pink: "&H7E2EFF&",
  gold: "&H38C8F4&",
  goldEdge: "&H6BD6F6&",
  purple: "&HFF5C7B&",
  white: "&HFFFFFF&",
  dark: "&H06121A&",
  bg: "&H0E070A&",
  goldBg: "&H080C11&",
};

const MAX_EVENTS = 300;
const MAX_SKEW_MS = 10 * 60 * 1000;

/**
 * Validates the host's turn log and moves it onto the server clock. Returns
 * null for anything unusable - a bad log must never stop a settle, it just
 * means a clip without a clock.
 *
 * Shape in: {v:1, sentAt, kind:'rounds'|'chess', turnMs, turnCount,
 *   players:[uidA, uidB], e:[{t, f, n, r:{uid: ms}, o}]}
 */
function sanitiseTurnLog(raw, serverNowMs, playerIds) {
  if (!raw || typeof raw !== "object") return null;
  const sentAt = Number(raw.sentAt);
  if (!Number.isFinite(sentAt)) return null;
  const skew = serverNowMs - sentAt;
  if (Math.abs(skew) > MAX_SKEW_MS) return null;
  const kind = raw.kind === "chess" ? "chess" : raw.kind === "rounds" ? "rounds" : null;
  if (!kind) return null;
  const ids = (playerIds || []).filter((p) => typeof p === "string" && p);
  if (ids.length !== 2) return null;
  const turnMs = Number(raw.turnMs);
  const turnCount = Number(raw.turnCount);
  if (kind === "rounds" && !(turnMs > 0 && turnMs <= 600000)) return null;
  if (kind === "rounds" && !(turnCount > 0 && turnCount <= 20)) return null;
  if (!Array.isArray(raw.e) || raw.e.length === 0) return null;

  const events = [];
  let lastT = -Infinity;
  for (const e of raw.e.slice(0, MAX_EVENTS)) {
    if (!e || typeof e !== "object") return null;
    const t = Number(e.t);
    if (!Number.isFinite(t) || t < lastT) return null;
    lastT = t;
    const f = ids.includes(e.f) ? e.f : null;
    const n = Math.max(0, Math.min(40, Math.trunc(Number(e.n) || 0)));
    const r = {};
    for (const id of ids) {
      const v = Number(e.r?.[id]);
      r[id] = Number.isFinite(v) ? Math.max(0, Math.min(600000, Math.round(v))) : 0;
    }
    events.push({t: Math.round(t + skew), f, n, r, o: e.o ? 1 : 0});
  }
  return {
    v: 1,
    kind,
    turnMs: kind === "rounds" ? Math.round(turnMs) : null,
    turnCount: kind === "rounds" ? Math.trunc(turnCount) : null,
    events,
  };
}

/** Rounded rectangle as an ASS drawing, origin top-left. */
function roundRect(w, h, r) {
  const k = Math.min(r, h / 2, w / 2);
  return `m ${k} 0 l ${w - k} 0 b ${w} 0 ${w} 0 ${w} ${k} l ${w} ${h - k} ` +
    `b ${w} ${h} ${w} ${h} ${w - k} ${h} l ${k} ${h} b 0 ${h} 0 ${h} 0 ${h - k} ` +
    `l 0 ${k} b 0 0 0 0 ${k} 0`;
}

/**
 * A circle as an ASS drawing, origin top-left of its bounding box: four
 * cubic beziers with the standard 0.5523 handle (corner handles drew a
 * rounded square).
 */
function circle(d) {
  const r = d / 2;
  const k = +(r * 0.5523).toFixed(2);
  const a = +(r + k).toFixed(2);
  const b = +(r - k).toFixed(2);
  return `m ${r} 0 b ${a} 0 ${d} ${b} ${d} ${r} b ${d} ${a} ${a} ${d} ${r} ${d} ` +
    `b ${b} ${d} 0 ${a} 0 ${r} b 0 ${b} ${b} 0 ${r} 0`;
}

const D = "{\\an7\\bord0\\shad0\\p1"; // drawing prefix (closed per call)

function shape(x, y, path, colour, extra = "") {
  return `${D}\\pos(${x},${y})\\1c${colour}${extra}}${path}{\\p0}`;
}

function fmtClock(ms) {
  const s = Math.max(0, Math.min(5999, Math.ceil(ms / 1000)));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

/** A lit clock pill (glow, body, label) anchored at its left or right edge. */
function pillItems(anchor, x, cy, w, colour, label, ink) {
  // A wide pill (LAST WORD) grows outward so it never runs into the logo.
  const left = anchor === "left" ?
    Math.min(x, STRIP.logoClearLeft - w) :
    Math.max(x - w, STRIP.logoClearRight);
  const top = cy - STRIP.pillH / 2;
  const path = roundRect(w, STRIP.pillH, STRIP.pillR);
  return [
    {layer: 2, text: shape(left, top, path, colour, "\\1a&H70&\\blur10")},
    {layer: 3, text: shape(left, top, path, colour)},
    {layer: 4, text: `{\\an5\\pos(${left + w / 2},${cy})\\bord0\\shad0\\b1` +
      `\\1c${ink}}${label}`},
  ];
}

function clockLabel(ms, extra) {
  return `{\\fs${STRIP.clockFont}}${fmtClock(ms)}` +
    (extra ? `{\\fs24}  ${extra}` : "");
}

function roundItems(round, count, x, cy) {
  const n = count > 0 ? count : 3;
  const items = [{
    layer: 4,
    text: `{\\an3\\pos(${x},${cy + 6})\\bord0\\shad0\\b1\\fs22\\1c${C.white}` +
      `\\1a&H40&}ROUND {\\fs38\\1c${C.gold}\\1a&H00&}${round}/${n}`,
  }];
  const d = 12;
  const gap = 8;
  for (let i = 0; i < n; i++) {
    const left = x - (n - i) * d - (n - 1 - i) * gap;
    const filled = i < round;
    items.push({
      layer: 4,
      text: shape(left, cy + 14, circle(d), C.gold,
          filled ? "" : `\\1a&HFF&\\bord2\\3c${C.gold}`),
    });
  }
  return items;
}

/**
 * Everything drawn in the strip for one battle state (excluding the bar).
 * [state] = {phase:'pre'|'live'|'over'|'none', kind, floor (1|2|0),
 *   clocks:{p1,p2}, holderMs, last, round, roundCount}.
 */
function stripItems(state, seam) {
  const L = STRIP.colLeft;
  const R = STRIP.colRight;
  const items = [];
  if (state.phase === "none") return items;
  if (state.kind === "chess") {
    // Both clocks: top player's left, bottom player's right, holder's lit.
    const sides = [["left", L, state.clocks.p1, state.floor === 1],
      ["right", R, state.clocks.p2, state.floor === 2]];
    for (const [anchor, x, ms, on] of sides) {
      if (on && state.phase === "live") {
        items.push(...pillItems(anchor, x, seam, 150, C.pink,
            clockLabel(ms), C.white));
      } else {
        const an = anchor === "left" ? 4 : 6;
        items.push({layer: 4, text: `{\\an${an}\\pos(${x},${seam})\\bord0` +
          `\\shad0\\b1\\fs${STRIP.clockFont}\\1c${C.white}\\1a&H50&}` +
          `${fmtClock(ms)}`});
      }
    }
    return items;
  }
  // Rapid rounds.
  if (state.phase === "pre") {
    items.push(...pillItems("left", L, seam, 210, C.purple,
        "{\\fs28}GET READY", C.white));
  } else if (state.phase === "over") {
    items.push(...pillItems("left", L, seam, 150, C.purple,
        "{\\fs32}TIME!", C.white));
  } else if (state.last) {
    items.push(...pillItems("left", L, seam, 250, C.gold,
        clockLabel(state.holderMs, "LAST WORD"), C.dark));
  } else {
    items.push(...pillItems("left", L, seam, 150, C.pink,
        clockLabel(state.holderMs), C.white));
  }
  items.push(...roundItems(state.round, state.roundCount, R, seam));
  return items;
}

/**
 * Splits [start,end) spans across the dead-air cuts. Each span carries a
 * render(origStart, origEnd) and comes back as pieces on the trimmed
 * timeline, so a clock or bar mid-turn stays right after a cut.
 */
function remapSpans(spans, keeps) {
  if (!keeps) {
    return spans.map((s) => ({...s, spanStart: s.start, oStart: s.start, oEnd: s.end}));
  }
  const out = [];
  let elapsed = 0;
  const offsets = keeps.map((k) => {
    const o = elapsed;
    elapsed += k.end - k.start;
    return o;
  });
  for (const s of spans) {
    keeps.forEach((k, i) => {
      const a = Math.max(s.start, k.start);
      const b = Math.min(s.end, k.end);
      if (b - a < 0.02) return;
      out.push({
        ...s,
        spanStart: s.start,
        oStart: a,
        oEnd: b,
        start: offsets[i] + (a - k.start),
        end: offsets[i] + (b - k.start),
      });
    });
  }
  return out;
}

/**
 * Turns the stored log into timed battle states on the clip's original
 * timeline (seconds from the recording start).
 */
function statesFromLog(log, t0Ms, durationSec, p1Id, p2Id) {
  if (!log || !Array.isArray(log.events) || log.events.length === 0) {
    return [{start: 0, end: durationSec, state: {phase: "none"}}];
  }
  const kind = log.kind;
  const roundCount = kind === "rounds" ? Math.max(1, Math.floor(log.turnCount / 2)) : 0;
  const out = [];
  const firstT = (log.events[0].t - t0Ms) / 1000;
  if (firstT > 0) {
    out.push({
      start: 0,
      end: Math.min(firstT, durationSec),
      state: kind === "chess" ?
        {phase: "pre", kind, floor: 0, clocks: {
          p1: log.events[0].r[p1Id] ?? 0, p2: log.events[0].r[p2Id] ?? 0}} :
        {phase: "pre", kind, round: 1, roundCount},
    });
  }
  log.events.forEach((e, i) => {
    const start = Math.max(0, (e.t - t0Ms) / 1000);
    const next = log.events[i + 1];
    const end = Math.min(durationSec, next ? (next.t - t0Ms) / 1000 : durationSec);
    if (end - start < 0.02) return;
    const floor = e.f === p1Id ? 1 : e.f === p2Id ? 2 : 0;
    const round = Math.max(1, Math.min(roundCount || 1, Math.ceil(e.n / 2) || 1));
    out.push({
      start,
      end,
      startMs: e.r[e.f] ?? 0,
      state: {
        phase: e.o ? "over" : floor ? "live" : "pre",
        kind,
        floor,
        clocks: {p1: e.r[p1Id] ?? 0, p2: e.r[p2Id] ?? 0},
        holderMs: e.r[e.f] ?? 0,
        last: kind === "rounds" && e.n >= log.turnCount,
        round: e.o ? roundCount : round,
        roundCount,
        turnMs: log.turnMs,
      },
    });
  });
  return out;
}

/**
 * Splits each state span into one span per displayed clock second (the
 * holder's clock ticks down inside a span), so the text can change.
 */
function tickSpans(stateSpans) {
  const out = [];
  for (const s of stateSpans) {
    const st = s.state;
    if (st.phase !== "live") {
      out.push(s);
      continue;
    }
    const base = st.kind === "chess" ?
      (st.floor === 1 ? st.clocks.p1 : st.clocks.p2) : st.holderMs;
    let t = s.start;
    while (t < s.end - 0.001) {
      const elapsedMs = (t - s.start) * 1000;
      const rem = Math.max(0, base - elapsedMs);
      // Next moment the shown second changes.
      const shown = Math.ceil(rem / 1000);
      const changeAtMs = shown <= 0 ? Infinity : base - (shown - 1) * 1000;
      const next = Math.min(s.end, s.start + changeAtMs / 1000);
      const remMs = rem;
      const state = {...st, holderMs: remMs, clocks: {...st.clocks}};
      if (st.kind === "chess") {
        if (st.floor === 1) state.clocks.p1 = remMs;
        else state.clocks.p2 = remMs;
      }
      out.push({start: t, end: next <= t ? s.end : next, state});
      if (next <= t) break;
      t = next;
    }
  }
  return out;
}

/**
 * Where each player's picture goes (top-left of its circle), both at the far
 * left: player 1 (top video) just above the strip, player 2 (bottom video)
 * just below it. The app puts its tap targets on exactly these spots.
 */
function avatarSpots(seam) {
  const top = seam - STRIP.height / 2;
  const bottom = seam + STRIP.height / 2;
  return {
    1: {x: STRIP.avatarLeft, y: top - STRIP.avatarGap - STRIP.avatarD, d: STRIP.avatarD},
    2: {x: STRIP.avatarLeft, y: bottom + STRIP.avatarGap, d: STRIP.avatarD},
  };
}

function initialOf(name) {
  const ch = typeof name === "string" ? name.trim().charAt(0) : "";
  return ch ? ch.toUpperCase() : "?";
}

/**
 * The whole strip as ASS styles + Dialogue lines, ready to append to the
 * caption file.
 *
 * opts: {canvas, durationSec, t0Ms, log, p1Id, p2Id, names:{1,2},
 *   hidden:{1:bool,2:bool}, mainStage:{label, seeds:{1,2}}|null, keeps}
 */
function buildStripAss(opts) {
  const {canvas, t0Ms, log, p1Id, p2Id, keeps} = opts;
  // The measured length comes from the VIDEO playlists, but the rendered
  // clip runs as long as its longest stream - the audio often outlasts the
  // video by a few seconds - and the strip vanished for that tail, leaving
  // the crown split across the bare seam (developer, 2026-11-17). Hold the
  // last state 30s past the measured end; subtitle events past the end of
  // the video are simply never shown. A trimmed clip is cut to its keeps
  // (audio and video alike), so it needs no pad.
  const durationSec = opts.durationSec + (keeps ? 0 : STRIP_TAIL_PAD_SEC);
  const names = opts.names || {};
  const hidden = opts.hidden || {};
  const ms = opts.mainStage || null;
  const seam = Math.round(canvas.height / 2);
  const top = seam - STRIP.height / 2;
  const bottom = seam + STRIP.height / 2;
  const lines = [];
  const push = (layer, start, end, text, styleName = "Strip") => {
    if (end - start < 0.02) return;
    lines.push(`Dialogue: ${layer},${formatAssTime(start)},${formatAssTime(end)},` +
      `${styleName},,0,0,0,,${text}`);
  };

  // The trimmed clip's length: the whole strip background spans it.
  const spans = remapSpans([{start: 0, end: durationSec}], keeps);
  const fullEnd = spans.reduce((m, s) => Math.max(m, s.end), 0);
  const W = canvas.width;
  if (ms) {
    push(0, 0, fullEnd, shape(0, top - 8, roundRect(W, STRIP.height + 16, 0),
        C.gold, "\\1a&HA0&\\blur18"));
  }
  push(1, 0, fullEnd, shape(0, top, roundRect(W, STRIP.height, 0),
      ms ? C.goldBg : C.bg, ms ? "" : "\\1a&H08&"));
  const edge = ms ? C.goldEdge : C.white;
  const edgeA = ms ? "" : "\\1a&HE0&";
  push(1, 0, fullEnd, shape(0, top, roundRect(W, 2, 0), edge, edgeA));
  push(1, 0, fullEnd, shape(0, bottom - 2, roundRect(W, 2, 0), edge, edgeA));

  // Main Stage tag, straddling the strip's top edge.
  let topNameBottom = top - STRIP.nameGap;
  if (ms && ms.label) {
    push(5, 0, fullEnd, `{\\an5\\pos(${W / 2},${top - 14})\\b1\\fs22\\bord8\\shad0` +
      `\\1c${C.dark}\\3c${C.gold}}${escapeAssText(`MAIN STAGE · ${ms.label}`)}`,
    "StripBox");
    topNameBottom = top - 44;
  }

  const states = statesFromLog(log, t0Ms, durationSec, p1Id, p2Id);

  // PLAYER PICTURES replace the burned-in names (developer, 2026-11-17:
  // names landed on faces, and every other spot is covered by TikTok's
  // buttons or the app's own). The photo itself is overlaid by ffmpeg on
  // top of everything here (highlightRender, `avatars`); this draws the
  // ring behind it - lit pink (gold on the Main Stage) while that player
  // holds the mic, a dim white edge otherwise - and, for a player with no
  // photo, an initials disc. A blurred player gets nothing.
  const spots = avatarSpots(seam);
  const photos = opts.photos || {};
  const ringD = STRIP.avatarD + STRIP.ring * 2;
  for (const s of remapSpans(states, keeps)) {
    const floor = s.state.phase === "live" ? s.state.floor : 0;
    for (const who of [1, 2]) {
      if (hidden[who]) continue;
      const {x, y} = spots[who];
      const lit = floor === who;
      const litColour = ms ? C.gold : C.pink;
      if (lit) {
        push(4, s.start, s.end, shape(x - STRIP.ring * 2, y - STRIP.ring * 2,
            circle(ringD + STRIP.ring * 2), litColour, "\\1a&H60&\\blur12"));
      }
      push(5, s.start, s.end, shape(x - STRIP.ring, y - STRIP.ring,
          circle(ringD), lit ? litColour : C.white, lit ? "" : "\\1a&H80&"));
    }
  }
  for (const who of [1, 2]) {
    if (hidden[who]) continue;
    const {x, y, d} = spots[who];
    if (!photos[who]) {
      push(6, 0, fullEnd, shape(x, y, circle(d), C.purple));
      push(7, 0, fullEnd, `{\\an5\\pos(${x + d / 2},${y + d / 2})\\b1\\fs50` +
        `\\bord0\\shad0\\1c${C.white}}${escapeAssText(initialOf(names[who]))}`);
    }
    // Main Stage seed, in gold just right of the picture.
    const seed = ms?.seeds?.[who];
    if (seed) {
      push(7, 0, fullEnd, `{\\an4\\pos(${x + d + 14},${y + d / 2})\\b1\\fs40` +
        `\\bord3\\shad0\\1c${C.gold}\\3c${C.dark}}#${seed}`);
    }
  }

  // Clock / round content, one span per shown second.
  for (const s of remapSpans(tickSpans(states), keeps)) {
    for (const item of stripItems(s.state, seam)) {
      push(item.layer, s.start, s.end, item.text);
    }
  }

  // The draining bar along the strip's bottom edge (rapid rounds only).
  if (log && log.kind === "rounds" && log.turnMs > 0) {
    for (const s of remapSpans(states, keeps)) {
      const st = s.state;
      if (st.phase !== "live") continue;
      // Remaining at this piece's original start (a cut can split a turn).
      const remAtStart = Math.max(0, st.holderMs - (s.oStart - s.spanStart) * 1000);
      const frac = Math.min(1, remAtStart / log.turnMs);
      const x0 = Math.round(W * frac);
      const dur = Math.round(remAtStart);
      const colour = st.last ? C.gold : C.pink;
      const y1 = bottom - STRIP.barH;
      push(4, s.start, s.end, `{\\an7\\pos(0,${y1})\\bord0\\shad0\\p1\\1c${colour}` +
        `\\clip(0,${y1},${x0},${bottom})\\t(0,${dur},\\clip(0,${y1},0,${bottom}))}` +
        `${roundRect(W, STRIP.barH, 0)}{\\p0}`);
    }
  }

  return {
    // Matches captions.js's shortened Format line (16 fields). Strip = plain
    // drawings and text; StripBox = opaque-box text (names, the tag).
    style: [
      "Style: Strip,Arial,32,&H00FFFFFF,&H00000000,&H00000000,-1,0,1,0,0,5,0,0,0,1",
      `Style: StripBox,Arial,${STRIP.nameFont},&H00FFFFFF,&H00000000,&H00000000,` +
        `-1,0,3,${STRIP.namePad},0,5,0,0,0,1`,
    ].join("\n"),
    lines,
    // Where the captions should go so they clear the strip and the bottom
    // name: just under the bottom name, top-aligned.
    // Captions sit just under the bottom player's picture.
    captionTop: bottom + STRIP.avatarGap + STRIP.avatarD + 24,
    // Where ffmpeg overlays each photo (null = none: no photo, or blurred).
    avatars: {
      1: !hidden[1] && photos[1] ? spots[1] : null,
      2: !hidden[2] && photos[2] ? spots[2] : null,
    },
    logo: {width: STRIP.logoWidth, centreY: seam},
  };
}

module.exports = {
  STRIP,
  avatarSpots,
  sanitiseTurnLog,
  buildStripAss,
  remapSpans,
  statesFromLog,
  tickSpans,
  fmtClock,
};
