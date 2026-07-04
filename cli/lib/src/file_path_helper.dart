/// 文件名/路径字符串工具，移植自 app/lib/util/file_path_helper.dart。
/// 仅保留 CLI 需要的部分（withCount / extension / withExtension），去掉 FileType 相关。

/// Matches myFile (123) -> "myFile", " (123)"
final _fileNumberRegex = RegExp(r'^(.*)(?:(\s\(\d+\)))$');

extension FilePathStringExt on String {
  String get extension {
    final index = lastIndexOf('.');
    if (index != -1) {
      return substring(index + 1).toLowerCase();
    } else {
      return '';
    }
  }

  String withExtension(String ext) {
    if (ext == '') {
      return this;
    } else {
      return '$this.$ext';
    }
  }

  /// 取路径最后一段（文件名）。复刻 app 端，统一处理反斜杠。
  /// 定义为方法（非 getter）以匹配 receiver.dart 的调用方式。
  String fileName() {
    return replaceAll('\\', '/').split('/').last;
  }

  /// 取父目录路径（去掉最后一段）。a/b/c.txt -> a/b；c.txt -> ''。
  String parentPath() {
    final parts = replaceAll('\\', '/').split('/');
    return parts.take(parts.length - 1).join('/');
  }

  /// 在文件名后插入序号：foo.txt -> foo (1).txt；已有 (n) 后缀的会递增 n。
  /// 复刻 app/lib/util/file_path_helper.dart 的同名方法，保证 CLI 与 app 行为一致。
  String withCount(int count) {
    final index = lastIndexOf('.');
    final String fileName;
    final String extension;
    if (index != -1) {
      fileName = substring(0, index);
      extension = substring(index + 1).toLowerCase();
    } else {
      fileName = this;
      extension = '';
    }

    final match = _fileNumberRegex.firstMatch(fileName);
    if (match != null) {
      return '${match.group(1)} ($count)'.withExtension(extension);
    } else {
      return '$fileName ($count)'.withExtension(extension);
    }
  }
}
