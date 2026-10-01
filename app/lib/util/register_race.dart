import 'dart:async';

import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Registers with all [ips] concurrently and returns the IP and response
/// of the first one that answers.
/// Throws the first error if no IP responds.
Future<(String, RegisterResponseDto)> raceRegister(
  Ref ref, {
  required List<String> ips,
  required int port,
  required bool https,
}) {
  final payload = ref.read(deviceFullInfoProvider).toRegisterDto();
  final completer = Completer<(String, RegisterResponseDto)>();
  var pending = ips.length;
  Object? firstError;

  for (final ip in ips) {
    unawaited(
      ref
          .read(httpProvider)
          .discovery
          .register(
            protocol: https ? ProtocolType.https : ProtocolType.http,
            ip: ip,
            port: port,
            payload: payload,
          )
          .then((response) {
            if (!completer.isCompleted) {
              completer.complete((ip, response.body));
            }
          })
          .catchError((Object e) {
            firstError ??= e;
            pending--;
            if (pending == 0 && !completer.isCompleted) {
              completer.completeError(firstError!);
            }
          }),
    );
  }

  return completer.future;
}
