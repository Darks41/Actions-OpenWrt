#!/bin/bash
# =============================================
# diy-part2.sh - OpenWRT build customization
# 修复 netdata v1.38.1 C++ 标准冲突
# =============================================
# 问题：
#   netdata aclk/schema-wrappers/Makefile.in 硬编码 -std=c++11
#   新版 protobuf/abseil-cpp 要求 C++14+，导致编译失败
#   #error "C++ versions less than C++14 are not supported."
#
# 修复：
#   在 Build/Configure 完成后，sed 替换生成的 Makefile 中的 -std=c++11
# =============================================

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
