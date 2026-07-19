import 'dart:convert';
import 'dart:math';
import '../models/account.dart';
import '../models/config.dart';
import 'oauth.dart';
import 'log_store.dart';

class Rotator {
  final Config cfg;
  final Store store;
  final OAuthClient auth;
  final _rng = Random();

  Rotator({required this.cfg, required this.store, required this.auth});

  List<Account> _sorted(List<Account> accounts) {
    accounts.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return accounts;
  }

  Future<Account?> get() async {
    final state = store.loadState();
    var cands = _sorted(store.healthyAccounts());
    if (cands.isEmpty) {
      cands = _sorted(store.loadAll().where((a) => a.enabled).toList());
    }
    if (cands.isEmpty) return null;

    Account? current;
    if (state.currentId.isNotEmpty) {
      current = cands.where((a) => a.id == state.currentId).firstOrNull;
    }

    if (shouldAdvance(current, state, cands) || current == null) {
      final next = nextAfter(cands, current);
      if (next == null) return null;
      state.currentId = next.id;
      state.lastRotationAt = DateTime.now();
      state.requestsSinceLast = 0;
      store.saveState(state);
      LogStore.info('rotator', 'Advance to ${next.label} (${next.id})');
      return next;
    }

    if (current.tokenIsExpired && current.refreshToken.isNotEmpty) {
      LogStore.info('rotator', 'Refreshing token for ${current.label}');
      try {
        final t = await auth.refresh(current.refreshToken);
        final exp = DateTime.now().add(Duration(seconds: t.expiresIn));
        store.updateTokens(
          current.id,
          t.accessToken,
          t.refreshToken,
          t.idToken,
          t.tokenType,
          t.scope,
          exp,
        );
        current = store.find(current.id);
        if (current != null)
          LogStore.success('rotator', 'Token refreshed for ${current.id}');
      } catch (e) {
        final cid = current?.id ?? 'unknown';
        LogStore.error('rotator', 'Refresh failed for $cid: $e');
        if (current == null) return null;
        store.markChecked(current.id, AcctState.expired, 'refresh failed: $e');
        final next = nextAfter(cands, current);
        if (next != null) {
          state.currentId = next.id;
          state.lastRotationAt = DateTime.now();
          state.requestsSinceLast = 0;
          store.saveState(state);
          return next;
        }
      }
    }

    if (current == null) return null;
    state.requestsSinceLast++;
    store.saveState(state);
    store.markUsed(current.id);
    return current;
  }

  bool shouldAdvance(
    Account? current,
    RotatorState state,
    List<Account> cands,
  ) {
    if (current == null) return true;
    return switch (cfg.rotationStrategy) {
      RotationStrategy.exhaustedNext || RotationStrategy.exhaustedRandom =>
        current.state == AcctState.exhausted ||
            current.state == AcctState.expired,
      RotationStrategy.requestCountNext ||
      RotationStrategy.requestCountRandom =>
        cfg.requestsPerRotation > 0 &&
            state.requestsSinceLast >= cfg.requestsPerRotation,
    };
  }

  Account? nextAfter(List<Account> cands, Account? current) {
    if (cands.isEmpty) return null;
    final isRandom =
        cfg.rotationStrategy == RotationStrategy.exhaustedRandom ||
        cfg.rotationStrategy == RotationStrategy.requestCountRandom;

    if (isRandom) {
      if (cands.length == 1) return cands[0];
      final others = current != null
          ? cands.where((a) => a.id != current.id).toList()
          : cands;
      if (others.isEmpty) return cands[0];
      return others[_rng.nextInt(others.length)];
    }

    if (current == null) return cands[0];
    for (var i = 0; i < cands.length; i++) {
      if (cands[i].id == current.id) {
        return cands[(i + 1) % cands.length];
      }
    }
    return cands[0];
  }

  Account? advanceToNext(String currentId) {
    final cands = _sorted(store.healthyAccounts());
    if (cands.isEmpty) return null;
    for (var i = 0; i < cands.length; i++) {
      if (cands[i].id == currentId) {
        final next = cands[(i + 1) % cands.length];
        final state = store.loadState();
        state.currentId = next.id;
        state.lastRotationAt = DateTime.now();
        state.requestsSinceLast = 0;
        store.saveState(state);
        return next;
      }
    }
    return cands[0];
  }

  Account? forceRotate() {
    final cands = store.healthyAccounts();
    if (cands.isEmpty) {
      final all = _sorted(store.loadAll().where((a) => a.enabled).toList());
      if (all.isEmpty) {
        LogStore.warning('rotator', 'Force rotate: no accounts');
        return null;
      }
      final state = store.loadState();
      Account? current;
      if (state.currentId.isNotEmpty) {
        current = all.where((a) => a.id == state.currentId).firstOrNull;
      }
      final next = nextAfter(all, current) ?? all[0];
      state.currentId = next.id;
      state.lastRotationAt = DateTime.now();
      state.requestsSinceLast = 0;
      store.saveState(state);
      LogStore.info('rotator', 'Force rotated to ${next.label} (${next.id})');
      return next;
    }
    final state = store.loadState();
    Account? current;
    if (state.currentId.isNotEmpty) {
      current = cands.where((a) => a.id == state.currentId).firstOrNull;
    }
    final next = nextAfter(cands, current) ?? cands[0];
    state.currentId = next.id;
    state.lastRotationAt = DateTime.now();
    state.requestsSinceLast = 0;
    store.saveState(state);
    LogStore.info('rotator', 'Force rotated to ${next.label} (${next.id})');
    return next;
  }

  Future<Account?> probeAccount(String id) async {
    final a = store.find(id);
    if (a == null) return null;
    if (a.accessToken.isEmpty) return a;

    LogStore.info('rotator', 'Probing ${a.label} (${a.id})');
    final result = await auth.quotaProbe(a.accessToken);
    if (result.error != null) {
      LogStore.warning('rotator', 'Probe ${a.id}: error ${result.error}');
      return a;
    }

    final (:state, :msg) = interpretQuotaResponse(result.status, result.body);
    if (state == AcctState.error) {
      LogStore.warning(
        'rotator',
        'Probe ${a.id}: error response (status=${result.status})',
      );
      return a;
    }
    store.markChecked(id, state, msg);
    LogStore.info('rotator', 'Probe ${a.id}: ${state.name} (${msg})');
    return store.find(id);
  }

  Future<void> probeAll() async {
    LogStore.info('rotator', 'Probing all accounts');
    for (final a in store.loadAll()) {
      if (!a.enabled) continue;
      await probeAccount(a.id);
    }
  }
}

({AcctState state, String msg}) interpretQuotaResponse(
  int status,
  String body,
) {
  if (status == 200) {
    try {
      final v = jsonDecode(body);
      if (v is Map) {
        for (final k in [
          'remaining',
          'remain',
          'left',
          'balance',
          'available',
          'quota',
        ]) {
          if (v.containsKey(k) && v[k] is num) {
            final n = (v[k] as num).toDouble();
            if (n <= 0) return (state: AcctState.exhausted, msg: '$k=$n');
            return (state: AcctState.ok, msg: '$k=$n');
          }
        }
        if (v.containsKey('code') && v['code'] is num) {
          final code = (v['code'] as num).toInt();
          if (code != 0)
            return (state: AcctState.error, msg: 'code=$code msg=${v['msg']}');
        }
      }
      if (looksLikeHtml(body)) {
        return (state: AcctState.error, msg: '200 OK but HTML response');
      }
      return (state: AcctState.ok, msg: '200 OK');
    } catch (_) {
      if (looksLikeHtml(body)) {
        return (state: AcctState.error, msg: '200 OK but HTML response');
      }
      return (state: AcctState.ok, msg: '200 OK');
    }
  }

  if (status == 401 || status == 403) {
    if (looksLikeHtml(body)) {
      return (
        state: AcctState.error,
        msg: 'HTTP $status HTML (token valid, wrong scope)',
      );
    }
    return (state: AcctState.expired, msg: 'HTTP $status (token rejected)');
  }

  if (status == 429) {
    return (state: AcctState.exhausted, msg: 'HTTP 429 rate limited');
  }

  return (state: AcctState.error, msg: 'HTTP $status');
}

bool looksLikeHtml(String body) {
  final h = body
      .substring(0, body.length < 200 ? body.length : 200)
      .toLowerCase();
  return h.contains('<html') || h.contains('<!doctype');
}
