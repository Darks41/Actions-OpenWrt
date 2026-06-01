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

NETDATA_MAKEFILE="feeds/packages/admin/netdata/Makefile"
[ -f "package/feeds/packages/netdata/Makefile" ] && NETDATA_MAKEFILE="package/feeds/packages/netdata/Makefile"

if [ ! -f "$NETDATA_MAKEFILE" ]; then
  echo "[DIY] netdata Makefile not found, skipping"
  exit 0
fi

echo "[DIY] Patching $NETDATA_MAKEFILE ..."

# 在文件末尾插入 Build/Configure 覆写
cat >> "$NETDATA_MAKEFILE" << 'EOF'

# === fix-netdata-cxx11 ===
# netdata 源码中 aclk/schema-wrappers/Makefile.am 硬编码 -std=c++11
# 但新版 protobuf + abseil-cpp 要求 C++14+，导致编译报错：
#   error: #error "C++ versions less than C++14 are not supported."
# 这里在 configure 后将生成的 Makefile 中的 -std=c++11 替换为 -std=c++17
define Build/Configure
	$(call Build/Configure/Default)
	sed -i 's|-std=c++11|-std=c++17|g' \
		$(PKG_BUILD_DIR)/aclk/schema-wrappers/Makefile
	sed -i 's|-std=c++11|-std=c++17|g' \
		$(PKG_BUILD_DIR)/aclk/Makefile
endef
# =========================
EOF

echo "[DIY] Done. Rebuild with: make package/feeds/packages/netdata/compile V=s"
