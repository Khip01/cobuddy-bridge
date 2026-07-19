import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import '../../lib/src/models/account.dart';
import '../../lib/src/models/config.dart';
import '../../lib/src/services/oauth.dart';
import '../../lib/src/services/rotator.dart';
import '../../lib/src/services/log_store.dart';
import '../../lib/src/server/proxy.dart';

/// Helper: start ProxyServer on an ephemeral port and return the base URL.
Future<String> startProxy({
  required Store store,
  required Config cfg,
  required OAuthClient auth,
  required Rotator rotator,
}) async {
  cfg.serverHost = '127.0.0.1';
  cfg.serverPort = 0; // let OS assign
  final proxy = ProxyServer(cfg: cfg, store: store, auth: auth, rotator: rotator);

  // Bind manually on port 0
  final server = await HttpServer.bind(cfg.serverHost, 0);
  final url = 'http://${server.address.address}:${server.port}';
  server.listen((req) => proxy.handle(req));

  // Store the server for cleanup via addTearDown
  addTearDown(() => server.close(force: true));

  return url;
}

/// Helper: create an account in the store
Account _mkAccount(String id, {AcctState state = AcctState.ok, String label = ''}) {
  return Account(
    id: id,
    label: label.isEmpty ? id : label,
    state: state,
    accessToken: 'tok_$id',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    priority: 0,
  );
}

void main() {
  late Directory tmpDir;
  late Store store;
  late Config cfg;
  late OAuthClient auth;
  late Rotator rotator;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('cobuddy_proxy_test_');
    store = Store(
      acctsDir: '${tmpDir.path}/accounts',
      stateFilePath: '${tmpDir.path}/state.json',
    );
    cfg = Config();
    cfg.quotaProbeUrl = ''; // disable real probes
    auth = OAuthClient(cfg);
    rotator = Rotator(cfg: cfg, store: store, auth: auth);
    LogStore.clear();
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  group('Proxy HTTP API', () {
    late String base;

    setUp(() async {
      base = await startProxy(store: store, cfg: cfg, auth: auth, rotator: rotator);
    });

    Future<http.Response> _get(String path) => http.get(Uri.parse('$base$path'));
    Future<http.Response> _post(String path, {Map? body}) =>
      http.post(Uri.parse('$base$path'), headers: {'Content-Type': 'application/json'}, body: body != null ? jsonEncode(body) : null);
    Future<http.Response> _patch(String path, Map body) =>
      http.patch(Uri.parse('$base$path'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
    Future<http.Response> _delete(String path) =>
      http.delete(Uri.parse('$base$path'));
    Future<http.Response> _options(String path) async {
      final req = http.Request('OPTIONS', Uri.parse('$base$path'));
      final streamed = await http.Client().send(req);
      return http.Response.fromStream(streamed);
    }

    test('GET /v1/health returns ok', () async {
      final resp = await _get('/v1/health');
      expect(resp.statusCode, 200);
      final j = jsonDecode(resp.body);
      expect(j['ok'], true);
      expect(j['version'], '1.0.0');
    });

    test('GET / returns health', () async {
      final resp = await _get('/');
      expect(resp.statusCode, 200);
      expect(jsonDecode(resp.body)['ok'], true);
    });

    test('GET /openapi.json returns ok', () async {
      final resp = await _get('/openapi.json');
      expect(resp.statusCode, 200);
    });

    test('GET /v1/config returns config snapshot', () async {
      final resp = await _get('/v1/config');
      expect(resp.statusCode, 200);
      final j = jsonDecode(resp.body);
      expect(j['issuer'], 'https://www.codebuddy.ai/auth/realms/copilot');
      expect(j['rotation_strategy'], 'exhausted-next');
      expect(j['server_host'], '127.0.0.1');
    });

    test('PATCH /v1/config updates config', () async {
      final resp = await _patch('/v1/config', {'server_port': 8080, 'rotation_strategy': 'request-count-next'});
      expect(resp.statusCode, 200);
      final j = jsonDecode(resp.body);
      expect(j['server_port'], 8080);
      expect(j['rotation_strategy'], 'request-count-next');
    });

    test('GET /v1/logs returns empty array', () async {
      final resp = await _get('/v1/logs');
      expect(resp.statusCode, 200);
      final j = jsonDecode(resp.body);
      expect(j['logs'], []);
    });

    test('GET /v1/connections returns empty list initially', () async {
      final resp = await _get('/v1/connections');
      expect(resp.statusCode, 200);
      final j = jsonDecode(resp.body);
      expect(j['connections'], []);
      expect(j['strategy'], 'exhaustedNext');
    });

    test('GET /v1/connections lists all accounts', () async {
      store.save(_mkAccount('a1', label: 'alpha'));
      store.save(_mkAccount('a2', label: 'beta'));

      final resp = await _get('/v1/connections');
      expect(resp.statusCode, 200);
      final j = jsonDecode(resp.body);
      expect(j['connections'].length, 2);
      final labels = j['connections'].map((c) => c['label']).toList();
      expect(labels, containsAll(['alpha', 'beta']));
    });

    test('GET /v1/connections/:id returns single account', () async {
      store.save(_mkAccount('findme'));

      final resp = await _get('/v1/connections/findme');
      expect(resp.statusCode, 200);
      expect(jsonDecode(resp.body)['id'], 'findme');
    });

    test('GET /v1/connections/:id returns 404 for unknown', () async {
      final resp = await _get('/v1/connections/nonexistent');
      expect(resp.statusCode, 404);
    });

    test('DELETE /v1/connections/:id deletes account', () async {
      store.save(_mkAccount('delete_me'));

      final resp = await _delete('/v1/connections/delete_me');
      expect(resp.statusCode, 200);
      expect(store.find('delete_me'), isNull);
    });

    test('PATCH /v1/connections/:id updates account fields', () async {
      store.save(_mkAccount('updatable'));

      final resp = await _patch('/v1/connections/updatable', {
        'label': 'updated_label',
        'enabled': false,
        'priority': 10,
      });
      expect(resp.statusCode, 200);

      final a = store.find('updatable');
      expect(a!.label, 'updated_label');
      expect(a.enabled, false);
      expect(a.priority, 10);
    });

    test('POST /v1/connections/:id/test probes account', () async {
      store.save(_mkAccount('probe_me'));

      final resp = await _post('/v1/connections/probe_me/test');
      // Should return the account (probe won't make real HTTP because quotaProbeUrl is empty)
      expect(resp.statusCode, 200);
      final j = jsonDecode(resp.body);
      expect(j['id'], 'probe_me');
    });

    test('POST /v1/connections/:id/reset resets state', () async {
      store.save(_mkAccount('reset_me', state: AcctState.expired));

      final resp = await _post('/v1/connections/reset_me/reset');
      expect(resp.statusCode, 200);
      final a = store.find('reset_me');
      expect(a!.state, AcctState.unknown);
    });

    test('POST /v1/rotation/rotate forces rotation', () async {
      store.save(_mkAccount('r1', state: AcctState.ok));
      store.save(_mkAccount('r2', state: AcctState.ok));

      final resp = await _post('/v1/rotation/rotate');
      expect(resp.statusCode, 200);
      final j = jsonDecode(resp.body);
      expect(j['ok'], true);
      expect(j['account'], isNotNull);
    });

    test('GET /v1/rotation/state returns rotation state', () async {
      store.saveState(RotatorState(currentId: 'current_abc', requestsSinceLast: 7));

      final resp = await _get('/v1/rotation/state');
      expect(resp.statusCode, 200);
      final j = jsonDecode(resp.body);
      expect(j['state']['current_id'], 'current_abc');
      expect(j['state']['requests_since_last'], 7);
      expect(j['strategy'], 'exhaustedNext');
    });

    test('GET /v1/models returns model list', () async {
      final resp = await _get('/v1/models');
      expect(resp.statusCode, 200);
      final j = jsonDecode(resp.body);
      expect(j['data'], isNotEmpty);
    });

    test('OPTIONS returns CORS headers', () async {
      final resp = await _options('/v1/health');
      expect(resp.statusCode, 204);
      expect(resp.headers['access-control-allow-origin'], '*');
    });

    test('unknown path returns 404', () async {
      final resp = await _get('/v1/nonexistent/route');
      expect(resp.statusCode, 404);
    });

    test('GET /v1/token returns error when no accounts', () async {
      final resp = await _get('/v1/token');
      expect(resp.statusCode, 500);
      expect(jsonDecode(resp.body)['error'], contains('no accounts'));
    });

    test('GET /v1/connections/:id/test returns 404 for unknown', () async {
      final resp = await _post('/v1/connections/unknown/test');
      expect(resp.statusCode, 404);
    });

    test('GET /v1/connections/:id/reset returns 404 for unknown', () async {
      final resp = await _post('/v1/connections/unknown/reset');
      expect(resp.statusCode, 404);
    });

    test('POST /v1/connections/import-session requires state field', () async {
      final resp = await _post('/v1/connections/import-session', body: {});
      expect(resp.statusCode, 400);
      expect(jsonDecode(resp.body)['error'], contains('state required'));
    });
  });

  group('Proxy CORS', () {
    late String base;

    setUp(() async {
      base = await startProxy(store: store, cfg: cfg, auth: auth, rotator: rotator);
    });

    test('OPTIONS returns correct CORS headers', () async {
      final req = http.Request('OPTIONS', Uri.parse('$base/v1/health'));
      final resp = await req.send();
      expect(resp.statusCode, 204);
      final headers = resp.headers;
      expect(headers['access-control-allow-origin'], '*');
      expect(headers['access-control-allow-methods'], contains('GET'));
    });
  });
}
