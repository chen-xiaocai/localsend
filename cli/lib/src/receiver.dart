import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

const _uuid = Uuid();
final _secureRandom = math.Random.secure();

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

  /// 最近一次活动时间(prepare/收到数据块时刷新)。
  /// 发送端 prepare 后崩溃/断网且不发 cancel 时,会话会永远残留,
  /// 后续所有 prepare-upload 都 409,只能 restart —— 靠此字段判定过期回收。
  DateTime lastActivity = DateTime.now();

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
        // upload 中途抛错时必须清会话，否则会一直 409 Blocked by another session
        if (request.uri.path.contains('upload')) {
          _session = null;
        }
        try {
          await _respondJson(request, 500, message: 'Internal server error');
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
      return _handlePrepareUpload(request, v2: true);
    }
    if (path == ApiRoute.upload.v2 && method == 'POST') {
      return _handleUpload(request, v2: true);
    }
    if (path == ApiRoute.cancel.v2 && method == 'POST') {
      return _handleCancel(request);
    }
    if (path == ApiRoute.show.v2 && method == 'POST') {
      return _respondJson(request, 403, message: 'Invalid token');
    }

    // v3 兼容：新版 Rust 客户端可能先探测 v3，但实际传输结构仍可复用。
    if (path == '/api/localsend/v3/nonce' && method == 'POST') {
      return _handleNonce(request);
    }
    if (path == '/api/localsend/v3/register' && method == 'POST') {
      return _handleRegister(request);
    }
    if (path == '/api/localsend/v3/prepare-upload' && method == 'POST') {
      return _handlePrepareUpload(request, v2: true);
    }
    if (path == '/api/localsend/v3/upload' && method == 'POST') {
      return _handleUpload(request, v2: true);
    }
    if (path == '/api/localsend/v3/cancel' && method == 'POST') {
      return _handleCancel(request);
    }

    // v1 兼容（部分老对端可能用 v1 路径探测）
    if (path == ApiRoute.info.v1 && method == 'GET') {
      return _respondInfo(request);
    }
    if (path == ApiRoute.register.v1 && method == 'POST') {
      return _handleRegister(request);
    }
    if (path == ApiRoute.prepareUpload.v1 && method == 'POST') {
      return _handlePrepareUpload(request, v2: false);
    }
    if (path == ApiRoute.upload.v1 && method == 'POST') {
      return _handleUpload(request, v2: false);
    }
    if (path == ApiRoute.cancel.v1 && method == 'POST') {
      return _handleCancel(request);
    }
    if (path == ApiRoute.show.v1 && method == 'POST') {
      return _respondJson(request, 403, message: 'Invalid token');
    }

    return _respondJson(request, 404, message: 'Not found');
  }

  /// GET /info、POST /register 共用：返回本机 InfoDto。
  Future<void> _respondInfo(HttpRequest request) async {
    final senderFp = request.uri.queryParameters['fingerprint'];
    if (senderFp == config.security.certificateHash) {
      return _respondJson(request, 412, message: 'Self-discovered');
    }
    return _respondJson(request, 200, body: _infoJson());
  }

  Future<void> _handleNonce(HttpRequest request) async {
    final body = await request.readAsString();
    try {
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final nonce = payload['nonce'] as String?;
      final decodedNonce = nonce == null ? <int>[] : base64Decode(nonce);
      if (decodedNonce.length < 16 || decodedNonce.length > 128) {
        return _respondJson(request, 400, message: 'Invalid nonce');
      }
    } catch (e, st) {
      _log('nonce parse failed: $e\n$st\nraw body: $body');
      return _respondJson(request, 400, message: 'Invalid nonce format');
    }

    final nonce = List<int>.generate(32, (_) => _secureRandom.nextInt(256));
    return _respondJson(request, 200, body: {'nonce': base64Encode(nonce)});
  }

  Future<void> _handleRegister(HttpRequest request) async {
    final body = await request.readAsString();
    RegisterDto? dto;
    try {
      final payload = jsonDecode(body) as Map<String, dynamic>;
      dto = RegisterDto.fromJson(_normalizeRegisterJson(payload));
    } catch (e, st) {
      _log('register parse failed: $e\n$st\nraw body: $body');
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
    return _respondJson(request, 200, body: _infoJson());
  }

  Map<String, dynamic> _infoJson() {
    final info = InfoDto(
      alias: config.alias,
      version: protocolVersion,
      deviceModel: 'Linux',
      deviceType: DeviceType.headless,
      fingerprint: config.security.certificateHash,
      download: false,
    ).toJson();
    return {
      ...info,
      'deviceType': 'HEADLESS',
      'token': config.security.certificateHash,
      'hasWebInterface': false,
    };
  }

  /// POST /prepare-upload：QuickSave 语义，全量接受，签发 token。
  /// 会话超过此时长无任何数据活动即视为死会话,允许被新会话顶替。
  static const _sessionIdleTimeout = Duration(minutes: 2);

  Future<void> _handlePrepareUpload(HttpRequest request,
      {required bool v2}) async {
    final existing = _session;
    if (existing != null) {
      final idle = DateTime.now().difference(existing.lastActivity);
      if (idle < _sessionIdleTimeout) {
        return _respondJson(request, 409,
            message: 'Blocked by another session');
      }
      _log(
          'Evicting stale session ${existing.sessionId} from ${existing.senderIp}: idle ${idle.inSeconds}s, pending files=${existing.files.keys.toList()}');
      _session = null;
    }

    final body = await request.readAsString();
    final PrepareUploadRequestDto dto;
    try {
      final payload = jsonDecode(body) as Map<String, dynamic>;
      dto = PrepareUploadRequestDto.fromJson(
          _normalizePrepareUploadRequestJson(payload));
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

    final acceptedFiles = {for (final e in files.entries) e.key: e.value.token};
    if (!v2) {
      return _respondJson(request, 200, body: acceptedFiles);
    }

    final response = PrepareUploadResponseDto(
      sessionId: sessionId,
      files: acceptedFiles,
    );
    return _respondJson(request, 200, body: response.toJson());
  }

  /// POST /upload?sessionId=&fileId=&token=：流式落盘。
  Future<void> _handleUpload(HttpRequest request, {required bool v2}) async {
    final session = _session;
    if (session == null) {
      return _respondJson(request, 409, message: 'No session');
    }
    if (request.ip != session.senderIp) {
      return _respondJson(request, 403, message: 'Invalid IP address');
    }

    var fileId = request.uri.queryParameters['fileId'];
    var token = request.uri.queryParameters['token'];
    var sessionId = request.uri.queryParameters['sessionId'];
    if (session.files.length == 1) {
      final onlyFile = session.files.entries.single;
      fileId ??= onlyFile.key;
      token ??= onlyFile.value.token;
      sessionId ??= session.sessionId;
    }
    if (fileId == null || token == null || (v2 && sessionId == null)) {
      _log(
          'upload missing parameters: uri=${request.uri}; queryParameters=${request.uri.queryParameters}; v2=$v2; expectedSessionId=${session.sessionId}; expectedFileIds=${session.files.keys.toList()}');
      return _respondJson(request, 400, message: 'Missing parameters');
    }
    if (v2 && sessionId != session.sessionId) {
      return _respondJson(request, 403, message: 'Invalid session id');
    }
    final incoming = session.files[fileId];
    if (incoming == null || incoming.token != token) {
      return _respondJson(request, 403, message: 'Invalid token');
    }

    // 落盘：destinationDir/fileName，含子目录自动创建。
    // 复刻 app/lib/util/native/file_saver.dart 的 digestFilePathAndPrepareDirectory：
    // 同名文件自动加序号（foo.txt → foo (1).txt），永不覆盖；并做路径穿越校验防 ../ 偷逃。
    // 注意：必须先用路径字符串做 isWithin 校验并 create，不能先 resolveSymbolicLinks——
    // 传文件夹时子目录尚不存在，resolve 会 PathNotFoundException，且外层 catch 不清 session 会卡死。
    final rawPath = incoming.fileName.replaceAll('\\', '/');
    final dir = rawPath.parentPath();
    final baseName = rawPath.fileName();
    final fullDir = dir.isEmpty
        ? config.destinationDir
        : p.normalize(p.join(config.destinationDir, dir));

    if (dir.isNotEmpty && !p.isWithin(config.destinationDir, fullDir)) {
      _log('Rejected path traversal: $rawPath');
      session.files.remove(fileId);
      if (session.files.isEmpty) {
        _session = null;
      }
      return _respondJson(request, 403, message: 'Invalid file path');
    }

    if (dir.isNotEmpty) {
      await Directory(fullDir).create(recursive: true);
    }

    // 目录已创建后再 resolve，挡住 destinationDir 内既有 symlink 逃逸。
    final normalizedDest =
        await Directory(config.destinationDir).resolveSymbolicLinks();
    final normalizedFullDir = await Directory(fullDir).resolveSymbolicLinks();
    final destPrefix =
        normalizedDest.endsWith('/') ? normalizedDest : '$normalizedDest/';
    if (normalizedFullDir != normalizedDest &&
        !normalizedFullDir.startsWith(destPrefix)) {
      _log('Rejected symlink escape: $rawPath -> $normalizedFullDir');
      session.files.remove(fileId);
      if (session.files.isEmpty) {
        _session = null;
      }
      return _respondJson(request, 403, message: 'Invalid file path');
    }

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

    session.lastActivity = DateTime.now();
    final sink = outFile.openWrite();
    int written = 0;
    try {
      await for (final chunk in request) {
        sink.add(chunk);
        written += chunk.length;
        session.lastActivity = DateTime.now();
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

  /// POST /cancel：对端取消传输时清掉残留会话，避免一直 409。
  Future<void> _handleCancel(HttpRequest request) async {
    _session = null;
    return _respondJson(request, 200, message: 'cancelled');
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

Map<String, dynamic> _normalizeRegisterJson(Map<String, dynamic> payload) {
  final normalized = Map<String, dynamic>.from(payload);

  if (!normalized.containsKey('fingerprint') && normalized['token'] != null) {
    normalized['fingerprint'] = normalized['token'];
  }
  if (!normalized.containsKey('download') &&
      normalized['hasWebInterface'] != null) {
    normalized['download'] = normalized['hasWebInterface'];
  }
  final protocol = normalized['protocol'];
  if (protocol is String) {
    normalized['protocol'] = protocol.toLowerCase();
  }
  final deviceType = normalized['deviceType'];
  if (deviceType is String) {
    normalized['deviceType'] = deviceType.toLowerCase();
  }

  return normalized;
}

Map<String, dynamic> _normalizePrepareUploadRequestJson(
    Map<String, dynamic> payload) {
  final normalized = Map<String, dynamic>.from(payload);
  final info = normalized['info'];
  if (info is Map<String, dynamic>) {
    normalized['info'] = _normalizeRegisterJson(info);
  }
  return normalized;
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
