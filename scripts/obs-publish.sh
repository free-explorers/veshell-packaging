#!/usr/bin/env bash
# obs-publish.sh - upload a rendered binary package to the Open Build Service.
#
# The binary recipe is small, so its sources are uploaded directly. The source
# package (Flutter's ~1.9 GB of pinned inputs) is not handled here: it needs a
# server-side _service or the sources hosted where OBS can fetch them.
#
# Environment:
#   OSC_CONFIG   path to an oscrc holding the apiurl and credentials
#
# Usage: obs-publish.sh SPEC_DIR OBS_PROJECT OBS_PACKAGE [--dry-run]
#   SPEC_DIR must contain veshell-bin.spec, veshell-bin.changes and the prebuilt
#   tarball named after the spec's Source0 URL basename.
#   The OBS package must already exist; create it once in the OBS web UI. The
#   openSUSE_Tumbleweed build repository is added to the project if missing.
set -euo pipefail

spec_dir="${1:?usage: obs-publish.sh SPEC_DIR OBS_PROJECT OBS_PACKAGE [--dry-run]}"
project="${2:?usage: obs-publish.sh SPEC_DIR OBS_PROJECT OBS_PACKAGE [--dry-run]}"
package="${3:?usage: obs-publish.sh SPEC_DIR OBS_PROJECT OBS_PACKAGE [--dry-run]}"
dry_run=0
[[ "${4:-}" == "--dry-run" ]] && dry_run=1

[[ -f "$spec_dir/veshell-bin.spec" ]] || { printf 'error: missing %s/veshell-bin.spec\n' "$spec_dir" >&2; exit 1; }
[[ -n "${OSC_CONFIG:-}" ]] || { printf 'error: OSC_CONFIG is not set\n' >&2; exit 1; }
command -v osc >/dev/null || { printf 'error: osc is required\n' >&2; exit 1; }

osc() { command osc --config "$OSC_CONFIG" "$@"; }

# OBS builds nothing until the project carries a target repository. Add the
# openSUSE Tumbleweed repository when it is missing, preserving any others.
ensure_repository() {
  local current
  current="$(mktemp)"
  osc meta prj "$project" > "$current"
  if ! grep -q 'name="openSUSE_Tumbleweed"' "$current"; then
    command -v python3 >/dev/null || {
      printf 'error: python3 is required to add the OBS repository\n' >&2; exit 1;
    }
    printf 'adding the openSUSE_Tumbleweed repository to %s\n' "$project"
    python3 - "$current" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
tree = ET.parse(path)
repo = ET.SubElement(tree.getroot(), "repository", {"name": "openSUSE_Tumbleweed"})
ET.SubElement(repo, "path", {"project": "openSUSE:Factory", "repository": "snapshot"})
ET.SubElement(repo, "arch").text = "x86_64"
tree.write(path, encoding="utf-8", xml_declaration=True)
PY
    osc meta prj "$project" -F "$current" -m "Add the openSUSE_Tumbleweed repository"
  fi
  rm -f "$current"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkg="$work/pkg/$package"

if ((dry_run)); then
  printf 'dry run: would ensure the openSUSE_Tumbleweed repository on %s\n' "$project"
else
  ensure_repository
fi

if ! osc checkout --output-dir "$work/pkg" "$project" "$package"; then
  printf 'error: OBS package %s/%s is not reachable; create it first\n' "$project" "$package" >&2
  exit 1
fi

# Replace the tracked sources with this release's.
find "$pkg" -maxdepth 1 -type f ! -name '.*' -delete
cp "$spec_dir"/veshell-bin.spec "$spec_dir"/veshell-bin.changes "$pkg/"
for asset in "$spec_dir"/veshell-*.tar.zst; do
  [[ -e "$asset" ]] && cp "$asset" "$pkg/"
done
( cd "$pkg" && osc addremove )

version="$(awk -F': *' '/^Version:/{print $2; exit}' "$spec_dir/veshell-bin.spec")"
release="$(awk -F': *' '/^Release:/{print $2; exit}' "$spec_dir/veshell-bin.spec")"

if ((dry_run)); then
  printf 'dry run: osc package %s/%s would be committed\n' "$project" "$package"
  ( cd "$pkg" && osc status )
  exit 0
fi

( cd "$pkg" && osc commit -m "Update veshell-bin to ${version}-${release}" )
printf 'committed %s/%s\n' "$project" "$package"
