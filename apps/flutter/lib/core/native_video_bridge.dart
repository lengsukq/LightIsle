import 'dart:async';

import 'package:flutter/services.dart';

/// Unified MethodChannel bridge for native macOS window chrome & video player
/// actions handled by `MainFlutterWindow.swift` / native video platform handlers.
abstract final class NativeVideoBridge {
  static const String channelName = 'lightisle/native-video';
  static const MethodChannel channel = MethodChannel(channelName);

  static void startWindowDrag() {
    unawaited(channel.invokeMethod<void>('startWindowDrag').catchError((_) {}));
  }

  static void doubleClickTitlebar() {
    unawaited(
      channel.invokeMethod<void>('doubleClickTitlebar').catchError((_) {}),
    );
  }

  static Future<bool?> openLocalVideo(String path) =>
      channel.invokeMethod<bool>('openLocal', {'path': path});

  static Future<void> toggleFullScreen() =>
      channel.invokeMethod<void>('toggleFullScreen');

  static Future<void> exitFullScreen() =>
      channel.invokeMethod<void>('exitFullScreen');
}
