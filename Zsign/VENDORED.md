# Vendored: Zsign-Package

- Source: https://github.com/khcrysalis/Zsign-Package
- Branch: `package`
- Commit: c4ba9da4283031c07efa03bce42c4b8602d22e73 (c4ba9da)
- Vendored on: 2026-11-10
- License: MIT (see `LICENSE`, copyright zhlynn)

Previously a git submodule; now a normal directory so Quill can carry local patches.

## Omitted from upstream
- `build/` (entire directory, ~69 MB): Windows VS2022 OpenSSL .lib files and headers, sln/vcxproj, getopt/iconv sources, linux/macos Makefiles. None of it is used by `Package.swift`. Listed in the root `.gitignore` so it is not re-added from an old local submodule checkout.

## Local changes
The vendoring commit is an unmodified copy. Patches applied afterwards:

### Strip empty entitlements slot from non-main binaries (upstream #616)
- `src/archo.cpp` (`ZArchO::BuildCodeSignature`): the entitlements slot now gets the real
  entitlements only for MH_EXECUTE; dylibs/frameworks get no entitlements slot (previously an
  empty `<dict/>` plist), matching Apple `codesign`. Removed the unused `strEmptyEntitlements`.
  The special-slot hash for an absent entitlements slot is the zero hash (already handled in
  `SlotBuildCodeDirectory`, `src/signing.cpp`).
- `src/archo.cpp`: added `size() > 8` guards before `strEntitlementsSlot.data() + 8` (get-task-allow
  search and the debug dump) so an empty slot is safe.
