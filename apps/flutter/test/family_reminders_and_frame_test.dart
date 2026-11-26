import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/photo_frame_dashboard_overlay.dart';
import 'package:lightisle/features/media/photo_frame_page.dart';
import 'package:lightisle/features/overview/family_reminders_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FamilyLifeApi extends LightIsleApi {
  _FamilyLifeApi() : super('http://127.0.0.1:16666');

  final List<Map<String, Object?>> sendCalls = [];
  final List<Map<String, Object?>> getCalls = [];

  List<Map<String, dynamic>> reminders = [
    {
      'id': 11,
      'authorUserId': 1,
      'authorUsername': 'alice',
      'title': '妈妈农历生日',
      'category': 'birthday',
      'calendarType': 'lunar',
      'year': 1968,
      'month': 8,
      'day': 15,
      'isLeapMonth': false,
      'repeatRule': 'yearly',
      'intervalDays': 0,
      'nextSolarDate': '2026-09-25',
      'daysUntil': 3,
      'yearsCount': 58,
      'lunarLabel': '农历八月十五',
      'remindDays': [7, 1, 0],
      'remindDaysCsv': '7,1,0',
      'notifyEnabled': true,
      'color': 'rose',
      'notes': '提前订鲜花和蛋糕',
      'createdAt': 1700000000,
      'updatedAt': 1700000000,
    },
    {
      'id': 12,
      'authorUserId': 1,
      'authorUsername': 'alice',
      'title': '更换净水器滤芯',
      'category': 'chore',
      'calendarType': 'solar',
      'year': 2026,
      'month': 10,
      'day': 1,
      'isLeapMonth': false,
      'repeatRule': 'interval_days',
      'intervalDays': 90,
      'nextSolarDate': '2026-10-01',
      'daysUntil': 9,
      'yearsCount': 0,
      'lunarLabel': '',
      'remindDays': [3, 0],
      'remindDaysCsv': '3,0',
      'notifyEnabled': true,
      'color': 'sage',
      'notes': '型号 RO-400',
      'createdAt': 1700000000,
      'updatedAt': 1700000000,
    },
  ];

  List<Map<String, dynamic>> boardMessages = [
    {
      'id': 5,
      'authorUserId': 1,
      'authorUsername': '爸爸',
      'authorRole': 'admin',
      'content': '周六上午一起去植物园野餐',
      'tag': '提醒',
      'color': 'amber',
      'pinned': true,
      'pinnedAt': 1700000500,
      'pinnedBy': '爸爸',
      'createdAt': 1700000400,
    },
  ];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    getCalls.add({'path': path, 'query': query});
    if (path == '/api/v2/family-reminders') {
      return {
        'reminders': reminders,
        'todaySolar': '2026-09-22',
        'todayLunar': {
          'year': 2026,
          'month': 8,
          'day': 12,
          'isLeap': false,
          'ganZhi': '丙午',
          'zodiac': '马',
          'monthName': '八月',
          'dayName': '十二',
          'display': '农历八月十二 · 丙午马年',
        },
        'isAdmin': true,
        'currentUserId': 1,
        'currentUsername': 'alice',
      };
    }
    if (path == '/api/v2/board/messages') {
      return {'messages': boardMessages, 'currentUserId': 1};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    sendCalls.add({'method': method, 'path': path, 'body': body});
    if (method == 'POST' && path == '/api/v2/family-reminders') {
      final map = Map<String, dynamic>.from(body as Map);
      final created = {
        'id': 99,
        'authorUserId': 1,
        'authorUsername': 'alice',
        ...map,
        'nextSolarDate': '2026-11-11',
        'daysUntil': 5,
        'lunarLabel': map['calendarType'] == 'lunar' ? '农历闰四月初五' : '',
        'createdAt': 1700001000,
        'updatedAt': 1700001000,
      };
      reminders = [...reminders, created];
      return {'reminder': created};
    }
    if (method == 'POST' && path == '/api/v2/family-reminders/12/complete') {
      final updated = {
        ...reminders[1],
        'nextSolarDate': '2026-12-30',
        'daysUntil': 99,
      };
      reminders[1] = updated;
      return {'completed': true, 'reminder': updated};
    }
    if (method == 'DELETE' && path.startsWith('/api/v2/family-reminders/')) {
      final id = int.tryParse(path.split('/').last) ?? 0;
      reminders = reminders.where((r) => r['id'] != id).toList();
      return {'deleted': true, 'id': id};
    }
    return {};
  }

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    // 1x1 transparent PNG
    return Uint8List.fromList(const <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'FamilyRemindersSection renders lunar reminders, supports check-in and lunar creation with leap month',
    (tester) async {
      final api = _FamilyLifeApi();
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: FamilyRemindersSection(api: api, isAdmin: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('近期纪念日与家务'), findsOneWidget);
      expect(find.text('农历八月十二 · 丙午马年'), findsOneWidget);
      expect(find.text('妈妈农历生日'), findsOneWidget);
      expect(find.text('3 天后'), findsOneWidget);
      expect(find.text('更换净水器滤芯'), findsOneWidget);

      // Complete chore reminder.
      await tester.tap(find.byKey(const ValueKey('familyReminderComplete-12')));
      await tester.pumpAndSettle();
      expect(
        api.sendCalls.any(
          (c) =>
              c['method'] == 'POST' &&
              c['path'] == '/api/v2/family-reminders/12/complete',
        ),
        isTrue,
      );
      expect(find.textContaining('2026-12-30'), findsWidgets);

      // Open creator sheet, switch to lunar, toggle leap month, and submit.
      await tester.tap(find.byKey(const ValueKey('addFamilyReminderButton')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('reminderTitleField')),
        '爷爷农历寿辰',
      );
      await tester.tap(find.byKey(const ValueKey('reminderLunarChip')));
      await tester.pumpAndSettle();

      final leapSwitch = find.byKey(const ValueKey('reminderLeapMonthSwitch'));
      expect(leapSwitch, findsOneWidget);
      await tester.ensureVisible(leapSwitch);
      await tester.tap(leapSwitch);
      await tester.pumpAndSettle();

      final submitBtn = find.byKey(const ValueKey('reminderSubmitButton'));
      await tester.ensureVisible(submitBtn);
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      final postCall = api.sendCalls.firstWhere(
        (c) => c['method'] == 'POST' && c['path'] == '/api/v2/family-reminders',
      );
      final body = Map<String, dynamic>.from(postCall['body'] as Map);
      expect(body['title'], '爷爷农历寿辰');
      expect(body['calendarType'], 'lunar');
      expect(body['isLeapMonth'], isTrue);
      expect(find.text('爷爷农历寿辰'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'PhotoFramePage toggles and persists dashboard mode, shows board + 14d reminders + night glow, and manages keep-screen-on',
    (tester) async {
      final api = _FamilyLifeApi();
      addTearDown(api.close);

      final keepAwakeCalls = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DeviceDisplayKeepAwake.channel, (call) async {
            if (call.method == 'setKeepScreenOn') {
              final args = Map<Object?, Object?>.from(call.arguments as Map);
              keepAwakeCalls.add(args['enabled'] == true);
              return true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DeviceDisplayKeepAwake.channel, null);
      });

      final assets = [
        const PhotoAsset(
          id: 1,
          path: 'Photos/family.jpg',
          name: 'family.jpg',
          type: 'photo',
          size: 1024,
          takenAt: 1700000000,
          favorite: false,
          canWrite: true,
        ),
      ];

      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.dark),
          home: PhotoFramePage(
            api: api,
            assets: assets,
            title: '家庭相册',
            nowOverride: DateTime(2026, 9, 22, 23, 15),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(keepAwakeCalls, contains(true));
      expect(find.byKey(const ValueKey('dashboardBoardCard')), findsNothing);

      // Switch to Family Dashboard mode and verify persistence + overlay content.
      await tester.tap(
        find.byKey(const ValueKey('photoFrameDashboardModeButton')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PhotoFramePage.dashboardModePrefKey), isTrue);

      expect(find.byKey(const ValueKey('dashboardBoardCard')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('dashboardRemindersCard')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('dashboardNightDimScrim')),
        findsOneWidget,
      );
      expect(find.text('周六上午一起去植物园野餐'), findsOneWidget);
      expect(find.text('妈妈农历生日'), findsOneWidget);
      expect(find.text('农历八月十二 · 丙午马年'), findsOneWidget);

      // Verify 14-day filter query was sent.
      expect(
        api.getCalls.any(
          (c) =>
              c['path'] == '/api/v2/family-reminders' &&
              (c['query'] as Map<String, String>?)?['days'] == '14',
        ),
        isTrue,
      );

      // Dispose page and verify keep-screen-on is restored to false.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      expect(keepAwakeCalls.last, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
