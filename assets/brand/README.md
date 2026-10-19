# LightIsle 官方 Logo

![轻屿 LightIsle](lightisle-logo.svg)

这枚蓝 → 青 → 紫的六边形网格品牌标识源于原始首次启动动画的视觉语言；正式图形由项目自行绘制，不把 Apple 的 SF Symbol 当作 App 图标或商标。

**唯一生成入口**：在项目根目录执行：

```bash
swift scripts/generate-brand-assets.swift
```

此命令统一生成：

- `assets/brand/lightisle-logo.svg` — 归档与 README 展示用矢量图。
- `apps/macos/Resources/LightIsleLogo.png` — SwiftUI 启动、初始化与侧栏。
- `apps/web/public/brand-icon.svg`、`brand-icon.png`、`brand-icon-512.png`、`favicon.png`、`apple-touch-icon.png` — Web 登录、浏览器标签和移动端主屏。
- `dist/LightIsle.iconset/` — Mac 原生 icns 素材，构建时由 `iconutil` 合成 `LightIsle.app/Contents/Resources/LightIsle.icns`。

`scripts/build-macos.sh` 会自动运行生成器并执行 `tests/test_brand_assets.py`，防止打包时遗漏图标。如果未来要修改 Logo 颜色或六边形布局，**只修改生成器，不要分别修改各端图标**。
