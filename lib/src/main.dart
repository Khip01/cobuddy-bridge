import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'models/config.dart';
import 'models/account.dart';
import 'services/oauth.dart';
import 'services/rotator.dart';
import 'server/proxy.dart';
import 'tui/app.dart';

void runCobuddyApp(List<String> args) {
  final cfg = Config.load();
  final store = Store();
  final auth = OAuthClient(cfg);
  final rotator = Rotator(cfg: cfg, store: store, auth: auth);

  if (args.contains('server')) {
    _runServer(cfg, store, auth, rotator);
  } else {
    runApp(CobuddyApp(store: store, auth: auth, rotator: rotator, config: cfg));
  }
}

void _runServer(Config cfg, Store store, OAuthClient auth, Rotator rotator) async {
  final server = ProxyServer(cfg: cfg, store: store, auth: auth, rotator: rotator);
  await server.run();
}