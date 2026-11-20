#!/usr/bin/env bash
# Download every source package the build needs -- bounded, retried, visible.
#
# Why this exists: `make download` drives scripts/download.pl, which hands curl
# only `--connect-timeout 5 --retry 3 --location`. There is no transfer
# timeout, so a connection that completes the handshake and then stops sending
# data hangs forever, and the phase prints nothing while it waits. On
# 2026-11-20 the r4pro build spent 616 s in one silent gap that way: the step
# looked dead, produced no log lines, and each extra minute came out of the
# job's 360 minute ceiling. This wrapper fixes the three parts of that:
#
#   * bounds every transfer. download.pl appends $CURL_OPTIONS to the curl
#     command line and later options win, so --speed-time/--speed-limit apply
#     (a transfer is aborted only after 90 s below 4 KB/s -- a slow but moving
#     mirror is unaffected). The git based download methods get
#     GIT_HTTP_LOW_SPEED_*.
#   * bounds the phase. make download runs in time slices under a total
#     budget, retried up to three times. dl/ stays on disk between attempts,
#     so a retry resumes instead of starting over; the step fails with an
#     explicit ::error:: only when the budget is gone.
#   * makes stalls visible. Every line is timestamped and a heartbeat prints
#     dl/ and tmp/dl sizes plus the number of live curl/git processes every
#     30 s, so the next stall names itself instead of costing an hour of
#     guesswork. The first attempt runs make with V=w (stderr passes through,
#     which is where download.pl prints "+ curl ..."); retries run V=s so the
#     full command trace is in the log when the first attempt did not finish.
#
# Knobs (all optional):
#   DOWNLOAD_DIR            source tree to download for   (openwrt)
#   DOWNLOAD_JOBS           make -j                        (8)
#   DOWNLOAD_BUDGET         total seconds for all attempts  (2400)
#   DOWNLOAD_ATTEMPT_LIMIT  ceiling for one attempt         (1200)
#   DOWNLOAD_ATTEMPTS       number of attempts              (3)
#   DOWNLOAD_HEARTBEAT      heartbeat period in seconds     (30)
set -uo pipefail

DIR=${DOWNLOAD_DIR:-openwrt}
JOBS=${DOWNLOAD_JOBS:-8}
BUDGET=${DOWNLOAD_BUDGET:-2400}
ATTEMPT_LIMIT=${DOWNLOAD_ATTEMPT_LIMIT:-1200}
ATTEMPTS=${DOWNLOAD_ATTEMPTS:-3}
HB=${DOWNLOAD_HEARTBEAT:-30}

now() { date -u +%H:%M:%S; }
log() { printf '%s %s\n' "$(now)" "$*"; }

# download.pl only reaches curl if the tree is new enough to read CURL_OPTIONS;
# an older tree ignores it silently, so say so instead of pretending.
export CURL_OPTIONS=${CURL_OPTIONS:---retry 5 --retry-delay 5 --retry-connrefused --speed-time 90 --speed-limit 4096}
export GIT_HTTP_LOW_SPEED_LIMIT=${GIT_HTTP_LOW_SPEED_LIMIT:-4096}
export GIT_HTTP_LOW_SPEED_TIME=${GIT_HTTP_LOW_SPEED_TIME:-90}
export GIT_TERMINAL_PROMPT=0

# Timestamp every line of the streamed output. perl is part of the build
# toolchain, so this needs no new package (the runner's awk is mawk, which has
# no strftime).
stamp_stream() {
  perl -pe 'BEGIN { $| = 1 } my @t = gmtime; $_ = sprintf("%02d:%02d:%02d %s", $t[2], $t[1], $t[0], $_)'
}

# git based download methods clone into tmp/dl and only move the finished
# tarball into dl/ at the end, so dl/ alone can look frozen while a clone is
# running; the staging size and the live process counts show that work.
staging_size() { [[ -d tmp/dl ]] && du -sh tmp/dl 2>/dev/null | cut -f1 || echo '-'; }
procs() { local n; n=$(pgrep -c -x "$1" 2>/dev/null) || n=0; echo "${n:-0}"; }

heartbeat() {
  local newest
  while sleep "$HB"; do
    newest=$(ls -t "$DL" 2>/dev/null | head -1)
    printf '%s [heartbeat] dl/ %s (%s files), staging %s, curl=%s git=%s, newest: %s\n' \
      "$(now)" "$(dl_size)" "$(dl_count)" "$(staging_size)" "$(procs curl)" "$(procs git)" "${newest:-none}"
  done
}

# dl/ does not exist until make creates it, so report "-" rather than "?".
dl_size() { [[ -d $DL ]] && du -sh "$DL" 2>/dev/null | cut -f1 || echo '-'; }
dl_count() { find "$DL" -type f 2>/dev/null | wc -l; }

# One bounded `make download` run. The download runs in its own session so the
# whole process group can be killed on timeout -- `timeout` would only signal
# make itself, leaving orphaned curl/git children writing into dl/ while the
# next attempt starts. Returns 124 when the slice expired.
run_slice() { # <seconds> [verbosity]
  local limit=$1 vopt=${2:-w} pid state deadline
  setsid bash -c "exec make download -j$JOBS V=$vopt" &
  pid=$!
  deadline=$(( $(date +%s) + limit ))
  while :; do
    kill -0 "$pid" 2>/dev/null || break
    state=$(sed -n 's/^[0-9]* (.*) \(.\).*/\1/p' "/proc/$pid/stat" 2>/dev/null)
    [[ $state == Z ]] && break
    if (( $(date +%s) >= deadline )); then
      log "slice reached ${limit}s; terminating the download process group"
      kill -TERM -- "-$pid" 2>/dev/null || true
      sleep 5
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 2
  done
  wait "$pid"
}

# Stub files: download.pl creates a small empty placeholder for optional
# sources that are missing upstream. They are reported and then removed, as
# the step always did -- a 0 byte file in dl/ would otherwise be extracted.
drop_stubs() {
  find "$DL" -size -1024c -exec ls -l {} \; 2>/dev/null | stamp_stream
  find "$DL" -size -1024c -exec rm -f {} \; 2>/dev/null || true
}

[[ -d $DIR ]] || { log "::error::$DIR does not exist"; exit 1; }
cd "$DIR"
# From here on dl/ is relative to the tree we just entered.
DL=dl

log "curl: $CURL_OPTIONS"
log "git: low-speed-limit=$GIT_HTTP_LOW_SPEED_LIMIT low-speed-time=$GIT_HTTP_LOW_SPEED_TIME"
if ! grep -qs CURL_OPTIONS scripts/download.pl; then
  log "::warning::scripts/download.pl does not read CURL_OPTIONS; transfers are unbounded"
fi

log "make defconfig"
if ! make defconfig 2>&1 | stamp_stream; then
  rc=${PIPESTATUS[0]}
  log "::error::make defconfig failed (rc=$rc)"
  exit 1
fi

start=$(date +%s)
attempt=0
ok=0
heartbeat &
hb_pid=$!
trap 'kill "$hb_pid" 2>/dev/null || true' EXIT

while (( attempt < ATTEMPTS )); do
  attempt=$((attempt + 1))
  left=$((BUDGET - ($(date +%s) - start)))
  if (( left < 180 )); then
    log "no budget left for another attempt (${left}s)"
    break
  fi
  limit=$((left < ATTEMPT_LIMIT ? left : ATTEMPT_LIMIT))
  # Only stderr (where download.pl prints "+ curl ...") on the first attempt;
  # a retry means the first one did not finish, so keep the full trace.
  vopt=w
  (( attempt > 1 )) && vopt=s
  log "download attempt $attempt/$ATTEMPTS (slice ${limit}s, V=$vopt, budget left ${left}s, dl/ $(dl_size), $(dl_count) files)"
  run_slice "$limit" "$vopt" 2>&1 | stamp_stream
  rc=${PIPESTATUS[0]}
  if (( rc == 0 )); then
    ok=1
    break
  fi
  log "::warning::download attempt $attempt failed (rc=$rc, dl/ $(dl_size), $(dl_count) files)"
  # Placeholders left for optional sources would be retried as failures; drop
  # the stubs only, real partial files stay so the next attempt resumes.
  drop_stubs
done

kill "$hb_pid" 2>/dev/null || true
trap - EXIT

if (( ok == 0 )); then
  log "::error::make download failed after $attempt attempt(s) in $(( $(date +%s) - start ))s (dl/ $(dl_size), $(dl_count) files)"
  exit 1
fi

drop_stubs
log "download finished in $(( $(date +%s) - start ))s after $attempt attempt(s): dl/ $(dl_size), $(dl_count) files"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  echo "status=success" >>"$GITHUB_OUTPUT"
fi
