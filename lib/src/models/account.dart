import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

const String acctsDir = '/home/khip/.config/codebuddy/accounts';
const String stateFilePath = '/home/khip/.config/codebuddy/state.json';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class RotatorState {
  String currentId;
  DateTime lastRotationAt;
  DateTime nextRotationAt;
  int requestsSinceLast;

  RotatorState({
    this.currentId = '',
    DateTime? lastRotationAt,
    DateTime? nextRotationAt,
    this.requestsSinceLast = 0,
  })  : lastRotationAt = lastRotationAt ?? DateTime.now(),
        nextRotationAt = nextRotationAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'current_id': currentId,
    'last_rotation_at': lastRotationAt.toIso8601String(),
    'next_rotation_at': nextRotationAt.toIso8601String(),
    'requests_since_last': requestsSinceLast,
  };

  factory RotatorState.fromJson(Map<String, dynamic> j) => RotatorState(
    currentId: j['current_id'] as String? ?? '',
    lastRotationAt: DateTime.tryParse(j['last_rotation_at'] as String? ?? '') ?? DateTime.now(),
    nextRotationAt: DateTime.tryParse(j['next_rotation_at'] as String? ?? '') ?? DateTime.now(),
    requestsSinceLast: j['requests_since_last'] as int? ?? 0,
  );
}

// ---------------------------------------------------------------------------
// Account
// ---------------------------------------------------------------------------

enum AcctState { ok, unknown, expired, exhausted, error }

class Account {
  final String id;
  String label;
  String userId;
  String email;
  bool enabled;
  int priority;
  final DateTime createdAt;
  DateTime lastUsedAt;
  DateTime lastCheckAt;
  String lastError;
  AcctState state;
  String stateMsg;
  String accessToken;
  String refreshToken;
  String idToken;
  DateTime expiresAt;
  String scope;
  String tokenType;
  int useCount;
  String note;

  Account({
    required this.id,
    this.label = '',
    this.userId = '',
    this.email = '',
    this.enabled = true,
    this.priority = 0,
    DateTime? createdAt,
    DateTime? lastUsedAt,
    DateTime? lastCheckAt,
    this.lastError = '',
    this.state = AcctState.unknown,
    this.stateMsg = '',
    this.accessToken = '',
    this.refreshToken = '',
    this.idToken = '',
    DateTime? expiresAt,
    this.scope = '',
    this.tokenType = '',
    this.useCount = 0,
    this.note = '',
  })  : createdAt = createdAt ?? DateTime.now(),
        lastUsedAt = lastUsedAt ?? DateTime(1),
        lastCheckAt = lastCheckAt ?? DateTime(1),
        expiresAt = expiresAt ?? DateTime.now().add(const Duration(hours: 1));

  bool get tokenIsExpired => expiresAt.isBefore(DateTime.now().add(const Duration(seconds: 30)));

  bool get isHealthy => enabled && state == AcctState.ok;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'user_id': userId,
    'email': email,
    'enabled': enabled,
    'priority': priority,
    'created_at': createdAt.toIso8601String(),
    'last_used_at': lastUsedAt.year > 2000 ? lastUsedAt.toIso8601String() : null,
    'last_check_at': lastCheckAt.year > 2000 ? lastCheckAt.toIso8601String() : null,
    'last_error': lastError,
    'state': state.name,
    'state_message': stateMsg,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'id_token': idToken,
    'expires_at': expiresAt.toIso8601String(),
    'scope': scope,
    'token_type': tokenType,
    'use_count': useCount,
    'note': note,
  };

  factory Account.fromJson(Map<String, dynamic> j) {
    final eps = j['expires_at'] as String? ?? '';
    final las = j['last_used_at'] as String? ?? '';
    final lcs = j['last_check_at'] as String? ?? '';
    return Account(
      id: j['id'] as String? ?? '',
      label: j['label'] as String? ?? '',
      userId: j['user_id'] as String? ?? '',
      email: j['email'] as String? ?? '',
      enabled: j['enabled'] as bool? ?? true,
      priority: j['priority'] as int? ?? 0,
      createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
      lastUsedAt: las.isNotEmpty ? (DateTime.tryParse(las) ?? DateTime(1)) : DateTime(1),
      lastCheckAt: lcs.isNotEmpty ? (DateTime.tryParse(lcs) ?? DateTime(1)) : DateTime(1),
      lastError: j['last_error'] as String? ?? '',
      state: AcctState.values.firstWhere(
        (e) => e.name == (j['state'] as String? ?? 'unknown'),
        orElse: () => AcctState.unknown,
      ),
      stateMsg: j['state_message'] as String? ?? '',
      accessToken: j['access_token'] as String? ?? '',
      refreshToken: j['refresh_token'] as String? ?? '',
      idToken: j['id_token'] as String? ?? '',
      expiresAt: eps.isNotEmpty ? (DateTime.tryParse(eps) ?? DateTime.now().add(const Duration(hours: 1))) : DateTime.now().add(const Duration(hours: 1)),
      scope: j['scope'] as String? ?? '',
      tokenType: j['token_type'] as String? ?? '',
      useCount: j['use_count'] as int? ?? 0,
      note: j['note'] as String? ?? '',
    );
  }
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

class Store {
  void _ensure() { Directory(acctsDir).createSync(recursive: true); }

  List<Account> loadAll() {
    _ensure();
    final d = Directory(acctsDir);
    if (!d.existsSync()) return [];
    return d.listSync()
        .whereType<File>()
        .map((f) => Account.fromJson(jsonDecode(f.readAsStringSync())))
        .toList();
  }

  void save(Account a) {
    _ensure();
    File('$acctsDir/${a.id}.json').writeAsStringSync(jsonEncode(a.toJson()));
  }

  void delete(String id) {
    File('$acctsDir/$id.json').deleteSync();
  }

  Account? find(String id) {
    final f = File('$acctsDir/$id.json');
    if (!f.existsSync()) return null;
    return Account.fromJson(jsonDecode(f.readAsStringSync()));
  }

  List<Account> healthyAccounts() {
    return loadAll().where((a) => a.isHealthy).toList();
  }

  void markUsed(String id) {
    final a = find(id);
    if (a == null) return;
    a.lastUsedAt = DateTime.now();
    a.useCount++;
    save(a);
  }

  void markChecked(String id, AcctState state, String msg) {
    final a = find(id);
    if (a == null) return;
    a.state = state;
    a.stateMsg = msg;
    a.lastCheckAt = DateTime.now();
    save(a);
  }

  void updateTokens(String id, String accessToken, String refreshToken, String idToken, String tokenType, String scope, DateTime expiresAt) {
    final a = find(id);
    if (a == null) return;
    a.accessToken = accessToken;
    a.refreshToken = refreshToken;
    a.idToken = idToken;
    a.tokenType = tokenType;
    a.scope = scope;
    a.expiresAt = expiresAt;
    save(a);
  }

  // Rotation state
  RotatorState loadState() {
    final f = File(stateFilePath);
    if (!f.existsSync()) return RotatorState();
    try {
      return RotatorState.fromJson(jsonDecode(f.readAsStringSync()));
    } catch (_) {
      return RotatorState();
    }
  }

  void saveState(RotatorState s) {
    Directory(acctsDir).parent.createSync(recursive: true);
    File(stateFilePath).writeAsStringSync(jsonEncode(s.toJson()));
  }
}

String accountIdFromToken(String token) {
  final hash = sha256.convert(utf8.encode(token)).toString();
  return hash.substring(0, 16);
}

int _nextPriority(Store store) {
  var max = 0;
  for (final a in store.loadAll()) {
    if (a.priority > max) max = a.priority;
  }
  return max + 1;
}