import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/track.dart';
import '../services/app_services.dart';
import '../services/keys.dart';
import '../services/sync.dart';
import '../sources/net.dart';
import '../sources/zvuk.dart';
import '../version.dart';
import 'equalizer_page.dart';
import 'login_page.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _ytKey = TextEditingController(text: app.settings.youtubeKey ?? '');
  late final _proxy = TextEditingController(text: app.settings.proxyUrl ?? '');
  late final _genius = TextEditingController(text: app.settings.geniusToken ?? '');
  late final _zvuk = TextEditingController(text: app.settings.zvukToken ?? '');
  late final _amKey = TextEditingController(text: app.settings.audiomackKey ?? '');
  late final _amSecret = TextEditingController(text: app.settings.audiomackSecret ?? '');

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  /// Сохранить вход в Звук и сразу проверить: вошёл ли человек или вставлен гостевой токен.
  Future<void> _saveZvuk(String pasted) async {
    final token = ZvukSource.extractToken(pasted);
    if (token.isEmpty) {
      app.settings.zvukToken = '';
      app.zvuk.userToken = null;
      _zvuk.clear();
      _toast('Звук: вышли из аккаунта');
      setState(() {});
      return;
    }
    try {
      final name = await app.zvuk.checkLogin(token);
      if (!mounted) return;
      if (name == null) {
        _toast('Это гостевой доступ: сначала войди на zvuk.com (шаг 1), потом снова открой шаг 2');
        return;
      }
      app.settings.zvukToken = token;
      app.zvuk.userToken = token;
      _zvuk.text = token;
      _toast(name.isEmpty ? 'Звук: вход выполнен' : 'Звук: вход выполнен — $name');
      setState(() {});
    } catch (e) {
      // проверить не дала сеть или защита Звука (часто — из-за VPN): токен всё равно сохраняем
      app.settings.zvukToken = token;
      app.zvuk.userToken = token;
      _zvuk.text = token;
      if (mounted) {
        _toast('Токен сохранён, но проверить его не удалось: ${Net.describe(e)}. '
            'Если Звук не играет — выключи VPN или исключи из него приложение.');
        setState(() {});
      }
    }
  }

  void _saveYouTube() {
    final v = _ytKey.text.trim();
    app.settings.youtubeKey = v;
    app.youtube.apiKey = AppKeys.pick(v, AppKeys.youtube);
    _toast(v.isEmpty ? 'YouTube отключён' : 'YouTube подключён');
    setState(() {});
  }

  /// Вход в Звук вставкой токена: открыть zvuk.com, войти, скопировать страницу с токеном.
  List<Widget> _manualZvuk() => [
        OutlinedButton.icon(
          icon: const Icon(Icons.login),
          label: const Text('1. Открыть zvuk.com и войти'),
          onPressed: () => launchUrl(Uri.parse('https://zvuk.com/'), mode: LaunchMode.externalApplication),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.key),
          label: const Text('2. Открыть страницу с токеном'),
          onPressed: () => launchUrl(Uri.parse('https://zvuk.com/api/tiny/profile'), mode: LaunchMode.externalApplication),
        ),
        const SizedBox(height: 4),
        const Text(
          'На этой странице выдели всё (Ctrl+A, на телефоне — долгое нажатие → «Выбрать всё»), скопируй и вставь ниже '
          'целиком — токен приложение найдёт само.',
          style: TextStyle(fontSize: 12, color: AppColors.textDim),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _zvuk,
          maxLines: 2,
          decoration:
              const InputDecoration(labelText: '3. Вставь сюда текст страницы (или только токен)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          FilledButton(onPressed: () => _saveZvuk(_zvuk.text), child: const Text('Сохранить и проверить')),
          if (app.zvuk.userToken?.isNotEmpty == true)
            TextButton(onPressed: () => _saveZvuk(''), child: const Text('Выйти')),
        ]),
      ];

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
        const AccountSection(),
        const Divider(height: 32),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.equalizer),
          title: Text('Эквалайзер', style: h),
          subtitle: Text(app.player.equalizer.supported
              ? (app.player.equalizer.enabled ? 'Включён · ${app.player.equalizer.preset}' : 'Выключен')
              : 'Только в приложениях для Android и Windows'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const EqualizerPage()));
            setState(() {});
          },
        ),
        const Divider(height: 32),
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
        Row(children: [Expanded(child: Text('Звук', style: h)), _status(app.zvuk.isConfigured)]),
        if (kIsWeb && !ZvukSource.webAvailable)
          const Text(
            'В веб-версии Звук работает только через свой прокси на сервере в России (proxy-vps): '
            'с серверов Cloudflare Звук отклоняет запросы. В приложениях для Android и Windows он работает всегда.',
            style: TextStyle(color: AppColors.textDim),
          )
        else ...[
          const SizedBox(height: 8),
          const Text(
            'Без входа Звук ищет, но вместо треков отдаёт 30-секундные фрагменты. Чтобы слушать целиком, '
            'войди своим аккаунтом (подписка не обязательна; с подпиской — 320 кбит/с).',
            style: TextStyle(color: AppColors.textDim),
          ),
          const SizedBox(height: 12),
          if (inAppLoginSupported) ...[
            FilledButton.icon(
              icon: const Icon(Icons.login),
              label: Text(app.zvuk.userToken?.isNotEmpty == true ? 'Войти заново' : 'Войти в Звук'),
              onPressed: () async {
                final token = await loginZvuk(context);
                if (token != null && mounted) await _saveZvuk(token);
              },
            ),
            // если встроенный вход не открывается (VPN, защита Звука) — можно вставить токен самому
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                title: const Text('Вставить токен вручную'),
                subtitle: const Text('Если кнопка входа не срабатывает', style: TextStyle(fontSize: 12)),
                children: _manualZvuk(),
              ),
            ),
          ] else ...[
            // В браузере и на ПК встроенного входа нет: браузер не даёт читать вход на чужом сайте.
            const Text('Вход в 3 шага:', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ..._manualZvuk(),
          ],
        ],
        const Divider(height: 40),
        Text('SoundCloud', style: h),
        const SizedBox(height: 8),
        const Text(
            'Работает без входа. Треки SoundCloud Go+ доступны только фрагментом — для них плеер сам ищет полную версию на других площадках.'),
        const Divider(height: 40),
        // ключи приложения: обычно уже встроены в сборку, свои нужны, только если встроенный закончился
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Text('Дополнительно: свои ключи', style: h),
          subtitle: const Text('YouTube, Genius, Audiomack, прокси. Обычно уже встроены — трогать не нужно.'),
          children: [
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
              onPressed: () => launchUrl(
                  Uri.parse('https://console.cloud.google.com/apis/library/youtube.googleapis.com'),
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
              const Text('Браузер не пускает сайт напрямую в Звук и SoundCloud, поэтому запросы идут через прокси '
                  'на Cloudflare Workers. Обычно адрес уже вшит в сборку — поле нужно, только если его поменяли.'),
              const SizedBox(height: 12),
              TextField(
                controller: _proxy,
                decoration: const InputDecoration(
                    labelText: 'Адрес прокси',
                    hintText: 'https://music-proxy.ИМЯ.workers.dev',
                    border: OutlineInputBorder()),
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
            Row(children: [Expanded(child: Text('Genius', style: h)), _status(app.genius.token?.isNotEmpty == true)]),
            const SizedBox(height: 8),
            const Text('Нужен, чтобы кнопка «Открыть текст на Genius» вела сразу на страницу песни, а не в поиск. '
                'Токен: genius.com/api-clients → New API Client → Generate Access Token.'),
            const SizedBox(height: 12),
            TextField(
              controller: _genius,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Genius Client Access Token', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () {
                final v = _genius.text.trim();
                app.settings.geniusToken = v;
                app.genius.token = AppKeys.pick(v, AppKeys.genius);
                _toast(v.isEmpty ? 'Genius: встроенный ключ' : 'Genius: свой токен');
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
                app.audiomack.consumerKey = AppKeys.pick(k, AppKeys.audiomackKey);
                app.audiomack.consumerSecret = AppKeys.pick(s, AppKeys.audiomackSecret);
                _toast(k.isEmpty || s.isEmpty ? 'Audiomack отключён' : 'Audiomack подключён');
                setState(() {});
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
        const SizedBox(height: 32),
        Center(
          child: Text('Music Player $appVersion',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

/// Аккаунт Google и синхронизация медиатеки между устройствами.
class AccountSection extends StatelessWidget {
  const AccountSection({super.key});

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'только что';
    if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final h = Theme.of(context).textTheme.titleMedium;
    final sync = app.sync;
    if (!SyncService.configured) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Аккаунт и синхронизация', style: h),
        const SizedBox(height: 6),
        const Text(
          'В этой сборке синхронизация не включена. Владельцу сборки: см. docs/SYNC.md в репозитории.',
          style: TextStyle(color: AppColors.textDim),
        ),
      ]);
    }
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        void toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
        if (!sync.signedIn) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Аккаунт и синхронизация', style: h),
            const SizedBox(height: 6),
            const Text(
              'Войди через Google — плейлисты, «Любимое», история и твой вкус для «Моей волны» '
              'будут одинаковыми на телефоне, ПК и в браузере.',
              style: TextStyle(color: AppColors.textDim),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.account_circle),
              label: const Text('Войти через Google'),
              onPressed: () async {
                try {
                  await sync.signIn();
                } catch (e) {
                  toast('Не удалось войти: ${SyncService.describe(e)}');
                }
              },
            ),
            if (sync.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(sync.error!, style: const TextStyle(color: Colors.redAccent)),
              ),
          ]);
        }
        final avatar = sync.avatarUrl;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundImage: avatar == null ? null : NetworkImage(avatar),
              child: avatar == null ? const Icon(Icons.person) : null,
            ),
            title: Text(sync.userName.isEmpty ? 'Аккаунт Google' : sync.userName, style: h),
            subtitle: Text([
              if (sync.userEmail != null && sync.userEmail != sync.userName) sync.userEmail!,
              sync.busy
                  ? 'Синхронизация…'
                  : sync.error != null
                      ? 'Ошибка: ${sync.error}'
                      : sync.lastSync == null
                          ? 'Ещё не синхронизировано'
                          : 'Синхронизировано ${_ago(sync.lastSync!)}',
            ].join('\n')),
          ),
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.sync),
              label: const Text('Синхронизировать'),
              onPressed: sync.busy ? null : sync.syncNow,
            ),
            TextButton(
              onPressed: () async {
                await sync.signOut();
                toast('Вышли из аккаунта. Медиатека на этом устройстве осталась.');
              },
              child: const Text('Выйти'),
            ),
          ]),
        ]);
      },
    );
  }
}
