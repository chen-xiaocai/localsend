import 'dart:io';

import 'package:common/model/file_type.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

/// Copies received content to the system clipboard using the best available representation:
/// - text: [Clipboard.setData]
/// - image files: [Pasteboard.writeImage]
/// - other files or large images: [Pasteboard.writeFiles]
///
/// Clipboard write failures are swallowed and reported as `false`.
///
/// Desktop Linux currently treats image writes as a no-op in pasteboard; this
/// feature is intended for macOS, Windows, and Android.
const _maxImageBytes = 20 * 1024 * 1024;

Future<bool> copyToClipboard({
  FileType? fileType,
  String? path,
  String? text,
}) async {
  try {
    if (fileType == FileType.text) {
      final content = text ?? await _readTextFile(path);
      if (content != null) {
        await Clipboard.setData(ClipboardData(text: content));
        return true;
      }
    } else if (text != null) {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    }

    if (fileType == FileType.image && path != null && _isLocalPath(path)) {
      final file = File(path);
      final size = await file.length();
      if (size <= _maxImageBytes) {
        final bytes = await file.readAsBytes();
        await Pasteboard.writeImage(bytes);
        return true;
      }
    }

    if (path != null && _isLocalPath(path)) {
      return await Pasteboard.writeFiles([path]);
    }

    return false;
  } catch (_) {
    return false;
  }
}

/// Reads small text files only. Invalid paths and read failures return null.
Future<String?> _readTextFile(String? path) async {
  if (path == null || !_isLocalPath(path)) return null;
  try {
    final file = File(path);
    final size = await file.length();
    if (size > _maxImageBytes) return null;
    return await file.readAsString();
  } catch (_) {
    return null;
  }
}

/// Copies multiple local file paths as files.
Future<bool> copyFilesToClipboard(List<String> paths) async {
  final localPaths = paths.where(_isLocalPath).toList();
  if (localPaths.isEmpty) return false;
  try {
    return await Pasteboard.writeFiles(localPaths);
  } catch (_) {
    return false;
  }
}

/// Filters out content URIs and remote URLs, which pasteboard cannot write as files.
bool _isLocalPath(String path) {
  return !path.startsWith('content://') && !path.startsWith('http://') && !path.startsWith('https://');
}
