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

# ---------------------------------------------------------------------------
# r4pro: make 2.5G copper SFP modules usable in the `sfp-lan` cage.
#
# OpenWrt patch 760-05 moved mxl862xx_setup_pcs() ahead of
# mxl862xx_wait_ready(), so the firmware-version based phylink PCS ops
# selection added by patch 760-16 always reads priv->fw_version == 0 and
# installs the legacy ops even on firmware >= 1.0.84.  The legacy in-band caps
# for 2500BASE-X only allow LINK_INBAND_DISABLE, while phylink sets the
# Autoneg bit for an SFP module, so insertion fails with
#
#   mxl862xx mdio-bus:10 sfp-lan: autoneg setting not compatible with PCS
#
# and sfp-lan stays unusable (`Module state: error`, tx_disable: 1).
#
# 760-18 re-selects the ops in mxl862xx_phylink_mac_select_pcs(), which only
# runs after mxl862xx_wait_ready() has populated priv->fw_version.
#
# It is dropped into target/linux/generic/pending-6.18/ next to 760-16 and is
# therefore applied last (patches are applied in sorted order, after the
# backport-6.18 series).
# ---------------------------------------------------------------------------
set -e

PATCH_NAME="760-18-net-dsa-mxl862xx-select-pcs-ops-after-fw-probe.patch"
PATCH_DIR="$GITHUB_WORKSPACE/patches"
KERNEL_PATCH_DIR="target/linux/generic/pending-6.18"

echo "==> r4pro: installing $PATCH_NAME"
install -D -m 0644 "$PATCH_DIR/$PATCH_NAME" "$KERNEL_PATCH_DIR/$PATCH_NAME"
sha256sum "$KERNEL_PATCH_DIR/$PATCH_NAME"
test "$(grep -c '^+.*pcs.ops = &mxl862xx_pcs_ops;' "$KERNEL_PATCH_DIR/$PATCH_NAME")" = "1"
ls -l "$KERNEL_PATCH_DIR" | grep 760-1

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
