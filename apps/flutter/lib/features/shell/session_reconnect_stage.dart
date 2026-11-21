import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../media/offline_photo_store.dart';
import '../media/offline_photos_page.dart';

/// Opens locally retained offline photos for the saved session account without
/// requiring a live NAS session.
Future<void> openOfflinePhotosFromSnapshot({
  required Map<String, dynamic>? snapshot,
  required GlobalKey<NavigatorState> navigatorKey,
  required bool Function() isMounted,
}) async {
  if (snapshot == null ||
      snapshot['offlineAccountId'] is! int ||
      (snapshot['offlineAccountId'] as int) < 1 ||
      snapshot['server'] is! String) {
    return;
  }
  final offlineApi = LightIsleApi(
    snapshot['server'] as String,
    allowInsecureHttp: true,
    certificateFingerprint: snapshot['certificateFingerprint'] as String?,
  );
  final accountId = 'uid:${snapshot['offlineAccountId']}';
  try {
    final sources = await OfflinePhotoStore.savedLocations(
      api: offlineApi,
      accountId: accountId,
    );
    if (!isMounted()) return;
    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    if (sources.isEmpty) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('当前账号还没有保存过本机离线照片。')));
      return;
    }
    OfflinePhotoSource? chosen;
    if (sources.length == 1) {
      chosen = sources.single;
    } else {
      chosen = await showIsleDialog<OfflinePhotoSource>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('选择离线照片所在的硬盘'),
          children: [
            for (final source in sources)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, source),
                child: Text(source.name),
              ),
          ],
        ),
      );
    }
    if (chosen == null || !isMounted() || !context.mounted) return;
    offlineApi.selectRoot(chosen.root);
    await navigatorKey.currentState?.push<void>(
      buildIslePageRoute(
        builder: (_) =>
            OfflinePhotosPage(api: offlineApi, accountId: accountId),
      ),
    );
  } catch (error) {
    final context = navigatorKey.currentContext;
    if (context != null && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('打开本机离线照片失败：${userFacingError(error)}')),
      );
    }
  } finally {
    offlineApi.close();
  }
}

/// Non-overlapping gallery entrance wrapper for top-level Auth / Reconnect /
/// Shell transitions. Never keeps a previous stage mounted (preventing disposed
/// API access) and removes all transform wrappers once settled.
class IsleStageEntrance extends StatefulWidget {
  const IsleStageEntrance({
    super.key,
    required this.stageKey,
    required this.child,
  });

  final Object stageKey;
  final Widget child;

  @override
  State<IsleStageEntrance> createState() => _IsleStageEntranceState();
}

class _IsleStageEntranceState extends State<IsleStageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
          vsync: this,
          duration: IsleMotion.authSwitch,
          value: 1.0,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() {});
          }
        });
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.76, curve: Curves.easeOut),
    );
    _scale = Tween<double>(begin: 0.988, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: IsleMotion.gentleSpring),
    );
    _slide = Tween<Offset>(begin: const Offset(0, 10), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _controller, curve: IsleMotion.gentleSpring),
        );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (IsleMotion.reducedMotion(context) &&
        (_controller.isAnimating || _controller.value < 1.0)) {
      _controller.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant IsleStageEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stageKey != widget.stageKey) {
      if (IsleMotion.reducedMotion(context)) {
        if (_controller.isAnimating || _controller.value < 1.0) {
          _controller.value = 1.0;
        }
      } else {
        _controller.forward(from: 0.0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (IsleMotion.reducedMotion(context) ||
        (!_controller.isAnimating && _controller.value >= 1.0)) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, stageChild) => Opacity(
        opacity: _fade.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: _slide.value,
          child: Transform.scale(scale: _scale.value, child: stageChild),
        ),
      ),
      child: widget.child,
    );
  }
}

/// Reconnect / session-restore fallback screen shown when verifying or
/// recovering a saved NAS session.
class SessionReconnectPage extends StatelessWidget {
  const SessionReconnectPage({
    super.key,
    required this.busy,
    this.statusLabel,
    required this.message,
    required this.onRetry,
    required this.onUseAnotherAccount,
    this.onBrowseOfflinePhotos,
  });

  final bool busy;
  final String? statusLabel;
  final String? message;
  final VoidCallback onRetry, onUseAnotherAccount;
  final VoidCallback? onBrowseOfflinePhotos;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: IsleGlassSurface(
                radius: IsleRadius.sheet,
                padding: const EdgeInsets.fromLTRB(26, 30, 26, 26),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: ShapeDecoration(
                        shape: IsleShapes.squircle(
                          26,
                          side: BorderSide(
                            color: IsleGlass.rimBorderColor(
                              dark,
                              isGlass: true,
                            ),
                            width: 1.0,
                          ),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            palette['cardTop'].withValues(
                              alpha: dark ? 0.90 : 0.96,
                            ),
                            Color.lerp(
                              palette['cardBottom'],
                              colors.primary,
                              dark ? 0.12 : 0.05,
                            )!,
                          ],
                        ),
                        shadows: [
                          BoxShadow(
                            color: colors.primary.withValues(
                              alpha: dark ? 0.24 : 0.14,
                            ),
                            blurRadius: 28,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: const Center(child: IsleBrandMark(size: 56)),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      busy ? '正在恢复登录' : '暂时无法连接 NAS',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (busy)
                      IsleLoadingState(
                        compact: true,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        label: statusLabel ?? '正在安全验证你的私有会话…',
                      )
                    else ...[
                      Text(
                        message!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('重试连接'),
                        ),
                      ),
                      if (onBrowseOfflinePhotos != null) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: onBrowseOfflinePhotos,
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('不连接 NAS，查看本机离线照片'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: onUseAnotherAccount,
                        child: const Text('使用其他账号或服务器'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
