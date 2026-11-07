import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/constants.dart';

void main() {
  group('Env.buildUrl', () {
    test('omits the default TLS port', () {
      expect(
        Env.buildUrl(
          host: 'chat.example',
          port: '443',
          tls: true,
          path: '/api',
        ),
        'https://chat.example/api',
      );
    });

    test('keeps TLS on a non-standard port', () {
      expect(
        Env.buildUrl(
          host: 'chat.example',
          port: '8443',
          tls: true,
          path: '/api',
        ),
        'https://chat.example:8443/api',
      );
      expect(
        Env.buildUrl(
          host: 'chat.example',
          port: '8443',
          tls: true,
          path: '/api/ws',
          ws: true,
        ),
        'wss://chat.example:8443/api/ws',
      );
    });

    test('plain HTTP omits port 80 only', () {
      expect(
        Env.buildUrl(host: '10.0.0.2', port: '80', tls: false, path: '/api'),
        'http://10.0.0.2/api',
      );
      expect(
        Env.buildUrl(host: '10.0.0.2', port: '8080', tls: false, path: '/api'),
        'http://10.0.0.2:8080/api',
      );
    });
  });
}
