"""The flutter-engine-nix pin of a Veshell source tree.

Veshell pins flutter-engine-nix as a flake input in flake.lock; sources from
before that pinned it in nix/engine-repository.json. Both give the
repository, the revision and the hash of the unpacked source: a narHash from
flake.lock, the equivalent fetchTarball sha256 from the older file.
"""

from __future__ import annotations

import json
from pathlib import Path


def read(veshell_src: Path) -> dict:
    lock_path = veshell_src / "flake.lock"
    if lock_path.is_file():
        lock = json.loads(lock_path.read_text())
        nodes = lock["nodes"]
        name = nodes[lock["root"]].get("inputs", {}).get("flutter-engine-nix")
        if isinstance(name, str):
            locked = nodes[name]["locked"]
            return {
                "repository": f"{locked['owner']}/{locked['repo']}",
                "revision": locked["rev"],
                "sha256": locked["narHash"],
            }
    legacy = veshell_src / "nix" / "engine-repository.json"
    if legacy.is_file():
        pin = json.loads(legacy.read_text())
        return {key: pin[key] for key in ("repository", "revision", "sha256")}
    raise FileNotFoundError(
        f"no flutter-engine-nix pin in {veshell_src}: "
        "neither a flutter-engine-nix input in flake.lock nor nix/engine-repository.json"
    )
