import 'dart:math' as math;
import 'dart:ui';

/// The full image as a normalized rect.
const fullCropRect = Rect.fromLTRB(0, 0, 1, 1);

/// Rotates a rect in normalized image coordinates (0..1) by 90° clockwise
/// together with the image it belongs to.
///
/// A point (x, y) of the image ends up at (1 - y, x) after the rotation.
Rect rotateNormalizedRectCw(Rect r) {
  return Rect.fromLTRB(1 - r.bottom, r.left, 1 - r.top, r.right);
}

/// Converts a rect in the coordinates of the upright source image into the
/// coordinates of the image rotated by [quarterTurns] × 90° clockwise.
Rect sourceToDisplayRect(Rect source, int quarterTurns) {
  var r = source;
  for (var i = 0; i < quarterTurns % 4; i++) {
    r = rotateNormalizedRectCw(r);
  }
  return r;
}

/// Inverse of [sourceToDisplayRect].
Rect displayToSourceRect(Rect display, int quarterTurns) {
  return sourceToDisplayRect(display, (4 - quarterTurns % 4) % 4);
}

/// Size of the image after rotating it by [quarterTurns] × 90°.
Size rotatedSize(Size size, int quarterTurns) {
  return quarterTurns.isOdd ? Size(size.height, size.width) : size;
}

/// Which part of the crop rect is being dragged.
enum CropHandle {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,
  move,
}

/// Returns the handle at [point] (screen coordinates) for the crop rect
/// [rect] (screen coordinates), or null if nothing is hit.
/// Corners win over edges, edges win over the inside.
CropHandle? hitTestCropHandle(Rect rect, Offset point, {double tolerance = 28}) {
  bool near(double a, double b) => (a - b).abs() <= tolerance;
  final withinX = point.dx >= rect.left - tolerance && point.dx <= rect.right + tolerance;
  final withinY = point.dy >= rect.top - tolerance && point.dy <= rect.bottom + tolerance;
  if (!withinX || !withinY) {
    return null;
  }

  final nearLeft = near(point.dx, rect.left);
  final nearRight = near(point.dx, rect.right);
  final nearTop = near(point.dy, rect.top);
  final nearBottom = near(point.dy, rect.bottom);

  if (nearTop && nearLeft) return CropHandle.topLeft;
  if (nearTop && nearRight) return CropHandle.topRight;
  if (nearBottom && nearLeft) return CropHandle.bottomLeft;
  if (nearBottom && nearRight) return CropHandle.bottomRight;
  if (nearTop) return CropHandle.top;
  if (nearBottom) return CropHandle.bottom;
  if (nearLeft) return CropHandle.left;
  if (nearRight) return CropHandle.right;
  if (rect.contains(point)) return CropHandle.move;
  return null;
}

/// Applies a drag of [delta] (normalized units) on [handle] to [rect].
///
/// The result always stays within 0..1 and keeps at least [minWidth] ×
/// [minHeight]. The rect is never re-centered: what the user drags is what
/// they get.
Rect dragCropRect(
  Rect rect,
  CropHandle handle,
  Offset delta, {
  required double minWidth,
  required double minHeight,
}) {
  if (handle == CropHandle.move) {
    final dx = delta.dx.clamp(-rect.left, 1 - rect.right).toDouble();
    final dy = delta.dy.clamp(-rect.top, 1 - rect.bottom).toDouble();
    return rect.shift(Offset(dx, dy));
  }

  var left = rect.left;
  var top = rect.top;
  var right = rect.right;
  var bottom = rect.bottom;

  final movesLeft = handle == CropHandle.topLeft || handle == CropHandle.left || handle == CropHandle.bottomLeft;
  final movesRight = handle == CropHandle.topRight || handle == CropHandle.right || handle == CropHandle.bottomRight;
  final movesTop = handle == CropHandle.topLeft || handle == CropHandle.top || handle == CropHandle.topRight;
  final movesBottom = handle == CropHandle.bottomLeft || handle == CropHandle.bottom || handle == CropHandle.bottomRight;

  if (movesLeft) {
    left = (left + delta.dx).clamp(0.0, math.max(0.0, right - minWidth)).toDouble();
  }
  if (movesRight) {
    right = (right + delta.dx).clamp(math.min(1.0, left + minWidth), 1.0).toDouble();
  }
  if (movesTop) {
    top = (top + delta.dy).clamp(0.0, math.max(0.0, bottom - minHeight)).toDouble();
  }
  if (movesBottom) {
    bottom = (bottom + delta.dy).clamp(math.min(1.0, top + minHeight), 1.0).toDouble();
  }

  return Rect.fromLTRB(left, top, right, bottom);
}

/// Whether the crop is a no-op, i.e. the source image can be used as is.
bool isIdentityCrop(Rect sourceRect, int quarterTurns) {
  const epsilon = 0.0005;
  return quarterTurns % 4 == 0 &&
      sourceRect.left <= epsilon &&
      sourceRect.top <= epsilon &&
      sourceRect.right >= 1 - epsilon &&
      sourceRect.bottom >= 1 - epsilon;
}
