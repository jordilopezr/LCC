import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linux_cloud_connector/src/version.dart';

/// Whether LCC checks GitHub for new releases on its own. On by default; a
/// manual "check now" works either way.
final updateCheckEnabledProvider =
    NotifierProvider<UpdateCheckEnabledNotifier, bool>(
        UpdateCheckEnabledNotifier.new);

class UpdateCheckEnabledNotifier extends Notifier<bool> {
  static const _prefsKey = 'update_check_enabled';

  /// The read of the stored value, started by [build]. The checker waits on
  /// it before its first request, so that a user who turned checking off is
  /// not checked for once on every start while the read is in flight.
  late Future<void> loaded;

  @override
  bool build() {
    loaded = _load();
    return true;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_prefsKey) ?? true;
  }

  Future<void> setEnabled(bool enabled) async {
    await loaded;
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, enabled);
  }
}

/// The channel the user is offered releases from.
///
/// Until the user picks one, it is the installed build's channel, and stays
/// so across upgrades: nothing is stored, so whoever moves from a preview to
/// a stable build moves to the stable channel with it.
final updateChannelProvider =
    NotifierProvider<UpdateChannelNotifier, ReleaseChannel>(
        UpdateChannelNotifier.new);

class UpdateChannelNotifier extends Notifier<ReleaseChannel> {
  static const _prefsKey = 'update_channel';

  late Future<void> loaded;

  @override
  ReleaseChannel build() {
    loaded = _load();
    return kChannel;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = parseUpdateChannel(prefs.getString(_prefsKey)) ?? kChannel;
  }

  Future<void> setChannel(ReleaseChannel channel) async {
    await loaded;
    state = channel;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, channel.name);
  }
}

/// A stored channel name, or null for none or one this version does not know.
ReleaseChannel? parseUpdateChannel(String? name) {
  for (final channel in ReleaseChannel.values) {
    if (channel.name == name) return channel;
  }
  return null;
}
