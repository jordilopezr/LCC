import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/connectivity_doctor.dart';

void main() {
  group('consoleUrlIn', () {
    // La ruta sin gcloud llega pegada al remedio de siempre. Si no se puede
    // extraer, el panel no puede ofrecerla como algo pulsable y al usuario sin
    // gcloud le queda transcribirla a mano.
    test('finds the console route Rust appended to a remedy', () {
      const details =
          'The VM is not running.\n\nWithout gcloud: https://console.cloud.google.com/compute/instances?project=demo';
      expect(
        consoleUrlIn(details),
        'https://console.cloud.google.com/compute/instances?project=demo',
      );
    });

    test('finds it when the remedy had no other details', () {
      expect(
        consoleUrlIn('Without gcloud: https://console.cloud.google.com/apis'),
        'https://console.cloud.google.com/apis',
      );
    });

    // Los remedios que no ofrecen consola no deben pintar botones muertos.
    test('returns null when there is no console route', () {
      expect(consoleUrlIn(null), isNull);
      expect(consoleUrlIn('Install the Google Cloud SDK from https://cloud.google.com/sdk'), isNull);
    });

    // La puntuación final de una frase no puede acabar dentro de la URL.
    test('does not swallow trailing sentence punctuation', () {
      expect(
        consoleUrlIn('See https://console.cloud.google.com/iam-admin.'),
        'https://console.cloud.google.com/iam-admin',
      );
    });
  });
}
