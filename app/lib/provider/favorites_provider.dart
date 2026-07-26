import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// This provider stores the list of favorite devices.
/// It automatically saves the list to the device's storage.
final favoritesProvider = ReduxProvider<FavoritesService, List<FavoriteDevice>>((ref) {
  return FavoritesService(ref.read(persistenceProvider));
});

class FavoritesService extends ReduxNotifier<List<FavoriteDevice>> {
  final PersistenceService _persistence;

  FavoritesService(this._persistence);

  @override
  List<FavoriteDevice> init() {
    // Merge legacy duplicates: older versions created one entry per IP,
    // so the same device (fingerprint) could be favorited multiple times.
    final result = <FavoriteDevice>[];
    final byFingerprint = <String, int>{}; // fingerprint -> index in result
    for (final favorite in _persistence.getFavorites()) {
      final index = favorite.fingerprint.isEmpty ? null : byFingerprint[favorite.fingerprint];
      if (index == null) {
        if (favorite.fingerprint.isNotEmpty) {
          byFingerprint[favorite.fingerprint] = result.length;
        }
        result.add(favorite);
      } else {
        result[index] = result[index].mergeWith(favorite);
      }
    }
    return List.unmodifiable(result);
  }
}

/// Adds a favorite device.
/// If a favorite with the same fingerprint already exists,
/// the new IP is merged into the existing entry instead.
class AddFavoriteAction extends AsyncReduxAction<FavoritesService, List<FavoriteDevice>> {
  final FavoriteDevice device;

  AddFavoriteAction(this.device);

  @override
  Future<List<FavoriteDevice>> reduce() async {
    final existingIndex =
        device.fingerprint.isEmpty ? -1 : state.indexWhere((e) => e.fingerprint == device.fingerprint);
    final List<FavoriteDevice> updated;
    if (existingIndex == -1) {
      updated = List<FavoriteDevice>.unmodifiable([
        ...state,
        device,
      ]);
    } else {
      updated = List<FavoriteDevice>.unmodifiable(
        <FavoriteDevice>[
          ...state,
        ]..replaceRange(existingIndex, existingIndex + 1, [state[existingIndex].mergeWith(device)]),
      );
    }
    await notifier._persistence.setFavorites(updated);
    return updated;
  }
}

/// Updates a favorite device.
class UpdateFavoriteAction extends AsyncReduxAction<FavoritesService, List<FavoriteDevice>> {
  final FavoriteDevice device;

  UpdateFavoriteAction(this.device);

  @override
  Future<List<FavoriteDevice>> reduce() async {
    final index = state.indexWhere((e) => e.id == device.id);
    if (index == -1) {
      // Unknown device
      await Future.microtask(() {});
      return state;
    }
    final updated = List<FavoriteDevice>.unmodifiable(
      <FavoriteDevice>[
        ...state,
      ]..replaceRange(index, index + 1, [device]),
    );
    await notifier._persistence.setFavorites(updated);
    return updated;
  }
}

/// Removes a favorite device.
class RemoveFavoriteAction extends AsyncReduxAction<FavoritesService, List<FavoriteDevice>> {
  final String deviceFingerprint;

  RemoveFavoriteAction({
    required this.deviceFingerprint,
  });

  @override
  Future<List<FavoriteDevice>> reduce() async {
    final index = state.indexWhere((e) => e.fingerprint == deviceFingerprint);
    if (index == -1) {
      // Unknown device
      return state;
    }
    final updated = List<FavoriteDevice>.unmodifiable(
      <FavoriteDevice>[
        ...state,
      ]..removeAt(index),
    );
    await notifier._persistence.setFavorites(updated);
    return updated;
  }
}
