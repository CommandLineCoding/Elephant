import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/core/backup_codec.dart';
import 'package:mobile/pages/settings/backup_page.dart';
import 'package:mobile/services/backup.dart';
import 'package:mobile/services/backup_files.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:provider/provider.dart';

import 'chat_harness.dart';

const cost = BackupCost.testing;

class MemoryStore implements BackupStore {
  BackupTables tables;
  bool failing = false;
  int replaced = 0;

  MemoryStore([BackupTables? tables]) : tables = tables ?? {};

  @override
  Future<BackupTables> dump() async => tables;

  @override
  Future<void> replaceAll(BackupTables next) async {
    if (failing) throw StateError('disk full');
    replaced++;
    tables = next;
  }
}

BackupTables sample() => {
  'messages': [
    {'id': 'm1', 'chat_id': 'u2', 'content': 'a secret plan'},
    {'id': 'm2', 'chat_id': 'u2', 'content': 'and another'},
  ],
  'inbox': [
    {'id': 'u2', 'title': 'Bob'},
  ],
  'contact_nicknames': [
    {'user_id': 'u2', 'nickname': 'Bobby'},
  ],
};

class FakeFiles implements BackupFiles {
  Uint8List? picked;
  final List<(String, Uint8List)> saved = [];
  bool cancelSave = false;

  @override
  Future<bool> save(String fileName, Uint8List bytes) async {
    if (cancelSave) return false;
    saved.add((fileName, bytes));
    return true;
  }

  @override
  Future<Uint8List?> pick() async => picked;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('the passphrase', () {
    test('is 30 digits in six groups of five', () {
      final p = BackupCodec.generatePassphrase();
      expect(RegExp(r'^(\d{5} ){5}\d{5}$').hasMatch(p), isTrue, reason: p);
    });

    test('is different each time, and follows its random source', () {
      expect(
        BackupCodec.generatePassphrase(),
        isNot(BackupCodec.generatePassphrase()),
      );
      expect(
        BackupCodec.generatePassphrase(Random(1)),
        BackupCodec.generatePassphrase(Random(1)),
      );
      expect(
        BackupCodec.generatePassphrase(Random(1)),
        isNot(BackupCodec.generatePassphrase(Random(2))),
      );
    });

    test('spaces and dashes only make it easier to read', () {
      expect(
        BackupCodec.normalize('12345 67890-11111\n'),
        '1234567890'
        '11111',
      );
    });
  });

  group('the file', () {
    final snapshot = {
      'note': 'a secret plan',
      'list': [1, 2, 3],
    };

    test('opens with the passphrase it was locked with', () async {
      final file = await BackupCodec.seal(snapshot, '12345 67890', cost: cost);
      expect(await BackupCodec.open(file, '12345 67890'), snapshot);
      expect(await BackupCodec.open(file, '12345-67890'), snapshot);
      expect(await BackupCodec.open(file, '1234567890'), snapshot);
    });

    test('does not show what is in it', () async {
      final file = await BackupCodec.seal(snapshot, 'pass', cost: cost);
      expect(
        utf8.decode(file, allowMalformed: true),
        isNot(contains('secret')),
      );
      expect(String.fromCharCodes(file.sublist(0, 7)), BackupCodec.magic);
    });

    test('is different every time, from a fresh salt and nonce', () async {
      final a = await BackupCodec.seal(snapshot, 'pass', cost: cost);
      final b = await BackupCodec.seal(snapshot, 'pass', cost: cost);
      expect(a, isNot(b));
      expect(a.sublist(11, 39), isNot(b.sublist(11, 39)));
    });

    Future<void> expectProblem(
      Future<Object?> Function() open,
      BackupProblem problem,
    ) async {
      try {
        await open();
        fail('expected $problem');
      } on BackupException catch (e) {
        expect(e.problem, problem);
      }
    }

    test('refuses a wrong passphrase', () async {
      final file = await BackupCodec.seal(snapshot, '11111', cost: cost);
      await expectProblem(
        () => BackupCodec.open(file, '22222'),
        BackupProblem.wrongPassphrase,
      );
      await expectProblem(
        () => BackupCodec.open(file, ''),
        BackupProblem.wrongPassphrase,
      );
    });

    test('refuses a file that was changed', () async {
      final file = await BackupCodec.seal(snapshot, '11111', cost: cost);
      // Anywhere in the contents, its tag, its salt or its settings.
      for (final at in [file.length - 1, file.length - 20, 20, 11, 30]) {
        final bad = Uint8List.fromList(file)..[at] ^= 1;
        await expectProblem(
          () => BackupCodec.open(bad, '11111'),
          BackupProblem.wrongPassphrase,
        );
      }
    });

    test(
      'refuses settings that were changed to others that are valid',
      () async {
        final file = await BackupCodec.seal(snapshot, '11111', cost: cost);
        // Cheaper scrypt would be a weaker lock, so the settings are signed.
        final bad = Uint8List.fromList(file)..[9] = 2;
        try {
          await BackupCodec.open(bad, '11111');
          fail('opened');
        } on BackupException catch (e) {
          expect(e.problem, BackupProblem.wrongPassphrase);
        }
      },
    );

    test('refuses what is not a backup', () async {
      final file = await BackupCodec.seal(snapshot, '11111', cost: cost);
      await expectProblem(
        () => BackupCodec.open(Uint8List(0), '1'),
        BackupProblem.notABackup,
      );
      await expectProblem(
        () => BackupCodec.open(file.sublist(0, 30), '11111'),
        BackupProblem.notABackup,
      );
      await expectProblem(
        () => BackupCodec.open(
          Uint8List.fromList(utf8.encode('{"a":1}' * 20)),
          '1',
        ),
        BackupProblem.notABackup,
      );
      final wrongMagic = Uint8List.fromList(file)..[0] = 0x58;
      await expectProblem(
        () => BackupCodec.open(wrongMagic, '11111'),
        BackupProblem.notABackup,
      );
    });

    test('says when it is from a newer app', () async {
      final file = await BackupCodec.seal(snapshot, '11111', cost: cost);
      final newer = Uint8List.fromList(file)..[7] = BackupCodec.version + 1;
      await expectProblem(
        () => BackupCodec.open(newer, '11111'),
        BackupProblem.tooNew,
      );
    });

    test('does not let a damaged header ask for the moon', () async {
      final file = await BackupCodec.seal(snapshot, '11111', cost: cost);
      for (final (at, value) in [
        (8, 40),
        (8, 0),
        (9, 200),
        (9, 0),
        (10, 0),
        (8, 22),
      ]) {
        final bad = Uint8List.fromList(file)..[at] = value;
        await expectProblem(
          () => BackupCodec.open(bad, '11111'),
          BackupProblem.notABackup,
        );
      }
    });
  });

  group('the service', () {
    Future<(BackupService, MemoryStore, Uint8List)> made({
      String userId = 'ME-1',
    }) async {
      final store = MemoryStore(sample());
      final service = BackupService(store: store, cost: cost);
      final file = await service.create(userId: userId, passphrase: '12345');
      return (service, store, file);
    }

    test('puts the chats back after they are gone', () async {
      final (service, store, file) = await made();
      store.tables = {};
      final summary = await service.restore(file, '12345', userId: 'me-1');
      expect(store.tables['messages'], hasLength(2));
      expect(store.tables['contact_nicknames']!.single['nickname'], 'Bobby');
      expect(summary.messages, 2);
      expect(summary.chats, 1);
    });

    test('replaces what is on the phone, not adds to it', () async {
      final (service, store, file) = await made();
      store.tables = {
        'messages': [
          {'id': 'new', 'chat_id': 'x', 'content': 'written since'},
        ],
        'call_log': [
          {'id': 'c'},
        ],
      };
      await service.restore(file, '12345', userId: 'me-1');
      expect(store.tables['messages']!.map((m) => m['id']), ['m1', 'm2']);
      expect(store.tables.containsKey('call_log'), isFalse);
    });

    test('leaves everything alone if the passphrase is wrong', () async {
      final (service, store, file) = await made();
      await expectLater(
        service.restore(file, '99999', userId: 'me-1'),
        throwsA(isA<BackupException>()),
      );
      expect(store.replaced, 0);
    });

    test('will not put another account\'s chats on this phone', () async {
      final (service, store, file) = await made(userId: 'someone-else');
      try {
        await service.restore(file, '12345', userId: 'me-1');
        fail('should refuse');
      } on BackupException catch (e) {
        expect(e.problem, BackupProblem.otherAccount);
      }
      expect(store.replaced, 0);
    });

    Future<Uint8List> forged(Map<String, Object?> snapshot) =>
        BackupCodec.seal(snapshot, '12345', cost: cost);

    test('refuses a file that opens but is not a chat backup', () async {
      final service = BackupService(store: MemoryStore(), cost: cost);
      for (final snapshot in <Map<String, Object?>>[
        {'hello': 'world'},
        {'app': 'other', 'format': 1, 'user_id': 'me-1', 'tables': {}},
        {'app': 'elephant', 'format': 1, 'user_id': 'me-1', 'tables': 'x'},
        {'app': 'elephant', 'format': 1, 'tables': {}},
        {
          'app': 'elephant',
          'format': 1,
          'user_id': 'me-1',
          'tables': {
            'messages': [
              {
                'id': 'm',
                'content': {'nested': 'object'},
              },
            ],
          },
        },
        {
          'app': 'elephant',
          'format': 1,
          'user_id': 'me-1',
          'tables': {'messages': 'not rows'},
        },
      ]) {
        try {
          await service.restore(
            await forged(snapshot),
            '12345',
            userId: 'me-1',
          );
          fail('accepted $snapshot');
        } on BackupException catch (e) {
          expect(e.problem, BackupProblem.notABackup, reason: '$snapshot');
        }
      }
    });

    test('says when the format is newer', () async {
      final service = BackupService(store: MemoryStore(), cost: cost);
      try {
        await service.restore(
          await forged({
            'app': 'elephant',
            'format': 99,
            'user_id': 'me-1',
            'tables': {},
          }),
          '12345',
          userId: 'me-1',
        );
        fail('should refuse');
      } on BackupException catch (e) {
        expect(e.problem, BackupProblem.tooNew);
      }
    });

    test('ignores a table it does not know', () async {
      final store = MemoryStore();
      final service = BackupService(store: store, cost: cost);
      await service.restore(
        await forged({
          'app': 'elephant',
          'format': 1,
          'user_id': 'me-1',
          'tables': {
            'signal_identities': [
              {'x': 'y'},
            ],
            'messages': [
              {'id': 'm'},
            ],
          },
        }),
        '12345',
        userId: 'me-1',
      );
      expect(store.tables.keys, ['messages']);
    });

    test('keeps the encryption keys out of a backup', () {
      expect(backupTables.any((t) => t.startsWith('signal')), isFalse);
      expect(backupTables, isNot(contains('action_queue')));
    });
  });

  test('names the file by the day', () {
    expect(
      backupFileName(DateTime(2026, 3, 9)),
      'elephant-backup-2026-03-09.elbk',
    );
  });

  group('the empty chat list', () {
    testWidgets('offers a restore, as well as starting a chat', (tester) async {
      var restored = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: Scaffold(
            body: EmptyState(
              icon: Icons.forum_rounded,
              title: 'No conversations yet',
              message: 'Say hello.',
              actionLabel: 'Start a chat',
              onAction: () {},
              secondaryLabel: 'Restore from a backup',
              onSecondary: () => restored++,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Restore from a backup'));
      expect(restored, 1);
      expect(find.text('Start a chat'), findsOne);
    });

    testWidgets('has no second choice unless given one', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: const Scaffold(
            body: EmptyState(
              icon: Icons.forum_rounded,
              title: 'T',
              message: 'M',
            ),
          ),
        ),
      );
      expect(find.byType(TextButton), findsNothing);
    });
  });

  group('the page', () {
    late FakeFiles files;
    late MemoryStore store;
    late int reloads;

    Future<void> show(WidgetTester tester) async {
      files = FakeFiles();
      store = MemoryStore(sample());
      reloads = 0;
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthState>(
          create: (_) => TestAuth('ME-1'),
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: BackupPage(
              service: BackupService(store: store, cost: cost),
              files: files,
              onRestored: (_) async => reloads++,
            ),
          ),
        ),
      );
    }

    /// The service works on another isolate, which fake time can't wait for.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    String shownPassphrase(WidgetTester tester) {
      final text = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .single
          .data!;
      return text.replaceAll('\n', ' ');
    }

    testWidgets('says what a backup is and is not', (tester) async {
      await show(tester);
      expect(find.text('Back up now'), findsOne);
      expect(find.text('Restore from a backup'), findsOne);
      expect(find.textContaining('encryption keys are not in it'), findsOne);
    });

    testWidgets('shows the passphrase once, then saves a file it opens', (
      tester,
    ) async {
      await show(tester);
      await tester.tap(find.text('Back up now'));
      await tester.pumpAndSettle();
      final passphrase = shownPassphrase(tester);
      expect(RegExp(r'^(\d{5} ){5}\d{5}$').hasMatch(passphrase), isTrue);

      // It can't be carried on until the person says they kept it.
      FilledButton save() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Choose where to save'),
      );
      expect(save().onPressed, isNull);
      await tester.tap(find.text('I have kept it somewhere safe'));
      await tester.pump();
      expect(save().onPressed, isNotNull);
      await tester.tap(find.text('Choose where to save'));
      await tester.pump();
      await settle(tester);

      expect(files.saved, hasLength(1));
      expect(
        files.saved.single.$1,
        matches(RegExp(r'^elephant-backup-.*\.elbk$')),
      );
      final opened = await tester.runAsync(
        () => BackupCodec.open(files.saved.single.$2, passphrase),
      );
      expect((opened!['tables'] as Map)['messages'], hasLength(2));
      expect(opened['user_id'], 'me-1');
      expect(find.text('Backup saved'), findsOne);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('makes no file if the person backs out', (tester) async {
      await show(tester);
      await tester.tap(find.text('Back up now'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(files.saved, isEmpty);
    });

    testWidgets('says nothing was saved if they leave the file picker', (
      tester,
    ) async {
      await show(tester);
      files.cancelSave = true;
      await tester.tap(find.text('Back up now'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I have kept it somewhere safe'));
      await tester.pump();
      await tester.tap(find.text('Choose where to save'));
      await tester.pump();
      await settle(tester);
      expect(find.text('Backup saved'), findsNothing);
    });

    Future<Uint8List> backupFor(
      WidgetTester tester, {
      String userId = 'me-1',
    }) async {
      final bytes = await tester.runAsync(
        () => BackupService(
          store: MemoryStore(sample()),
          cost: cost,
        ).create(userId: userId, passphrase: '11111 22222'),
      );
      return bytes!;
    }

    testWidgets('restores with the passphrase, after a wrong try', (
      tester,
    ) async {
      await show(tester);
      files.picked = await backupFor(tester);
      store.tables = {};

      await tester.tap(find.text('Restore from a backup'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '99999');
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('doesn\'t open this backup'), findsOne);
      expect(store.replaced, 0);

      await tester.enterText(find.byType(TextField), '11111 22222');
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await settle(tester);
      await tester.pumpAndSettle();
      expect(store.tables['messages'], hasLength(2));
      expect(reloads, 1, reason: 'the screens are told to reload');
      expect(find.text('Restored 2 messages in 1 chat'), findsOne);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('does nothing if no file is chosen', (tester) async {
      await show(tester);
      await tester.tap(find.text('Restore from a backup'));
      await tester.pumpAndSettle();
      expect(find.text('Restore this backup'), findsNothing);
    });

    testWidgets('does nothing if the passphrase box is cancelled', (
      tester,
    ) async {
      await show(tester);
      files.picked = await backupFor(tester);
      await tester.tap(find.text('Restore from a backup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.replaced, 0);
      expect(reloads, 0);
    });

    testWidgets('explains a backup from another account', (tester) async {
      await show(tester);
      files.picked = await backupFor(tester, userId: 'someone-else');
      await tester.tap(find.text('Restore from a backup'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '11111 22222');
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('from a different account'), findsOne);
      expect(store.replaced, 0);
      expect(reloads, 0);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('says so, and changes nothing, if the file is not a backup', (
      tester,
    ) async {
      await show(tester);
      files.picked = Uint8List.fromList(utf8.encode('not a backup' * 10));
      await tester.tap(find.text('Restore from a backup'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '11111');
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('This isn\'t an Elephant backup.'), findsOne);
      expect(store.replaced, 0);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a restore that fails says nothing was changed', (
      tester,
    ) async {
      await show(tester);
      files.picked = await backupFor(tester);
      store.failing = true;
      await tester.tap(find.text('Restore from a backup'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '11111 22222');
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing was changed'), findsOne);
      expect(reloads, 0);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
