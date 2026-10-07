#!/bin/bash
#
# preflight.sh - run before the firmware build.
#
# The r4pro branch carries two out-of-tree kernel patches that work around
# problems in the upstream/OpenWrt code:
#
#   760-18-net-dsa-mxl862xx-select-pcs-ops-after-fw-probe.patch
#   761-net-sfp-add-quirk-for-OEM-SFP-XG-T-H-2.5G-copper-module.patch
#
# Upstream may fix either problem at any time, and then the patches become
# obsolete - or worse, stop applying and break the build.  This script checks,
# before the (three hour) firmware build:
#
#   * whether the pristine kernel sources of the version that is about to be
#     built already contain the fix (patch obsolete), or no longer provide the
#     symbol the patch relies on (patch needs rework);
#   * whether the tree's own kernel patch series (target/linux/generic/*) has
#     meanwhile started providing the fix - this matters for the mxl862xx DSA
#     driver, which is not an upstream file but ships in the 760-xx series;
#   * whether every patch in patches/ is present, non-empty, a unified diff and
#     actually installed into target/linux/generic/pending-*;
#   * whether the patches still apply (make target/linux/prepare) and whether
#     they really ended up in the prepared kernel tree.
#
# If anything says "this patch should not be applied any more", the firmware
# build is skipped and the reason is printed in the log, written to the job
# summary and exported as the `skip`/`reason` step outputs.
#
# Upstream fixes are added to the table below: <tag>|<file>|<marker that means
# the fix is already there>|<symbol the patch needs>|<what the patch does>.
#
# Exit status: 0 always, unless something unexpected happened.  The decision is
# exported through $GITHUB_OUTPUT as `skip` (true/false) and `reason`.
#
# Environment:
#   SRC              source tree to check          (default: openwrt)
#   PATCH_DIR        directory holding *.patch     (default: $GITHUB_WORKSPACE/patches)
#   PATCH_BASE_VERSION  kernel version the patches were written for (default
#                       below); any other tree of the same series is accepted,
#                       only a different series is refused
#   GITHUB_OUTPUT    optional, as provided by GitHub Actions
#   GITHUB_STEP_SUMMARY  optional, as provided by GitHub Actions
#
set -uo pipefail

SRC="${SRC:-openwrt}"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
PATCH_DIR="${PATCH_DIR:-$GITHUB_WORKSPACE/patches}"

# The two patches were written and tested against this kernel version.  Every
# tree of the same series (6.18.x) is fine: whether the patches still fit is not
# guessed from the version but verified below by actually applying them.  A
# different series has a different mxl862xx DSA driver (781-04/760-16 select the
# PCS ops with `pcs->pcs.ops`, the SerDes port lookup still looks different) and
# a different sfp.c, so patching it is not appropriate - a bad or pointless
# build must not be produced silently.
PATCH_BASE_VERSION="${PATCH_BASE_VERSION:-6.18.54}"
PATCH_BASE_SERIES="${PATCH_BASE_VERSION%.*}"

SKIP_REASONS=()
NOTES=()
VANILLA_OK=0

note() { printf '%s\n' "$*"; }
add_skip() { SKIP_REASONS+=("$*"); }
add_note() { NOTES+=("$*"); }
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; }

# ---------------------------------------------------------------------------
# 1. Which kernel is this build going to use?
# ---------------------------------------------------------------------------
PATCHVER="$(sed -n 's/^CONFIG_LINUX_\([0-9][0-9]*\)_\([0-9][0-9]*\)=y$/\1.\2/p' "$SRC/.config" 2>/dev/null | head -1)"
[ -n "$PATCHVER" ] || PATCHVER="6.18"
SUFFIX="$(sed -n "s/^LINUX_VERSION-$PATCHVER *= *//p" "$SRC/target/linux/generic/kernel-$PATCHVER" 2>/dev/null | head -1)"
KV="$PATCHVER$SUFFIX"
note "==> preflight: target kernel $KV (series $PATCHVER), source tree $SRC"

KV_SERIES="${KV%.*}"
if [ "$KV_SERIES" != "$PATCH_BASE_SERIES" ]; then
	add_skip "the sources would build kernel $KV ($KV_SERIES series), but these patches were written for the $PATCH_BASE_SERIES series ($PATCH_BASE_VERSION): a different kernel series has a different mxl862xx driver and sfp.c, so patching it is not appropriate"
elif [ "$KV" != "$PATCH_BASE_VERSION" ]; then
	add_note "sources build kernel $KV, the patches were written for $PATCH_BASE_VERSION (same $KV_SERIES series, so this is fine - the patches are applied and checked below)"
fi

# ---------------------------------------------------------------------------
# 2. Which patches does this branch carry?  (their file names are used below to
#    tell "the tree already fixes it" apart from "our own patch does".)
# ---------------------------------------------------------------------------
PATCH_FILES=()
OWN_FILES=()
for f in "$PATCH_DIR"/*.patch; do
	[ -e "$f" ] || continue
	PATCH_FILES+=("$f")
	OWN_FILES+=("$(basename "$f")")
done

is_own_patch() {
	local base="$1" own
	for own in ${OWN_FILES[@]+"${OWN_FILES[@]}"}; do
		[ "$base" = "$own" ] && return 0
	done
	return 1
}

# Print the tree's kernel patches (other than ours) that *add* a line matching
# the given ERE.  This is how a fix that arrived with the tree's own patch
# series - rather than with a new upstream kernel - is detected.
tree_patches_adding() {
	local re="$1" hit
	while IFS= read -r hit; do
		[ -n "$hit" ] || continue
		is_own_patch "$(basename "$hit")" && continue
		printf '%s\n' "$hit"
	done < <(grep -l -E "^\+.*$re" \
		"$SRC/target/linux/generic/backport-$PATCHVER"/*.patch \
		"$SRC/target/linux/generic/pending-$PATCHVER"/*.patch 2>/dev/null || true)
}

# ---------------------------------------------------------------------------
# 3. Extract the pristine sources of the files the patches touch.
# ---------------------------------------------------------------------------
TARBALL="$SRC/dl/linux-$KV.tar.xz"
VANILLA="$(mktemp -d)"
MXL_PHYLINK="drivers/net/dsa/mxl862xx/mxl862xx-phylink.c"
SFP_C="drivers/net/phy/sfp.c"

if [ -f "$TARBALL" ]; then
	for f in "$MXL_PHYLINK" "$SFP_C"; do
		tar -xJf "$TARBALL" -C "$VANILLA" --strip-components=1 "linux-$KV/$f" 2>/dev/null || true
	done
	VANILLA_OK=1
	note "==> preflight: inspecting pristine sources from $(basename "$TARBALL")"
else
	add_note "kernel tarball $TARBALL is missing, the pristine upstream sources could not be inspected"
	note "::warning::preflight: $TARBALL not found, skipping the pristine-source checks"
fi

# ---------------------------------------------------------------------------
# 4. Is any of the fixes already in the sources (upstream kernel or the tree's
#    own patch series)?  If so the corresponding patch must not be applied.
# ---------------------------------------------------------------------------
CHECKS=(
	"760-18|$MXL_PHYLINK|serdes_ports\\[port.*\\.pcs\\.ops = &mxl862xx_pcs_ops;||make the mxl862xx SerDes port select the real PCS ops"
	"761|$SFP_C|SFP_QUIRK_S\\(\"OEM\", \"SFP\\+XG-T-H\"|sfp_quirk_disable_autoneg|disable autonegotiation for the OEM SFP+XG-T-H copper module"
)

for entry in "${CHECKS[@]}"; do
	IFS='|' read -r ptag file marker need desc <<<"$entry"
	state="needed"

	if [ "$VANILLA_OK" = 1 ] && [ -f "$VANILLA/$file" ]; then
		if grep -qE "$marker" "$VANILLA/$file"; then
			add_skip "patch $ptag is obsolete: the pristine $KV sources already $desc"
			continue
		fi
		if [ -n "$need" ] && ! grep -q "$need" "$VANILLA/$file"; then
			add_skip "patch $ptag needs rework: the pristine $KV $file no longer provides $need"
			continue
		fi
	else
		# Not an upstream file (the mxl862xx DSA driver ships in the tree's own
		# 760-xx patch series), so only the tree's patch series can be checked.
		if [ "$VANILLA_OK" = 1 ]; then
			add_note "$file is not an upstream $KV file (provided by the tree's patch series), checking the tree's patches instead"
		fi
	fi

	FIXERS="$(tree_patches_adding "$marker")"
	if [ -n "$FIXERS" ]; then
		add_skip "patch $ptag is obsolete: the tree's own kernel patch series already contains a fix that would $desc ($(printf '%s ' $FIXERS))"
		continue
	fi

	[ "$state" = needed ] && add_note "patch $ptag still needed: nothing under target/linux/generic/{backport,pending}-$PATCHVER $desc yet"
done

# ---------------------------------------------------------------------------
# 5. Are the patch files present, non-empty and installed into the tree?
# ---------------------------------------------------------------------------
if [ "${#PATCH_FILES[@]}" -eq 0 ]; then
	add_skip "no patches found in $PATCH_DIR, nothing would fix the sfp-lan problem"
fi

for f in ${PATCH_FILES[@]+"${PATCH_FILES[@]}"}; do
	name="$(basename "$f")"
	if [ ! -s "$f" ]; then
		add_skip "$name is empty"
		continue
	fi
	if ! grep -q '^+++ ' "$f"; then
		add_skip "$name does not look like a unified diff (no '+++' file header)"
	fi
	if [ ! -e "$SRC/target/linux/generic/pending-$PATCHVER/$name" ]; then
		add_skip "$name was not installed into target/linux/generic/pending-$PATCHVER by diy-part2.sh"
	fi
done

# ---------------------------------------------------------------------------
# 6. Apply the patches (this is what the build would do anyway) and see
#    whether they still fit.  A plain `patch` conflict is a skip; anything
#    else is reported as a warning and left to the real build.
# ---------------------------------------------------------------------------
PREPARED=0
STAMP="$(ls "$SRC"/build_dir/target-*/linux-*/linux-*/.prepared_* 2>/dev/null | head -1)"
if [ "${#SKIP_REASONS[@]}" -eq 0 ] && [ -n "$STAMP" ]; then
	# The kernel was already unpacked and patched (the CI runner starts clean,
	# but a local run may not).  Re-running the patch step on an already patched
	# tree would produce bogus conflicts, so the patches are only inspected.
	PREPARED=1
	add_note "a prepared kernel tree ($(basename "$(dirname "$STAMP")")) is already present, skipping the patch application check"
elif [ "${#SKIP_REASONS[@]}" -eq 0 ]; then
	PREP_LOG="$(mktemp)"
	note "==> preflight: applying kernel patches (make target/linux/prepare V=s -j1)"
	# PATCH_DIR is our own variable, but make would import it from the
	# environment and mistake it for the platform patch directory, so it is
	# explicitly dropped for the make run.
	if ( cd "$SRC" && env -u PATCH_DIR -u PATCH_BASE_VERSION make target/linux/prepare V=s -j1 ) >"$PREP_LOG" 2>&1; then
		PREPARED=1
		note "==> preflight: kernel prepared without patch conflicts"
	else
		if grep -qi 'patch failed' "$PREP_LOG"; then
			FAILED="$(grep -i -A1 'patch failed' "$PREP_LOG" | tr '\n' ' ' | cut -c1-400)"
			add_skip "a kernel patch no longer applies to the $KV sources: $FAILED"
			note "---- the 25 lines before the conflict ----"
			grep -i -B25 -A2 'patch failed' "$PREP_LOG" | tail -60
			note "---- last lines of the patch log ----"
			tail -20 "$PREP_LOG"
			note "-------------------------------------"
			cp "$PREP_LOG" "$GITHUB_WORKSPACE/preflight-prepare.log" 2>/dev/null || true
		else
			add_note "make target/linux/prepare failed for a reason other than a patch conflict; leaving the decision to the build"
			note "::warning::preflight: make target/linux/prepare failed, see the log below"
			tail -30 "$PREP_LOG"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# 7. Sanity check: the fixes must be visible in the prepared kernel tree.  This
#    also covers the case where `make target/linux/prepare` failed for some
#    other reason before it ever got to applying the patches.
# ---------------------------------------------------------------------------
if [ "${#SKIP_REASONS[@]}" -eq 0 ]; then
	KDIR="$(ls -d "$SRC"/build_dir/target-*/linux-*/linux-* 2>/dev/null | head -1)"
	if [ -n "$KDIR" ]; then
		if ! grep -q 'pcs\.ops = &mxl862xx_pcs_ops;' "$KDIR/$MXL_PHYLINK" 2>/dev/null; then
			if [ "$PREPARED" = 1 ]; then
				add_skip "patch 760-18 is not in effect: $KDIR/$MXL_PHYLINK still does not select the PCS ops after preparing the kernel"
			else
				add_note "patch 760-18 could not be verified ($MXL_PHYLINK has no PCS ops assignment); the kernel was not prepared here, so the build itself will report it"
			fi
		fi
		if ! grep -q 'SFP_QUIRK_S("OEM", "SFP+XG-T-H"' "$KDIR/$SFP_C" 2>/dev/null; then
			if [ "$PREPARED" = 1 ]; then
				add_skip "patch 761 is not in effect: $KDIR/$SFP_C does not carry the OEM SFP+XG-T-H quirk after preparing the kernel"
			else
				add_note "patch 761 could not be verified ($SFP_C has no OEM SFP+XG-T-H quirk); the kernel was not prepared here, so the build itself will report it"
			fi
		fi
		if [ "${#SKIP_REASONS[@]}" -eq 0 ]; then
			if [ "$PREPARED" = 1 ]; then
				add_note "both patches are in place in the prepared kernel tree"
			else
				add_note "both patches are already in place in the kernel tree (the kernel was prepared earlier)"
			fi
		fi
	else
		add_note "no build_dir/target-*/linux-*/linux-* found under $SRC, the patches could not be verified"
	fi
fi

rm -rf "$VANILLA"

# ---------------------------------------------------------------------------
# 8. Report.
# ---------------------------------------------------------------------------
if [ "${#SKIP_REASONS[@]}" -gt 0 ]; then
	JOINED="$(printf '%s; ' "${SKIP_REASONS[@]}")"
	JOINED="${JOINED%; }"
	note ""
	note "======================================================================"
	note " SKIPPING THE FIRMWARE BUILD"
	note "======================================================================"
	for r in "${SKIP_REASONS[@]}"; do
		note " * $r"
	done
	for n in ${NOTES[@]+"${NOTES[@]}"}; do
		note " - $n"
	done
	note ""
	note "No firmware is built for this run; the sources on this branch did not"
	note "change, so the previously published artifacts are still current.  Fix"
	note "the patches under patches/ (or delete them if upstream solved the"
	note "problem) and dispatch the workflow again."
	note "======================================================================"
	echo "::warning::Build skipped - ${JOINED}"
	printf '%s\n' "$JOINED" > "$GITHUB_WORKSPACE/preflight-skip-reason.txt"

	summary "## ⏭️ Firmware build skipped"
	summary ""
	summary "The r4pro kernel patches are no longer applicable to the sources that"
	summary "were just cloned, so the build was skipped instead of producing a"
	summary "broken or pointless image."
	summary ""
	summary "**Reason(s)**"
	summary ""
	for r in "${SKIP_REASONS[@]}"; do
		summary "- ${r}"
	done
	summary ""
	if [ "${#NOTES[@]}" -gt 0 ]; then
		summary "**Details**"
		summary ""
		for n in ${NOTES[@]+"${NOTES[@]}"}; do
			summary "- ${n}"
		done
		summary ""
	fi
	summary "Target kernel: \`$KV\`  "
	summary "Workflow: \`${GITHUB_WORKFLOW:-?}\` on \`${GITHUB_REF_NAME:-?}\`  "
	summary "Commit: \`${GITHUB_SHA:-?}\`"

	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		{
			echo "skip=true"
			echo "reason=$JOINED"
		} >> "$GITHUB_OUTPUT"
	fi
	exit 0
fi

note ""
note "==> preflight: patches are still needed and applicable - building the firmware"
summary "## ✅ Preflight passed"
summary ""
summary "The r4pro kernel patches are still needed and still apply to the $KV sources."
summary ""
for n in ${NOTES[@]+"${NOTES[@]}"}; do
	summary "- $n"
done
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "skip=false" >> "$GITHUB_OUTPUT"
fi
exit 0
