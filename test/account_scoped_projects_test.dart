import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The workspace's project selection belongs to an account. A global
/// `selected_project_ids` left by the previous account was loaded for a newly
/// signed-in one: its dashboard asked Google for ten projects it cannot see
/// (403/404 on every one) and never showed its own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      // What the previous account left behind, exactly as found on disk.
      'flutter.selected_project_ids': ['ccusa-proy-gcve-prd', 'xoon-473720'],
      'flutter.account_project_map':
          'old%40example.com=ccusa-proy-gcve-prd,xoon-473720;'
              'other%40example.com=lcc-app-505403',
    });
    await StorageService().init();
  });

  test('una cuenta sin selección propia empieza vacía, no hereda la global', () {
    expect(
      StorageService().getSelectedProjectsForAccount('new@example.com'),
      isEmpty,
    );
  });

  test('sin cuenta activa no hay selección', () {
    expect(StorageService().getSelectedProjectsForAccount(null), isEmpty);
  });

  test('cada cuenta recupera solo sus proyectos', () {
    expect(
      StorageService().getSelectedProjectsForAccount('old@example.com'),
      ['ccusa-proy-gcve-prd', 'xoon-473720'],
    );
    expect(
      StorageService().getSelectedProjectsForAccount('other@example.com'),
      ['lcc-app-505403'],
    );
  });
}
