# LightIsle 第三方组件与授权边界

LightIsle 项目自有代码的许可见 [LICENSE](LICENSE)；**第三方依赖、工具、字体、图标与媒体资源仍按各自许可证授权**，不因根目录的 PolyForm 条款而自动转成非商业许可。本页是依赖入口清单，**不是完整的版权声明清单或 SPDX SBOM**。

## 已在依赖清单中出现的组件示例

| 所属组件 | 依赖或资源示例 | 核对来源 |
| --- | --- | --- |
| Go Core | `go-sqlite3`、`goexif`、`golang.org/x/crypto`、`golang.org/x/net`、`robfig/cron` | `go.mod`、`go.sum` |
| Web / PWA | Vue、Leaflet、hls.js、lucide-vue-next、Vite、TypeScript | `apps/web/package.json`、`apps/web/package-lock.json` |
| Flutter 客户端 | Flutter SDK、video_player、photo_view、pdfx、flutter_map、file_picker 等 | `apps/flutter/pubspec.yaml`、`apps/flutter/pubspec.lock` |
| 可选外部工具 | FFmpeg、aria2、cloudflared、frp、Docker Desktop / Colima 等 | 实际构建、安装和部署清单 |

上表不代表这些组件采用相同许可证，也不确认它们全部被嵌入最终安装包。不同版本、静态或动态链接方式、编译选项和分发方式可能对应不同义务；例如 FFmpeg 的许可边界应按具体构建配置核查。

## 发布及商业交付前的检查

1. 根据**实际锁定版本**及构建产物生成完整依赖与许可证清单（含间接依赖、原生框架、可选工具及资源），逐一核对上游许可证。
2. 依各许可证要求提供适用的版权声明、完整许可文本、源代码或对应源码获取方式（若有该义务）。
3. 核实是否存在 GPL/AGPL/LGPL、特殊素材授权、商标和专利条款，以及与当前分发、链接方式或商业双授权模式的兼容性。
4. 商业授权合同仅能许可维护者拥有或有权再许可的权利；**不得以 LightIsle 商业许可代替第三方许可**。

第三方材料的许可冲突应在分发前解决。本页不构成对第三方许可证的再授权。
