import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'about_showcase_painters.dart';
import 'about_showcase_widgets.dart';

/// Wraps each webpage-style feature chapter in a scroll-reactive 3D stage.
class ScrollShowcaseStage extends StatelessWidget {
  const ScrollShowcaseStage({
    super.key,
    required this.scrollOffset,
    required this.anchorOffset,
    required this.disableAnimations,
    required this.child,
  });

  final double scrollOffset;
  final double anchorOffset;
  final bool disableAnimations;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (disableAnimations) return child;

    final delta = (scrollOffset - anchorOffset) / 520.0;
    final distance = delta.abs().clamp(0.0, 1.0);
    final scale = 1.0 - (distance * 0.035);
    final opacity = (1.0 - (distance * 0.18)).clamp(0.78, 1.0);
    final tiltX = (delta.clamp(-1.0, 1.0)) * 0.028;
    final parallaxY = delta.clamp(-1.0, 1.0) * -8.0;

    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.0008)
      ..translateByDouble(0.0, parallaxY, 0.0, 1.0)
      ..rotateX(tiltX)
      ..scaleByDouble(scale, scale, 1.0, 1.0);

    return Opacity(
      opacity: opacity,
      child: Transform(
        alignment: Alignment.center,
        transform: matrix,
        child: child,
      ),
    );
  }
}

/// Chapter 01: Mac Native Core & Multi-Disk Sovereignty Showcase.
class AboutArchitectureShowcase extends StatelessWidget {
  const AboutArchitectureShowcase({
    super.key,
    required this.phase,
    required this.scrollOffset,
    required this.isDark,
    required this.colors,
    required this.theme,
  });

  final double phase;
  final double scrollOffset;
  final bool isDark;
  final ColorScheme colors;
  final ThemeData theme;

  Widget _buildArchitectureStage(double effectivePhase) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 520;
        final macNode = AboutStageFloatingNode(
          icon: Icons.laptop_mac_rounded,
          title: 'Mac 原生核心',
          subtitle: 'lightisled · 静默常驻',
          accent: const Color(0xFF0071E3),
          isDark: isDark,
          pulse: 0.5 + 0.5 * math.sin(effectivePhase * math.pi * 2),
        );
        final rootANode = AboutStageFloatingNode(
          icon: Icons.dns_rounded,
          title: '物理卷 Root A',
          subtitle: '100 GiB 独立配额 · device+inode',
          accent: const Color(0xFF0071E3),
          isDark: isDark,
          pulse: 0.5 + 0.5 * math.cos(effectivePhase * math.pi * 2),
        );
        final tmNode = AboutStageFloatingNode(
          icon: Icons.shield_rounded,
          title: 'Time Machine 保护',
          subtitle: '无私有格式锁定 · 原片直存',
          accent: const Color(0xFF10B981),
          isDark: isDark,
          pulse: 0.5 + 0.5 * math.sin(effectivePhase * math.pi * 2 + 1.5),
        );

        return Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: MacStorageStagePainter(
                    phase: effectivePhase,
                    isDark: isDark,
                    verticalFlow: !isWide,
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, isWide ? 28 : 24),
              child: isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          flex: 5,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: macNode,
                          ),
                        ),
                        const Spacer(flex: 2),
                        Expanded(
                          flex: 6,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              rootANode,
                              const SizedBox(height: 12),
                              tmNode,
                            ],
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        macNode,
                        const SizedBox(height: 8),
                        rootANode,
                        const SizedBox(height: 8),
                        tmNode,
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final effectivePhase = (phase + scrollOffset * 0.0008) % 1.0;
    final activeStep = ((effectivePhase * 3).floor()) % 3;

    final card0 = AboutAnimatedFeatureSpecCard(
      isDark: isDark,
      theme: theme,
      colors: colors,
      highlighted: activeStep == 0,
      badgeLabel: '独立常驻后台',
      badgeColor: const Color(0xFF0071E3),
      icon: Icons.laptop_mac_rounded,
      iconGradient: const [Color(0xFF0071E3), Color(0xFF38BDF8)],
      title: 'Mac 原生管理端独立运行',
      subtitle: 'NAS 服务、存储权限与设备通信由原生服务管理；关闭当前客户端不会中断 NAS 运行。',
      tags: const ['常驻后台', '关闭界面不中断', '静默低功耗'],
    );
    final card1 = AboutAnimatedFeatureSpecCard(
      isDark: isDark,
      theme: theme,
      colors: colors,
      highlighted: activeStep == 1,
      badgeLabel: '原片无损直存',
      badgeColor: const Color(0xFF10B981),
      icon: Icons.backup_rounded,
      iconGradient: const [Color(0xFF10B981), Color(0xFF34D399)],
      title: '原片由用户自主防护',
      subtitle: '原始照片、视频与文件建议通过 macOS Time Machine 或独立备份工具保护，客户端不替您冒险。',
      tags: const ['Time Machine 原生兼容', '无私有格式锁定', '本地数据绝对隐私'],
    );
    final card2 = AboutAnimatedFeatureSpecCard(
      isDark: isDark,
      theme: theme,
      colors: colors,
      highlighted: activeStep == 2,
      badgeLabel: '轻巧敏捷',
      badgeColor: const Color(0xFFF59E0B),
      icon: Icons.spa_rounded,
      iconGradient: const [Color(0xFFF59E0B), Color(0xFFFBBF24)],
      title: '轻量透明，无企业级冗余',
      subtitle: '专为个人与家庭设计，不额外堆砌冗余复杂服务，保持整机稳定与资源轻简。',
      tags: const ['零冗余后台堆积', '单机专属调优', '家庭日常首选'],
    );

    return AboutChapterContainer(
      isDark: isDark,
      chapterNumber: '01',
      eyebrow: 'NATIVE SANCTUARY · 原生家庭数据原则',
      accent: const Color(0xFF0071E3),
      title: '系统架构与数据原则',
      subtitle: '轻屿将 Mac 变成安静可靠的家庭私有云主机：原生守护进程常驻低功耗运行，每块外置硬盘独立核算配额，原始数据始终以标准文件形态交由您和 Time Machine 守护。',
      stageCanvas: _buildArchitectureStage(effectivePhase),
      bottomContent: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          if (w >= 820) {
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: card0),
                  const SizedBox(width: 12),
                  Expanded(child: card1),
                  const SizedBox(width: 12),
                  Expanded(child: card2),
                ],
              ),
            );
          }
          if (w >= 540) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: card0),
                      const SizedBox(width: 10),
                      Expanded(child: card1),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                card2,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              card0,
              const SizedBox(height: 10),
              card1,
              const SizedBox(height: 10),
              card2,
            ],
          );
        },
      ),
    );
  }
}

/// Chapter 02 & 03: Google Photos-grade Timeline & Cinema Showcase.
class AboutMediaExperienceShowcase extends StatelessWidget {
  const AboutMediaExperienceShowcase({
    super.key,
    required this.phase,
    required this.scrollOffset,
    required this.isDark,
    required this.colors,
    required this.theme,
  });

  final double phase;
  final double scrollOffset;
  final bool isDark;
  final ColorScheme colors;
  final ThemeData theme;

  static const _memories = <(String, String, Color, IconData)>[
    ('那年今日', '2023 · 镰仓海街', Color(0xFF8B5CF6), Icons.auto_awesome_rounded),
    ('星标精选', '128 张家庭高光', Color(0xFFEC4899), Icons.favorite_rounded),
    ('足迹地图', 'EXIF 经纬度聚簇', Color(0xFF06B6D4), Icons.map_rounded),
    ('共享相册', '受控软链接直通', Color(0xFF10B981), Icons.folder_shared_rounded),
  ];

  static const _posters = <(int, String, String, String, Color)>[
    (1, '深海归屿', '4K HDR10 · 原盘', '9.4', Color(0xFF0071E3)),
    (2, '镰仓物语', '杜比视界 · 双语', '9.2', Color(0xFF8B5CF6)),
    (3, '流光之屿', 'REMUX · 无损音轨', '9.0', Color(0xFF10B981)),
    (4, '星际漫游', 'IMAX 画幅 · 4K', '9.5', Color(0xFFF59E0B)),
  ];

  Widget _buildPhotoRadarPod(double p, {required bool isWide}) {
    return Container(
      height: isWide ? 148 : 112,
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF0A1120).withValues(alpha: 0.65)
            : Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF8B5CF6).withValues(alpha: 0.24),
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: PhotoRadarPainter(phase: p, isDark: isDark),
            ),
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF0F172A).withValues(alpha: 0.88)
                      : Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFF8B5CF6).withValues(alpha: 0.35),
                  ),
                ),
                child: const Text(
                  'EXIF · GPS 实时聚簇',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF8B5CF6),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoChapter(double p) {
    return AboutChapterContainer(
      isDark: isDark,
      chapterNumber: '02',
      eyebrow: 'MEMORIES & TIMELINE · 光影图库漫游',
      accent: const Color(0xFF8B5CF6),
      title: '回忆精选与多维时间线',
      subtitle: '对齐 Google Photos 的「那年今日 / 星标精选 / 足迹地图」横向漫游，支持按相机型号、GPS 与拍摄日期多维检索，并通过受控相对软链接与家人安全共享文件夹相册。',
      stageCanvas: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [Color(0xFF0E1729), Color(0xFF14213D)]
                : const [Color(0xFFF5F3FF), Color(0xFFEDE9FE)],
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 540;
            final useTwoColPills = constraints.maxWidth >= 340;
            final pills = [
              for (var i = 0; i < _memories.length; i++)
                AboutDriftingMemoryPill(
                  title: _memories[i].$1,
                  subtitle: _memories[i].$2,
                  color: _memories[i].$3,
                  icon: _memories[i].$4,
                  offsetPhase: (p + i * 0.25) % 1.0,
                  isDark: isDark,
                ),
            ];
            final memoryGrid = useTwoColPills
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(child: pills[0]),
                          const SizedBox(width: 8),
                          Expanded(child: pills[1]),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: pills[2]),
                          const SizedBox(width: 8),
                          Expanded(child: pills[3]),
                        ],
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < pills.length; i++) ...[
                        pills[i],
                        if (i < pills.length - 1) const SizedBox(height: 6),
                      ],
                    ],
                  );
            final radarPod = _buildPhotoRadarPod(p, isWide: isWide);
            return Padding(
              padding: const EdgeInsets.all(14),
              child: isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(flex: 6, child: memoryGrid),
                        const SizedBox(width: 12),
                        Expanded(flex: 4, child: radarPod),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        memoryGrid,
                        const SizedBox(height: 10),
                        radarPod,
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCinemaChapter(double p) {
    return AboutChapterContainer(
      isDark: isDark,
      chapterNumber: '03',
      eyebrow: 'PRIVATE CINEMA · 巨幕私人影院',
      accent: const Color(0xFFE50914),
      title: '巨幕海报墙与智能刮削',
      subtitle: '全宽巨幕 Billboard、TOP 10 口碑序列与红线续播进度条；扫描完成自动衔接 TMDB 增量刮削，影片详情页支持免凭据豆瓣搜索、TMDB 匹配与本地 NFO 一键导入。',
      stageCanvas: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final visibleCount = w >= 620 ? 4 : (w >= 430 ? 3 : 2);
          return Stack(
            children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: CinemaBillboardStagePainter(phase: p),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3.5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE50914),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'TOP 10 · 4K HDR',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 3.5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.16),
                                ),
                              ),
                              child: const Text(
                                'TMDB · 豆瓣 · NFO 自动刮削',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFE2E8F0),
                                ),
                              ),
                            ),
                          ],
                        ),
                        AboutCinemaAudioSpectrumPill(phase: p),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        for (var i = 0; i < visibleCount; i++) ...[
                          Expanded(
                            child: Transform.translate(
                              offset: Offset(
                                0,
                                math.sin(p * math.pi * 2 + i * 0.9) * 2.5,
                              ),
                              child: AboutMiniCinemaPosterCard(
                                rank: _posters[i].$1,
                                title: _posters[i].$2,
                                tag: _posters[i].$3,
                                rating: _posters[i].$4,
                                accent: _posters[i].$5,
                                progress: (p + i * 0.21) % 1.0,
                              ),
                            ),
                          ),
                          if (i < visibleCount - 1) const SizedBox(width: 10),
                        ],
                      ],
                    ),
                    const SizedBox(height: 14),
                    AboutCinemaPlayerScrubberBar(phase: p),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = (phase + scrollOffset * 0.001) % 1.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPhotoChapter(p),
        const SizedBox(height: 18),
        _buildCinemaChapter(p),
      ],
    );
  }
}

/// Chapter 04: Cross-Platform Flow, Security & System Overview Showcase.
class AboutCrossPlatformShowcase extends StatelessWidget {
  const AboutCrossPlatformShowcase({
    super.key,
    required this.phase,
    required this.scrollOffset,
    required this.isDark,
    required this.colors,
    required this.theme,
  });

  final double phase;
  final double scrollOffset;
  final bool isDark;
  final ColorScheme colors;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final p = (phase + scrollOffset * 0.0009) % 1.0;
    final activeCard = ((p * 2).floor()) % 2;

    final spec0 = AboutAnimatedFeatureSpecCard(
      isDark: isDark,
      theme: theme,
      colors: colors,
      highlighted: activeCard == 0,
      badgeLabel: '全家设备通用',
      badgeColor: const Color(0xFF8B5CF6),
      icon: Icons.devices_rounded,
      iconGradient: const [Color(0xFF8B5CF6), Color(0xFFA78BFA)],
      title: '跨平台统一体验',
      subtitle: '支持 macOS、iOS、Android 等多平台，使用一致的文件与媒体流转界面。',
      tags: const ['Mac / iPhone / Android', '一致流转操作', '原生丝滑渲染'],
    );
    final spec1 = AboutAnimatedFeatureSpecCard(
      isDark: isDark,
      theme: theme,
      colors: colors,
      highlighted: activeCard == 1,
      badgeLabel: '系统安全隔离',
      badgeColor: const Color(0xFF06B6D4),
      icon: Icons.lock_outline_rounded,
      iconGradient: const [Color(0xFF06B6D4), Color(0xFF38BDF8)],
      title: '凭据与会话安全',
      subtitle: '登录会话保存在设备的安全存储中，不保存明文密码；可随时改密或撤销。',
      tags: const ['系统级安全钥匙串', '不保存明文密码', '会话随时安全撤销'],
    );

    return AboutChapterContainer(
      isDark: isDark,
      chapterNumber: '04',
      eyebrow: 'CROSS-PLATFORM & SECURITY · 多端流转与隐私安全',
      accent: const Color(0xFF06B6D4),
      title: '关于客户端与全端互联',
      subtitle: '无论是 Mac 原生端、iPhone / iPad、Android 还是 Web 浏览器，乃至局域网 Finder 原生 SMB 与 WebDAV 挂载，均遵循同一套物理根身份校验与安全会话保护。',
      stageCanvas: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 560;
          final hubNode = AboutStageFloatingNode(
            icon: Icons.verified_user_rounded,
            title: 'Argon2id · Keychain',
            subtitle: '物理根代际鉴权中心',
            accent: const Color(0xFF10B981),
            isDark: isDark,
            pulse: 0.5 + 0.5 * math.sin(p * math.pi * 2),
          );

          const devMac = AboutDeviceCornerChip(
            icon: Icons.desktop_mac_rounded,
            label: 'macOS · SMB',
            subtitle: 'Bonjour 原生挂载',
          );
          const devIos = AboutDeviceCornerChip(
            icon: Icons.phone_iphone_rounded,
            label: 'iOS · iPadOS',
            subtitle: '原片流转与相册',
          );
          const devAndroid = AboutDeviceCornerChip(
            icon: Icons.phone_android_rounded,
            label: 'Android 备份',
            subtitle: 'WorkManager 守护',
          );
          const devWeb = AboutDeviceCornerChip(
            icon: Icons.language_rounded,
            label: 'Web · WebDAV',
            subtitle: '浏览器与受控读写',
          );

          return Stack(
            children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: CrossPlatformStagePainter(
                      phase: p,
                      isDark: isDark,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: isWide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Expanded(
                            flex: 4,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                devMac,
                                SizedBox(height: 12),
                                devAndroid,
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(flex: 5, child: Center(child: hubNode)),
                          const SizedBox(width: 12),
                          const Expanded(
                            flex: 4,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [devIos, SizedBox(height: 12), devWeb],
                            ),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(child: hubNode),
                          const SizedBox(height: 10),
                          const Row(
                            children: [
                              Expanded(child: devMac),
                              SizedBox(width: 8),
                              Expanded(child: devIos),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Row(
                            children: [
                              Expanded(child: devAndroid),
                              SizedBox(width: 8),
                              Expanded(child: devWeb),
                            ],
                          ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
      bottomContent: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 560) {
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: spec0),
                  const SizedBox(width: 12),
                  Expanded(child: spec1),
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [spec0, const SizedBox(height: 10), spec1],
          );
        },
      ),
    );
  }
}
