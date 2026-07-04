import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli/src/config.dart';
import 'package:cli/src/file_path_helper.dart';
import 'package:cli/src/peer.dart';
import 'package:common/api_route_builder.dart';
import 'package:common/constants.dart';
import 'package:common/model/device.dart';
import 'package:common/model/dto/info_dto.dart';
import 'package:common/model/dto/multicast_dto.dart';
import 'package:common/model/dto/prepare_upload_request_dto.dart';
import 'package:common/model/dto/prepare_upload_response_dto.dart';
import 'package:common/model/dto/register_dto.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// HttpRequest 缺失的便捷访问,复刻 app 的 simple_server.dart extension。
extension _HttpRequestExt on HttpRequest {
  String get ip => connectionInfo!.remoteAddress.address;
  Future<String> readAsString() => utf8.decoder.bind(this).join();
}

/// 单次接收会话的状态：prepare-upload 阶段签发的 token 映射。
class _Session {
  final String sessionId;
  final String senderIp;
  final Map<String, _IncomingFile> files; // fileId -> {token, fileName, size}

  _Session({
    required this.sessionId,
    required this.senderIp,
    required this.files,
  });
}

class _IncomingFile {
  final String token;
  final String fileName;
  final int size;
  _IncomingFile(
      {required this.token, required this.fileName, required this.size});
}

/// LocalSend v2 接收服务器：HTTPS + 多播回应 + QuickSave 自动落盘。
///
/// 复刻 app/lib/provider/network/server/controller/receive_controller.dart 的 v2 路由，
/// 去掉 UI/会话交互，prepare-upload 直接全量接受（QuickSave 语义）。
class ReceiverServer {
  final NodeConfig config;
  final void Function(DiscoveredPeer peer)? onPeerSeen;
  final void Function(String line) onLog;

  HttpServer? _server;
  _Session? _session;
  final Map<String, DiscoveredPeer> _peers = {};

  ReceiverServer({
    required this.config,
    this.onPeerSeen,
    required this.onLog,
  });

  Future<void> start() async {
    final ctx = SecurityContext()
      ..usePrivateKeyBytes(utf8.encode(config.security.privateKey))
      ..useCertificateChainBytes(utf8.encode(config.security.certificate));

    _server = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      config.port,
      ctx,
    );

    _log('Receiver listening on https://0.0.0.0:${config.port}');
    _log('Fingerprint: ${config.security.certificateHash}');
    _log('Destination: ${config.destinationDir}');
    _log('Waiting for incoming files... (Ctrl+C to stop)');

    await for (final request in _server!) {
      try {
        await _handle(request);
      } catch (e, st) {
        _log('Request error: $e\n$st');
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;

    // v2 路由
    if (path == ApiRoute.info.v2 && method == 'GET') {
      return _respondInfo(request);
    }
    if (path == ApiRoute.register.v2 && method == 'POST') {
      return _handleRegister(request);
    }
    if (path == ApiRoute.prepareUpload.v2 && method == 'POST') {
      return _handlePrepareUpload(request);
    }
    if (path == ApiRoute.upload.v2 && method == 'POST') {
      return _handleUpload(request);
    }
    if (path == ApiRoute.cancel.v2 && method == 'POST') {
      return _respondJson(request, 200, message: 'cancelled');
    }
    if (path == ApiRoute.show.v2 && method == 'POST') {
      return _respondJson(request, 403, message: 'Invalid token');
    }

    // v1 兼容（部分老对端可能用 v1 路径探测）
    if (path == ApiRoute.info.v1 && method == 'GET') {
      return _respondInfo(request);
    }

    request.response.statusCode = 404;
    await request.response.close();
  }

  /// GET /info、POST /register 共用：返回本机 InfoDto。
  Future<void> _respondInfo(HttpRequest request) async {
    final senderFp = request.uri.queryParameters['fingerprint'];
    if (senderFp == config.security.certificateHash) {
      return _respondJson(request, 412, message: 'Self-discovered');
    }
    return _respondJson(request, 200, body: _infoDto().toJson());
  }

  Future<void> _handleRegister(HttpRequest request) async {
    final body = await request.readAsString();
    RegisterDto? dto;
    try {
      dto = RegisterDto.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } catch (_) {
      return _respondJson(request, 400, message: 'Request body malformed');
    }
    if (dto.fingerprint == config.security.certificateHash) {
      return _respondJson(request, 412, message: 'Self-discovered');
    }
    final peer = DiscoveredPeer(
      ip: request.ip,
      port: dto.port ?? config.port,
      https: dto.protocol == ProtocolType.https,
      alias: dto.alias,
      fingerprint: dto.fingerprint,
      deviceModel: dto.deviceModel,
      deviceType: dto.deviceType ?? DeviceType.desktop,
      source: PeerDiscoverySource.lan,
    );
    _peers[peer.fingerprint] = peer;
    onPeerSeen?.call(peer);
    return _respondJson(request, 200, body: _infoDto().toJson());
  }

  InfoDto _infoDto() => InfoDto(
        alias: config.alias,
        version: protocolVersion,
        deviceModel: 'Linux',
        deviceType: DeviceType.headless,
        fingerprint: config.security.certificateHash,
        download: false,
      );

  /// POST /prepare-upload：QuickSave 语义，全量接受，签发 token。
  Future<void> _handlePrepareUpload(HttpRequest request) async {
    if (_session != null) {
      return _respondJson(request, 409, message: 'Blocked by another session');
    }

    final body = await request.readAsString();
    final PrepareUploadRequestDto dto;
    try {
      dto = PrepareUploadRequestDto.fromJson(
          jsonDecode(body) as Map<String, dynamic>);
    } catch (e, st) {
      _log('prepare-upload parse failed: $e\n$st\nraw body: $body');
      return _respondJson(request, 400, message: 'Request body malformed');
    }
    if (dto.files.isEmpty) {
      _log('prepare-upload rejected: empty files\nraw body: $body');
      return _respondJson(request, 400,
          message: 'Request must contain at least one file');
    }

    final sessionId = _uuid.v4();
    final files = <String, _IncomingFile>{};
    for (final entry in dto.files.entries) {
      files[entry.key] = _IncomingFile(
        token: _uuid.v4(),
        fileName: entry.value.fileName,
        size: entry.value.size,
      );
    }
    _session =
        _Session(sessionId: sessionId, senderIp: request.ip, files: files);

    _log(
        'Incoming from ${dto.info.alias} (${request.ip}): ${files.length} file(s)');

    final response = PrepareUploadResponseDto(
      sessionId: sessionId,
      files: {for (final e in files.entries) e.key: e.value.token},
    );
    return _respondJson(request, 200, body: response.toJson());
  }

  /// POST /upload?sessionId=&fileId=&token=：流式落盘。
  Future<void> _handleUpload(HttpRequest request) async {
    final session = _session;
    if (session == null) {
      return _respondJson(request, 409, message: 'No session');
    }
    if (request.ip != session.senderIp) {
      return _respondJson(request, 403, message: 'Invalid IP address');
    }

    final fileId = request.uri.queryParameters['fileId'];
    final token = request.uri.queryParameters['token'];
    final sessionId = request.uri.queryParameters['sessionId'];
    if (fileId == null || token == null || sessionId == null) {
      return _respondJson(request, 400, message: 'Missing parameters');
    }
    if (sessionId != session.sessionId) {
      return _respondJson(request, 403, message: 'Invalid session id');
    }
    final incoming = session.files[fileId];
    if (incoming == null || incoming.token != token) {
      return _respondJson(request, 403, message: 'Invalid token');
    }

    // 落盘：destinationDir/fileName，含子目录自动创建。
    // 复刻 app/lib/util/native/file_saver.dart 的 digestFilePathAndPrepareDirectory：
    // 同名文件自动加序号（foo.txt → foo (1).txt），永不覆盖；并做路径穿越校验防 ../ 偷逃。
    final rawPath = incoming.fileName.replaceAll('\\', '/');
    final dir = rawPath.parentPath();
    final baseName = rawPath.fileName();
    final fullDir =
        dir.isEmpty ? config.destinationDir : '${config.destinationDir}/$dir';

    // 路径穿越校验：确保最终目录在 destinationDir 之内，防恶意 fileName 逃出接收目录。
    final normalizedDest =
        File('${config.destinationDir}/').resolveSymbolicLinksSync();
    final normalizedFullDir = await Directory(fullDir).resolveSymbolicLinks();
    if (!normalizedFullDir.startsWith(normalizedDest)) {
      _log('Rejected path traversal: $rawPath');
      session.files.remove(fileId);
      if (session.files.isEmpty) {
        _session = null;
      }
      return _respondJson(request, 403, message: 'Invalid file path');
    }

    await Directory(fullDir).create(recursive: true);

    // 找一个不存在的文件名：原名 → foo (1).txt → foo (2).txt → ...
    String destinationName = baseName;
    int counter = 1;
    String destinationPath = '$fullDir/$destinationName';
    while (await File(destinationPath).exists()) {
      counter++;
      destinationName = baseName.withCount(counter);
      destinationPath = '$fullDir/$destinationName';
    }
    final outFile = File(destinationPath);

    final sink = outFile.openWrite();
    int written = 0;
    try {
      await for (final chunk in request) {
        sink.add(chunk);
        written += chunk.length;
      }
      await sink.flush();
    } catch (e) {
      await sink.close();
      _session = null;
      return _respondJson(request, 500, message: 'Save failed: $e');
    }
    await sink.close();

    _log('Saved: ${outFile.path} (${_fmtSize(written)})');

    // 单文件完成后：若全部完成则清会话。
    session.files.remove(fileId);
    if (session.files.isEmpty) {
      _session = null;
      _log('Transfer complete.');
    }
    return _respondJson(request, 200);
  }

  Future<void> _respondJson(HttpRequest request, int code,
      {String? message, Map<String, dynamic>? body}) async {
    request.response
      ..statusCode = code
      ..headers.contentType = ContentType.json
      ..write(
          jsonEncode(message != null ? {'message': message} : (body ?? {})));
    await request.response.close();
  }

  void _log(String line) => onLog(line);

  Future<void> stop() async {
    await _server?.close(force: true);
  }
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
