import 'package:common/model/device.dart';

enum PeerDiscoverySource {
  lan,
  tailscale,
  manual,
}

/// 发现到的对端设备。
class DiscoveredPeer {
  final String ip;
  final int port;
  final bool https;
  final String alias;
  final String fingerprint;
  final String? deviceModel;
  final DeviceType deviceType;
  final PeerDiscoverySource source;
  final String? system;

  const DiscoveredPeer({
    required this.ip,
    required this.port,
    required this.https,
    required this.alias,
    required this.fingerprint,
    this.deviceModel,
    this.deviceType = DeviceType.desktop,
    this.source = PeerDiscoverySource.lan,
    this.system,
  });

  String get protocol => https ? 'https' : 'http';

  String get systemLabel {
    final parts = <String>[
      if (system != null && system!.isNotEmpty) system!,
      if (deviceModel != null && deviceModel!.isNotEmpty) deviceModel!,
      deviceType.name,
    ];
    return parts.toSet().join(' / ');
  }

  @override
  String toString() => '$alias @ $ip:$port ($protocol, ${deviceType.name})';
}
