import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform.dart';

/// Готовая настройка эквалайзера: усиление (дБ) в зависимости от частоты полосы.
class EqPreset {
  final String name;
  final double Function(double hz) curve;
  const EqPreset(this.name, this.curve);
}

/// Эквалайзер с двумя «движками» и одинаковым интерфейсом:
/// - Android — системный эквалайзер (через just_audio);
/// - Windows/Linux — фильтр `equalizer` из FFmpeg в движке mpv, 10 полос.
/// На iPhone и в браузере недоступен: там нет способа обработать звук.
class EqualizerService extends ChangeNotifier {
  final AndroidEqualizer? android = isAndroid ? AndroidEqualizer() : null;
  final bool _desktop = isDesktop;

  bool get supported => android != null || _desktop;

  bool enabled = false;
  String preset = 'Ровно';

  // Android: полосы приходят от системы, когда у плеера есть звук.
  AndroidEqualizerParameters? _params;
  List<double> _saved = const [];

  // ПК: свои 10 полос.
  static const _desktopHz = [31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];
  final List<double> _desktopGains = List.filled(_desktopHz.length, 0);

  /// Полосы готовы к настройке (на Android — после запуска первого трека).
  bool get ready => _desktop || _params != null;

  int get bandCount => _desktop ? _desktopHz.length : (_params?.bands.length ?? 0);
  double get minDb => _desktop ? -12 : (_params?.minDecibels ?? -12);
  double get maxDb => _desktop ? 12 : (_params?.maxDecibels ?? 12);

  double bandHz(int i) {
    if (_desktop) return _desktopHz[i];
    final cf = _params!.bands[i].centerFrequency;
    return cf > 50000 ? cf / 1000 : cf; // некоторые устройства отдают миллигерцы
  }

  double gain(int i) => _desktop ? _desktopGains[i] : _params!.bands[i].gain;

  static final presets = <EqPreset>[
    EqPreset('Ровно', (_) => 0),
    EqPreset('Бас', (hz) => hz < 150 ? 6 : hz < 400 ? 4 : hz < 1000 ? 1 : 0),
    EqPreset('Супер-бас', (hz) => hz < 150 ? 9 : hz < 400 ? 6 : hz < 1000 ? 1 : -1),
    EqPreset('Рэп', (hz) => hz < 150 ? 5 : hz < 400 ? 3 : hz < 2000 ? 0 : hz < 6000 ? 2 : 3),
    EqPreset('Вокал', (hz) => hz < 150 ? -2 : hz < 400 ? 0 : hz < 4000 ? 4 : 1),
    EqPreset('Высокие', (hz) => hz < 1000 ? 0 : hz < 6000 ? 3 : 5),
    EqPreset('Рок', (hz) => hz < 150 ? 5 : hz < 400 ? 2 : hz < 2000 ? -1 : hz < 6000 ? 3 : 5),
    EqPreset('Электроника', (hz) => hz < 150 ? 6 : hz < 400 ? 2 : hz < 2000 ? 0 : hz < 6000 ? 2 : 5),
  ];

  /// Для плеера на Android: подключить эквалайзер к звуковому тракту.
  AudioPipeline? get pipeline => android == null ? null : AudioPipeline(androidAudioEffects: [android!]);

  Future<void> load() async {
    if (!supported) return;
    final p = await SharedPreferences.getInstance();
    enabled = p.getBool('eq_on') ?? false;
    preset = p.getString('eq_preset') ?? 'Ровно';
    _saved = (p.getString('eq_gains') ?? '').split(',').map(double.tryParse).whereType<double>().toList();
    if (_desktop) {
      for (var i = 0; i < _desktopGains.length && i < _saved.length; i++) {
        _desktopGains[i] = _clamp(_saved[i]);
      }
      await _applyDesktop();
    }
  }

  /// Android: полосы доступны, только когда у плеера есть звук. Вызывается после запуска трека.
  Future<void> attach() async {
    final eq = android;
    if (eq == null || _params != null) return;
    try {
      _params = await eq.parameters;
      final bands = _params!.bands;
      for (var i = 0; i < bands.length && i < _saved.length; i++) {
        await bands[i].setGain(_clamp(_saved[i]));
      }
      await eq.setEnabled(enabled);
      notifyListeners();
    } catch (e) {
      debugPrint('Эквалайзер недоступен: $e');
    }
  }

  double _clamp(double v) => min(maxDb, max(minDb, v));

  Future<void> setEnabled(bool v) async {
    enabled = v;
    await android?.setEnabled(v);
    await _applyDesktop();
    await _save();
    notifyListeners();
  }

  Future<void> setGain(int band, double db) async {
    await _setBand(band, _clamp(db));
    preset = 'Своя';
    await _applyDesktop();
    notifyListeners();
    await _save();
  }

  Future<void> applyPreset(EqPreset p) async {
    if (!ready) return;
    for (var i = 0; i < bandCount; i++) {
      await _setBand(i, _clamp(p.curve(bandHz(i))));
    }
    preset = p.name;
    enabled = true;
    await android?.setEnabled(true);
    await _applyDesktop();
    await _save();
    notifyListeners();
  }

  Future<void> _setBand(int i, double db) async {
    if (_desktop) {
      _desktopGains[i] = db;
    } else {
      await _params?.bands[i].setGain(db);
    }
  }

  /// ПК: собираем фильтр для mpv. Перед эквалайзером немного убавляем общий уровень,
  /// если полосы подняты, — иначе на громких местах будет хрип (клиппинг).
  static String desktopFilter(List<double> hz, List<double> gains) {
    final parts = <String>[];
    final boost = gains.fold<double>(0, (m, g) => max(m, g));
    if (boost > 0) parts.add('volume=volume=-${(boost * 0.7).toStringAsFixed(1)}dB');
    for (var i = 0; i < hz.length; i++) {
      if (gains[i].abs() < 0.05) continue;
      parts.add('equalizer=f=${hz[i].round()}:t=o:w=1:g=${gains[i].toStringAsFixed(1)}');
    }
    return parts.isEmpty ? '' : 'lavfi=[${parts.join(',')}]';
  }

  Future<void> _applyDesktop() async {
    if (!_desktop) return;
    try {
      await JustAudioMediaKit.setAudioFilter(enabled ? desktopFilter(_desktopHz, _desktopGains) : '');
    } catch (e) {
      debugPrint('Эквалайзер на ПК: $e');
    }
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('eq_on', enabled);
    await p.setString('eq_preset', preset);
    if (ready) {
      await p.setString('eq_gains', [for (var i = 0; i < bandCount; i++) gain(i).toStringAsFixed(1)].join(','));
    }
  }

  static String formatHz(double hz) =>
      hz >= 1000 ? '${(hz / 1000).toStringAsFixed(hz >= 10000 || hz % 1000 == 0 ? 0 : 1)} кГц' : '${hz.round()} Гц';
}
