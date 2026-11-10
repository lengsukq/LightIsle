import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'media_models.dart';

/// Manages the user's preference for local hardware decoding (direct file
/// streaming via `?direct=1`) versus server-side FFmpeg transcoding.
class CinemaDecodePreference {
  CinemaDecodePreference._();

  static const String prefsKey = 'lightisle_cinema_prefer_local_decode';

  static final ValueNotifier<bool> preferLocalDecode = ValueNotifier<bool>(
    false,
  );

  static Future<bool> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getBool(prefsKey) ?? false;
      preferLocalDecode.value = value;
      return value;
    } catch (_) {
      return preferLocalDecode.value;
    }
  }

  static Future<void> setPreferLocalDecode(bool value) async {
    preferLocalDecode.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey, value);
    } catch (_) {
      // Keep in-memory setting even if persistence is unavailable in tests.
    }
  }
}

Future<void> showCinemaDecodeSettingsDialog(BuildContext context) async {
  await CinemaDecodePreference.load();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => ValueListenableBuilder<bool>(
      valueListenable: CinemaDecodePreference.preferLocalDecode,
      builder: (context, enabled, _) => AlertDialog(
        title: const Text('影视播放与本地解码'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile.adaptive(
                key: const ValueKey('cinemaPreferLocalDecodeSwitch'),
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  '优先本地解码（原画直传）',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  '开启后，即使服务器已安装 FFmpeg，也会优先直接传输原始视频文件由当前设备本地硬件解码播放。',
                ),
                value: enabled,
                onChanged: (next) =>
                    CinemaDecodePreference.setPreferLocalDecode(next),
              ),
              const SizedBox(height: 12),
              Text(
                '• 未安装 FFmpeg 时：系统会自动跳过转码并直传原文件由本地解码播放。\n'
                '• 已安装 FFmpeg 时：开启此开关可避免服务器 CPU 转码开销，享受原片画质与拖动响应；若当前设备不支持该视频编码，播放器会自动回退至服务器转码。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showCinemaExternalPlayerDialog(
  BuildContext context, {
  required LightIsleApi api,
  required CinemaFilm film,
}) async {
  String? streamUrl;
  String? errorText;
  bool loading = true;

  Future<void> createStreamLink(StateSetter update) async {
    update(() {
      loading = true;
      errorText = null;
    });
    try {
      final response = await api.send(
        'POST',
        '/api/v2/shares',
        body: <String, Object>{'path': film.path, 'expiresInHours': 6},
      );
      final share = response['share'] is Map<String, dynamic>
          ? response['share'] as Map<String, dynamic>
          : response;
      final token = (share['token'] ?? '').toString().trim();
      if (token.isEmpty) {
        throw StateError('服务器未返回有效的串流令牌。');
      }
      streamUrl = api.uri('/s/$token', const {'download': '1'}).toString();
    } catch (error) {
      errorText = userFacingError(error);
    } finally {
      update(() => loading = false);
    }
  }

  Future<void> launchScheme(BuildContext dialogContext, Uri uri) async {
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && dialogContext.mounted) {
        ScaffoldMessenger.maybeOf(dialogContext)?.showSnackBar(
          const SnackBar(content: Text('未检测到对应播放器，请先安装或复制串流链接手动打开。')),
        );
      }
    } catch (_) {
      if (dialogContext.mounted) {
        ScaffoldMessenger.maybeOf(dialogContext)?.showSnackBar(
          const SnackBar(content: Text('无法唤起外部播放器，请复制串流链接手动打开。')),
        );
      }
    }
  }

  var initialized = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setModalState) {
        if (!initialized) {
          initialized = true;
          Future<void>.microtask(() => createStreamLink(setModalState));
        }
        final url = streamUrl;
        return AlertDialog(
          title: const Text('外部播放器本地解码'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: loading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : errorText != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('无法生成临时串流链接：$errorText'),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () => createStreamLink(setModalState),
                        child: const Text('重试'),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '已为“${film.title}”生成 6 小时有效的原画直传串流链接，可唤起本机播放器进行硬解播放（支持 MKV / HEVC / 杜比视界 / 内封 ASS 字幕）：',
                        style: Theme.of(dialogContext).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(
                        key: const ValueKey('externalPlayerIinaButton'),
                        onPressed: url == null
                            ? null
                            : () => launchScheme(
                                dialogContext,
                                Uri.parse(
                                  'iina://weblink?url=${Uri.encodeComponent(url)}',
                                ),
                              ),
                        icon: const Icon(Icons.play_circle_fill_rounded),
                        label: const Text('使用 IINA 打开 (macOS)'),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        key: const ValueKey('externalPlayerInfuseButton'),
                        onPressed: url == null
                            ? null
                            : () => launchScheme(
                                dialogContext,
                                Uri.parse(
                                  'infuse://x-callback-url/play?url=${Uri.encodeComponent(url)}',
                                ),
                              ),
                        icon: const Icon(Icons.movie_filter_rounded),
                        label: const Text('使用 Infuse 打开 (iOS / macOS)'),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        key: const ValueKey('externalPlayerVlcButton'),
                        onPressed: url == null
                            ? null
                            : () => launchScheme(
                                dialogContext,
                                Uri.parse('vlc://$url'),
                              ),
                        icon: const Icon(Icons.slideshow_rounded),
                        label: const Text('使用 VLC 打开'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const ValueKey('externalPlayerCopyUrlButton'),
                        onPressed: url == null
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: url),
                                );
                                if (dialogContext.mounted) {
                                  ScaffoldMessenger.maybeOf(
                                    dialogContext,
                                  )?.showSnackBar(
                                    const SnackBar(
                                      content: Text('已复制原画串流链接到剪贴板'),
                                    ),
                                  );
                                }
                              },
                        icon: const Icon(Icons.copy_rounded, size: 17),
                        label: const Text('复制原画串流直链'),
                      ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    ),
  );
}
