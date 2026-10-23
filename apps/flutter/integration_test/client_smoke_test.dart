import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player/video_player.dart';

import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/main.dart' as client;

const _server = String.fromEnvironment('LIGHTISLE_SMOKE_SERVER');
const _username = String.fromEnvironment('LIGHTISLE_SMOKE_USERNAME');
const _password = String.fromEnvironment('LIGHTISLE_SMOKE_PASSWORD');
const _fingerprint = String.fromEnvironment('LIGHTISLE_SMOKE_FINGERPRINT');
const _captureScreenshots = bool.fromEnvironment('LIGHTISLE_SMOKE_CAPTURE');
const _movieName = 'LightIsleNativeSmoke.mp4';
const _movieTitle = 'LightIsleNativeSmoke';
const _textFixture = 'LightIsleSmokeNotes.txt';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'logs in, browses files and gallery, plays and seeks a movie, then logs out',
    (tester) async {
      expect(
        _server,
        isNotEmpty,
        reason: 'Use scripts/test-flutter-native.py.',
      );
      expect(
        _username,
        isNotEmpty,
        reason: 'Use scripts/test-flutter-native.py.',
      );
      expect(
        _password,
        isNotEmpty,
        reason: 'Use scripts/test-flutter-native.py.',
      );

      final preferences = await SharedPreferences.getInstance();
      final previousServer = preferences.getString('lightisle.server');
      final pinKey = 'lightisle.certificatePin.${Uri.parse(_server).origin}';
      final previousPin = preferences.getString(pinKey);
      addTearDown(() async {
        if (previousServer == null) {
          await preferences.remove('lightisle.server');
        } else {
          await preferences.setString('lightisle.server', previousServer);
        }
        if (previousPin == null) {
          await preferences.remove(pinKey);
        } else {
          await preferences.setString(pinKey, previousPin);
        }
      });
      client.main();
      await _waitFor(tester, find.text('连接并登录'));

      final editableFields = find.byType(EditableText);
      expect(editableFields, findsNWidgets(3));
      await tester.enterText(editableFields.at(0), _server);
      await tester.enterText(editableFields.at(1), _username);
      await tester.enterText(editableFields.at(2), _password);
      if (_fingerprint.isNotEmpty) {
        await tester.ensureVisible(find.text('连接安全设置'));
        await tester.tap(find.text('连接安全设置'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('certificateFingerprint')),
          _fingerprint,
        );
      }
      await tester.ensureVisible(find.text('连接并登录'));
      await tester.tap(find.text('连接并登录'));

      await _waitFor(tester, find.text('轻屿 · 概览'));
      await _captureScreen(tester, 'overview');

      await _selectTab(tester, '文件');
      await _waitFor(tester, find.text(_textFixture));
      await _waitFor(tester, find.text(_movieName));
      await _captureScreen(tester, 'files');

      await _selectTab(tester, '图库');
      await _waitFor(tester, find.text('照片图库'));
      final galleryMovie = find.bySemanticsLabel(
        RegExp(r'LightIsleNativeSmoke\.mp4, 视频'),
        skipOffstage: false,
      );
      final galleryScan = find.text('扫描媒体');
      await _tapWhenVisible(tester, galleryScan);
      await _waitFor(
        tester,
        galleryMovie,
        timeout: const Duration(seconds: 90),
      );
      await _captureScreen(tester, 'gallery');

      await _selectTab(tester, '影视');
      await _waitFor(tester, find.text('私人影院'));
      await _tapWhenVisible(tester, find.text('扫描影视库'));
      // The card's semantics label changes when the native decoder/probe
      // reports that direct playback is unavailable. The visible title is
      // stable across both supported states and remains inside the tappable
      // card, so use it to open the player details.
      final cinemaTitles = find.text(_movieTitle);
      await _waitFor(tester, cinemaTitles, timeout: const Duration(seconds: 90));
      final cinemaMovie = cinemaTitles.last;
      final cinemaCard = find
          .ancestor(of: cinemaMovie, matching: find.byType(IsleSurface))
          .first;
      final moviePoster = find
          .descendant(of: cinemaCard, matching: find.byType(InkWell))
          .first;
      await tester.ensureVisible(moviePoster);
      await tester.tap(moviePoster);

      await _waitFor(tester, find.text('电影详情'));
      final cinemaDialog = find.byType(Dialog).last;
      final videoView = find.descendant(
        of: cinemaDialog,
        matching: find.byType(VideoPlayer),
      );
      await _waitFor(tester, videoView, timeout: const Duration(seconds: 45));
      await _captureScreen(tester, 'cinema');
      expect(
        find.descendant(of: cinemaDialog, matching: find.text('播放进度')),
        findsOneWidget,
      );

      final playButton = find.byTooltip('播放');
      await tester.ensureVisible(playButton);
      await tester.tap(playButton);
      final pauseButton = find.byTooltip('暂停');
      await _waitFor(tester, pauseButton, timeout: const Duration(seconds: 5));
      await tester.tap(pauseButton);
      await tester.pump(const Duration(milliseconds: 150));

      final seekBar = find.descendant(
        of: cinemaDialog,
        matching: find.byType(VideoProgressIndicator),
      );
      await tester.ensureVisible(seekBar);
      await tester.pump();
      final seekBounds = tester.getRect(seekBar);
      await tester.tapAt(
        Offset(seekBounds.left + seekBounds.width * .55, seekBounds.center.dy),
      );
      await _waitFor(
        tester,
        find.descendant(of: cinemaDialog, matching: find.text('00:01')),
        timeout: const Duration(seconds: 5),
      );

      final closePlayer = find.byTooltip('关闭').last;
      await tester.ensureVisible(closePlayer);
      await tester.tap(closePlayer);
      await tester.pumpAndSettle();
      await _selectTab(tester, '设置');
      await _waitFor(tester, find.text('账号与连接'));
      await _captureScreen(tester, 'settings');
      await _tapWhenVisible(tester, find.text('密码与登录会话'));
      await _waitFor(tester, find.text('当前会话'));
      await _captureScreen(tester, 'security');
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      await _tapWhenVisible(tester, find.text('安全审计'));
      await _waitFor(tester, find.textContaining('查看最近 90 天'));
      await _captureScreen(tester, 'audit');
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      await _tapWhenVisible(tester, find.text('存储与任务通知'));
      await _waitFor(tester, find.textContaining('查看共享盘离线'));
      await _captureScreen(tester, 'alerts');
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      await _tapWhenVisible(tester, find.text('退出登录 / 切换服务器'));
      await _waitFor(tester, find.text('将结束当前会话。下次连接需要重新输入密码。'));
      await tester.tap(find.text('退出登录').last);
      await _waitFor(tester, find.text('连接并登录'));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _captureScreen(WidgetTester tester, String name) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 15),
  );
  if (!_captureScreenshots) return;
  await tester.pump(const Duration(milliseconds: 200));
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final bytes = await binding.takeScreenshot('lightisle-$name');
  final temporary = await getTemporaryDirectory();
  final directory = Directory('${temporary.path}/lightisle-native-evidence');
  await directory.create(recursive: true);
  await File('${directory.path}/$name.png').writeAsBytes(bytes);
  debugPrint('LIGHTISLE_SCREEN:$name');
}

Future<void> _selectTab(WidgetTester tester, String label) async {
  final tab = find.text(label).last;
  await tester.ensureVisible(tab);
  await tester.tap(tab);
  await tester.pump();
}

Future<void> _tapWhenVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: find.byType(Scrollable).last,
    );
  }
  final target = finder.first;
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(target);
  await tester.pump();
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsOneWidget);
}
