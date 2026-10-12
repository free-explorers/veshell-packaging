# The Flutter engine

Veshell links a pinned Flutter engine revision and ships its embedder runtime.

**Engine releases do not live in the Veshell repository.** They are built and
published by the dedicated engine repository:

> `free-explorers/flutter-engine`

That repository is a fork of
[meta-flutter/flutter-engine](https://github.com/meta-flutter/flutter-engine)
with an added GitHub-hosted build (`build-engine.sh` and
`.github/workflows/engine-release.yml`) that produces a portable Linux x86_64
SDK. It uses the Debian bullseye sysroot so the result runs on Debian and
Fedora — unlike the Nix engine build in `flutter-engine-nix`, whose outputs are
patched to the Nix loader.

```
linux-engine-sdk-release-x86_64-<revision>.tar.gz
linux-engine-sdk-release-x86_64-<revision>.tar.gz.sha256
```

The tarball's `flutter/engine/src/out/<out>/engine-sdk/{include,lib}` holds
`flutter_embedder.h` and `libflutter_engine.so`, exactly what
`scripts/build-veshell.sh` and the project's dev build read. It is the
same artifact contract (names, layout) as the meta-flutter releases, so
switching is only a matter of changing the owner/repo in the download URL.

## Switching Veshell to our engine

> Done for the current pin: `release.json` consumes
> `linux-engine-sdk-release-x86_64-a804b261645ef8c13eb3d5c44a5c2fb0340c5539`
> from `free-explorers/flutter-engine`. The steps below are for the next engine
> revision.

1. In `free-explorers/flutter-engine`, dispatch **Engine Release** with the
   pinned engine revision (mode `release`; run `debug` too for keyless dev
   builds). It publishes `linux-engine-sdk-<mode>-x86_64-<rev>`.
2. The engine URL and hash are app-owned: `nix/flutter-artifacts.json` in the
   Veshell checkout holds them, the **Bump Flutter Version** workflow fills them
   (the sha256 lands when the release above exists), and `prepare-release.py`
   mirrors them into `release.json` and re-renders. To verify by hand:

   ```sh
   VESHELL_SRC=/path/to/veshell python3 scripts/render-recipes.py --check --veshell-src "$VESHELL_SRC"
   ```

3. For dev builds, set `VESHELL_ENGINE_REPO=free-explorers/flutter-engine` (see
   `extra/build/flutter_engine_lib.rs`; it defaults to
   `meta-flutter/flutter-engine`).
