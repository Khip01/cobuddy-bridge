import 'dart:io';
import 'package:test/test.dart';
import '../../lib/src/models/account.dart';

void main() {
  group('Account', () {
    test('default constructor uses defaults', () {
      final a = Account(id: 'test123');
      expect(a.id, 'test123');
      expect(a.label, '');
      expect(a.enabled, true);
      expect(a.state, AcctState.unknown);
      expect(a.isHealthy, false);
      expect(a.useCount, 0);
    });

    test('isHealthy returns true only if enabled and ok', () {
      final a = Account(id: 'x', label: 'x');
      a.state = AcctState.ok;
      expect(a.isHealthy, true);
      a.enabled = false;
      expect(a.isHealthy, false);
      a.enabled = true;
      a.state = AcctState.expired;
      expect(a.isHealthy, false);
    });

    test('tokenIsExpired returns true when token is past expiry', () {
      final a = Account(id: 'x', expiresAt: DateTime.now().add(const Duration(seconds: 60)));
      expect(a.tokenIsExpired, false);
      a.expiresAt = DateTime.now().subtract(const Duration(seconds: 1));
      expect(a.tokenIsExpired, true);
    });

    test('toJson/fromJson roundtrip preserves all fields', () {
      final now = DateTime.utc(2026, 7, 19, 10, 0, 0);
      final a = Account(
        id: 'abc123def456',
        label: 'test-session',
        userId: 'user_1',
        email: 'test@example.com',
        enabled: true,
        priority: 5,
        createdAt: now,
        lastUsedAt: now,
        lastCheckAt: now,
        lastError: 'some error',
        state: AcctState.expired,
        stateMsg: 'token expired',
        accessToken: 'eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3QifQ',
        refreshToken: 'rt_refresh',
        idToken: 'id_token_val',
        expiresAt: now.add(const Duration(hours: 1)),
        scope: 'openid profile',
        tokenType: 'Bearer',
        useCount: 42,
        note: 'my note',
      );
      final json = a.toJson();
      final b = Account.fromJson(json);

      expect(b.id, a.id);
      expect(b.label, a.label);
      expect(b.userId, a.userId);
      expect(b.email, a.email);
      expect(b.enabled, a.enabled);
      expect(b.priority, a.priority);
      expect(b.createdAt.toIso8601String(), a.createdAt.toIso8601String());
      expect(b.lastUsedAt.toIso8601String(), a.lastUsedAt.toIso8601String());
      expect(b.lastCheckAt.toIso8601String(), a.lastCheckAt.toIso8601String());
      expect(b.lastError, a.lastError);
      expect(b.state, a.state);
      expect(b.stateMsg, a.stateMsg);
      expect(b.accessToken, a.accessToken);
      expect(b.refreshToken, a.refreshToken);
      expect(b.idToken, a.idToken);
      expect(b.expiresAt.toIso8601String(), a.expiresAt.toIso8601String());
      expect(b.scope, a.scope);
      expect(b.tokenType, a.tokenType);
      expect(b.useCount, a.useCount);
      expect(b.note, a.note);
    });

    test('fromJson handles missing optional fields gracefully', () {
      final json = {'id': 'abc', 'label': 'test'};
      final a = Account.fromJson(json);
      expect(a.id, 'abc');
      expect(a.label, 'test');
      expect(a.enabled, true);
      expect(a.state, AcctState.unknown);
      expect(a.useCount, 0);
    });

    test('fromJson handles null last_used_at and last_check_at', () {
      final json = {
        'id': 'abc',
        'label': 't',
        'expires_at': DateTime.now().toIso8601String(),
      };
      final a = Account.fromJson(json);
      expect(a.lastUsedAt.year, 1);
      expect(a.lastCheckAt.year, 1);
    });

    test('state serialization uses enum name', () {
      for (final s in AcctState.values) {
        final a = Account(id: 'x', state: s);
        expect(a.toJson()['state'], s.name);
      }
    });
  });

  group('RotatorState', () {
    test('default constructor uses now', () {
      final rs = RotatorState();
      expect(rs.currentId, '');
      expect(rs.requestsSinceLast, 0);
    });

    test('toJson/fromJson roundtrip', () {
      final now = DateTime.utc(2026, 7, 19);
      final rs = RotatorState(
        currentId: 'abc123',
        lastRotationAt: now,
        nextRotationAt: now.add(const Duration(minutes: 5)),
        requestsSinceLast: 10,
      );
      final json = rs.toJson();
      final rs2 = RotatorState.fromJson(json);
      expect(rs2.currentId, 'abc123');
      expect(rs2.requestsSinceLast, 10);
      expect(rs2.lastRotationAt.toIso8601String(), now.toIso8601String());
    });

    test('fromJson handles missing keys', () {
      final rs = RotatorState.fromJson({});
      expect(rs.currentId, '');
      expect(rs.requestsSinceLast, 0);
    });
  });

  group('accountIdFromToken', () {
    test('returns consistent hash prefix for same token', () {
      final id1 = accountIdFromToken('token123');
      final id2 = accountIdFromToken('token123');
      expect(id1, id2);
    });

    test('returns different hash for different tokens', () {
      final id1 = accountIdFromToken('token-abc');
      final id2 = accountIdFromToken('token-xyz');
      expect(id1, isNot(id2));
    });

    test('returns 16 hex characters', () {
      final id = accountIdFromToken('any-token');
      expect(id.length, 16);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(id), true);
    });
  });

  group('Store', () {
    late Directory tmpDir;
    late Store store;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('cobuddy_test_');
      store = Store(
        acctsDir: '${tmpDir.path}/accounts',
        stateFilePath: '${tmpDir.path}/state.json',
      );
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    Account _make(String id, {String label = '', AcctState state = AcctState.ok}) {
      return Account(
        id: id,
        label: label.isEmpty ? id : label,
        state: state,
        priority: 0,
      );
    }

    test('loadAll returns empty list when no accounts', () {
      expect(store.loadAll(), isEmpty);
    });

    test('save and loadAll roundtrip', () {
      store.save(_make('a1', label: 'first'));
      store.save(_make('a2', label: 'second'));
      final all = store.loadAll();
      expect(all.length, 2);
      expect(all.map((a) => a.id), containsAll(['a1', 'a2']));
    });

    test('find returns correct account', () {
      store.save(_make('find-me', label: 'target'));
      final a = store.find('find-me');
      expect(a, isNotNull);
      expect(a!.label, 'target');
    });

    test('find returns null for non-existent', () {
      expect(store.find('nonexistent'), isNull);
    });

    test('delete removes account', () {
      store.save(_make('del-me'));
      expect(store.find('del-me'), isNotNull);
      store.delete('del-me');
      expect(store.find('del-me'), isNull);
    });

    test('healthyAccounts filters by healthy state', () {
      final ok = _make('ok', state: AcctState.ok);
      final expired = _make('exp', state: AcctState.expired);
      final exhausted = _make('exh', state: AcctState.exhausted);
      store.save(ok);
      store.save(expired);
      store.save(exhausted);
      final healthy = store.healthyAccounts();
      expect(healthy.length, 1);
      expect(healthy.first.id, 'ok');
    });

    test('markUsed updates lastUsedAt and increments useCount', () {
      store.save(_make('used', state: AcctState.ok));
      store.markUsed('used');
      final a = store.find('used');
      expect(a!.useCount, 1);
      expect(a.lastUsedAt.year, greaterThan(2000));
    });

    test('markUsed does nothing for non-existent id', () {
      store.markUsed('no-such-id');
    });

    test('markChecked updates state, msg, and lastCheckAt', () {
      store.save(_make('chk', state: AcctState.ok));
      store.markChecked('chk', AcctState.expired, 'rate limited');
      final a = store.find('chk');
      expect(a!.state, AcctState.expired);
      expect(a.stateMsg, 'rate limited');
      expect(a.lastCheckAt.year, greaterThan(2000));
    });

    test('markChecked does nothing for non-existent id', () {
      store.markChecked('no-such', AcctState.expired, 'x');
    });

    test('updateTokens modifies all token fields', () {
      store.save(_make('tok', state: AcctState.ok));
      final exp = DateTime.now().add(const Duration(hours: 2));
      store.updateTokens('tok', 'new_at', 'new_rt', 'new_id', 'Bearer', 'scope', exp);
      final a = store.find('tok');
      expect(a!.accessToken, 'new_at');
      expect(a.refreshToken, 'new_rt');
      expect(a.idToken, 'new_id');
      expect(a.tokenType, 'Bearer');
      expect(a.scope, 'scope');
      expect(a.expiresAt.toIso8601String(), exp.toIso8601String());
    });

    test('updateTokens does nothing for non-existent id', () {
      store.updateTokens('no-such', 'at', 'rt', 'id', 'Bearer', 'scope', DateTime.now());
    });

    test('loadState returns default when file missing', () {
      final s = store.loadState();
      expect(s.currentId, '');
    });

    test('saveState and loadState roundtrip', () {
      final s = RotatorState(
        currentId: 'current1',
        requestsSinceLast: 5,
      );
      store.saveState(s);
      final loaded = store.loadState();
      expect(loaded.currentId, 'current1');
      expect(loaded.requestsSinceLast, 5);
    });

    test('loadState handles corrupt JSON gracefully', () {
      File('${tmpDir.path}/state.json').writeAsStringSync('not json');
      final s = store.loadState();
      expect(s.currentId, '');
    });

    test('persists accounts across store instances', () {
      store.save(_make('persist1'));
      store.save(_make('persist2'));

      final store2 = Store(
        acctsDir: '${tmpDir.path}/accounts',
        stateFilePath: '${tmpDir.path}/state.json',
      );
      final all = store2.loadAll();
      expect(all.length, 2);
    });
  });
}
