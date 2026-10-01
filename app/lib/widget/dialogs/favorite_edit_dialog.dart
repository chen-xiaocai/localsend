import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/register_race.dart';
import 'package:localsend_app/widget/dialogs/error_dialog.dart';
import 'package:localsend_app/widget/dialogs/favorite_delete_dialog.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// A dialog to add or edit a favorite device.
class FavoriteEditDialog extends StatefulWidget {
  final FavoriteDevice? favorite;
  final Device? prefilledDevice;

  const FavoriteEditDialog({
    this.favorite,
    this.prefilledDevice,
  });

  @override
  State<FavoriteEditDialog> createState() => _FavoriteEditDialogState();
}

class _FavoriteEditDialogState extends State<FavoriteEditDialog> with Refena {
  /// One controller per IP address; the first one is the primary IP.
  final _ipControllers = <TextEditingController>[];

  /// Controllers of rows added by the user, which should get focus.
  final _addedIpControllers = <TextEditingController>{};
  final _portController = TextEditingController();
  final _aliasController = TextEditingController();
  bool _fetching = false;
  String? _error;
  bool _ipMissing = false;

  @override
  void initState() {
    super.initState();

    final ips = widget.prefilledDevice != null ? [widget.prefilledDevice!.ip ?? ''] : widget.favorite?.addresses ?? const <String>[];
    for (final ip in ips.isEmpty ? [''] : ips) {
      _ipControllers.add(TextEditingController(text: ip));
    }
    _aliasController.text = widget.prefilledDevice?.alias ?? widget.favorite?.alias ?? '';

    ensureRef((ref) {
      _portController.text =
          widget.prefilledDevice?.port.toString() ?? widget.favorite?.port.toString() ?? ref.read(settingsProvider).port.toString();
    });
  }

  @override
  void dispose() {
    for (final controller in _ipControllers) {
      controller.dispose();
    }
    _portController.dispose();
    _aliasController.dispose();
    super.dispose();
  }

  /// The entered IPs, trimmed and without empty entries or duplicates.
  List<String> _collectIps() {
    return _ipControllers.map((c) => c.text.trim()).where((ip) => ip.isNotEmpty).toSet().toList();
  }

  void _addIp() {
    final controller = TextEditingController();
    setState(() {
      _ipControllers.add(controller);
      _addedIpControllers.add(controller);
    });
  }

  void _removeIp(TextEditingController controller) {
    setState(() {
      _ipControllers.remove(controller);
      _addedIpControllers.remove(controller);
    });
    // Dispose after the field using it is gone.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.favorite != null ? t.dialogs.favoriteEditDialog.titleEdit : t.dialogs.favoriteEditDialog.titleAdd),
      content: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.dialogs.favoriteEditDialog.name),
            const SizedBox(height: 5),
            TextFormField(
              controller: _aliasController,
              decoration: InputDecoration(
                hintText: t.dialogs.favoriteEditDialog.auto,
              ),
              enabled: !_fetching,
            ),
            const SizedBox(height: 16),
            Text(t.dialogs.favoriteEditDialog.ip),
            const SizedBox(height: 5),
            for (final (index, controller) in _ipControllers.indexed)
              Padding(
                key: ObjectKey(controller),
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: controller,
                        autofocus:
                            _addedIpControllers.contains(controller) || (index == 0 && widget.favorite == null && widget.prefilledDevice == null),
                        enabled: !_fetching,
                        keyboardType: TextInputType.url,
                        decoration: InputDecoration(
                          suffixText: index == 0 && _ipControllers.length > 1 ? t.dialogs.favoriteEditDialog.primaryIp : null,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: t.dialogs.favoriteEditDialog.removeIp,
                      onPressed: _fetching || _ipControllers.length <= 1 ? null : () => _removeIp(controller),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ],
                ),
              ),
            if (_ipMissing)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(t.dialogs.favoriteEditDialog.ipRequired, style: TextStyle(color: Theme.of(context).colorScheme.warning)),
              ),
            TextButton.icon(
              onPressed: _fetching ? null : _addIp,
              icon: const Icon(Icons.add),
              label: Text(t.dialogs.favoriteEditDialog.addIp),
            ),
            const SizedBox(height: 16),
            Text(t.dialogs.favoriteEditDialog.port),
            const SizedBox(height: 5),
            TextFormField(
              controller: _portController,
              enabled: !_fetching,
              keyboardType: TextInputType.number,
            ),
            if (widget.favorite != null) ...[
              const SizedBox(height: 16),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.warning,
                ),
                onPressed: () async {
                  final result = await showDialog<bool>(
                    context: context,
                    builder: (_) => FavoriteDeleteDialog(widget.favorite!),
                  );

                  if (context.mounted && result == true) {
                    await context.ref.redux(favoritesProvider).dispatchAsync(RemoveFavoriteAction(deviceFingerprint: widget.favorite!.fingerprint));
                    if (context.mounted) {
                      context.pop();
                    }
                  }
                },
                icon: const Icon(Icons.delete),
                label: Text(t.general.delete),
              ),
            ],
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
      ),
      actions: [
        TextButton(
          onPressed: () => context.pop(),
          child: Text(t.general.cancel),
        ),
        FilledButton(
          onPressed: _fetching
              ? null
              : () async {
                  final ips = _collectIps();
                  setState(() => _ipMissing = ips.isEmpty);
                  if (ips.isEmpty) {
                    return;
                  }

                  if (_portController.text.isEmpty) {
                    return;
                  }

                  if (widget.favorite != null) {
                    // Update existing favorite
                    final existingFavorite = widget.favorite!;
                    final trimmedNewAlias = _aliasController.text.trim();
                    if (trimmedNewAlias.isEmpty) {
                      return;
                    }

                    await ref
                        .redux(favoritesProvider)
                        .dispatchAsync(
                          UpdateFavoriteAction(
                            existingFavorite.copyWith(
                              ip: ips.first,
                              ips: ips,
                              port: int.parse(_portController.text),
                              alias: trimmedNewAlias,
                              customAlias: existingFavorite.customAlias || trimmedNewAlias != existingFavorite.alias,
                            ),
                          ),
                        );

                    if (context.mounted) {
                      context.pop();
                    }
                  } else {
                    // Add new favorite
                    final port = int.parse(_portController.text);
                    final https = ref.read(settingsProvider).https;
                    setState(() {
                      _fetching = true;
                    });

                    try {
                      // The first IP that responds becomes the primary IP.
                      final (ip, response) = await raceRegister(ref, ips: ips, port: port, https: https);

                      final name = _aliasController.text.trim();

                      await ref
                          .redux(favoritesProvider)
                          .dispatchAsync(
                            AddFavoriteAction(
                              FavoriteDevice.fromValues(
                                fingerprint: response.token,
                                ip: ip,
                                port: port,
                                alias: name.isEmpty ? response.alias : name,
                              ).copyWith(ips: [ip, ...ips.where((e) => e != ip)]),
                            ),
                          );

                      if (context.mounted) {
                        context.pop();
                      }
                    } catch (e) {
                      setState(() {
                        _fetching = false;
                        _error = e.toString();
                      });
                    }
                  }
                },
          child: Text(t.general.confirm),
        ),
      ],
    );
  }
}
