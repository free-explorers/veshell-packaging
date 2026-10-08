#!/usr/bin/env bash
# prebuilt-in-container-debian.sh - build the Debian payload inside debian:13.
#
# Debian 13 ships libdisplay-info.so.2 while Arch/Fedora/openSUSE/Ubuntu ship
# .so.3, so the common payload cannot link Debian's copy. This builds a second
# payload against Debian's own libraries for the Debian_13 OBS repository; the
# OBS recipes select it with a per-repository veshell-bin-Debian_13.dsc.
#
# Invoked by .github/workflows/release.yml via:
#   docker run --rm -v "$GITHUB_WORKSPACE:/work" -w /work debian:13 \
#     bash /work/ci/prebuilt-in-container-debian.sh
set -euo pipefail

work="${1:-/work}"
cd "$work"

if [[ ! -f /etc/debian_version ]]; then
  printf 'error: this script must run inside a Debian container\n' >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
mapfile -t packages < <(grep -vE '^[[:space:]]*(#|$)' ci/debian-deps.txt)
apt-get install -y --no-install-recommends "${packages[@]}"

# Debian's rustc is older than Cargo.lock requires; install current stable.
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
curl -fsSL https://sh.rustup.rs \
  | sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable
export PATH="/usr/local/cargo/bin:$PATH"
rustc --version
cargo --version

commit="$(python3 -c 'import json; print(json.load(open("release.json"))["commit"])')"
rm -rf "$work/.veshell"
git clone https://github.com/free-explorers/veshell.git "$work/.veshell"
git -C "$work/.veshell" checkout "$commit"

rm -rf "$work/.inputs"
scripts/fetch-inputs.sh "$work/.inputs"

rm -rf "$work/out"
VESHELL_SRC="$work/.veshell" PAYLOAD_SUFFIX=debian13-x86_64 \
  scripts/build-prebuilt.sh "$work/.inputs" "$work/out"

ls -la "$work/out"
