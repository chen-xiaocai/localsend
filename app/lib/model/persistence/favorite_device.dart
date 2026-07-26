import 'package:dart_mappable/dart_mappable.dart';
import 'package:uuid/uuid.dart';

part 'favorite_device.mapper.dart';

const _uuid = Uuid();

@MappableClass()
class FavoriteDevice with FavoriteDeviceMappable {
  final String id;
  final String fingerprint;

  /// The primary (last known working) IP address.
  final String ip;

  /// All known IP addresses of this device (a device may be reachable via
  /// multiple interfaces, e.g. LAN and Tailscale).
  /// May be empty for entries persisted by older versions; use [addresses].
  final List<String> ips;

  final int port;
  final String alias;

  /// If true, the alias was set by the user.
  /// If false, the alias is derived from the original device alias and
  /// should be updated when the original device alias changes.
  final bool customAlias;

  const FavoriteDevice({
    required this.id,
    required this.fingerprint,
    required this.ip,
    this.ips = const [],
    required this.port,
    required this.alias,
    this.customAlias = false,
  });

  factory FavoriteDevice.fromValues({
    required String fingerprint,
    required String ip,
    required int port,
    required String alias,
  }) {
    return FavoriteDevice(
      id: _uuid.v1(),
      fingerprint: fingerprint,
      ip: ip,
      ips: [ip],
      port: port,
      alias: alias,
      customAlias: false,
    );
  }

  /// All known IPs with the primary [ip] first.
  List<String> get addresses => [ip, ...ips.where((e) => e != ip)];

  /// Returns a copy with [newIp] added to the known IPs.
  /// If [primary] is true, [newIp] becomes the primary IP.
  FavoriteDevice withIp(String newIp, {bool primary = false}) {
    final merged = primary
        ? [newIp, ...addresses.where((e) => e != newIp)]
        : [...addresses, if (!addresses.contains(newIp)) newIp];
    return copyWith(ip: merged.first, ips: merged);
  }

  /// Merges [other] (same fingerprint) into this favorite, keeping this
  /// entry's identity and combining the known IPs.
  FavoriteDevice mergeWith(FavoriteDevice other) {
    var merged = this;
    for (final ip in other.addresses) {
      merged = merged.withIp(ip);
    }
    if (!customAlias && other.customAlias) {
      merged = merged.copyWith(alias: other.alias, customAlias: true);
    }
    return merged;
  }

  static const fromJson = FavoriteDeviceMapper.fromJson;
}
