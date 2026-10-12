import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// History and favorites belong to an account. Both were global lists: a newly
/// signed-in account was shown the VMs and projects another account had
/// connected to or starred.
class _FakeAccountNotifier extends AccountNotifier {
  _FakeAccountNotifier(this._initial);
  final String? _initial;

  @override
  AccountState build() => AccountState(activeAccountEmail: _initial);

  /// Switch the active account the way `_loadAccounts` does: a whole new state.
  void activate(String? email) => state = AccountState(activeAccountEmail: email);
}

ProviderContainer _containerFor(String? email) {
  final container = ProviderContainer(overrides: [
    accountProvider.overrideWith(() => _FakeAccountNotifier(email)),
  ]);
  addTearDown(container.dispose);
  return container;
}

ConnectionHistoryEntry _entry(String instance, String project) =>
    ConnectionHistoryEntry(
      instanceName: instance,
      projectId: project,
      zone: 'southamerica-west1-a',
      connectionType: 'vnc',
      timestamp: DateTime.now(),
    );

/// Read both providers so they build, then let their async loads land.
Future<void> _settle(ProviderContainer c) async {
  c.read(favoritesProvider);
  c.read(connectionHistoryProvider);
  await pumpEventQueue();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      // The global lists found on disk, left by a previous account.
      'flutter.favorite_vms': ['project-shared-backup:southamerica-west1-c:backupmig'],
      'flutter.connection_history': [
        '{"instanceName":"vbr-server-01","projectId":"project-shared-backup",'
            '"zone":"southamerica-west1-a","connectionType":"rdp",'
            '"timestamp":"${DateTime.now().toIso8601String()}","success":true}',
      ],
    });
  });

  // Esto afirmaba lo contrario: que las listas globales no se le daban a
  // nadie. El usuario revirtió esa decisión el 2026-10-06, porque el precio
  // medido en su máquina fueron cuatro conexiones y un favorito en disco que
  // la app ya no mostraba nunca. Se entregan a quien esté dentro cuando llega
  // la actualización. El detalle de la entrega está en
  // legacy_lists_handed_to_account_test.dart.
  test('una cuenta nueva hereda el historial y los favoritos de antes',
      () async {
    final c = _containerFor('new@example.com');
    await _settle(c);

    expect(c.read(favoritesProvider), isNotEmpty);
    expect(c.read(connectionHistoryProvider), isNotEmpty);
  });

  test('lo que guarda una cuenta no lo ve otra, y la suya lo recupera', () async {
    final a = _containerFor('a@example.com');
    await _settle(a);
    await a.read(favoritesProvider.notifier).toggle('p-a:z:vm-a');
    await a.read(connectionHistoryProvider.notifier).addEntry(_entry('vm-a', 'p-a'));

    final b = _containerFor('b@example.com');
    await _settle(b);
    expect(b.read(favoritesProvider), isEmpty);
    expect(b.read(connectionHistoryProvider), isEmpty);

    final aAgain = _containerFor('a@example.com');
    await _settle(aAgain);
    // Lo suyo, más lo que heredó de antes del reparto. Sin orden exigido: las
    // dos conexiones llevan la hora de ahora y el orden entre ellas no está
    // definido.
    expect(aAgain.read(favoritesProvider), contains('p-a:z:vm-a'));
    expect(
      aAgain.read(connectionHistoryProvider).map((e) => e.instanceName),
      contains('vm-a'),
    );
  });

  test('al cambiar de cuenta en caliente se recargan los de la nueva', () async {
    final a = _containerFor('a@example.com');
    await _settle(a);
    await a.read(favoritesProvider.notifier).toggle('p-a:z:vm-a');
    await a.read(connectionHistoryProvider.notifier).addEntry(_entry('vm-a', 'p-a'));

    (a.read(accountProvider.notifier) as _FakeAccountNotifier)
        .activate('b@example.com');
    await _settle(a);

    expect(a.read(favoritesProvider), isEmpty);
    expect(a.read(connectionHistoryProvider), isEmpty);
  });

  test('sin cuenta activa no se lee ni se escribe nada', () async {
    final c = _containerFor(null);
    await _settle(c);
    expect(c.read(favoritesProvider), isEmpty);
    expect(c.read(connectionHistoryProvider), isEmpty);

    await c.read(favoritesProvider.notifier).toggle('p:z:vm');
    await c.read(connectionHistoryProvider.notifier).addEntry(_entry('vm', 'p'));

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().where(
          (k) => k.startsWith('favorite_vms') || k.startsWith('connection_history')),
      {'favorite_vms', 'connection_history'},
      reason: 'only the untouched legacy keys; nothing written for no account',
    );
    expect(prefs.getStringList('favorite_vms'),
        ['project-shared-backup:southamerica-west1-c:backupmig']);
  });
}
