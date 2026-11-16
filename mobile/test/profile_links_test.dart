import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/constants.dart';
import 'package:mobile/core/profile_links.dart';

void main() {
  group('usernameFrom', () {
    test('reads both link forms', () {
      expect(
        ProfileLinks.usernameFrom(
          Uri.parse('https://elephant.commandlinecoding.in/u/Alex.4821'),
        ),
        'alex.4821',
      );
      expect(
        ProfileLinks.usernameFrom(Uri.parse('elephant://u/alex.4821')),
        'alex.4821',
      );
    });

    test('ignores anything that isn\'t a profile link', () {
      for (final link in [
        'https://evil.example/u/alex.4821',
        'http://elephant.commandlinecoding.in/u/alex.4821',
        'https://elephant.commandlinecoding.in/api/auth/callback',
        'https://elephant.commandlinecoding.in/u/alex.4821/extra',
        'elephant://oauth-callback?token=x',
        'elephant://u/',
        'elephant://u/alex',
        'elephant://u/a_b.1234',
      ]) {
        expect(
          ProfileLinks.usernameFrom(Uri.parse(link)),
          isNull,
          reason: link,
        );
      }
    });
  });

  test('the shared link uses https only on Elephant Cloud', () {
    final host = Env.host, port = Env.port;
    addTearDown(() {
      Env.host = host;
      Env.port = port;
    });

    Env.host = Env.defaultHost;
    Env.port = Env.defaultPort;
    expect(
      ProfileLinks.linkFor('alex.4821').toString(),
      'https://elephant.commandlinecoding.in/u/alex.4821',
    );

    Env.host = 'chat.example.org';
    expect(
      ProfileLinks.linkFor('alex.4821').toString(),
      'elephant://u/alex.4821',
    );
  });

  test('opening a profile link queues it until someone is signed in', () {
    final links = ProfileLinks.instance;
    addTearDown(() => links.pending.value = null);
    expect(links.open(Uri.parse('https://example.com')), isFalse);
    expect(links.pending.value, isNull);
    expect(links.open(Uri.parse('elephant://u/alex.4821')), isTrue);
    expect(links.pending.value, 'alex.4821');
  });
}
