import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart' hide LogEntry;
import '../models/account.dart';
import '../models/config.dart';
import '../services/oauth.dart';
import '../services/rotator.dart';
import '../services/log_store.dart';

class CobuddyApp extends StatefulComponent {
  final Store store;
  final OAuthClient auth;
  final Rotator rotator;
  final Config config;
  final String serverUrl;

  CobuddyApp({
    required this.store,
    required this.auth,
    required this.rotator,
    required this.config,
    required this.serverUrl,
  });

  @override
  State<CobuddyApp> createState() => AppState();
}

enum _Panel { main, addUrl, import, delete, strategy, requestCount, portConfig, quit, help }

enum _ConfirmAction { none, clearAll, clearOld }

enum _StatusLevel { ready, info, success, error, warning }

class AppState extends State<CobuddyApp> {
  late final _store = component.store;
  late final _auth = component.auth;
  late final _rotator = component.rotator;
  late final _config = component.config;
  late final String _serverUrl = component.serverUrl;
  List<Account> _accts = [];
  int _cursor = 0;
  _Panel _panel = _Panel.main;
  bool _showLog = false;
  bool _logFullscreen = false;
  String _status = '';
  _StatusLevel _statusLevel = _StatusLevel.ready;
  Timer? _statusTimer;
  String _authUrl = '';
  int _importFocus = 0;
  int _strategyCursor = 0;
  _ConfirmAction _confirmAction = _ConfirmAction.none;
  final _urlCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _labelCtrl = TextEditingController();
  final _reqCountCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  final Map<int, bool> _portStatus = {};
  bool _portScanDone = false;
  final _helpScrollCtrl = ScrollController();
  final _logScrollCtrl = ScrollController();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _reload();
    _ticker = Timer.periodic(const Duration(seconds: 2), (_) => _reload());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _statusTimer?.cancel();
    _urlCtrl.dispose();
    _stateCtrl.dispose();
    _labelCtrl.dispose();
    _reqCountCtrl.dispose();
    _portCtrl.dispose();
    _helpScrollCtrl.dispose();
    _logScrollCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    _accts = _store.loadAll();
    _accts.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (_cursor >= _accts.length)
      _cursor = (_accts.length - 1).clamp(0, _accts.length - 1);
    if (_cursor < 0) _cursor = 0;
    if (mounted) setState(() {});
  }

  void _backToMain() {
    _panel = _Panel.main;
    _statusTimer?.cancel();
    _status = '';
    _statusLevel = _StatusLevel.ready;
    setState(() {});
  }

  void _setStatus(String msg, _StatusLevel level, {int? duration}) {
    _statusTimer?.cancel();
    _statusTimer = null;
    _status = msg;
    _statusLevel = level;
    setState(() {});

    if (_panel == _Panel.main && duration != null && duration > 0) {
      _statusTimer = Timer(Duration(seconds: duration), () {
        _status = 'Ready';
        _statusLevel = _StatusLevel.ready;
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (e) {
        // Global: toggle log sidebar from anywhere
        if (e.logicalKey == LogicalKey.keyL && e.isControlPressed) {
          if (_panel == _Panel.strategy ||
              _panel == _Panel.delete ||
              _panel == _Panel.addUrl ||
              _panel == _Panel.import ||
              _panel == _Panel.requestCount ||
              _panel == _Panel.quit ||
              _panel == _Panel.help) {
            return false;
          }
          _showLog = !_showLog;
          setState(() {});
          return true;
        }

        // When log is visible: fullscreen toggle + clear keys
        if (_showLog && _panel == _Panel.main) {
          if (e.logicalKey == LogicalKey.keyF) {
            _logFullscreen = !_logFullscreen;
            setState(() {});
            return true;
          }
          if (e.logicalKey == LogicalKey.keyC && !e.isControlPressed) {
            if (LogStore.totalCount == 0) return false;
            _confirmAction = _ConfirmAction.clearAll;
            _setStatus('Clear all logs? [Y]es [N]o', _StatusLevel.warning);
            setState(() {});
            return true;
          }
          if (e.logicalKey == LogicalKey.keyO) {
            final n = LogStore.countBeforeToday();
            if (n == 0) {
              _setStatus(
                'No entries before today',
                _StatusLevel.info,
                duration: 2,
              );
              return true;
            }
            _confirmAction = _ConfirmAction.clearOld;
            _setStatus(
              'Clear $n entries before today? [Y]es [N]o',
              _StatusLevel.warning,
            );
            setState(() {});
            return true;
          }
          if (_confirmAction != _ConfirmAction.none) {
            if (e.logicalKey == LogicalKey.keyY ||
                e.logicalKey == LogicalKey.enter) {
              _doConfirmClear();
              return true;
            }
            if (e.logicalKey == LogicalKey.keyN ||
                e.logicalKey == LogicalKey.escape) {
              _cancelConfirmClear();
              return true;
            }
            return false;
          }
        }

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
          if (e.logicalKey == LogicalKey.keyA) {
            _startAdd();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyD && _accts.isNotEmpty) {
            _confirmDelete();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyT && _accts.isNotEmpty) {
            _test();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyR && !e.isShiftPressed) {
            _showStrategy();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyR && e.isShiftPressed) {
            _rotate();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyE && _accts.isNotEmpty) {
            _toggleEnabled();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyS && _accts.isNotEmpty) {
            _setCurrent();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyC) {
            _doCopyPath();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyQ) {
            _confirmQuit();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyH) {
            _showHelp();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyP) {
            _showPortConfig();
            return true;
          }
          return false;
        }

        if (_panel == _Panel.addUrl) {
          if (e.logicalKey == LogicalKey.escape) {
            _backToMain();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyC) {
            _doCopyUrl(_authUrl);
            return true;
          }
          if (e.logicalKey == LogicalKey.enter) {
            _advanceToImport();
            return true;
          }
          return false;
        }

        if (_panel == _Panel.import) {
          if (e.logicalKey == LogicalKey.escape) {
            _backToMain();
            return true;
          }
          if (e.logicalKey == LogicalKey.tab) {
            _importFocus = (_importFocus + 1) % 2;
            setState(() {});
            return true;
          }
          if (e.logicalKey == LogicalKey.enter) {
            _doImport();
            return true;
          }
          return false;
        }

        if (_panel == _Panel.delete) {
          if (e.logicalKey == LogicalKey.keyY ||
              e.logicalKey == LogicalKey.enter) {
            _doDelete();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyN ||
              e.logicalKey == LogicalKey.escape) {
            _cancelDelete();
            return true;
          }
          return false;
        }

        if (_panel == _Panel.strategy) {
          if (e.logicalKey == LogicalKey.escape) {
            _backToMain();
            return true;
          }
          if (e.logicalKey == LogicalKey.arrowDown) {
            if (_strategyCursor < 3) _strategyCursor++;
            setState(() {});
            return true;
          }
          if (e.logicalKey == LogicalKey.arrowUp) {
            if (_strategyCursor > 0) _strategyCursor--;
            setState(() {});
            return true;
          }
          if (e.logicalKey == LogicalKey.enter) {
            _selectStrategy();
            return true;
          }
          return false;
        }

        if (_panel == _Panel.requestCount) {
          if (e.logicalKey == LogicalKey.escape) {
            _panel = _Panel.strategy;
            _setStatus(
              'Select rotation strategy and press Enter',
              _StatusLevel.info,
            );
            setState(() {});
            return true;
          }
          if (e.logicalKey == LogicalKey.enter) {
            _doSetRequestCount();
            return true;
          }
          return false;
        }

        if (_panel == _Panel.help) {
          if (e.logicalKey == LogicalKey.escape ||
              e.logicalKey == LogicalKey.keyH) {
            _backToMain();
            return true;
          }
          return false;
        }

        if (_panel == _Panel.portConfig) {
          if (e.logicalKey == LogicalKey.escape) {
            _backToMain();
            return true;
          }
          if (e.logicalKey == LogicalKey.enter) {
            _doSetPort();
            return true;
          }
          return false;
        }

        if (_panel == _Panel.quit) {
          if (e.logicalKey == LogicalKey.keyY ||
              e.logicalKey == LogicalKey.enter) {
            _ticker?.cancel();
            _statusTimer?.cancel();
            shutdownApp();
            return true;
          }
          if (e.logicalKey == LogicalKey.keyN ||
              e.logicalKey == LogicalKey.escape) {
            _cancelQuit();
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
    final state = _store.loadState();
    final currentName = state.currentId.isNotEmpty
        ? _accts.where((a) => a.id == state.currentId).firstOrNull?.label ?? ''
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Cobuddy Bridge',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              if (currentName.isNotEmpty) ...[
                const SizedBox(width: 1),
                Text('|', style: TextStyle(color: Colors.grey)),
                const SizedBox(width: 1),
                Text(
                  currentName,
                  style: TextStyle(
                    color: Colors.cyan,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
              const Spacer(),
              Text(
                '$ok/${_accts.length} ok',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
          Row(
            children: [
              Text('\u25b8 ', style: TextStyle(color: Colors.green)),
              Text(_serverUrl, style: TextStyle(color: Colors.green)),
            ],
          ),
        ],
      ),
    );
  }

  Component _body() {
    final content = switch (_panel) {
      _Panel.main => _accts.isEmpty ? _emptyView() : _list(),
      _Panel.addUrl => _addUrlPanel(),
      _Panel.import => _importPanel(),
      _Panel.delete => _deletePanel(),
      _Panel.strategy => _strategyPanel(),
      _Panel.requestCount => _requestCountPanel(),
      _Panel.portConfig => _portConfigPanel(),
      _Panel.quit => _quitPanel(),
      _Panel.help => _helpPanel(),
    };
    if (_logFullscreen && _showLog) return _logPanel(fullscreen: true);
    if (!_showLog) return content;
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.only(right: 1),
            child: content,
          ),
        ),
        const SizedBox(width: 1),
        Expanded(
          flex: 2,
          child: Container(
            padding: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              border: BoxBorder.all(color: Colors.grey),
            ),
            child: _logPanel(fullscreen: false),
          ),
        ),
      ],
    );
  }

  Component _emptyView() =>
      const Center(child: Text('No accounts. Press [a] to add one.'));

  Component _list() {
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 1),
          child: GestureDetector(
            onTap: () => _doCopyPath(),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Text('Accounts: ', style: TextStyle(color: Colors.grey)),
                Expanded(
                  child: Text(
                    Store.defaultAcctsDir,
                    style: TextStyle(color: Colors.cyan),
                  ),
                ),
                Text(' [c] copy', style: TextStyle(color: Colors.grey)),
              ],
            ),
          ),
        ),
        Container(height: 1, color: Colors.grey),
        const SizedBox(height: 1),
        for (var i = 0; i < _accts.length; i++) _row(i),
      ],
    );
  }

  Component _row(int i) {
    final a = _accts[i];
    final sel = i == _cursor;
    final state = _store.loadState();
    final isCurrent = a.id == state.currentId;

    final (badge, color) = switch (a.state) {
      AcctState.ok => ('\u2713', Colors.green),
      AcctState.expired => ('\u2717', Colors.red),
      AcctState.exhausted => ('!', Colors.yellow),
      AcctState.error => ('\u26a0', Colors.red),
      _ => ('?', Colors.white),
    };

    final stateLabel = switch (a.state) {
      AcctState.ok => 'OK',
      AcctState.expired => 'EXPIRED',
      AcctState.exhausted => 'EXHAUSTED',
      AcctState.error => 'ERROR',
      _ => 'UNKNOWN',
    };

    final disabledTag = !a.enabled ? ' DISABLED' : '';
    final currentTag = isCurrent ? ' \u25b6 CURRENT' : '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (sel)
                Text('> ', style: const TextStyle(color: Colors.cyan))
              else
                const Text('  '),
              Text(
                '$badge ',
                style: TextStyle(color: color, fontWeight: FontWeight.bold),
              ),
              Text(
                a.label,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (isCurrent)
                Text(
                  currentTag,
                  style: TextStyle(
                    color: Colors.cyan,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              if (!a.enabled)
                Text(
                  disabledTag,
                  style: TextStyle(
                    color: Colors.grey,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
          Text('    $stateLabel  \u00b7  ${_fmtDate(a.createdAt)}'),
          Text(
            '    ${a.id}${a.stateMsg.isNotEmpty ? '  \u00b7  ${a.stateMsg}' : ''}',
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime t) {
    return '${t.year}-${_pad(t.month)}-${_pad(t.day)} ${_pad(t.hour)}:${_pad(t.minute)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  Component _addUrlPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Add Account',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 1),
        const Text(
          '1. Click box to copy URL, or press [c] to copy',
          style: TextStyle(color: Colors.cyan),
        ),
        const SizedBox(height: 1),
        GestureDetector(
          onTap: () => _doCopyUrl(_authUrl),
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              border: BoxBorder.all(color: Colors.cyan),
            ),
            child: TextField(
              controller: _urlCtrl,
              focused: true,
              width: _urlCtrl.text.length + 2,
              onKeyEvent: (e) {
                if (e.logicalKey == LogicalKey.keyC && !e.isControlPressed) {
                  _doCopyUrl(_authUrl);
                  return true;
                }
                return false;
              },
              onSubmitted: (_) => _advanceToImport(),
            ),
          ),
        ),
        const SizedBox(height: 1),
        const Text(
          '2. Open it in a browser where you are logged into CodeBuddy',
        ),
        const Text(
          '3. After login via GitHub, the URL changes to one with ?state=...',
        ),
        const Text('4. Copy the state parameter value from the URL bar'),
        const SizedBox(height: 1),
        const Text('[c] copy URL  [Enter] next  [Esc] cancel'),
      ],
    );
  }

  void _doCopyUrl(String url) async {
    _statusTimer?.cancel();
    _setStatus('Copying URL to clipboard...', _StatusLevel.info);
    final ok = await _copyNative(url);
    if (ok) {
      _setStatus('URL copied to clipboard!', _StatusLevel.success, duration: 2);
    } else {
      _setStatus(
        'Copy failed, select URL manually',
        _StatusLevel.warning,
        duration: 4,
      );
    }
  }

  Future<bool> _copyNative(String text) async {
    try {
      final p = await _spawnAndPipe('wl-copy', [], text);
      if (p) return true;
    } catch (_) {}
    try {
      final p = await _spawnAndPipe('xclip', ['-selection', 'clipboard'], text);
      if (p) return true;
    } catch (_) {}
    return ClipboardManager.copy(text);
  }

  Future<bool> _spawnAndPipe(
    String cmd,
    List<String> args,
    String input,
  ) async {
    try {
      final proc = await Process.start(cmd, args);
      proc.stdin.write(input);
      await proc.stdin.flush();
      await proc.stdin.close();
      final code = await proc.exitCode;
      return code == 0;
    } catch (_) {
      return false;
    }
  }

  Component _importPanel() {
    final focusLabel = _importFocus == 0;
    final focusState = _importFocus == 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Import Account',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 1),
        Row(
          children: [
            Text(
              'Label:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: focusLabel ? Colors.cyan : Colors.white,
              ),
            ),
            const SizedBox(width: 1),
            Expanded(
              child: TextField(
                controller: _labelCtrl,
                focused: focusLabel,
                placeholder: 'my-session (auto-increment)',
                onSubmitted: (_) => _doImport(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 1),
        Row(
          children: [
            Text(
              'State:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: focusState ? Colors.cyan : Colors.white,
              ),
            ),
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

  // ---------------------------------------------------------------------------
  // Strategy selector
  // ---------------------------------------------------------------------------

  static const _strategies = [
    RotationStrategy.exhaustedNext,
    RotationStrategy.exhaustedRandom,
    RotationStrategy.requestCountNext,
    RotationStrategy.requestCountRandom,
  ];

  static const _strategyLabels = {
    RotationStrategy.exhaustedNext:
        'exhausted-next  (advance when exhausted, next in order)',
    RotationStrategy.exhaustedRandom:
        'exhausted-random  (advance when exhausted, random pick)',
    RotationStrategy.requestCountNext:
        'request-count-next  (advance every N requests, next in order)',
    RotationStrategy.requestCountRandom:
        'request-count-random  (advance every N requests, random pick)',
  };

  Component _strategyPanel() {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Rotation Strategy',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.cyan),
            ),
            const SizedBox(height: 1),
            for (var i = 0; i < _strategies.length; i++) ...[
              if (i > 0) const SizedBox(height: 1),
              _strategyRow(i),
            ],
            const SizedBox(height: 1),
            Text(
              'Current: ${_strategyLabel(_config.rotationStrategy)}',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 1),
            const Text('[Enter] select  [Esc] cancel'),
          ],
        ),
      ),
    );
  }

  Component _strategyRow(int i) {
    final s = _strategies[i];
    final sel = i == _strategyCursor;
    final active = s == _config.rotationStrategy;
    return Row(
      children: [
        if (sel)
          Text('> ', style: TextStyle(color: Colors.cyan))
        else
          const Text('  '),
        Text(
          active ? '\u25c9' : '\u25cb',
          style: TextStyle(color: active ? Colors.cyan : Colors.grey),
        ),
        const SizedBox(width: 1),
        Text(
          _strategyLabels[s]!,
          style: TextStyle(
            color: sel ? Colors.cyan : Colors.white,
            fontWeight: sel ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  String _strategyLabel(RotationStrategy s) => _strategyLabels[s] ?? s.name;

  void _showStrategy() {
    _strategyCursor = _strategies
        .indexOf(_config.rotationStrategy)
        .clamp(0, _strategies.length - 1);
    _panel = _Panel.strategy;
    _setStatus('Select rotation strategy and press Enter', _StatusLevel.info);
  }

  void _selectStrategy() {
    final s = _strategies[_strategyCursor];
    if (s == RotationStrategy.requestCountNext ||
        s == RotationStrategy.requestCountRandom) {
      _reqCountCtrl.text = '${_config.requestsPerRotation}';
      _panel = _Panel.requestCount;
      _setStatus(
        'Enter request count (1-999999) and press Enter',
        _StatusLevel.info,
      );
    } else {
      _applyStrategy(s);
    }
  }

  void _applyStrategy(RotationStrategy s) {
    _config.rotationStrategy = s;
    _config.save();
    _panel = _Panel.main;
    LogStore.info('tui', 'Strategy: ${_strategyLabel(s)}');
    _setStatus(
      'Strategy: ${_strategyLabel(s)}',
      _StatusLevel.success,
      duration: 3,
    );
  }

  Component _requestCountPanel() {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Request Count',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.cyan,
                  ),
                ),
                const SizedBox(width: 1),
                Text(
                  '(${_strategyLabel(_strategies[_strategyCursor])})',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 1),
            const Text(
              'Rotate after how many API requests?',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 1),
            Row(
              children: [
                Text('N:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 1),
                SizedBox(
                  width: 10,
                  child: TextField(
                    controller: _reqCountCtrl,
                    focused: true,
                    placeholder: '5',
                    onSubmitted: (_) => _doSetRequestCount(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 1),
            const Text('[Enter] confirm  [Esc] back to strategy'),
          ],
        ),
      ),
    );
  }

  void _doSetRequestCount() {
    final raw = _reqCountCtrl.text.trim();
    final n = int.tryParse(raw);
    if (n == null || n < 1 || n > 999999) {
      _setStatus(
        'Enter a number between 1 and 999999',
        _StatusLevel.error,
        duration: 3,
      );
      return;
    }
    _config.requestsPerRotation = n;
    _applyStrategy(_strategies[_strategyCursor]);
  }

  // ---------------------------------------------------------------------------
  // Port configuration
  // ---------------------------------------------------------------------------

  static const _recommendedPorts = [
    20130, 3010, 4001, 9090, 3001, 5001, 20131, 10000, 18080, 65432,
  ];

  Component _portConfigPanel() {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Server Port',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.cyan),
            ),
            const SizedBox(height: 1),
            const Text(
              'Port for the OpenAI-compatible proxy endpoint.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 1),
            Row(
              children: [
                Text('Port:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 1),
                SizedBox(
                  width: 7,
                  child: TextField(
                    controller: _portCtrl,
                    focused: true,
                    placeholder: '20130',
                    onSubmitted: (_) => _doSetPort(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 1),
            Text(
              'Available ports (scanned):',
              style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
            ),
            Text(
              _portScanDone
                  ? _portStatus.entries
                      .where((e) => e.value)
                      .map((e) => '${e.key}')
                      .take(5)
                      .join(', ')
                  : 'scanning...',
              style: TextStyle(color: Colors.green),
            ),
            const SizedBox(height: 1),
            if (!_portScanDone)
              const Text(
                'Scanning ports...',
                style: TextStyle(color: Colors.yellow),
              ),
            if (_portScanDone && _portStatus.values.where((v) => v).isEmpty)
              const Text(
                'No recommended ports available',
                style: TextStyle(color: Colors.red),
              ),
            const SizedBox(height: 1),
            const Text(
              'Restart required for port change to take effect.',
              style: TextStyle(color: Colors.yellow),
            ),
            const SizedBox(height: 1),
            const Text('[Enter] confirm  [Esc] cancel'),
          ],
        ),
      ),
    );
  }

  Future<void> _scanPorts() async {
    _portScanDone = false;
    _portStatus.clear();
    for (final port in _recommendedPorts) {
      if (port == _config.serverPort) {
        _portStatus[port] = true;
        continue;
      }
      try {
        final s = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
          shared: true,
        );
        await s.close();
        _portStatus[port] = true;
      } catch (_) {
        _portStatus[port] = false;
      }
    }
    _portScanDone = true;
    if (mounted) setState(() {});
  }

  void _showPortConfig() {
    _portCtrl.text = '${_config.serverPort}';
    _portScanDone = false;
    _panel = _Panel.portConfig;
    _scanPorts();
    _setStatus('Enter new port and press Enter', _StatusLevel.info);
  }

  void _doSetPort() {
    final raw = _portCtrl.text.trim();
    final n = int.tryParse(raw);
    if (n == null || n < 1024 || n > 65535) {
      _setStatus(
        'Enter a port between 1024 and 65535',
        _StatusLevel.error,
        duration: 3,
      );
      return;
    }
    _config.serverPort = n;
    _config.save();
    _panel = _Panel.main;
    LogStore.info('tui', 'Port set to $n (restart required)');
    _setStatus(
      'Port set to $n. Restart to apply changes.',
      _StatusLevel.success,
      duration: 5,
    );
  }

  // ---------------------------------------------------------------------------
  // Quit confirmation
  // ---------------------------------------------------------------------------

  Component _quitPanel() {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(border: BoxBorder.all(color: Colors.red)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('\u26a0 ', style: TextStyle(color: Colors.yellow)),
                Text(
                  'Quit',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 1),
            const Text('Are you sure you want to quit?'),
            Text(
              'Proxy at $_serverUrl will be terminated.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 1),
            const Text('[Y]es  [N]o  [Esc]'),
          ],
        ),
      ),
    );
  }

  void _confirmQuit() {
    _panel = _Panel.quit;
    _setStatus('Press Y to quit, N or Esc to cancel', _StatusLevel.warning);
  }

  void _cancelQuit() {
    _panel = _Panel.main;
    _setStatus('', _StatusLevel.ready);
  }

  // ---------------------------------------------------------------------------
  // Delete confirmation
  // ---------------------------------------------------------------------------

  Component _deletePanel() {
    final a = _accts[_cursor];
    return Center(
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(border: BoxBorder.all(color: Colors.red)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Delete Account',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
            ),
            const SizedBox(height: 1),
            const Text('Are you sure you want to delete this account?'),
            const SizedBox(height: 1),
            Text(
              a.label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.yellow,
              ),
            ),
            Text('(${a.id})', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 1),
            const Text(
              'This action cannot be undone.',
              style: TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 1),
            const Text('[Y]es  [N]o  [Esc]'),
          ],
        ),
      ),
    );
  }

  Component _footer() {
    final widgets = <Component>[];
    void addKey(String label, Color color) {
      if (widgets.isNotEmpty) widgets.add(const Text('  '));
      widgets.add(
        Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.bold),
        ),
      );
    }

    if (_panel == _Panel.main) {
      final showLogKeys = _showLog && _logFullscreen;
      if (!showLogKeys) {
        addKey('[a]dd', Colors.white);
        addKey('[d]el', Colors.white);
        addKey('[e]nable', Colors.white);
        addKey('[s]et', Colors.white);
        addKey('[t]est', Colors.white);
        addKey('[r]strat', Colors.white);
        addKey('[R]otate', Colors.white);
        addKey('[p]ort', Colors.white);
      }
      if (_showLog) {
        addKey('[C]lear', Colors.yellow);
        addKey('[O]ld-clr', Colors.yellow);
        addKey(_logFullscreen ? '[f]side' : '[f]ull', Colors.yellow);
        addKey('[Ctrl+L] close', Colors.yellow);
      } else {
        addKey('[Ctrl+L] log', Colors.yellow);
      }
      addKey('[h]elp', Colors.magenta);
      addKey('[q]uit', Colors.red);
    } else if (_panel == _Panel.addUrl) {
      addKey('[c]opy', Colors.white);
      addKey('[Enter]', Colors.white);
      addKey('[Esc]', Colors.white);
    } else if (_panel == _Panel.import) {
      addKey('[Tab]', Colors.white);
      addKey('[Enter]', Colors.white);
      addKey('[Esc]', Colors.white);
    } else if (_panel == _Panel.delete) {
      addKey('[Y]es', Colors.white);
      addKey('[N]o', Colors.white);
      addKey('[Esc]', Colors.white);
    } else if (_panel == _Panel.strategy) {
      addKey('[Enter]', Colors.white);
      addKey('[Esc]', Colors.white);
    } else if (_panel == _Panel.requestCount) {
      addKey('[Enter]', Colors.cyan);
      addKey('[Esc]', Colors.white);
    } else if (_panel == _Panel.help) {
      addKey('[h] close', Colors.white);
      addKey('[Esc]', Colors.white);
    } else if (_panel == _Panel.portConfig) {
      addKey('[Enter]', Colors.cyan);
      addKey('[Esc]', Colors.white);
    } else if (_panel == _Panel.quit) {
      addKey('[Y]es', Colors.red);
      addKey('[N]o', Colors.white);
      addKey('[Esc]', Colors.white);
    }
    final fg = switch (_statusLevel) {
      _StatusLevel.ready => Colors.white,
      _StatusLevel.info => Colors.cyan,
      _StatusLevel.success => Colors.green,
      _StatusLevel.error => Colors.red,
      _StatusLevel.warning => Colors.yellow,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _status.isEmpty ? 'Ready' : _status,
              style: TextStyle(color: fg, fontWeight: FontWeight.bold),
            ),
          ),
          ...widgets,
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Log panel
  // ---------------------------------------------------------------------------

  Component _logPanel({required bool fullscreen}) {
    final entries = LogStore.latestFirst;
    final listChildren = <Component>[];
    for (var i = 0; i < entries.length; i++) {
      if (i == 0 || !_isSameDay(entries[i].time, entries[i - 1].time)) {
        listChildren.add(_logDateSep(entries[i].time));
      }
      listChildren.add(_logRow(entries[i]));
    }

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
            if (fullscreen) ...[
              const SizedBox(width: 1),
              Text('(fullscreen)', style: TextStyle(color: Colors.grey)),
            ],
            const Spacer(),
            Text('${entries.length}', style: TextStyle(color: Colors.grey)),
          ],
        ),
        Container(height: 1, color: Colors.grey),
        Expanded(
          child: Scrollbar(
            controller: _logScrollCtrl,
            thumbVisibility: true,
            thickness: 1,
            thumbColor: Colors.grey,
            child: ListView(controller: _logScrollCtrl, children: listChildren),
          ),
        ),
      ],
    );

    if (fullscreen) return body;
    return body;
  }

  Component _logRow(LogEntry e) {
    final ts =
        '${_pad(e.time.hour)}:${_pad(e.time.minute)}:${_pad(e.time.second)}';
    final (clr, lvl) = _logStyle(e.level);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('[$ts]', style: TextStyle(color: Colors.grey)),
          Text(
            '[$lvl]',
            style: TextStyle(color: clr, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 1),
          Expanded(
            child: Text(e.message, style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Component _logDateSep(DateTime d) {
    final months = [
      '',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final days = [
      'Sunday',
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ];
    final label =
        '${days[d.weekday % 7]}, ${d.day} ${months[d.month]} ${d.year}';
    final line = '\u2500' * (50 - label.length - 2);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Text(line, style: TextStyle(color: Colors.grey)),
          const SizedBox(width: 1),
          Text(
            label,
            style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 1),
          Text(line, style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  (Color, String) _logStyle(LogLevel l) => switch (l) {
    LogLevel.error => (Colors.red, 'ERR'),
    LogLevel.warning => (Colors.yellow, 'WRN'),
    LogLevel.success => (Colors.green, 'OK'),
    LogLevel.info => (Colors.cyan, 'INF'),
    LogLevel.debug => (Colors.grey, 'DBG'),
  };

  // ---------------------------------------------------------------------------
  // Copy path
  // ---------------------------------------------------------------------------

  void _doCopyPath() async {
    LogStore.info('tui', 'Copy storage path to clipboard');
    final path = Store.defaultAcctsDir;
    final ok = await _copyNative(path);
    if (ok) {
      _setStatus('Path copied: $path', _StatusLevel.success, duration: 2);
    } else {
      _setStatus('Copy failed', _StatusLevel.warning, duration: 4);
    }
  }

  // ---------------------------------------------------------------------------
  // Clear log confirmation
  // ---------------------------------------------------------------------------

  void _doConfirmClear() {
    switch (_confirmAction) {
      case _ConfirmAction.clearAll:
        LogStore.clear();
        LogStore.info('tui', 'Log cleared');
        _setStatus('Log cleared', _StatusLevel.info, duration: 2);
      case _ConfirmAction.clearOld:
        final n = LogStore.countBeforeToday();
        LogStore.clearBeforeToday();
        LogStore.info('tui', 'Cleared $n old entries');
        _setStatus(
          'Cleared $n entries before today',
          _StatusLevel.info,
          duration: 2,
        );
      case _ConfirmAction.none:
        break;
    }
    _confirmAction = _ConfirmAction.none;
  }

  void _cancelConfirmClear() {
    _confirmAction = _ConfirmAction.none;
    _setStatus('Canceled', _StatusLevel.ready);
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  void _startAdd() async {
    _statusTimer?.cancel();
    _setStatus('Getting login URL...', _StatusLevel.info);
    try {
      final result = await _auth.startLoginOfficial();
      _authUrl = result.authUrl;
      _urlCtrl.text = result.authUrl;
      _panel = _Panel.addUrl;
      LogStore.info('tui', 'Auth URL obtained');
      _setStatus(
        'Press [c] to copy URL, then open in browser',
        _StatusLevel.info,
      );
    } catch (e) {
      _panel = _Panel.main;
      LogStore.error('tui', 'Start add failed: $e');
      _setStatus('Failed: $e', _StatusLevel.error, duration: 5);
    }
  }

  void _advanceToImport() {
    _statusTimer?.cancel();
    _panel = _Panel.import;
    _importFocus = 0;
    _labelCtrl.text = '';
    _stateCtrl.text = '';
    _setStatus(
      'Enter a label (empty = my-session, auto-dedupe), then paste session_code and press Enter',
      _StatusLevel.info,
    );
  }

  String _uniqueLabel(String base) {
    final labels = _store.loadAll().map((a) => a.label).toSet();
    if (!labels.contains(base)) return base;
    var i = 1;
    while (labels.contains('$base($i)')) {
      i++;
    }
    return '$base($i)';
  }

  void _doImport() async {
    final state = _stateCtrl.text.trim();
    final raw = _labelCtrl.text.trim();
    final base = raw.isEmpty ? 'my-session' : raw;
    final label = _uniqueLabel(base);
    if (state.isEmpty) {
      _setStatus(
        'State/session_code is required',
        _StatusLevel.error,
        duration: 4,
      );
      return;
    }
    _setStatus('Exchanging state for token...', _StatusLevel.info);
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
      _reload();
      LogStore.success('tui', 'Imported: $label (${a.id})');
      _setStatus('Imported: $label', _StatusLevel.success, duration: 3);
    } catch (e) {
      LogStore.error('tui', 'Import failed: $e');
      _setStatus('Import failed: $e', _StatusLevel.error, duration: 5);
    }
  }

  void _confirmDelete() {
    _panel = _Panel.delete;
    _setStatus(
      'Confirm deletion of "${_accts[_cursor].label}"',
      _StatusLevel.warning,
    );
  }

  void _doDelete() {
    final a = _accts[_cursor];
    _store.delete(a.id);
    _panel = _Panel.main;
    _reload();
    LogStore.info('tui', 'Deleted: ${a.label} (${a.id})');
    _setStatus('Deleted: ${a.label}', _StatusLevel.success, duration: 3);
  }

  void _cancelDelete() {
    _backToMain();
  }

  Component _helpPanel() {
    final lines = <Component>[];
    void add(String text, [Color? color]) {
      if (text.isEmpty) {
        lines.add(const SizedBox(height: 1));
        return;
      }
      lines.add(Text(text, style: TextStyle(color: color ?? Colors.white)));
    }

    void addRow(List<Component> items) {
      lines.add(Row(children: items));
    }

    // Title
    addRow([
      Text(
        'Help',
        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.cyan),
      ),
    ]);
    add('');

    // General
    add('Global Keys', Colors.yellow);
    addRow([
      Text(
        '  [Ctrl+L]  ',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      Text('Toggle log sidebar on/off', style: TextStyle(color: Colors.grey)),
    ]);
    addRow([
      Text(
        '  [h]  ',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      Text('Open this help panel', style: TextStyle(color: Colors.grey)),
    ]);
    addRow([
      Text(
        '  [\u2191/\u2193]  ',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      Text(
        'Navigate lists (accounts, log, help)',
        style: TextStyle(color: Colors.grey),
      ),
    ]);
    add('');

    // Main panel
    add('Main Panel \u2014 Account List', Colors.cyan);
    final mainKeys = [
      ('[a]dd ', 'Add a new account'),
      ('[d]el ', 'Delete selected account'),
      ('[e]nable ', 'Toggle selected account enabled/disabled'),
      ('[s]et ', 'Set selected account as current session'),
      ('[t]est ', 'Probe selected account quota'),
      ('[r]strat ', 'Open rotation strategy selector'),
      ('[R]otate ', 'Force rotate to next account'),
      ('[c] ', 'Copy storage path to clipboard'),
      ('[q]uit ', 'Quit application'),
    ];
    for (final (k, d) in mainKeys) {
      addRow([
        Text(
          '  $k',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        Text(d, style: TextStyle(color: Colors.grey)),
      ]);
    }
    add('');

    // Log keys
    add('Log Sidebar / Fullscreen', Colors.yellow);
    final logKeys = [
      ('[C]lear ', 'Clear all log entries'),
      ('[O]ld-clr ', 'Clear entries before today'),
      ('[f]ull / [f]side ', 'Toggle between sidebar and fullscreen log'),
      ('[Ctrl+L] ', 'Close log panel'),
    ];
    for (final (k, d) in logKeys) {
      addRow([
        Text(
          '  $k',
          style: TextStyle(color: Colors.yellow, fontWeight: FontWeight.bold),
        ),
        Text(d, style: TextStyle(color: Colors.grey)),
      ]);
    }
    add('');

    // Dialogs
    add('Dialogs', Colors.cyan);
    add('  Delete / Quit', Colors.red);
    addRow([
      Text(
        '    [Y]es  ',
        style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
      ),
      Text('Confirm  ', style: TextStyle(color: Colors.grey)),
      Text(
        '[N]o  ',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      Text('Cancel  ', style: TextStyle(color: Colors.grey)),
      Text(
        '[Esc]  ',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      Text('Back to main panel', style: TextStyle(color: Colors.grey)),
    ]);
    add('  Rotation Strategy', Colors.cyan);
    addRow([
      Text(
        '    [\u2191/\u2193]  ',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      Text('Navigate strategies  ', style: TextStyle(color: Colors.grey)),
      Text(
        '[Enter]  ',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      Text('Select / confirm', style: TextStyle(color: Colors.grey)),
    ]);
    add('  Request Count Input', Colors.cyan);
    addRow([
      Text(
        '    [Enter]  ',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      Text('Confirm N value  ', style: TextStyle(color: Colors.grey)),
      Text(
        '[Esc]  ',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      Text('Back to strategy list', style: TextStyle(color: Colors.grey)),
    ]);
    add('');

    // Add / Import
    add('Add Account Flow', Colors.cyan);
    add('  Step 1 \u2014 Auth URL', Colors.grey);
    addRow([
      Text(
        '    [c]opy  ',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      Text('Copy URL to clipboard  ', style: TextStyle(color: Colors.grey)),
      Text(
        '[Enter]  ',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      Text('Go to import panel', style: TextStyle(color: Colors.grey)),
    ]);
    add('  Step 2 \u2014 Import', Colors.grey);
    addRow([
      Text(
        '    [Tab]  ',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      Text(
        'Switch between Label / State fields',
        style: TextStyle(color: Colors.grey),
      ),
    ]);
    add('');

    // Strategy labels
    add('Rotation Strategies', Colors.yellow);
    add(
      '  exhausted-next     Advance when exhausted, next in order',
      Colors.grey,
    );
    add(
      '  exhausted-random   Advance when exhausted, random pick',
      Colors.grey,
    );
    add(
      '  request-count-next Advance every N API requests, in order',
      Colors.grey,
    );
    add(
      '  request-count-random Advance every N API requests, random',
      Colors.grey,
    );
    add('');

    // Storage
    add('Storage', Colors.yellow);
    add('  Accounts: ~/.config/codebuddy/accounts/', Colors.grey);
    add('  Config:  ~/.config/codebuddy/config.json', Colors.grey);
    add('  Logs:    ~/.config/codebuddy/logs.jsonl', Colors.grey);
    add('');

    // Footer hint
    add('Press [h] or [Esc] to close help', Colors.grey);

    final total = lines.length;
    if (total <= 18)
      return ListView(controller: _helpScrollCtrl, children: lines);
    return Scrollbar(
      controller: _helpScrollCtrl,
      thumbVisibility: true,
      thickness: 1,
      thumbColor: Colors.grey,
      child: ListView(controller: _helpScrollCtrl, children: lines),
    );
  }

  void _showHelp() {
    _panel = _Panel.help;
    _setStatus('Help \u2014 press [h] or [Esc] to close', _StatusLevel.info);
  }

  void _test() async {
    final a = _accts[_cursor];
    _setStatus('Testing ${a.label}...', _StatusLevel.info);
    final fresh = await _rotator.probeAccount(a.id);
    if (fresh != null) {
      LogStore.info(
        'tui',
        'Test ${a.label}: ${fresh.state.name} (${fresh.stateMsg})',
      );
      _setStatus(
        '${a.label}: ${fresh.state.name} (${fresh.stateMsg})',
        _StatusLevel.info,
        duration: 3,
      );
    } else {
      LogStore.warning('tui', 'Test ${a.label}: not found');
      _setStatus('${a.label}: not found', _StatusLevel.error, duration: 4);
    }
    _reload();
  }

  void _rotate() {
    final acc = _rotator.forceRotate();
    if (acc != null) {
      _reload();
      LogStore.info('tui', 'Rotated to ${acc.label} (${acc.id})');
      _setStatus('Rotated to ${acc.label}', _StatusLevel.success, duration: 3);
    } else {
      LogStore.warning('tui', 'Rotate: no accounts available');
      _setStatus('No accounts to rotate', _StatusLevel.warning, duration: 3);
    }
  }

  void _toggleEnabled() {
    final a = _accts[_cursor];
    a.enabled = !a.enabled;
    _store.save(a);
    _reload();
    if (a.enabled) {
      LogStore.info('tui', 'Enabled: ${a.label}');
      _setStatus('${a.label} enabled', _StatusLevel.success, duration: 2);
    } else {
      LogStore.info('tui', 'Disabled: ${a.label}');
      _setStatus('${a.label} disabled', _StatusLevel.warning, duration: 2);
    }
  }

  void _setCurrent() {
    final a = _accts[_cursor];
    final state = _store.loadState();
    state.currentId = a.id;
    state.lastRotationAt = DateTime.now();
    state.requestsSinceLast = 0;
    _store.saveState(state);
    _reload();
    LogStore.info('tui', 'Current session: ${a.label}');
    _setStatus(
      'Current session: ${a.label}',
      _StatusLevel.success,
      duration: 3,
    );
  }

  int _nextPri() {
    var max = 0;
    for (final a in _store.loadAll()) {
      if (a.priority > max) max = a.priority;
    }
    return max + 1;
  }
}
