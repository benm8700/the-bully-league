// If the founder qualifies for the Main Stage, they must not judge it or
// break a tie on it (developer's rule, 2026-11-08).
const assert = require("assert");
const {lockOutcome} = require("../mainStageLifecycle");
const {headJudgeFor, tallyJudgeVotes} = require("../mainStageJudging");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const FOUNDER = "founder";
const finalists = [FOUNDER, "p2", "p3", "p4"];
const invites = {founder: "accepted", p2: "accepted", p3: "accepted",
  p4: "accepted", j2: "accepted", j3: "accepted"};
const out = lockOutcome({
  finalists, alternates: ["a1"], invites,
  handPicked: [FOUNDER, "j2", "j3"],
  judgePool: ["pool1", "pool2", "pool3"],
});

check("the founder plays: they are in the locked field", () => {
  assert.ok(out.field.includes(FOUNDER));
});

check("the founder is NOT seated as a judge", () => {
  assert.ok(!out.judges.includes(FOUNDER));
  assert.ok(!out.judgeStandby.includes(FOUNDER));
  assert.strictEqual(out.judges.length, 5);
});

check("the tiebreak passes to the founder's next seated pick", () => {
  assert.strictEqual(headJudgeFor([FOUNDER, "j2", "j3"], out.judges), "j2");
});

check("a vote from the founder (a battler) never counts", () => {
  const panel = out.judges;
  const votes = {[FOUNDER]: "p2"};
  // Split the seated panel 2-2 with the head judge on p3's side.
  const [h, b, c, d] = panel;
  Object.assign(votes, {[h]: "p3", [b]: "p3", [c]: "p2", [d]: "p2"});
  const t = tallyJudgeVotes(votes, panel, {headJudge: headJudgeFor(
      [FOUNDER, "j2", "j3"], panel)});
  assert.strictEqual(t.counts.p2, 2); // founder's ballot ignored
});

check("when the founder does NOT qualify, they are head judge as usual", () => {
  const o = lockOutcome({
    finalists: ["p1", "p2", "p3", "p4"], alternates: [],
    invites: {p1: "accepted", p2: "accepted", p3: "accepted", p4: "accepted",
      founder: "accepted"},
    handPicked: [FOUNDER], judgePool: ["pool1", "pool2", "pool3", "pool4"],
  });
  assert.ok(o.judges.includes(FOUNDER));
  assert.strictEqual(headJudgeFor([FOUNDER], o.judges), FOUNDER);
});

console.log(`founderQualifies: ${passed} passed`);
