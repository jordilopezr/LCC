// El historial y los favoritos de antes del reparto por cuenta se entregan a
// la cuenta activa, como ya se hacía con los proyectos.
//
// Al partirlos por cuenta se decidió no atribuirlos — "de quién eran no se
// puede saber, así que no se le dan a nadie" — y el precio medido en la
// máquina del usuario el 2026-10-06 fue cuatro conexiones y un favorito en
// disco que la app ya no mostraba nunca. Se entregan a quien esté dentro
// cuando llega la actualización, que es la misma apuesta que hace
// `migrateProjectsToAccount`.
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
}

ProviderContainer _containerFor(String? email) {
  final c = ProviderContainer(overrides: [
    accountProvider.overrideWith(() => _FakeAccountNotifier(email)),
  ]);
  addTearDown(c.dispose);
  return c;
}

/// Una conexión como las que hay en disco de verdad.
String _hist(String vm, String when, {String type = 'vnc'}) =>
    '{"instanceName":"$vm","projectId":"p","zone":"z",'
    '"connectionType":"$type","timestamp":"$when","success":true}';

String _recent(int daysAgo) =>
    DateTime.now().subtract(Duration(days: daysAgo)).toIso8601String();

Future<void> _settle(ProviderContainer c) async {
  c.read(favoritesProvider);
  c.read(connectionHistoryProvider);
  await pumpEventQueue();
}

Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const yo = 'yo@example.com';
  const otro = 'otro@example.com';

  group('historial', () {
    // La forma real medida en disco: la misma VM en las dos listas, con horas
    // distintas, más conexiones que solo están en la global.
    setUp(() => SharedPreferences.setMockInitialValues({
          'flutter.connection_history': [
            _hist('application-server', _recent(5)),
            _hist('gateway-01', _recent(8), type: 'ssh'),
          ],
          'flutter.connection_history:$yo': [
            _hist('application-server', _recent(9)),
          ],
        }));

    test('las conexiones de antes del reparto aparecen para la cuenta activa',
        () async {
      final c = _containerFor(yo);
      await _settle(c);

      expect(c.read(connectionHistoryProvider).map((e) => e.instanceName),
          containsAll(['application-server', 'gateway-01']));
    });

    test('una VM que está en las dos listas no sale dos veces, y gana la nueva',
        () async {
      final c = _containerFor(yo);
      await _settle(c);

      final appServer = c
          .read(connectionHistoryProvider)
          .where((e) => e.instanceName == 'application-server');
      expect(appServer.length, 1, reason: 'una entrada por VM, como addEntry');
      expect(appServer.single.timestamp.isAfter(DateTime.now().subtract(const Duration(days: 7))),
          isTrue, reason: 'se queda la conexión más reciente de las dos');
    });

    test('la lista global se entrega, no se copia: una segunda cuenta no la hereda',
        () async {
      await _settle(_containerFor(yo));
      expect((await _prefs).getStringList('connection_history'), isNull,
          reason: 'entregada, así que ya no está para nadie más');

      final b = _containerFor(otro);
      await _settle(b);
      expect(c2(b), isEmpty, reason: 'la segunda cuenta empieza limpia');
    });

    test('entregarla dos veces no duplica nada', () async {
      await _settle(_containerFor(yo));
      final primera = (await _prefs).getStringList('connection_history:$yo')!.length;

      await _settle(_containerFor(yo)); // segundo arranque
      expect((await _prefs).getStringList('connection_history:$yo')!.length,
          primera);
    });
  });

  group('favoritos', () {
    setUp(() => SharedPreferences.setMockInitialValues({
          'flutter.favorite_vms': ['p:z:backupmig'],
        }));

    test('la VM marcada antes del reparto sigue marcada', () async {
      final c = _containerFor(yo);
      await _settle(c);

      expect(c.read(favoritesProvider), contains('p:z:backupmig'));
      expect((await _prefs).getStringList('favorite_vms'), isNull,
          reason: 'entregada, no copiada');
    });

    test('se une a lo que la cuenta ya tenía, sin perder ninguno', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.favorite_vms': ['p:z:backupmig'],
        'flutter.favorite_vms:$yo': ['p:z:mio'],
      });
      final c = _containerFor(yo);
      await _settle(c);

      expect(c.read(favoritesProvider), {'p:z:backupmig', 'p:z:mio'});
    });
  });

  group('sin cuenta activa', () {
    setUp(() => SharedPreferences.setMockInitialValues({
          'flutter.connection_history': [_hist('vm', _recent(1))],
          'flutter.favorite_vms': ['p:z:vm'],
        }));

    test('no se entrega nada, y las listas viejas siguen ahí para luego',
        () async {
      await _settle(_containerFor(null));

      final p = await _prefs;
      expect(p.getStringList('connection_history'), isNotNull);
      expect(p.getStringList('favorite_vms'), isNotNull);
    });
  });

  // Las dos mitades van juntas, pase lo que pase.
  //
  // La entrega vivía en la carga de cada provider, así que solo ocurría
  // cuando algo en pantalla leía ese provider. Medido en una máquina real el
  // 2026-10-12: el panel de VMs lee los favoritos al abrir, pero el historial
  // no se lee hasta que abres su vista, así que la estrella se entregó a una
  // cuenta y el historial se quedó esperando — y se lo habría llevado la
  // cuenta que estuviera activa al abrir esa vista, que puede ser otra.
  group('las dos mitades no se separan', () {
    setUp(() => SharedPreferences.setMockInitialValues({
          'flutter.connection_history': [_hist('vm-vieja', _recent(2))],
          'flutter.favorite_vms': ['p:z:estrella-vieja'],
        }));

    test('tocar solo los favoritos entrega también el historial', () async {
      final c = _containerFor(yo);
      c.read(favoritesProvider); // el historial no se lee en ningún momento
      await pumpEventQueue();

      final p = await _prefs;
      expect(p.getStringList('connection_history'), isNull,
          reason: 'la lista global del historial también se entrega');
      expect(p.getStringList('connection_history:$yo'), hasLength(1));
    });

    test('tocar solo el historial entrega también los favoritos', () async {
      final c = _containerFor(yo);
      c.read(connectionHistoryProvider); // los favoritos no se leen
      await pumpEventQueue();

      final p = await _prefs;
      expect(p.getStringList('favorite_vms'), isNull);
      expect(p.getStringList('favorite_vms:$yo'), ['p:z:estrella-vieja']);
    });
  });
}

List<String> c2(ProviderContainer c) =>
    c.read(connectionHistoryProvider).map((e) => e.instanceName).toList();
