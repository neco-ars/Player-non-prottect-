import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_services.dart';
import '../services/importer.dart';
import 'library_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// Импорт плейлиста из текста: вставил список — плеер нашёл песни и собрал плейлист.
class ImportPage extends StatefulWidget {
  const ImportPage({super.key});
  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  final _text = TextEditingController();
  final _name = TextEditingController(text: 'Импорт');
  List<ImportItem>? _items;
  bool _running = false;
  bool _cancel = false;

  int get _parsed => PlaylistImporter.parse(_text.text).length;

  Future<void> _start() async {
    final lines = PlaylistImporter.parse(_text.text);
    if (lines.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _items = [for (final l in lines) ImportItem(l)];
      _running = true;
      _cancel = false;
    });
    await PlaylistImporter(app.search).run(
      _items!,
      onUpdate: () => mounted ? setState(() {}) : null,
      cancelled: () => _cancel || !mounted,
    );
    if (mounted) setState(() => _running = false);
  }

  void _save() {
    final found = [for (final i in _items!) if (i.track != null) i.track!];
    if (found.isEmpty) return;
    final lib = app.library;
    final p = lib.createPlaylist(_name.text.trim().isEmpty ? 'Импорт' : _name.text.trim());
    for (final t in found) {
      lib.addTo(p, t);
    }
    // вместо экрана импорта сразу открываем новый плейлист
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => PlaylistPage(playlist: p)));
  }

  /// Загрузить список из файла .txt или .csv; название плейлиста — по имени файла.
  Future<void> _openFile() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Файл со списком песен',
      type: FileType.custom,
      allowedExtensions: const ['txt', 'csv'],
    );
    if (files.isEmpty || !mounted) return;
    final f = files.first;
    try {
      final text = PlaylistImporter.decodeFile(await f.readAsBytes());
      setState(() {
        _text.text = text;
        if (_name.text.trim().isEmpty || _name.text == 'Импорт') {
          _name.text = f.name.replaceAll(RegExp(r'\.(txt|csv)$', caseSensitive: false), '');
        }
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Загружено из «${f.name}»: ${PlaylistImporter.parse(text).length} песен')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось прочитать файл: $e')));
    }
  }

  void _copyMissing() {
    final missing = [for (final i in _items!) if (i.status == ImportStatus.notFound) i.line.raw];
    Clipboard.setData(ClipboardData(text: missing.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ненайденные строки скопированы')));
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Импорт плейлиста')),
      body: items == null ? _input() : _progress(items),
    );
  }

  Widget _input() => ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
          'Вставь список песен — по одной на строку, в виде «Исполнитель — Песня». '
          'Подойдёт список из любого места: Spotify, Apple Music, VK, заметки. '
          'Нумерация и длительность в строках не мешают. Можно вставить и таблицу CSV '
          'с колонками названия и исполнителя.\n\n'
          'Для каждой строки плеер найдёт лучшую версию на подключённых площадках '
          '(без цензуры, если включено «Предпочитать explicit»).',
          style: TextStyle(color: AppColors.textDim),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Название плейлиста', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _text,
          minLines: 10,
          maxLines: 20,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'LAZZY2WICE — Nuke\nKai Angel — Hurricane\n…',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Text('Песен: $_parsed', style: const TextStyle(color: AppColors.textDim)),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Файл .txt'),
            onPressed: _openFile,
          ),
          TextButton.icon(
            icon: const Icon(Icons.content_paste),
            label: const Text('Вставить'),
            onPressed: () async {
              final d = await Clipboard.getData(Clipboard.kTextPlain);
              if (d?.text != null) setState(() => _text.text = d!.text!);
            },
          ),
        ]),
        const SizedBox(height: 8),
        FilledButton.icon(
          icon: const Icon(Icons.search),
          label: const Text('Найти песни'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _parsed == 0 ? null : _start,
        ),
      ]);

  Widget _progress(List<ImportItem> items) {
    final done = items.where((i) => i.status == ImportStatus.found || i.status == ImportStatus.notFound).length;
    final found = items.where((i) => i.status == ImportStatus.found).length;
    final missing = items.where((i) => i.status == ImportStatus.notFound).length;
    return Column(children: [
      LinearProgressIndicator(value: items.isEmpty ? 0 : done / items.length, minHeight: 3),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          Expanded(
            child: Text(
              _running ? 'Ищу: $done из ${items.length}' : 'Найдено $found из ${items.length}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          if (_running) TextButton(onPressed: () => setState(() => _cancel = true), child: const Text('Стоп')),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final it = items[i];
            final t = it.track;
            return ListTile(
              dense: true,
              leading: switch (it.status) {
                ImportStatus.waiting => const Icon(Icons.schedule, color: AppColors.textDim),
                ImportStatus.searching =>
                  const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                ImportStatus.found => Cover(t!.coverUrl, size: 40),
                ImportStatus.notFound => const Icon(Icons.close, color: Colors.redAccent),
              },
              title: Text(t?.title ?? it.line.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Row(children: [
                if (t != null) ...[
                  if (t.explicit) const ExplicitBadge(),
                  SourceDot(t.source),
                ],
                Flexible(
                  child: Text(
                    it.status == ImportStatus.notFound
                        ? 'не найдено: ${it.line.raw}'
                        : (t?.artist ?? it.line.artist),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            );
          },
        ),
      ),
      if (!_running)
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              if (missing > 0)
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy),
                  label: Text('Ненайденные ($missing)'),
                  onPressed: _copyMissing,
                ),
              const Spacer(),
              FilledButton.icon(
                icon: const Icon(Icons.playlist_add_check),
                label: Text('Создать плейлист ($found)'),
                onPressed: found == 0 ? null : _save,
              ),
            ]),
          ),
        ),
    ]);
  }
}
