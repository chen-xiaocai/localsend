import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli/src/peer.dart';
import 'package:cli/src/security.dart';
import 'package:common/constants.dart';
import 'package:common/model/device.dart';
import 'package:common/model/dto/multicast_dto.dart';

/// UDP 多播发现：加入 224.0.0.167:53317，收发 LocalSend 多播通告。
///
/// 纯 dart:io 实现，不依赖 isolate 体系。收到非自身通告时回调 [onPeer]。
class MulticastDiscovery {
  final SecurityContextData security;
  final String alias;
  final String deviceModel;
  final int port;
  final bool https;
  final void Function(DiscoveredPeer peer) onPeer;

  RawDatagramSocket? _socket;

  MulticastDiscovery({
    required this.security,
    required this.alias,
    required this.deviceModel,
    required this.port,
    required this.https,
    required this.onPeer,
  });

  Future<void> start() async {
    _socket =
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, defaultPort);
    _socket!.broadcastEnabled = true;
    _socket!.multicastLoopback = false;

    // 逐接口加入多播组，提升多网卡环境下的接收覆盖。
    final interfaces = await NetworkInterface.list();
    for (final iface in interfaces) {
      try {
        _socket!.joinMulticast(InternetAddress(defaultMulticastGroup), iface);
      } catch (e) {
        stderr.writeln('[multicast] join ${iface.name} failed: $e');
      }
    }

    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _socket!.receive();
      if (dg == null) return;
      try {
        final dto = MulticastDto.fromJson(
            jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>);
        if (dto.fingerprint == security.certificateHash) return; // 自身回环
        onPeer(DiscoveredPeer(
          ip: dg.address.address,
          port: dto.port ?? defaultPort,
          https: dto.protocol == ProtocolType.https,
          alias: dto.alias,
          fingerprint: dto.fingerprint,
          deviceModel: dto.deviceModel,
          deviceType: dto.deviceType ?? DeviceType.desktop,
          source: PeerDiscoverySource.lan,
        ));
      } catch (_) {
        // 解析失败的报文忽略
      }
    });
  }

  MulticastDto _buildDto({required bool announcement}) => MulticastDto(
        alias: alias,
        version: protocolVersion,
        deviceModel: deviceModel,
        deviceType: DeviceType.headless,
        fingerprint: security.certificateHash,
        port: port,
        protocol: https ? ProtocolType.https : ProtocolType.http,
        download: false,
        announcement: announcement,
        announce: announcement,
      );

  /// 发送一次多播通告。连发两遍以提高对端捕获率。
  Future<void> announce() async {
    final bytes =
        utf8.encode(jsonEncode(_buildDto(announcement: true).toJson()));
    final group = InternetAddress(defaultMulticastGroup);
    for (final wait in const [Duration.zero, Duration(milliseconds: 200)]) {
      await Future.delayed(wait);
      _socket?.send(bytes, group, defaultPort);
    }
  }

  Future<void> stop() async {
    _socket?.close();
  }
}
