/**
 * The daily window push schedule.
 *
 * The property under test is IDEMPOTENCE. This runs on a timer, so without
 * a record of what has already gone out it re-sends on every tick. Nothing
 * gets an app muted faster than the same notification twice - and because
 * muting is per-app at the OS level, one duplicate can cost every future
 * category too.
 *
 * Run: node test/eventWindowPush.test.js
 */
const assert = require("assert");
const {
  pushDecision,
  pacificNow,
  readConfig,
  copyFor,
  LAST_CALL_LEAD_MINUTES,
} = require("../eventWindowPush");
const {wantsCategory, CATEGORIES} = require("../notifications");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

const START = 18 * 60; // 6pm
const END = 19 * 60; // 7pm
const at = (hour, minute = 0, sentKinds = []) => pushDecision({
  nowMinutes: hour * 60 + minute,
  startMinutes: START,
  endMinutes: END,
  sentKinds,
});

// --- when it fires ---

check("nothing fires before the window opens", () => {
  assert.strictEqual(at(17, 59), null);
});

check("the start push fires at the top of the window", () => {
  assert.strictEqual(at(18, 0), "start");
});

check("nothing fires once the window has closed", () => {
  assert.strictEqual(at(19, 0), null);
  assert.strictEqual(at(23, 30), null);
});

check("the last call fires in the closing stretch", () => {
  assert.strictEqual(at(18, 60 - LAST_CALL_LEAD_MINUTES), "last_call");
  assert.strictEqual(at(18, 59), "last_call");
});

// --- idempotence, the part that matters ---

check("the start push does not repeat on the next tick", () => {
  assert.strictEqual(at(18, 5, ["start"]), null);
  assert.strictEqual(at(18, 30, ["start"]), null);
});

check("the last call does not repeat either", () => {
  assert.strictEqual(at(18, 50, ["start", "last_call"]), null);
  assert.strictEqual(at(18, 58, ["start", "last_call"]), null);
});

check("a sent start does not suppress the later last call", () => {
  // Two different notifications; sending one must not consume the other.
  assert.strictEqual(at(18, 50, ["start"]), "last_call");
});

check("a late recovery sends the last call, NOT a stale 'starting now'", () => {
  // If the job was down through 6pm and recovers at 6:50, announcing that
  // the window "starts now" would be actively false - it's nearly over.
  assert.strictEqual(at(18, 50, []), "last_call");
});

check("a mid-window recovery still sends the start", () => {
  // Late is fine while there's real time left to play.
  assert.strictEqual(at(18, 20, []), "start");
});

// --- config-driven hours ---

check("the schedule follows reconfigured hours", () => {
  const decide = (h, m, sent = []) => pushDecision({
    nowMinutes: h * 60 + m, startMinutes: 20 * 60, endMinutes: 22 * 60, sentKinds: sent,
  });
  assert.strictEqual(decide(18, 0), null, "old hour must not fire");
  assert.strictEqual(decide(20, 0), "start");
  assert.strictEqual(decide(21, 50, ["start"]), "last_call");
});

check("a window shorter than the lead time is all last call", () => {
  // Degenerate but reachable from the console: the whole window is inside
  // the closing stretch, so "starts now" would be wrong the entire time.
  const decide = (m, sent = []) => pushDecision({
    nowMinutes: 18 * 60 + m, startMinutes: 18 * 60, endMinutes: 18 * 60 + 10, sentKinds: sent,
  });
  assert.strictEqual(decide(0), "last_call");
  assert.strictEqual(decide(5, ["last_call"]), null);
});

// --- Pacific clock ---

check("Pacific time is read in daylight saving", () => {
  // 2026-07-02T01:30Z is 6:30pm PDT on July 1st.
  const {dayKey, minutes} = pacificNow(new Date("2026-07-02T01:30:00Z"));
  assert.strictEqual(dayKey, "2026-07-01");
  assert.strictEqual(minutes, 18 * 60 + 30);
});

check("Pacific time is read in standard time", () => {
  // 2026-01-16T02:30Z is 6:30pm PST on January 15th.
  const {dayKey, minutes} = pacificNow(new Date("2026-01-16T02:30:00Z"));
  assert.strictEqual(dayKey, "2026-01-15");
  assert.strictEqual(minutes, 18 * 60 + 30);
});

check("the same UTC instant maps to one Pacific moment year-round", () => {
  // The whole point of anchoring to a single timezone: the window is one
  // global moment, so this must never depend on where the server runs.
  const summer = pacificNow(new Date("2026-07-02T01:00:00Z")).minutes;
  const winter = pacificNow(new Date("2026-01-16T02:00:00Z")).minutes;
  assert.strictEqual(summer, 18 * 60);
  assert.strictEqual(winter, 18 * 60);
});

check("midnight Pacific reads as minute zero, not 1440", () => {
  // Some ICU builds format midnight as hour 24, which would put the clock a
  // full day out.
  const {minutes} = pacificNow(new Date("2026-07-01T07:00:00Z"));
  assert.strictEqual(minutes, 0);
});

// --- config parsing ---

check("config defaults apply when the document is missing", () => {
  const c = readConfig(null);
  assert.strictEqual(c.startHourPacific, 18);
  assert.strictEqual(c.endHourPacific, 19);
  assert.strictEqual(c.enabled, true);
});

check("an out-of-range hour is refused in favour of the default", () => {
  assert.strictEqual(readConfig({startHourPacific: 47}).startHourPacific, 18);
  assert.strictEqual(readConfig({startHourPacific: 20, endHourPacific: 3}).endHourPacific, 19);
});

check("the server and client agree on the default hours", () => {
  // These are two separate implementations of the same window - one in Dart
  // for the countdown, one here for the push. If they drift, the app counts
  // down to one time and notifies at another.
  const c = readConfig(null);
  assert.strictEqual(c.startHourPacific, 18, "must match event_window.dart");
  assert.strictEqual(c.endHourPacific, 19, "must match event_window.dart");
});

// --- copy ---

check("copy names the window and uses the live count when there is one", () => {
  const {title, body} = copyFor("start", {name: "Sixes and Sevens"}, 7);
  assert.ok(title.includes("Sixes and Sevens"));
  assert.ok(body.includes("7 roasters"));
});

check("copy never claims people are online when nobody is", () => {
  // The count is only persuasive while it is true.
  const {body} = copyFor("start", {name: "Sixes and Sevens"}, 0);
  assert.ok(!/\d/.test(body), `should not quote a count: "${body}"`);
});

check("a single roaster is described in the singular", () => {
  assert.ok(copyFor("start", {name: "X"}, 1).body.includes("1 roaster is"));
});

check("people who committed are reminded of their own promise", () => {
  // The whole mechanism pre-commitment relies on: an intention only raises
  // follow-through if something reminds you that you made it. Sending the
  // generic broadcast to someone who deliberately opted in wastes the
  // strongest signal the app has about who intends to show up.
  const committed = copyFor("start", {name: "X"}, 4, {committed: true});
  const general = copyFor("start", {name: "X"}, 4);
  assert.ok(/you said/i.test(committed.body), committed.body);
  assert.ok(!/you said/i.test(general.body), general.body);
  assert.notStrictEqual(committed.body, general.body);
});

check("the committed last call also references the promise", () => {
  const committed = copyFor("last_call", {name: "X"}, 3, {committed: true});
  assert.ok(/you said/i.test(committed.body), committed.body);
});

check("committed copy still never invents a count", () => {
  for (const kind of ["start", "last_call"]) {
    const {body} = copyFor(kind, {name: "X"}, 0, {committed: true});
    assert.ok(!/\d/.test(body), `${kind}: "${body}"`);
  }
});

check("committed copy reads correctly for exactly one other person", () => {
  // Plural agreement is easy to get wrong when a count is spliced into a
  // sentence, and "So are 1 others" is the kind of thing that makes an app
  // feel unfinished.
  const {body} = copyFor("start", {name: "X"}, 1, {committed: true});
  assert.ok(!/are 1 others/.test(body), body);
  assert.ok(/is 1 other\b/.test(body), body);
});

// --- preferences ---

check("absent preferences mean opted IN", () => {
  // Every existing account has no preferences map. Treating absent as
  // opted-out would silently switch notifications off for the whole
  // userbase - the same trap as the missing-accountStatus bug.
  assert.strictEqual(wantsCategory({}, "event_window"), true);
  assert.strictEqual(wantsCategory({notificationPrefs: {}}, "event_window"), true);
  assert.strictEqual(wantsCategory(undefined, "event_window"), true);
});

check("only an explicit false opts out", () => {
  assert.strictEqual(
      wantsCategory({notificationPrefs: {event_window: false}}, "event_window"), false);
  assert.strictEqual(
      wantsCategory({notificationPrefs: {event_window: true}}, "event_window"), true);
});

check("muting one category leaves the others alone", () => {
  // The entire reason for per-category toggles: a single global switch is
  // the one that gets turned off forever after one annoying notification.
  const user = {notificationPrefs: {event_window: false}};
  assert.strictEqual(wantsCategory(user, "event_window"), false);
  assert.strictEqual(wantsCategory(user, "match_found"), true);
});

check("every category the app sends is user-mutable", () => {
  for (const c of ["match_found", "event_window", "vote_reminder"]) {
    assert.ok(CATEGORIES.includes(c), `${c} must be mutable`);
  }
});

console.log(`\n${checks} checks passed.`);
