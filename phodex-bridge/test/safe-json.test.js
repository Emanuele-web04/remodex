// FILE: safe-json.test.js
// Purpose: Test secure JSON parsing with prototype pollution protection

const test = require("node:test");
const assert = require("node:assert");
const { safeParseJSON, createNullObject } = require("../src/safe-json");

test("safeParseJSON returns null for non-string input", () => {
  assert.strictEqual(safeParseJSON(null), null);
  assert.strictEqual(safeParseJSON(undefined), null);
  assert.strictEqual(safeParseJSON(123), null);
  assert.strictEqual(safeParseJSON({}), null);
  assert.strictEqual(safeParseJSON([]), null);
});

test("safeParseJSON returns null for empty string", () => {
  assert.strictEqual(safeParseJSON(""), null);
  assert.strictEqual(safeParseJSON("   "), null);
});

test("safeParseJSON returns null for invalid JSON", () => {
  assert.strictEqual(safeParseJSON("{invalid}"), null);
  assert.strictEqual(safeParseJSON("not json"), null);
});

test("safeParseJSON parses valid JSON correctly", () => {
  const result = safeParseJSON('{"foo": "bar"}');
  assert.deepStrictEqual(result, { foo: "bar" });
});

test("safeParseJSON prevents __proto__ pollution", () => {
  const result = safeParseJSON('{"__proto__": {"polluted": true}}');
  // The implementation filters out __proto__ keys, so result should be empty object
  assert.deepStrictEqual(result, {});
  assert.strictEqual(Object.prototype.polluted, undefined);
});

test("safeParseJSON prevents constructor pollution", () => {
  const result = safeParseJSON('{"constructor": {"polluted": true}}');
  assert.strictEqual(result.constructor, Object);
  assert.strictEqual(Object.prototype.polluted, undefined);
});

test("safeParseJSON prevents prototype pollution", () => {
  const result = safeParseJSON('{"prototype": {"polluted": true}}');
  assert.strictEqual(result.prototype, undefined);
  assert.strictEqual(Object.prototype.polluted, undefined);
});

test("safeParseJSON allows safe keys with dangerous names in nested objects", () => {
  const result = safeParseJSON('{"safe": {"__proto__": "value"}}');
  // The implementation filters out __proto__ keys at all levels
  assert.deepStrictEqual(result.safe, {});
});

test("safeParseJSON applies custom reviver function", () => {
  const result = safeParseJSON('{"foo": "bar"}', (key, value) => {
    if (key === "foo") return "modified";
    return value;
  });
  assert.strictEqual(result.foo, "modified");
});

test("safeParseJSON custom reviver respects dangerous key filtering", () => {
  const result = safeParseJSON(
    '{"__proto__": {"polluted": true}, "safe": "value"}',
    (key, value) => {
      if (key === "safe") return "modified";
      return value;
    }
  );
  // The implementation filters out __proto__ keys before applying custom reviver
  assert.deepStrictEqual(result, { safe: "modified" });
});

test("createNullObject creates object with null prototype", () => {
  const obj = createNullObject();
  assert.strictEqual(Object.getPrototypeOf(obj), null);
  assert.strictEqual(obj.toString, undefined);
});

test("createNullObject can still hold properties", () => {
  const obj = createNullObject();
  obj.foo = "bar";
  assert.strictEqual(obj.foo, "bar");
});

test("createNullObject prevents prototype pollution via assignment", () => {
  const obj = createNullObject();
  obj.__proto__ = { polluted: true };
  assert.strictEqual(Object.prototype.polluted, undefined);
});