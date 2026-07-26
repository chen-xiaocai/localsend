import 'package:common/isolate.dart';
import 'package:common/model/device.dart';
import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

void main() {
  test('RegisterSignalingDeviceAction ignores local fingerprint', () {
    final service = ReduxNotifier.test(
      redux: NearbyDevicesService(
        isolateController: _MockIsolateController(),
        favoriteService: _MockFavoritesService(),
        discoveryLogs: _MockDiscoveryLogger(),
      ),
      initialState: const NearbyDevicesState(
        runningFavoriteScan: false,
        runningIps: {},
        devices: {},
        signalingDevices: {},
      ),
    );

    final localDevice = _createSignalingDevice(fingerprint: 'local-fp');

    service.dispatch(
      RegisterSignalingDeviceAction(
        localDevice,
        localFingerprint: 'local-fp',
      ),
    );

    expect(service.state.signalingDevices, isEmpty);

    service.dispatch(
      RegisterSignalingDeviceAction(
        localDevice,
        localFingerprint: 'other-fp',
      ),
    );

    expect(service.state.signalingDevices['local-fp']?.length, 1);
  });
}

Device _createSignalingDevice({required String fingerprint}) {
  return Device(
    signalingId: 'signaling-id',
    ip: null,
    version: '2.1',
    port: -1,
    https: false,
    fingerprint: fingerprint,
    alias: 'Test Device',
    deviceModel: 'Android',
    deviceType: DeviceType.mobile,
    download: false,
    discoveryMethods: {},
  );
}

class _MockIsolateController extends Mock implements IsolateController {}

class _MockFavoritesService extends Mock implements FavoritesService {}

class _MockDiscoveryLogger extends Mock implements DiscoveryLogger {}
