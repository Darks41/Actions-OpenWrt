#!/usr/bin/env bash
# "Free space" for the OpenWrt builder.
#
# This replaces `uses: Darks41/free-disk-space@ubuntu-24.04`, which does the
# same deletions but has no time bounds and no timing information.  On
# 2026-11-19 the step took 104 s (snapshot), 116 s (LEDE), 124 s (ac5s) and
# 149 s (r4pro); in every case apt finished 35-48 s before the step did,
# because the step ends by waiting for background `rm -rf` jobs that are
# sensitive to the runner's disk throughput.
#
# What this script changes, with the deletion set kept identical (the build
# grows by 66-72 GiB, so we still need the same ~107 GiB):
#   1. Stops the apt-daily / unattended-upgrades timers first, so a background
#      apt run cannot hold the dpkg lock while we remove packages.
#   2. Pre-reads /var/lib/apt/lists so the first `Reading package lists...`
#      does not wait for the rm storm to finish.
#   3. Starts `docker image prune` before the removals, in the background.
#   4. Removes the Android SDK per top-level directory, up to 8 in parallel --
#      it is the biggest tree (12-14 GiB) and single-threaded `rm -rf` on it
#      is what pushes the tail of the step past 40 s.
#   5. Removes packages and their orphans in one apt transaction, so dpkg
#      walks the 216k-file database once instead of twice.
#   6. Drops the `df -a` dumps, bounds every command with `timeout -k`, and
#      prints one line per phase with its duration.
#
# Test hooks (unset in CI): FS_SUDO ("" = no sudo), FS_ROOT (path prefix for
# every deletion and tool-cache lookup), FS_SKIP_APT=1.
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_SUSPEND=1
export TZ="${TZ:-Asia/Shanghai}"

PREFIX=${FS_ROOT:-}
START=$SECONDS
WORK=$(mktemp -d)
DONE=$WORK/done
: >"$DONE"

say() { printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
warn() { echo "::warning::$*"; }

if [[ -n ${FS_SUDO+x} ]]; then
  SUDO=$FS_SUDO
elif [[ $EUID -eq 0 ]]; then
  SUDO=
else
  SUDO=sudo
fi
run_root() {
  if [[ -n $SUDO ]]; then $SUDO "$@"; else "$@"; fi
}

avail_kb() { df -k / 2>/dev/null | awk 'NR==2 {print $4}'; }
dfh() { df -h / 2>/dev/null | awk 'NR==2 {print $3" used of "$2", "$4" avail ("$5")"}'; }

note() { printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$DONE"; }

# One timed, bounded deletion; records its own outcome for the summary.
rm_paths() { # <label> <seconds> <path>...
  local label=$1 secs=$2 t0=$SECONDS rc=0
  shift 2
  run_root timeout -k 10 "$secs" rm -rf -- "$@" || rc=$?
  case $rc in
  0) note "$label" "$((SECONDS - t0))" ok ;;
  124) note "$label" "$((SECONDS - t0))" "timeout after ${secs}s" ;;
  *) note "$label" "$((SECONDS - t0))" "rc=$rc" ;;
  esac
}

bg_rm() { # <label> <seconds> <path>...
  local label=$1 secs=$2
  shift 2
  (rm_paths "$label" "$secs" "$@") &
}

# The big trees (android, dotnet, tool cache) are handed to a small worker
# pool instead of one `rm -rf` that cannot use more than one CPU/queue.  A tree
# with a single top-level entry -- android/sdk is the common case, 12-14 GiB
# behind one directory -- is split one level deeper first, otherwise the pool
# would still have exactly one job.
bg_rm_children() { # <label> <dir> <seconds>
  local label=$1 dir=$2 secs=$3
  (
    local target=$dir depth=0 kid n=0
    local -a kids=()
    while :; do
      mapfile -d '' -t kids < <(find "$target" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
      if ((${#kids[@]} == 1 && depth < 2)) && [[ -d ${kids[0]} ]]; then
        target=${kids[0]}
        depth=$((depth + 1))
        continue
      fi
      break
    done
    if ((${#kids[@]} == 0)); then
      rm_paths "$label" "$secs" "$target"
    else
      for kid in "${kids[@]}"; do
        (rm_paths "$label/${kid#"$dir"/}" "$secs" "$kid") &
        n=$((n + 1))
        ((n % 8 == 0)) && wait -n
      done
      wait
    fi
    # Remove what is left of the skeleton (empty directories, a few files).
    run_root timeout -k 10 60 rm -rf -- "$dir" 2>/dev/null || true
  ) &
}

APT_PKGS=(
  google-chrome-stable firefox microsoft-edge-stable
  azure-cli google-cloud-cli
  rustc cargo
  '^openjdk-.*' '^temurin-.*' '^msopenjdk-.*'
  maven gradle ant
  '^aspnetcore-.*' '^dotnet-.*' '^llvm-.*' 'php.*'
  '^mongodb-.*' '^mysql-.*' '^postgresql-.*'
  mono-devel libgl1-mesa-dri
)
APT_OPTS=(
  -o DPkg::Lock::Timeout=180
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
  -o Dpkg::Use-Pty=0
  -o APT::Color=0
  -o APT::Progress-Fancy=0
  -o Acquire::ForceIPv4=true
  -o Acquire::http::Timeout=15
  -o Acquire::https::Timeout=15
)

say "freeing disk space; before: $(dfh)"
BEFORE=$(avail_kb)
[[ $BEFORE =~ ^[0-9]+$ ]] || BEFORE='' 

# 1. No background apt runs while we uninstall.
t0=$SECONDS
run_root systemctl stop \
  apt-daily.service apt-daily.timer \
  apt-daily-upgrade.service apt-daily-upgrade.timer \
  unattended-upgrades.service 2>/dev/null || true
say "apt timers stopped in $((SECONDS - t0))s"

# 2. Warm the package-list cache, so the first `Reading package lists...`
#    does not compete with the deletions below.
t0=$SECONDS
cat /var/lib/apt/lists/*_Packages* >/dev/null 2>&1 || true
say "apt lists warmed in $((SECONDS - t0))s"

# 3. The container images are only needed by Actions itself; start early.
if command -v docker >/dev/null 2>&1; then
  (
    t0=$SECONDS
    rc=0
    run_root timeout -k 10 240 docker image prune --all --force >"$WORK/docker.log" 2>&1 || rc=$?
    note "docker prune" "$((SECONDS - t0))" "$( ((rc == 0)) && echo ok || echo "rc=$rc")"
  ) &
  say "docker image prune started in the background"
else
  say "docker not present; skipping image prune"
fi

# 4. The SDK/runtime trees. Same set as the action we replace.
bg_rm_children "rm android" "$PREFIX/usr/local/lib/android" 240
bg_rm_children "rm dotnet" "$PREFIX/usr/share/dotnet" 120
bg_rm "rm haskell" 120 "$PREFIX/opt/ghc" "$PREFIX/usr/local/.ghcup"
bg_rm "rm browsers" 120 \
  "$PREFIX/usr/local/share/chromium" \
  "$PREFIX/usr/local/share/chromedriver-linux64" \
  "$PREFIX/usr/local/share/gecko_driver" \
  "$PREFIX/usr/local/share/geckodriver" \
  "$PREFIX/usr/local/share/edge_driver" \
  "$PREFIX/usr/share/java/selenium-server.jar"
bg_rm "rm java/rust caches" 120 \
  "$PREFIX/usr/share/maven" "$PREFIX/usr/share/gradle" "$PREFIX/usr/share/ant" \
  "$PREFIX/usr/share/rust" "$PREFIX/home/runner/.rustup" "$PREFIX/home/runner/.cargo" \
  "$PREFIX/root/.cache/pip" "$PREFIX/root/.cache/npm" "$PREFIX/root/.cache/pipenv" \
  "$PREFIX/home/linuxbrew/.cache/Homebrew"
TOOLCACHE=${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}
bg_rm_children "rm tool cache" "$PREFIX$TOOLCACHE" 240

# 5. Packages, in a single transaction (remove + orphan sweep).
if [[ ${FS_SKIP_APT:-0} == 1 ]]; then
  say "apt removal skipped (FS_SKIP_APT=1)"
elif command -v apt-get >/dev/null 2>&1; then
  t0=$SECONDS
  rc=0
  run_root timeout -k 20 420 apt-get -y --auto-remove --fix-missing \
    "${APT_OPTS[@]}" remove "${APT_PKGS[@]}" || rc=$?
  note "apt remove" "$((SECONDS - t0))" "$( ((rc == 0)) && echo ok || echo "rc=$rc")"
  t0=$SECONDS
  run_root timeout -k 10 120 apt-get clean || true
  note "apt clean" "$((SECONDS - t0))" ok
  if command -v pip3 >/dev/null 2>&1; then
    run_root timeout -k 5 60 pip3 uninstall -y awscli >/dev/null 2>&1 || true
  fi
  if command -v snap >/dev/null 2>&1; then
    run_root timeout -k 5 90 snap remove aws-cli >/dev/null 2>&1 || true
  fi
else
  say "apt-get not present; skipping package removal"
fi

# 6. Swap files: the runner usually has none, but a swapfile can hold a lot of
#    the growth we need to give back.
t0=$SECONDS
if swapon --show --noheadings 2>/dev/null | grep -q .; then
  while read -r swapfile; do
    run_root timeout -k 10 60 swapoff "$swapfile" || warn "could not swapoff $swapfile"
    run_root timeout -k 10 30 rm -f "$PREFIX$swapfile" || true
  done < <(swapon --show --noheadings --raw 2>/dev/null | awk '{print $1}' | grep -E '^/')
  note "remove swap" "$((SECONDS - t0))" ok
else
  say "no swap to remove"
fi

# 7. Collect the background work, then report.
wait
say "background removals done"

AFTER=$(avail_kb)
[[ $AFTER =~ ^[0-9]+$ ]] || AFTER=''
say "after: $(dfh)"

while IFS='|' read -r label secs status; do
  [[ -n $label ]] || continue
  printf '[free-space] %-26s %4ss  %s\n' "$label" "$secs" "$status"
done < <(sort "$DONE")

TOTAL=$((SECONDS - START))
if [[ -n $BEFORE && -n $AFTER && $BEFORE -gt 0 ]]; then
  printf '[free-space] reclaimed %s MiB (%s GiB -> %s GiB free)\n' \
    "$(((AFTER - BEFORE) / 1024))" "$((BEFORE / 1048576))" "$((AFTER / 1048576))"
  if ((AFTER < 80 * 1048576)); then
    warn "only $((AFTER / 1048576)) GiB free after cleanup; the build grows by 66-72 GiB"
  fi
fi
say "free-space finished in ${TOTAL}s"
