import 'dart:ui';

import 'package:localsend_app/util/image_crop_math.dart';
import 'package:test/test.dart';

void main() {
  group('rotateNormalizedRectCw', () {
    test('rotates the top-left quadrant to the top-right quadrant', () {
      const r = Rect.fromLTRB(0, 0, 0.5, 0.5);
      expect(rotateNormalizedRectCw(r), const Rect.fromLTRB(0.5, 0, 1, 0.5));
    });

    test('swaps width and height of a wide rect', () {
      const r = Rect.fromLTRB(0.1, 0.4, 0.9, 0.6);
      final rotated = rotateNormalizedRectCw(r);
      expect(rotated.width, closeTo(r.height, 1e-9));
      expect(rotated.height, closeTo(r.width, 1e-9));
    });

    test('four rotations are the identity', () {
      const r = Rect.fromLTRB(0.12, 0.34, 0.56, 0.78);
      final back = rotateNormalizedRectCw(rotateNormalizedRectCw(rotateNormalizedRectCw(rotateNormalizedRectCw(r))));
      expect(back.left, closeTo(r.left, 1e-9));
      expect(back.top, closeTo(r.top, 1e-9));
      expect(back.right, closeTo(r.right, 1e-9));
      expect(back.bottom, closeTo(r.bottom, 1e-9));
    });
  });

  test('displayToSourceRect is the inverse of sourceToDisplayRect', () {
    const source = Rect.fromLTRB(0.05, 0.2, 0.4, 0.95);
    for (var q = 0; q < 4; q++) {
      final back = displayToSourceRect(sourceToDisplayRect(source, q), q);
      expect(back.left, closeTo(source.left, 1e-9), reason: 'q=$q');
      expect(back.top, closeTo(source.top, 1e-9), reason: 'q=$q');
      expect(back.right, closeTo(source.right, 1e-9), reason: 'q=$q');
      expect(back.bottom, closeTo(source.bottom, 1e-9), reason: 'q=$q');
    }
  });

  test('rotatedSize swaps dimensions on odd turns', () {
    expect(rotatedSize(const Size(4000, 3000), 1), const Size(3000, 4000));
    expect(rotatedSize(const Size(4000, 3000), 2), const Size(4000, 3000));
  });

  group('dragCropRect', () {
    test('dragging a corner to the image corner reaches it exactly', () {
      final r = dragCropRect(
        const Rect.fromLTRB(0.3, 0.3, 0.7, 0.7),
        CropHandle.topLeft,
        const Offset(-5, -5),
        minWidth: 0.05,
        minHeight: 0.05,
      );
      expect(r, const Rect.fromLTRB(0, 0, 0.7, 0.7));
    });

    test('an edge cannot cross the opposite edge', () {
      final r = dragCropRect(
        const Rect.fromLTRB(0.3, 0.3, 0.7, 0.7),
        CropHandle.left,
        const Offset(0.9, 0),
        minWidth: 0.1,
        minHeight: 0.1,
      );
      expect(r.left, closeTo(0.6, 1e-9));
      expect(r.right, 0.7);
    });

    test('moving keeps the size and stays inside the image', () {
      final r = dragCropRect(
        const Rect.fromLTRB(0.6, 0.6, 0.9, 0.9),
        CropHandle.move,
        const Offset(0.5, 0.5),
        minWidth: 0.05,
        minHeight: 0.05,
      );
      expect(r.right, closeTo(1, 1e-9));
      expect(r.bottom, closeTo(1, 1e-9));
      expect(r.width, closeTo(0.3, 1e-9));
    });
  });

  test('hitTestCropHandle prefers corners, then edges, then the inside', () {
    const rect = Rect.fromLTRB(100, 100, 300, 300);
    expect(hitTestCropHandle(rect, const Offset(102, 98)), CropHandle.topLeft);
    expect(hitTestCropHandle(rect, const Offset(200, 101)), CropHandle.top);
    expect(hitTestCropHandle(rect, const Offset(200, 200)), CropHandle.move);
    expect(hitTestCropHandle(rect, const Offset(10, 10)), isNull);
  });

  test('isIdentityCrop', () {
    expect(isIdentityCrop(fullCropRect, 0), isTrue);
    expect(isIdentityCrop(fullCropRect, 1), isFalse);
    expect(isIdentityCrop(const Rect.fromLTRB(0, 0, 0.9, 1), 0), isFalse);
  });
}
