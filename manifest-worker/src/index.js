const MAX_URL_LENGTH = 2048;

const BUNDLE_ID_RE = /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*$/;
const VERSION_RE = /^[A-Za-z0-9._+-]{1,64}$/;
const IPA_PATH_RE = /^\/[A-Za-z0-9._-]{1,128}\.ipa$/;
function hasControl(str) {
  for (const ch of str) {
    const c = ch.codePointAt(0);
    if (c <= 0x1f || (c >= 0x7f && c <= 0x9f) || c === 0x2028 || c === 0x2029) return true;
  }
  return false;
}

function text(body, status, extra = {}) {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...extra,
    },
  });
}

function escapeXml(value) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function single(params, key) {
  const all = params.getAll(key);
  return all.length === 1 ? all[0] : null;
}

// Strict check of the raw string first, so URL-parser normalisation cannot hide tricks.
function validFetchUrl(raw) {
  const m = /^(https?):\/\/([^/?#]*)(\/[^?#]*)?$/.exec(raw);
  if (!m) return false;
  const am = /^(127\.0\.0\.1|localhost)(?::([0-9]{1,5}))?$/.exec(m[2]);
  if (!am) return false;
  if (am[2] !== undefined) {
    const port = Number(am[2]);
    if (port < 1 || port > 65535) return false;
  }
  if (!IPA_PATH_RE.test(m[3] || "")) return false;

  let url;
  try {
    url = new URL(raw);
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  if (url.username || url.password || url.search || url.hash) return false;
  if (url.hostname !== "127.0.0.1" && url.hostname !== "localhost") return false;
  return IPA_PATH_RE.test(url.pathname);
}

function validName(name) {
  const length = [...name].length;
  return length >= 1 && length <= 128 && !hasControl(name);
}

function buildPlist({ fetchurl, bundleid, version, name }) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>items</key>
	<array>
		<dict>
			<key>assets</key>
			<array>
				<dict>
					<key>kind</key>
					<string>software-package</string>
					<key>url</key>
					<string>${escapeXml(fetchurl)}</string>
				</dict>
			</array>
			<key>metadata</key>
			<dict>
				<key>bundle-identifier</key>
				<string>${escapeXml(bundleid)}</string>
				<key>bundle-version</key>
				<string>${escapeXml(version)}</string>
				<key>kind</key>
				<string>software</string>
				<key>title</key>
				<string>${escapeXml(name)}</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
`;
}

export function handle(request) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return text("method not allowed", 405, { Allow: "GET, HEAD" });
  }
  if (request.url.length > MAX_URL_LENGTH) return text("uri too long", 414);

  const url = new URL(request.url);
  if (url.pathname === "/") return text("ok", 200);
  if (url.pathname !== "/genPlist") return text("not found", 404);

  const p = url.searchParams;
  const bundleid = single(p, "bundleid");
  const name = single(p, "name");
  const version = single(p, "version");
  const fetchurl = single(p, "fetchurl");

  if (bundleid === null || name === null || version === null || fetchurl === null) {
    return text("bad request", 400);
  }
  if (bundleid.length > 255 || !BUNDLE_ID_RE.test(bundleid)) return text("bad request", 400);
  if (!VERSION_RE.test(version)) return text("bad request", 400);
  if (!validName(name)) return text("bad request", 400);
  if (!validFetchUrl(fetchurl)) return text("bad request", 400);

  return new Response(buildPlist({ fetchurl, bundleid, version, name }), {
    status: 200,
    headers: {
      "Content-Type": "application/xml; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

export default {
  fetch(request) {
    return handle(request);
  },
};
