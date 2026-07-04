import 'dart:convert';
import 'dart:io';

import 'package:cli/src/security.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// 节点配置：身份别名 + 端口 + 是否 HTTPS + 接收目录 + 安全上下文。
///
/// 持久化到 ~/.localsend/node.json，使设备指纹（certificateHash）跨进程稳定，
/// 这样 Mac 端官方 app 才能把 Linux CLI 记成同一个设备。
class NodeConfig {
  final String alias;
  final int port;
  final bool https;
  final String destinationDir;
  final SecurityContextData security;

  const NodeConfig({
    required this.alias,
    required this.port,
    required this.https,
    required this.destinationDir,
    required this.security,
  });

  static String get home =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
  static String get configDirPath => '$home/.localsend';
  static String get configFilePath => '$configDirPath/node.json';
  static String get defaultDestinationDir => '$home/Downloads';

  Map<String, dynamic> toJson() => {
        'alias': alias,
        'port': port,
        'https': https,
        'destinationDir': destinationDir,
        'security': security.toJson(),
      };

  factory NodeConfig.fromJson(Map<String, dynamic> json) => NodeConfig(
        alias: json['alias'] as String,
        port: json['port'] as int,
        https: json['https'] as bool,
        destinationDir: json['destinationDir'] as String,
        security: SecurityContextData.fromJson(
            json['security'] as Map<String, dynamic>),
      );
}

/// 加载或创建节点配置。已有 node.json 则复用其安全上下文与别名；
/// 任意 override 非空则覆盖对应字段，并回写磁盘。
Future<NodeConfig> loadOrCreateConfig({
  String? alias,
  int? port,
  bool? https,
  String? destinationDir,
}) async {
  final file = File(NodeConfig.configFilePath);

  NodeConfig? existing;
  if (await file.exists()) {
    try {
      existing = NodeConfig.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      existing = null;
    }
  }

  final security = existing?.security ?? generateSecurityContext();
  final cfg = NodeConfig(
    alias: (alias != null && alias.trim().isNotEmpty)
        ? alias.trim()
        : (existing?.alias ?? _randomAlias()),
    port: port ?? existing?.port ?? 53317,
    https: https ?? existing?.https ?? true,
    destinationDir: (destinationDir != null && destinationDir.trim().isNotEmpty)
        ? destinationDir.trim()
        : (existing?.destinationDir ?? NodeConfig.defaultDestinationDir),
    security: security,
  );

  await Directory(NodeConfig.configDirPath).create(recursive: true);
  await file.writeAsString(jsonEncode(cfg.toJson()));
  return cfg;
}

String _randomAlias() => 'linux-${_uuid.v4().substring(0, 6)}';
