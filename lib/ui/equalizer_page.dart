import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../services/equalizer.dart';
import 'theme.dart';

class EqualizerPage extends StatelessWidget {
  const EqualizerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final eq = app.player.equalizer;
    return Scaffold(
      appBar: AppBar(title: const Text('Эквалайзер')),
      body: !eq.supported
          ? const _Note('Эквалайзер доступен только в приложении для Android: на iPhone, в браузере и на Windows '
              'плеер не даёт к нему доступа.')
          : ListenableBuilder(
              listenable: eq,
              builder: (context, _) {
                final params = eq.params;
                return ListView(padding: const EdgeInsets.all(16), children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Включить', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                    subtitle: Text(eq.enabled ? 'Пресет: ${eq.preset}' : 'Звук без обработки'),
                    value: eq.enabled,
                    onChanged: params == null ? null : eq.setEnabled,
                  ),
                  if (params == null)
                    const _Note('Включи любой трек — полосы эквалайзера появятся, когда плеер начнёт играть.')
                  else ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final p in EqualizerService.presets)
                        ChoiceChip(
                          label: Text(p.name),
                          selected: eq.preset == p.name,
                          showCheckmark: false,
                          selectedColor: AppColors.accent,
                          labelStyle: TextStyle(
                              color: eq.preset == p.name ? Colors.black : AppColors.text, fontWeight: FontWeight.w600),
                          backgroundColor: AppColors.card,
                          side: BorderSide.none,
                          shape: const StadiumBorder(),
                          onSelected: (_) => eq.applyPreset(p),
                        ),
                    ]),
                    const SizedBox(height: 24),
                    Opacity(
                      opacity: eq.enabled ? 1 : 0.4,
                      child: SizedBox(
                        height: 300,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < params.bands.length; i++)
                              Expanded(child: _Band(index: i, eq: eq)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Диапазон: ${params.minDecibels.round()}…+${params.maxDecibels.round()} дБ. '
                      'Сильное усиление баса на громкости может давать хрип — тогда убавь пару делений.',
                      style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                    ),
                  ],
                ]);
              },
            ),
    );
  }
}

class _Band extends StatelessWidget {
  final int index;
  final EqualizerService eq;
  const _Band({required this.index, required this.eq});

  @override
  Widget build(BuildContext context) {
    final params = eq.params!;
    final band = params.bands[index];
    return StreamBuilder<double>(
      stream: band.gainStream,
      initialData: band.gain,
      builder: (context, snap) {
        final gain = snap.data ?? 0;
        return Column(children: [
          Text('${gain >= 0 ? '+' : ''}${gain.toStringAsFixed(0)}',
              style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(
                min: params.minDecibels,
                max: params.maxDecibels,
                value: gain.clamp(params.minDecibels, params.maxDecibels),
                activeColor: AppColors.accent,
                onChanged: eq.enabled ? (v) => eq.setGain(index, v) : null,
              ),
            ),
          ),
          Text(EqualizerService.formatHz(EqualizerService.hz(band)), style: const TextStyle(fontSize: 11)),
        ]);
      },
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim)),
      );
}
