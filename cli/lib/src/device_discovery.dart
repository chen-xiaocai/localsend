import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli/src/config.dart';
import 'package:cli/src/multicast.dart';
import 'package:cli/src/peer.dart';
import 'package:common/api_route_builder.dart';
import 'package:common/model/device.dart' hide MulticastDiscovery;
import 'package:common/model/dto/info_dto.dart';

class DeviceDiscoveryClient {
  final NodeConfig config;

  const DeviceDiscoveryClient({required this.config});

  Future<List<DiscoveredPeer>> discover({
    required Duration timeout,
    required bool includeLan,
    required bool includeTailscale,
  }) async {
    final results = await Future.wait<List<DiscoveredPeer>>([
      if (includeLan) _discoverLan(timeout),
      if (includeTailscale) _discoverTailscale(timeout),
    ]);
    return _dedupe(results.expand((e) => e).toList());
  }

  Future<List<DiscoveredPeer>> _discoverLan(Duration timeout) async {
    final peers = <String, DiscoveredPeer>{};
    final completer = Completer<void>();
    final discovery = MulticastDiscovery(
      security: config.security,
      alias: config.alias,
      deviceModel: 'Linux',
      port: config.port,
      https: config.https,
      onPeer: (peer) {
        final key = peer.fingerprint.isEmpty
            ? '${peer.ip}:${peer.port}'
            : peer.fingerprint;
        peers[key] = peer;
      },
    );
    Timer? timer;
    Timer? announceTimer;
    try {
      await discovery.start();
      await discovery.announce();

      timer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });
      announceTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
        unawaited(discovery.announce());
      });

      await completer.future;
    } catch (_) {
      return const [];
    } finally {
      timer?.cancel();
      announceTimer?.cancel();
      await discovery.stop();
    }
    return peers.values.toList();
  }

  Future<List<DiscoveredPeer>> _discoverTailscale(Duration timeout) async {
    final candidates = await _tailscaleCandidates();
    final probes = candidates.map((candidate) => _probe(candidate, timeout));
    final peers = await Future.wait(probes);
    return peers.whereType<DiscoveredPeer>().toList();
  }

  Future<DiscoveredPeer?> _probe(
      _TailscaleCandidate candidate, Duration timeout) async {
    final protocols = <bool>{config.https, true, false};
    for (final https in protocols) {
      for (final route in [ApiRoute.info.v2, ApiRoute.info.v1]) {
        final peer = await _probeRoute(candidate, https, route, timeout);
        if (peer != null) {
          return peer;
        }
      }
    }
    return null;
  }

  Future<DiscoveredPeer?> _probeRoute(
    _TailscaleCandidate candidate,
    bool https,
    String route,
    Duration timeout,
  ) async {
    final client = HttpClient();
    client.badCertificateCallback = (_, __, ___) => true;
    client.connectionTimeout = timeout;
    client.idleTimeout = timeout;

    try {
      final uri = Uri(
        scheme: https ? 'https' : 'http',
        host: candidate.ip,
        port: config.port,
        path: route,
        queryParameters: {'fingerprint': config.security.certificateHash},
      );
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
      final response = await request.close().timeout(timeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode == 412) {
        return null;
      }
      if (response.statusCode != 200) {
        return null;
      }

      final dto = InfoDto.fromJson(jsonDecode(body) as Map<String, dynamic>);
      if (dto.fingerprint == config.security.certificateHash) {
        return null;
      }
      return DiscoveredPeer(
        ip: candidate.ip,
        port: config.port,
        https: https,
        alias: dto.alias,
        fingerprint: dto.fingerprint ?? '${candidate.ip}:${config.port}',
        deviceModel: dto.deviceModel ?? candidate.name,
        deviceType: dto.deviceType ?? _deviceTypeFromSystem(candidate.system),
        source: PeerDiscoverySource.tailscale,
        system: candidate.system,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<_TailscaleCandidate>> _tailscaleCandidates() async {
    final fromStatus = await _tailscaleStatusCandidates();
    if (fromStatus.isNotEmpty) {
      return fromStatus;
    }

    return const [
      _TailscaleCandidate(
          ip: '100.75.58.59', name: 'macbook-air', system: 'macOS'),
      _TailscaleCandidate(
          ip: '100.75.118.59', name: 'mate-30-5g', system: 'Android'),
      _TailscaleCandidate(
          ip: '100.93.84.127', name: 'chenxiaobai', system: 'Linux'),
    ];
  }

  Future<List<_TailscaleCandidate>> _tailscaleStatusCandidates() async {
    try {
      final result = await Process.run(
        'tailscale',
        ['status', '--json'],
      ).timeout(const Duration(seconds: 3));
      if (result.exitCode != 0) {
        return const [];
      }

      final root = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final selfIps = _tailscaleIps(root['Self']).toSet();
      final peers = root['Peer'];
      if (peers is! Map) {
        return const [];
      }

      final candidates = <_TailscaleCandidate>[];
      for (final node in peers.values) {
        if (node is! Map) {
          continue;
        }
        final online = node['Online'] == true || node['Active'] == true;
        if (!online) {
          continue;
        }
        final ip = _firstTailscaleIp(node, selfIps);
        if (ip == null) {
          continue;
        }
        candidates.add(
          _TailscaleCandidate(
            ip: ip,
            name: _stringOrNull(node['HostName']) ??
                _stringOrNull(node['DNSName']),
            system: _stringOrNull(node['OS']),
          ),
        );
      }
      return candidates;
    } catch (_) {
      return const [];
    }
  }

  List<String> _tailscaleIps(Object? node) {
    if (node is! Map) {
      return const [];
    }
    final raw = node['TailscaleIPs'];
    if (raw is! List) {
      return const [];
    }
    return raw.whereType<String>().where((ip) => ip.contains('.')).toList();
  }

  String? _firstTailscaleIp(Object? node, Set<String> excluded) {
    for (final ip in _tailscaleIps(node)) {
      if (!excluded.contains(ip)) {
        return ip;
      }
    }
    return null;
  }

  List<DiscoveredPeer> _dedupe(List<DiscoveredPeer> peers) {
    final byEndpoint = <String, DiscoveredPeer>{};
    for (final peer in peers) {
      final key = '${peer.ip}:${peer.port}:${peer.protocol}';
      byEndpoint[key] = peer;
    }
    final sorted = byEndpoint.values.toList()
      ..sort((a, b) {
        final source = a.source.index.compareTo(b.source.index);
        if (source != 0) return source;
        return a.alias.toLowerCase().compareTo(b.alias.toLowerCase());
      });
    return sorted;
  }
}

class _TailscaleCandidate {
  final String ip;
  final String? name;
  final String? system;

  const _TailscaleCandidate({
    required this.ip,
    required this.name,
    required this.system,
  });
}

DeviceType _deviceTypeFromSystem(String? system) {
  switch (system?.toLowerCase()) {
    case 'android':
    case 'ios':
      return DeviceType.mobile;
    case 'linux':
      return DeviceType.headless;
    case 'windows':
    case 'macos':
    case 'darwin':
      return DeviceType.desktop;
    default:
      return DeviceType.desktop;
  }
}

String? _stringOrNull(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}
