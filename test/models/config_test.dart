import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import '../../lib/src/models/config.dart';

void main() {
  group('Config defaults', () {
    test('constructor uses default values', () {
      final c = Config();
      expect(c.issuer, 'https://www.codebuddy.ai/auth/realms/copilot');
      expect(c.clientId, 'console');
      expect(c.identityProvider, 'github');
      expect(c.scopes, 'openid profile email offline_access');
      expect(c.bridgeUrl, '');
      expect(c.rotationStrategy, RotationStrategy.exhaustedNext);
      expect(c.rotationIntervalS, 300);
      expect(c.requestsPerRotation, 5);
      expect(c.quotaProbeIntervalS, 0);
      expect(c.serverHost, '127.0.0.1');
      expect(c.serverPort, 20130);
      expect(c.logsVisible, true);
      expect(c.codebuddyApiBase, 'https://www.codebuddy.ai');
    });
  });

  group('Config.toJson / snapshot', () {
    test('toJson contains all expected keys', () {
      final c = Config();
      final json = c.toJson();
      expect(json['issuer'], isA<String>());
      expect(json['client_id'], isA<String>());
      expect(json['rotation_strategy'], isA<String>());
      expect(json['server_port'], isA<int>());
      expect(json['logs_visible'], isA<bool>());
    });

    test('snapshot returns same as toJson', () {
      final c = Config();
      expect(c.snapshot(), c.toJson());
    });

    test('toJson reflects changed values', () {
      final c = Config();
      c.serverPort = 9999;
      c.rotationStrategy = RotationStrategy.requestCountRandom;
      final json = c.toJson();
      expect(json['server_port'], 9999);
      expect(json['rotation_strategy'], 'request-count-random');
    });
  });

  group('Config.apply', () {
    late Config c;

    setUp(() {
      c = Config();
    });

    test('updates individual fields', () {
      c.apply({
        'issuer': 'https://other.example.com',
        'client_id': 'my-client',
        'server_port': 8080,
        'logs_visible': false,
      });
      expect(c.issuer, 'https://other.example.com');
      expect(c.clientId, 'my-client');
      expect(c.serverPort, 8080);
      expect(c.logsVisible, false);
    });

    test('ignores unknown keys', () {
      c.apply({'unknown_key': 'value'});
      expect(c.issuer, 'https://www.codebuddy.ai/auth/realms/copilot');
    });

    test('ignores wrong types', () {
      c.apply({'server_port': 'not-a-number'});
      expect(c.serverPort, 20130);
    });

    test('handles rotation_strategy enum for all strategies', () {
      c.apply({'rotation_strategy': 'exhausted-next'});
      expect(c.rotationStrategy, RotationStrategy.exhaustedNext);

      c.apply({'rotation_strategy': 'exhausted-random'});
      expect(c.rotationStrategy, RotationStrategy.exhaustedRandom);

      c.apply({'rotation_strategy': 'request-count-next'});
      expect(c.rotationStrategy, RotationStrategy.requestCountNext);

      c.apply({'rotation_strategy': 'request-count-random'});
      expect(c.rotationStrategy, RotationStrategy.requestCountRandom);

      c.apply({'rotation_strategy': 'invalid'});
      expect(c.rotationStrategy, RotationStrategy.exhaustedNext);
    });

    test('handles numeric fields from num values', () {
      c.apply({'rotation_interval_s': 600.0, 'server_port': 8080.0});
      expect(c.rotationIntervalS, 600);
      expect(c.serverPort, 8080);
    });

    test('handles codebuddy_api_base update', () {
      c.apply({'codebuddy_api_base': 'https://staging.example.com'});
      expect(c.codebuddyApiBase, 'https://staging.example.com');
    });
  });

  group('Config.load from file', () {
    late Directory tmpDir;
    late String configPath;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('cobuddy_config_test_');
      configPath = '${tmpDir.path}/config.json';
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('Config construction -> toJson -> from file -> equals', () {
      final c = Config();
      c.serverPort = 7777;
      c.rotationStrategy = RotationStrategy.requestCountRandom;
      c.codebuddyApiBase = 'https://custom.example.com';

      File(configPath).writeAsStringSync(jsonEncode(c.toJson()));
      final json = jsonDecode(File(configPath).readAsStringSync()) as Map<String, dynamic>;

      final loaded = Config(
        issuer: (json['issuer'] as String?) ?? 'https://www.codebuddy.ai/auth/realms/copilot',
        clientId: (json['client_id'] as String?) ?? 'console',
        identityProvider: (json['identity_provider'] as String?) ?? 'github',
        scopes: (json['scopes'] as String?) ?? 'openid profile email offline_access',
        bridgeUrl: (json['bridge_url'] as String?) ?? '',
        rotationStrategy: switch (json['rotation_strategy'] as String? ?? '') {
          'exhausted-random' => RotationStrategy.exhaustedRandom,
          'request-count-next' => RotationStrategy.requestCountNext,
          'request-count-random' => RotationStrategy.requestCountRandom,
          _ => RotationStrategy.exhaustedNext,
        },
        rotationIntervalS: (json['rotation_interval_s'] as int?) ?? 300,
        requestsPerRotation: (json['requests_per_rotation'] as int?) ?? 50,
        quotaProbeIntervalS: (json['quota_probe_interval_s'] as int?) ?? 0,
        serverHost: (json['server_host'] as String?) ?? '127.0.0.1',
        serverPort: (json['server_port'] as int?) ?? 20130,
        quotaProbeUrl: (json['quota_probe_url'] as String?) ?? 'https://www.codebuddy.ai/v2/billing/meter/get-dosage-notify',
        logsVisible: (json['logs_visible'] as bool?) ?? true,
        codebuddyApiBase: (json['codebuddy_api_base'] as String?) ?? 'https://www.codebuddy.ai',
      );

      expect(loaded.serverPort, 7777);
      expect(loaded.rotationStrategy, RotationStrategy.requestCountRandom);
      expect(loaded.codebuddyApiBase, 'https://custom.example.com');
    });
  });
}
