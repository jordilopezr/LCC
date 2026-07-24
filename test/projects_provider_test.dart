import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';

class _FakeAccountNotifier extends AccountNotifier {
  @override
  AccountState build() =>
      const AccountState(activeAccountEmail: 'test@example.com');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('projectsProvider propaga errores de listado en vez de lista vacía',
      () async {
    final container = ProviderContainer(overrides: [
      gcloudStatusProvider.overrideWith((ref) async => {'authenticated': true}),
      accountProvider.overrideWith(_FakeAccountNotifier.new),
    ]);
    addTearDown(container.dispose);

    // Sin el bridge Rust inicializado, listProjects() lanza. El provider debe
    // propagar ese error para que ProjectSelector muestre
    // appErrorLoadingProjects, no "No projects found" con lista vacía.
    await expectLater(
      container.read(projectsProvider.future),
      throwsA(anything),
    );
  });
}
