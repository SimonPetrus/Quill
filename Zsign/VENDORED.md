# Vendored: Zsign-Package

- Source: https://github.com/khcrysalis/Zsign-Package
- Branch: `package`
- Commit: c4ba9da4283031c07efa03bce42c4b8602d22e73 (c4ba9da)
- Vendored on: 2026-11-10
- License: MIT (see `LICENSE`, copyright zhlynn)

Previously a git submodule; now a normal directory so Quill can carry local patches.

## Upstream sync (`src/` only)
- Zsign-Package c4ba9da is based on zhlynn/zsign 28a6421 (merged in Zsign-Package 570d292).
- `src/` was then three-way merged with https://github.com/zhlynn/zsign up to
  **9299685** (2026-10-20, "fix: fail instead of sealing an unreadable file as empty (#413)"),
  29 upstream commits. Notable fixes picked up: Apple-canonical DER entitlements (fe1750d),
  execSegFlags / CDHashes (a98b1ce), CMS and CodeDirectory build errors are no longer
  swallowed (2d0b08b, 3425554), WWDR G2-G8 intermediates + p12 CA chain (6c1870f, 57e6463),
  ASN1 double free (132f45b), OpenSSL 4 accessors (c39607e), unreadable files fail sealing
  (9299685), multi-profile write order (e803f87), json/base64 merge (614caa8).
- `swift/`, `Package.swift` and `src/include/` are Zsign-Package/Quill code and were not synced.
- `src/common/base64.{h,cpp}` were removed upstream (moved into `json.{h,cpp}`) and dropped
  from `Package.swift`.
- Not taken from upstream: the removal of the `chmod` fallback in `src/common/fs.cpp`
  (e6e7aa7); open PR #415 (ExtensionKit; Quill does this in Swift, `SigningHandler.swift`).
- Not compiled by `Package.swift` (synced only so future diffs stay small): `src/zsign.cpp`,
  `src/common/archive.cpp`, `src/metadata.cpp`, `src/certcheck.cpp`.

## Omitted from upstream
- `build/` (entire directory, ~69 MB): Windows VS2022 OpenSSL .lib files and headers, sln/vcxproj, getopt/iconv sources, linux/macos Makefiles. None of it is used by `Package.swift`. Listed in the root `.gitignore` so it is not re-added from an old local submodule checkout.

## Local changes (difference to zhlynn/zsign 9299685 in `src/`)
Keep these when syncing with upstream again.

### From Zsign-Package
- `src/archo.cpp`, `src/archo.h`, `src/macho.cpp`, `src/macho.h`: `ListDylibs`, `ChangeDylibPath`,
  `ZMachO::CheckSignature` / `ZArchO::IsSigned` (used by the Swift wrapper).
- `src/bundle.cpp`, `src/bundle.h`: Zsign-Package's iOS patches were reworked by Quill:
  - `bRemoveProvision` has the upstream meaning again (true = do not embed the profile); the
    Zsign-Package inversion plus upstream's removal in `GenerateCodeResources` had dropped
    `embedded.mobileprovision` from every signed app. The profile is written only when it is
    kept; `GetNodeChangedFiles` has the upstream signature.
  - Signing is strict again for loadable code: a nested executable/dylib/bundle that can't be
    signed fails the whole signing (other Mach-O types only warn); an app or app extension whose
    executable can't be parsed fails; a framework without a valid executable is still skipped.
  - `ZMachO::IsLoadableCode` (`src/macho.cpp`, `src/macho.h`) supports the above.
- `src/common/mach-o.h`: `#ifndef _H_CSCOMMON` guard around `eSecRequirementType`
  (Xcode 27 SDK clash).
- `src/openssl.h`: `m_evpPKey`, `m_x509Cert`, `m_caCerts` are `public` (`swift/zsign.mm`
  `checkCert` reads the certificate).
- `src/common/fs.cpp` (`ZFile::MapFile`): `chmod(0755)` and retry when `open` fails
  (files extracted on iOS without permissions). Upstream removed it in e6e7aa7; Quill keeps it.
- `src/common/util.h`: includes `TargetConditionals.h` on Apple platforms.
- `src/common/log.h`, `src/common/log.cpp` (Quill): `ZLog::GetFirstError` / `ClearFirstError`
  keep the first error logged on the thread, so `swift/zsign.mm` (`ZsignFirstError`) can show
  why signing failed.
- `src/include/ZSign.h`: umbrella header for SwiftPM.

### Strip empty entitlements slot from non-main binaries (upstream #616)
- `src/archo.cpp` (`ZArchO::BuildCodeSignature`): the entitlements slot now gets the real
  entitlements only for MH_EXECUTE; dylibs/frameworks get no entitlements slot (previously an
  empty `<dict/>` plist), matching Apple `codesign`. Removed the unused `strEmptyEntitlements`.
  The special-slot hash for an absent entitlements slot is the zero hash (already handled in
  `SlotBuildCodeDirectory`, `src/signing.cpp`).
- `src/archo.cpp`: added `size() > 8` guards before `strEntitlementsSlot.data() + 8` (get-task-allow
  search and the debug dump) so an empty slot is safe.
