#!/usr/bin/env bash
# prebuilt-in-container.sh - build the prebuilt payload inside archlinux.
#
# Invoked by .github/workflows/release.yml via:
#   docker run --rm -v "$GITHUB_WORKSPACE:/work" -w /work archlinux:base-devel \
#     bash /work/ci/prebuilt-in-container.sh
#
# It installs the Arch build dependencies, checks out the pinned Veshell source,
# then fetches and verifies every pinned input and builds
# out/veshell-<release>-x86_64.tar.zst plus out/SHA256SUMS.
set -euo pipefail

work="${1:-/work}"
cd "$work"

if ! command -v pacman >/dev/null; then
  printf 'error: this script must run inside an Arch Linux container\n' >&2
  exit 1
fi

pacman-key --init
pacman-key --populate archlinux

mapfile -t packages < <(grep -vE '^[[:space:]]*(#|$)' ci/arch-deps.txt)
pacman -Syu --noconfirm --needed "${packages[@]}"

# The source that gets packaged is not in this repository.
commit="$(python3 -c 'import json; print(json.load(open("release.json"))["commit"])')"
rm -rf "$work/.veshell"
git clone https://github.com/free-explorers/veshell.git "$work/.veshell"
git -C "$work/.veshell" checkout "$commit"

rm -rf "$work/.inputs"
scripts/fetch-inputs.sh "$work/.inputs"

rm -rf "$work/out"
VESHELL_SRC="$work/.veshell" scripts/build-prebuilt.sh "$work/.inputs" "$work/out"

ls -la "$work/out"
