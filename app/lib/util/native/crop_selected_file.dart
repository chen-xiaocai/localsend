import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/pages/image_crop_page.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// The image a crop starts from: the untouched original if the file was cropped before.
String? cropSourceOf(CrossFile file) => file.originalPath ?? file.path;

/// Whether [file] can be opened in [ImageCropPage].
bool canCropFile(CrossFile file) {
  final source = cropSourceOf(file);
  return checkPlatform([TargetPlatform.android]) && file.fileType == FileType.image && source != null && !source.startsWith('content://');
}

/// Opens [file] (an entry of the sending selection) in the crop page, starting from
/// its original image and its previous crop, and replaces the entry with the result.
Future<void> cropSelectedFile(BuildContext context, Ref ref, CrossFile file) async {
  final source = cropSourceOf(file);
  if (source == null || !canCropFile(file)) {
    return;
  }

  final result = await context.push<ImageCropResult, ImageCropPage>(
    () => ImageCropPage(sourcePath: source, initialState: file.cropState),
  );
  if (result is! ImageCropDone) {
    return;
  }

  final converted = await CrossFileConverters.convertXFile(XFile(result.path));
  final cropped = result.path != source;
  final updated = converted.copyWith(
    // The cropped file is always a JPEG.
    name: cropped ? '${p.basenameWithoutExtension(file.name)}.jpg' : file.name,
    thumbnail: null,
    asset: result.path == file.path ? file.asset : null,
    lastModified: file.lastModified,
    lastAccessed: file.lastAccessed,
    originalPath: source,
    cropState: result.state,
  );

  // The selection may have changed while the crop page was open.
  final index = ref.read(selectedSendingFilesProvider).indexWhere((e) => identical(e, file));
  if (index == -1) {
    return;
  }
  ref.redux(selectedSendingFilesProvider).dispatch(ReplaceSelectedFileAction(index: index, file: updated));
}
