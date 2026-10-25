import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lightisle/features/files/upload_resume_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('upload IDs survive between store instances and can be removed', () async {
    final original = UploadResumeStore();
    await original.write('upload-key', 'server-id');
    expect(await UploadResumeStore().read('upload-key'), 'server-id');
    await original.remove('upload-key');
    expect(await UploadResumeStore().read('upload-key'), isNull);
    await original.remove(null);
  });

  test('preference failures do not prevent upload flow and are reported', () async {
    final failures = <Object>[];
    final storage = UploadResumeStore(
      openPreferences: () async => throw StateError('storage unavailable'),
      reportFailure: failures.add,
    );
    expect(await storage.read('upload-key'), isNull);
    await storage.write('upload-key', 'server-id');
    await storage.remove('upload-key');
    expect(failures, hasLength(3));
  });
}
