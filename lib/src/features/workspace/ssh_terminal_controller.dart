import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';

enum TerminalPhase { connectingTunnel, launching, connected, disconnected, error }

/// Owns the xterm Terminal + the ssh PTY for one SSH tab. Given a function that
/// establishes (or reuses) the IAP tunnel and returns the local port, it spawns
/// `ssh` over that port and streams both directions.
class SshTerminalController {
  final String username;
  final String instanceName;
  final Future<int?> Function() ensureTunnel;

  final Terminal terminal = Terminal(maxLines: 10000);
  final ValueNotifier<TerminalPhase> phaseNotifier =
      ValueNotifier(TerminalPhase.connectingTunnel);
  String? errorDetail;

  Pty? _pty;

  SshTerminalController({
    required this.username,
    required this.instanceName,
    required this.ensureTunnel,
  });

  TerminalPhase get phase => phaseNotifier.value;
  void _setPhase(TerminalPhase v) => phaseNotifier.value = v;

  Future<void> start() async {
    _setPhase(TerminalPhase.connectingTunnel);
    try {
      final port = await ensureTunnel();
      if (port == null) {
        errorDetail = 'Tunnel could not be established';
        _setPhase(TerminalPhase.error);
        return;
      }
      _setPhase(TerminalPhase.launching);

      final support = await getApplicationSupportDirectory();
      final knownHosts = p.join(support.path, 'ssh_known_hosts');

      final pty = Pty.start(
        'ssh',
        arguments: [
          '-p', '$port',
          '-o', 'StrictHostKeyChecking=accept-new',
          '-o', 'UserKnownHostsFile=$knownHosts',
          '$username@localhost',
        ],
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      _pty = pty;

      pty.output
          .cast<List<int>>()
          .transform(const Utf8Decoder())
          .listen(terminal.write);
      terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
      terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);

      pty.exitCode.then((_) {
        if (phase != TerminalPhase.error) _setPhase(TerminalPhase.disconnected);
      });

      _setPhase(TerminalPhase.connected);
    } catch (e) {
      errorDetail = e.toString();
      _setPhase(TerminalPhase.error);
    }
  }

  void reconnect() {
    _pty?.kill();
    _pty = null;
    start();
  }

  void dispose() {
    _pty?.kill();
    _pty = null;
    phaseNotifier.dispose();
  }
}
