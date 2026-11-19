# quill-manifest

Cloudflare Worker that builds the iOS itms-services manifest plist for the Semi Local install.

`GET /genPlist?bundleid=&name=&version=&fetchurl=` returns the plist. `fetchurl` must point to the
device's own loopback server (`http(s)://127.0.0.1|localhost[:port]/<id>.ipa`); anything else gets 400.
No parameters are logged or stored.

- Test: `npm test` (Node 20+, no install needed)
- Deploy: `npm install && npm run deploy`, then put the resulting workers.dev URL into `ManifestService.genPlistURL` in the app.
