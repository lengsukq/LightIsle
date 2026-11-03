/// Value objects and safe errors shared by the API transport and clients.
/// Kept independent of HttpClient and native video relay lifecycles.
/// A structured API failure with a stable machine-readable [code].
///
/// The message is safe to show to a user. Response bodies, request URLs, and
/// session cookies are deliberately never included in [toString].
final class LightIsleApiException implements Exception {
  const LightIsleApiException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// An authenticated, generation-bound shared root. A null selection means
/// the original single-root API, including servers without root discovery.
final class LightIsleRoot {
  const LightIsleRoot({
    required this.id,
    required this.name,
    required this.generation,
    required this.online,
    this.volumeMount,
  });
  final String id;
  final String name;
  final int generation;
  final bool online;

  /// Admin-only diagnostic association to a physical macOS volume.
  /// File operations always remain relative to this registered NAS root.
  final String? volumeMount;

  factory LightIsleRoot.fromJson(Map<String, dynamic> json) {
    final id = json['rootID'];
    final generation = json['generation'];
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id) ||
        generation is! num ||
        generation.toInt() <= 0 ||
        generation.toInt() != generation) {
      throw const FormatException('无效的共享根标识或代际。');
    }
    return LightIsleRoot(
      id: id,
      name: json['name']?.toString() ?? id,
      generation: generation.toInt(),
      online: json['online'] == true,
      volumeMount: json['volumeMount'] is String
          ? json['volumeMount'] as String
          : null,
    );
  }

  String get identity => '$id:$generation';
}

class SavedSessionExpired implements Exception {
  const SavedSessionExpired();
  @override
  String toString() => '保存的登录已过期，请重新登录。';
}
