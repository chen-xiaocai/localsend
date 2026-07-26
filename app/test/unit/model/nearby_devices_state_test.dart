import 'package:common/model/device.dart';
import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:test/test.dart';

void main() {
  test('allDevices merges multiple IPs of the same fingerprint into one entry', () {
    final state = NearbyDevicesState(
      runningFavoriteScan: false,
      runningIps: const {},
      devices: {
        '192.168.72.8': _createDevice(fingerprint: 'fp-a', ip: '192.168.72.8'),
        '100.75.118.59': _createDevice(fingerprint: 'fp-a', ip: '100.75.118.59'),
        '192.168.72.20': _createDevice(fingerprint: 'fp-b', ip: '192.168.72.20'),
      },
      signalingDevices: const {},
    );

    final all = state.allDevices;

    expect(all.length, 2);
    expect(all.keys, containsAll(['fp-a', 'fp-b']));
    expect(all['fp-a']!.ip, isNotNull);
  });

  test('allDevices merges signaling entry into the LAN entry of the same fingerprint', () {
    final lanDevice = _createDevice(fingerprint: 'fp-a', ip: '192.168.72.8');
    final signalingDevice = Device(
      signalingId: 'signaling-id',
      ip: null,
      version: '2.1',
      port: -1,
      https: false,
      fingerprint: 'fp-a',
      alias: lanDevice.alias,
      deviceModel: 'Android',
      deviceType: DeviceType.mobile,
      download: false,
      discoveryMethods: const {},
    );

    final state = NearbyDevicesState(
      runningFavoriteScan: false,
      runningIps: const {},
      devices: {'192.168.72.8': lanDevice},
      signalingDevices: {
        'fp-a': {signalingDevice},
      },
    );

    final all = state.allDevices;

    expect(all.length, 1);
    expect(all['fp-a']!.ip, '192.168.72.8');
    expect(all['fp-a']!.signalingId, 'signaling-id');
  });
}

Device _createDevice({required String fingerprint, required String ip}) {
  return Device(
    signalingId: null,
    ip: ip,
    version: '2.1',
    port: 53317,
    https: true,
    fingerprint: fingerprint,
    alias: 'Test Device',
    deviceModel: 'Android',
    deviceType: DeviceType.mobile,
    download: false,
    discoveryMethods: const {},
  );
}
