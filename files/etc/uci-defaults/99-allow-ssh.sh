#!/bin/sh
# 预置防火墙规则：允许从 WAN 和 LAN 访问 SSH(22)
# 放到 workflow 仓库的 files/etc/uci-defaults/ 下，构建时自动并入固件

# WAN -> 22 放行
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-SSH-WAN'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest_port='22'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='ACCEPT'

# LAN 默认已放行全部入站，无需额外规则

# 可选：如需从 WAN 访问 LuCI，取消下面三行注释
#uci add firewall rule
#uci set firewall.@rule[-1].name='Allow-LuCI-WAN'
#uci set firewall.@rule[-1].src='wan'
#uci set firewall.@rule[-1].dest_port='80 443'
#uci set firewall.@rule[-1].proto='tcp'
#uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall
exit 0
