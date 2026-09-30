import 'dart:ui';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:localsend_app/util/image_crop_math.dart';

part 'crop_state.mapper.dart';

/// How an image has been cropped.
///
/// The rect is normalized (0..1) and refers to the upright source image
/// (EXIF orientation already applied), before the user rotation. Keeping it
/// independent of the rotation and the screen means the crop can be reopened
/// and adjusted later.
@MappableClass()
class CropState with CropStateMappable {
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// Clockwise rotation in 90° steps, 0..3.
  final int quarterTurns;

  const CropState({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.quarterTurns,
  });

  static const identity = CropState(left: 0, top: 0, right: 1, bottom: 1, quarterTurns: 0);

  factory CropState.fromRect(Rect sourceRect, int quarterTurns) {
    return CropState(
      left: sourceRect.left,
      top: sourceRect.top,
      right: sourceRect.right,
      bottom: sourceRect.bottom,
      quarterTurns: quarterTurns % 4,
    );
  }

  Rect get sourceRect => Rect.fromLTRB(left, top, right, bottom);

  bool get isIdentity => isIdentityCrop(sourceRect, quarterTurns);
}
