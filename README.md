**English** | [中文](https://p3terx.com/archives/build-openwrt-with-github-actions.html)

# Actions-OpenWrt

[![LICENSE](https://img.shields.io/github/license/mashape/apistatus.svg?style=flat-square&label=LICENSE)](https://github.com/P3TERX/Actions-OpenWrt/blob/master/LICENSE)
![GitHub Stars](https://img.shields.io/github/stars/P3TERX/Actions-OpenWrt.svg?style=flat-square&label=Stars&logo=github)
![GitHub Forks](https://img.shields.io/github/forks/P3TERX/Actions-OpenWrt.svg?style=flat-square&label=Forks&logo=github)

A template for building OpenWrt with GitHub Actions

## Usage

- Click the [Use this template](https://github.com/P3TERX/Actions-OpenWrt/generate) button to create a new repository.
- Generate `.config` files using [Lean's OpenWrt](https://github.com/coolsnowwolf/lede) source code. ( You can change it through environment variables in the workflow file. )
- Push `.config` file to the GitHub repository.
- Select `Build OpenWrt` on the Actions page.
- Click the `Run workflow` button.
- When the build is complete, click the `Artifacts` button in the upper right corner of the Actions page to download the binaries.

## Tips

- It may take a long time to create a `.config` file and build the OpenWrt firmware. Thus, before create repository to build your own firmware, you may check out if others have already built it which meet your needs by simply [search `Actions-Openwrt` in GitHub](https://github.com/search?q=Actions-openwrt).
- Add some meta info of your built firmware (such as firmware architecture and installed packages) to your repository introduction, this will save others' time.

## Build cache

To shorten the next compilation, each build stores its caches **in this repository
itself**, so no third-party cache service is involved. Every branch has its own
pair of **draft** Releases -- `dl-cache` / `ccache-cache` for `snapshot`, the same
names with a `-lede` / `-ac5s-6.18` / `-r4pro` suffix for the other branches -- and
their titles carry the branch and the update time (Beijing time).

- Both caches are split into 1800M parts (below GitHub's 2 GiB/asset limit) and
  guarded by a manifest asset (`dl.manifest` / `ccache.manifest`). Parts are
  uploaded first and the manifest last, and the parts of the previous revision are
  deleted right afterwards: **exactly one revision of each cache is ever kept.**
- `dl/` is re-uploaded only when its contents change: `dl.manifest` holds a hash of
  the file list, and an unchanged `dl/` skips the upload entirely.
- Compiler caching is enabled by `CONFIG_DEVEL=y` and `CONFIG_CCACHE=y` in the
  branch's `.config` file, with `CCACHE_MAX_SIZE` (6G) applied by `ccache -M` just
  before the build.
- `ccache.manifest` also records a **platform fingerprint** -- target architecture,
  GCC version and C library. A cache built for a different architecture or
  toolchain is refused and the build starts cold, instead of restoring objects it
  could never use. Changing the device while staying on the same architecture
  keeps the cache.
- Both caches are switched by the `CACHE_DL` / `CACHE_CCACHE` variables at the top
  of the workflow.

> Releases are used instead of `actions/cache` on purpose. The free-tier Actions
> cache is capped at 10 GB per repository and **expires 7 days after last access**,
> which a firmware repository that is built only occasionally would constantly hit.

**Clearing the cache:** delete that branch's `dl-cache*` and `ccache-cache*`
Releases. To disable caching, set `CACHE_DL: false` and `CACHE_CCACHE: false`.

## r4pro: 2.5G copper SFP fix for the BPI-R4 Pro 4E

The `r4pro` branch is `snapshot` plus one kernel patch,
`patches/760-18-net-dsa-mxl862xx-select-pcs-ops-after-fw-probe.patch`, which
`diy-part2.sh` installs into `target/linux/generic/pending-6.18/` right before
the build (so it is applied after patch 760-16, the last patch touching that
driver).

OpenWrt patch 760-05 moved `mxl862xx_setup_pcs()` ahead of
`mxl862xx_wait_ready()`, so the firmware-version based phylink PCS ops selection
from patch 760-16 always reads `priv->fw_version == 0` and installs the legacy
ops even on firmware >= 1.0.84.  The legacy in-band caps for 2500BASE-X only
allow `LINK_INBAND_DISABLE`, while phylink sets the Autoneg bit for an SFP
module, so module insertion fails with

```
mxl862xx mdio-bus:10 sfp-lan: autoneg setting not compatible with PCS
```

and `sfp-lan` never links (`Module state: error`, `tx_disable: 1`).  The patch
re-selects the ops in `mxl862xx_phylink_mac_select_pcs()`, which only runs after
`mxl862xx_wait_ready()` has populated `priv->fw_version`.

Expected result in the boot log after flashing this image:

```
mxl862xx mdio-bus:10 sfp-lan: switched to inband/2500base-x link mode
```

## Credits

- [Microsoft Azure](https://azure.microsoft.com)
- [GitHub Actions](https://github.com/features/actions)
- [OpenWrt](https://github.com/openwrt/openwrt)
- [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)
- [Mikubill/transfer](https://github.com/Mikubill/transfer)
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release)
- [Mattraks/delete-workflow-runs](https://github.com/Mattraks/delete-workflow-runs)
- [dev-drprasad/delete-older-releases](https://github.com/dev-drprasad/delete-older-releases)
- [peter-evans/repository-dispatch](https://github.com/peter-evans/repository-dispatch)

## License

[MIT](https://github.com/P3TERX/Actions-OpenWrt/blob/main/LICENSE) © [**P3TERX**](https://p3terx.com)
