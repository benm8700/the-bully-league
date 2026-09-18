const assert = require("assert");
const {sanitiseRoundBoundaries} = require("../matchmaking");
let n = 0;
const ok = (name, cond) => { n++; if (!cond) { console.log("FAIL:", name); process.exitCode = 1; } };

// Valid list is normalised (rounded, truncated).
const clean = sanitiseRoundBoundaries([
  {round: 0, startMs: 100.4, endMs: 5000.6},
  {round: 1, startMs: 6000, endMs: 11000},
]);
ok("valid list kept", Array.isArray(clean) && clean.length === 2);
ok("rounded", clean[0].startMs === 100 && clean[0].endMs === 5001);
ok("round truncated to int", clean[0].round === 0 && clean[1].round === 1);

// Rejections (whole array) - a partial list would misseek the player.
ok("null in -> null", sanitiseRoundBoundaries(null) === null);
ok("empty -> null", sanitiseRoundBoundaries([]) === null);
ok("not array -> null", sanitiseRoundBoundaries({round: 0}) === null);
ok("end<=start rejects whole", sanitiseRoundBoundaries([{round: 0, startMs: 100, endMs: 100}]) === null);
ok("negative start rejects", sanitiseRoundBoundaries([{round: 0, startMs: -1, endMs: 10}]) === null);
ok("NaN rejects", sanitiseRoundBoundaries([{round: 0, startMs: "x", endMs: 10}]) === null);
ok("one bad entry rejects the whole list",
   sanitiseRoundBoundaries([{round: 0, startMs: 0, endMs: 5}, {round: 1, startMs: 5, endMs: 4}]) === null);
ok("over-long rejects", sanitiseRoundBoundaries(Array.from({length: 21}, (_, i) => ({round: i, startMs: i, endMs: i + 1}))) === null);
ok("round out of range rejects", sanitiseRoundBoundaries([{round: 99, startMs: 0, endMs: 5}]) === null);

console.log(`roundBoundaries: ${n} checks run`);
