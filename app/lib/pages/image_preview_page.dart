import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/crop_selected_file.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Shows the selected images full screen. Swipe to switch, pinch to zoom,
/// and crop again from the original image.
class ImagePreviewPage extends StatefulWidget {
  /// The image to show first.
  final CrossFile initialFile;

  const ImagePreviewPage({required this.initialFile, super.key});

  @override
  State<ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends State<ImagePreviewPage> with Refena {
  late final PageController _controller;
  int _page = 0;

  static bool _isPreviewable(CrossFile file) {
    return file.fileType == FileType.image && file.path != null && !file.path!.startsWith('content://');
  }

  @override
  void initState() {
    super.initState();
    final images = ref.read(selectedSendingFilesProvider).where(_isPreviewable).toList();
    _page = images.indexWhere((e) => identical(e, widget.initialFile)).clamp(0, images.isEmpty ? 0 : images.length - 1);
    _controller = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final images = context.ref.watch(selectedSendingFilesProvider).where(_isPreviewable).toList();
    final current = images.isEmpty ? null : images[_page.clamp(0, images.length - 1)];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(images.isEmpty ? '' : '${_page + 1} / ${images.length}'),
        actions: [
          if (current != null && canCropFile(current))
            IconButton(
              icon: const Icon(Icons.crop),
              tooltip: t.selectedFilesPage.crop,
              onPressed: () async => await cropSelectedFile(context, context.ref, current),
            ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: images.length,
        onPageChanged: (page) => setState(() => _page = page),
        itemBuilder: (context, index) {
          final file = images[index];
          return InteractiveViewer(
            maxScale: 8,
            child: Center(
              child: Image.file(
                File(file.path!),
                // A new path after cropping must not show the cached old image.
                key: ValueKey(file.path),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(Icons.broken_image, color: Colors.white54, size: 64),
              ),
            ),
          );
        },
      ),
    );
  }
}
