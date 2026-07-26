import 'package:localsend_app/provider/network/webrtc/signaling_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import '../../mocks.mocks.dart';

void main() {
  late MockPersistenceService persistenceService;

  setUp(() {
    persistenceService = MockPersistenceService();
  });

  test('SetupSignalingConnection skips already connected or connecting servers', () {
    final service = ReduxNotifier.test(
      redux: SignalingService(persistence: persistenceService),
      initialState: SignalingState(
        signalingServers: [
          'wss://connected.example/ws',
          'wss://connecting.example/ws',
          'wss://free.example/ws',
        ],
        stunServers: [],
        connections: {},
        connectingServers: {
          'wss://connecting.example/ws',
        },
      ),
    );

    final skipped = service.state.signalingServers.where((signalingServer) {
      return service.state.connections.containsKey(signalingServer) || service.state.connectingServers.contains(signalingServer);
    }).toList();

    expect(skipped, ['wss://connecting.example/ws']);

    final eligible = service.state.signalingServers.where((signalingServer) {
      return !service.state.connections.containsKey(signalingServer) && !service.state.connectingServers.contains(signalingServer);
    }).toList();

    expect(eligible, [
      'wss://connected.example/ws',
      'wss://free.example/ws',
    ]);
  });
}
