import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/track.dart';
import '../services/app_services.dart';
import '../sources/net.dart';
import '../sources/yandex.dart';
import '../version.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _token = TextEditingController(text: app.settings.yandexToken ?? '');
  late final _ytKey = TextEditingController(text: app.settings.youtubeKey ?? '');
  late final _proxy = TextEditingController(text: app.settings.proxyUrl ?? '');
  late final _zvuk = TextEditingController(text: app.settings.zvukToken ?? '');
  late final _amKey = TextEditingController(text: app.settings.audiomackKey ?? '');
  late final _amSecret = TextEditingController(text: app.settings.audiomackSecret ?? '');

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  void _saveYandex() {
    // можно вставить как сам токен, так и всю ссылку из адресной строки
    var v = _token.text.trim();
    final m = RegExp(r'access_token=([^&]+)').firstMatch(v);
    if (m != null) v = m.group(1)!;
    _token.text = v;
    app.settings.yandexToken = v;
    app.yandex.token = v.isEmpty ? null : v;
    _toast(v.isEmpty ? 'Яндекс отключён' : 'Яндекс подключён');
    setState(() {});
  }

  void _saveYouTube() {
    final v = _ytKey.text.trim();
    app.settings.youtubeKey = v;
    app.youtube.apiKey = v.isEmpty ? null : v;
    _toast(v.isEmpty ? 'YouTube отключён' : 'YouTube подключён');
    setState(() {});
  }

  Widget _status(bool ok) => Chip(
        label: Text(ok ? 'подключено' : 'не подключено'),
        avatar: Icon(ok ? Icons.check_circle : Icons.cancel_outlined, size: 18),
        visualDensity: VisualDensity.compact,
      );

  @override
  Widget build(BuildContext context) {
    final h = Theme.of(context).textTheme.titleMedium;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Без цензуры', style: h),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Предпочитать explicit'),
          subtitle: const Text('Если песня нашлась в нескольких версиях, по нажатию играет версия с пометкой E.'),
          value: app.settings.preferExplicit,
          onChanged: (v) => setState(() {
            app.settings.preferExplicit = v;
            TrackGroup.preferExplicitDefault(v);
          }),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Искать оригинал'),
          subtitle: const Text('Когда играет «чистая» версия, плеер ищет ту же песню без цензуры на других площадках '
              'и предлагает переключиться.'),
          value: app.settings.findOriginal,
          onChanged: (v) => setState(() {
            app.settings.findOriginal = v;
            app.player.findOriginal = v;
          }),
        ),
        const Divider(height: 40),
        Row(children: [Expanded(child: Text('Яндекс Музыка', style: h)), _status(app.yandex.isConfigured)]),
        const SizedBox(height: 8),
        const Text(
          '1. Нажми «Войти в Яндекс» и войди в свой аккаунт.\n'
          '2. После входа браузер откроет пустую страницу. Скопируй весь адрес из адресной строки.\n'
          '3. Вставь его сюда и нажми «Сохранить».\n\n'
          'Полные треки и «Моя волна» доступны с подпиской Яндекс Плюс. Токен хранится только на этом устройстве.',
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.login),
          label: const Text('Войти в Яндекс'),
          onPressed: () => launchUrl(YandexSource.authUrl, mode: LaunchMode.externalApplication),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _token,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Токен или ссылка после входа', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton(onPressed: _saveYandex, child: const Text('Сохранить')),
          const SizedBox(width: 8),
          if (app.yandex.isConfigured)
            TextButton(
              onPressed: () {
                _token.clear();
                _saveYandex();
              },
              child: const Text('Выйти'),
            ),
        ]),
        const Divider(height: 40),
        Row(children: [Expanded(child: Text('YouTube', style: h)), _status(app.youtube.isConfigured)]),
        const SizedBox(height: 8),
        const Text(
          'Для поиска по YouTube нужен бесплатный ключ YouTube Data API:\n'
          '1. Открой Google Cloud Console и создай проект.\n'
          '2. В «Библиотеке API» включи «YouTube Data API v3».\n'
          '3. В «Учётных данных» создай «Ключ API» и вставь его сюда.\n\n'
          'Бесплатного лимита хватает примерно на 100 поисков в день. '
          'Ролики играют через официальный плеер YouTube: на экране, без фонового режима.',
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('Открыть Google Cloud Console'),
          onPressed: () => launchUrl(Uri.parse('https://console.cloud.google.com/apis/library/youtube.googleapis.com'),
              mode: LaunchMode.externalApplication),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ytKey,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Ключ YouTube Data API', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton(onPressed: _saveYouTube, child: const Text('Сохранить')),
          const SizedBox(width: 8),
          if (app.youtube.isConfigured)
            TextButton(
              onPressed: () {
                _ytKey.clear();
                _saveYouTube();
              },
              child: const Text('Отключить'),
            ),
        ]),
        if (Net.needsProxy) ...[
          const Divider(height: 40),
          Row(children: [Expanded(child: Text('Прокси (веб-версия)', style: h)), _status(Net.proxy.isNotEmpty)]),
          const SizedBox(height: 8),
          const Text('Браузер не пускает сайт напрямую в Яндекс и SoundCloud, поэтому запросы идут через прокси '
              'на Cloudflare Workers. Обычно адрес уже вшит в сборку — поле нужно, только если его поменяли.'),
          const SizedBox(height: 12),
          TextField(
            controller: _proxy,
            decoration: const InputDecoration(
                labelText: 'Адрес прокси', hintText: 'https://music-proxy.ИМЯ.workers.dev', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () {
              _proxy.text = Net.normalize(_proxy.text);
              app.settings.proxyUrl = _proxy.text;
              Net.userProxy = _proxy.text;
              _toast('Сохранено');
              setState(() {});
            },
            child: const Text('Сохранить'),
          ),
        ],
        const Divider(height: 40),
        Row(children: [Expanded(child: Text('Звук', style: h)), _status(app.zvuk.isConfigured)]),
        const SizedBox(height: 8),
        const Text(
          'Без входа работает поиск, но вместо треков Звук может отдавать только 30-секундные фрагменты '
          '(тогда плеер сам ищет полную версию на других площадках).\n\n'
          'Для полных треков вставь токен своего аккаунта — подписка не обязательна, '
          'если на сайте Звука ты можешь слушать без неё. С подпиской — 320 кбит/с:\n'
          '1. Войди на zvuk.com в браузере.\n'
          '2. Не закрывая сайт, открой ссылку ниже — откроется текст с данными профиля.\n'
          '3. Скопируй значение поля "token" (без кавычек) и вставь сюда.\n'
          'Токен никому не показывай.',
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('Открыть zvuk.com/api/tiny/profile'),
          onPressed: () =>
              launchUrl(Uri.parse('https://zvuk.com/api/tiny/profile'), mode: LaunchMode.externalApplication),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _zvuk,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: 'Токен Звука (необязательно)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () {
            final v = _zvuk.text.trim();
            app.settings.zvukToken = v;
            app.zvuk.userToken = v.isEmpty ? null : v;
            _toast(v.isEmpty ? 'Звук: гостевой доступ' : 'Звук: вход по токену');
            setState(() {});
          },
          child: const Text('Сохранить'),
        ),
        const Divider(height: 40),
        Row(children: [Expanded(child: Text('Audiomack', style: h)), _status(app.audiomack.isConfigured)]),
        const SizedBox(height: 8),
        const Text(
          'Площадка, куда артисты сами выкладывают музыку — много рэпа в оригинальных версиях.\n\n'
          'Нужны ключи Audiomack Data API (consumer key и consumer secret). Их выдают по запросу:\n'
          '1. Открой страницу документации API (кнопка ниже) и найди ссылку для связи.\n'
          '2. Напиши, что делаешь личный некоммерческий плеер и нужен доступ к поиску и воспроизведению.\n'
          '3. Когда пришлют ключи — вставь их сюда.',
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('Документация Audiomack API'),
          onPressed: () =>
              launchUrl(Uri.parse('https://audiomack.com/data-api/docs'), mode: LaunchMode.externalApplication),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _amKey,
          decoration: const InputDecoration(labelText: 'Consumer key', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _amSecret,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Consumer secret', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () {
            final k = _amKey.text.trim(), s = _amSecret.text.trim();
            app.settings.audiomackKey = k;
            app.settings.audiomackSecret = s;
            app.audiomack.consumerKey = k;
            app.audiomack.consumerSecret = s;
            _toast(k.isEmpty || s.isEmpty ? 'Audiomack отключён' : 'Audiomack подключён');
            setState(() {});
          },
          child: const Text('Сохранить'),
        ),
        const Divider(height: 40),
        Text('SoundCloud', style: h),
        const SizedBox(height: 8),
        const Text('Работает без входа. Треки SoundCloud Go+ доступны только фрагментом — для них плеер сам ищет полную версию на других площадках.'),
        const SizedBox(height: 32),
        Center(
          child: Text('Music Player $appVersion',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}
