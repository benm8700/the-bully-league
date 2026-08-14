/**
 * The two-stage auto-render rules.
 *
 * Worth pinning because both stages spend real money on real compute, and
 * the failure modes are quiet: rendering a match whose files are not there
 * yet burns a 4GiB job to produce nothing, and re-captioning an already-
 * captioned clip pays the expensive part of the pipeline twice.
 *
 * Run: node test/autoRender.test.js
 */
const assert = require("assert");
const {
  needsFirstRender,
  canBeCaptioned,
  captionsForced,
  selectForCaptioning,
  voteMargin,
  MAX_ATTEMPTS,
  CAPTION_TOP_N,
  CAPTION_WEEKLY_CAP,
} = require("../autoRender");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

const ready = {
  status: "completed",
  mode: "ranked",
  recording: {files: [{path: "a.ts"}]},
};

// --- stage 1: composite ---

check("a finished ranked match with footage gets rendered", () => {
  assert.strictEqual(needsFirstRender(ready), true);
});

check("a match still in progress is left alone", () => {
  assert.strictEqual(needsFirstRender({...ready, status: "pending"}), false);
  assert.strictEqual(needsFirstRender({...ready, status: "abandoned"}), false);
});

check("exhibition matches are never rendered", () => {
  // They are never recorded either, so there is nothing to render - and
  // rendering the mode people play most casually would put cost exactly
  // where the existing recording decision deliberately keeps it off.
  assert.strictEqual(needsFirstRender({...ready, mode: "exhibition"}), false);
});

check("tournament matches are rendered", () => {
  assert.strictEqual(needsFirstRender({...ready, mode: "tournament"}), true);
});

check("a match with no recorded files is NOT rendered", () => {
  // The single most important case. completeMatch writes status:completed
  // BEFORE the recording stops and its files are listed, so a match is
  // routinely 'completed' with nothing to render. Starting a 4GiB job then
  // burns compute to produce nothing.
  assert.strictEqual(needsFirstRender({...ready, recording: {}}), false);
  assert.strictEqual(needsFirstRender({...ready, recording: {files: []}}), false);
  assert.strictEqual(needsFirstRender({...ready, recording: null}), false);
  assert.strictEqual(needsFirstRender({status: "completed", mode: "ranked"}), false);
});

check("an already-rendered match is not rendered again", () => {
  assert.strictEqual(
      needsFirstRender({...ready, highlight: {renditions: {vertical: {}}}}), false);
});

check("a repeatedly failing match is eventually left alone", () => {
  // Something is broken about it - a truncated recording, a missing track -
  // and retrying forever would burn compute on it indefinitely.
  assert.strictEqual(
      needsFirstRender({...ready, autoRender: {attempts: MAX_ATTEMPTS - 1}}), true);
  assert.strictEqual(
      needsFirstRender({...ready, autoRender: {attempts: MAX_ATTEMPTS}}), false);
});

check("a missing match never qualifies", () => {
  assert.strictEqual(needsFirstRender(null), false);
  assert.strictEqual(needsFirstRender(undefined), false);
});

// --- stage 2: captions, the expensive half ---

const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.parse("2026-08-14T12:00:00Z");

/** A finished, rendered, uncaptioned match ready to be ranked. */
const finished = (votes, {ageDays = 1, p1 = null, p2 = null, id = "m"} = {}) => ({
  id,
  voteCount: votes,
  voteFinalized: true,
  finalizedAtMs: NOW - ageDays * DAY,
  player1FinalWeight: p1 ?? votes,
  player2FinalWeight: p2 ?? 0,
});

const rendered = {
  ...ready,
  highlight: {renditions: {vertical: {}}},
  voteCount: 0,
};

check("a rendered, uncaptioned clip is a candidate", () => {
  assert.strictEqual(canBeCaptioned(rendered), true);
});

check("an already-captioned clip is never re-captioned", () => {
  // Paying for transcription twice on the same audio is pure waste.
  assert.strictEqual(canBeCaptioned({
    ...rendered, highlight: {renditions: {}, captioned: true},
  }), false);
});

check("a match with no render yet is not a caption candidate", () => {
  assert.strictEqual(canBeCaptioned(ready), false);
});

check("repeated caption failures stop retrying", () => {
  assert.strictEqual(canBeCaptioned({
    ...rendered, autoRender: {captionAttempts: MAX_ATTEMPTS},
  }), false);
});

check("an admin preparing a clip for posting forces captions", () => {
  // External posting is where captions matter most - muted autoplay - and
  // that path is individually approved anyway, so it skips the ranking.
  assert.strictEqual(captionsForced({
    ...rendered, highlight: {renditions: {}, captionRequested: true},
  }), true);
  assert.strictEqual(captionsForced(rendered), false);
});

// --- the ranking, and the growth problem it exists to solve ---

check("only the top N of the week are captioned", () => {
  const many = Array.from({length: 30}, (_, i) =>
    finished(i + 1, {id: `m${i}`}));
  assert.strictEqual(selectForCaptioning(many, {now: NOW}).length, CAPTION_TOP_N);
});

check("the highest scoring matches win", () => {
  const picked = selectForCaptioning(
      [finished(1, {id: "low"}), finished(50, {id: "high"}), finished(10, {id: "mid"})],
      {now: NOW, topN: 2});
  assert.deepStrictEqual(picked.map((c) => c.id), ["high", "mid"]);
});

check("GROWTH DOES NOT CHANGE THE SELECTION", () => {
  // The developer's concern, and the reason this is a ranking rather than
  // a fixed vote threshold. Ten times the userbase means ten times the
  // votes on every match - and exactly the same clips should still win.
  const week = [finished(2, {id: "a"}), finished(9, {id: "b"}), finished(4, {id: "c"})];
  const grown = week.map((m) => ({
    ...m, voteCount: m.voteCount * 10,
    player1FinalWeight: m.player1FinalWeight * 10,
  }));
  assert.deepStrictEqual(
      selectForCaptioning(week, {now: NOW, topN: 2}).map((c) => c.id),
      selectForCaptioning(grown, {now: NOW, topN: 2}).map((c) => c.id));
});

check("a quiet day competes against its own peers, not a busy one", () => {
  // Normalising to the same-day median is what stops every winner coming
  // from whichever day happened to be busiest.
  const busyDay = [40, 50, 60].map((v, i) => finished(v, {ageDays: 1, id: `busy${i}`}));
  const quietDay = [2, 3, 20].map((v, i) => finished(v, {ageDays: 3, id: `quiet${i}`}));
  const picked = selectForCaptioning([...busyDay, ...quietDay], {now: NOW, topN: 2})
      .map((c) => c.id);
  // quiet2 is 20 against a median of 3 - far more exceptional for its day
  // than busy2's 60 against a median of 50, despite a third of the votes.
  assert.ok(picked.includes("quiet2"), `picked ${picked}`);
});

check("a decisive result outranks a coin flip at equal volume", () => {
  const blowout = finished(10, {id: "blowout", p1: 10, p2: 0});
  const closeRun = finished(10, {id: "close", p1: 5, p2: 5});
  assert.deepStrictEqual(
      selectForCaptioning([closeRun, blowout], {now: NOW, topN: 1}).map((c) => c.id),
      ["blowout"]);
});

check("vote margin runs from a dead heat to a shut out", () => {
  assert.strictEqual(voteMargin({player1FinalWeight: 5, player2FinalWeight: 5}), 0);
  assert.strictEqual(voteMargin({player1FinalWeight: 10, player2FinalWeight: 0}), 1);
  assert.strictEqual(voteMargin({}), 0);
});

check("matches still open for voting are NOT ranked", () => {
  // Their counts are still moving, so ranking them against finished
  // matches would measure age rather than merit.
  const open = {...finished(99, {id: "open"}), voteFinalized: false};
  assert.deepStrictEqual(selectForCaptioning([open], {now: NOW}), []);
});

check("matches older than a week drop out", () => {
  assert.deepStrictEqual(
      selectForCaptioning([finished(99, {ageDays: 8, id: "old"})], {now: NOW}), []);
});

check("a match nobody judged is never captioned", () => {
  // However quiet the week, zero votes is not a highlight.
  assert.deepStrictEqual(
      selectForCaptioning([finished(0, {id: "unjudged"})], {now: NOW}), []);
});

check("the weekly cap is a hard ceiling", () => {
  const many = Array.from({length: 30}, (_, i) => finished(i + 1, {id: `m${i}`}));
  assert.strictEqual(
      selectForCaptioning(many, {now: NOW, captionedThisWeek: CAPTION_WEEKLY_CAP})
          .length, 0);
  assert.strictEqual(
      selectForCaptioning(many, {now: NOW, captionedThisWeek: CAPTION_WEEKLY_CAP - 2})
          .length, 2);
});

check("an empty week selects nothing rather than throwing", () => {
  assert.deepStrictEqual(selectForCaptioning([], {now: NOW}), []);
});

console.log(`\n${checks} checks passed.`);
