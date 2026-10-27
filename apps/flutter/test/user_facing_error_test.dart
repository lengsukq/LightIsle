import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/user_facing_error.dart';

void main() {
  test('volume offline includes a safe reconnection step', () {
    final message = userFacingError(const LightIsleApiException(
      code: 'volume_offline', message: 'volume_offline', statusCode: 503,
    ));
    expect(message, contains('重新连接原卷'));
    expect(message, isNot('volume_offline'));
  });
  test('TLS errors keep the helpful safe API-client message', () {
    expect(userFacingError(const LightIsleApiException(
      code: 'certificate_mismatch', message: '服务器证书指纹已变化，请核对后重试。',
    )), contains('核对'));
  });
  test('unknown status is still a recovery instruction', () {
    expect(userFacingError(const LightIsleApiException(
      code: 'unknown_operation', message: 'unknown_operation', statusCode: 401,
    )), contains('重新登录'));
    expect(userFacingError(StateError('unknown_internal')), contains('排查标识'));
  });
}
