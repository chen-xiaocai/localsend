import 'dart:async';

import 'package:common/model/device.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/rust/api/model.dart';
import 'package:localsend_app/util/rust.dart';
import 'package:localsend_app/widget/dialogs/error_dialog.dart';
import 'package:localsend_app/widget/dialogs/favorite_edit_dialog.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// A dialog showing a list of favorites
class FavoritesDialog extends StatefulWidget {
  const FavoritesDialog();

  @override
  State<FavoritesDialog> createState() => _FavoritesDialogState();
}

class _FavoritesDialogState extends State<FavoritesDialog> with Refena {
  bool _fetching = false;
  String? _error;

  /// Checks if the device is reachable and pops the dialog with the result if it is.
  /// All known IPs of the favorite are probed in parallel;
  /// the first one that responds wins and becomes the new primary IP.
  Future<void> _checkConnectionToDevice(FavoriteDevice favorite) async {
    setState(() {
      _fetching = true;
      _error = null;
    });

    final https = ref.read(settingsProvider).https;

    try {
      final payload = ref.read(deviceFullInfoProvider).toRegisterDto();
      final device = await _raceAddresses(favorite, https, payload);

      // Remember which IP actually worked.
      await ref.redux(favoritesProvider).dispatchAsync(UpdateFavoriteAction(favorite.withIp(device.ip!, primary: true)));

      if (mounted) {
        context.pop(device);
      }
    } catch (e) {
      setState(() {
        _fetching = false;
        _error = e.toString();
      });
    }
  }

  /// Registers with all known IPs of [favorite] concurrently and returns the
  /// device from the first successful response.
  /// Throws the first error if no IP responds.
  Future<Device> _raceAddresses(FavoriteDevice favorite, bool https, RegisterDto payload) {
    final addresses = favorite.addresses;
    final completer = Completer<Device>();
    var pending = addresses.length;
    Object? firstError;

    for (final ip in addresses) {
      // ignore: discarded_futures
      ref
          .read(httpProvider)
          .v2
          .register(
            protocol: https ? ProtocolType.https : ProtocolType.http,
            ip: ip,
            port: favorite.port,
            payload: payload,
          )
          .then((response) {
        if (!completer.isCompleted) {
          completer.complete(response.body.toDevice(ip, favorite.port, https, HttpDiscovery(ip: ip)));
        }
      }).catchError((Object e) {
        firstError ??= e;
        pending--;
        if (pending == 0 && !completer.isCompleted) {
          completer.completeError(firstError!);
        }
      });
    }

    return completer.future;
  }

  Future<void> _showDeviceDialog([FavoriteDevice? favorite]) async {
    await showDialog(
      context: context,
      builder: (_) => FavoriteEditDialog(favorite: favorite),
    );
  }

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(favoritesProvider);

    return AlertDialog(
      title: Text(t.dialogs.favoriteDialog.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (favorites.isEmpty)
            Text(
              t.dialogs.favoriteDialog.noFavorites,
              style: const TextStyle(color: Colors.grey),
            ),
          for (final favorite in favorites)
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
                    onPressed: _fetching ? null : () async => await _checkConnectionToDevice(favorite),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('${favorite.alias}\n(${favorite.addresses.join(', ')})'),
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
                  onPressed: _fetching ? null : () async => await _showDeviceDialog(favorite),
                  child: const Icon(Icons.edit),
                ),
              ],
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Text(t.general.error, style: TextStyle(color: Theme.of(context).colorScheme.warning)),
                  if (_error != null) ...[
                    const SizedBox(width: 5),
                    InkWell(
                      onTap: () async {
                        await showDialog(
                          context: context,
                          builder: (_) => ErrorDialog(error: _error!),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: Icon(Icons.info, color: Theme.of(context).colorScheme.warning, size: 20),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => context.pop(),
          child: Text(t.general.cancel),
        ),
        FilledButton(
          onPressed: _showDeviceDialog,
          child: Text(t.dialogs.favoriteDialog.addFavorite),
        ),
      ],
    );
  }
}
