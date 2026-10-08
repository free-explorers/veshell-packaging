#!/usr/bin/env bash
# Installs veshell-bin from the published channel inside a throwaway container
# and checks the things a package manager cannot.
#
# Why this exists: Smithay dlopen()s libEGL.so.1 and libwayland-server.so.0, and
# xkbcommon-dl dlopen()s libxkbcommon-x11.so.0. Those never appear in a binary's
# DT_NEEDED entries, so dh_shlibdeps, RPM's auto-requires and makepkg cannot see
# them. A package that forgets to declare them installs perfectly and then
# panics on first launch. This script asserts they resolve *after* installing
# (and reports which of them the base image already provided, so the credit for
# bringing them is attributable to the package).
#
# Usage: smoke-install.sh <channel> <expected-version-prefix>
#   channel = deb:<obs-repo> | zypper | copr | aur   e.g. deb:Debian_13
set -uo pipefail

channel="${1:?usage: smoke-install.sh <deb:REPO|zypper|copr|aur> <expected-version>}"
expected="${2:?expected version prefix, e.g. 0.1.0}"

OBS_ROOT="https://download.opensuse.org/repositories/home:/PapyElGringo"
wait_attempts="${SMOKE_WAIT_ATTEMPTS:-20}"
wait_sleep="${SMOKE_WAIT_SLEEP:-30}"

dlopen_libs=(libEGL.so.1 libwayland-server.so.0 libxkbcommon-x11.so.0)
fail=0
say() { printf '\n### %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

ldconfig_bin() {
  command -v ldconfig 2>/dev/null || command -v /sbin/ldconfig 2>/dev/null || command -v /usr/sbin/ldconfig 2>/dev/null || true
}

# Sonames the loader can currently resolve, printed space separated.
resolved_libs() {
  local lcc out=""
  lcc="$(ldconfig_bin)"
  for l in "${dlopen_libs[@]}"; do
    if [[ -n $lcc ]] && "$lcc" -p 2>/dev/null | grep -qF "$l"; then
      out+="$l "
    elif compgen -G "/usr/lib*/**/$l" >/dev/null 2>&1 || [[ -e /usr/lib/$l ]] || [[ -e /usr/lib64/$l ]]; then
      out+="$l "
    fi
  done
  printf '%s' "$out"
}

# ---- channel plumbing -------------------------------------------------------

add_repo() {
  case "$channel" in
    deb:*)
      local repo="${channel#deb:}"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq ca-certificates curl gnupg >/dev/null
      curl -fsSL "$OBS_ROOT/${repo}/Release.key" -o /tmp/veshell.asc
      gpg --batch --no-tty --yes --dearmor -o /usr/share/keyrings/veshell.gpg /tmp/veshell.asc
      echo "deb [signed-by=/usr/share/keyrings/veshell.gpg] $OBS_ROOT/${repo}/ ./" \
        > /etc/apt/sources.list.d/veshell.list
      ;;
    zypper)
      zypper --non-interactive rr veshell >/dev/null 2>&1 || true
      zypper --non-interactive ar -f "$OBS_ROOT/openSUSE_Tumbleweed/" veshell
      ;;
    copr)
      dnf install -y dnf-plugins-core >/dev/null
      dnf copr enable -y @free-explorers/veshell >/dev/null
      ;;
    aur)
      pacman -Sy --noconfirm --needed base-devel git sudo >/dev/null
      if ! pacman-key --list-keys >/dev/null 2>&1; then
        pacman-key --init >/dev/null
        pacman-key --populate archlinux >/dev/null
      fi
      ;;
    *) echo "unknown channel: $channel" >&2; exit 2 ;;
  esac
}

available_version() {
  case "$channel" in
    deb:*)
      apt-get update -qq >/dev/null 2>&1 || true
      apt-cache policy veshell-bin 2>/dev/null | awk '/Candidate:/{print $2; exit}'
      ;;
    zypper)
      zypper --non-interactive refresh >/dev/null 2>&1 || true
      zypper --non-interactive info veshell-bin 2>/dev/null | awk -F': *' '/^Version:/{print $2; exit}'
      ;;
    copr)
      dnf -q makecache >/dev/null 2>&1 || true
      dnf -q info veshell-bin 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}'
      ;;
    aur)
      curl -fsSL "https://aur.archlinux.org/rpc/v5/info?arg%5B%5D=veshell-bin" 2>/dev/null \
        | python3 -c 'import sys,json; r=json.load(sys.stdin)["results"]; print(r[0]["Version"] if r else "")' 2>/dev/null || true
      ;;
  esac
}

install_package() {
  case "$channel" in
    deb:*)
      # --no-install-recommends keeps the check strict: nothing may come from
      # a Recommends that a plain install would have pulled in anyway.
      apt-get install -y --no-install-recommends veshell-bin
      ;;
    zypper)
      zypper --non-interactive --gpg-auto-import-keys install -y veshell-bin
      ;;
    copr)
      dnf install -y veshell-bin
      ;;
    aur)
      id builder >/dev/null 2>&1 || useradd -m -G wheel builder
      echo 'builder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/builder
      rm -rf /tmp/aur
      sudo -u builder git clone -q https://aur.archlinux.org/veshell-bin.git /tmp/aur
      ( cd /tmp/aur && sudo -u builder makepkg -si --noconfirm --needed )
      ;;
  esac
}

installed_version() {
  case "$channel" in
    deb:*)  dpkg-query -W -f='${Version}' veshell-bin ;;
    zypper|copr) rpm -q --qf '%{VERSION}' veshell-bin ;;
    aur)    pacman -Q veshell-bin | awk '{print $2}' ;;
  esac
}

# ---- run --------------------------------------------------------------------

. /etc/os-release 2>/dev/null || true
say os
echo "  ${PRETTY_NAME:-unknown}  (${ID:-?} ${VERSION_ID:-?})"
echo "  channel: $channel   expecting version prefix: $expected"

say base-image-libraries
before="$(resolved_libs)"
echo "  already resolvable before install: ${before:-<none>}"

add_repo

say wait-for-published-build
candidate=""
for i in $(seq 1 "$wait_attempts"); do
  candidate="$(available_version)"
  echo "  [$i/$wait_attempts] candidate=${candidate:-<none>}"
  case "$candidate" in "$expected"*) break ;; esac
  candidate=""
  sleep "$wait_sleep"
done
if [[ -z $candidate ]]; then
  echo "  FAIL no published version starting with $expected after $((wait_attempts * wait_sleep))s"
  fail=1
fi

say install
install_package || fail=1
installed="$(installed_version)"
echo "  installed: ${installed:-<none>}"
case "$installed" in "$expected"*) ;; *) bad "installed '$installed' does not start with '$expected'" ;; esac

say dlopen-libraries
for l in "${dlopen_libs[@]}"; do
  if printf '%s' "$(resolved_libs)" | grep -qF "$l"; then
    printf '  OK   %s\n' "$l"
  else
    bad "$l does not resolve after installing (the package must declare it)"
  fi
done

say required-paths
for p in /usr/bin/veshell /usr/bin/veshell-session /usr/bin/veshell-session-stop \
         /usr/lib/veshell/libapp.so /usr/lib/veshell/libflutter_engine.so \
         /usr/share/veshell/data/flutter_assets \
         /usr/share/wayland-sessions/veshell.desktop \
         /usr/share/xdg-desktop-portal/portals/veshell.portal \
         /usr/lib/systemd/user/veshell.service; do
  if [[ -e $p ]]; then printf '  OK   %s\n' "$p"; else bad "missing $p"; fi
done

say ldd-shared-library-resolution
shopt -s nullglob
for f in /usr/bin/veshell /usr/bin/veshell-session /usr/bin/veshell-session-stop \
         /usr/lib/veshell/*.so*; do
  [[ -e $f ]] || continue
  miss="$(ldd "$f" 2>&1 | grep 'not found' || true)"
  if [[ -n $miss ]]; then bad "$f"; printf '       %s\n' "$miss"; else printf '  OK   %s\n' "$f"; fi
done

printf '\n### RESULT: %s\n' "$( [[ $fail == 0 ]] && echo PASS || echo FAIL )"
exit "$fail"
