import 'package:flutter/foundation.dart';

/// В браузере сайты не могут напрямую обращаться к API Яндекса и SoundCloud (CORS).
/// Поэтому веб-версия ходит через свой прокси на Cloudflare Workers (папка proxy/).
/// В приложениях для Android/iOS/Windows запросы идут напрямую.
class Net {
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
