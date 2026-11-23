import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpServer, InternetAddress, ContentType;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'library.dart';

/// Вход через Google и синхронизация медиатеки (плейлисты, «Любимое», история, «Скрытое»,
/// что ты дослушиваешь и пропускаешь) между телефоном, ПК и браузером.
///
/// Хранилище — Supabase (бесплатный тариф): одна строка на пользователя в таблице `libraries`,
/// доступ к ней есть только у самого пользователя (правила RLS, см. supabase/schema.sql).
/// Адрес проекта и публичный ключ вшиваются при сборке: SUPABASE_URL и SUPABASE_ANON_KEY.
class SyncService extends ChangeNotifier {
  static const _url = String.fromEnvironment('SUPABASE_URL');
  static const _key = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Синхронизация включена в этой сборке.
  static bool get configured => _url.isNotEmpty && _key.isNotEmpty;

  /// Куда Google вернёт человека после входа в приложении для Android.
  static const mobileRedirect = 'com.musicplayer.music_player://login-callback';

  final Library library;
  SyncService(this.library);

  bool _ready = false;
  bool busy = false;
  bool _again = false;
  String? error;
  DateTime? lastSync;
  Timer? _pushTimer;
  Timer? _pullTimer;

  SupabaseClient get _db => Supabase.instance.client;
  User? get user => _ready ? _db.auth.currentUser : null;
  bool get signedIn => user != null;

  String get userName {
    final m = user?.userMetadata ?? const {};
    return (m['full_name'] ?? m['name'] ?? user?.email ?? '').toString();
  }

  String? get userEmail => user?.email;
  String? get avatarUrl => (user?.userMetadata?['avatar_url'] ?? user?.userMetadata?['picture'])?.toString();

  Future<void> init() async {
    if (!configured) return;
    try {
      await Supabase.initialize(
        url: _url,
        publishableKey: _key,
        authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
      );
      _ready = true;
    } catch (e) {
      error = 'Синхронизация не запустилась: $e';
      debugPrint(error);
      return;
    }
    _db.auth.onAuthStateChange.listen((s) {
      notifyListeners();
      if (s.event == AuthChangeEvent.signedIn) unawaited(syncNow());
    }, onError: (e) {
      error = 'Вход не удался: $e';
      notifyListeners();
    });
    library.onSaved = _schedulePush;
    // изменения с других устройств подтягиваем раз в несколько минут
    _pullTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      if (signedIn) unawaited(syncNow());
    });
    if (signedIn) unawaited(syncNow());
  }

  void _schedulePush() {
    if (!signedIn) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(seconds: 4), () => unawaited(syncNow()));
  }

  // ---------- вход ----------

  /// Войти через Google. В браузере — переход на страницу Google и обратно на сайт,
  /// на Android — через браузер с возвратом в приложение, на ПК — через браузер
  /// с возвратом на временный локальный адрес (как у приложений Google для компьютера).
  Future<void> signIn() async {
    if (!_ready) throw Exception(error ?? 'синхронизация не настроена в этой сборке');
    error = null;
    if (kIsWeb) {
      final back = '${Uri.base.origin}${Uri.base.path}'; // адрес сайта без ?code= и #
      await _db.auth.signInWithOAuth(OAuthProvider.google, redirectTo: back);
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
      await _db.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: mobileRedirect,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
      return;
    }
    await _desktopSignIn();
  }

  Future<void> _desktopSignIn() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirect = 'http://localhost:${server.port}/';
      final res = await _db.auth.getOAuthSignInUrl(provider: OAuthProvider.google, redirectTo: redirect);
      if (!await launchUrl(Uri.parse(res.url), mode: LaunchMode.externalApplication)) {
        throw Exception('не удалось открыть браузер');
      }
      String? code;
      String? fail;
      await for (final req in server.timeout(const Duration(minutes: 5))) {
        final q = req.uri.queryParameters;
        code = q['code'];
        fail = q['error_description'] ?? q['error'];
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(_page(code != null
              ? 'Готово! Вход выполнен — можно закрыть эту вкладку и вернуться в Music Player.'
              : 'Вход не удался${fail == null ? '' : ': $fail'}. Закрой вкладку и попробуй ещё раз.'));
        await req.response.close();
        if (code != null || fail != null) break;
      }
      if (code == null) throw Exception(fail ?? 'вход не завершён');
      await _db.auth.exchangeCodeForSession(code);
    } on TimeoutException {
      throw Exception('не дождались входа в браузере (5 минут)');
    } finally {
      await server.close(force: true);
    }
  }

  static String _page(String text) => '<!doctype html><meta charset="utf-8"><title>Music Player</title>'
      '<body style="font-family:sans-serif;background:#121212;color:#fff;display:flex;'
      'align-items:center;justify-content:center;height:100vh;margin:0">'
      '<p style="font-size:20px;max-width:520px;text-align:center">${const HtmlEscape().convert(text)}</p>';

  Future<void> signOut() async {
    if (!_ready) return;
    _pushTimer?.cancel();
    await _db.auth.signOut();
    lastSync = null;
    notifyListeners();
  }

  // ---------- синхронизация ----------

  /// Забрать версию из облака, слить с этой и отправить результат обратно.
  /// Ничего не теряется: см. [Library.merge].
  Future<void> syncNow() async {
    final u = user;
    if (u == null) return;
    if (busy) {
      _again = true;
      return;
    }
    busy = true;
    notifyListeners();
    try {
      final row = await _db.from('libraries').select('data').eq('user_id', u.id).maybeSingle();
      final raw = row?['data'];
      final remote = raw is Map ? Map<String, dynamic>.from(raw) : null;
      final local = library.toJson();
      final merged = remote == null ? local : Library.merge(local, remote);
      final m = canonical(merged);
      if (m != canonical(local)) library.replaceWith(merged);
      if (remote == null || m != canonical(remote)) {
        await _db.from('libraries').upsert({
          'user_id': u.id,
          'data': merged,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
      lastSync = DateTime.now();
      error = null;
    } catch (e) {
      error = describe(e);
      debugPrint('Синхронизация: $e');
    } finally {
      busy = false;
      notifyListeners();
    }
    if (_again) {
      _again = false;
      unawaited(syncNow());
    }
  }

  static String describe(Object e) {
    final s = '$e';
    if (s.contains('relation') && s.contains('does not exist') || s.contains('PGRST205')) {
      return 'в Supabase нет таблицы libraries — выполни supabase/schema.sql (см. docs/SYNC.md)';
    }
    if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('Failed to fetch')) {
      return 'нет связи с сервером синхронизации';
    }
    return s.replaceFirst('Exception: ', '');
  }

  /// JSON с ключами по алфавиту: база (jsonb) меняет порядок ключей, а сравнивать надо содержимое.
  static String canonical(Object? v) {
    Object? sort(Object? x) {
      if (x is Map) {
        final keys = x.keys.map((k) => '$k').toList()..sort();
        return {for (final k in keys) k: sort(x[k])};
      }
      if (x is List) return [for (final e in x) sort(e)];
      if (x is double && x == x.roundToDouble()) return x.toInt();
      return x;
    }

    return jsonEncode(sort(v));
  }

  @override
  void dispose() {
    _pushTimer?.cancel();
    _pullTimer?.cancel();
    super.dispose();
  }
}
