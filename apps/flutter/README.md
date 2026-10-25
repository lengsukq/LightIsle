# LightIsle Flutter 用户客户端

Flutter 工程位于 `apps/flutter/`，覆盖 **Android / iOS / macOS**，通过已有 macOS arm64 LightIsle NAS 的 HTTPS/HTTP API 访问文件、图库、影视、账号和照片备份。它不是 NAS 服务端，也不负责宿主 Mac 的磁盘格式化、管理员初始化或 Core 生命周期。

**功能、证书指纹、联调和真机验收**：[Flutter 客户端指南](../../docs/FLUTTER_CLIENT.md) · [当前功能状态](../../docs/STATUS.md) · [真实设备验收清单](../../docs/ACCEPTANCE_DEBT_2026-10-25.md)。

## 开发调试

先在 Apple Silicon Mac 启动 `LightIsle.app` 并初始化管理员。Flutter 客户端使用 Mac 已开启的 LAN HTTPS（本机 macOS 可使用 loopback）；自签证书必须核对 Mac 管理端 SHA-256 指纹，不能关闭 TLS 校验或自动信任局域网发现结果。

```bash
cd apps/flutter
flutter pub get
flutter analyze
flutter test
flutter devices
flutter run -d macos
# 连接 Android/iOS 后：flutter run -d <设备ID>
```

仓库根目录还可以执行 `./scripts/verify-flutter.sh android macos ios` 检查构建；Xcode 签名、SDK 与设备权限需在目标机配置。**编译成功不等于** Android 后台备份、iOS Photos 权限、视频解码、TLS 和文件导出已通过真机验收。

这里不复制详细功能清单；实际接口、平台差异和历史验收统一维护于上述文档。
