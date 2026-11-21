# The Flutter engine

Veshell links a pinned Flutter engine revision and ships its embedder runtime.

**Engine releases do not live in the Veshell repository.** They are built and
published by the dedicated engine repository:

> `free-explorers/flutter-engine`

It builds upstream's engine at the pinned revision, with Veshell's engine
patches (its `patches/`) applied, for x86_64 and arm64 in the release, debug
and profile modes. It uses the Debian bullseye sysroot so the result runs on
Debian, Fedora and Arch. The Nix engine build in `flutter-engine-nix` applies
the same patch files, but its outputs are patched to the Nix loader.

The engine is not upstream's, so every release is named after the set of
patches too (`PATCHSET` there, `flutter_engine_patchset` in Veshell's
`Cargo.toml`):

```
linux-engine-sdk-<mode>-<arch>-<revision>-<patchset>.tar.gz
linux-engine-sdk-<mode>-<arch>-<revision>-<patchset>.tar.gz.sha256
```

The tarball's `flutter/engine/src/out/<out>/engine-sdk/{include,lib}` holds
`flutter_embedder.h` and `libflutter_engine.so`, which `scripts/build-veshell.sh`
and the project's dev build read. The recipes only consume
`release-x86_64`.

## Moving to a new engine

1. Veshell's **Bump Flutter Version** workflow dispatches **Engine Release** in
   `free-explorers/flutter-engine` with the new revision, and the Nix build.
   Changing the patches means bumping `PATCHSET` there and Veshell's pin
   together.
2. The engine URL and hash are app-owned: `nix/flutter-artifacts.json` in the
   Veshell checkout holds them, the bump writes the URL, and **Complete Flutter
   Bump** fills the sha256 once the release exists. `prepare-release.py`
   mirrors them into `release.json` and re-renders. To verify by hand:

   ```sh
   VESHELL_SRC=/path/to/veshell python3 scripts/render-recipes.py --check --veshell-src "$VESHELL_SRC"
   ```

3. Dev builds (`cargo build`) download the matching release from
   `free-explorers/flutter-engine` themselves (`extra/build/flutter_engine_lib.rs`);
   `VESHELL_ENGINE_REPO` points them elsewhere.
