import 'dart:io';

import 'package:fuzzybox/fuzzybox.dart';

class FuzzyBoxInitialize {
  static FuzzyBoxInitialize? _instance;
  late FuzzyBox _box;
  late Directory _tempDir;
  FuzzyBoxInitialize._();

  factory FuzzyBoxInitialize() {
    _instance = FuzzyBoxInitialize._();
    return _instance!;
  }

  static Future<void> init(String dir) async {
    if (_instance != null) return;
    _instance = FuzzyBoxInitialize._();
    _instance!._tempDir = Directory.systemTemp.createTempSync(dir);

    // 1. Open the Box
    _instance!._box = await FuzzyBox.open(
      name: 'app_config',
      directoryPath: _instance!._tempDir.path,
      autoCompact: true,
      compactionThreshold: 10,
    );
  }

  static void delete() async {
    if (_instance == null) {
      throw StateError(
        'FuzzyBoxInitialize.init() must be awaited before accessing box.',
      );
    }
    await _instance!._box.close();
    _instance!._tempDir.deleteSync(recursive: true);
    print('✅ ConfigDocBox demo completed successfully!');
  }

  static FuzzyBox get box {
    if (_instance == null) {
      throw StateError(
        'FuzzyBoxInitialize.init() must be awaited before accessing box.',
      );
    }

    return _instance!._box;
  }
}
