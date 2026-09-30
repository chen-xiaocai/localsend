import 'dart:typed_data';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:localsend_app/model/crop_state.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

part 'cross_file.mapper.dart';

/// Common file model to avoid any third party libraries in the core logic.
/// This model is used during the file selection phase.
@MappableClass()
class CrossFile with CrossFileMappable {
  final String name;
  final FileType fileType;
  final int size;
  final Uint8List? thumbnail;
  final AssetEntity? asset; // for thumbnails
  final String? path;
  final List<int>? bytes; // if type message, then UTF-8 encoded
  final String? lastModified; // RFC 3339; a string because DateTime would truncate to microseconds
  final String? lastAccessed; // RFC 3339

  /// The unmodified image this file was cropped from, kept so the crop can be
  /// adjusted again. Null if the file has not been cropped.
  final String? originalPath;

  /// The crop applied to [originalPath] to produce [path].
  final CropState? cropState;

  const CrossFile({
    required this.name,
    required this.fileType,
    required this.size,
    required this.thumbnail,
    required this.asset,
    required this.path,
    required this.bytes,
    required this.lastModified,
    required this.lastAccessed,
    this.originalPath,
    this.cropState,
  });

  /// Custom toString() to avoid printing the bytes.
  @override
  String toString() {
    return 'CrossFile(name: $name, fileType: $fileType, size: $size, thumbnail: ${thumbnail != null ? thumbnail!.length : 'null'}, asset: $asset, path: $path, bytes: ${bytes != null ? bytes!.length : 'null'}, originalPath: $originalPath, cropState: $cropState)';
  }
}
