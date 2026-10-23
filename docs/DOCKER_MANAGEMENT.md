# Docker / Colima 本机管理与镜像源配置

> 2026-10-23 开发版能力。此模块由 **Mac 原生管理端**拥有，只有进入该页面时才探测 Docker；与 Go Core 服务启动、Web 用户端、Flutter 客户端相互独立。不会自动安装、启动、关闭 Docker Desktop 或 Colima。

## 已实现的入口和操作

在原生 LightIsle.app 左侧 **Docker 与应用**（⌘8）：

- 选择 **Docker Desktop**（context: `desktop-linux`）或 **Colima**（context: `colima`）；仅接受本机已验证的 Unix Socket，不沿用环境变量中的远程 Docker Host。
- 按需读取 Docker Engine 版本、实际生效的 Registry Mirrors、已有容器和本地镜像（界面最多显示 100 个镜像）。
- 容器支持 **启动、停止、重启**；每次明确二次确认。没有删除容器、删除卷、`prune` 或自启 Docker VM。
- 可查看已有 Compose 项目和配置路径，对已存在的项目执行 **启动、停止、重启**。也可以从原生文件选择器显式选择用户家目录内的 `.yaml/.yml` 配置文件，指定新项目名称，经过确认后部署一个**尚不存在的项目**。
- Compose 导入在执行前重新核验所选本机文件、拦截路径中的符号链接、校验 YAML 配置和同名项目；实际执行 `up --detach --no-build --no-recreate --pull missing`，可能从网络下载缺失镜像并创建网络和数据卷，但**不会编译 Dockerfile、替换同名已有项目或执行 down/prune**。需要对文件中的宿主挂载、端口和运行权限自行负责。
- 容器支持只读显示**最近 200 行日志**（返回限制 1 MiB），不会自动跟随日志；本地镜像可按具体名称/标签或 sha256 摘要手动拉取，重新拉取镜像**不会自动更新已有容器**。
- 数据卷和网络支持列表展示，也可以二次确认后新建空数据卷或默认 bridge 网络；没有自动挂载 NAS 数据。未提供删除、格式化、重命名、网络断开等不可恢复操作。
- “国内 Docker Hub 镜像加速”可选择下表内置预设，或自行输入严格校验的 `https://` 镜像服务地址。**一次配置一个镜像加速端点**，不静默覆盖其他 Docker Engine 设置。
- 提供按需 **测试加速源连接**（对 `/v2/` 发送一次 HEAD 请求，200/401 表示接口可达，429/403 表示限流/拒绝）。只代表接口可达，**不等于镜像完整可拉取或标签保持最新**。
- 由用户主动点击 **应用镜像源配置… → 备份并应用**，本机写入前保留带 UUID 的旧配置备份。拒绝符号链接配置、非普通文件、异常 JSON/YAML、超过 256 KiB 的配置。

## 内置常见镜像源

| 选项 | 预设地址 | 限制 |
| --- | --- | --- |
| 毫秒镜像（公网候选） | `https://docker.1ms.run` | 非官方第三方服务，可能限流、更改镜像或暂停服务 |
| DaoCloud（Docker Hub） | `https://docker.m.daocloud.io` | 可能存在白名单、限流；仅作为候选，不承诺全部仓库可用 |
| 阿里云 ACR（个人专属） | 用户在 ACR 控制台获取 | 需要自行粘贴专属地址；阿里云 2026 年官方文档已提示**停止同步最新镜像** |
| 腾讯云（云内专用） | `https://mirror.ccs.tencentyun.com` | **仅腾讯云内网有效**，家庭 Mac 请勿选择 |

文档依据（核对于 2026-10-23）：
- [Docker Desktop：Engine 配置](https://docs.docker.com/desktop/settings-and-maintenance/settings/)
- [Colima：registry-mirrors](https://colima.run/docs/configuration/)
- [阿里云 ACR 官方说明](https://help.aliyun.com/zh/acr/user-guide/accelerate-the-pulls-of-docker-official-images)
- [腾讯云内网限制](https://cloud.tencent.com.cn/document/product/213/8623)
- [2026 年 10 月加速源候选清单](https://cloud.tencent.com/developer/article/2756629)

公共第三方镜像加速器不是信任代理；敏感或生产工作负载应使用可信私有 Registry 并固定 digest。添加 `registry-mirrors` 不会自动加速 GHCR、GCR、Quay、私有镜像仓库，也不能保证容器镜像完整、最新或跨架构兼容。

## 一键配置的真实边界

### Docker Desktop

1. 在原生页面选择合适的公共候选或粘贴自定义服务地址。
2. 点击 **应用镜像源配置…** 并确认。
3. LightIsle 原子写入 `~/.docker/daemon.json`，只调整 `registry-mirrors`，保留原有其他 JSON 字段、旧文件备份及私有权限。
4. 在 **Docker Desktop → Settings → Docker Engine** 确认更改并选择 **Apply & Restart**。LightIsle 不会擅自停止其他容器来代替用户执行此步。

### Colima（默认 profile）

1. 先安装并按自己的方式创建过默认 Colima 配置（`~/.colima/default/colima.yaml`）；**LightIsle 不会启动或初始化虚拟机**。
2. 选择 Colima，上方自动勾选 **同时配置 Colima 默认虚拟机**。
3. 显式确认后，保守合并 YAML `docker.registry-mirrors`，并同步写入宿主机 `~/.docker/daemon.json`，两个文件分别备份。
4. 在合适的维护时间手动重启 Colima 以应用新 daemon 配置。复杂/自定义 YAML 或不存在的 profile 会拒绝自动写入，改用官方 `colima start --edit`。

两处写入属于两个独立文件系统事务，不承诺跨文件原子性。如果第二个文件失败，页面会给出第一份备份名，以供用户恢复。不会自动重启或删除运行中的容器。

## 未实现（不能宣传为完整 Docker 管理）

- Compose 文件图形编辑、服务级配置更新与无中断升级、Stack/Swarm、单容器图形创建/编辑、镜像搜索与删除、私有仓库凭据、Web Terminal/容器 exec、卷与网络写入管理；
- 镜像自动更新、运行容器的热迁移/重建，批量 Compose 升级、定期拉取以及应用模板商店；
- 多 Colima profile、OrbStack/Podman、Docker Desktop 图形设置直接自动重启；
- 在 Web/手机端控制 Docker；高权限 Docker 操作不能直接通过对局域网开放的普通 Web API 转发；
- 正式用户设备的 Docker Desktop/Colima 真实 Engine 功能测试、运行/停止中断测试、不同 macOS/CLI 版本的兼容性矩阵。

本地独立验证命令：`bash scripts/test-docker-support.sh`（不触碰真实 Docker 配置）、`swift build -c release --product LightIsle`。只有真实 Docker 引擎已安装并允许访问时，才能进行人工容器与镜像源应用验收。
