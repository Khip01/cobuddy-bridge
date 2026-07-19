import 'dart:convert';
import 'package:test/test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import '../../lib/src/models/config.dart';
import '../../lib/src/services/oauth.dart';

void main() {
  group('OidcDiscovery', () {
    test('fromJson parses all fields', () {
      final j = {
        'issuer': 'https://example.com',
        'authorization_endpoint': 'https://example.com/auth',
        'token_endpoint': 'https://example.com/token',
        'userinfo_endpoint': 'https://example.com/userinfo',
        'revocation_endpoint': 'https://example.com/revoke',
        'device_authorization_endpoint': 'https://example.com/device',
      };
      final d = OidcDiscovery.fromJson(j);
      expect(d.issuer, 'https://example.com');
      expect(d.authorizationEndpoint, 'https://example.com/auth');
      expect(d.tokenEndpoint, 'https://example.com/token');
      expect(d.userinfoEndpoint, 'https://example.com/userinfo');
      expect(d.revocationEndpoint, 'https://example.com/revoke');
      expect(d.deviceAuthorizationEndpoint, 'https://example.com/device');
    });

    test('fromJson handles missing fields', () {
      final d = OidcDiscovery.fromJson({});
      expect(d.issuer, '');
      expect(d.authorizationEndpoint, '');
      expect(d.tokenEndpoint, '');
    });
  });

  group('OAuthClient PKCE', () {
    test('pkce generates verifier and challenge', () {
      final cfg = Config();
      final oa = OAuthClient(cfg);
      final result = oa.pkce();
      expect(result.verifier, isNotEmpty);
      expect(result.challenge, isNotEmpty);
      expect(result.verifier, isNot(result.challenge));
    });

    test('pkce produces URL-safe base64 (no padding)', () {
      final cfg = Config();
      final oa = OAuthClient(cfg);
      final result = oa.pkce();
      expect(result.verifier, isNot(contains('=')));
      expect(result.challenge, isNot(contains('=')));
      expect(result.verifier, isNot(contains('+')));
      expect(result.verifier, isNot(contains('/')));
    });
  });

  group('OAuthClient discover', () {
    test('fetches and caches discovery document', () async {
      final cfg = Config();
      cfg.issuer = 'https://op.example.com';

      final mock = MockClient((req) async {
        expect(req.url.toString(), 'https://op.example.com/.well-known/openid-configuration');
        expect(req.headers['accept'], 'application/json');
        return http.Response(jsonEncode({
          'issuer': 'https://op.example.com',
          'authorization_endpoint': 'https://op.example.com/auth',
          'token_endpoint': 'https://op.example.com/token',
        }), 200);
      });

      final oa = OAuthClient(cfg, client: mock);
      final meta = await oa.discover();
      expect(meta.issuer, 'https://op.example.com');
      expect(meta.authorizationEndpoint, 'https://op.example.com/auth');

      // Second call should use cache
      final meta2 = await oa.discover();
      expect(meta2.issuer, 'https://op.example.com');
    });

    test('throws on non-200 response', () async {
      final cfg = Config();
      final mock = MockClient((req) async {
        return http.Response('Not Found', 404);
      });
      final oa = OAuthClient(cfg, client: mock);
      expect(() => oa.discover(), throwsA(isA<Exception>()));
    });
  });

  group('OAuthClient buildAuthorizationUrl', () {
    test('builds URL with correct parameters', () async {
      final cfg = Config();
      cfg.issuer = 'https://idp.example.com';
      final mock = MockClient((req) async {
        return http.Response(jsonEncode({
          'issuer': 'https://idp.example.com',
          'authorization_endpoint': 'https://idp.example.com/protocol/openid-connect/auth',
          'token_endpoint': 'https://idp.example.com/protocol/openid-connect/token',
        }), 200);
      });

      final oa = OAuthClient(cfg, client: mock);
      final url = await oa.buildAuthorizationUrl('state123', 'verifier456');

      expect(url, startsWith('https://idp.example.com/protocol/openid-connect/auth'));
      expect(url, contains('response_type=code'));
      expect(url, contains('client_id=console'));
      expect(url, contains('state=state123'));
      expect(url, contains('code_challenge_method=S256'));
    });
  });

  group('OAuthClient _parseToken', () {
    test('fetchTokenByState parses token from response', () async {
      final cfg = Config();
      cfg.codebuddyApiBase = 'https://api.test.com';
      final mock = MockClient((req) async {
        return http.Response(jsonEncode({
          'code': 0,
          'data': {
            'accessToken': 'at_from_state',
            'refreshToken': 'rt_from_state',
            'expiresIn': 3600,
            'userId': 'user_abc',
          },
        }), 200);
      });
      final oa = OAuthClient(cfg, client: mock);
      final t = await oa.fetchTokenByState('state_1');
      expect(t.accessToken, 'at_from_state');
      expect(t.refreshToken, 'rt_from_state');
      expect(t.expiresIn, 3600);
      expect(t.userId, 'user_abc');
    });

    test('parses minimal token response with default values', () async {
      final cfg = Config();
      cfg.codebuddyApiBase = 'https://api.test.com';
      final mock = MockClient((req) async {
        return http.Response(jsonEncode({
          'code': 0,
          'data': {
            'accessToken': 'at_min',
          },
        }), 200);
      });
      final oa = OAuthClient(cfg, client: mock);
      final t = await oa.fetchTokenByState('state_2');
      expect(t.accessToken, 'at_min');
      expect(t.refreshToken, '');
      expect(t.expiresIn, 0);
    });
  });

  group('OAuthClient fetchTokenByState', () {
    test('extracts token from CodeBuddy API response', () async {
      final cfg = Config();
      cfg.codebuddyApiBase = 'https://api.test.com';

      final mock = MockClient((req) async {
        expect(req.url.toString(), 'https://api.test.com/v2/plugin/auth/token?state=test_state');
        expect(req.headers['X-No-Authorization'], 'true');
        return http.Response(jsonEncode({
          'code': 0,
          'data': {
            'accessToken': 'at_from_state',
            'refreshToken': 'rt_from_state',
            'expiresIn': 7200,
            'userId': 'user_state',
          },
        }), 200);
      });

      final oa = OAuthClient(cfg, client: mock);
      final t = await oa.fetchTokenByState('test_state');
      expect(t.accessToken, 'at_from_state');
      expect(t.refreshToken, 'rt_from_state');
      expect(t.expiresIn, 7200);
      expect(t.userId, 'user_state');
    });

    test('throws when code != 0', () async {
      final cfg = Config();
      final mock = MockClient((req) async {
        return http.Response(jsonEncode({
          'code': 1,
          'msg': 'state expired',
          'data': null,
        }), 200);
      });
      final oa = OAuthClient(cfg, client: mock);
      expect(() => oa.fetchTokenByState('bad_state'), throwsA(isA<Exception>()));
    });

    test('throws on HTTP error', () async {
      final cfg = Config();
      final mock = MockClient((req) async {
        return http.Response('Bad Gateway', 502);
      });
      final oa = OAuthClient(cfg, client: mock);
      expect(() => oa.fetchTokenByState('x'), throwsA(isA<Exception>()));
    });
  });

  group('OAuthClient startLoginOfficial', () {
    test('extracts authUrl and state', () async {
      final cfg = Config();
      cfg.codebuddyApiBase = 'https://api.test.com';

      final mock = MockClient((req) async {
        expect(req.url.toString(), 'https://api.test.com/v2/plugin/auth/state?platform=cli');
        expect(req.method, 'POST');
        return http.Response(jsonEncode({
          'code': 0,
          'data': {
            'authUrl': 'https://auth.test.com/login',
            'state': 'login_state_123',
          },
        }), 200);
      });

      final oa = OAuthClient(cfg, client: mock);
      final result = await oa.startLoginOfficial();
      expect(result.authUrl, 'https://auth.test.com/login');
      expect(result.state, 'login_state_123');
    });

    test('throws on error code', () async {
      final cfg = Config();
      final mock = MockClient((req) async {
        return http.Response(jsonEncode({
          'code': 500,
          'msg': 'server error',
          'data': null,
        }), 200);
      });
      final oa = OAuthClient(cfg, client: mock);
      expect(() => oa.startLoginOfficial(), throwsA(isA<Exception>()));
    });
  });

  group('OAuthClient deviceAuth', () {
    test('throws when endpoint is missing', () async {
      final cfg = Config();
      final mock = MockClient((req) async {
        return http.Response(jsonEncode({
          'issuer': 'https://op.example.com',
          'authorization_endpoint': 'https://op.example.com/auth',
          'token_endpoint': 'https://op.example.com/token',
        }), 200);
      });
      final oa = OAuthClient(cfg, client: mock);
      expect(() => oa.deviceAuth(), throwsA(isA<Exception>()));
    });
  });

  group('OAuthClient userInfo', () {
    test('returns null when endpoint not advertised', () async {
      final cfg = Config();
      final mock = MockClient((req) async {
        return http.Response(jsonEncode({
          'issuer': 'https://op.example.com',
          'authorization_endpoint': 'https://op.example.com/auth',
          'token_endpoint': 'https://op.example.com/token',
        }), 200);
      });
      final oa = OAuthClient(cfg, client: mock);
      final info = await oa.userInfo('some_token');
      expect(info, isNull);
    });

    test('returns null on HTTP error', () async {
      final cfg = Config();
      final mock = MockClient((req) async {
        if (req.url.toString().contains('openid-configuration')) {
          return http.Response(jsonEncode({
            'userinfo_endpoint': 'https://op.example.com/userinfo',
          }), 200);
        }
        return http.Response('Unauthorized', 401);
      });
      final oa = OAuthClient(cfg, client: mock);
      final info = await oa.userInfo('bad_token');
      expect(info, isNull);
    });

    test('returns user info on success', () async {
      final cfg = Config();
      final mock = MockClient((req) async {
        if (req.url.toString().contains('openid-configuration')) {
          return http.Response(jsonEncode({
            'userinfo_endpoint': 'https://op.example.com/userinfo',
            'authorization_endpoint': 'https://op.example.com/auth',
            'token_endpoint': 'https://op.example.com/token',
          }), 200);
        }
        return http.Response(jsonEncode({
          'sub': 'user123',
          'email': 'test@example.com',
          'name': 'Test User',
        }), 200);
      });
      final oa = OAuthClient(cfg, client: mock);
      final info = await oa.userInfo('valid_token');
      expect(info, isNotNull);
      expect(info!['sub'], 'user123');
      expect(info['email'], 'test@example.com');
    });
  });

  group('OAuthClient exchangeCode', () {
    test('exchanges code for tokens', () async {
      final cfg = Config();
      cfg.issuer = 'https://op.example.com';

      var discoveryDone = false;
      final mock = MockClient((req) async {
        if (!discoveryDone) {
          discoveryDone = true;
          return http.Response(jsonEncode({
            'issuer': 'https://op.example.com',
            'authorization_endpoint': 'https://op.example.com/auth',
            'token_endpoint': 'https://op.example.com/token',
          }), 200);
        }
        expect(req.method, 'POST');
        expect(req.url.toString(), 'https://op.example.com/token');
        return http.Response(jsonEncode({
          'access_token': 'exchanged_at',
          'refresh_token': 'exchanged_rt',
          'id_token': 'id',
          'token_type': 'Bearer',
          'scope': 'openid',
          'expires_in': 3600,
        }), 200);
      });

      final oa = OAuthClient(cfg, client: mock);
      final t = await oa.exchangeCode('auth_code', 'verifier');
      expect(t.accessToken, 'exchanged_at');
      expect(t.refreshToken, 'exchanged_rt');
    });

    test('throws on non-200', () async {
      final cfg = Config();
      final mock = MockClient((req) async {
        if (req.url.toString().contains('openid-configuration')) {
          return http.Response(jsonEncode({
            'issuer': 'https://op.example.com',
            'authorization_endpoint': 'https://op.example.com/auth',
            'token_endpoint': 'https://op.example.com/token',
          }), 200);
        }
        return http.Response('error', 400);
      });
      final oa = OAuthClient(cfg, client: mock);
      expect(() => oa.exchangeCode('code', 'ver'), throwsA(isA<Exception>()));
    });
  });

  group('OAuthClient refresh', () {
    test('refreshes token successfully', () async {
      final cfg = Config();
      cfg.issuer = 'https://op.example.com';

      var discoDone = false;
      final mock = MockClient((req) async {
        if (!discoDone) {
          discoDone = true;
          return http.Response(jsonEncode({
            'issuer': 'https://op.example.com',
            'authorization_endpoint': 'https://op.example.com/auth',
            'token_endpoint': 'https://op.example.com/token',
          }), 200);
        }
        return http.Response(jsonEncode({
          'access_token': 'refreshed_at',
          'refresh_token': 'new_rt',
          'expires_in': 3600,
        }), 200);
      });

      final oa = OAuthClient(cfg, client: mock);
      final t = await oa.refresh('old_refresh_token');
      expect(t.accessToken, 'refreshed_at');
    });
  });

  group('OAuthClient devicePoll', () {
    test('throws PendingError on 400 with error field', () async {
      final cfg = Config();
      final mock = MockClient((req) async {
        if (req.url.toString().contains('openid-configuration')) {
          return http.Response(jsonEncode({
            'issuer': 'https://op.example.com',
            'authorization_endpoint': 'https://op.example.com/auth',
            'token_endpoint': 'https://op.example.com/token',
          }), 200);
        }
        return http.Response(jsonEncode({'error': 'authorization_pending'}), 400);
      });
      final oa = OAuthClient(cfg, client: mock);
      expect(() => oa.devicePoll('dev_code'), throwsA(isA<PendingError>()));
    });
  });

  group('OAuthClient quotaProbe', () {
    test('returns error when URL not configured', () async {
      final cfg = Config();
      cfg.quotaProbeUrl = '';
      final oa = OAuthClient(cfg);
      final r = await oa.quotaProbe('token');
      expect(r.error, isNotNull);
      expect(r.status, 0);
    });

    test('returns HTTP result on success', () async {
      final cfg = Config();
      cfg.quotaProbeUrl = 'https://api.test.com/quota';
      final mock = MockClient((req) async {
        return http.Response(jsonEncode({'remaining': 100}), 200);
      });
      final oa = OAuthClient(cfg, client: mock);
      final r = await oa.quotaProbe('token');
      expect(r.status, 200);
      expect(r.body, contains('remaining'));
      expect(r.error, isNull);
    });

    test('handles network error gracefully', () async {
      final cfg = Config();
      cfg.quotaProbeUrl = 'https://api.test.com/quota';
      final mock = MockClient((req) async {
        throw Exception('Connection refused');
      });
      final oa = OAuthClient(cfg, client: mock);
      final r = await oa.quotaProbe('token');
      expect(r.error, isNotNull);
      expect(r.status, 0);
    });
  });
}
