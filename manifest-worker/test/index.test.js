import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const call = (qs, init) => worker.fetch(new Request("https://m.example/genPlist" + qs, init));
const q = (o) => "?" + new URLSearchParams(o).toString();
const status = async (o) => (await call(q({ ...good, ...o }))).status;
const hex = (s) => [...s].map((c) => "U+" + c.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")).join(" ");
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
    assert.equal(await status({ fetchurl: u }), 200, u);
  }
});

test("accepted odd fetchurl shapes only ever point to loopback", async () => {
  for (const u of ["http://127.0.0.1:00080/a.ipa", "http://localhost:1/..ipa", "http://127.0.0.1/-.ipa"]) {
    assert.equal(await status({ fetchurl: u }), 200, u);
    const h = new URL(u).hostname;
    assert.ok(h === "127.0.0.1" || h === "localhost", u);
  }
});

test("double-encoded fetchurl stays encoded and is rejected", async () => {
  const r = await call(`?bundleid=a.b&name=x&version=1&fetchurl=http%253A%252F%252Fevil.com%252Fa.ipa`);
  assert.equal(r.status, 400);
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
    // Private / LAN addresses stay rejected (Quill always sends loopback).
    "http://192.168.1.5:8080/a.ipa",
    "http://10.0.0.2:8080/a.ipa",
    "http://172.16.0.1:8080/a.ipa",
    "http://169.254.1.1/a.ipa",
    // From the independent review.
    "HTTP://127.0.0.1/a.ipa",
    "http://Localhost/a.ipa",
    "http://127.0.0.1\t/a.ipa",
    "http://127.0.0.1/a\t.ipa",
    "http://127.0.0.1/a.ipa\t",
    "http://127.0.0.1/a\n.ipa",
    "http://127.0.0%2e1/a.ipa",
    "http://127%2e0.0.1/a.ipa",
    "http://１２７.0.0.1/a.ipa",
    "http://ⓛocalhost/a.ipa",
    "http://xn--localhost-/a.ipa",
    "http://0x7f000001/a.ipa",
    "http://0177.0.0.1/a.ipa",
    "http://127.000.000.001/a.ipa",
    "http://[0:0:0:0:0:0:0:1]/a.ipa",
    "http://127.0.0.1:/a.ipa",
    "http://localhost:8080:9/a.ipa",
    "http://127.0.0.1:8080\\evil.com/a.ipa",
    "http:\\\\127.0.0.1\\a.ipa",
    "http:/127.0.0.1/a.ipa",
    "http:127.0.0.1/a.ipa",
    "https://127.0.0.1@/a.ipa",
    "http://127.0.0.1/a.ipa/",
    "http://127.0.0.1/a.IPA",
    "http://127.0.0.1/a.ipa;x",
    "http://127.0.0.1/%61.ipa",
    "http://127.0.0.1/a.ipa%00",
    "http://127.0.0.1/a.ipa?",
    "http://127.0.0.1/a.ipa#",
    "http://127.0.0.1/a.ipa%3Fx",
    "http://evil.com/127.0.0.1/a.ipa",
    "http://evil.com#@127.0.0.1/a.ipa",
    "‮http://127.0.0.1/a.ipa",
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
    { bundleid: "a_." },
    { bundleid: "<x>" },
    { bundleid: "a".repeat(256) },
    { bundleid: "" },
    { version: "" },
    { version: "1".repeat(65) },
    { version: "1\n2" },
    { version: "1\u0000" },
    { version: "1 " },
    { name: "" },
    { name: "x".repeat(256) },
    { name: "a\u0000b" },
    { name: "a\nb" },
    { name: "a\tb" },
    { name: "a\u007Fb" },
    { name: "a\u0085b" },
    { name: "a b" },
  ];
  for (const c of cases) {
    assert.equal(await status(c), 400, JSON.stringify(c));
  }
  assert.equal(await status({ name: "x".repeat(255) }), 200);
  assert.equal(await status({ name: "\u{1F600}".repeat(255) }), 414); // 255 emoji exceed the 2048 URL limit
  assert.equal(await status({ name: "\u{1F600}".repeat(128) }), 200);
  assert.equal(await status({ version: "1.0.0-beta+5" }), 200);
  assert.equal(await status({ version: "1".repeat(64) }), 200);
});

test("real-world version, bundle id and name values are accepted", async () => {
  for (const version of ["1.0 (5)", "2.0 beta", "1 2", "v3.1-rc.2 [build 7]", "2024.11.19", "١٫٢"]) {
    assert.equal(await status({ version }), 200, version);
  }
  for (const bundleid of ["com.foo_bar.app", "_a._b", "com.Example-1.App_2"]) {
    assert.equal(await status({ bundleid }), 200, bundleid);
  }
  assert.equal(await status({ name: "ğ".repeat(255) }), 200);
  const r = await call(q({ ...good, version: `<1> & "2"` }));
  assert.equal(r.status, 200);
  assert.match(await r.text(), /<key>bundle-version<\/key>\s*<string>&lt;1&gt; &amp; &quot;2&quot;<\/string>/);
});

test("XML 1.0 non-characters U+FFFE/U+FFFF are rejected", async () => {
  for (const ch of ["￾", "￿"]) {
    assert.equal(await status({ name: "a" + ch }), 400, "name " + hex(ch));
    assert.equal(await status({ version: "1" + ch }), 400, "version " + hex(ch));
  }
});

test("bidi control characters are rejected in name and version", async () => {
  const bidi = ["‎", "‏", "‪", "‫", "‬", "‭", "‮", "⁦", "⁧", "⁨", "⁩"];
  for (const ch of bidi) {
    assert.equal(await status({ name: "Update" + ch + "ppa.exe" }), 400, "name " + hex(ch));
    assert.equal(await status({ version: "1" + ch }), 400, "version " + hex(ch));
  }
  // Neighbouring characters stay allowed: zero width joiner inside an emoji sequence, right-to-left text itself.
  assert.equal(await status({ name: "\u{1F469}‍\u{1F4BB} Dev" }), 200);
  assert.equal(await status({ name: "مرحبا" }), 200);
});

test("invalid UTF-8 / lone surrogates arrive as U+FFFD and are allowed", async () => {
  const r = await call(`?bundleid=a.b&name=%ED%A0%80x&version=1&fetchurl=${encodeURIComponent(good.fetchurl)}`);
  assert.equal(r.status, 200);
  const b = await r.text();
  assert.ok(b.includes("<string>���x</string>") || b.includes("�x</string>"));
  assert.ok(!/[\uD800-\uDFFF]/.test(b));
});

test("XML structure cannot be broken through name or version", async () => {
  const evil = `]]></string><key>x</key><string>&#x26;<!--`;
  for (const field of ["name", "version"]) {
    const r = await call(q({ ...good, [field]: evil }));
    assert.equal(r.status, 200, field);
    const b = await r.text();
    assert.equal((b.match(/<string>/g) || []).length, 6, field);
    assert.equal((b.match(/<\/string>/g) || []).length, 6, field);
    assert.equal((b.match(/<key>/g) || []).length, 9, field);
    assert.ok(!b.includes("]]>"), field);
    assert.ok(!b.includes("<!--"), field);
  }
});

test("error bodies never reflect input", async () => {
  const evil = "<script>alert(1)</script>";
  const paths = [
    `/genPlist?name=${evil}`,
    `/${evil}`,
    `/genPlist${q({ ...good, fetchurl: evil })}`,
    `/genPlist${q({ ...good, version: "1\n" + evil })}`,
    `/genPlist${q({ ...good, name: evil + "‮" })}`,
  ];
  for (const p of paths) {
    const r = await worker.fetch(new Request("https://m.example" + p));
    assert.notEqual(r.status, 200, p);
    const t = await r.text();
    assert.ok(!t.includes("script"), p);
    assert.equal(r.headers.get("content-type"), "text/plain; charset=utf-8");
    assert.equal(r.headers.get("access-control-allow-origin"), null);
  }
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
  assert.equal(await status({ name: "x".repeat(3000) }), 414);
  assert.equal((await call(q(good) + "&x=1".repeat(600))).status, 414);
  assert.equal((await call(q(good) + "&x=1".repeat(200))).status, 200); // unknown extra params are ignored
});

// Mirrors ServerInstaller.externalServerLink: each value is encoded on its own (only unreserved characters
// stay), then the whole link is encoded alphanumerics-only for the itms-services url= value. The fetchurl is
// always ServerInstaller.externalPayloadEndpoint, i.e. http://127.0.0.1:<port>/<UUID>.ipa, never sni().
const strictEnc = (s) =>
  [...new TextEncoder().encode(s)]
    .map((b) => (b < 128 && /[A-Za-z0-9\-._~]/.test(String.fromCharCode(b)) ? String.fromCharCode(b) : "%" + b.toString(16).toUpperCase().padStart(2, "0")))
    .join("");
const alnumOnly = (s) =>
  s.replace(/[^A-Za-z0-9]/g, (c) =>
    [...new TextEncoder().encode(c)].map((b) => "%" + b.toString(16).toUpperCase().padStart(2, "0")).join(""),
  );
const SERVICE = "https://quill-manifest.example.workers.dev/genPlist";
const innerLink = (app, payload) =>
  `${SERVICE}?bundleid=${strictEnc(app.identifier)}&name=${strictEnc(app.name)}&version=${strictEnc(app.version)}&fetchurl=${strictEnc(payload)}`;
const quillLink = (app, port, id) =>
  `itms-services://?action=download-manifest&url=${alnumOnly(innerLink(app, `http://127.0.0.1:${port}/${id}.ipa`))}`;
// iOS decodes the url= value of itms-services once.
const decodeOnce = (link) => new URL(link.replace("itms-services://", "https://x/")).searchParams.get("url");

test("end to end with strict per-value encoding and tricky names", async () => {
  const names = ["A&B", "x=y", "1+1", "C#", "what?", "two  spaces", "Çalışkan Üğür İş", "Game \u{1F3AE} Pro", "%41 100%", "a&fetchurl=http://evil.com/x.ipa"];
  for (const name of names) {
    const once = decodeOnce(quillLink({ identifier: "com.example.App", name, version: "1.0+5" }, 61234, "0F3A9C"));
    const r = await worker.fetch(new Request(once));
    assert.equal(r.status, 200, name);
    const b = await r.text();
    assert.ok(b.includes(`<string>${name.replace(/&/g, "&amp;")}</string>`), name);
    assert.match(b, /<string>1\.0\+5<\/string>/);
    assert.match(b, /<string>http:\/\/127\.0\.0\.1:61234\/0F3A9C\.ipa<\/string>/);
  }
});

test("end to end: Quill link shape with real-world metadata", async () => {
  const id = "9B2E6F1C-3A4D-4E5F-8A9B-0C1D2E3F4A5B"; // Swift UUID description
  const apps = [
    { identifier: "com.foo_bar.app", name: "Quill Test", version: "1.0 (5)" },
    { identifier: "com.example.App", name: "My App: Pro & More", version: "2.0 beta" },
    { identifier: "com.example.App", name: "ğ".repeat(255), version: "3" },
  ];
  for (const app of apps) {
    for (const port of [4000, 8000]) {
      const once = decodeOnce(quillLink(app, port, id));
      assert.ok(once.startsWith(SERVICE + "?"));
      const r = await worker.fetch(new Request(once));
      assert.equal(r.status, 200, JSON.stringify(app));
      const b = await r.text();
      assert.ok(b.includes(`<string>http://127.0.0.1:${port}/${id}.ipa</string>`));
      assert.ok(b.includes(`<string>${app.identifier}</string>`));
      assert.ok(b.includes(`<string>${app.version}</string>`));
      assert.ok(b.includes(`<string>${app.name.replace(/&/g, "&amp;")}</string>`));
    }
  }
});

test("a LAN fetchurl (what sni() returns with IP fix off) is still rejected", async () => {
  const app = { identifier: "com.example.App", name: "x", version: "1" };
  assert.equal((await worker.fetch(new Request(innerLink(app, "http://192.168.1.20:4321/ABC.ipa")))).status, 400);
});
