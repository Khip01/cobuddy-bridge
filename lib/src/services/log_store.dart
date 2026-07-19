import 'dart:collection';
import 'dart:convert';
import 'dart:io';

enum LogLevel { info, success, error, warning, debug }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String source;
  final String message;

  LogEntry({required this.level, required this.source, required this.message})
    : time = DateTime.now();

  LogEntry._({
    required this.time,
    required this.level,
    required this.source,
    required this.message,
  });

  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'level': level.name,
    'source': source,
    'message': message,
  };

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry._(
    time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
    level: LogLevel.values.firstWhere(
      (e) => e.name == (j['level'] as String? ?? 'info'),
      orElse: () => LogLevel.info,
    ),
    source: j['source'] as String? ?? '',
    message: j['message'] as String? ?? '',
  );
}

class LogStore {
  LogStore._();

  static final _entries = Queue<LogEntry>();
  static const int _max = 2000;
  static String? _filePath;

  static void init({String? filePath}) {
    _filePath =
        filePath ??
        '${Platform.environment['HOME'] ?? '/home/khip'}/.config/codebuddy/logs.jsonl';
    _loadFromFile();
  }

  static void add(LogLevel level, String source, String message) {
    final e = LogEntry(level: level, source: source, message: message);
    _entries.add(e);
    _appendToFile(e);
    while (_entries.length > _max) {
      _entries.removeFirst();
      _rewriteFile();
    }
  }

  static void info(String source, String msg) =>
      add(LogLevel.info, source, msg);
  static void success(String source, String msg) =>
      add(LogLevel.success, source, msg);
  static void error(String source, String msg) =>
      add(LogLevel.error, source, msg);
  static void warning(String source, String msg) =>
      add(LogLevel.warning, source, msg);
  static void debug(String source, String msg) =>
      add(LogLevel.debug, source, msg);

  static List<LogEntry> get entries => _entries.toList();
  static List<LogEntry> get latestFirst => _entries.toList().reversed.toList();

  static void clear() {
    _entries.clear();
    _rewriteFile();
  }

  static void clearBeforeToday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _entries.removeWhere((e) => e.time.isBefore(today));
    _rewriteFile();
  }

  static int countBeforeToday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _entries.where((e) => e.time.isBefore(today)).length;
  }

  static int get totalCount => _entries.length;

  static void _loadFromFile() {
    if (_filePath == null) return;
    final f = File(_filePath!);
    if (!f.existsSync()) return;
    try {
      for (final line in f.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          _entries.add(LogEntry.fromJson(jsonDecode(line)));
        } catch (_) {}
      }
      while (_entries.length > _max) _entries.removeFirst();
    } catch (_) {}
  }

  static void _appendToFile(LogEntry e) {
    if (_filePath == null) return;
    try {
      final f = File(_filePath!);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('${jsonEncode(e.toJson())}\n', mode: FileMode.append);
    } catch (_) {}
  }

  static void _rewriteFile() {
    if (_filePath == null) return;
    try {
      final f = File(_filePath!);
      f.parent.createSync(recursive: true);
      final buf = StringBuffer();
      for (final e in _entries) {
        buf.writeln(jsonEncode(e.toJson()));
      }
      f.writeAsStringSync(buf.toString());
    } catch (_) {}
  }
}
