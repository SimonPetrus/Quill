# quill-manifest

Cloudflare Worker that builds the iOS itms-services manifest plist for the Semi Local install.

`GET /genPlist?bundleid=&name=&version=&fetchurl=` returns the plist. `fetchurl` must point to the
device's own loopback server (`http(s)://127.0.0.1|localhost[:port]/<id>.ipa`); anything else gets 400.
No parameters are logged or stored.

Accepted values: `bundleid` letters, digits, `-`, `_` in dot-separated parts (max 255); `version` and `name`
any text up to 64 / 255 characters without control, bidi or XML non-characters; the whole request max 2048 characters.

- Test: `npm test` (Node 20+, no install needed)
- Deploy: `npm ci && npm run deploy` (wrangler is pinned in `package-lock.json`). The app points to
  `ManifestService.genPlistURL` in `Feather/Backend/Server/ServerInstaller+Compute.swift`; keep both in sync.
