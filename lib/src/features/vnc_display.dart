/// The VNC display each VM serves on, remembered between runs.
///
/// A VNC server's display number and its TCP port are the same fact written
/// two ways: display `:1` listens on 5901. The UI asks for the display because
/// that is what you typed when you started the server (`vncserver :1`) and
/// what the client shows you; everything below the UI works in ports.
///
/// Until this existed the port was the constant 5900, so a VM serving `:1` was
/// simply unreachable from the app with no way to say otherwise.
library;

import 'dart:convert';

/// Port 5900 is display `:0`; every display after it counts up from there.
const int _vncBasePort = 5900;

/// Displays above this are refused. Nobody runs `:100`, and the number that
/// people WILL type here is a port — 5901 — which this rejects for them.
const int _maxVncDisplay = 99;

/// The TCP port a VNC display serves on.
int vncPortForDisplay(int display) => _vncBasePort + display;

/// Read a display number the user typed, or `null` if it is not one.
///
/// Rejecting `5901` is the point, not a side effect: this field replaced a
/// hardcoded port, so it invites exactly that answer. Accepted, it would
/// tunnel to 11801 and fail with an error about the wrong thing entirely.
int? parseVncDisplay(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final display = int.tryParse(text);
  if (display == null) return null;
  if (display < 0 || display > _maxVncDisplay) return null;
  return display;
}

/// The display stored for `vmKey`, or 0 — which is port 5900, the behaviour
/// this app had before any of this existed.
int vncDisplayFor(Map<String, int> displays, String vmKey) =>
    displays[vmKey] ?? 0;

/// `displays` with `vmKey` set to `display`, as a new map.
Map<String, int> withVncDisplay(
  Map<String, int> displays,
  String vmKey,
  int display,
) =>
    {...displays, vmKey: display};

/// The stored form. JSON rather than a packed string so that a human opening
/// the preferences file can read it, and fix it.
String encodeVncDisplays(Map<String, int> displays) => jsonEncode(displays);

/// Read the stored form, tolerating anything.
///
/// Nothing here is worth failing a VNC launch over: the worst case of reading
/// badly is that the user re-types a display number. So a truncated file, a
/// shape from some future version, or a value outside the range the field
/// enforces all read as "not configured" rather than as an error — and an
/// out-of-range number on disk is discarded rather than trusted, because the
/// rule the field applies has to hold on the way in too.
Map<String, int> decodeVncDisplays(String? stored) {
  if (stored == null || stored.trim().isEmpty) return {};
  final Object? decoded;
  try {
    decoded = jsonDecode(stored);
  } catch (_) {
    return {};
  }
  if (decoded is! Map) return {};

  final displays = <String, int>{};
  decoded.forEach((key, value) {
    if (key is! String || value is! int) return;
    if (value < 0 || value > _maxVncDisplay) return;
    displays[key] = value;
  });
  return displays;
}

/// Key for one VM, matching `ProjectAwareInstance.uniqueKey`.
String vncVmKey(String projectId, String zone, String instanceName) =>
    '$projectId:$zone:$instanceName';
