const assert = require("assert");
const {shouldAutoFollow} = require("../founder");

let n = 0;
function t(name, fn) { fn(); n++; console.log("  ok  " + name); }

t("auto-follows when founder set and a different new account", () => {
  assert.strictEqual(shouldAutoFollow("founder1", "newUser2"), true);
});
t("no founder configured -> no auto-follow", () => {
  assert.strictEqual(shouldAutoFollow(null, "newUser2"), false);
  assert.strictEqual(shouldAutoFollow("", "newUser2"), false);
});
t("the founder's own account never auto-follows itself", () => {
  assert.strictEqual(shouldAutoFollow("founder1", "founder1"), false);
});
t("missing new uid -> no-op", () => {
  assert.strictEqual(shouldAutoFollow("founder1", ""), false);
  assert.strictEqual(shouldAutoFollow("founder1", null), false);
});

console.log(`\nfounder: ${n} passed`);
