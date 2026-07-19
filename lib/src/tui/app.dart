import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import '../models/account.dart';
import '../models/config.dart';
import '../services/oauth.dart';
import '../services/rotator.dart';

class CobuddyApp extends StatefulComponent {
  final Store store;
  final OAuthClient auth;
  final Rotator rotator;
  final Config config;

  CobuddyApp({
    required this.store,
    required this.auth,
    required this.rotator,
    required this.config,
  });

  @override
  State<CobuddyApp> createState() => AppState();
}

enum _Panel { main, addUrl, import }

class AppState extends State<CobuddyApp> {
  late final _store = component.store;
  late final _auth = component.auth;
  late final _rotator = component.rotator;
  List<Account> _accts = [];
  int _cursor = 0;
  _Panel _panel = _Panel.main;
  String _status = '';
  String _authUrl = '';
  bool _showCopied = false;
  Timer? _copyTimer;
  int _importFocus = 0;
  final _stateCtrl = TextEditingController();
  final _labelCtrl = TextEditingController();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _reload();
    _ticker = Timer.periodic(const Duration(seconds: 10), (_) => _reload());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _stateCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    _accts = _store.loadAll();
    if (mounted) setState(() {});
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (e) {
        // Main panel keys
        if (_panel == _Panel.main) {
          if (e.logicalKey == LogicalKey.arrowDown) {
            if (_cursor < _accts.length - 1) _cursor++;
            setState(() {});
            return true;
          }
          if (e.logicalKey == LogicalKey.arrowUp) {
            if (_cursor > 0) _cursor--;
            setState(() {});
            return true;
          }
          if (e.logicalKey == LogicalKey.keyA) { _startAdd(); return true; }
          if (e.logicalKey == LogicalKey.keyD && _accts.isNotEmpty) { _delete(); return true; }
          if (e.logicalKey == LogicalKey.keyT && _accts.isNotEmpty) { _test(); return true; }
          if (e.logicalKey == LogicalKey.keyR) { _rotate(); return true; }
          if (e.logicalKey == LogicalKey.keyQ) { _ticker?.cancel(); shutdownApp(); return true; }
          return false;
        }

        // Add URL panel keys
        if (_panel == _Panel.addUrl) {
          if (e.logicalKey == LogicalKey.escape) {
            _copyTimer?.cancel();
            _copyTimer = null;
            _showCopied = false;
            _panel = _Panel.main;
            _status = '';
            setState(() {});
            return true;
          }
          if (e.logicalKey == LogicalKey.keyC) {
            _doCopyUrl(_authUrl);
            return true;
          }
          if (e.logicalKey == LogicalKey.enter) {
            _copyTimer?.cancel();
            _copyTimer = null;
            _showCopied = false;
            _panel = _Panel.import;
            _importFocus = 0;
            _labelCtrl.text = '';
            _stateCtrl.text = '';
            _status = 'Enter a label (optional), then paste the session_code from the URL bar and press Enter';
            setState(() {});
            return true;
          }
          return false;
        }

        // Import panel keys
        if (_panel == _Panel.import) {
          if (e.logicalKey == LogicalKey.escape) {
            _panel = _Panel.main;
            setState(() {});
            return true;
          }
          if (e.logicalKey == LogicalKey.tab) {
            _importFocus = (_importFocus + 1) % 2;
            setState(() {});
            return true;
          }
          // TextField consumes Enter, so _doImport is called via onSubmitted.
          // This is a fallback in case Focusable receives Enter before TextField.
          if (e.logicalKey == LogicalKey.enter) {
            _doImport();
            return true;
          }
          return false;
        }

        return false;
      },
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: Column(
          children: [
            _header(),
            Expanded(child: _body()),
            _footer(),
          ],
        ),
      ),
    );
  }

  Component _header() {
    var ok = _accts.where((a) => a.state == AcctState.ok).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Row(
        children: [
          Text('Cobuddy Bridge', style: const TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          Text('$ok/${_accts.length} ok'),
        ],
      ),
    );
  }

  Component _body() {
    switch (_panel) {
      case _Panel.main:
        return _accts.isEmpty ? _emptyView() : _list();
      case _Panel.addUrl:
        return _addUrlPanel();
      case _Panel.import:
        return _importPanel();
    }
  }

  Component _emptyView() => const Center(child: Text('No accounts. Press [a] to add one.'));

  Component _list() {
    return ListView(children: [
      for (var i = 0; i < _accts.length; i++) _row(i),
    ]);
  }

  Component _row(int i) {
    final a = _accts[i];
    final sel = i == _cursor;
    final badge = switch (a.state) {
      AcctState.ok => '✓',
      AcctState.expired => '✗',
      AcctState.exhausted => '!',
      AcctState.error => '⚠',
      _ => '?',
    };
    final color = switch (a.state) {
      AcctState.ok => Colors.green,
      AcctState.expired => Colors.red,
      AcctState.exhausted => Colors.yellow,
      _ => Colors.white,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0),
      child: Row(
        children: [
          if (sel) Text('> ', style: const TextStyle(color: Colors.cyan)) else const Text('  '),
          Text('$badge ', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          Expanded(child: Text(a.label, style: const TextStyle(fontWeight: FontWeight.bold))),
          Text(_expStr(a.expiresAt)),
        ],
      ),
    );
  }

  String _expStr(DateTime t) {
    final d = t.difference(DateTime.now());
    if (d.isNegative) return 'expired';
    return '${d.inHours}h${d.inMinutes.remainder(60)}m';
  }

  Component _addUrlPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Add Account', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 1),
        const Text('1. Press [c] to copy the URL below',
            style: TextStyle(color: Colors.cyan)),
        const SizedBox(height: 1),
        Text(
          _showCopied ? '✓ Copied to clipboard!' : _authUrl,
          style: TextStyle(
            color: _showCopied ? Colors.green : Colors.white,
          ),
        ),
        const SizedBox(height: 1),
        const Text('2. Open it in a browser where you are logged into CodeBuddy'),
        const Text('3. After login via GitHub, the URL changes to one with ?state=...'),
        const Text('4. Copy the state parameter value from the URL bar'),
        const SizedBox(height: 1),
        const Text('[c] copy URL  [Enter] next  [Esc] cancel'),
      ],
    );
  }

  void _doCopyUrl(String url) {
    // Try OSC 52 (nocterm clipboard)
    final oscOk = Clipboard.copy(url);

    // Fallback: try xclip, then wl-copy
    if (!oscOk) {
      try {
        File('/tmp/cb_url.txt').writeAsStringSync(url);
        var p = Process.runSync(
          'xclip', ['-selection', 'clipboard', '/tmp/cb_url.txt'],
          runInShell: true,
        );
        if (p.exitCode != 0) {
          p = Process.runSync(
            'wl-copy', ['<', '/tmp/cb_url.txt'],
            runInShell: true,
          );
        }
      } catch (_) {}
    }

    _copyTimer?.cancel();
    _showCopied = true;
    _status = 'URL copied to clipboard!';
    setState(() {});

    _copyTimer = Timer(const Duration(seconds: 2), () {
      _showCopied = false;
      _status = 'Press [c] to copy URL, then open in browser';
      if (mounted) setState(() {});
    });
  }

  Component _importPanel() {
    final focusLabel = _importFocus == 0;
    final focusState = _importFocus == 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Import Account', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 1),
        Row(
          children: [
            Text('Label:', style: TextStyle(fontWeight: FontWeight.bold, color: focusLabel ? Colors.cyan : Colors.white)),
            const SizedBox(width: 1),
            Expanded(
              child: TextField(
                controller: _labelCtrl,
                focused: focusLabel,
                placeholder: 'my-session (optional)',
                onSubmitted: (_) => _doImport(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 1),
        Row(
          children: [
            Text('State:', style: TextStyle(fontWeight: FontWeight.bold, color: focusState ? Colors.cyan : Colors.white)),
            const SizedBox(width: 1),
            Expanded(
              child: TextField(
                controller: _stateCtrl,
                focused: focusState,
                placeholder: 'paste session_code here',
                onSubmitted: (_) => _doImport(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 1),
        const Text('[Tab] switch field  [Enter] import  [Esc] cancel'),
      ],
    );
  }

  Component _footer() {
    var keys = <String>[];
    if (_panel == _Panel.main) {
      keys = ['[a]dd', '[d]el', '[t]est', '[r]otate', '[q]uit'];
    } else if (_panel == _Panel.addUrl) {
      keys = ['[c]opy', '[Enter]', '[Esc]'];
    } else if (_panel == _Panel.import) {
      keys = ['[Tab]', '[Enter]', '[Esc]'];
    }
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        children: [
          Expanded(child: Text(_status.isEmpty ? 'Ready' : _status)),
          Text(keys.join('  ')),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  void _startAdd() async {
    _status = 'Getting login URL...';
    _copyTimer?.cancel();
    _copyTimer = null;
    _showCopied = false;
    setState(() {});
    try {
      final result = await _auth.startLoginOfficial();
      _authUrl = result.authUrl;
      _panel = _Panel.addUrl;
      _status = 'Press [c] to copy URL, then open in browser';
    } catch (e) {
      _status = 'Failed: $e';
      _panel = _Panel.main;
    }
    setState(() {});
  }

  void _doImport() async {
    final state = _stateCtrl.text.trim();
    final label = _labelCtrl.text.trim().isEmpty ? 'imported' : _labelCtrl.text.trim();
    if (state.isEmpty) {
      _status = 'State/session_code is required';
      setState(() {});
      return;
    }
    _status = 'Exchanging state for token...';
    setState(() {});
    try {
      final token = await _auth.fetchTokenByState(state);
      final a = Account(
        id: accountIdFromToken(token.accessToken),
        label: label,
        userId: token.userId,
        accessToken: token.accessToken,
        refreshToken: token.refreshToken,
        expiresAt: DateTime.now().add(Duration(seconds: token.expiresIn)),
        state: AcctState.ok,
        priority: _nextPri(),
      );
      _store.save(a);
      _panel = _Panel.main;
      _status = 'Imported: $label';
      _reload();
    } catch (e) {
      _status = 'Import failed: $e';
    }
    setState(() {});
  }

  void _delete() {
    final a = _accts[_cursor];
    _store.delete(a.id);
    _status = 'Deleted: ${a.label}';
    _reload();
  }

  void _test() async {
    final a = _accts[_cursor];
    _status = 'Testing ${a.label}...';
    setState(() {});
    final fresh = await _rotator.probeAccount(a.id);
    if (fresh != null) {
      _status = '${a.label}: ${fresh.state.name} (${fresh.stateMsg})';
    } else {
      _status = '${a.label}: not found';
    }
    _reload();
  }

  void _rotate() {
    final acc = _rotator.forceRotate();
    if (acc != null) {
      _status = 'Rotated to ${acc.label}';
      _reload();
    } else {
      _status = 'No accounts to rotate';
      setState(() {});
    }
  }

  int _nextPri() {
    var max = 0;
    for (final a in _store.loadAll()) { if (a.priority > max) max = a.priority; }
    return max + 1;
  }
}