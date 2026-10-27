#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# 原始版本已备份为 diy-part2.sh.old（同一目录，仅供对照，不会被执行）。
#

# ---------------------------------------------------------------------------
# r4pro: make 2.5G copper SFP modules usable in the `sfp-lan` cage.
#
# Two problems have to be solved for the OEM SFP+XG-T-H module.
#
# (1) 760-18-net-dsa-mxl862xx-select-pcs-ops-after-fw-probe.patch
#
#     OpenWrt patch 760-05 moved mxl862xx_setup_pcs() ahead of
#     mxl862xx_wait_ready(), so the firmware-version based phylink PCS ops
#     selection added by patch 760-16 always reads priv->fw_version == 0 and
#     installs the legacy ops even on firmware >= 1.0.84.  The legacy in-band
#     caps for 2500BASE-X only allow LINK_INBAND_DISABLE, while phylink sets
#     the Autoneg bit for an SFP module, so insertion fails with
#
#       mxl862xx mdio-bus:10 sfp-lan: autoneg setting not compatible with PCS
#
#     and sfp-lan stays unusable (`Module state: error`, tx_disable: 1).
#     760-18 re-selects the ops in mxl862xx_phylink_mac_select_pcs(), which
#     only runs after mxl862xx_wait_ready() has populated priv->fw_version.
#
# (2) 761-net-sfp-add-quirk-for-OEM-SFP-XG-T-H-2.5G-copper-module.patch
#
#     After (1) the module is probed fine, the PCS switches to in-band
#     2500base-x and the MxL862xx XPCS reports the link as up, but sfp-lan
#     still stays in NO-CARRIER: the module never sends a clause 37 word, so
#     phylink_decode_c37_word() reports a negotiation failure and keeps the
#     link down.  The quirk clears the Autoneg bit for this module, which
#     makes phylink use the out-of-band path: it derives 2500baseX/Full from
#     the interface and calls pcs_link_up(2500, FULL) instead.
#
#     This mirrors the upstream quirks for other OEM 2.5G copper modules
#     (e.g. "OEM"/"SFP-2.5G-T" -> sfp_quirk_oem_2_5g) and, unlike a driver
#     change, it cannot affect any other 2500BASE-X module.
#
# Both patches are dropped into target/linux/generic/pending-6.18/ and are
# applied after the 750/751 SFP quirk patches and after 760-16 (patches are
# applied in sorted order, after the backport-6.18 series).
# ---------------------------------------------------------------------------
set -e

PATCH_DIR="$GITHUB_WORKSPACE/patches"
KERNEL_PATCH_DIR="target/linux/generic/pending-6.18"

for patch_file in "$PATCH_DIR"/*.patch; do
	patch_name="$(basename "$patch_file")"
	echo "==> r4pro: installing $patch_name"
	install -D -m 0644 "$patch_file" "$KERNEL_PATCH_DIR/$patch_name"
done

sha256sum "$KERNEL_PATCH_DIR"/760-18-*.patch "$KERNEL_PATCH_DIR"/761-*.patch

# 760-18 must re-select the PCS ops; 761 must clear the Autoneg bit.
test "$(grep -c '^+.*pcs.ops = &mxl862xx_pcs_ops;' "$KERNEL_PATCH_DIR/760-18-net-dsa-mxl862xx-select-pcs-ops-after-fw-probe.patch")" = "1"
grep -q '^+	SFP_QUIRK_S("OEM", "SFP+XG-T-H", sfp_quirk_disable_autoneg),$' \
	"$KERNEL_PATCH_DIR/761-net-sfp-add-quirk-for-OEM-SFP-XG-T-H-2.5G-copper-module.patch"
ls -l "$KERNEL_PATCH_DIR" | grep -E '76[01]-'

# Modify default IP
#sed -i 's/192.168.1.1/192.168.50.5/g' package/base-files/files/bin/config_generate

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Modify hostname
#sed -i 's/OpenWrt/P3TERX-Router/g' package/base-files/files/bin/config_generate

# 移除旧版本 netdata
#rm -rf feeds/packages/admin/netdata
# 临时克隆官方最新 packages 仓库，并提取最新版 netdata
#git clone --depth=1 https://github.com/openwrt/packages.git temp_packages
#cp -r temp_packages/admin/netdata feeds/packages/admin/netdata
#rm -rf temp_packages

# 移除自带的PW库
#rm -rf feeds/luci/applications/luci-app-passwall

# ===========================================================================
# 修复 smartdns-ui / smartdns-webui 编译（2026-10-24 构建唯一失败点）
#
# 现象：
#   ld: cannot find PATH=...: No such file or directory
#   ld: cannot find AWS_LC_SYS_CFLAGS=-O0
#   ld: error: .../plugin/smartdns-ui: read: Is a directory
#   make[3]: *** [Makefile:148: .../smartdns-.../.built] Error 1
#
# 原因：feeds/passwall_packages/smartdns/Makefile 的 Build/Compile/smartdns-ui 里
#   CC=$(TARGET_CC)
# 没加引号。分支 .config 开了 CONFIG_CCACHE，rules.mk 会把 TARGET_CC 改写成
#   "ccache aarch64-openwrt-linux-musl-gcc"
# 含空格，于是 shell 把这行拆成「CC=ccache 赋值 + 直接执行交叉 gcc」，后面的
# PATH=… / AWS_LC_SYS_CFLAGS=-O0 / make 全被 gcc 当成输入文件传给 ld。
#
# 修法：改用 TARGET_CC_NOCACHE（rules.mk:397 定义、401 export，展开是单个词）
# 并补上引号。只影响这一个 recipe，其余包的 ccache 不受影响。
# ===========================================================================
smartdns_mk=feeds/passwall_packages/smartdns/Makefile
if [ -f "$smartdns_mk" ]; then
	if grep -qF 'CC="$(TARGET_CC_NOCACHE)"' "$smartdns_mk"; then
		echo "[diy2] smartdns-ui CC already patched, skip"
	elif grep -qF 'CC=$(TARGET_CC)' "$smartdns_mk"; then
		sed -i 's|CC=\$(TARGET_CC)|CC="$(TARGET_CC_NOCACHE)"|g' "$smartdns_mk"
		if grep -qF 'CC="$(TARGET_CC_NOCACHE)"' "$smartdns_mk"; then
			echo "[diy2] patched smartdns-ui CC quoting in $smartdns_mk"
		else
			echo "[diy2] ERROR: patch did not apply to $smartdns_mk" >&2
			exit 1
		fi
	else
		echo "[diy2] WARNING: 'CC=$(TARGET_CC)' not found in $smartdns_mk (upstream may have fixed it, please re-check)" >&2
	fi
else
	echo "[diy2] WARNING: $smartdns_mk not found, skip smartdns-ui CC patch" >&2
fi

# smartdns-webui 由 Next.js 16 构建（npm install / npm run build），要求 Node >= 20.9。
# workflow 的 apt 清单里没有 npm；OpenWrt 的 node/host 还会在 Host/Install 里删掉 npm
# （feeds/packages/lang/node/node/Makefile:254-257），所以把 runner 预装的 Node 22/24
# 加进后续步骤的 PATH（GITHUB_PATH 会被 prepend），Compile 步骤即可找到 node/npm。
node_bin=
for candidate in /opt/hostedtoolcache/node/2[0-9].*/x64/bin; do
	if [ -x "$candidate/node" ] && [ -x "$candidate/npm" ]; then
		case "$("$candidate/node" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" in
		2[0-9]) node_bin=$candidate ;;
		esac
	fi
done

if [ -n "$node_bin" ]; then
	export PATH="$node_bin:$PATH"
	if [ -n "${GITHUB_PATH:-}" ]; then
		echo "$node_bin" >> "$GITHUB_PATH"
	fi
	echo "[diy2] node $(node -v) / npm $(npm -v) from $node_bin"
elif [ -n "${GITHUB_ACTIONS:-}" ]; then
	# 兜底：runner 镜像结构变了就装 NodeSource 22
	echo "[diy2] WARNING: no Node >= 20 in /opt/hostedtoolcache/node, installing NodeSource 22" >&2
	curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - || exit 1
	sudo apt-get install -y nodejs || exit 1
	command -v node >/dev/null && command -v npm >/dev/null || { echo "[diy2] ERROR: node/npm still missing" >&2; exit 1; }
	echo "[diy2] node $(node -v) / npm $(npm -v)"
else
	echo "[diy2] WARNING: no Node >= 20 found and not running in GitHub Actions, skip" >&2
fi
