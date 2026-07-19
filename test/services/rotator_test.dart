import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import '../../lib/src/models/account.dart';
import '../../lib/src/models/config.dart';
import '../../lib/src/services/oauth.dart';
import '../../lib/src/services/rotator.dart';

void main() {
  group('looksLikeHtml', () {
    test('returns true for HTML content', () {
      expect(looksLikeHtml('<html><body>Hello</body></html>'), true);
      expect(looksLikeHtml('<!DOCTYPE html><html>'), true);
      expect(looksLikeHtml('<!doctype html>'), true);
    });

    test('returns false for non-HTML content', () {
      expect(looksLikeHtml('{"key": "value"}'), false);
      expect(looksLikeHtml('plain text'), false);
      expect(looksLikeHtml(''), false);
    });

    test('case insensitive', () {
      expect(looksLikeHtml('<HTML>'), true);
      expect(looksLikeHtml('<!DOCTYPE HTML>'), true);
    });
  });

  group('interpretQuotaResponse', () {
    test('200 with remaining field returns ok with message', () {
      final r = interpretQuotaResponse(200, jsonEncode({'remaining': 150}));
      expect(r.state, AcctState.ok);
      expect(r.msg, contains('remaining'));
    });

    test('200 with remaining=0 returns exhausted', () {
      final r = interpretQuotaResponse(200, jsonEncode({'remaining': 0}));
      expect(r.state, AcctState.exhausted);
    });

    test('200 with balance field returns ok', () {
      final r = interpretQuotaResponse(200, jsonEncode({'balance': 100.5}));
      expect(r.state, AcctState.ok);
    });

    test('200 with available field returns ok', () {
      final r = interpretQuotaResponse(200, jsonEncode({'available': 10}));
      expect(r.state, AcctState.ok);
    });

    test('200 with negative remaining returns exhausted', () {
      final r = interpretQuotaResponse(200, jsonEncode({'remaining': -1}));
      expect(r.state, AcctState.exhausted);
    });

    test('200 with non-zero code in response returns error', () {
      final r = interpretQuotaResponse(200, jsonEncode({'code': 1, 'msg': 'over quota'}));
      expect(r.state, AcctState.error);
    });

    test('200 with HTML body returns error', () {
      final r = interpretQuotaResponse(200, '<html>login page</html>');
      expect(r.state, AcctState.error);
    });

    test('200 with no quota fields returns ok', () {
      final r = interpretQuotaResponse(200, jsonEncode({'status': 'ok'}));
      expect(r.state, AcctState.ok);
    });

    test('401 with HTML returns error (APISIX)', () {
      final r = interpretQuotaResponse(401, '<html>Unauthorized</html>');
      expect(r.state, AcctState.error);
      expect(r.msg, contains('HTML'));
    });

    test('401 with non-HTML returns expired', () {
      final r = interpretQuotaResponse(401, jsonEncode({'error': 'unauthorized'}));
      expect(r.state, AcctState.expired);
    });

    test('403 with HTML returns error', () {
      final r = interpretQuotaResponse(403, '<html>Forbidden</html>');
      expect(r.state, AcctState.error);
      expect(r.msg, contains('HTML'));
    });

    test('403 with non-HTML returns expired', () {
      final r = interpretQuotaResponse(403, '{"error":"forbidden"}');
      expect(r.state, AcctState.expired);
    });

    test('429 returns exhausted', () {
      final r = interpretQuotaResponse(429, 'Too Many Requests');
      expect(r.state, AcctState.exhausted);
    });

    test('404 returns error', () {
      final r = interpretQuotaResponse(404, 'Not Found');
      expect(r.state, AcctState.error);
    });

    test('200 with non-Map JSON returns ok', () {
      final r = interpretQuotaResponse(200, '["item1", "item2"]');
      expect(r.state, AcctState.ok);
    });
  });

  group('Rotator', () {
    late Directory tmpDir;
    late Store store;
    late Config cfg;
    late OAuthClient auth;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('cobuddy_rotator_test_');
      store = Store(
        acctsDir: '${tmpDir.path}/accounts',
        stateFilePath: '${tmpDir.path}/state.json',
      );
      cfg = Config();
      cfg.quotaProbeUrl = '';
      auth = OAuthClient(cfg);
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    Account _mk(String id, {AcctState state = AcctState.ok, bool enabled = true, String rt = '', int priority = 0}) {
      final a = Account(
        id: id,
        label: id,
        state: state,
        enabled: enabled,
        priority: priority,
        refreshToken: rt,
      );
      a.expiresAt = DateTime.now().add(const Duration(hours: 1));
      store.save(a);
      return a;
    }

    test('get returns null when no accounts', () async {
      final r = Rotator(cfg: cfg, store: store, auth: auth);
      final a = await r.get();
      expect(a, isNull);
    });

    test('get returns first healthy account sorted by createdAt', () async {
      await Future.delayed(const Duration(milliseconds: 5));
      _mk('acc2', state: AcctState.ok);
      await Future.delayed(const Duration(milliseconds: 5));
      _mk('acc1', state: AcctState.ok);
      final r = Rotator(cfg: cfg, store: store, auth: auth);
      final a = await r.get();
      expect(a, isNotNull);
      expect(a!.id, 'acc2'); // acc2 created first
    });

    test('get skips non-healthy accounts when healthy exist', () async {
      _mk('expired', state: AcctState.expired);
      _mk('ok1', state: AcctState.ok);
      _mk('ok2', state: AcctState.ok);
      final r = Rotator(cfg: cfg, store: store, auth: auth);
      final a = await r.get();
      expect(a, isNotNull);
      expect(a!.id, 'ok1');
    });

    test('get falls back to enabled accounts when no healthy', () async {
      _mk('exp', state: AcctState.expired);
      _mk('err', state: AcctState.error, enabled: true);
      final r = Rotator(cfg: cfg, store: store, auth: auth);
      final a = await r.get();
      expect(a, isNotNull);
    });

    test('get advances on exhausted in exhaustedNext mode', () async {
      _mk('e1', state: AcctState.exhausted);
      _mk('e2', state: AcctState.ok);
      cfg.rotationStrategy = RotationStrategy.exhaustedNext;
      final r = Rotator(cfg: cfg, store: store, auth: auth);
      final a = await r.get();
      expect(a, isNotNull);
      expect(a!.state, AcctState.ok);
    });

    test('get advances on exhausted in exhaustedRandom mode', () async {
      _mk('e1', state: AcctState.exhausted);
      _mk('e2', state: AcctState.ok);
      cfg.rotationStrategy = RotationStrategy.exhaustedRandom;
      final r = Rotator(cfg: cfg, store: store, auth: auth);
      final a = await r.get();
      expect(a, isNotNull);
      expect(a!.state, AcctState.ok);
    });

    test('get advances on request count in requestCountNext mode', () async {
      _mk('r1', state: AcctState.ok);
      _mk('r2', state: AcctState.ok);
      cfg.rotationStrategy = RotationStrategy.requestCountNext;
      cfg.requestsPerRotation = 3;

      final r = Rotator(cfg: cfg, store: store, auth: auth);
      // Call 1: current is null, advance to first (r1), requestsSinceLast = 0
      final a1 = await r.get();
      expect(a1, isNotNull);
      expect(a1!.id, 'r1');

      // Calls 2-4: increment counter (0 -> 1 -> 2 -> 3)
      await r.get();
      await r.get();
      await r.get();

      // Call 5: requestsSinceLast = 3 >= 3, advance to r2
      final a5 = await r.get();
      expect(a5, isNotNull);
      expect(a5!.id, 'r2');
    });

    test('get increments requestsSinceLast on each call', () async {
      _mk('acc', state: AcctState.ok);
      cfg.rotationStrategy = RotationStrategy.requestCountNext;
      cfg.requestsPerRotation = 10;

      final r = Rotator(cfg: cfg, store: store, auth: auth);
      // First call: advance (null current), requestsSinceLast = 0
      await r.get();
      // Second call: increment to 1
      await r.get();
      final s = store.loadState();
      expect(s.requestsSinceLast, 1);
    });

    test('forceRotate cycles among healthy accounts', () async {
      _mk('a1', state: AcctState.ok);
      _mk('a2', state: AcctState.ok);
      _mk('a3', state: AcctState.ok);
      final r = Rotator(cfg: cfg, store: store, auth: auth);

      final first = r.forceRotate();
      expect(first, isNotNull);

      final state = store.loadState();
      state.currentId = first!.id;
      store.saveState(state);

      final second = r.forceRotate();
      expect(second, isNotNull);
      expect(second!.id, isNot(first.id));

      final third = r.forceRotate();
      expect(third, isNotNull);
      expect(third!.id, isNot(second.id));
    });

    test('nextAfter returns next by createdAt order for exhaustedNext', () async {
      cfg.rotationStrategy = RotationStrategy.exhaustedNext;
      final now = DateTime.now();
      final cands = [
        Account(id: 'a', createdAt: now.subtract(const Duration(seconds: 3))),
        Account(id: 'b', createdAt: now.subtract(const Duration(seconds: 2))),
        Account(id: 'c', createdAt: now.subtract(const Duration(seconds: 1))),
      ];
      final r = Rotator(cfg: cfg, store: store, auth: auth);
      expect(r.nextAfter(cands, cands[0])!.id, 'b');
      expect(r.nextAfter(cands, cands[1])!.id, 'c');
      expect(r.nextAfter(cands, cands[2])!.id, 'a');
      expect(r.nextAfter(cands, null)!.id, 'a');
      expect(r.nextAfter([], null), isNull);
    });

    test('nextAfter returns random in random mode', () async {
      cfg.rotationStrategy = RotationStrategy.exhaustedRandom;
      final cands = [
        Account(id: 'a', createdAt: DateTime.now()),
        Account(id: 'b', createdAt: DateTime.now()),
        Account(id: 'c', createdAt: DateTime.now()),
      ];
      final r = Rotator(cfg: cfg, store: store, auth: auth);
      // Shouldn't return current id
      final next = r.nextAfter(cands, cands[0]);
      expect(next, isNotNull);
      expect(next!.id, isNot('a'));
    });

    test('nextAfter returns only option when single account in random mode', () async {
      cfg.rotationStrategy = RotationStrategy.exhaustedRandom;
      final cands = [Account(id: 'solo', createdAt: DateTime.now())];
      final r = Rotator(cfg: cfg, store: store, auth: auth);
      expect(r.nextAfter(cands, cands[0])!.id, 'solo');
      expect(r.nextAfter(cands, null)!.id, 'solo');
    });

    test('advanceToNext cycles correctly', () {
      _mk('x', state: AcctState.ok);
      _mk('y', state: AcctState.ok);
      _mk('z', state: AcctState.ok);
      final r = Rotator(cfg: cfg, store: store, auth: auth);

      final next = r.advanceToNext('x');
      expect(next, isNotNull);
      expect(next!.id, 'y');

      final storeState = store.loadState();
      expect(storeState.currentId, 'y');
    });

    test('advanceToNext wraps around', () {
      _mk('x', state: AcctState.ok);
      _mk('y', state: AcctState.ok);
      final r = Rotator(cfg: cfg, store: store, auth: auth);

      r.advanceToNext('x');
      final next = r.advanceToNext('y');
      expect(next!.id, 'x');
    });

    test('probeAccount returns null for non-existent id', () async {
      final r = Rotator(cfg: cfg, store: store, auth: auth);
      final a = await r.probeAccount('no-such');
      expect(a, isNull);
    });

    test('probeAccount returns account as-is if no access token', () async {
      final a = Account(id: 'no-token');
      store.save(a);
      final r = Rotator(cfg: cfg, store: store, auth: auth);
      final result = await r.probeAccount('no-token');
      expect(result, isNotNull);
      expect(result!.id, 'no-token');
      expect(result.state, AcctState.unknown);
    });
  });
}
