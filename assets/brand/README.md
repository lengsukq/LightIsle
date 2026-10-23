# LightIsle 官方 Logo

![轻屿 LightIsle](lightisle-logo.svg)

这枚「灵光晶屿与静海之澜（Prismatic Crystalline Isle & Radiant Beacon）」品牌标识象征着 LightIsle（轻屿）的品牌内核：**光（清晰、灵动、指引之灯塔）与屿（安全、静谧、安放回忆的数字私域港湾）**。图形采用符合 Apple HIG 标准的连续超椭圆（Squircle）底座，以深邃静谧的午夜蔚蓝天穹为底，中央悬浮着朝霞与暮紫折射的三棱结晶浮岛，基底映照着微澜静海，峰顶绽放着纯粹澄澈的引路星芒。正式图形由项目自主矢量绘制，兼顾 16px 浏览器 Favicon 的清晰轮廓与 512px Retina 屏幕的细腻光感。

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
