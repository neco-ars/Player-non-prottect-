import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../platform.dart';
import '../sources/yandex.dart';
import 'theme.dart';

/// Встроенный вход есть только на телефоне (Android, iPhone): на Windows и в браузере
/// встроенной страницы входа нет — там вход через браузер и вставку токена.
bool get inAppLoginSupported => isMobile;

/// Вход в Яндекс: страница входа Яндекса прямо в приложении.
/// После входа Яндекс перенаправляет на адрес с access_token — забираем его сами.
Future<String?> loginYandex(BuildContext context) => Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => _LoginPage(
          title: 'Вход в Яндекс',
          start: YandexSource.authUrl,
          hint: 'Войди в свой аккаунт Яндекса — токен подхватится сам.',
          onUrl: (url) {
            final m = RegExp(r'access_token=([^&]+)').firstMatch(url);
            return m?.group(1);
          },
        ),
      ),
    );

/// Вход в Звук: обычная страница входа zvuk.com. Когда вошёл — нажимаешь «Готово»,
/// приложение открывает страницу профиля и берёт из неё токен.
Future<String?> loginZvuk(BuildContext context) => Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => _LoginPage(
          title: 'Вход в Звук',
          start: Uri.parse('https://zvuk.com/'),
          hint: 'Нажми «Войти» на сайте и войди в свой аккаунт. Потом нажми «Готово» внизу.',
          doneButton: true,
          profileUrl: Uri.parse('https://zvuk.com/api/tiny/profile'),
          readProfile: (text) {
            try {
              final j = jsonDecode(text) as Map;
              final r = j['result'] as Map?;
              final token = r?['token'];
              if (token is! String || token.isEmpty) return null;
              // гостевой профиль (без входа) нам не нужен — с ним только 30-секундные фрагменты
              final anon = r?['is_anonymous'] == true || (r?['profile'] as Map?)?['is_anonymous'] == true;
              return anon ? '' : token;
            } catch (_) {
              return null;
            }
          },
        ),
      ),
    );

class _LoginPage extends StatefulWidget {
  final String title;
  final Uri start;
  final String hint;
  final String? Function(String url)? onUrl;
  final bool doneButton;
  final Uri? profileUrl;
  final String? Function(String bodyText)? readProfile;
  const _LoginPage({
    required this.title,
    required this.start,
    required this.hint,
    this.onUrl,
    this.doneButton = false,
    this.profileUrl,
    this.readProfile,
  });

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  late final WebViewController _web;
  bool _loading = true;
  bool _readingProfile = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: _onPageFinished,
        onUrlChange: (c) => _checkUrl(c.url),
        onNavigationRequest: (r) {
          _checkUrl(r.url);
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(widget.start);
  }

  void _checkUrl(String? url) {
    if (url == null || widget.onUrl == null) return;
    final token = widget.onUrl!(url);
    if (token != null && token.isNotEmpty) _finish(token);
  }

  Future<void> _onPageFinished(String url) async {
    if (mounted) setState(() => _loading = false);
    _checkUrl(url);
    if (!_readingProfile || widget.readProfile == null) return;
    _readingProfile = false;
    final raw = await _web.runJavaScriptReturningResult('document.body.innerText');
    // результат приходит строкой в кавычках (JSON-строка) — разворачиваем
    var text = '$raw';
    try {
      final decoded = jsonDecode(text);
      if (decoded is String) text = decoded;
    } catch (_) {}
    final token = widget.readProfile!(text);
    if (!mounted) return;
    if (token == null) {
      _snack('Не удалось прочитать профиль. Попробуй ещё раз.');
      await _web.goBack();
    } else if (token.isEmpty) {
      _snack('Похоже, вход ещё не выполнен. Войди в аккаунт и снова нажми «Готово».');
      await _web.loadRequest(widget.start);
    } else {
      _finish(token);
    }
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  void _finish(String token) {
    if (_finished || !mounted) return;
    _finished = true;
    Navigator.pop(context, token);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Column(children: [
          Container(
            width: double.infinity,
            color: AppColors.card,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Text(widget.hint, style: const TextStyle(color: AppColors.textDim)),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: WebViewWidget(controller: _web)),
        ]),
        floatingActionButton: widget.doneButton
            ? FloatingActionButton.extended(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.black,
                icon: const Icon(Icons.check),
                label: const Text('Готово, я вошёл'),
                onPressed: () {
                  _readingProfile = true;
                  _web.loadRequest(widget.profileUrl!);
                },
              )
            : null,
      );
}
