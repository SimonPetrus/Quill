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

### Mach-O hardening (Quill, untrusted IPAs)
- `src/archo.cpp` `ZArchO::Init`: bounds checks for sizeofcmds, every load command (size >= 8,
  multiple of 4, inside sizeofcmds), segment section tables, `__info_plist`, encryption info and
  `LC_CODE_SIGNATURE` (dataoff inside the file, SuperBlob length clamped); 16-byte segment/section
  names compared with `strncmp`. Free space after the load commands is measured up to the first
  section's data (was: `__text` only, 0 when not found).
- `src/macho.cpp` `ZMachO::OpenFile`: fat header, arch table and every slice must lie inside the file.
- Dylib names (`ListDylibs`, `InjectDylib`, `RemoveDylibs`, `ChangeDylibPath`, `PrintInfo`) are read
  bounded by `cmdsize` (`ReadLoadCommandString`).
- `RemoveDylibs` rebuilds the command list without writing past sizeofcmds and returns `bool`
  (was a heap overflow with inconsistent cmdsize values).
- `ChangeDylibPath` writes at the real `name.offset`, clears the old name and requires room for the
  NUL terminator.
- `InjectDylib` refuses when there is no free space (it used to overwrite section data when the
  free space was 0); `ReallocCodeSignSpace` checks for room for a whole `LC_CODE_SIGNATURE`
  before editing the header.
- `s_uExecSegLimit` (static shared by all slices and files) is now the member `m_uExecSegLimit`.

### Paths and symbolic links (Quill)
- `src/bundle.cpp`: `CFBundleExecutable` must be a plain file name; the bundle executable must not
  be a symbolic link or resolve outside the app (`realpath` of the app folder, `m_strRealAppFolder`);
  Mach-O files are never signed through symbolic links; a symbolic link that resolves outside the
  app (or to nothing) fails sealing; a symbolic link at `_CodeSignature` or
  `_CodeSignature/CodeResources` is removed before CodeResources is written.
  Symbolic links inside the app are still sealed by their target's content (Apple's `symlink`
  entries are not implemented).
- `src/common/fs.cpp`: the `chmod(0755)` retry only applies to regular files (`lstat`), never to the
  target of a symbolic link.

### Entitlements (Quill)
- `src/openssl.cpp` `ZSignAsset::Init`: a custom entitlements file that can't be read, is empty or
  is not a plist dictionary fails signing (it used to fall back to the profile's entitlements);
  a binary plist is converted to XML for the entitlements slot.
- `src/signing.cpp` `ZSign::_DER` returns `bool`: INTEGER uses minimal two's complement (it wrote
  the value as the length, and 0 looped about 512 MB of output); real/date/data/null are refused
  instead of `assert`; `SlotBuildDerEntitlements` fails on unparsable entitlements and
  `ZArchO::BuildCodeSignature` fails when the main executable's entitlements have no DER form.
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
