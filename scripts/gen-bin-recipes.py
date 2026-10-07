#!/usr/bin/env python3
"""Generate the release-time binary recipes for the prebuilt payload.

The prebuilt payload is produced by scripts/build-prebuilt.sh and
uploaded to the GitHub release, so its hash is only known at release time. These
recipes therefore cannot be rendered by render-recipes.py.

Formats:
    aur   -> PKGBUILD                     (AUR `veshell-bin`)
    rpm   -> veshell-bin.spec + changes   (OBS / COPR binary RPM)
    deb   -> veshell-bin.dsc + debian.*   (OBS binary DEB via debtransform)

Usage:
    scripts/gen-bin-recipes.py --format aur|rpm|deb --prebuilt-sha SHA \\
        [--tag TAG] --out DIR
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "release.json"
# The prebuilt payload is published by this repository's own release.
PREBUILT_REPO = "https://github.com/free-explorers/veshell-packaging"

# format -> [(template, output filename)]
FORMATS = {
    "aur": [("PKGBUILD-bin.in", "PKGBUILD")],
    "rpm": [
        ("veshell-bin.spec.in", "veshell-bin.spec"),
        ("veshell-bin.changes.in", "veshell-bin.changes"),
    ],
    # OBS's debtransform does not skip comment lines in a .dsc, so
    # veshell-bin.dsc.in must stay comment-free (and colon-free).
    "deb": [
        ("veshell-bin.dsc.in", "veshell-{repo}.dsc"),
        ("debian.control.in", "debian.control"),
        ("debian.rules.in", "debian.rules"),
        ("debian.changelog.in", "debian.changelog"),
        ("debian.copyright.in", "debian.copyright"),
        ("build.script.in", "build.script"),
    ],
}

# Recipe files that must stay executable for the Debian tooling.
EXECUTABLE = {"debian.rules", "build.script"}


def load_renderer():
    spec = importlib.util.spec_from_file_location(
        "render_recipes", ROOT / "scripts" / "render-recipes.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", required=True, choices=sorted(FORMATS))
    parser.add_argument("--prebuilt-sha", required=True, help="sha256 of the prebuilt tarball")
    parser.add_argument("--tag", help="release tag (default: v<release-id>)")
    parser.add_argument("--repo", help="OBS repository name (required for --format deb)")
    parser.add_argument(
        "--obs-package",
        default="veshell",
        help="OBS package name, used in the per-repository .dsc filename",
    )
    parser.add_argument(
        "--payload-asset",
        help="payload asset for this recipe (default: the common veshell-<release>-x86_64.tar.zst)",
    )
    parser.add_argument("--out", required=True, type=Path, help="output directory")
    args = parser.parse_args()

    renderer = load_renderer()
    manifest = json.loads(MANIFEST.read_text())
    renderer.validate(manifest)
    tokens = renderer.build_tokens(manifest)

    release_id = tokens["RELEASE_ID"]
    tag = args.tag or f"v{release_id}"
    asset = f"veshell-{release_id}-x86_64.tar.zst"

    tokens["PREBUILT_URL"] = f"{PREBUILT_REPO}/releases/download/{tag}/{asset}"
    tokens["PREBUILT_SHA256"] = args.prebuilt_sha
    tokens["TAG"] = tag
    tokens["PAYLOAD_ASSET"] = args.payload_asset or asset

    if args.format == "deb" and not args.repo:
        parser.error("--format deb requires --repo")

    args.out.mkdir(parents=True, exist_ok=True)
    for template_name, output_pattern in FORMATS[args.format]:
        output_name = output_pattern.format(repo=args.repo, obs_package=args.obs_package)
        template = ROOT / "templates" / template_name
        if not template.is_file():
            renderer.fail(f"missing template: {template}")
        rendered = renderer.render(template.read_text(), tokens, str(template))
        out_path = args.out / output_name
        out_path.write_text(rendered)
        if output_name in EXECUTABLE:
            out_path.chmod(0o755)
        print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
