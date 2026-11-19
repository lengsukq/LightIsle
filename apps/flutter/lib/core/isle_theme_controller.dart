import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'isle_style.dart';
import 'isle_theme_presets.dart';

/// Persists and notifies changes to the active theme preset and brightness mode.
class IsleThemeController extends ChangeNotifier {
  IsleThemeController({
    IsleThemePresetId initialPreset = IsleThemePresetId.warmGallery,
    ThemeMode initialThemeMode = ThemeMode.system,
    Future<SharedPreferences> Function()? openPreferences,
  }) : _presetId = initialPreset,
       _themeMode = initialThemeMode,
       _openPreferences = openPreferences ?? SharedPreferences.getInstance {
    IslePalette.activePreset = IsleThemePresets.byId(_presetId);
  }

  static const String presetPreferenceKey = 'lightisle.theme.preset.v1';
  static const String modePreferenceKey = 'lightisle.theme.mode.v1';

  final Future<SharedPreferences> Function() _openPreferences;

  IsleThemePresetId _presetId;
  ThemeMode _themeMode;
  bool _loaded = false;

  IsleThemePresetId get presetId => _presetId;
  IsleThemePreset get preset => IsleThemePresets.byId(_presetId);
  ThemeMode get themeMode => _themeMode;
  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      final prefs = await _openPreferences();
      final savedPreset = IsleThemePresetId.fromStorageKey(
        prefs.getString(presetPreferenceKey),
      );
      final savedMode = _themeModeFromStorage(
        prefs.getString(modePreferenceKey),
      );
      final changed = savedPreset != _presetId || savedMode != _themeMode;
      _presetId = savedPreset;
      _themeMode = savedMode;
      _loaded = true;
      IslePalette.activePreset = preset;
      if (changed) notifyListeners();
    } catch (_) {
      _loaded = true;
    }
  }

  Future<void> setPreset(IsleThemePresetId next) async {
    if (_presetId == next) return;
    _presetId = next;
    IslePalette.activePreset = preset;
    notifyListeners();
    try {
      final prefs = await _openPreferences();
      await prefs.setString(presetPreferenceKey, next.storageKey);
    } catch (_) {
      // Keep the in-memory theme switch responsive even if local storage fails.
    }
  }

  Future<void> setThemeMode(ThemeMode next) async {
    if (_themeMode == next) return;
    _themeMode = next;
    notifyListeners();
    try {
      final prefs = await _openPreferences();
      await prefs.setString(modePreferenceKey, _themeModeToStorage(next));
    } catch (_) {
      // Keep the in-memory mode switch responsive even if local storage fails.
    }
  }

  Future<void> reset() async {
    final changed =
        _presetId != IsleThemePresetId.warmGallery ||
        _themeMode != ThemeMode.system;
    _presetId = IsleThemePresetId.warmGallery;
    _themeMode = ThemeMode.system;
    IslePalette.activePreset = preset;
    if (changed) notifyListeners();
    try {
      final prefs = await _openPreferences();
      await prefs.remove(presetPreferenceKey);
      await prefs.remove(modePreferenceKey);
    } catch (_) {
      // Ignore storage failures during reset.
    }
  }

  static ThemeMode _themeModeFromStorage(String? raw) => switch (raw) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String _themeModeToStorage(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };
}

/// Provides [IsleThemeController] to descendant widgets without extra packages.
class IsleThemeScope extends InheritedNotifier<IsleThemeController> {
  const IsleThemeScope({
    super.key,
    required IsleThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static IsleThemeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IsleThemeScope>()?.notifier;

  static IsleThemeController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'No IsleThemeScope found in context.');
    return controller!;
  }
}
