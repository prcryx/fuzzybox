import 'package:example/fuzzy_box.dart';
import 'package:flutter/material.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FuzzyBoxInitialize.init('fuzzybox_demo');
  // print(
  //   '📦 Box "${box.name}" opened successfully. Current doc count: ${box.length}\n',
  // );

  runApp(const MyApp());
}

// void main() {
//   runApp(const MyApp());
// }

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  void initState() {
    super.initState();
    printInConsole();
  }

  void printInConsole() async {
    final box = FuzzyBoxInitialize.box;
    // 2. Put simple primitives (SharedPreferences-like convenience)
    await box.put('app.onboarded', true, tags: {'setup'});
    await box.put('app.launch_count', 42, tags: {'telemetry'});
    await box.put('app.environment', 'production', tags: {'env', 'runtime'});

    // 3. Put structured documents with nested maps and tags (Database-like capability)
    await box.put(
      'theme.palette',
      {
        'mode': 'dark',
        'primary_color': '#4F46E5',
        'accent_color': '#10B981',
        'font_size': 14.5,
        'contrast_high': true,
      },
      tags: {'ui', 'appearance', 'user_preference'},
      schema: 'ThemeConfig',
    );

    await box.put(
      'flags.new_checkout_flow',
      {
        'enabled': true,
        'rollout_percentage': 85,
        'min_app_version': '3.2.0',
        'geo_whitelist': ['US', 'CA', 'GB', 'DE'],
      },
      tags: {'feature_flag', 'billing', 'remote_config'},
      schema: 'FeatureFlag',
    );

    await box.put(
      'flags.ai_search_v2',
      {
        'enabled': false,
        'rollout_percentage': 10,
        'min_app_version': '3.5.0',
        'geo_whitelist': ['US'],
      },
      tags: {'feature_flag', 'experimental', 'remote_config'},
      schema: 'FeatureFlag',
    );

    await box.put(
      'user.session',
      {
        'user_id': 'usr_98124',
        'tier': 'pro',
        'quota_limit': 500,
        'quota_used': 128,
        'last_active_epoch': DateTime.now().millisecondsSinceEpoch,
      },
      tags: {'user_preference', 'session'},
      schema: 'UserProfile',
    );

    // 4. Synchronous O(1) Instant Reads
    print('--- Synchronous O(1) Reads ---');
    print('Onboarded: ${box.getBool('app.onboarded')}');
    print('Launch count: ${box.getInt('app.launch_count')}');
    print(
      'Theme primary color: ${box.getDoc('theme.palette')?.getString('primary_color')}',
    );
    print(
      'Checkout rollout: ${box.getDoc('flags.new_checkout_flow')?.getInt('rollout_percentage')}%\n',
    );

    // 5. Query 1: Filter by Key Prefix (like namespace queries)
    print('--- Query 1: Feature Flags by Prefix ---');
    final flags = box.query().whereKeyStartsWith('flags.').find();
    for (final flag in flags) {
      print(
        '• ${flag.key}: enabled=${flag.getBool('enabled')}, rollout=${flag.getInt('rollout_percentage')}%',
      );
    }
    print('');

    // 6. Query 2: Tag-based Inverted Index Lookup (Microsecond execution)
    print('--- Query 2: Instant Tag Index Search: "remote_config" ---');
    final remoteConfigs = box.getByTag('remote_config');
    for (final doc in remoteConfigs) {
      print('• ${doc.key} -> tags: ${doc.tags}');
    }
    print('');

    // 7. Query 3: Complex Structured Document Query
    print(
      '--- Query 3: Property Conditions (> 50 rollout percentage & enabled) ---',
    );
    final activeRollouts = box
        .query()
        .whereSchema('FeatureFlag')
        .whereEquals('enabled', true)
        .whereGreaterThan('rollout_percentage', 50)
        .orderBy('rollout_percentage', descending: true)
        .find();

    for (final doc in activeRollouts) {
      print(
        '• ${doc.key}: ${doc.getInt('rollout_percentage')}% [schema=${doc.schema}]',
      );
    }
    print('');

    // 8. Reactive Stream Listening
    print('--- Reactive Stream Watching ---');
    final sub = box.watchKey('theme.palette').listen((doc) {
      print(
        '🔔 [Watch Event] Theme updated! New mode: ${doc?.getString('mode')}',
      );
    });

    // Mutate theme to trigger watch event
    await box.put(
      'theme.palette',
      {'mode': 'system', 'primary_color': '#6366F1', 'font_size': 16.0},
      tags: {'ui', 'appearance'},
    );

    // Give microtask time to fire stream
    await Future.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    print('');

    // 9. Inspect Stats & Compaction
    final statsBefore = await box.getStats();
    print('--- Storage Diagnostics ---');
    print('Documents: ${statsBefore.documentCount}');
    print('Total log records: ${statsBefore.totalLogRecords}');
    print('Dead records: ${statsBefore.deadRecords}');
    print('File size: ${statsBefore.fileSizeBytes} bytes');

    print('Running atomic compaction...');
    await box.compact();

    final statsAfter = await box.getStats();
    print(
      'Compacted file size: ${statsAfter.fileSizeBytes} bytes, dead records: ${statsAfter.deadRecords}\n',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
            Text(
              'Check Console',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
    );
  }
}
