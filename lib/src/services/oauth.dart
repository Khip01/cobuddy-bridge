import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import '../models/config.dart';

// ---------------------------------------------------------------------------
// OAuth service — OIDC discovery, PKCE, device auth, token exchange, refresh
// ---------------------------------------------------------------------------

class OidcDiscovery {
  final String issuer;
  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String userinfoEndpoint;
  final String revocationEndpoint;
  final String deviceAuthorizationEndpoint;

  OidcDiscovery({
    required this.issuer,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.userinfoEndpoint = '',
    this.revocationEndpoint = '',
    this.deviceAuthorizationEndpoint = '',
  });

  factory OidcDiscovery.fromJson(Map<String, dynamic> j) => OidcDiscovery(
    issuer: j['issuer'] as String? ?? '',
    authorizationEndpoint: j['authorization_endpoint'] as String? ?? '',
    tokenEndpoint: j['token_endpoint'] as String? ?? '',
    userinfoEndpoint: j['userinfo_endpoint'] as String? ?? '',
    revocationEndpoint: j['revocation_endpoint'] as String? ?? '',
    deviceAuthorizationEndpoint: j['device_authorization_endpoint'] as String? ?? '',
  );
}

class TokenResponse {
  final String accessToken;
  final String refreshToken;
  final String idToken;
  final String tokenType;
  final String scope;
  final int expiresIn;
  final int refreshIn;
  final String userId;

  TokenResponse({
    required this.accessToken,
    this.refreshToken = '',
    this.idToken = '',
    this.tokenType = '',
    this.scope = '',
    this.expiresIn = 0,
    this.refreshIn = 0,
    this.userId = '',
  });
}

class DeviceAuthResponse {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final String verificationUriComplete;
  final int expiresIn;
  final int interval;

  DeviceAuthResponse({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    this.verificationUriComplete = '',
    required this.expiresIn,
    this.interval = 5,
  });
}

class PendingError implements Exception {
  final String reason;
  PendingError(this.reason);
  @override
  String toString() => reason;
}

// ---------------------------------------------------------------------------
// OAuth client
// ---------------------------------------------------------------------------

class OAuthClient {
  final Config cfg;
  final http.Client _hc = http.Client();
  OidcDiscovery? _meta;
  DateTime _metaAt = DateTime(1);

  OAuthClient(this.cfg);

  Future<OidcDiscovery> discover() async {
    if (_meta != null && DateTime.now().difference(_metaAt).inHours < 1) {
      return _meta!;
    }
    final u = '${cfg.issuer.replaceAll(RegExp(r'/+$'), '')}/.well-known/openid-configuration';
    final resp = await _hc.get(Uri.parse(u), headers: {'Accept': 'application/json'});
    if (resp.statusCode != 200) {
      throw Exception('discover $u: HTTP ${resp.statusCode}: ${resp.body}');
    }
    _meta = OidcDiscovery.fromJson(jsonDecode(resp.body));
    _metaAt = DateTime.now();
    return _meta!;
  }

  /// Generate PKCE verifier + S256 challenge
  ({String verifier, String challenge}) pkce() {
    final buf = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final verifier = base64Url.encode(buf).replaceAll('=', '');
    final sum = sha256.convert(utf8.encode(verifier));
    final challenge = base64Url.encode(sum.bytes).replaceAll('=', '');
    return (verifier: verifier, challenge: challenge);
  }

  /// Build authorization URL
  Future<String> buildAuthorizationUrl(String state, String verifier) async {
    final meta = await discover();
    final challenge = base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
    final q = {
      'response_type': 'code',
      'client_id': cfg.clientId,
      'redirect_uri': '${cfg.bridgeUrl}/auth/callback',
      'scope': cfg.scopes,
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    };
    final uri = Uri.parse(meta.authorizationEndpoint).replace(queryParameters: q);
    return uri.toString();
  }

  /// Exchange authorization code for tokens
  Future<TokenResponse> exchangeCode(String code, String verifier) async {
    final meta = await discover();
    final resp = await _hc.post(
      Uri.parse(meta.tokenEndpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json'},
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': '${cfg.bridgeUrl}/auth/callback',
        'client_id': cfg.clientId,
        'code_verifier': verifier,
      },
    );
    if (resp.statusCode != 200) {
      throw Exception('exchange: HTTP ${resp.statusCode}: ${resp.body}');
    }
    return _parseToken(resp.body);
  }

  /// Refresh token
  Future<TokenResponse> refresh(String refreshToken) async {
    final meta = await discover();
    final resp = await _hc.post(
      Uri.parse(meta.tokenEndpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json'},
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': cfg.clientId,
        'scope': cfg.scopes,
      },
    );
    if (resp.statusCode != 200) {
      throw Exception('refresh: HTTP ${resp.statusCode}: ${resp.body}');
    }
    return _parseToken(resp.body);
  }

  /// Device authorization (RFC 8628)
  Future<DeviceAuthResponse> deviceAuth() async {
    final meta = await discover();
    if (meta.deviceAuthorizationEndpoint.isEmpty) {
      throw Exception('issuer does not advertise device_authorization_endpoint');
    }
    final resp = await _hc.post(
      Uri.parse(meta.deviceAuthorizationEndpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json'},
      body: {'client_id': cfg.clientId, 'scope': cfg.scopes},
    );
    if (resp.statusCode != 200) {
      throw Exception('device auth: HTTP ${resp.statusCode}: ${resp.body}');
    }
    final d = jsonDecode(resp.body) as Map;
    return DeviceAuthResponse(
      deviceCode: d['device_code'] as String,
      userCode: d['user_code'] as String,
      verificationUri: d['verification_uri'] as String,
      verificationUriComplete: d['verification_uri_complete'] as String? ?? '',
      expiresIn: d['expires_in'] as int,
      interval: d['interval'] as int? ?? 5,
    );
  }

  /// Poll device auth status
  Future<TokenResponse> devicePoll(String deviceCode) async {
    final meta = await discover();
    final resp = await _hc.post(
      Uri.parse(meta.tokenEndpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json'},
      body: {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'device_code': deviceCode,
        'client_id': cfg.clientId,
      },
    );
    if (resp.statusCode == 400) {
      final e = jsonDecode(resp.body) as Map;
      throw PendingError(e['error'] as String? ?? 'unknown');
    }
    if (resp.statusCode != 200) {
      throw Exception('device poll: HTTP ${resp.statusCode}: ${resp.body}');
    }
    return _parseToken(resp.body);
  }

  /// Fetch userinfo (best-effort)
  Future<Map<String, dynamic>?> userInfo(String accessToken) async {
    try {
      final meta = await discover();
      if (meta.userinfoEndpoint.isEmpty) return null;
      final resp = await _hc.get(
        Uri.parse(meta.userinfoEndpoint),
        headers: {'Authorization': 'Bearer $accessToken', 'Accept': 'application/json'},
      );
      if (resp.statusCode != 200) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Quota probe — checks billing/quota endpoint
  Future<({int status, String body, String? error})> quotaProbe(String accessToken) async {
    if (cfg.quotaProbeUrl.isEmpty) {
      return (status: 0, body: '', error: 'quota probe URL not configured');
    }
    try {
      final resp = await _hc.get(
        Uri.parse(cfg.quotaProbeUrl),
        headers: {'Authorization': 'Bearer $accessToken', 'Accept': 'application/json'},
      );
      return (status: resp.statusCode, body: resp.body, error: null);
    } catch (e) {
      return (status: 0, body: '', error: e.toString());
    }
  }

  /// Fetch token by state (CodeBuddy's official flow)
  Future<TokenResponse> fetchTokenByState(String state) async {
    final url = '${cfg.codebuddyApiBase.replaceAll(RegExp(r'/+$'), '')}/v2/plugin/auth/token?state=$state';
    final resp = await _hc.get(
      Uri.parse(url),
      headers: {
        'Accept': 'application/json',
        'X-No-Authorization': 'true',
        'X-No-User-Id': 'true',
        'X-No-Enterprise-Id': 'true',
        'X-No-Department-Info': 'true',
      },
    );
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    final wrapper = jsonDecode(resp.body) as Map;
    final code = wrapper['code'] as int? ?? -1;
    if (code != 0 || wrapper['data'] == null) {
      throw Exception('auth not ready: code=$code msg=${wrapper['msg']}');
    }
    final d = wrapper['data'] as Map;
    return TokenResponse(
      accessToken: d['accessToken'] as String? ?? d['access_token'] as String? ?? '',
      refreshToken: d['refreshToken'] as String? ?? d['refresh_token'] as String? ?? '',
      idToken: d['idToken'] as String? ?? d['id_token'] as String? ?? '',
      tokenType: d['tokenType'] as String? ?? d['token_type'] as String? ?? '',
      scope: d['scope'] as String? ?? '',
      expiresIn: (d['expiresIn'] ?? d['expires_in'] ?? 0) as int,
      userId: d['userId'] as String? ?? d['user_id'] as String? ?? '',
    );
  }

  /// Start official CodeBuddy login
  Future<({String authUrl, String state})> startLoginOfficial() async {
    final url = '${cfg.codebuddyApiBase.replaceAll(RegExp(r'/+$'), '')}/v2/plugin/auth/state?platform=cli';
    final resp = await _hc.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
    );
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    final wrapper = jsonDecode(resp.body) as Map;
    final code = wrapper['code'] as int? ?? -1;
    if (code != 0 || wrapper['data'] == null) {
      throw Exception('no authUrl: code=$code msg=${wrapper['msg']}');
    }
    final d = wrapper['data'] as Map;
    return (
      authUrl: d['authUrl'] as String? ?? d['auth_url'] as String? ?? '',
      state: d['state'] as String? ?? '',
    );
  }

  TokenResponse _parseToken(String body) {
    final j = jsonDecode(body) as Map;
    return TokenResponse(
      accessToken: j['access_token'] as String? ?? '',
      refreshToken: j['refresh_token'] as String? ?? '',
      idToken: j['id_token'] as String? ?? '',
      tokenType: j['token_type'] as String? ?? '',
      scope: j['scope'] as String? ?? '',
      expiresIn: j['expires_in'] as int? ?? 0,
      refreshIn: j['refresh_in'] as int? ?? 0,
      userId: j['user_id'] as String? ?? '',
    );
  }
}