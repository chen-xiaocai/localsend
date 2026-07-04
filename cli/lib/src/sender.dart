import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli/src/config.dart';
import 'package:cli/src/multicast.dart';
import 'package:cli/src/peer.dart';
import 'package:common/api_route_builder.dart';
import 'package:common/constants.dart';
import 'package:common/model/device.dart' hide MulticastDiscovery;
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/info_register_dto.dart';
import 'package:common/model/dto/multicast_dto.dart';
import 'package:common/model/dto/prepare_upload_request_dto.dart';
import 'package:common/model/dto/prepare_upload_response_dto.dart';
import 'package:common/model/file_type.dart';
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// LocalSend v2 发送客户端：发现对端 → prepare-upload → upload。
class SendClient {
  final NodeConfig config;
  final void Function(String line) onLog;

  SendClient({required this.config, required this.onLog});

  /// 发送 [files] 到指定对端 [peer]。返回是否全部成功。
  Future<bool> sendTo(DiscoveredPeer peer, List<File> files) async {
    final client = _httpClient();
    try {
      return await _send(client, peer, files);
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _send(
      HttpClient client, DiscoveredPeer peer, List<File> files) async {
    final base = '${peer.https ? 'https' : 'http'}://${peer.ip}:${peer.port}';

    // 1. 构造文件 DTO
    final fileDtos = <String, FileDto>{};
    final fileMap = <String, File>{}; // fileId -> 本地文件
    for (final file in files) {
      final id = _uuid.v4();
      final stat = await file.stat();
      fileDtos[id] = FileDto(
        id: id,
        fileName: file.path.split('/').last,
        size: stat.size,
        fileType: _lookupType(file.path),
        hash: null,
        preview: null,
        metadata: null,
      );
      fileMap[id] = file;
    }

    // 2. prepare-upload
    final info = InfoRegisterDto(
      alias: config.alias,
      version: protocolVersion,
      deviceModel: 'Linux',
      deviceType: DeviceType.headless,
      fingerprint: config.security.certificateHash,
      port: config.port,
      protocol: config.https ? ProtocolType.https : ProtocolType.http,
      download: false,
    );
    final reqDto = PrepareUploadRequestDto(info: info, files: fileDtos);

    _log(
        'Sending to ${peer.alias} (${peer.ip}) — ${files.length} file(s), asking recipient to accept...');

    final PrepareUploadResponseDto resp;
    try {
      final body = await _postJson(
        client,
        '$base${ApiRoute.prepareUpload.v2}',
        reqDto.toJson(),
      );
      resp = PrepareUploadResponseDto.fromJson(body);
    } catch (e) {
      _log('prepare-upload failed: $e');
      return false;
    }

    if (resp.files.isEmpty) {
      _log('Recipient declined or selected nothing.');
      return false;
    }

    // 3. upload 每个被接受的文件
    bool allOk = true;
    for (final entry in resp.files.entries) {
      final fileId = entry.key;
      final token = entry.value;
      final file = fileMap[fileId]!;
      final ok =
          await _uploadFile(client, base, resp.sessionId, fileId, token, file);
      if (!ok) allOk = false;
    }

    _log(allOk ? 'All files sent.' : 'Some files failed.');
    return allOk;
  }

  Future<bool> _uploadFile(
    HttpClient client,
    String base,
    String sessionId,
    String fileId,
    String token,
    File file,
  ) async {
    final stat = await file.stat();
    final uri = Uri.parse(
      '$base${ApiRoute.upload.v2}?sessionId=${Uri.encodeQueryComponent(sessionId)}'
      '&fileId=${Uri.encodeQueryComponent(fileId)}&token=${Uri.encodeQueryComponent(token)}',
    );

    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.binary;
    request.headers.contentLength = stat.size;

    int sent = 0;
    final stream = file.openRead();
    try {
      await for (final chunk in stream) {
        request.add(chunk);
        sent += chunk.length;
      }
      final response = await request.close();
      final ok = response.statusCode == 200;
      // 读完响应体以释放连接
      await response.drain<void>();
      _log(
          '${ok ? "✓" : "✗"} ${file.path.split('/').last} (${_fmtSize(sent)}) -> ${response.statusCode}');
      return ok;
    } catch (e) {
      _log('✗ ${file.path.split('/').last} failed: $e');
      return false;
    }
  }

  /// 多播发现，最多等待 [timeout]，返回见到的所有对端（去重）。
  Future<List<DiscoveredPeer>> discover({required Duration timeout}) async {
    final peers = <String, DiscoveredPeer>{};
    final completer = Completer<void>();
    final discovery = MulticastDiscovery(
      security: config.security,
      alias: config.alias,
      deviceModel: 'Linux',
      port: config.port,
      https: config.https,
      onPeer: (peer) {
        peers[peer.fingerprint] = peer;
      },
    );
    await discovery.start();
    await discovery.announce();

    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete();
    });

    // 边等边周期性通告，提高被对端捕获率
    final announceTimer =
        Timer.periodic(const Duration(milliseconds: 800), (_) {
      unawaited(discovery.announce());
    });

    await completer.future;
    timer.cancel();
    announceTimer.cancel();
    await discovery.stop();
    return peers.values.toList();
  }

  HttpClient _httpClient() {
    final client = HttpClient();
    // 对端是自签证书，必须接受
    client.badCertificateCallback = (cert, host, port) => true;
    // Tailscale 冷隧道握手可能较慢,留足余量
    client.connectionTimeout = const Duration(seconds: 15);
    client.idleTimeout = const Duration(seconds: 30);
    return client;
  }

  Future<Map<String, dynamic>> _postJson(
      HttpClient client, String url, Map<String, dynamic> json) async {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(json));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: $body');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  void _log(String line) => onLog(line);
}

FileType _lookupType(String path) {
  final mime = lookupMimeType(path) ?? 'application/octet-stream';
  if (mime.startsWith('image/')) return FileType.image;
  if (mime.startsWith('video/')) return FileType.video;
  if (mime == 'application/pdf') return FileType.pdf;
  if (mime.startsWith('text/')) return FileType.text;
  if (mime == 'application/vnd.android.package-archive') return FileType.apk;
  return FileType.other;
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
