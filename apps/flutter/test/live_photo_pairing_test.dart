import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/media/media_models.dart';

PhotoAsset image(int id, String path, {int takenAt = 1234}) =>
    PhotoAsset.fromJson({
      'id': id,
      'path': path,
      'name': path.split('/').last,
      'type': 'photo',
      'takenAt': takenAt,
    });
PhotoAsset movie(int id, String path, {int takenAt = 1234}) =>
    PhotoAsset.fromJson({
      'id': id,
      'path': path,
      'name': path.split('/').last,
      'type': 'video',
      'takenAt': takenAt,
    });

void main() {
  test(
    'only same-directory, unique, same-stem MOV pairs to Live Photo still',
    () {
      final still = image(1, 'iPhone2026/IMG_2031.HEIC');
      final linked = movie(2, 'iPhone2026/IMG_2031.MOV', takenAt: 1235);
      final unrelated = movie(3, 'other/IMG_2031.MOV');
      expect(livePhotoMotionFor(still, [still, linked, unrelated])?.id, 2);
      expect(livePhotoMotionFor(still, [still, unrelated]), isNull);
      expect(
        livePhotoMotionFor(still, [
          still,
          linked,
          movie(4, 'iPhone2026/IMG_2031.mov'),
        ]),
        isNull,
        reason: 'ambiguous duplicate should not claim a Live Photo pair',
      );
      expect(
        livePhotoMotionFor(still, [
          still,
          movie(5, 'iPhone2026/IMG_2031.MOV', takenAt: 1290),
        ]),
        isNull,
      );
    },
  );

  test(
    'RAW original type recognized without pretending Flutter can decode',
    () {
      expect(image(6, 'camera/shot.CR3').isRaw, isTrue);
      expect(image(7, 'camera/photo.dng').isRaw, isTrue);
      expect(image(8, 'camera/photo.heic').isRaw, isFalse);
    },
  );
}
