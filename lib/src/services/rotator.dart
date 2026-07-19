import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/account.dart';
import '../models/config.dart';
import 'oauth.dart';

// ---------------------------------------------------------------------------
// Rotator — picks active account with strategy support
// ---------------------------------------------------------------------------

class Rotator {
  final Config cfg;
  final Store store;
  final OAuthClient auth;

  Rotator({required this.cfg, required this.store, required this.auth});

  /// Get the next access token (with refresh if needed)
  Future<Account?> get() async {
    final state = store.loadState();
    var cands = store.healthyAccounts();
    if (cands.isEmpty) {
      cands = store.loadAll().where((a) => a.enabled).toList();
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
      if (cfg.rotationStrategy == RotationStrategy.roundRobin) {
        state.nextRotationAt = DateTime.now().add(Duration(seconds: cfg.rotationIntervalS));
      }
      store.saveState(state);
      return next;
    }

    // Refresh if near expiry
    if (current.tokenIsExpired && current.refreshToken.isNotEmpty) {
      try {
        if (current == null) return null;
        final t = await auth.refresh(current.refreshToken);
        final exp = DateTime.now().add(Duration(seconds: t.expiresIn));
        store.updateTokens(current.id, t.accessToken, t.refreshToken, t.idToken, t.tokenType, t.scope, exp);
        current = store.find(current.id);
      } catch (e) {
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
    store.markUsed(current.id);
    return current;
  }

  bool shouldAdvance(Account? current, RotatorState state, List<Account> cands) {
    if (current == null) return true;
    switch (cfg.rotationStrategy) {
      case RotationStrategy.quotaAware:
        return current.state == AcctState.exhausted || current.state == AcctState.expired;
      case RotationStrategy.roundRobin:
        return state.nextRotationAt.isBefore(DateTime.now());
      case RotationStrategy.perRequest:
        return cfg.requestsPerRotation > 0 && state.requestsSinceLast >= cfg.requestsPerRotation;
    }
  }

  Account? nextAfter(List<Account> cands, Account? current) {
    if (current == null) return cands.isNotEmpty ? cands[0] : null;
    for (var i = 0; i < cands.length; i++) {
      if (cands[i].id == current.id) {
        return cands[(i + 1) % cands.length];
      }
    }
    return cands.isNotEmpty ? cands[0] : null;
  }

  Account? advanceToNext(String currentId) {
    final cands = store.healthyAccounts();
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

  /// Force advance to next account regardless of strategy
  Account? forceRotate() {
    final cands = store.healthyAccounts();
    if (cands.isEmpty) {
      final all = store.loadAll().where((a) => a.enabled).toList();
      if (all.isEmpty) return null;
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
    return next;
  }

  /// Probe a single account's quota
  Future<Account?> probeAccount(String id) async {
    final a = store.find(id);
    if (a == null) return null;
    if (a.accessToken.isEmpty) return a;

    final result = await auth.quotaProbe(a.accessToken);
    if (result.error != null) return a; // network error, leave state alone

    final (:state, :msg) = interpretQuotaResponse(result.status, result.body);
    if (state == AcctState.error) {
      return a; // inconclusive, leave state alone
    }
    store.markChecked(id, state, msg);
    return store.find(id);
  }

  /// Probe all enabled accounts
  Future<void> probeAll() async {
    for (final a in store.loadAll()) {
      if (!a.enabled) continue;
      await probeAccount(a.id);
    }
  }
}

/// Interpret quota probe HTTP response
({AcctState state, String msg}) interpretQuotaResponse(int status, String body) {
  if (status == 200) {
    try {
      final v = jsonDecode(body);
      if (v is Map) {
        for (final k in ['remaining', 'remain', 'left', 'balance', 'available', 'quota']) {
          if (v.containsKey(k) && v[k] is num) {
            final n = (v[k] as num).toDouble();
            if (n <= 0) return (state: AcctState.exhausted, msg: '$k=$n');
            return (state: AcctState.ok, msg: '$k=$n');
          }
        }
        if (v.containsKey('code') && v['code'] is num) {
          final code = (v['code'] as num).toInt();
          if (code != 0) return (state: AcctState.error, msg: 'code=$code msg=${v['msg']}');
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
      return (state: AcctState.error, msg: 'HTTP $status HTML (token valid, wrong scope)');
    }
    return (state: AcctState.expired, msg: 'HTTP $status (token rejected)');
  }

  if (status == 429) {
    return (state: AcctState.exhausted, msg: 'HTTP 429 rate limited');
  }

  return (state: AcctState.error, msg: 'HTTP $status');
}

bool looksLikeHtml(String body) {
  final h = body.substring(0, body.length < 200 ? body.length : 200).toLowerCase();
  return h.contains('<html') || h.contains('<!doctype');
}