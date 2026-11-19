/**
 * Clips start on round 1 (2026-11-19). Plain `node test/headCut.test.js`.
 */
const assert = require("node:assert/strict");
const {applyHeadCut, buildTrimFilters, remapCues} = require("../trimSilence");
const {firstTurnOffsetSec} = require("../clipStrip");

let n = 0;
function check(name, fn) {
  fn();
  n++;
  console.log(`ok - ${name}`);
}

check("no plan + cut = one interval from the cut", () => {
  assert.deepEqual(applyHeadCut(null, 50, 4.7), [{start: 4.7, end: 50}]);
});

check("existing dead-air plan is clipped, not replaced", () => {
  const keeps = [{start: 0, end: 10}, {start: 12, end: 30}, {start: 31, end: 50}];
  assert.deepEqual(applyHeadCut(keeps, 50, 4.7),
      [{start: 4.7, end: 10}, {start: 12, end: 30}, {start: 31, end: 50}]);
  assert.deepEqual(applyHeadCut(keeps, 50, 11),
      [{start: 12, end: 30}, {start: 31, end: 50}]);
});

check("unusable cut leaves the plan alone", () => {
  assert.deepEqual(applyHeadCut(null, 50, 0), [{start: 0, end: 50}]);
  assert.deepEqual(applyHeadCut(null, 50, 49.5), [{start: 0, end: 50}]);
  assert.deepEqual(applyHeadCut(null, 50, NaN), [{start: 0, end: 50}]);
});

check("the cut produces real trim filters and moves captions", () => {
  const keeps = applyHeadCut(null, 50, 4.7);
  assert.ok(buildTrimFilters(keeps, 50));
  const cues = remapCues([{start: 2, end: 3, text: "a"},
    {start: 6, end: 7, text: "b"}], keeps);
  assert.equal(cues.length, 1);
  assert.equal(cues[0].text, "b");
  assert.ok(Math.abs(cues[0].start - 1.3) < 1e-9);
});

check("first turn = first live, not-over event", () => {
  const log = {events: [
    {t: 1000, f: null, n: 0, o: 0, r: {}},
    {t: 5700, f: "A", n: 1, o: 0, r: {}},
    {t: 9000, f: null, n: 6, o: 1, r: {}},
  ]};
  assert.equal(firstTurnOffsetSec(log, 1000), 4.7);
  assert.equal(firstTurnOffsetSec({events: []}, 0), null);
  assert.equal(firstTurnOffsetSec(null, 0), null);
});

console.log(`\n${n} checks passed`);
