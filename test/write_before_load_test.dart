// Historial y favoritos se guardan por cuenta, y su lectura del disco la
// lanza `build()` sin esperarla. Una escritura que llegue en esa ventana
// computa su lista nueva a partir de un estado vacío y la escribe encima de
// la guardada.
//
// Medido el 2026-10-03: con dos conexiones guardadas, una conexión nueva
// hecha antes de que la lectura aterrizara dejó **una** entrada en disco. Lo
// mismo con los favoritos. Es el mismo fallo que se arregló en
// `VncDisplayNotifier` (6276e21), en las otras dos clases del fichero.
//
// Ninguna de estas pruebas espera a la carga antes de escribir: esa espera es
// precisamente lo que no se puede exigir a quien pulsa un botón.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAccountNotifier extends AccountNotifier {
  _FakeAccountNotifier(this._initial);
  final String? _initial;

  @override
  AccountState build() => AccountState(activeAccountEmail: _initial);

  /// Cambiar de cuenta activa como lo hace `_loadAccounts`: estado nuevo.
  void activate(String? email) => state = AccountState(activeAccountEmail: email);
}

ProviderContainer _containerFor(String? email) {
  final c = ProviderContainer(overrides: [
    accountProvider.overrideWith(() => _FakeAccountNotifier(email)),
  ]);
  addTearDown(c.dispose);
  return c;
}

String _histJson(String name) =>
    '{"instanceName":"$name","projectId":"p","zone":"z",'
    '"connectionType":"rdp","timestamp":"${DateTime.now().toIso8601String()}",'
    '"success":true}';

ConnectionHistoryEntry _entry(String name) => ConnectionHistoryEntry(
      instanceName: name,
      projectId: 'p',
      zone: 'z',
      connectionType: 'vnc',
      timestamp: DateTime.now(),
    );

Future<List<String>?> _onDisk(String key) async =>
    (await SharedPreferences.getInstance()).getStringList(key);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const yo = 'yo@example.com';
  const histKey = 'connection_history:$yo';
  const favKey = 'favorite_vms:$yo';

  group('historial', () {
    setUp(() => SharedPreferences.setMockInitialValues({
          'flutter.$histKey': [_histJson('vieja-1'), _histJson('vieja-2')],
        }));

    test('una conexión anotada antes de la carga no borra las guardadas',
        () async {
      final c = _containerFor(yo);
      c.read(connectionHistoryProvider); // primer toque, sin esperar la carga
      await c.read(connectionHistoryProvider.notifier).addEntry(_entry('nueva'));
      await pumpEventQueue();

      expect((await _onDisk(histKey))?.length, 3,
          reason: 'las dos guardadas más la nueva');
      expect(
          c.read(connectionHistoryProvider).map((e) => e.instanceName),
          containsAll(['vieja-1', 'vieja-2', 'nueva']));
    });

    test('la limpieza de antiguas antes de la carga no borra las guardadas',
        () async {
      final c = _containerFor(yo);
      c.read(connectionHistoryProvider);
      await c.read(connectionHistoryProvider.notifier).cleanupOldEntries();
      await pumpEventQueue();

      expect((await _onDisk(histKey))?.length, 2,
          reason: 'ninguna tiene 30 días, así que no se va ninguna');
    });

    test('un borrado hecho antes de la carga no se deshace al aterrizar',
        () async {
      final c = _containerFor(yo);
      c.read(connectionHistoryProvider);
      await c.read(connectionHistoryProvider.notifier).clearHistory();
      await pumpEventQueue();

      // `clearHistory` quita la clave entera, así que en disco no queda `[]`
      // sino nada.
      expect(await _onDisk(histKey), isNull);
      expect(c.read(connectionHistoryProvider), isEmpty,
          reason: 'la carga no puede resucitar lo que se acaba de borrar');
    });
  });

  group('favoritos', () {
    setUp(() => SharedPreferences.setMockInitialValues({
          'flutter.$favKey': ['p:z:vieja-1', 'p:z:vieja-2'],
        }));

    test('un favorito marcado antes de la carga no borra los guardados',
        () async {
      final c = _containerFor(yo);
      c.read(favoritesProvider);
      await c.read(favoritesProvider.notifier).toggle('p:z:nueva');
      await pumpEventQueue();

      expect(await _onDisk(favKey),
          containsAll(['p:z:vieja-1', 'p:z:vieja-2', 'p:z:nueva']));
    });

    test('quitar un favorito antes de la carga no borra los otros', () async {
      final c = _containerFor(yo);
      c.read(favoritesProvider);
      await c.read(favoritesProvider.notifier).removeFavorite('p:z:vieja-1');
      await pumpEventQueue();

      expect(await _onDisk(favKey), ['p:z:vieja-2'],
          reason: 'se va el que se quitó, se queda el otro');
    });
  });

  // La espera que arregla lo de arriba no puede romper el caso sin cuenta:
  // sin cuenta activa no hay nada que cargar, así que nadie espera una carga
  // que no existe.
  group('sin cuenta activa', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('anotar una conexión no se queda colgado ni revienta', () async {
      final c = _containerFor(null);
      c.read(connectionHistoryProvider);
      await c.read(connectionHistoryProvider.notifier).addEntry(_entry('x'));
      expect(await _onDisk('connection_history'), isNull,
          reason: 'sin cuenta no se escribe en ninguna clave');
    });

    test('marcar un favorito no se queda colgado ni revienta', () async {
      final c = _containerFor(null);
      c.read(favoritesProvider);
      await c.read(favoritesProvider.notifier).toggle('p:z:vm');
      expect(await _onDisk('favorite_vms'), isNull);
    });
  });

  // Esperar la carga mete un `await` en medio de la escritura, y por ahí
  // podría colarse un cambio de cuenta.
  //
  // Esto lo da Riverpod, no el código de aquí: medido el 2026-10-06, el
  // cambio descarta el notifier y la escritura en vuelo se cae con él, con el
  // chequeo puesto y sin él. Queda como guardia de esa propiedad, porque la
  // espera que arregla todo lo de arriba es justo lo que abre la ventana.
  test('un cambio de cuenta a mitad de escritura no mezcla las dos', () async {
    SharedPreferences.setMockInitialValues({
      'flutter.$favKey': ['p:z:mio-1'],
      'flutter.favorite_vms:otro@example.com': ['p:z:suyo-1'],
    });
    final c = _containerFor(yo);
    final fake = c.read(accountProvider.notifier) as _FakeAccountNotifier;
    c.read(favoritesProvider);

    final escritura = c.read(favoritesProvider.notifier).toggle('p:z:mio-2');
    fake.activate('otro@example.com'); // la cuenta cambia mientras escribe
    await escritura;
    await pumpEventQueue();

    expect(await _onDisk('favorite_vms:otro@example.com'), ['p:z:suyo-1'],
        reason: 'lo de una cuenta no se escribe en el fichero de la otra');
  });
}
