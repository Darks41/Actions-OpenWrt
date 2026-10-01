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
itself**, so no third-party cache service is involved:

| Cache | Contents | Stored as |
| --- | --- | --- |
| `dl` | packages fetched by `make download` | assets of the **draft** Release tagged `dl-cache-25.12` |
| ccache | intermediate compiler output (`.ccache`) | assets of the **draft** Release tagged `ccache-cache-25.12` |

- Both caches are split into parts (1800M each, below GitHub's 2 GiB/asset limit)
  and guarded by a manifest asset (`dl.manifest` / `ccache.manifest`). Parts are
  uploaded first and the manifest last, so a half-finished upload can never be
  restored; parts of older revisions are deleted afterwards.
- `dl/` is re-uploaded only when its contents change: `dl.manifest` holds a hash of
  the file list, and an unchanged `dl/` skips the upload entirely.
- Compiler caching itself is enabled by `CONFIG_DEVEL=y` and `CONFIG_CCACHE=y` in
  the `.config` file, with `CCACHE_MAX_SIZE` (2G) capping the directory.
- Both caches are switched by the `CACHE_DL` / `CACHE_CCACHE` variables at the top
  of the workflow.

> Releases are used instead of `actions/cache` on purpose. The free-tier Actions
> cache is capped at 10 GB per repository and **expires 7 days after last access**,
> which a firmware repository that is built only occasionally would constantly hit.

**清理缓存 / Clearing the cache:** delete the `dl-cache-25.12` and `ccache-cache-25.12`
Releases. To disable caching, set `CACHE_DL: false` and `CACHE_CCACHE: false`.

> Both Releases are deliberately created as **drafts**: the
> `delete-older-releases` step only lists published releases, so `keep_latest: 3`
> can never delete them, and they stay hidden on the Releases page.

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
