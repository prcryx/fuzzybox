import 'dart:async';
import 'src/box_impl.dart';

export 'src/box_impl.dart' show FuzzyBox, BoxStats;
export 'src/config_doc.dart' show ConfigDoc;
export 'src/doc_query.dart' show DocQuery, QueryOperator, PropertyCondition;
export 'src/storage_format.dart' show StorageFormat, ReplayResult;

/// A global manager and registry for multiple named [FuzzyBox] instances.
///
/// Allows convenient singleton-like access across Flutter widgets, services,
/// and Bloc/Riverpod providers without manual dependency plumbing.
class DocBoxRegistry {
  static final Map<String, FuzzyBox> _boxes = {};
  static String? _defaultDirectory;

  /// Sets the default storage directory for all boxes (e.g. `getApplicationDocumentsDirectory().path`).
  static void setDefaultDirectory(String path) {
    _defaultDirectory = path;
  }

  /// Opens or retrieves an existing [FuzzyBox] with the given [name].
  static Future<FuzzyBox> open({
    required String name,
    String? directoryPath,
    bool autoCompact = true,
    int compactionThreshold = 100,
  }) async {
    if (_boxes.containsKey(name)) {
      return _boxes[name]!;
    }

    final targetDir = directoryPath ?? _defaultDirectory;
    if (targetDir == null) {
      throw ArgumentError(
        'directoryPath must be provided or DocBoxRegistry.setDefaultDirectory() must be called first.',
      );
    }

    final box = await FuzzyBox.open(
      name: name,
      directoryPath: targetDir,
      autoCompact: autoCompact,
      compactionThreshold: compactionThreshold,
    );

    _boxes[name] = box;
    return box;
  }

  /// Synchronously gets an already opened box by [name].
  static FuzzyBox box([String name = 'default']) {
    final b = _boxes[name];
    if (b == null) {
      throw StateError(
        'Box "$name" is not open. Call `await DocBoxRegistry.open(name: "$name")` first.',
      );
    }
    return b;
  }

  /// Checks if a box with [name] is currently open.
  static bool isOpen(String name) => _boxes.containsKey(name);

  /// Closes and removes a box from the registry.
  static Future<void> close(String name) async {
    final b = _boxes.remove(name);
    if (b != null) {
      await b.close();
    }
  }

  /// Closes all registered boxes.
  static Future<void> closeAll() async {
    for (final box in _boxes.values) {
      await box.close();
    }
    _boxes.clear();
  }
}
