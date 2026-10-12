import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';

enum TerminalPhase { connectingTunnel, launching, connected, disconnected, error }

/// The argv handed to `ssh(1)` for one terminal tab.
///
/// A free function so it can be asserted on without spawning a process: the
/// `-i` it may add is the difference between a working session and
/// `Permission denied (publickey)` on every VM LCC has just provisioned, and
/// that is worth a regression guard.
///
/// [identityFile] is the key that already authenticated against this VM (see
/// [SshTerminalController.identityFile]). `IdentitiesOnly=yes` travels with
/// it and is not cosmetic: given `-i` alone, `ssh` still offers every agent
/// identity first, and a user holding a few of them can exhaust the server's
/// `MaxAuthTries` budget before the key named by `-i` is ever tried.
List<String> sshArguments({
  required int port,
  required String knownHosts,
  required String username,
  String? identityFile,
}) =>
    [
      '-p', '$port',
      '-o', 'StrictHostKeyChecking=accept-new',
      '-o', 'UserKnownHostsFile=$knownHosts',
      if (identityFile != null) ...['-i', identityFile, '-o', 'IdentitiesOnly=yes'],
      '$username@localhost',
    ];

/// Owns the xterm Terminal + the ssh PTY for one SSH tab. Given a function that
/// establishes (or reuses) the IAP tunnel and returns the local port, it spawns
/// `ssh` over that port and streams both directions.
class SshTerminalController {
  final String username;
  final String instanceName;

  /// The key file to present, from [SshAccessGranted.keyPath].
  ///
  /// Without it this tab could never work on a freshly provisioned VM: the
  /// key LCC authorises lives in the app's data directory, not in `~/.ssh`,
  /// and nothing writes an `~/.ssh/config` entry for it — so the `ssh(1)`
  /// spawned below has no way to find it and the session dies with
  /// `Permission denied (publickey)` moments after the user was told their
  /// key had been authorised. Null means the SSH agent authenticated during
  /// the probe, and `ssh` should be left to its own defaults.
  final String? identityFile;
  final Future<int?> Function() ensureTunnel;

  final Terminal terminal = Terminal(maxLines: 10000);
  final ValueNotifier<TerminalPhase> phaseNotifier =
      ValueNotifier(TerminalPhase.connectingTunnel);
  String? errorDetail;

  Pty? _pty;
  StreamSubscription<String>? _outputSubscription;
  bool _disposed = false;

  SshTerminalController({
    required this.username,
    required this.instanceName,
    required this.ensureTunnel,
    this.identityFile,
  });

  TerminalPhase get phase => phaseNotifier.value;
  void _setPhase(TerminalPhase v) {
    if (_disposed) return;
    phaseNotifier.value = v;
  }

  Future<void> start() async {
    errorDetail = null;
    _setPhase(TerminalPhase.connectingTunnel);
    try {
      final port = await ensureTunnel();
      if (_disposed) return;
      if (port == null) {
        errorDetail = 'Tunnel could not be established';
        _setPhase(TerminalPhase.error);
        return;
      }
      _setPhase(TerminalPhase.launching);

      final support = await getApplicationSupportDirectory();
      if (_disposed) return;
      final knownHosts = p.join(support.path, 'ssh_known_hosts');

      final pty = Pty.start(
        'ssh',
        arguments: sshArguments(
          port: port,
          knownHosts: knownHosts,
          username: username,
          identityFile: identityFile,
        ),
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      if (_disposed) {
        // dispose() ran while we were awaiting the tunnel/support dir, so it
        // could not kill a pty that did not exist yet. Kill this one now,
        // otherwise the ssh child process leaks.
        pty.kill();
        return;
      }
      _pty = pty;

      _outputSubscription = pty.output
          .cast<List<int>>()
          .transform(const Utf8Decoder())
          .listen(terminal.write);
      terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
      terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);

      pty.exitCode.then((_) {
        if (_disposed || !identical(_pty, pty)) return;
        if (phase != TerminalPhase.error) _setPhase(TerminalPhase.disconnected);
      });

      _setPhase(TerminalPhase.connected);
    } catch (e) {
      errorDetail = e.toString();
      _setPhase(TerminalPhase.error);
    }
  }

  void reconnect() {
    _outputSubscription?.cancel();
    _outputSubscription = null;
    _pty?.kill();
    _pty = null;
    start();
  }

  void dispose() {
    _disposed = true;
    _outputSubscription?.cancel();
    _outputSubscription = null;
    _pty?.kill();
    _pty = null;
    phaseNotifier.dispose();
  }
}
