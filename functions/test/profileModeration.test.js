const assert = require("assert");
const {blockedFields, textFieldsOf} = require("../profileModeration");
let passed = 0;
function test(name, fn) { fn(); passed++; }
test("only typed text is checked, never URLs", () => {
  const t = textFieldsOf({name: "x", introVideoUrl: "https://a", photoUrls: ["a"], facePhotoUrl: "b"});
  assert.deepStrictEqual(Object.keys(t), ["name"]);
});
test("the beta tester's profile is caught field by field", () => {
  assert.deepStrictEqual(blockedFields({
    name: "Gay Nigger", ammoText: "I fuck little boys in the ass", hometown: "",
  }).sort(), ["ammoText", "name"]);
});
test("a normal roast-app profile passes", () => {
  assert.deepStrictEqual(blockedFields({name: "Jim", ammoText: "fuck around and find out",
    profession: "Line cook", hometown: "Omaha, NE"}), []);
});
console.log(`profileModeration: ${passed} checks passed`);
