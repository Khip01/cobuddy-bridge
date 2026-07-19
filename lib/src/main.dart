import 'package:nocterm/nocterm.dart';
import 'models/config.dart';
import 'models/account.dart';
import 'services/oauth.dart';
import 'services/rotator.dart';
import 'services/log_store.dart';
import 'server/proxy.dart';
import 'tui/app.dart';

Future<void> runCobuddyApp(List<String> args) async {
  LogStore.init();
  final cfg = Config.load();
  final store = Store();
  final auth = OAuthClient(cfg);
  final rotator = Rotator(cfg: cfg, store: store, auth: auth);

  if (args.contains('server')) {
    await _runServer(cfg, store, auth, rotator);
  } else {
    final server = ProxyServer(
      cfg: cfg,
      store: store,
      auth: auth,
      rotator: rotator,
    );
    final serverUrl = await server.run();
    runApp(
      CobuddyApp(
        store: store,
        auth: auth,
        rotator: rotator,
        config: cfg,
        serverUrl: serverUrl,
      ),
    );
  }
}

Future<void> _runServer(
  Config cfg,
  Store store,
  OAuthClient auth,
  Rotator rotator,
) async {
  final server = ProxyServer(
    cfg: cfg,
    store: store,
    auth: auth,
    rotator: rotator,
  );
  await server.run();
}
