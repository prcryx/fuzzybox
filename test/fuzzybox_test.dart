import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuzzybox/fuzzybox.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('config_doc_box_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('FuzzyBox Core Operations', () {
    test('opens clean box and writes 16-byte header', () async {
      final box = await FuzzyBox.open(
        name: 'test_box',
        directoryPath: tempDir.path,
      );

      expect(box.length, equals(0));
      expect(box.isEmpty, isTrue);

      final file = File('${tempDir.path}/test_box.cdb');
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), equals(16));

      await box.close();
    });

    test('stores and synchronously reads primitives', () async {
      final box = await FuzzyBox.open(
        name: 'primitives_box',
        directoryPath: tempDir.path,
      );

      await box.put('str', 'hello');
      await box.put('num_int', 42);
      await box.put('num_double', 3.1415);
      await box.put('flag', true);

      expect(box.getString('str'), equals('hello'));
      expect(box.getInt('num_int'), equals(42));
      expect(box.getDouble('num_double'), closeTo(3.1415, 0.0001));
      expect(box.getBool('flag'), isTrue);
      expect(box.containsKey('str'), isTrue);
      expect(box.containsKey('non_existent'), isFalse);

      await box.close();
    });

    test(
      'supports structured nested documents and deep path resolution',
      () async {
        final box = await FuzzyBox.open(
          name: 'nested_box',
          directoryPath: tempDir.path,
        );

        await box.put('user.settings', {
          'profile': {
            'name': 'Alex Rivera',
            'tier': 'enterprise',
            'preferences': {
              'dark_mode': true,
              'notifications': {'email': true, 'push': false},
            },
          },
          'limits': {'max_projects': 50},
        });

        final doc = box.getDoc('user.settings')!;
        expect(doc.getString('profile.name'), equals('Alex Rivera'));
        expect(doc.getBool('profile.preferences.dark_mode'), isTrue);
        expect(doc.getBool('profile.preferences.notifications.push'), isFalse);
        expect(doc.getInt('limits.max_projects'), equals(50));

        await box.close();
      },
    );
  });

  group('Query Engine', () {
    late FuzzyBox box;

    setUp(() async {
      box = await FuzzyBox.open(name: 'query_box', directoryPath: tempDir.path);

      await box.put('ui.theme', {'mode': 'dark'}, tags: {'ui'});
      await box.put('ui.sidebar', {'collapsed': false}, tags: {'ui'});
      await box.put(
        'flags.v1',
        {'enabled': true, 'weight': 10},
        tags: {'flag', 'remote'},
        schema: 'Feature',
      );
      await box.put(
        'flags.v2',
        {'enabled': true, 'weight': 80},
        tags: {'flag', 'remote'},
        schema: 'Feature',
      );
      await box.put(
        'flags.beta',
        {'enabled': false, 'weight': 95},
        tags: {'flag'},
        schema: 'Feature',
      );
    });

    tearDown(() async {
      await box.close();
    });

    test('filters by key prefix', () {
      final results = box.query().whereKeyStartsWith('flags.').find();
      expect(results.length, equals(3));
      expect(
        results.map((e) => e.key),
        containsAll(['flags.v1', 'flags.v2', 'flags.beta']),
      );
    });

    test('instant inverted index lookup by tag', () {
      final uiDocs = box.getByTag('ui');
      expect(uiDocs.length, equals(2));

      final remoteFlags = box.query().whereTag('remote').find();
      expect(remoteFlags.length, equals(2));
      expect(remoteFlags.every((d) => d.tags.contains('remote')), isTrue);
    });

    test('structured property comparison queries', () {
      final highWeight = box
          .query()
          .whereSchema('Feature')
          .whereEquals('enabled', true)
          .whereGreaterThan('weight', 50)
          .find();

      expect(highWeight.length, equals(1));
      expect(highWeight.first.key, equals('flags.v2'));
    });

    test('orders and paginates query results', () {
      final sorted = box
          .query()
          .whereSchema('Feature')
          .orderBy('weight', descending: true)
          .limit(2)
          .find();

      expect(sorted.length, equals(2));
      expect(sorted[0].key, equals('flags.beta')); // weight 95
      expect(sorted[1].key, equals('flags.v2')); // weight 80
    });
  });

  group('Crash-Safety, CRC32 and Compaction', () {
    test('persists state across box close and reopen', () async {
      var box = await FuzzyBox.open(
        name: 'persistence_box',
        directoryPath: tempDir.path,
      );

      await box.put('key1', 'persisted_val', tags: {'alpha'});
      await box.put('key2', 12345);
      await box.close();

      // Re-open from disk
      box = await FuzzyBox.open(
        name: 'persistence_box',
        directoryPath: tempDir.path,
      );

      expect(box.length, equals(2));
      expect(box.getString('key1'), equals('persisted_val'));
      expect(box.getInt('key2'), equals(12345));
      expect(box.getByTag('alpha').length, equals(1));

      await box.close();
    });

    test(
      'recovers gracefully from truncated or corrupted records at EOF',
      () async {
        var box = await FuzzyBox.open(
          name: 'crash_box',
          directoryPath: tempDir.path,
        );

        await box.put('safe_key', 'safe_value');
        await box.close();

        // Append simulated corrupt / torn write bytes directly to disk
        final file = File('${tempDir.path}/crash_box.cdb');
        final corruptedBytes = Uint8List.fromList([
          StorageFormat.recordTypeUpsert,
          0x00, 0x00, 0x01, 0x00, // payload length = 256
          0xAA, 0xBB, 0xCC, 0xDD, // invalid CRC
          0x7B, 0x22, // incomplete payload truncated mid-flight
        ]);
        file.writeAsBytesSync(corruptedBytes, mode: FileMode.append);

        // Re-open box: should ignore damaged record and truncate cleanly to valid tail
        box = await FuzzyBox.open(
          name: 'crash_box',
          directoryPath: tempDir.path,
        );

        expect(box.length, equals(1));
        expect(box.getString('safe_key'), equals('safe_value'));

        // New writes succeed smoothly after recovery
        await box.put('after_recovery', true);
        expect(box.getBool('after_recovery'), isTrue);

        await box.close();
      },
    );

    test(
      'atomic compaction purges dead records and reduces file size',
      () async {
        final box = await FuzzyBox.open(
          name: 'compaction_box',
          directoryPath: tempDir.path,
          autoCompact: false,
        );

        // Repeatedly overwrite same key to create dead log records
        for (int i = 0; i < 20; i++) {
          await box.put('churn_key', 'value_iteration_$i');
        }

        var stats = await box.getStats();
        expect(stats.deadRecords, equals(19));
        final sizeBefore = stats.fileSizeBytes;

        await box.compact();

        stats = await box.getStats();
        expect(stats.deadRecords, equals(0));
        expect(stats.documentCount, equals(1));
        expect(stats.fileSizeBytes, lessThan(sizeBefore));
        expect(box.getString('churn_key'), equals('value_iteration_19'));

        await box.close();
      },
    );
  });

  group('Reactive Streams', () {
    test('emits updates on key changes', () async {
      final box = await FuzzyBox.open(
        name: 'reactive_box',
        directoryPath: tempDir.path,
      );

      final received = <String>[];
      final sub = box.watchKey('stream_key').listen((doc) {
        if (doc != null) {
          received.add(doc.getString());
        }
      });

      await box.put('stream_key', 'first');
      await Future.delayed(const Duration(milliseconds: 10));
      await box.put('stream_key', 'second');
      await Future.delayed(const Duration(milliseconds: 10));

      expect(received, containsAll(['first', 'second']));

      await sub.cancel();
      await box.close();
    });
  });
}
