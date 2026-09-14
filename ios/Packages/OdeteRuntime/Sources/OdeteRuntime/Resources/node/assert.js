__nodeDefine("assert", (module, exports, require) => {
  class AssertionError extends Error { constructor(o) { super(o.message || `${require("util").inspect(o.actual)} ${o.operator} ${require("util").inspect(o.expected)}`); this.name = "AssertionError"; this.code = "ERR_ASSERTION"; Object.assign(this, o); } }
  const fail = (o) => { throw new AssertionError(o); };
  function deepEq(a, b, strict) { if (strict ? Object.is(a, b) : a == b) return true; if (typeof a !== "object" || typeof b !== "object" || !a || !b) return false; if (strict && Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false; if (a instanceof Date && b instanceof Date) return a.getTime() === b.getTime(); if (a instanceof RegExp && b instanceof RegExp) return String(a) === String(b); if (ArrayBuffer.isView(a) && ArrayBuffer.isView(b)) { if (a.length !== b.length) return false; for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false; return true; } if (a instanceof Map && b instanceof Map) { if (a.size !== b.size) return false; for (const [k, v] of a) if (!b.has(k) || !deepEq(v, b.get(k), strict)) return false; return true; } if (a instanceof Set && b instanceof Set) { if (a.size !== b.size) return false; for (const v of a) if (!b.has(v)) return false; return true; } const ka = Object.keys(a), kb = Object.keys(b); if (ka.length !== kb.length) return false; return ka.every((k) => kb.includes(k) && deepEq(a[k], b[k], strict)); }
  const assert = (v, m) => { if (!v) fail({ message: m || "The expression evaluated to a falsy value", actual: v, expected: true, operator: "==" }); };
  Object.assign(assert, {
    AssertionError, ok: assert, fail: (m) => fail({ message: m instanceof Error ? m.message : m || "Failed" }),
    equal: (a, b, m) => { if (a != b) fail({ message: m, actual: a, expected: b, operator: "==" }); }, notEqual: (a, b, m) => { if (a == b) fail({ message: m, actual: a, expected: b, operator: "!=" }); },
    strictEqual: (a, b, m) => { if (!Object.is(a, b)) fail({ message: m, actual: a, expected: b, operator: "strictEqual" }); }, notStrictEqual: (a, b, m) => { if (Object.is(a, b)) fail({ message: m, actual: a, expected: b, operator: "notStrictEqual" }); },
    deepEqual: (a, b, m) => { if (!deepEq(a, b, false)) fail({ message: m, actual: a, expected: b, operator: "deepEqual" }); }, deepStrictEqual: (a, b, m) => { if (!deepEq(a, b, true)) fail({ message: m, actual: a, expected: b, operator: "deepStrictEqual" }); },
    notDeepEqual: (a, b, m) => { if (deepEq(a, b, false)) fail({ message: m, actual: a, expected: b, operator: "notDeepEqual" }); }, notDeepStrictEqual: (a, b, m) => { if (deepEq(a, b, true)) fail({ message: m, actual: a, expected: b, operator: "notDeepStrictEqual" }); },
    throws: (fn, exp, m) => { try { fn(); } catch (e) { if (exp instanceof RegExp && !exp.test(String(e && e.message || e))) fail({ message: m || "wrong error" }); if (typeof exp === "function" && exp.prototype && !(e instanceof exp)) fail({ message: m || "wrong error type" }); return; } fail({ message: typeof exp === "string" ? exp : m || "Missing expected exception" }); },
    doesNotThrow: (fn, m) => { try { fn(); } catch (e) { fail({ message: m || "Got unwanted exception: " + e.message }); } },
    rejects: async (p, exp, m) => { try { await (typeof p === "function" ? p() : p); } catch (e) { if (exp instanceof RegExp && !exp.test(String(e && e.message || e))) fail({ message: m || "wrong error" }); return; } fail({ message: m || "Missing expected rejection" }); },
    doesNotReject: async (p, m) => { try { await (typeof p === "function" ? p() : p); } catch (e) { fail({ message: m || "Got unwanted rejection" }); } },
    match: (s, re, m) => { if (!re.test(s)) fail({ message: m || `${s} does not match ${re}` }); }, doesNotMatch: (s, re, m) => { if (re.test(s)) fail({ message: m || `${s} matches ${re}` }); },
    ifError: (e) => { if (e != null) throw e; },
  });
  assert.strict = assert;
  module.exports = assert;
});
__nodeDefine("assert/strict", (module, exports, require) => { module.exports = require("assert"); });
