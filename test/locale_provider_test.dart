import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:linux_cloud_connector/src/features/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('locale defaults to null (system) and persists override', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(localeProvider), isNull);

    await container.read(localeProvider.notifier).setLocale(const Locale('es'));
    expect(container.read(localeProvider), const Locale('es'));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_locale'), 'es');

    await container.read(localeProvider.notifier).setLocale(null);
    expect(container.read(localeProvider), isNull);
    expect(prefs.getString('app_locale'), 'system');
  });
}
