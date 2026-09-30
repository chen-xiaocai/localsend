import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/pages/progress_page.dart';
import 'package:localsend_app/pages/send_page.dart';
import 'package:localsend_app/pages/tabs/send_tab.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/widget/dialogs/add_file_dialog.dart';
import 'package:localsend_app/widget/dialogs/address_input_dialog.dart';
import 'package:localsend_app/widget/dialogs/favorite_dialog.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

class SendTabVm {
  final SendMode sendMode;
  final List<CrossFile> selectedFiles;
  final List<String> localIps;
  final Iterable<Device> nearbyDevices;
  final List<FavoriteDevice> favoriteDevices;
  final Future<void> Function(BuildContext context) onTapAddress;
  final Future<void> Function(BuildContext context) onTapFavorite;
  final Future<void> Function(BuildContext context, SendMode mode) onTapSendMode;
  final Future<void> Function(BuildContext context, Device device) onTapDevice;
  final Future<void> Function(BuildContext context, Device device) onTapDeviceMultiSend;

  /// Fingerprints of the devices checked in the multiple recipients mode.
  final Set<String> checkedDevices;
  final void Function(Device device, bool checked) onCheckDevice;
  final void Function(bool checked) onCheckAllDevices;

  /// Sends the selection to all checked devices at once.
  final Future<void> Function(BuildContext context) onSendToCheckedDevices;

  const SendTabVm({
    required this.sendMode,
    required this.selectedFiles,
    required this.localIps,
    required this.nearbyDevices,
    required this.favoriteDevices,
    required this.onTapAddress,
    required this.onTapFavorite,
    required this.onTapSendMode,
    required this.onTapDevice,
    required this.onTapDeviceMultiSend,
    required this.checkedDevices,
    required this.onCheckDevice,
    required this.onCheckAllDevices,
    required this.onSendToCheckedDevices,
  });
}

final sendTabVmProvider = ViewProvider((ref) {
  final sendMode = ref.watch(settingsProvider.select((s) => s.sendMode));
  final selectedFiles = ref.watch(selectedSendingFilesProvider);
  final localIps = ref.watch(localIpProvider).localIps;
  final nearbyDevices = ref.watch(nearbyDevicesProvider).allDevices.values;
  final favoriteDevices = ref.watch(favoritesProvider);
  final checkedDevices = ref.watch(multiSendCheckedDevicesProvider);

  return SendTabVm(
    sendMode: sendMode,
    selectedFiles: selectedFiles,
    localIps: localIps,
    nearbyDevices: nearbyDevices,
    favoriteDevices: favoriteDevices,
    onTapAddress: (context) async {
      var files = ref.read(selectedSendingFilesProvider);
      if (files.isEmpty) {
        await AddFileDialog.open(
          context: context,
          options: pickerOptions,
        );
      }

      files = ref.read(selectedSendingFilesProvider);

      if (files.isEmpty || !context.mounted) {
        return;
      }
      final device = await showDialog<Device?>(
        context: context,
        builder: (_) => const AddressInputDialog(),
      );
      if (device != null && context.mounted) {
        await ref
            .notifier(sendProvider)
            .startSession(
              target: device,
              files: files,
              background: false,
            );
      }
    },
    onTapFavorite: (context) async {
      final device = await showDialog<Device?>(
        context: context,
        builder: (_) => const FavoritesDialog(),
      );
      if (device != null && context.mounted) {
        var files = ref.read(selectedSendingFilesProvider);
        if (files.isEmpty) {
          await AddFileDialog.open(
            context: context,
            options: pickerOptions,
          );
        }

        files = ref.read(selectedSendingFilesProvider);

        if (files.isEmpty) {
          return;
        }

        await ref
            .notifier(sendProvider)
            .startSession(
              target: device,
              files: files,
              background: false,
            );
      }
    },
    onTapSendMode: (context, mode) async {
      if (mode == SendMode.link) {
        var files = ref.read(selectedSendingFilesProvider);
        if (files.isEmpty) {
          await AddFileDialog.open(
            context: context,
            options: pickerOptions,
          );
        }

        files = ref.read(selectedSendingFilesProvider);

        if (files.isEmpty || !context.mounted) {
          return;
        }
        await context.push(() => WebSharePage(files: files));
        return;
      }

      await ref.notifier(settingsProvider).setSendMode(mode);
      if (mode != SendMode.multiple) {
        ref.notifier(sendProvider).clearAllSessions();
      }
    },
    onTapDevice: (context, device) async {
      var files = selectedFiles;
      if (files.isEmpty) {
        await AddFileDialog.open(
          context: context,
          options: pickerOptions,
        );
      }

      files = ref.read(selectedSendingFilesProvider);

      if (files.isEmpty) {
        return;
      }

      await ref
          .notifier(sendProvider)
          .startSession(
            target: device,
            files: files,
            background: false,
          );
    },
    onTapDeviceMultiSend: (context, device) async {
      final session = ref.read(sendProvider).values.firstWhereOrNull((s) => s.target.ip == device.ip);
      if (session != null) {
        if (session.status == SessionStatus.waiting) {
          ref.notifier(sendProvider).setBackground(session.sessionId, false);
          await context.push(
            () => SendPage(showAppBar: true, closeSessionOnClose: false, sessionId: session.sessionId),
            transition: RouterinoTransition.fade(),
          );
          // Only restore background mode if the user actually backed out.
          // When the receiver accepts, the provider replaces this page with the ProgressPage,
          // which also resolves this future; the ProgressPage then owns the background flag.
          if (ref.read(sendProvider)[session.sessionId]?.status == SessionStatus.waiting) {
            ref.notifier(sendProvider).setBackground(session.sessionId, true);
          }
          return;
        } else if (session.status == SessionStatus.sending || session.status == SessionStatus.finishedWithErrors) {
          ref.notifier(sendProvider).setBackground(session.sessionId, false);
          await context.push(() => ProgressPage(showAppBar: true, closeSessionOnClose: false, sessionId: session.sessionId));
          ref.notifier(sendProvider).setBackground(session.sessionId, true);
          return;
        }
      }

      var files = ref.read(selectedSendingFilesProvider);

      if (files.isEmpty) {
        await AddFileDialog.open(
          context: context,
          options: pickerOptions,
        );
      }

      files = ref.read(selectedSendingFilesProvider);

      if (files.isEmpty) {
        return;
      }

      if (session != null) {
        // close old session
        ref.notifier(sendProvider).closeSession(session.sessionId);
      }

      await ref
          .notifier(sendProvider)
          .startSession(
            target: device,
            files: files,
            background: true,
          );
    },
    checkedDevices: checkedDevices,
    onCheckDevice: (device, checked) {
      ref
          .notifier(multiSendCheckedDevicesProvider)
          .setState((old) => checked ? {...old, device.fingerprint} : ({...old}..remove(device.fingerprint)));
    },
    onCheckAllDevices: (checked) {
      ref.notifier(multiSendCheckedDevicesProvider).setState((_) => checked ? nearbyDevices.map((d) => d.fingerprint).toSet() : {});
    },
    onSendToCheckedDevices: (context) async {
      final targets = nearbyDevices.where((d) => checkedDevices.contains(d.fingerprint)).toList();
      if (targets.isEmpty) {
        return;
      }

      var files = ref.read(selectedSendingFilesProvider);
      if (files.isEmpty) {
        await AddFileDialog.open(
          context: context,
          options: pickerOptions,
        );
      }
      files = ref.read(selectedSendingFilesProvider);
      if (files.isEmpty) {
        return;
      }

      for (final device in targets) {
        final session = ref.read(sendProvider).values.firstWhereOrNull((s) => s.target.ip == device.ip);
        if (session != null) {
          if (session.status == SessionStatus.waiting || session.status == SessionStatus.sending) {
            // Already in progress for this device.
            continue;
          }
          ref.notifier(sendProvider).closeSession(session.sessionId);
        }

        // The sessions run in parallel; each tile shows its own progress.
        unawaited(
          ref
              .notifier(sendProvider)
              .startSession(
                target: device,
                files: files,
                background: true,
              ),
        );
      }

      ref.notifier(multiSendCheckedDevicesProvider).setState((_) => {});
    },
  );
});

/// Devices checked for sending in the multiple recipients mode (by fingerprint).
final multiSendCheckedDevicesProvider = StateProvider<Set<String>>((ref) => {});

class SendTabInitAction extends AsyncGlobalAction {
  final BuildContext context;

  SendTabInitAction(this.context);

  @override
  Future<void> reduce() async {
    final devices = ref.read(nearbyDevicesProvider).devices;
    if (devices.isEmpty) {
      await dispatchAsync(StartSmartScan());
    }
  }
}
