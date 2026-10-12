import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/workspace/ssh_terminal_controller.dart';

/// Round 3, finding 1. La clave que LCC autoriza en la VM vive en el
/// directorio de datos de la app, NO en `~/.ssh`, y nada escribe un
/// `~/.ssh/config` que la nombre. Sin `-i`, el `ssh(1)` que lanza esta
/// pestaña no tiene forma de encontrarla: el usuario consiente, LCC le
/// modifica la infraestructura, `provision_ssh_access` confirma por libssh2
/// que la clave vale... y el terminal muere con `Permission denied
/// (publickey)`.
void main() {
  const knownHosts = '/home/u/.local/share/lcc/ssh_known_hosts';
  const key = '/home/u/.local/share/lightweight_cloud_connector/ssh/lcc_ed25519';

  test('la clave provisionada se presenta con -i', () {
    final args = sshArguments(
      port: 2222,
      knownHosts: knownHosts,
      username: 'ext_jordi_gmail_com',
      identityFile: key,
    );
    final i = args.indexOf('-i');
    expect(i, isNonNegative, reason: 'sin -i la clave de LCC es inalcanzable: $args');
    expect(args[i + 1], key);
  });

  /// Sin `IdentitiesOnly=yes`, `ssh` sigue ofreciendo primero las identidades
  /// del agente y puede agotar el presupuesto `MaxAuthTries` del servidor
  /// antes de llegar a la clave de `-i`.
  test('-i viaja siempre con IdentitiesOnly=yes', () {
    final args = sshArguments(
      port: 2222,
      knownHosts: knownHosts,
      username: 'u',
      identityFile: key,
    );
    expect(args.contains('-i'), isTrue);
    expect(args.contains('IdentitiesOnly=yes'), isTrue,
        reason: 'el agente puede agotar MaxAuthTries antes de la clave de -i: $args');
  });

  /// Cuando quien autenticó fue el agente no hay fichero que presentar, y
  /// forzar `IdentitiesOnly` rompería precisamente ese caso.
  test('sin clave validada no se toca la configuración por defecto de ssh', () {
    final args = sshArguments(port: 2222, knownHosts: knownHosts, username: 'u');
    expect(args.contains('-i'), isFalse, reason: args.toString());
    expect(args.contains('IdentitiesOnly=yes'), isFalse, reason: args.toString());
    expect(args.last, 'u@localhost');
  });

  /// El destino tiene que seguir siendo el último argumento: `ssh` interpreta
  /// todo lo que va después como el comando a ejecutar en la VM.
  test('el destino sigue siendo el último argumento', () {
    final args = sshArguments(
      port: 22,
      knownHosts: knownHosts,
      username: 'u',
      identityFile: key,
    );
    expect(args.last, 'u@localhost');
  });
}
