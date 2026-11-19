import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const call = (qs, init) => worker.fetch(new Request("https://m.example/genPlist" + qs, init));
const q = (o) => "?" + new URLSearchParams(o).toString();
const good = {
  bundleid: "com.example.App",
  name: "My App",
  version: "1.2.3",
  fetchurl: "http://127.0.0.1:8080/abc-123.ipa",
};

test("valid request returns plist", async () => {
  const r = await call(q(good));
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-type"), "application/xml; charset=utf-8");
  assert.equal(r.headers.get("cache-control"), "no-store");
  assert.equal(r.headers.get("x-content-type-options"), "nosniff");
  const b = await r.text();
  assert.match(b, /<string>software-package<\/string>/);
  assert.match(b, /<string>http:\/\/127\.0\.0\.1:8080\/abc-123\.ipa<\/string>/);
  assert.match(b, /<key>bundle-identifier<\/key>\s*<string>com\.example\.App<\/string>/);
  assert.match(b, /<key>bundle-version<\/key>\s*<string>1\.2\.3<\/string>/);
  assert.match(b, /<key>title<\/key>\s*<string>My App<\/string>/);
});

test("name is xml-escaped, unicode allowed", async () => {
  const r = await call(q({ ...good, name: `A&B <"x"> 'y' Uygulama` }));
  assert.equal(r.status, 200);
  assert.match(await r.text(), /A&amp;B &lt;&quot;x&quot;&gt; &apos;y&apos; Uygulama/);
});

test("accepted fetchurl variants", async () => {
  for (const u of ["https://localhost/a.ipa", "http://localhost:65535/a.ipa", "http://127.0.0.1/a_b.c-d.ipa"]) {
    assert.equal((await call(q({ ...good, fetchurl: u }))).status, 200, u);
  }
});

test("fetchurl bypass attempts are rejected", async () => {
  const bad = [
    "http://LOCALHOST/a.ipa",
    "http://localhost./a.ipa",
    "http://127.0.0.1./a.ipa",
    "http://127.1/a.ipa",
    "http://[::1]/a.ipa",
    "http://[::ffff:127.0.0.1]/a.ipa",
    "http://127.0.0.1.nip.io/a.ipa",
    "http://localhost.evil.com/a.ipa",
    "http://a@evil.com/a.ipa",
    "http://127.0.0.1@evil.com/a.ipa",
    "http://127.0.0.1:80@evil.com/a.ipa",
    "http://user:pw@127.0.0.1/a.ipa",
    "http://127.0.0.1\\@evil.com/a.ipa",
    "ftp://127.0.0.1/a.ipa",
    "javascript:alert(1)",
    "//127.0.0.1/a.ipa",
    "http://127.0.0.1:0/a.ipa",
    "http://127.0.0.1:65536/a.ipa",
    "http://127.0.0.1:99999/a.ipa",
    "http://127.0.0.1/a.ipa?x=1",
    "http://127.0.0.1/a.ipa#f",
    "http://127.0.0.1/a.zip",
    "http://127.0.0.1/",
    "http://127.0.0.1/dir/a.ipa",
    "http://127.0.0.1/../a.ipa",
    "http://127.0.0.1/%2e%2e/a.ipa",
    "http://127.0.0.1/a%20b.ipa",
    "http://127.0.0.1/" + "a".repeat(129) + ".ipa",
    "http://0x7f.0.0.1/a.ipa",
    "http://2130706433/a.ipa",
    " http://127.0.0.1/a.ipa",
    "http://127.0.0.1/a.ipa\n",
    "http://0.0.0.0/a.ipa",
    "",
  ];
  for (const u of bad) {
    const r = await call(q({ ...good, fetchurl: u }));
    assert.equal(r.status, 400, JSON.stringify(u));
    assert.equal(await r.text(), "bad request");
  }
});

test("bundleid / version / name validation", async () => {
  const cases = [
    { bundleid: "bad id" },
    { bundleid: "a..b" },
    { bundleid: ".a" },
    { bundleid: "a." },
    { bundleid: "<x>" },
    { bundleid: "a".repeat(256) },
    { bundleid: "" },
    { version: "1 2" },
    { version: "" },
    { version: "1".repeat(65) },
    { version: "<1>" },
    { name: "" },
    { name: "x".repeat(129) },
    { name: "a\u0000b" },
    { name: "a\nb" },
    { name: "a\u007Fb" },
  ];
  for (const c of cases) {
    assert.equal((await call(q({ ...good, ...c }))).status, 400, JSON.stringify(c));
  }
  assert.equal((await call(q({ ...good, name: "x".repeat(128) }))).status, 200);
  assert.equal((await call(q({ ...good, name: "😀".repeat(128) }))).status, 200);
  assert.equal((await call(q({ ...good, version: "1.0.0-beta+5" }))).status, 200);
});

test("missing and duplicated parameters", async () => {
  for (const k of Object.keys(good)) {
    const o = { ...good };
    delete o[k];
    assert.equal((await call(q(o))).status, 400, k);
  }
  const dup = q(good) + "&fetchurl=" + encodeURIComponent("http://127.0.0.1/b.ipa");
  assert.equal((await call(dup)).status, 400);
  assert.equal((await call(q(good) + "&name=x")).status, 400);
});

test("routing, methods, url length", async () => {
  const root = await worker.fetch(new Request("https://m.example/"));
  assert.equal(root.status, 200);
  assert.equal(await root.text(), "ok");
  assert.equal((await worker.fetch(new Request("https://m.example/other"))).status, 404);
  assert.equal((await worker.fetch(new Request("https://m.example/genPlist/"))).status, 404);
  for (const m of ["POST", "PUT", "DELETE", "PATCH"]) {
    assert.equal((await call(q(good), { method: m })).status, 405, m);
  }
  assert.equal((await call(q(good), { method: "HEAD" })).status, 200);
  assert.equal((await call(q({ ...good, name: "x".repeat(3000) }))).status, 414);
});

// Mirrors ServerInstaller.externalServerLink: urlQueryAllowed, then alphanumerics-only encoding.
const urlQueryAllowed = (s) =>
  s.replace(/[^A-Za-z0-9\-._~!$&'()*+,;=:@\/?]/gu, (c) => encodeURIComponent(c));
const alnumOnly = (s) =>
  s.replace(/[^A-Za-z0-9]/g, (c) =>
    [...new TextEncoder().encode(c)].map((b) => "%" + b.toString(16).toUpperCase().padStart(2, "0")).join(""),
  );

test("end to end with Quill's real link shape", async () => {
  const app = { identifier: "com.example.App", name: "Quill Test", version: "2.0" };
  const payload = "http://127.0.0.1:61234/0F3A9C.ipa";
  const base = `https://quill-manifest.example.workers.dev/genPlist?bundleid=${app.identifier}&name=${app.name}&version=${app.version}&fetchurl=${payload}`;
  // iOS decodes the url= value once.
  const itms = `itms-services://?action=download-manifest&url=${alnumOnly(urlQueryAllowed(base))}`;
  const once = new URL(itms.replace("itms-services://", "https://x/")).searchParams.get("url");
  const r2 = await worker.fetch(new Request(once));
  assert.equal(r2.status, 200);
  const b = await r2.text();
  assert.match(b, /<string>http:\/\/127\.0\.0\.1:61234\/0F3A9C\.ipa<\/string>/);
  assert.match(b, /<string>Quill Test<\/string>/);
});
