#!/usr/bin/env bash
# "Initialization environment" for the OpenWrt builder.
#
# This replaces the single `apt-get -qq install <77 packages>` call.  On
# 2026-11-19 that call burned *exactly* 30 minutes per attempt (three attempts,
# then the step failed at 90 minutes) because `-qq` hid every progress line:
# a slow mirror, a stalled connection and a stuck dpkg lock all looked the
# same -- nothing in the log for half an hour.
#
# What this script does instead:
#   1. Probes the runner's current Ubuntu mirror plus fallbacks *in parallel*
#      and uses the fastest one for the main and security pockets.
#   2. Runs apt without -qq, so the log names the file in flight.
#   3. Downloads first in five-minute slices and installs from the local cache
#      afterwards.  A slice killed by `timeout` leaves
#      /var/cache/apt/archives/partial behind, so the next slice resumes
#      instead of starting over.
#   4. Bounds every wait: 15 s per connection, 120 s for the dpkg lock, and
#      `timeout -k` so a killed apt-get cannot leave a dpkg/postinst orphan
#      holding the lock.
#   5. Gives up after a 25-minute budget with a clear ::error:: instead of
#      running into the job timeout.
#
# Exit status is 0 only when every package is installed and the key tools
# (`ccache`, `dtc`, `flex`, `bison`, `make`, `python3`, `rsync`) resolve.
#
# Test hooks (unset in CI): INIT_ENV_SUDO ("" = no sudo), APT_DIR, WORKDIR,
# INIT_ENV_BUDGET.
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export TZ="${TZ:-Asia/Shanghai}"

APT_DIR=${APT_DIR:-/etc/apt}
SOURCES_DIR=$APT_DIR/sources.list.d
SOURCES_FILE=$SOURCES_DIR/ubuntu.sources
TARGET_WORKDIR=${WORKDIR:-/workdir}

# Seconds the whole apt phase may take.  A healthy run needs 2-5 minutes.
BUDGET=${INIT_ENV_BUDGET:-1500}
START=$SECONDS
budget_left() { echo $((BUDGET - (SECONDS - START))); }

say() { printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
warn() { echo "::warning::$*"; }
fatal() { echo "::error::$*"; say "giving up after $((SECONDS - START))s"; exit 1; }

if [[ -n ${INIT_ENV_SUDO+x} ]]; then
  SUDO=$INIT_ENV_SUDO
elif [[ $EUID -eq 0 ]]; then
  SUDO=
else
  SUDO=sudo
fi
run_root() {
  if [[ -n $SUDO ]]; then $SUDO -E "$@"; else "$@"; fi
}

# The same branch on the same runner image has taken 40 and 100 minutes for the
# *same* 244 package targets, so record the machine we actually got.  The
# Compile step prints its own thread count; this line names the CPU.
host_info() {
  local cpu cores mem disk
  cpu=$(LC_ALL=C lscpu 2>/dev/null | awk -F': +' '/^Model name/{print $2; exit}')
  cores=$(nproc 2>/dev/null)
  mem=$(awk '/^MemTotal/{printf "%.0fG", $2/1048576}' /proc/meminfo 2>/dev/null)
  disk=$(LC_ALL=C lsblk -dno NAME,MODEL 2>/dev/null | head -n1 | awk '{$1=""; sub(/^ /, ""); print}')
  printf 'cpu=%s cores=%s mem=%s disk=%s' "${cpu:-?}" "${cores:-?}" "${mem:-?}" "${disk:-?}"
}
say "host: $(host_info)"

APT_OPTS=(
  -o Acquire::ForceIPv4=true
  -o Acquire::Retries=2
  -o Acquire::http::Timeout=15
  -o Acquire::https::Timeout=15
  -o Acquire::Languages=none
  -o DPkg::Lock::Timeout=120
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
  -o Dpkg::Use-Pty=0
  -o APT::Color=0
  -o APT::Progress-Fancy=0
)

# Keep this list identical to the one the workflow used before: the union of
# what immortalwrt/lede need on ubuntu-24.04.
PKGS=(
  ack
  antlr3
  asciidoc
  autoconf
  automake
  autopoint
  binutils
  bison
  build-essential
  bzip2
  ccache
  clang
  cmake
  cpio
  curl
  device-tree-compiler
  ecj
  fastjar
  flex
  gawk
  gettext
  gcc-multilib
  g++-multilib
  git
  gnutls-dev
  gperf
  haveged
  help2man
  intltool
  lib32gcc-s1
  libc6-dev-i386
  libelf-dev
  libglib2.0-dev
  libgmp3-dev
  libltdl-dev
  libmpc-dev
  libmpfr-dev
  libncurses-dev
  libpython3-dev
  libreadline-dev
  libssl-dev
  libtool
  libyaml-dev
  libz-dev
  lld
  llvm
  lrzsz
  mkisofs
  msmtp
  nano
  ninja-build
  p7zip
  p7zip-full
  patch
  pkgconf
  python3
  python3-pip
  python3-ply
  python3-docutils
  python3-pyelftools
  qemu-utils
  re2c
  rsync
  scons
  squashfs-tools
  subversion
  swig
  texinfo
  uglifyjs
  upx-ucl
  unzip
  vim
  wget
  xmlto
  xxd
  zlib1g-dev
  zstd
)

run_apt() { # <seconds> <label> <apt-get args...>
  local limit=$1 label=$2 t0 rc
  shift 2
  t0=$SECONDS
  say "-> ${label} (limit ${limit}s)"
  run_root timeout -k 20 "$limit" apt-get "${APT_OPTS[@]}" "$@"
  rc=$?
  say "<- ${label} rc=${rc} after $((SECONDS - t0))s"
  return "$rc"
}

current_mirror() {
  [[ -r $SOURCES_FILE ]] || return 0
  awk '/^URIs:/{print $2; exit}' "$SOURCES_FILE" | sed 's#/*$##'
}

# ---------------------------------------------------------------- mirrors ---
declare -a MIRRORS=()
add_mirror() {
  local m=$1 i
  [[ $m =~ ^https?:// ]] || return 0
  for i in "${MIRRORS[@]:-}"; do
    [[ $i == "$m" ]] && return 0
  done
  MIRRORS+=("$m")
}

add_mirror "$(current_mirror)"
add_mirror http://azure.archive.ubuntu.com/ubuntu
add_mirror http://archive.ubuntu.com/ubuntu
add_mirror https://mirrors.edge.kernel.org/ubuntu
add_mirror http://mirror.math.princeton.edu/pub/ubuntu
add_mirror https://ftp.osuosl.org/pub/ubuntu
add_mirror http://ftp.ubuntu.com/ubuntu

WORK_LOG=$(mktemp -d)
PROBE_FILE=$(mktemp)
SEC_FILE=$(mktemp)

# A 1 MiB metadata file is usually served from a mirror cache and says little
# about sustained throughput: on 2026-11-20 azure probed fastest at 2.6 MB/s
# and then delivered 200-600 kB/s during the actual download.  Sample 8 MiB of
# the much larger Contents index instead, and fall back to the Packages index
# only for mirrors that do not publish it, so the ranking reflects the speed
# the download will actually see.
probe_one() { # <mirror>
  local mirror=$1 speed
  speed=$(curl -fsSL --max-time 25 --range 0-8388607 -o /dev/null \
    -w '%{speed_download}' \
    "$mirror/dists/noble/Contents-amd64.gz" 2>/dev/null) || speed=0
  speed=${speed%.*}
  [[ $speed =~ ^[0-9]+$ ]] || speed=0
  if ((speed == 0)); then
    speed=$(curl -fsSL --max-time 15 --range 0-1048575 -o /dev/null \
      -w '%{speed_download}' \
      "$mirror/dists/noble/main/binary-amd64/Packages.gz" 2>/dev/null) || speed=0
    speed=${speed%.*}
    [[ $speed =~ ^[0-9]+$ ]] || speed=0
  fi
  printf '%s\t%s\n' "$speed" "$mirror" >>"$PROBE_FILE"
}

# noble-security lives on a different host for some mirrors and on the same
# archive for others.  Find one that answers *before* writing sources: pointing
# apt at a dead security host costs ~100 s of connect timeouts per update
# (2026-11-19: security.ubuntu.com was dead and apt still reported success).
probe_sec() { # <mirror>
  local mirror=$1
  if curl -fsS --max-time 10 -o /dev/null "$mirror/dists/noble-security/Release" 2>/dev/null; then
    echo "$mirror" >>"$SEC_FILE"
  fi
}

# Rank every candidate by measured throughput and pick the security host that
# actually answers.  Called once at the start, and again whenever a download
# slice runs out of time on the mirror we picked.
probe_rank() {
  local speed mirror m
  : >"$PROBE_FILE"
  : >"$SEC_FILE"
  say "probing ${#MIRRORS[@]} Ubuntu mirrors (8 MiB of noble/Contents-amd64.gz) in parallel"
  for m in "${MIRRORS[@]}"; do probe_one "$m" & done
  wait
  mapfile -t RANKED < <(sort -rn "$PROBE_FILE" | cut -f2)
  if [[ ${#RANKED[@]} -eq 0 ]]; then
    warn "mirror probe returned nothing; keeping the runner's own sources"
    RANKED=("$(current_mirror)")
  fi
  while IFS=$'\t' read -r speed mirror; do
    printf '  %7s KiB/s  %s\n' "$((speed / 1024))" "$mirror"
  done < <(sort -rn "$PROBE_FILE")
  BEST=${RANKED[0]}
  BEST_SPEED=$(awk -F'\t' -v m="$BEST" '$2==m{print $1}' "$PROBE_FILE" | head -n1)
  BEST_SPEED=${BEST_SPEED:-0}
  if ((BEST_SPEED < 200000)); then
    warn "fastest mirror is only $((BEST_SPEED / 1024)) KiB/s; downloads may be slow"
  fi

  say "checking which mirrors carry noble-security"
  for m in "${RANKED[@]}"; do probe_sec "$m" & done
  wait
  SEC_MIRROR=
  for m in "${RANKED[@]}"; do
    if grep -qxF "$m" "$SEC_FILE" 2>/dev/null; then
      SEC_MIRROR=$m
      break
    fi
  done
  if [[ -n $SEC_MIRROR ]]; then
    say "security pocket will come from $SEC_MIRROR"
  else
    warn "no probed mirror carries noble-security; dropping that pocket from the sources"
  fi
}

probe_rank

write_sources() { # <mirror> [security-mirror]
  local main=$1 sec=${2:-}
  {
    cat <<EOF
Types: deb
URIs: $main/
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    if [[ -n $sec ]]; then
      cat <<EOF

Types: deb
URIs: $sec/
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    fi
  } | run_root tee "$SOURCES_FILE" >/dev/null
}

if [[ -d $SOURCES_DIR ]]; then
  run_root find "$SOURCES_DIR" -type f ! -name ubuntu.sources -delete
  if [[ -r $SOURCES_FILE && ! -e $SOURCES_FILE.dist ]]; then
    run_root cp "$SOURCES_FILE" "$SOURCES_FILE.dist"
  fi
fi

# ------------------------------------------------------------- apt update ---
UPDATE_LOG=$WORK_LOG/apt-update.log
update_on() { # <mirror>
  local m=$1 t0 rc
  write_sources "$m" "$SEC_MIRROR"
  say "-> apt-get update via $m (security: ${SEC_MIRROR:-none})"
  t0=$SECONDS
  set -o pipefail
  run_root timeout -k 20 240 apt-get "${APT_OPTS[@]}" update 2>&1 | tee "$UPDATE_LOG"
  rc=${PIPESTATUS[0]}
  say "<- apt-get update rc=${rc} after $((SECONDS - t0))s"
  return "$rc"
}

# A slice that runs out of time means the mirror we picked cannot keep up.
# Probe again and move to a different one: apt resumes from partial/, so the
# bytes already fetched are kept.  This is the difference between waiting out a
# slow evening mirror (2026-11-20: three 300 s slices with almost no progress)
# and switching to one that is fast right now.
switch_mirror() {
  local cur pick m
  cur=$(current_mirror)
  probe_rank
  pick=
  for m in "${RANKED[@]}"; do
    [[ $m == "$cur" ]] && continue
    pick=$m
    break
  done
  [[ -n $pick ]] || pick=$BEST
  say "switching $cur -> $pick after a slow slice"
  update_on "$pick" || { warn "apt-get update via $pick failed"; return 1; }
  return 0
}

UPDATED=0
CLEAN=0
for m in "${RANKED[@]:0:3}"; do
  if update_on "$m"; then
    UPDATED=1
    if grep -q "Failed to fetch" "$UPDATE_LOG"; then
      warn "apt-get update via $m left a pocket unfetched; trying the next mirror"
    else
      CLEAN=1
      break
    fi
  else
    warn "apt-get update failed on $m"
  fi
done
((UPDATED)) || fatal "apt-get update failed on every probed mirror"
((CLEAN)) || warn "continuing with incomplete package indexes"

# --------------------------------------------------------------- packages ---
MISSING=()
for p in "${PKGS[@]}"; do
  status=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || true)
  [[ $status == *"install ok installed"* ]] || MISSING+=("$p")
done
say "${#MISSING[@]} of ${#PKGS[@]} packages are not installed yet"

if ((${#MISSING[@]} == 0)); then
  say "nothing to install"
else
  DL_OK=0
  SWITCHES=0
  for slice in $(seq 1 8); do
    left=$(budget_left)
    if ((left < 120)); then
      fatal "out of time before the download finished ($(du -sh /var/cache/apt/archives/partial 2>/dev/null | cut -f1) cached)"
    fi
    limit=$((left < 300 ? left : 300))
    run_apt "$limit" "download slice $slice" -y install --download-only "${MISSING[@]}"
    rc=$?
    if ((rc == 0)); then
      DL_OK=1
      break
    fi
    warn "download slice $slice stopped early (rc=$rc); partial files are kept for the next slice"
    # 124 is `timeout`: the mirror is too slow right now, not broken.  Try a
    # different one before spending another full slice on it.
    if ((rc == 124 && SWITCHES < 2)); then
      SWITCHES=$((SWITCHES + 1))
      switch_mirror || warn "keeping the current mirror"
    fi
  done
  ((DL_OK)) || fatal "package download did not finish within the ${BUDGET}s budget"

  run_apt 900 "install from local cache" \
    -y --no-download install "${MISSING[@]}" ||
    fatal "installing the downloaded packages failed"
fi

# ------------------------------------------------------------------ tidy ----
run_apt 240 "autoremove" -y autoremove --purge || warn "autoremove failed"
run_apt 120 "apt-get clean" clean || warn "apt-get clean failed"

run_root timedatectl set-timezone "$TZ" || warn "could not set timezone to $TZ"
run_root mkdir -p "$TARGET_WORKDIR"
run_root chown "$(id -un):$(id -gn)" "$TARGET_WORKDIR"

for tool in ccache dtc flex bison make python3 rsync; do
  command -v "$tool" >/dev/null || fatal "$tool is still missing after the install"
done
say "initialization finished in $((SECONDS - START))s; $(ccache --version | head -n1)"
