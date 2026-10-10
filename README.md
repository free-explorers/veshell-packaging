# Veshell packaging

This repository builds and publishes the packaging artifacts for Veshell. It is
separate from the application and the engine: packaging releases are never held
in `free-explorers/veshell` or `free-explorers/flutter-engine`.

All recipes share one hermetic build model and build the **same** payload:

1. compile the Dart shell from source against a pinned Flutter SDK,
2. compile the Rust compositor from source against that shell, with no network
   access (vendored crates),
3. install the compositor, the AOT shell, the matching Flutter embedder engine,
   the assets/settings, the session scripts, the systemd user units and the
   xdg-desktop-portal descriptors.

The packaged source is a Veshell checkout pinned by `release.json` (`commit`),
not a working tree in this repository; `scripts/build-veshell.sh` consumes it via
`VESHELL_SRC`. The payload layout is defined by Veshell's `Makefile`
(`make install PREFIX=/usr DESTDIR=…`), which every recipe reuses.

## Layout

```
.
├── release.json                 # release manifest, single source of truth
├── release.schema.json          # JSON Schema for the manifest
├── .github/workflows/           # release.yml, install-smoke.yml, nix-package-release.yml
├── templates/                   # recipe templates rendered from the manifest
│   ├── PKGBUILD.in
│   ├── PKGBUILD-bin.in          # AUR veshell-bin (rendered at release time)
│   ├── veshell.spec.in
│   ├── veshell-bin.spec.in      # RPM veshell-bin (rendered at release time)
│   ├── veshell-bin.changes.in
│   ├── veshell-bin.dsc.in        # OBS binary DEB, one .dsc per repository (rendered at release time)
│   ├── debian.control.in
│   ├── debian.rules.in
│   ├── debian.changelog.in
│   ├── debian.copyright.in
│   ├── build.script.in           # restores debian/rules mode on OBS
│   └── debian/{changelog,rules}.in
├── scripts/
│   ├── build-veshell.sh         # the shared hermetic build (copied into each recipe)
│   ├── fetch-inputs.sh          # download + verify + lay out every pinned input
│   ├── build-prebuilt.sh        # build a prebuilt payload tarball (PAYLOAD_SUFFIX picks the variant)
│   ├── generate-inputs.sh       # regenerates the generated inputs + verifies pins
│   ├── render-recipes.py        # release.json + templates -> source recipes
│   ├── gen-bin-recipes.py       # prebuilt hash -> AUR/RPM/DEB veshell-bin recipes
│   ├── aur-publish.sh           # push a package to the AUR
│   ├── copr-publish.sh          # submit the binary SRPM to COPR
│   ├── obs-publish.sh           # commit the binary package to OBS
│   └── sync-helpers.sh          # copies build-veshell.sh into each recipe
├── ci/
│   ├── arch-deps.txt            # Arch build dependencies for the CI container
│   ├── prebuilt-in-container.sh # common payload build entry point (Arch)
│   ├── debian-deps.txt          # Debian build dependencies for the CI container
│   ├── prebuilt-in-container-debian.sh # Debian payload build entry point (Debian 13)
│   └── smoke-install.sh         # post-release install check, run per channel in a container
├── engine/README.md             # the engine repository and the switch to it
├── arch/
│   ├── PKGBUILD                 # Arch / Manjaro source package (generated)
│   ├── build-veshell.sh         # copy of scripts/build-veshell.sh
│   └── .SRCINFO
├── arch-git/
│   ├── PKGBUILD                 # AUR veshell-git (VCS; not generated per release)
│   └── .SRCINFO
├── fedora/
│   ├── veshell.spec             # Fedora source RPM (generated)
│   └── build-veshell.sh
└── debian/
    ├── debian/                  # Debian source package (changelog/rules generated)
    └── build-veshell.sh
```

## Why this model

Veshell links a specific Flutter engine revision and AOT-compiles its Dart shell
against the matching Flutter SDK. Neither Flutter nor the Flutter engine is
packaged by any mainstream distribution (`flutter` is AUR-only on Arch,
COPR-only on Fedora, and absent from Debian), and the Flutter engine cannot be
built by a generic distro buildroot: it needs Chromium's `depot_tools`, `gn`
and `ninja` and a multi-gigabyte checkout. Even nixpkgs' `mkFlutter` downloads
the official SDK and Dart/engine artifacts rather than building them.

The only viable, reproducible approach is therefore the one used here and by
the project's own Nix packaging: build Veshell's own sources from source, and
consume **pinned, checksummed upstream Flutter artifacts**. Concretely:

| Input | Source | Pinned by |
| --- | --- | --- |
| Veshell source | git commit | `_veshell_commit` |
| Flutter SDK | official stable bundle | sha256 |
| Flutter engine artifacts | `flutter_infra_release` | sha256 (6 zips) |
| Flutter embedder engine | meta-flutter release (transitional, see `engine/`) | sha256 |
| Rust crates | `cargo vendor` | generated tarball sha256 |
| Dart packages | pub cache | generated tarball sha256 |

`flutter pub get` runs with `--offline` against the vendored pub cache, and the
Rust build runs with `CARGO_NET_OFFLINE=true` against the vendored crate tree.
`scripts/generate-inputs.sh verify` re-checks every upstream hash.

**Engine strategy.** The distro recipes currently consume the prebuilt
meta-flutter engine (`flutter.engine`). The dedicated engine repository
`free-explorers/flutter-engine` source-builds a portable engine SDK and
publishes it **there** — engine releases are never held in this repository.
`engine/README.md` documents it and the switch. Once a revision is published,
point `flutter.engine` at it, re-render, and set `VESHELL_ENGINE_REPO` for dev
builds. The Nix channel already source-builds its engine through
`free-explorers/flutter-engine-nix`, pinned as `nix.engine_source`.

### Single source of truth

`release.json` holds the release version, the pinned Flutter SDK/engine
revisions, and the sha256 of every upstream artifact and generated input. The
per-distro recipes are **generated** from it:

```sh
scripts/render-recipes.py          # write the recipes
scripts/render-recipes.py --check  # verify they are in sync (CI)
```

The renderer applies the per-distro version mapping (Arch `0.2.0beta1`,
RPM `0.2.0` with `Release: 0.1.beta1`, Debian `0.2.0~beta.1-1`) and refuses to
run when a recipe's copy of `build-veshell.sh` drifts from the canonical helper.
`--check` also fails if `Cargo.toml`, `nix/flutter-sdk.json` or
`nix/engine-repository.json` disagree with the manifest, so one release identity
covers the distro recipes and the Nix packaging. Editing a rendered recipe by
hand is a mistake: change `release.json` or the templates and re-render.

## Release pipeline

`.github/workflows/release.yml` runs when a GitHub release is published:

1. **validate** — the release tag must match the manifest (tag `v0.2.0-beta.1`
   for release id `0.2.0-beta.1`), the recipes must already be rendered
   (`--check`), and the repository pins must agree with the manifest.
2. **prebuilt** — builds `veshell-<release>-x86_64.tar.zst` inside an
   `archlinux:base-devel` container, attests `SHA256SUMS`, and uploads both to
   the release.
3. **aur** — regenerates `.SRCINFO`, renders `veshell-bin` from the prebuilt
   hash, and pushes `veshell`, `veshell-bin` and `veshell-git` to the AUR. The
   `veshell-git` recipe tracks the VCS and rebuilds the shell through Veshell's
   own development bootstrap.
4. **copr** — builds the `veshell-bin` SRPM from the prebuilt payload and
   submits it to COPR.
5. **obs** — commits the `veshell-bin` spec, changes and prebuilt payload to the
   Open Build Service.
6. **nix** — the second workflow `.github/workflows/nix-package-release.yml` runs
   on the same release event. It checks out the pinned Veshell source, builds the
   flake's package/SDK/shell closures (the engine is substituted from the project
   Cachix cache, never built here), and pushes them to that cache. The Nix
   toolchain is not used by the distro recipes.

`scripts/fetch-inputs.sh` downloads and checksum-verifies the pinned SDK/engine
artifacts and the two generated inputs before the build, so nothing is fetched
unverified.

### GitHub releases

Two release objects are published per version, for two different audiences:

- **`free-explorers/veshell`** — the product release. It carries the user-facing
  changelog, so watchers of the application repository are notified, and it tags
  the exact commit the release was built from. It holds no assets.
- **this repository** — the artifact release. It holds the prebuilt payloads and
  their checksums, and it is what the pipeline above keys off. Nix closures are
  not attached here; they live in the `veshell` Cachix cache.

Do not mark either as a GitHub **pre-release** while `release.json` says
`"channel": "beta"`. GitHub's pre-release flag only excludes a release from
`releases/latest`; because beta is the shipping channel and there is no stable
release for `latest` to point at, marking it pre-release leaves "Latest"
pointing at an old alpha. The maturity signal lives in `channel` and the
changelog title, not in that flag. Reserve the flag for builds that are not
meant to be consumed, such as nightly or RC snapshots. `packaging-inputs-*`
stays pre-release: it is an internal artifact, not a product release.

### Install smoke test

`.github/workflows/install-smoke.yml` is the counterpart to the build pipeline.
When the Release workflow finishes (or when dispatched manually with a tag) it
installs the
published `veshell-bin` from each channel in a throwaway container — Debian 13,
Ubuntu 26.04, openSUSE Tumbleweed, openSUSE Leap 16.0, Fedora 44 and Arch (AUR)
— and asserts what a
package manager cannot (`ci/smoke-install.sh`):

- the libraries the compositor **`dlopen()`s** (`libEGL.so.1`,
  `libwayland-server.so.0`, `libxkbcommon-x11.so.0`) resolve. They are absent
  from `DT_NEEDED`, so `dh_shlibdeps`, RPM's auto-requires and `makepkg` cannot
  discover them: a package that forgets to declare one installs perfectly and
  then panics on first launch;
- the payload layout (`/usr/bin/veshell*`, `libapp.so`, `libflutter_engine.so`,
  assets, session desktop, portal, systemd user unit);
- every shipped ELF links (`ldd`).

It waits, bounded, for the release's own build to appear on each channel and
asserts the installed version matches `release.json`, so it can never quietly
pass against a previous release. It deliberately does **not** start the
compositor: containers have no `/dev/dri`, and installing a display server to
fake one would pull several of the very libraries under test. The runtime
(DRM backend) smoke test is done in a VM instead.

Every channel job is a no-op until its secret is configured, so a release still
succeeds before the channels are set up:

| Job | Secret | Variables (default) |
| --- | --- | --- |
| aur | `AUR_SSH_PRIVATE_KEY` | — |
| copr | `COPR_CONFIG` | `COPR_PROJECT` (required, e.g. `@<fas-group>/veshell`) |
| obs | `OSC_CONFIG` | `OBS_PROJECT` (required, e.g. `home:<user>`), `OBS_PACKAGE` (`veshell`), `OBS_RPM_REPOS` (`openSUSE_Tumbleweed openSUSE_Slowroll 16.0`), `OBS_DEB_REPOS` (`xUbuntu_26.04 Debian_13`) |
| nix | `CACHIX_AUTH_TOKEN` | `VESHELL_REPO` (`free-explorers/veshell`) |

Both AUR packages, the COPR project, and the OBS project/package must exist
first; create them once in the respective web UI. The OBS job adds the
`openSUSE_Tumbleweed`, `openSUSE_Slowroll`, `16.0` (Leap 16),
`xUbuntu_26.04` and `Debian_13` build repositories to
the project if they are missing, resolving each base project from the OBS
instance's distribution list.

The channels are split by distribution so they never overlap:

| Channel | Distributions |
| --- | --- |
| AUR (`veshell`, `veshell-bin`, `veshell-git`) | Arch / Manjaro |
| COPR | **Fedora** |
| OBS | openSUSE Tumbleweed + Slowroll + Leap 16.0, Ubuntu 26.04, Debian 13 |
| Nix | NixOS |

The AUR, COPR and OBS channels ship the `veshell-bin` binary package built from
the prebuilt payload (the same model as the AUR `veshell-bin`), because Flutter's
~1.9 GB of pinned inputs exceed the services' upload limits. A source package on
those services needs a server-side `_service` or builder-side fetching, and is
worth doing once we publish our own engine. The Nix channel instead builds from
source with Nix and publishes the result to the `veshell` Cachix cache, which the
flake substitutes from.

Fedora RPMs are built on COPR, not OBS: `dnf copr enable` is the idiomatic Fedora
install path, and OBS gets no Fedora targets. The same `veshell-bin.spec` serves
both: it carries an openSUSE branch (`%if 0%{?suse_version}`) that uses openSUSE
package names and otherwise relies on openSUSE's automatic shared-library
dependency generation. COPR uses the Fedora branch unchanged.

The COPR project is owned by the Fedora `free-explorers` group
(`@free-explorers/veshell`, chroots `fedora-44`, `fedora-45`, `rawhide`):

```sh
sudo dnf copr enable @free-explorers/veshell
sudo dnf install veshell-bin
```

Debian and Ubuntu packages are built on OBS from the same prebuilt payload
through OBS's `debtransform`: `veshell-bin.dsc` plus `debian.control`,
`debian.rules`, `debian.changelog` and `debian.copyright` are assembled into a
source package whose upstream archive is the payload tarball. `veshell-bin`
carries the Debian runtime dependency names and `Provides`/`Conflicts: veshell`.
OBS source files do not carry a file mode, so `build.script` restores the
executable bit on `debian/rules` before `dpkg-buildpackage` runs.

The payloads are chosen by **library family**, not by distribution. Debian 13 and
openSUSE Leap 16.0 ship `libdisplay-info.so.2`; Arch, Fedora, openSUSE
Tumbleweed/Slowroll and Ubuntu 26.04 ship `.so.3`. A single payload cannot link
both, so the pipeline builds a second one in a Debian 13 container
(`ci/prebuilt-in-container-debian.sh`), published as
`veshell-<release>-debian13-x86_64.tar.zst`. Every other target uses the common
Arch-built payload. (The payloads have the same glibc floor, 2.39, so the split
is purely about the linked sonames.)

OBS selects a recipe per repository — `veshell-<repository>.dsc` for DEB and
`veshell-<repository>.spec` for RPM — so `Debian_13` and `openSUSE_Leap_16.0`
point at the `.so.2` payload while the rest point at the common one. (Leap's
OBS build repository is named `16.0`.) Prefer that
mechanism over a new payload whenever a target joins an existing family. No
distribution library is bundled.

### Installing from the OBS repositories

Replace `<project>` with `OBS_PROJECT`, using `:` -> `:/` in the download URL
(`home:alice` becomes `home:/alice`).

openSUSE:

```sh
# Tumbleweed, or openSUSE_Slowroll / 16.0 (Leap 16)
sudo zypper addrepo -f \
  https://download.opensuse.org/repositories/<project>/openSUSE_Tumbleweed/ veshell
sudo zypper --gpg-auto-import-keys refresh
sudo zypper install veshell-bin
```

Ubuntu 26.04 and Debian 13 - the repository path selects the target
(`xUbuntu_26.04` or `Debian_13`):

```sh
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.opensuse.org/repositories/<project>/xUbuntu_26.04/Release.key \
  | sudo gpg --batch --no-tty --yes --dearmor -o /etc/apt/keyrings/veshell.gpg
echo "deb [signed-by=/etc/apt/keyrings/veshell.gpg] https://download.opensuse.org/repositories/<project>/xUbuntu_26.04/ ./" \
  | sudo tee /etc/apt/sources.list.d/veshell.list
sudo apt update && sudo apt install veshell-bin
```

`veshell-bin` then upgrades with `zypper up` or `apt upgrade` like any other
repository. It `Provides`/`Conflicts: veshell`, so it cannot be installed next
to the source package.

### Compliance note

These recipes are **source packages** and are built entirely with
distribution-provided toolchains plus checksummed upstream artifacts. That is
as close to "build from source" as any distro gets for Flutter.

They are **not** uploadable to Debian `main` or Fedora `main` as-is, because
Debian and Fedora forbid relying on prebuilt binaries that are themselves not
built from source in the archive. A main-repo upload would additionally require
separate `flutter-sdk` and `flutter-engine` source packages that build those
artifacts from source. Until that exists upstream, target the AUR, COPR and
the OBS repositories (openSUSE, Debian, Ubuntu). See `docs/building.md` for the
upstream build contract.

## Building

### Arch / Manjaro

The PKGBUILD uses the pinned git commit as its source and expects the two
generated inputs to be published at `$_input_mirror`. Build locally:

```sh
cd arch
makepkg -s
```

`makepkg` fetches the upstream SDK/engine artifacts directly and the two
generated inputs from the mirror. Self-hosting the inputs works by pointing
`VESHELL_INPUT_MIRROR` at another location.

### Fedora

The spec is intended for COPR / a self-hosted repository. After placing
`build-veshell.sh` and the pinned inputs in `SOURCES/` (or uploading them to the
lookaside cache):

```sh
rpmbuild -ba fedora/veshell.spec
```

### Debian / Ubuntu

The source package needs the pinned inputs out of band (they are not part of the
downloadable source). Provide them in a directory and build:

```sh
cd debian
VESHELL_INPUT_DIR=/path/to/inputs debian/rules binary
# or a full source build:
VESHELL_INPUT_DIR=/path/to/inputs dpkg-buildpackage -b -us -uc
```

`debian/rules` extracts them into `debian/.build-inputs/` and drives the shared
helper.

## Regenerating the generated inputs

```sh
# in a checkout with a working .flutter_sdk
scripts/generate-inputs.sh all     # cargo vendor + pub cache
scripts/generate-inputs.sh verify  # re-check upstream hashes
```

Then update the sha256 values in `release.json`, publish the two tarballs at
`mirrors.inputs` (each release's generated inputs live at
`<mirrors.inputs>/veshell-<release>-*.tar.zst`), and re-render:

```sh
scripts/render-recipes.py
```

The renderer computes the `build-veshell.sh` checksum itself. When the shared
helper changes, run `scripts/sync-helpers.sh` first so the copies in
each recipe directory match, then re-render.

## Build flags

The recipes disable LTO (`!lto` on Arch, `_lto_cflags` on Fedora,
`DEB_BUILD_OPTIONS=nolto` on Debian). The `libspa-sys` build script compiles a C
shim into a static archive; when that shim is built with `-flto`, rustc's
non-LTO final link cannot resolve its symbols and the link fails with undefined
`*_libspa_rs` symbols.

## Validation status

- **Arch / Manjaro**: built end-to-end with `makepkg` on Manjaro and inspected
  with `namcap`; the installed payload is checked against
  `extra/tests/packaging_install.sh`.
- **Prebuilt payload**: `scripts/build-prebuilt.sh` produces
  `veshell-<release>-x86_64.tar.zst`; validated locally — the payload contains
  `usr/bin/veshell`, the AOT `libapp.so`, the embedder engine and the license,
  and extracts cleanly as the `veshell-bin` package root.
- **AUR**: `scripts/aur-publish.sh` exercised against a local bare git remote
  (first push, idempotent re-run, and `--dry-run`); the `veshell-bin` recipe is
  validated with `makepkg --printsrcinfo`.
- **OBS / COPR**: `scripts/obs-publish.sh` and `scripts/copr-publish.sh`
  exercised against stubbed `osc`/`rpmbuild`; the `veshell-bin` RPM spec and the
  `debtransform` DEB recipe (`veshell-bin.dsc` plus `debian.*`) are rendered from
  the manifest. The `osc` invocations were re-checked against `osc` 1.27
  (`--config` and `--output-dir`; the older `-c`/positional-dir forms are not
  accepted). Build repositories are resolved from the instance's
  `/distributions` list, so no base project path is hardcoded. Not built on a
  real service here (no OBS/COPR credentials, no `rpmbuild` on the validation
  host).
- **Fedora**: recipe supplied; not built here (no `rpmbuild` available on the
  validation host).
- **Debian / Ubuntu**: source recipe supplied; the OBS binary recipe was
  validated locally with the upstream `debtransform` / `debtransformarchive`
  scripts - they produce a clean `Format: 3.0 (quilt)` source package, and the
  `debian/rules` install step re-attaches the `usr/` top level that
  `dpkg-source` strips. Not built here (no `debhelper` on the validation host).
  The payload itself is exercised by the project's
  `extra/tests/packaging_install.sh`.
