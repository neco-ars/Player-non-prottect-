import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/track.dart';
import 'theme.dart';

const sourceColors = {
  'local': Color(0xFF2EC4B6),
  'yandex': Color(0xFFFFCC00),
  'soundcloud': Color(0xFFFF5500),
  'audiomack': Color(0xFFFFA200),
  'zvuk': Color(0xFF3D6BFF),
  'youtube': Color(0xFFFF0033),
};
const sourceNames = {'local': 'Мои файлы', 'yandex': 'Яндекс', 'soundcloud': 'SoundCloud', 'audiomack': 'Audiomack', 'zvuk': 'Звук', 'youtube': 'YouTube'};

String fmtDuration(Duration? d) {
  if (d == null || d == Duration.zero) return '';
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class Cover extends StatelessWidget {
  final String? url;
  final double size;
  final double radius;
  final IconData placeholderIcon;
  const Cover(this.url, {super.key, this.size = 52, this.radius = 4, this.placeholderIcon = Icons.music_note});

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      color: AppColors.cardHover,
      child: Icon(placeholderIcon, size: size * 0.45, color: AppColors.textDim),
    );
    final u = url;
    // декодируем картинку в том размере, в каком она на экране, а не в исходном —
    // меньше работы процессору и памяти (батарея), быстрее появляется
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: u == null
          ? placeholder
          : u.startsWith('file:') && !kIsWeb
              // обложка из «Моих файлов» лежит на устройстве
              ? Image.file(File(Uri.parse(u).toFilePath()),
                  width: size,
                  height: size,
                  cacheWidth: px,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => placeholder)
              : Image.network(u,
                  width: size,
                  height: size,
                  cacheWidth: px,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => placeholder),
    );
  }
}

class ExplicitBadge extends StatelessWidget {
  const ExplicitBadge({super.key});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(color: AppColors.textDim, borderRadius: BorderRadius.circular(2)),
        child: const Text('E', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.black)),
      );
}

/// Маленькая цветная метка площадки.
class SourceDot extends StatelessWidget {
  final String source;
  const SourceDot(this.source, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: 8,
        height: 8,
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(color: sourceColors[source] ?? Colors.grey, shape: BoxShape.circle),
      );
}

/// Строка трека: обложка, название (акцентом, если играет), исполнитель, ⋮.
class TrackTile extends StatelessWidget {
  final Track track;
  final bool playing;
  final VoidCallback onTap;
  final VoidCallback? onMenu;
  final Widget? trailing;
  final int? number;
  const TrackTile(
      {super.key, required this.track, required this.onTap, this.onMenu, this.playing = false, this.trailing, this.number});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onMenu,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
        child: Row(children: [
          if (number != null)
            SizedBox(
              width: 28,
              child: playing
                  ? const Icon(Icons.graphic_eq, size: 18, color: AppColors.accent)
                  : Text('$number', style: const TextStyle(color: AppColors.textDim)),
            ),
          Cover(track.coverUrl, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w500, color: playing ? AppColors.accent : AppColors.text)),
              const SizedBox(height: 3),
              Row(children: [
                if (track.explicit) const ExplicitBadge(),
                SourceDot(track.source),
                if (track.isVideo) const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.smart_display, size: 14, color: AppColors.textDim),
                ),
                Flexible(
                  child: Text(track.artist,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
                ),
              ]),
            ]),
          ),
          trailing ??
              (onMenu == null
                  ? const SizedBox.shrink()
                  : IconButton(icon: const Icon(Icons.more_vert, color: AppColors.textDim), onPressed: onMenu)),
        ]),
      ),
    );
  }
}

/// Кнопка-версия трека: площадка, длительность, explicit, превью.
class VariantChip extends StatelessWidget {
  final Track track;
  final bool playing;
  final VoidCallback onTap;
  const VariantChip({super.key, required this.track, required this.onTap, this.playing = false});

  @override
  Widget build(BuildContext context) {
    final color = sourceColors[track.source] ?? Colors.grey;
    final label = [
      sourceNames[track.source] ?? track.source,
      fmtDuration(track.duration),
      if (track.extra['drm'] == true) 'защищён' else if (track.previewOnly) 'превью',
    ].where((s) => s.isNotEmpty).join(' · ');
    return Material(
      color: playing ? color.withValues(alpha: 0.25) : AppColors.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(playing ? Icons.graphic_eq : (track.isVideo ? Icons.smart_display : Icons.play_arrow),
                size: 14, color: color),
            const SizedBox(width: 4),
            if (track.explicit) const ExplicitBadge(),
            Text(label, style: const TextStyle(fontSize: 12, color: AppColors.text)),
          ]),
        ),
      ),
    );
  }
}

/// Свайп влево — следующий трек, вправо — предыдущий (обложка в плеере, мини-плеер).
/// Короткие и медленные движения игнорируются, чтобы не переключать случайно.
class SwipeToSkip extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const SwipeToSkip({super.key, required this.child, this.onTap});
  @override
  State<SwipeToSkip> createState() => _SwipeToSkipState();
}

class _SwipeToSkipState extends State<SwipeToSkip> {
  double _dx = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onHorizontalDragUpdate: (d) => setState(() => _dx += d.delta.dx),
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          final far = _dx.abs() > 60;
          if ((v < -250 || (far && _dx < 0)) && skipHandlers.next != null) {
            skipHandlers.next!();
          } else if ((v > 250 || (far && _dx > 0)) && skipHandlers.previous != null) {
            skipHandlers.previous!();
          }
          setState(() => _dx = 0);
        },
        onHorizontalDragCancel: () => setState(() => _dx = 0),
        // во время свайпа элемент немного едет за пальцем
        child: Transform.translate(offset: Offset(_dx.clamp(-80, 80) * 0.6, 0), child: widget.child),
      );
}

/// Что делать при свайпе — задаётся при запуске (плеер), чтобы виджеты не зависели от сервисов.
class SkipHandlers {
  VoidCallback? next;
  VoidCallback? previous;
}

final skipHandlers = SkipHandlers();

/// Большая круглая кнопка «играть».
class PlayButton extends StatelessWidget {
  final VoidCallback onPressed;
  final double size;
  final bool playing;
  const PlayButton({super.key, required this.onPressed, this.size = 52, this.playing = false});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: Material(
          color: AppColors.accent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Icon(playing ? Icons.pause : Icons.play_arrow, color: Colors.black, size: size * 0.55),
          ),
        ),
      );
}

/// Заголовок секции.
class SectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const SectionTitle(this.title, {super.key, this.subtitle, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 8, 10),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
              if (subtitle != null)
                Text(subtitle!, style: const TextStyle(fontSize: 13, color: AppColors.textDim)),
            ]),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Карточка в горизонтальной карусели: большая обложка + подписи.
class CoverCard extends StatelessWidget {
  final String? cover;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool explicit;
  final bool playing;
  final double size;
  const CoverCard({
    super.key,
    required this.cover,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.onLongPress,
    this.explicit = false,
    this.playing = false,
    this.size = 148,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: size,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Stack(children: [
              Cover(cover, size: size, radius: 6),
              if (playing)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                    child: const Icon(Icons.graphic_eq, size: 18, color: Colors.black),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            Text(title,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            if (subtitle != null)
              Row(children: [
                if (explicit) const ExplicitBadge(),
                Flexible(
                  child: Text(subtitle!,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
                ),
              ]),
          ]),
        ),
      );
}
