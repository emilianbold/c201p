# U-Boot patches

`u-boot/` is a git submodule pinned to the upstream `v2024.04` tag,
unmodified. Everything this board needs beyond stock U-Boot lives here
instead of in the submodule itself, and `build.sh` applies it at build time.

## Files

- **`0001-board-critical.patch`** — required to boot at all.
  `VEYRON_CHAINLOAD`: skip re-initialising the PMIC/PLL/regulators
  Depthcharge already configured, when U-Boot is chainloaded rather than
  started from SPL. Re-running that init hangs the board permanently (no
  watchdog is armed yet at that point). Touches `board/google/veyron/Kconfig`
  and `board/google/veyron/veyron.c`. Always applied.

- **`chromebook_speedy_defconfig`** — not a patch; a full file, copied
  wholesale over `u-boot/configs/chromebook_speedy_defconfig` before
  configuring. It's a from-scratch replacement rather than a diff because
  nearly every line differs from upstream's own veyron-speedy defconfig
  (`CONFIG_POSITION_INDEPENDENT=y`, `CONFIG_VIDEO` disabled, ext4/sysboot
  support, etc.) — a line-based patch would be more fragile than just
  owning the file outright. Always applied.

## Verifying the patch still applies

The patch was generated as `git diff <old> <new> -- <paths>` against this
project's own history and validated against a genuinely fresh clone of the
pinned tag before being committed — not just checked for syntax. To
re-verify after bumping the pinned U-Boot version:

```sh
cd u-boot
git apply --check ../patches/uboot/0001-board-critical.patch
```

## Bumping the pinned U-Boot version

```sh
cd u-boot
git fetch --tags
git checkout vX.YY.ZZ
cd ..
git add u-boot
```

Then re-verify the patch applies (above) and re-check
`chromebook_speedy_defconfig` — upstream's own veyron-speedy defconfig may
have changed, and `make savedefconfig` can help spot new/renamed options.
