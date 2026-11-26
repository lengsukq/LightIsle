# LightIsle 官方在线插件商店（Git Store）

本目录是 LightIsle 应用中心默认挂载的官方在线插件商店源：

- 商店索引：`plugins-store/registry.json`
- 插件源码：`plugins-store/plugins/<plugin-id>/`（符合 Plugin Specification v2：`plugin.json`、`icon.svg`、`ui/index.html` 等）
- 共享前端资源：`plugins-store/shared/`（纯静态家庭轻应用共享的暖白画廊样式与 `./__lightisle_kv` 乐观锁存储桥）
- 预打包分发包：`plugins-store/packages/<plugin-id>.liapp.zip`（含逐文件 `package-manifest.json` SHA-256 清单，外层摘要登记在 `registry.json`）

## 新增或更新插件流程

1. 在 `plugins-store/plugins/<plugin-id>/` 下新增或编辑插件源码，更新 `plugin.json` 中的 `version`（语义化版本号，例如 `1.1.0` → `1.2.0`）。
2. 运行确定性打包与索引生成脚本：
   ```bash
   python3 -B scripts/build-plugin-store.py
   ```
3. 校验所有打包产物与 `registry.json` 的 SHA-256 一致性：
   ```bash
   python3 -B scripts/build-plugin-store.py --check
   ```
4. 提交并推送至 Git 仓库后，LightIsle Web 端与 macOS 原生端「应用中心 → 在线商店」点击刷新即可发现新插件或新版本并一键下载安装/无损升级（保留 `plugin-data/` 全部业务数据）。
