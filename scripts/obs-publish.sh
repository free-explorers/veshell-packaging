#!/usr/bin/env bash
# obs-publish.sh - upload a rendered binary package to the Open Build Service.
#
# The binary recipes are small, so their sources are uploaded directly. The
# source package (Flutter's ~1.9 GB of pinned inputs) is not handled here: it
# needs a server-side _service or the sources hosted where OBS can fetch them.
#
# Environment:
#   OSC_CONFIG     path to an oscrc holding the apiurl and credentials
#   OBS_RPM_REPOS  repositories to add for the RPM build (default: Tumbleweed,
#                  Slowroll and Leap 16.0)
#   OBS_DEB_REPOS  repositories to add for the DEB build (default below)
#
# Usage: obs-publish.sh RECIPE_DIR OBS_PROJECT OBS_PACKAGE [--format rpm|deb|all] [--dry-run]
#   RECIPE_DIR must contain the rendered recipe for the requested format(s)
#   plus the prebuilt tarball (veshell-*.tar.zst):
#     rpm  veshell-<repository>.spec (one per repository), veshell-bin.changes
#     deb  veshell-<repository>.dsc (one per repository), debian.control,
#          debian.rules, debian.changelog
#   plus one or more prebuilt tarballs (veshell-*.tar.zst).
#   The OBS package must already exist; create it once in the OBS web UI. The
#   openSUSE and Debian/Ubuntu build repositories are added to the project if
#   missing, using the distribution list advertised by the OBS instance.
set -euo pipefail

usage() {
  printf 'usage: obs-publish.sh RECIPE_DIR OBS_PROJECT OBS_PACKAGE [--format rpm|deb|all] [--dry-run]\n' >&2
}

recipe_dir="${1:?$(usage)}"
project="${2:?$(usage)}"
package="${3:?$(usage)}"
shift 3

format=all
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) format="${2:?--format needs a value}"; shift 2 ;;
    --format=*) format="${1#--format=}"; shift ;;
    --dry-run) dry_run=1; shift ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
done
case "$format" in rpm | deb | all) ;; *) printf 'error: invalid --format %s\n' "$format" >&2; exit 1 ;; esac

[[ -n "${OSC_CONFIG:-}" ]] || { printf 'error: OSC_CONFIG is not set\n' >&2; exit 1; }
command -v osc >/dev/null || { printf 'error: osc is required\n' >&2; exit 1; }

osc() { command osc --config "$OSC_CONFIG" "$@"; }

# Collect the recipe files to upload for the requested format(s).
upload=()
if [[ "$format" == rpm || "$format" == all ]]; then
  # One spec per RPM repository: OBS selects <package>-<repository>.spec, which
  # is how openSUSE Leap 16.0 gets the payload built against libdisplay-info.so.2
  # while Tumbleweed and Slowroll get the common one.
  shopt -s nullglob
  specs=("$recipe_dir"/"$package"-*.spec)
  shopt -u nullglob
  [[ ${#specs[@]} -gt 0 ]] || { printf 'error: no %s-*.spec in %s\n' "$package" "$recipe_dir" >&2; exit 1; }
  for spec in "${specs[@]}"; do upload+=("$(basename "$spec")"); done
  [[ -f "$recipe_dir/veshell-bin.changes" ]] || { printf 'error: missing %s/veshell-bin.changes\n' "$recipe_dir" >&2; exit 1; }
  upload+=("veshell-bin.changes")
fi
if [[ "$format" == deb || "$format" == all ]]; then
  for f in debian.control debian.rules debian.changelog; do
    [[ -f "$recipe_dir/$f" ]] || { printf 'error: missing %s/%s\n' "$recipe_dir" "$f" >&2; exit 1; }
    upload+=("$f")
  done
  for f in debian.copyright build.script; do
    [[ -f "$recipe_dir/$f" ]] && upload+=("$f")
  done
  # One .dsc per OBS repository: OBS selects <package>-<repository>.dsc, which is
  # how the Debian repository gets the payload built against its libraries.
  shopt -s nullglob
  dscs=("$recipe_dir"/"$package"-*.dsc)
  shopt -u nullglob
  [[ ${#dscs[@]} -gt 0 ]] || { printf 'error: no %s-*.dsc in %s\n' "$package" "$recipe_dir" >&2; exit 1; }
  for dsc in "${dscs[@]}"; do upload+=("$(basename "$dsc")"); done
fi

# The prebuilt payload is shared by both recipes.
shopt -s nullglob
assets=("$recipe_dir"/veshell-*.tar.zst)
shopt -u nullglob
[[ ${#assets[@]} -gt 0 ]] || { printf 'error: no veshell-*.tar.zst in %s\n' "$recipe_dir" >&2; exit 1; }

# Repositories that must exist on the project for the requested format(s).
# Tumbleweed and Slowroll share one payload set; Leap 16.0 needs the payload
# built against libdisplay-info.so.2 (see the release workflow's family map).
# shellcheck disable=SC2206  # intentional word splitting
repos=(${OBS_RPM_REPOS:-openSUSE_Tumbleweed openSUSE_Slowroll openSUSE_Leap_16.0})
if [[ "$format" == deb || "$format" == all ]]; then
  # shellcheck disable=SC2206  # intentional word splitting
  repos+=(${OBS_DEB_REPOS:-xUbuntu_26.04 Debian_13})
fi

# Add any missing repositories. The base project/repository for each target is
# looked up in the instance's /distributions list, so no base path is hardcoded.
ensure_repositories() {
  local current dists repo added=0
  current="$(mktemp)"
  dists="$(mktemp)"
  osc meta prj "$project" > "$current"
  osc api /distributions > "$dists"
  for repo in "$@"; do
    if grep -q "name=\"$repo\"" "$current"; then
      continue
    fi
    printf 'adding the %s build repository to %s\n' "$repo" "$project"
    if ! python3 - "$current" "$dists" "$repo" <<'PY'
import sys
import xml.etree.ElementTree as ET

current, dists, repo = sys.argv[1], sys.argv[2], sys.argv[3]
path = None
for dist in ET.parse(dists).getroot().findall("distribution"):
    if dist.findtext("reponame") == repo:
        path = (dist.findtext("project"), dist.findtext("repository"))
        break
if not path or not all(path):
    sys.exit(1)
tree = ET.parse(current)
repository = ET.SubElement(tree.getroot(), "repository", {"name": repo})
ET.SubElement(repository, "path", {"project": path[0], "repository": path[1]})
ET.SubElement(repository, "arch").text = "x86_64"
tree.write(current, encoding="utf-8", xml_declaration=True)
PY
    then
      printf 'error: repository %s is not offered by this OBS instance\n' "$repo" >&2
      rm -f "$current" "$dists"
      exit 1
    fi
    added=1
  done
  if ((added)); then
    osc meta prj "$project" -F "$current" -m "Add build repositories: $*"
  fi
  rm -f "$current" "$dists"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# `osc checkout --output-dir DIR` stores the package directly in DIR (no
# PROJECT/PACKAGE structure), so the working copy is $work/pkg itself.
pkg="$work/pkg"

if ((dry_run)); then
  printf 'dry run: would ensure repositories on %s: %s\n' "$project" "${repos[*]}"
else
  ensure_repositories "${repos[@]}"
fi

if ! osc checkout --output-dir "$pkg" "$project" "$package"; then
  printf 'error: OBS package %s/%s is not reachable; create it first\n' "$project" "$package" >&2
  exit 1
fi

# Replace the tracked sources with this release's.
find "$pkg" -maxdepth 1 -type f ! -name '.*' -delete
for f in "${upload[@]}"; do
  cp "$recipe_dir/$f" "$pkg/"
done
for asset in "${assets[@]}"; do
  cp "$asset" "$pkg/"
done
( cd "$pkg" && osc addremove )

version=""
spec="$(find "$recipe_dir" -maxdepth 1 -name "$package-*.spec" -print -quit)"
if [[ -n "$spec" ]]; then
  version="$(sed -n 's/^Version:[[:space:]]*//p' "$spec" | head -1)"
  release="$(sed -n 's/^Release:[[:space:]]*//p' "$spec" | head -1 | sed 's/%{.*}//')"
  version="${version}-${release}"
else
  dsc="$(find "$recipe_dir" -maxdepth 1 -name "$package-*.dsc" -print -quit)"
  [[ -n "$dsc" ]] && version="$(awk -F': *' '/^Version:/{print $2; exit}' "$dsc")"
fi

if ((dry_run)); then
  printf 'dry run: osc package %s/%s would be committed (%s)\n' "$project" "$package" "${version:-unknown}"
  ( cd "$pkg" && osc status )
  exit 0
fi

( cd "$pkg" && osc commit -m "Update veshell-bin to ${version:-unknown}" )
printf 'committed %s/%s\n' "$project" "$package"
