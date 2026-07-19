import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/account.dart';
import '../models/config.dart';
import '../services/oauth.dart';
import '../services/rotator.dart';

// ---------------------------------------------------------------------------
// Proxy server — HTTP REST API + OpenAI-compatible proxy
// ---------------------------------------------------------------------------

class ProxyServer {
  final Config cfg;
  final Store store;
  final OAuthClient auth;
  final Rotator rotator;
  final DateTime startedAt = DateTime.now();

  ProxyServer({
    required this.cfg,
    required this.store,
    required this.auth,
    required this.rotator,
  });

  Future<void> run() async {
    final server = await HttpServer.bind(cfg.serverHost, cfg.serverPort);
    print('Server on http://${cfg.serverHost}:${cfg.serverPort}');
    server.listen((req) => _handle(req));
  }

  Future<void> _handle(HttpRequest req) async {
    final p = req.uri.path;

    // CORS preflight
    if (req.method == 'OPTIONS') {
      _cors(req);
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    try {
      if (p == '/' || p == '/v1/health') _health(req);
      else if (p == '/openapi.json') _openapi(req);
      else if (p == '/v1/config') {
        if (req.method == 'GET') _getConfig(req);
        else if (req.method == 'PATCH' || req.method == 'POST') await _patchConfig(req);
        else _methodNotAllowed(req);
      }
      else if (p == '/v1/logs') _logs(req);
      else if (p == '/v1/connections') _listConnections(req);
      else if (p == '/v1/connections/login-official') await _startLoginOfficial(req);
      else if (p == '/v1/connections/import') await _importConnection(req);
      else if (p == '/v1/connections/import-session') await _importSession(req);
      else if (p == '/v1/connections/test-all') await _testAll(req);
      else if (p.startsWith('/v1/connections/')) await _handleConnectionById(req, p);
      else if (p == '/v1/rotation/rotate') await _rotateNow(req);
      else if (p == '/v1/rotation/state') _rotationState(req);
      else if (p == '/v1/rotation/strategy') _strategy(req);
      else if (p == '/v1/token') await _getToken(req);
      else if (p == '/v1/probe') await _probe(req);
      else if (p == '/v1/chat/completions') await _proxyChat(req);
      else if (p == '/v1/models') _models(req);
      else if (p.startsWith('/v1/')) _notFound(req);
      else _notFound(req);
    } catch (e) {
      _error(req, 500, e.toString());
    }
  }

  void _cors(HttpRequest req) {
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    req.response.headers.set('Access-Control-Allow-Headers', 'Authorization, Content-Type, Origin, X-Requested-With');
    req.response.headers.set('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE, OPTIONS');
  }

  void _health(HttpRequest req) => _ok(req, {'ok': true, 'version': '1.0.0', 'started_at': startedAt.toIso8601String(), 'accounts': store.loadAll().length, 'strategy': cfg.rotationStrategy.name});

  void _openapi(HttpRequest req) => _okJson(req, 200, '{"openapi":"3.0.0"}');

  void _getConfig(HttpRequest req) => _ok(req, cfg.snapshot());

  Future<void> _patchConfig(HttpRequest req) async {
    final body = await utf8.decodeStream(req);
    final u = jsonDecode(body) as Map<String, dynamic>;
    cfg.apply(u);
    cfg.save();
    _ok(req, cfg.snapshot());
  }

  void _logs(HttpRequest req) => _ok(req, {'logs': []});

  void _listConnections(HttpRequest req) {
    final state = store.loadState();
    final conns = store.loadAll().map((a) => _viewAccount(a, state)).toList();
    _ok(req, {'connections': conns, 'current_id': state.currentId, 'strategy': cfg.rotationStrategy.name});
  }

  Future<void> _startLoginOfficial(HttpRequest req) async {
    try {
      final result = await auth.startLoginOfficial();
      _ok(req, {
        'auth_url': result.authUrl,
        'state': result.state,
        'message': 'Open auth_url in any browser. After login, copy the `session_code` parameter from the URL bar (or the `state` param) and POST it to /v1/connections/import-session',
      });
    } catch (e) {
      _error(req, 502, e.toString());
    }
  }

  Future<void> _importConnection(HttpRequest req) async {
    final body = await utf8.decodeStream(req);
    final j = jsonDecode(body) as Map;
    if (j['access_token'] == null) { _error(req, 400, 'access_token required'); return; }

    String? userId = j['user_id'] as String?;
    String email = j['email'] as String? ?? '';
    if (userId == null) {
      final info = await auth.userInfo(j['access_token'] as String);
      if (info != null) {
        userId = info['sub'] as String? ?? info['preferred_username'] as String?;
        if (email.isEmpty) email = info['email'] as String? ?? '';
      }
    }

    final exp = Duration(seconds: (j['expires_in'] as int? ?? 3600));
    final a = Account(
      id: accountIdFromToken(j['access_token'] as String),
      label: j['label'] as String? ?? 'imported',
      userId: userId ?? '',
      email: email,
      accessToken: j['access_token'] as String,
      refreshToken: j['refresh_token'] as String? ?? '',
      idToken: j['id_token'] as String? ?? '',
      tokenType: j['token_type'] as String? ?? '',
      scope: j['scope'] as String? ?? '',
      expiresAt: DateTime.now().add(exp),
      state: AcctState.ok,
      priority: _nextPriority(),
      note: j['note'] as String? ?? '',
    );
    store.save(a);
    _ok(req, _viewAccount(a, store.loadState()));
  }

  Future<void> _importSession(HttpRequest req) async {
    final body = await utf8.decodeStream(req);
    final j = jsonDecode(body) as Map;
    final stateParam = j['state'] as String?;
    if (stateParam == null || stateParam.isEmpty) {
      _error(req, 400, 'state required (the session_code from the auth flow)');
      return;
    }
    try {
      final token = await auth.fetchTokenByState(stateParam);
      final a = Account(
        id: accountIdFromToken(token.accessToken),
        label: j['label'] as String? ?? 'session',
        userId: token.userId,
        accessToken: token.accessToken,
        refreshToken: token.refreshToken,
        idToken: token.idToken,
        tokenType: token.tokenType,
        scope: token.scope,
        expiresAt: DateTime.now().add(Duration(seconds: token.expiresIn)),
        state: AcctState.ok,
        priority: _nextPriority(),
        note: 'imported via session_code',
      );
      store.save(a);
      _ok(req, _viewAccount(a, store.loadState()));
    } catch (e) {
      _error(req, 502, '${e}\nhint: session_code may have expired; try logging in again and capture the fresh code');
    }
  }

  Future<void> _testAll(HttpRequest req) async {
    await rotator.probeAll();
    final state = store.loadState();
    final conns = store.loadAll().map((a) => _viewAccount(a, state)).toList();
    _ok(req, {'connections': conns, 'current_id': state.currentId, 'strategy': cfg.rotationStrategy.name});
  }

  Future<void> _handleConnectionById(HttpRequest req, String p) async {
    final parts = p.split('/');
    if (parts.length < 3) { _notFound(req); return; }
    final id = parts[3];
    final sub = parts.length > 4 ? parts[4] : '';

    if (sub == 'test') {
      final a = await rotator.probeAccount(id);
      if (a == null) { _notFound(req); return; }
      _ok(req, _viewAccount(a, store.loadState()));
      return;
    }
    if (sub == 'reset') {
      store.markChecked(id, AcctState.unknown, 'manually reset');
      final a = store.find(id);
      if (a == null) { _notFound(req); return; }
      _ok(req, _viewAccount(a, store.loadState()));
      return;
    }

    if (req.method == 'GET') {
      final a = store.find(id);
      if (a == null) { _notFound(req); return; }
      _ok(req, _viewAccount(a, store.loadState()));
    } else if (req.method == 'DELETE') {
      store.delete(id);
      _ok(req, {'ok': true, 'deleted': id});
    } else if (req.method == 'PATCH' || req.method == 'POST') {
      final body = await utf8.decodeStream(req);
      final j = jsonDecode(body) as Map;
      final a = store.find(id);
      if (a == null) { _notFound(req); return; }
      if (j['enabled'] != null) a.enabled = j['enabled'] as bool;
      if (j['label'] != null) a.label = j['label'] as String;
      if (j['priority'] != null) a.priority = (j['priority'] as num).toInt();
      if (j['note'] != null) a.note = j['note'] as String;
      store.save(a);
      _ok(req, _viewAccount(a, store.loadState()));
    } else {
      _methodNotAllowed(req);
    }
  }

  Future<void> _rotateNow(HttpRequest req) async {
    final acc = rotator.forceRotate();
    if (acc == null) { _error(req, 500, 'no accounts'); return; }
    _ok(req, {'ok': true, 'account': _viewAccount(acc, store.loadState())});
  }

  void _rotationState(HttpRequest req) {
    final state = store.loadState();
    final accounts = store.loadAll();
    Account? current;
    if (state.currentId.isNotEmpty) {
      current = accounts.where((a) => a.id == state.currentId).firstOrNull;
    }
    _ok(req, {
      'state': state.toJson(),
      'current': current != null ? _viewAccount(current, state) : null,
      'strategy': cfg.rotationStrategy.name,
      'settings': cfg.snapshot(),
    });
  }

  void _strategy(HttpRequest req) {
    if (req.method == 'GET') {
      _ok(req, {'strategy': cfg.rotationStrategy.name});
      return;
    }
    // POST/PATCH - must read body
    // For now just GET
    _methodNotAllowed(req);
  }

  Future<void> _getToken(HttpRequest req) async {
    final acc = await rotator.get();
    if (acc == null) { _error(req, 500, 'no accounts'); return; }
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.text;
    req.response.write(acc.accessToken);
    await req.response.close();
  }

  Future<void> _probe(HttpRequest req) async {
    final candidates = [
      'console', 'codebuddy-cli', 'codebuddy-cli-public', 'codebuddy',
      'codebuddy-code', 'codebuddy-public', 'codebuddy-code-cli',
      'codebuddy-ide', 'codebuddy-web', 'codebuddy-vscode', 'codebuddy-jb',
      'copilot-cli', 'copilot', 'tencent-copilot', 'tencent-codebuddy',
      'Tencent-Cloud.coding-copilot', 'Tencent-Cloud.coding-copilot-vs',
    ];
    final results = <Map<String, dynamic>>[];
    for (final cid in candidates) {
      try {
        final meta = await auth.discover();
        final u = '${meta.authorizationEndpoint}?client_id=$cid&response_type=code&redirect_uri=${cfg.bridgeUrl}/auth/callback&scope=${cfg.scopes}&state=probe&code_challenge=Yh-npV_wGErE-5M4oFxsZN2FY0F4LCeOS9kpfXvgKdo&code_challenge_method=S256';
        final resp = await http.get(Uri.parse(u), headers: {'Accept': 'text/html'});
        final text = resp.body;
        var result = 'no-response';
        var msg = '';
        if (text.contains('kc-form-login') && !text.contains('result-icon error-icon')) {
          result = 'valid-client-login-form';
          msg = 'client_id is registered; realm ready to authenticate you';
        } else if (text.contains('账号不存在') || text.contains('account does not exist')) {
          result = 'valid-client-no-account';
          msg = 'client_id registered, but your account is NOT in this realm.';
        }
        results.add({'client_id': cid, 'http_status': resp.statusCode, 'result': result, 'error_message': msg, 'response_bytes': text.length});
      } catch (e) {
        results.add({'client_id': cid, 'result': 'error', 'error_message': e.toString()});
      }
    }
    _ok(req, {'issuer': cfg.issuer, 'results': results});
  }

  // ---------------------------------------------------------------------------
  // OpenAI-compatible proxy
  // ---------------------------------------------------------------------------

  Future<void> _proxyChat(HttpRequest req) async {
    final body = await utf8.decodeStream(req);
    final acc = await rotator.get();
    if (acc == null) {
      req.response.statusCode = 503;
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"error":"no accounts","rotate":true}');
      await req.response.close();
      return;
    }

    final upstream = await http.post(
      Uri.parse('${cfg.codebuddyApiBase.replaceAll(RegExp(r'/+$'), '')}/v2/chat/completions'),
      headers: {'Authorization': 'Bearer ${acc.accessToken}', 'Content-Type': 'application/json'},
      body: body,
    );
    req.response.statusCode = upstream.statusCode;
    req.response.headers.contentType = ContentType.json;
    req.response.write(upstream.body);
    await req.response.close();

    if (upstream.statusCode == 401 || upstream.statusCode == 403) {
      store.markChecked(acc.id, AcctState.expired, 'upstream HTTP ${upstream.statusCode}');
    }
  }

  void _models(HttpRequest req) => _ok(req, {'data': [
    {'id': 'gpt-5.4', 'object': 'model', 'owned_by': 'codebuddy'},
    {'id': 'gpt-5.5', 'object': 'model', 'owned_by': 'codebuddy'},
  ], 'object': 'list'});

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _viewAccount(Account a, RotatorState state) => {
    'id': a.id,
    'label': a.label,
    'user_id': a.userId,
    'email': a.email,
    'enabled': a.enabled,
    'priority': a.priority,
    'state': a.state.name,
    'state_msg': a.stateMsg,
    'expires_at': a.expiresAt.toIso8601String(),
    'created_at': a.createdAt.toIso8601String(),
    'last_used_at': a.lastUsedAt.year > 2000 ? a.lastUsedAt.toIso8601String() : null,
    'last_check': a.lastCheckAt.year > 2000 ? a.lastCheckAt.toIso8601String() : null,
    'use_count': a.useCount,
    'note': a.note,
    'is_current': state.currentId == a.id,
  };

  int _nextPriority() {
    var max = 0;
    for (final a in store.loadAll()) {
      if (a.priority > max) max = a.priority;
    }
    return max + 1;
  }

  void _ok(HttpRequest req, dynamic v) => _okJson(req, 200, jsonEncode(v));
  void _okJson(HttpRequest req, int status, String body) {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    req.response.write(body);
    req.response.close();
  }

  void _error(HttpRequest req, int status, String msg) => _okJson(req, status, jsonEncode({'error': msg}));
  void _notFound(HttpRequest req) => _okJson(req, 404, jsonEncode({'error': 'not found'}));
  void _methodNotAllowed(HttpRequest req) => _okJson(req, 405, jsonEncode({'error': 'method not allowed'}));
}