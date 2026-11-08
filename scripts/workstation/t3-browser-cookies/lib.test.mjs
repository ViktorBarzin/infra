// Run: node --test scripts/workstation/t3-browser-cookies/
import { test } from "node:test";
import assert from "node:assert/strict";
import { cookieKey, pushable, changedSince, toInject, rendererCount, baselineOf } from "./lib.mjs";

const NOW = 1_800_000_000;
const ck = (over = {}) => ({
  name: "sid", value: "v", domain: ".example.com", path: "/", expires: NOW + 86400,
  httpOnly: true, secure: true, sameSite: "Lax", ...over,
});

test("pushable keeps persistent cookies for outside sites only", () => {
  const cookies = [
    ck(),
    ck({ name: "session", expires: -1 }),
    ck({ name: "old", expires: NOW - 1 }),
    ck({ name: "home", domain: ".viktorbarzin.me" }),
    ck({ name: "sub", domain: "t3.viktorbarzin.me" }),
    ck({ name: "lan", domain: "nas.viktorbarzin.lan" }),
    ck({ name: "ip", domain: "10.0.10.10" }),
    ck({ name: "local", domain: "localhost" }),
  ];
  assert.deepEqual(pushable(cookies, NOW).map((c) => c.name), ["sid"]);
});

test("cookieKey separates partitioned cookies", () => {
  assert.notEqual(cookieKey(ck()), cookieKey(ck({ partitionKey: "https://p.example" })));
});

test("changedSince returns only cookies whose value or expiry moved", () => {
  const base = baselineOf([ck(), ck({ name: "b" })]);
  const now = [ck(), ck({ name: "b", value: "new" }), ck({ name: "c" })];
  assert.deepEqual(changedSince(now, base).map((c) => c.name), ["b", "c"]);
});

test("toInject adds missing cookies and replaces only with a later expiry", () => {
  const t3 = [ck({ name: "same" }), ck({ name: "older", expires: NOW + 10 }), ck({ name: "newer", expires: NOW + 999999 })];
  const hub = [
    ck({ name: "same" }),
    ck({ name: "older", expires: NOW + 500 }),
    ck({ name: "newer", expires: NOW + 500 }),
    ck({ name: "missing" }),
    ck({ name: "expired", expires: NOW - 5 }),
  ];
  assert.deepEqual(toInject(hub, t3, NOW).map((c) => c.name).sort(), ["missing", "older"]);
});

test("toInject strips Playwright's internal partition flag", () => {
  const [c] = toInject([ck({ partitionKey: "https://p.example", _crHasCrossSiteAncestor: false })], [], NOW);
  assert.equal("_crHasCrossSiteAncestor" in c, false);
  assert.equal(c.partitionKey, "https://p.example");
});

test("rendererCount counts only renderer processes", () => {
  const args = [
    "/x/chrome-headless-shell --type=zygote",
    "/x/chrome-headless-shell --type=renderer --foo",
    "/x/chrome-headless-shell --type=gpu-process",
    "/x/chrome-headless-shell --type=renderer",
  ];
  assert.equal(rendererCount(args), 2);
});
