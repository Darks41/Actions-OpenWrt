# 编译缓存

一次编译要两三个小时，时间主要花在两件事上：下载源码包，以及反复编译同样的代码。
这两样都被缓存下来，存进**本仓库自己的 Releases**，下一次编译直接复用。

## 每个分支一对 Release

| 分支 | `dl/` 缓存 | `.ccache` 缓存 |
| --- | --- | --- |
| `snapshot` | `dl-cache` | `ccache-cache` |
| `LEDE` | `dl-cache-lede` | `ccache-cache-lede` |
| `beeconmini-ac5s-6.18` | `dl-cache-ac5s-6.18` | `ccache-cache-ac5s-6.18` |

每个分支的缓存 tag 必须不同：manifest 里的哈希覆盖整份缓存内容，
两个分支共用 tag 会互相覆盖。

两个 Release 都刻意建成**草稿（draft）**，访客的 Releases 页面看不到它们，
只遍历已发布 Release 的步骤（如 `delete-older-releases`）也不会误删。
标题写明分支和更新时间（统一北京时间，UTC+8）：

```
[snapshot] ccache cache - updated 2026-10-02 02:22 UTC+8
```

## 永远只保留一份

写入顺序是**先传新分片 → 再发布新 manifest → 最后删掉旧分片**。
任何一步中断，旧缓存仍然完好，恢复端也读不到半成品。

`dl/` 内容没变时整个上传会跳过（manifest 里的哈希未变）。

分片是为了绕开 GitHub 的单文件限制：两种缓存都按 1800 MB 切片
（Release 单个资产上限 2 GiB）。

## 平台指纹

`ccache.manifest` 的第一段是平台指纹，由 `.config` 中下列符号排序后取 sha256 前 8 位：

```
CONFIG_TARGET_ARCH_PACKAGES  CONFIG_GCC_VERSION  CONFIG_LIBC  CONFIG_LIBC_VERSION  CONFIG_ARCH
```

换架构 / 工具链 / C 库时指纹变化，恢复阶段打印 `::warning::` 并**冷启动**，
而不是把用不上的目标文件交给编译器。同一架构下换设备不换指纹——
host 工具和公共库的绝大部分对象仍然有效。

指纹在 `Restore ccache` 步骤里算一次并导出为 `PLATFORM_FP`，
`Save ccache` 直接复用，避免"编译前"和"编译后"两份 `.config` 算出不同结果。

## 开关

工作流顶部：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `CACHE_DL` | `true` | 是否保存 / 恢复 `dl/` |
| `CACHE_CCACHE` | `true` | 是否保存 / 恢复 `.ccache` |
| `CCACHE_MAX_SIZE` | `6G` | ccache 上限，编译前由 `ccache -M` 设定 |

> `CCACHE_MAX_SIZE` 不是 ccache 认识的环境变量，必须在编译前调用 `ccache -M`
> 才有效；否则上限由恢复回来的 `.ccache/ccache.conf` 决定。

`CONFIG_DEVEL=y` 与 `CONFIG_CCACHE=y` 写在各分支的 `.config` 里
（`r4pro.config` / `h66k.config` / `ac5s.config`）。
`DEVEL` 只让 `CCACHE` 选项在 menuconfig 里可见，本身不改变其它配置。

## 实测

| | 冷启动 | 热缓存 |
| --- | --- | --- |
| `make download` | 191 s | 63 – 98 s |
| 编译 | 182 min | 98 – 147 min |

## 手动操作

- **查看**：仓库 → Releases（草稿需登录可见），标题即分支与更新时间。
- **清缓存**：删掉对应的 draft Release，下次编译会重新建立并冷启动。
- **清工作流记录 / 固件产物**：到 Actions 页面手动删除。
  原模板自带的 `Mattraks/delete-workflow-runs` 自动删除步骤**已移除**，
  因为它会连带删掉运行记录和编译产物。

## 为什么不用 actions/cache

免费额度的 Actions 缓存每仓库上限 10 GB，且**最后一次访问后 7 天过期**。
固件仓库不是天天编译，缓存会反复失效；Release 资产没有这个限制。
