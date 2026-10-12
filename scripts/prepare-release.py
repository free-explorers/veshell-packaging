#!/usr/bin/env python3
"""prepare-release.py - update release.json for a release and re-render recipes.

Run from the packaging repository root. It writes the per-release metadata
(version, prerelease, channel, date, commit), re-syncs the Flutter and engine
pins from the Veshell checkout, records the generated-input checksums, points the
inputs mirror at this release, and re-renders the recipes, so a release is driven
from the app instead of hand-editing the manifest.

The upstream Flutter artifact block (SDK and engine URLs and hashes) is *not*
derived here: it changes only when the Flutter version changes, which is a
deliberate dependency upgrade. If the checkout pins a different Flutter version,
the script requires the artifact block to already match and fails with a clear
message otherwise.

The generated inputs (cargo vendor tree and pub cache) are recorded from
--inputs-dir, or from --cargo-vendor-sha256 / --pubcache-sha256.

Usage:
  scripts/prepare-release.py --version 0.2.0 [--prerelease beta.1]
      [--channel beta] --commit <40-hex> [--veshell-src DIR]
      [--inputs-dir DIR | --cargo-vendor-sha256 H --pubcache-sha256 H]

With --veshell-src (or VESHELL_SRC) the Flutter version, engine revision and the
Nix engine pin are read from that checkout and must agree with it.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

try:
    import tomllib as _toml
except ModuleNotFoundError:  # Python < 3.11
    _toml = None


def fail(message: str) -> "NoReturn":  # noqa: F821
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def release_id(version: str, prerelease: str) -> str:
    return f"{version}-{prerelease}" if prerelease else version


def sha256(path: Path) -> str:
    if not path.is_file():
        fail(f"missing generated input: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sync_pins(manifest: dict, veshell_src: Path) -> None:
    cargo_toml = veshell_src / "Cargo.toml"
    if not cargo_toml.is_file():
        fail(f"missing Cargo.toml in --veshell-src {veshell_src}")
    if _toml is None:
        fail("python3.11+ (tomllib) is required to read Cargo.toml")
    with cargo_toml.open("rb") as handle:
        cargo = _toml.load(handle)

    cargo_version = cargo["package"]["version"]
    if cargo_version != manifest["version"]:
        fail(
            f"Cargo.toml package.version ({cargo_version}) != manifest version "
            f"({manifest['version']}); bump it before releasing"
        )

    flutter_version = cargo["package"]["metadata"]["flutter_version"]
    sdk_pins = json.loads((veshell_src / "nix" / "flutter-sdk.json").read_text())
    if flutter_version not in sdk_pins:
        fail(f"nix/flutter-sdk.json has no entry for Flutter {flutter_version}")
    engine_revision = sdk_pins[flutter_version]["engineVersion"]
    engine_source = json.loads((veshell_src / "nix" / "engine-repository.json").read_text())

    flutter = manifest["flutter"]
    if flutter_version != flutter["version"]:
        artifacts = [("sdk", flutter["sdk"])] + list(flutter["artifacts"].items()) + [("engine", flutter["engine"])]
        stale = [label for label, artifact in artifacts if engine_revision not in artifact["url"]]
        if stale:
            fail(
                f"the checkout pins Flutter {flutter_version} (engine {engine_revision}) but the "
                f"upstream artifact block is stale ({', '.join(stale)}); update it as a dependency "
                "upgrade before releasing"
            )
        flutter["version"] = flutter_version
    flutter["engine_revision"] = engine_revision
    manifest["nix"]["engine_source"] = {
        "repository": engine_source["repository"],
        "revision": engine_source["revision"],
        "sha256": engine_source["sha256"],
    }


def sync_inputs(manifest: dict, args: argparse.Namespace) -> None:
    release = release_id(manifest["version"], manifest.get("prerelease") or "")

    base = manifest["mirrors"]["inputs"].rsplit("/", 1)[0]
    manifest["mirrors"]["inputs"] = f"{base}/packaging-inputs-v{release}"

    vendor, pubcache = args.cargo_vendor_sha256, args.pubcache_sha256
    if args.inputs_dir is not None:
        vendor = sha256(args.inputs_dir / f"veshell-cargo-vendor-{release}.tar.zst")
        pubcache = sha256(args.inputs_dir / f"veshell-pubcache-{release}.tar.zst")
    if vendor is not None:
        manifest["inputs"]["cargo_vendor"]["sha256"] = vendor
    if pubcache is not None:
        manifest["inputs"]["pubcache"]["sha256"] = pubcache


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", required=True)
    parser.add_argument("--prerelease", default="")
    parser.add_argument("--channel", default="beta", choices=["beta", "stable"])
    parser.add_argument("--commit", required=True)
    parser.add_argument("--veshell-src", type=Path)
    parser.add_argument("--manifest", type=Path, default=ROOT / "release.json")
    parser.add_argument("--inputs-dir", type=Path, help="directory with the generated input tarballs")
    parser.add_argument("--cargo-vendor-sha256")
    parser.add_argument("--pubcache-sha256")
    parser.add_argument("--no-render", action="store_true", help="only update the manifest")
    args = parser.parse_args()

    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        fail(f"--version must be x.y.z, got {args.version!r}")
    if args.prerelease and not re.fullmatch(r"[A-Za-z0-9.]+", args.prerelease):
        fail(f"--prerelease must be [A-Za-z0-9.]+, got {args.prerelease!r}")
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        fail(f"--commit must be a full 40-character sha, got {args.commit!r}")
    for name, value in (("--cargo-vendor-sha256", args.cargo_vendor_sha256), ("--pubcache-sha256", args.pubcache_sha256)):
        if value is not None and not re.fullmatch(r"[0-9a-f]{64}", value):
            fail(f"{name} must be a 64-character sha256, got {value!r}")
    if not args.manifest.is_file():
        fail(f"manifest not found: {args.manifest}")

    veshell_src = args.veshell_src
    if veshell_src is None and os.environ.get("VESHELL_SRC"):
        veshell_src = Path(os.environ["VESHELL_SRC"])

    manifest = json.loads(args.manifest.read_text())
    manifest["version"] = args.version
    manifest["prerelease"] = args.prerelease or None
    manifest["channel"] = args.channel
    manifest["commit"] = args.commit
    manifest["date"] = (
        datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
    )

    if veshell_src is not None:
        sync_pins(manifest, veshell_src)
    sync_inputs(manifest, args)

    args.manifest.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    release = release_id(args.version, args.prerelease)
    print(f"prepared {args.manifest.name}: {release} ({args.channel}) at {args.commit[:7]}")

    if not args.no_render:
        cmd = [sys.executable, str(ROOT / "scripts" / "render-recipes.py"), str(args.manifest)]
        if veshell_src is not None:
            cmd += ["--veshell-src", str(veshell_src)]
        subprocess.run(cmd, cwd=ROOT, check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
