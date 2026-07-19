import 'dart:convert';
import 'dart:io';

const String configDir = '/home/khip/.config/codebuddy';
const String configPath = '$configDir/config.json';

enum RotationStrategy {
  exhaustedNext,
  exhaustedRandom,
  requestCountNext,
  requestCountRandom,
}

class Config {
  String issuer;
  String clientId;
  String identityProvider;
  String scopes;
  String bridgeUrl;
  RotationStrategy rotationStrategy;
  int rotationIntervalS;
  int requestsPerRotation;
  int quotaProbeIntervalS;
  String serverHost;
  int serverPort;
  String quotaProbeUrl;
  bool logsVisible;
  String codebuddyApiBase;

  Config({
    this.issuer = 'https://www.codebuddy.ai/auth/realms/copilot',
    this.clientId = 'console',
    this.identityProvider = 'github',
    this.scopes = 'openid profile email offline_access',
    this.bridgeUrl = '',
    this.rotationStrategy = RotationStrategy.exhaustedNext,
    this.rotationIntervalS = 300,
    this.requestsPerRotation = 5,
    this.quotaProbeIntervalS = 0,
    this.serverHost = '127.0.0.1',
    this.serverPort = 20130,
    this.quotaProbeUrl =
        'https://www.codebuddy.ai/v2/billing/meter/get-dosage-notify',
    this.logsVisible = true,
    this.codebuddyApiBase = 'https://www.codebuddy.ai',
  });

  static Config load() => _loadFrom(configPath);

  static Config _loadFrom(String path) {
    final f = File(path);
    if (!f.existsSync()) {
      final c = Config();
      c.save();
      return c;
    }
    final d = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    return Config(
      issuer:
          d['issuer'] as String? ??
          'https://www.codebuddy.ai/auth/realms/copilot',
      clientId: d['client_id'] as String? ?? 'console',
      identityProvider: d['identity_provider'] as String? ?? 'github',
      scopes: d['scopes'] as String? ?? 'openid profile email offline_access',
      bridgeUrl: d['bridge_url'] as String? ?? '',
      rotationStrategy: _parseStrategy(d['rotation_strategy'] as String? ?? ''),
      rotationIntervalS: d['rotation_interval_s'] as int? ?? 300,
      requestsPerRotation: d['requests_per_rotation'] as int? ?? 5,
      quotaProbeIntervalS: d['quota_probe_interval_s'] as int? ?? 0,
      serverHost: d['server_host'] as String? ?? '127.0.0.1',
      serverPort: d['server_port'] as int? ?? 20130,
      quotaProbeUrl:
          d['quota_probe_url'] as String? ??
          'https://www.codebuddy.ai/v2/billing/meter/get-dosage-notify',
      logsVisible: d['logs_visible'] as bool? ?? true,
      codebuddyApiBase:
          d['codebuddy_api_base'] as String? ?? 'https://www.codebuddy.ai',
    );
  }

  static RotationStrategy _parseStrategy(String s) {
    return switch (s) {
      'exhausted-random' => RotationStrategy.exhaustedRandom,
      'request-count-next' => RotationStrategy.requestCountNext,
      'request-count-random' => RotationStrategy.requestCountRandom,
      _ => RotationStrategy.exhaustedNext,
    };
  }

  void save() {
    Directory(configDir).createSync(recursive: true);
    File(configPath).writeAsStringSync(jsonEncode(toJson()));
  }

  Map<String, dynamic> toJson() => {
    'issuer': issuer,
    'client_id': clientId,
    'identity_provider': identityProvider,
    'scopes': scopes,
    'bridge_url': bridgeUrl,
    'rotation_strategy': _strategyName(rotationStrategy),
    'rotation_interval_s': rotationIntervalS,
    'requests_per_rotation': requestsPerRotation,
    'quota_probe_interval_s': quotaProbeIntervalS,
    'server_host': serverHost,
    'server_port': serverPort,
    'quota_probe_url': quotaProbeUrl,
    'logs_visible': logsVisible,
    'codebuddy_api_base': codebuddyApiBase,
  };

  static String _strategyName(RotationStrategy s) {
    return switch (s) {
      RotationStrategy.exhaustedNext => 'exhausted-next',
      RotationStrategy.exhaustedRandom => 'exhausted-random',
      RotationStrategy.requestCountNext => 'request-count-next',
      RotationStrategy.requestCountRandom => 'request-count-random',
    };
  }

  void apply(Map<String, dynamic> u) {
    if (u.containsKey('issuer') && u['issuer'] is String)
      issuer = u['issuer'] as String;
    if (u.containsKey('client_id') && u['client_id'] is String)
      clientId = u['client_id'] as String;
    if (u.containsKey('identity_provider') && u['identity_provider'] is String)
      identityProvider = u['identity_provider'] as String;
    if (u.containsKey('scopes') && u['scopes'] is String)
      scopes = u['scopes'] as String;
    if (u.containsKey('bridge_url') && u['bridge_url'] is String)
      bridgeUrl = u['bridge_url'] as String;
    if (u.containsKey('rotation_strategy') &&
        u['rotation_strategy'] is String) {
      rotationStrategy = _parseStrategy(u['rotation_strategy'] as String);
    }
    if (u.containsKey('rotation_interval_s') &&
        u['rotation_interval_s'] is num) {
      rotationIntervalS = (u['rotation_interval_s'] as num).toInt();
    }
    if (u.containsKey('requests_per_rotation') &&
        u['requests_per_rotation'] is num) {
      requestsPerRotation = (u['requests_per_rotation'] as num).toInt();
    }
    if (u.containsKey('quota_probe_interval_s') &&
        u['quota_probe_interval_s'] is num) {
      quotaProbeIntervalS = (u['quota_probe_interval_s'] as num).toInt();
    }
    if (u.containsKey('server_host') && u['server_host'] is String)
      serverHost = u['server_host'] as String;
    if (u.containsKey('server_port') && u['server_port'] is num)
      serverPort = (u['server_port'] as num).toInt();
    if (u.containsKey('quota_probe_url') && u['quota_probe_url'] is String)
      quotaProbeUrl = u['quota_probe_url'] as String;
    if (u.containsKey('logs_visible') && u['logs_visible'] is bool)
      logsVisible = u['logs_visible'] as bool;
    if (u.containsKey('codebuddy_api_base') &&
        u['codebuddy_api_base'] is String)
      codebuddyApiBase = u['codebuddy_api_base'] as String;
  }

  Map<String, dynamic> snapshot() => toJson();
}
