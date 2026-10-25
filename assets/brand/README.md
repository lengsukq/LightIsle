# LightIsle 官方 Logo

![轻屿 LightIsle](lightisle-logo.svg)

LightIsle（轻屿）品牌标识以“光”和“屿”为主题，使用蓝紫渐变、晶体岛屿与灯塔星芒。此目录保留**生成源与修改说明**；多端图标应由同一生成脚本输出，避免分别编辑导致版本不一致。实际显示效果需按 16 px Favicon 和高分辨率应用图标分别验证。

**唯一生成入口**：在项目根目录执行：

```bash
swift scripts/generate-brand-assets.swift
```

此命令统一生成：

- `assets/brand/lightisle-logo.svg` — 归档与 README 展示用矢量图。
- `apps/macos/Resources/LightIsleLogo.png` — SwiftUI 启动、初始化与侧栏。
- `apps/web/public/brand-icon.svg`、`brand-icon.png`、`brand-icon-512.png`、`favicon.png`、`apple-touch-icon.png` — Web 登录、浏览器标签和移动端主屏。
- `dist/LightIsle.iconset/` — Mac 原生 icns 素材，构建时由 `iconutil` 合成 `LightIsle.app/Contents/Resources/LightIsle.icns`。

`scripts/build-macos.sh` 会自动运行生成器并执行 `tests/test_brand_assets.py`，防止打包时遗漏图标。如果未来要微调 Logo 颜色或几何布局，**只修改生成器，不要分别修改各端图标**。
