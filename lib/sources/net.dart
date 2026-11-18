import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';

/// В браузере сайты не могут напрямую обращаться к API Звука и SoundCloud (CORS).
/// Поэтому веб-версия ходит через свой прокси на Cloudflare Workers (папка proxy/).
/// В приложениях для Android/iOS/Windows запросы идут напрямую.
class Net {
  /// Один клиент на всё приложение: соединения переиспользуются (keep-alive),
  /// поэтому не нужно заново устанавливать защищённое соединение на каждый запрос —
  /// это быстрее и экономит батарею. Сетевые сбои (оборванное TLS-соединение, таймаут,
  /// 502/503) повторяются до двух раз.
  static final http.Client client = RetryClient(
    http.Client(),
    retries: 2,
    when: (r) => r.statusCode == 502 || r.statusCode == 503 || r.statusCode == 504,
    whenError: (e, _) => isTransient(e),
    delay: (attempt) => Duration(milliseconds: 400 * (attempt + 1)),
  );

  /// Временный сетевой сбой, после которого стоит повторить запрос.
  static bool isTransient(Object e) {
    if (e is TimeoutException || e is http.ClientException) return true;
    final s = '$e';
    return s.contains('Handshake') ||
        s.contains('SocketException') ||
        s.contains('Connection reset') ||
        s.contains('Connection closed') ||
        s.contains('Connection terminated');
  }

  /// Понятный текст сетевой ошибки для пользователя.
  static String describe(Object e) {
    final s = '$e';
    // в браузере так выглядит отказ прокси (старая версия worker.js или чужой адрес сайта)
    if (kIsWeb && s.contains('Failed to fetch')) {
      return 'прокси не пропустил запрос — обнови worker.js на Cloudflare (см. proxy/README.md) '
          'и открывай сайт по адресу из ALLOWED_ORIGIN';
    }
    if (s.contains('Handshake')) return 'не удалось установить защищённое соединение (сеть или провайдер обрывает его)';
    if (s.contains('SocketException') || s.contains('Failed host lookup')) return 'нет соединения с сервером';
    if (e is TimeoutException) return 'сервер не ответил вовремя';
    return s.replaceFirst('Exception: ', '');
  }

  /// Адрес прокси, вшитый при сборке: --dart-define=PROXY_URL=https://...workers.dev
  static const _builtIn = String.fromEnvironment('PROXY_URL');

  /// Адрес из настроек приложения (перекрывает вшитый).
  static String? userProxy;

  static String get proxy => normalize(userProxy?.trim().isNotEmpty == true ? userProxy! : _builtIn);

  /// «music-proxy.x.workers.dev» → «https://music-proxy.x.workers.dev» (без слеша на конце).
  static String normalize(String raw) {
    var p = raw.trim();
    if (p.isEmpty) return p;
    if (!p.startsWith(RegExp(r'https?://'))) p = 'https://$p';
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static bool get needsProxy => kIsWeb;
  static bool get proxyMissing => kIsWeb && proxy.isEmpty;

  static Uri wrap(Uri u) {
    if (!kIsWeb || proxy.isEmpty) return u;
    return Uri.parse('$proxy/?url=${Uri.encodeComponent(u.toString())}');
  }
}
