import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/crop_state.dart';
import 'package:localsend_app/util/image_crop_math.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:logging/logging.dart';

final _logger = Logger('ImageCropPage');

/// Result of [ImageCropPage]. `null` means the user discarded the image.
sealed class ImageCropResult {
  const ImageCropResult();
}

/// The user wants to take the photo again.
class ImageCropRetake extends ImageCropResult {
  const ImageCropRetake();
}

/// The user confirmed the crop.
class ImageCropDone extends ImageCropResult {
  /// The file to send: the cropped image, or the source itself if nothing was cropped.
  final String path;
  final CropState state;

  const ImageCropDone({required this.path, required this.state});
}

enum _GestureMode { none, handle, view }

/// Lets the user crop and rotate an image.
///
/// Unlike uCrop, the crop frame is moved over a fixed image: handles can be
/// dragged anywhere inside the image and stay where they are released. Two
/// fingers zoom and pan the view, so small details can be selected precisely.
class ImageCropPage extends StatefulWidget {
  final String sourcePath;
  final CropState? initialState;

  /// Shows the "retake" button (camera flow only).
  final bool allowRetake;

  const ImageCropPage({
    required this.sourcePath,
    this.initialState,
    this.allowRetake = false,
    super.key,
  });

  @override
  State<ImageCropPage> createState() => _ImageCropPageState();
}

class _ImageCropPageState extends State<ImageCropPage> {
  static const _padding = 28.0;
  static const _minCropPx = 48.0;
  static const _maxZoom = 8.0;

  late final ImageProvider _provider;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  Size? _imageSize; // upright source image, only the aspect ratio matters
  bool _loadFailed = false;

  late int _quarterTurns;
  late Rect _rect; // normalized, in the rotated (displayed) image
  double _zoom = 1;
  Offset _pan = Offset.zero;

  bool _cropping = false;

  // gesture state
  _GestureMode _mode = _GestureMode.none;
  CropHandle? _handle;
  int _pointerCount = 0;
  double _zoomAtStart = 1;
  Offset _panAtStart = Offset.zero;
  Offset _focalAtStart = Offset.zero;
  double _scaleBase = 1;
  Size _viewport = Size.zero;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialState ?? CropState.identity;
    _quarterTurns = initial.quarterTurns % 4;
    _rect = sourceToDisplayRect(initial.sourceRect, _quarterTurns);

    // Downscaled for display; the crop itself works on the original file.
    _provider = ResizeImage(
      FileImage(File(widget.sourcePath)),
      width: 2560,
      height: 2560,
      policy: ResizeImagePolicy.fit,
    );
    _imageStream = _provider.resolve(ImageConfiguration.empty);
    _imageListener = ImageStreamListener(
      (info, _) {
        if (mounted) {
          setState(() => _imageSize = Size(info.image.width.toDouble(), info.image.height.toDouble()));
        }
      },
      onError: (e, st) {
        _logger.warning('Failed to load ${widget.sourcePath}', e, st);
        if (mounted) {
          setState(() => _loadFailed = true);
        }
      },
    );
    _imageStream!.addListener(_imageListener!);
  }

  @override
  void dispose() {
    _imageStream?.removeListener(_imageListener!);
    super.dispose();
  }

  /// The displayed image in viewport coordinates.
  Rect _imageRect(Size viewport) {
    final displaySize = rotatedSize(_imageSize!, _quarterTurns);
    final contentWidth = math.max(1.0, viewport.width - 2 * _padding);
    final contentHeight = math.max(1.0, viewport.height - 2 * _padding);
    final baseScale = math.min(contentWidth / displaySize.width, contentHeight / displaySize.height);
    final size = displaySize * baseScale * _zoom;
    final center = viewport.center(Offset.zero) + _pan;
    return Rect.fromCenter(center: center, width: size.width, height: size.height);
  }

  Rect _cropRectOnScreen(Rect imageRect) {
    return Rect.fromLTRB(
      imageRect.left + _rect.left * imageRect.width,
      imageRect.top + _rect.top * imageRect.height,
      imageRect.left + _rect.right * imageRect.width,
      imageRect.top + _rect.bottom * imageRect.height,
    );
  }

  /// Keeps the zoomed image from drifting away: it can only be panned as far as it is larger than the content area.
  Offset _clampPan(Offset pan, double zoom) {
    final displaySize = rotatedSize(_imageSize!, _quarterTurns);
    final contentWidth = math.max(1.0, _viewport.width - 2 * _padding);
    final contentHeight = math.max(1.0, _viewport.height - 2 * _padding);
    final baseScale = math.min(contentWidth / displaySize.width, contentHeight / displaySize.height);
    final maxDx = math.max(0.0, (displaySize.width * baseScale * zoom - contentWidth) / 2);
    final maxDy = math.max(0.0, (displaySize.height * baseScale * zoom - contentHeight) / 2);
    return Offset(pan.dx.clamp(-maxDx, maxDx).toDouble(), pan.dy.clamp(-maxDy, maxDy).toDouble());
  }

  void _startViewGesture(Offset localFocal, double scale) {
    _mode = _GestureMode.view;
    _handle = null;
    _zoomAtStart = _zoom;
    _panAtStart = _pan;
    _focalAtStart = localFocal;
    _scaleBase = scale;
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (_imageSize == null || _cropping) {
      return;
    }
    _pointerCount = details.pointerCount;
    if (details.pointerCount >= 2) {
      _startViewGesture(details.localFocalPoint, 1);
      return;
    }

    final imageRect = _imageRect(_viewport);
    final handle = hitTestCropHandle(_cropRectOnScreen(imageRect), details.localFocalPoint);
    if (handle != null) {
      _mode = _GestureMode.handle;
      _handle = handle;
    } else {
      // One finger outside the frame pans the zoomed image.
      _startViewGesture(details.localFocalPoint, 1);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_imageSize == null || _mode == _GestureMode.none) {
      return;
    }

    if (details.pointerCount != _pointerCount) {
      // A finger was added or lifted: continue as a view gesture from here.
      _pointerCount = details.pointerCount;
      _startViewGesture(details.localFocalPoint, details.scale);
      return;
    }

    if (_mode == _GestureMode.handle) {
      final imageRect = _imageRect(_viewport);
      setState(() {
        _rect = dragCropRect(
          _rect,
          _handle!,
          Offset(details.focalPointDelta.dx / imageRect.width, details.focalPointDelta.dy / imageRect.height),
          minWidth: math.min(1.0, _minCropPx / imageRect.width),
          minHeight: math.min(1.0, _minCropPx / imageRect.height),
        );
      });
      return;
    }

    final scale = _scaleBase == 0 ? 1.0 : details.scale / _scaleBase;
    final newZoom = (_zoomAtStart * scale).clamp(1.0, _maxZoom).toDouble();
    final center = _viewport.center(Offset.zero);
    // The image point under the initial focal point stays under the fingers.
    final imagePoint = (_focalAtStart - center - _panAtStart) / _zoomAtStart;
    final newPan = details.localFocalPoint - center - imagePoint * newZoom;
    setState(() {
      _zoom = newZoom;
      _pan = _clampPan(newPan, newZoom);
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _mode = _GestureMode.none;
    _handle = null;
    _pointerCount = 0;
  }

  void _rotate() {
    setState(() {
      _rect = rotateNormalizedRectCw(_rect);
      _quarterTurns = (_quarterTurns + 1) % 4;
      _zoom = 1;
      _pan = Offset.zero;
    });
  }

  void _reset() {
    setState(() {
      _rect = fullCropRect;
      _quarterTurns = 0;
      _zoom = 1;
      _pan = Offset.zero;
    });
  }

  Future<void> _confirm() async {
    final state = CropState.fromRect(displayToSourceRect(_rect, _quarterTurns), _quarterTurns);
    if (state.isIdentity) {
      Navigator.of(context).pop(ImageCropDone(path: widget.sourcePath, state: state));
      return;
    }

    setState(() => _cropping = true);
    try {
      final output = await android_channel.cropImageAndroid(
        path: widget.sourcePath,
        left: state.left,
        top: state.top,
        right: state.right,
        bottom: state.bottom,
        quarterTurns: state.quarterTurns,
      );
      if (mounted) {
        Navigator.of(context).pop(ImageCropDone(path: output, state: state));
      }
    } catch (e, st) {
      _logger.warning('Failed to crop ${widget.sourcePath} with $state', e, st);
      if (mounted) {
        setState(() => _cropping = false);
        context.showSnackBar('${t.imageCropPage.failed}: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: t.general.cancel,
          onPressed: _cropping ? null : () => Navigator.of(context).pop(),
        ),
        title: Text(t.imageCropPage.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: t.general.confirm,
            onPressed: _imageSize == null || _cropping ? null : _confirm,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _viewport = constraints.biggest;
                  if (_loadFailed) {
                    return Center(
                      child: Text(t.imageCropPage.failed, style: const TextStyle(color: Colors.white)),
                    );
                  }
                  if (_imageSize == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final imageRect = _imageRect(_viewport);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    onScaleEnd: _onScaleEnd,
                    child: ClipRect(
                      child: Stack(
                        children: [
                          Positioned.fromRect(
                            rect: imageRect,
                            child: RotatedBox(
                              quarterTurns: _quarterTurns,
                              child: Image(image: _provider, fit: BoxFit.fill, gaplessPlayback: true),
                            ),
                          ),
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _CropOverlayPainter(cropRect: _cropRectOnScreen(imageRect)),
                            ),
                          ),
                          if (_cropping)
                            const Positioned.fill(
                              child: ColoredBox(
                                color: Colors.black54,
                                child: Center(child: CircularProgressIndicator()),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (widget.allowRetake)
                    _BottomButton(
                      icon: Icons.replay,
                      label: t.imageCropPage.retake,
                      onPressed: _cropping ? null : () => Navigator.of(context).pop(const ImageCropRetake()),
                    ),
                  _BottomButton(
                    icon: Icons.rotate_90_degrees_cw,
                    label: t.imageCropPage.rotate,
                    onPressed: _imageSize == null || _cropping ? null : _rotate,
                  ),
                  _BottomButton(
                    icon: Icons.restart_alt,
                    label: t.general.reset,
                    onPressed: _imageSize == null || _cropping ? null : _reset,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _BottomButton({required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      style: TextButton.styleFrom(foregroundColor: Colors.white, disabledForegroundColor: Colors.white38),
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

class _CropOverlayPainter extends CustomPainter {
  final Rect cropRect;

  _CropOverlayPainter({required this.cropRect});

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(cropRect);
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.55));

    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 0.8;
    for (var i = 1; i < 3; i++) {
      final x = cropRect.left + cropRect.width * i / 3;
      final y = cropRect.top + cropRect.height * i / 3;
      canvas.drawLine(Offset(x, cropRect.top), Offset(x, cropRect.bottom), gridPaint);
      canvas.drawLine(Offset(cropRect.left, y), Offset(cropRect.right, y), gridPaint);
    }

    canvas.drawRect(
      cropRect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final handlePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.square;
    final length = math.min(22.0, math.min(cropRect.width, cropRect.height) / 2);
    final corners = [
      (cropRect.topLeft, 1.0, 1.0),
      (cropRect.topRight, -1.0, 1.0),
      (cropRect.bottomLeft, 1.0, -1.0),
      (cropRect.bottomRight, -1.0, -1.0),
    ];
    for (final (corner, dx, dy) in corners) {
      canvas.drawLine(corner, corner + Offset(length * dx, 0), handlePaint);
      canvas.drawLine(corner, corner + Offset(0, length * dy), handlePaint);
    }
  }

  @override
  bool shouldRepaint(_CropOverlayPainter oldDelegate) => oldDelegate.cropRect != cropRect;
}
