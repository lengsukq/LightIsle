import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/user_facing_error.dart';

void main() {
  test('volume offline includes a safe reconnection step', () {
    final message = userFacingError(
      const LightIsleApiException(
        code: 'volume_offline',
        message: 'volume_offline',
        statusCode: 503,
      ),
    );
    expect(message, contains('重新连接原卷'));
    expect(message, isNot('volume_offline'));
  });

  test('cross origin and missing application header are security failures, not disk ACLs', () {
    expect(
      userFacingError(
        const LightIsleApiException(
          code: 'request_header_required',
          statusCode: 403,
          message: '服务器拒绝此操作',
        ),
      ),
      contains('安全标识'),
    );
    expect(
      userFacingError(
        const LightIsleApiException(
          code: 'cross_origin_request_rejected',
          statusCode: 403,
          message: '服务器拒绝此操作',
        ),
      ),
      contains('来源'),
    );
  });

  test('unconfigured default root explains the exact setup action', () {
    const failure = LightIsleApiException(
      code: 'default_root_not_configured',
      statusCode: 503,
      message: '服务器暂时无法完成请求，请稍后重试。',
    );
    expect(userFacingError(failure), contains('尚未设置默认 NAS 存储目录'));
    expect(userFacingError(failure), contains('数据与存储'));
    expect(
      errorDiagnosticLabel(failure),
      'HTTP 503 · default_root_not_configured',
    );
  });

  test('unknown 503 is not misdiagnosed as a hard disk failure', () {
    const failure = LightIsleApiException(
      code: 'unrecognized_service_error',
      statusCode: 503,
      message: '服务器暂时无法完成请求，请稍后重试。',
    );
    expect(userFacingError(failure), contains('未提供可识别的故障原因'));
    expect(
      errorDiagnosticLabel(failure),
      contains('unrecognized_service_error'),
    );
    expect(userFacingError(failure), isNot(contains('硬盘暂时不可用')));
  });

  test(
    'diagnostics cannot echo private HTTP responses or arbitrary strings',
    () {
      const malformed = LightIsleApiException(
        code: 'secret-token=unsafe thing',
        statusCode: 503,
        message: 'internal response and credentials',
      );
      expect(errorDiagnosticLabel(malformed), 'HTTP 503 · unknown');
      expect(errorDiagnosticLabel(StateError('api_key=test')), isNull);
    },
  );
  test('TLS errors keep the helpful safe API-client message', () {
    expect(
      userFacingError(
        const LightIsleApiException(
          code: 'certificate_mismatch',
          message: '服务器证书指纹已变化，请核对后重试。',
        ),
      ),
      contains('核对'),
    );
  });
  test('unknown status is still a recovery instruction', () {
    expect(
      userFacingError(
        const LightIsleApiException(
          code: 'unknown_operation',
          message: 'unknown_operation',
          statusCode: 401,
        ),
      ),
      contains('重新登录'),
    );
    expect(userFacingError(StateError('unknown_internal')), contains('排查标识'));
  });

  test('light-app lifecycle and public file share error codes map to clear guidance', () {
    expect(
      userFacingError(
        const LightIsleApiException(
          code: 'app_changed',
          statusCode: 409,
          message: 'app_changed',
        ),
      ),
      contains('本地应用配置已更新'),
    );
    expect(
      userFacingError(
        const LightIsleApiException(
          code: 'app_pending_activation',
          statusCode: 403,
          message: 'app_pending_activation',
        ),
      ),
      contains('尚未完成首次激活'),
    );
    expect(
      userFacingError(
        const LightIsleApiException(
          code: 'app_disabled',
          statusCode: 403,
          message: 'app_disabled',
        ),
      ),
      contains('停用'),
    );
    expect(
      userFacingError(
        const LightIsleApiException(
          code: 'app_running',
          statusCode: 409,
          message: 'app_running',
        ),
      ),
      contains('正在运行'),
    );
    expect(
      userFacingError(
        const LightIsleApiException(
          code: 'file_too_large_to_share',
          statusCode: 413,
          message: 'file_too_large_to_share',
        ),
      ),
      equals('单次公开分享仅支持不超过 32 GiB 的文件。'),
    );
    expect(
      userFacingError(
        const LightIsleApiException(
          code: 'dav_remount_required',
          statusCode: 409,
          message: 'dav_remount_required',
        ),
      ),
      contains('重新连接'),
    );
    expect(
      userFacingError(
        const LightIsleApiException(
          code: 'dav_cross_owner_move',
          statusCode: 403,
          message: 'dav_cross_owner_move',
        ),
      ),
      contains('不支持跨账号或跨公共与私人目录直接移动'),
    );
  });

  test('new backend app, automation, strm, person share, tmdb & transcode codes map cleanly', () {
    const codes = [
      'app_access_forbidden',
      'app_invalid',
      'app_unavailable',
      'app_already_exists',
      'app_template_not_found',
      'app_busy',
      'app_operation_failed',
      'automation_task_not_found',
      'automation_operation_failed',
      'invalid_strm_url',
      'forbidden_strm_url',
      'person_share_requires_owned_photos',
      'invalid_person_share',
      'admin_confirmation_required',
      'admin_confirmation_invalid',
      'tmdb_token_not_configured',
      'douban_web_unavailable',
      'transcode_insufficient_space',
      'transcode_busy',
      'transcode_failed',
    ];
    for (final code in codes) {
      expect(
        knownLightIsleErrorMessage(code),
        isNotNull,
        reason: 'Missing mapping for $code',
      );
      final text = userFacingError(
        LightIsleApiException(code: code, statusCode: 400, message: code),
      );
      expect(text, isNot(contains(code)));
      expect(text, isNot(contains('排查标识')));
    }
  });
}
