import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/radio_settings.dart';
import '../services/app_debug_log_service.dart';

/// Convert device coding-rate value (1-4 on some firmware, 5-8 on others)
/// to the UI enum range (always 5-8).
int _toUiCodingRate(int deviceCr) {
  return deviceCr <= 4 ? deviceCr + 4 : deviceCr;
}

/// Frequencies stock companion firmware accepts for off-grid client repeat
/// when it doesn't report its own list (CMD_GET_ALLOWED_REPEAT_FREQ).
const List<RepeatFreqRange> _defaultRepeatFreqRanges = [
  (lowKHz: 433000, highKHz: 433000),
  (lowKHz: 869495, highKHz: 869495),
  (lowKHz: 918000, highKHz: 918000),
];

List<RepeatFreqRange> _repeatFreqRanges(MeshCoreConnector connector) {
  final ranges = connector.allowedRepeatFreqRanges;
  return ranges == null || ranges.isEmpty ? _defaultRepeatFreqRanges : ranges;
}

/// Whether the radio's firmware says it accepts [freqKHz] for off-grid
/// client repeat.
bool _isAllowedRepeatFreqKHz(MeshCoreConnector connector, int freqKHz) {
  return _repeatFreqRanges(
    connector,
  ).any((r) => freqKHz >= r.lowKHz && freqKHz <= r.highKHz);
}

/// The frequency the firmware allows for off-grid repeat nearest [freqKHz].
int _nearestAllowedRepeatFreqKHz(MeshCoreConnector connector, int freqKHz) {
  final candidates = [
    for (final r in _repeatFreqRanges(connector))
      freqKHz.clamp(r.lowKHz, r.highKHz),
  ];
  return candidates.reduce(
    (a, b) => (a - freqKHz).abs() <= (b - freqKHz).abs() ? a : b,
  );
}

String _mhz(int kHz) => (kHz / 1000.0).toStringAsFixed(3);

/// "433.000, 869.495 or 918.000" style list of the allowed repeat frequencies.
String _allowedRepeatFreqList(MeshCoreConnector connector) {
  return _repeatFreqRanges(connector)
      .map(
        (r) => r.lowKHz == r.highKHz
            ? _mhz(r.lowKHz)
            : '${_mhz(r.lowKHz)}–${_mhz(r.highKHz)}',
      )
      .join(', ');
}

/// Lowest TX power companion firmware accepts (CMD_SET_RADIO_TX_POWER).
const int _minTxPowerDbm = -9;

/// Radio parameter editor (preset, frequency, bandwidth, SF, CR, TX power and
/// off-grid client repeat). Stays open when the radio rejects or fails to
/// apply the settings so the user's edits are not lost.
///
/// Off-grid repeat uses whatever frequency is chosen: the app no longer moves
/// it to 433/869.495/918 MHz. Firmware that only allows repeat on certain
/// frequencies refuses others, and the dialog then offers the nearest one.
class RadioSettingsDialog extends StatefulWidget {
  final MeshCoreConnector connector;

  const RadioSettingsDialog({super.key, required this.connector});

  @override
  State<RadioSettingsDialog> createState() => _RadioSettingsDialogState();
}

class _RadioSettingsDialogState extends State<RadioSettingsDialog> {
  final _frequencyController = TextEditingController();
  LoRaBandwidth _bandwidth = LoRaBandwidth.bw125;
  LoRaSpreadingFactor _spreadingFactor = LoRaSpreadingFactor.sf7;
  LoRaCodingRate _codingRate = LoRaCodingRate.cr4_5;
  final _txPowerController = TextEditingController(text: '22');
  bool _clientRepeat = false;
  int? _selectedPresetIndex;
  String? _frequencyError;
  String? _txPowerError;

  AppDebugLogService get _appLog =>
      Provider.of<AppDebugLogService>(context, listen: false);

  @override
  void initState() {
    super.initState();

    if (widget.connector.currentFreqHz != null) {
      _frequencyController.text = (widget.connector.currentFreqHz! / 1000.0)
          .toStringAsFixed(3);
    } else {
      _frequencyController.text = '915.0';
    }

    final bwValue = widget.connector.currentBwHz;
    if (bwValue != null) {
      _bandwidth =
          LoRaBandwidth.values.where((bw) => bw.hz == bwValue).firstOrNull ??
          _bandwidth;
    }

    final sfValue = widget.connector.currentSf;
    if (sfValue != null) {
      _spreadingFactor =
          LoRaSpreadingFactor.values
              .where((sf) => sf.value == sfValue)
              .firstOrNull ??
          _spreadingFactor;
    }

    if (widget.connector.currentCr != null) {
      final crValue = _toUiCodingRate(widget.connector.currentCr!);
      _codingRate =
          LoRaCodingRate.values
              .where((cr) => cr.value == crValue)
              .firstOrNull ??
          _codingRate;
    }

    if (widget.connector.currentTxPower != null) {
      _txPowerController.text = widget.connector.currentTxPower.toString();
    }

    _clientRepeat = widget.connector.clientRepeat ?? false;
    _selectedPresetIndex = _findMatchingPresetIndex();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _logRadioSettingsState('Dialog initialized');
    });
  }

  @override
  void dispose() {
    _frequencyController.dispose();
    _txPowerController.dispose();
    super.dispose();
  }

  void _applyPreset(int index) {
    setState(() {
      _applyPresetState(index);
    });
    _logRadioSettingsState(
      'Applied preset ${RadioSettings.presets[index].$1} (#$index)',
    );
  }

  /// Presets match on frequency, bandwidth, SF and CR (not TX power).
  int? _findMatchingPresetIndex() {
    final snapshot = _currentSnapshot();
    for (final i in _visiblePresetIndexes()) {
      final preset = RadioSettings.presets[i].$2;
      if (preset.frequencyHz == snapshot.frequencyHz &&
          preset.bandwidth == snapshot.bandwidth &&
          preset.spreadingFactor == snapshot.spreadingFactor &&
          preset.codingRate == snapshot.codingRate) {
        return i;
      }
    }
    return null;
  }

  Iterable<int> _visiblePresetIndexes() =>
      Iterable<int>.generate(RadioSettings.presets.length);

  _RadioSettingsSnapshot _currentSnapshot() {
    final frequencyMHz = double.tryParse(_frequencyController.text) ?? 915.0;
    final txPowerDbm = int.tryParse(_txPowerController.text) ?? 22;
    return _RadioSettingsSnapshot(
      frequencyMHz: frequencyMHz,
      bandwidth: _bandwidth,
      spreadingFactor: _spreadingFactor,
      codingRate: _codingRate,
      txPowerDbm: txPowerDbm,
    );
  }

  void _applyPresetState(int index) {
    final preset = RadioSettings.presets[index].$2;
    _frequencyController.text = preset.frequencyMHz.toStringAsFixed(3);
    _bandwidth = preset.bandwidth;
    _spreadingFactor = preset.spreadingFactor;
    _codingRate = preset.codingRate;
    // A preset's power may be above what this radio can do (some boards top
    // out below 22 dBm): use the radio's maximum instead.
    final maxTxPower = widget.connector.maxTxPower;
    final txPower = maxTxPower != null && preset.txPowerDbm > maxTxPower
        ? maxTxPower
        : preset.txPowerDbm;
    _txPowerController.text = txPower.toString();
    _selectedPresetIndex = index;
    // Programmatic writes skip TextField.onChanged, so clear any stale
    // frequency/TX errors here or Save stays disabled.
    _validateFields();
  }

  void _syncPresetSelection() {
    final previous = _selectedPresetIndex;
    _selectedPresetIndex = _findMatchingPresetIndex();
    if (previous != _selectedPresetIndex) {
      _logRadioSettingsState(
        'Preset match ${_presetLabel(previous)} -> ${_presetLabel(_selectedPresetIndex)}',
      );
    }
  }

  void _handleManualSettingsChanged(String source) {
    _logRadioSettingsState('Manual settings edit: $source');
    setState(() {
      _validateFields();
      _syncPresetSelection();
    });
  }

  void _validateFields() {
    final l10n = context.l10n;
    final freqMHz = double.tryParse(_frequencyController.text);
    _frequencyError = (freqMHz == null || freqMHz < 150 || freqMHz > 2500)
        ? l10n.settings_frequencyInvalid
        : null;

    final maxTxPower = widget.connector.maxTxPower ?? 22;
    final txPower = int.tryParse(_txPowerController.text);
    _txPowerError =
        (txPower == null || txPower < _minTxPowerDbm || txPower > maxTxPower)
        ? l10n.settings_txPowerInvalidRange(_minTxPowerDbm, maxTxPower)
        : null;
  }

  /// Turning off-grid repeat on or off leaves the frequency alone.
  void _handleClientRepeatChanged(bool enabled) {
    setState(() => _clientRepeat = enabled);
    _logRadioSettingsState('Off-grid repeat toggled');
  }

  /// The radio refused off-grid repeat on [freqKHz]: say which frequencies
  /// its firmware allows and offer the nearest one.
  Future<void> _offerAllowedRepeatFrequency(int freqKHz) async {
    final l10n = context.l10n;
    final nearestKHz = _nearestAllowedRepeatFreqKHz(widget.connector, freqKHz);
    final use = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.settings_clientRepeat),
        content: Text(
          l10n.settings_clientRepeatRefused(
            _mhz(freqKHz),
            _allowedRepeatFreqList(widget.connector),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.settings_clientRepeatUseFreq(_mhz(nearestKHz))),
          ),
        ],
      ),
    );
    if (use != true || !mounted) return;
    setState(() {
      _frequencyController.text = _mhz(nearestKHz);
      _validateFields();
      _syncPresetSelection();
    });
  }

  Future<void> _saveSettings() async {
    final l10n = context.l10n;
    final freqMHz = double.tryParse(_frequencyController.text);
    final txPower = int.tryParse(_txPowerController.text);

    if (freqMHz == null || freqMHz < 150 || freqMHz > 2500) {
      showDismissibleSnackBar(
        context,
        content: Text(l10n.settings_frequencyInvalid),
      );
      return;
    }

    final maxTxPower = widget.connector.maxTxPower ?? 22;
    if (txPower == null || txPower < _minTxPowerDbm || txPower > maxTxPower) {
      showDismissibleSnackBar(
        context,
        content: Text(
          l10n.settings_txPowerInvalidRange(_minTxPowerDbm, maxTxPower),
        ),
      );
      return;
    }

    final freqHz = (freqMHz * 1000).round();
    final bwHz = _bandwidth.hz;
    final sf = _spreadingFactor.value;
    final cr = _codingRate.value;

    // if the client repeat isnt null then we know its supported
    //otherwise we leave it out of the frame to avoid accidentally enabling
    final knownRepeat = widget.connector.clientRepeat != null;

    try {
      _logRadioSettingsState('Saving radio settings');
      final accepted = await widget.connector.setRadioParams(
        freqHz,
        bwHz,
        sf,
        cr,
        clientRepeat: knownRepeat ? _clientRepeat : null,
      );
      if (!accepted) {
        _logRadioSettingsState('Radio rejected requested settings');
        if (!mounted) return;
        // Repeat is sent on any frequency; firmware that only allows it on
        // some refuses the rest. Explain and offer an allowed one.
        if (knownRepeat &&
            _clientRepeat &&
            !_isAllowedRepeatFreqKHz(widget.connector, freqHz)) {
          await _offerAllowedRepeatFrequency(freqHz);
          return;
        }
        showDismissibleSnackBar(
          context,
          content: Text(l10n.settings_radioSettingsNotApplied),
        );
        return;
      }
      await widget.connector.sendFrame(buildSetRadioTxPowerFrame(txPower));
      final selfInfo = widget.connector.receivedFrames
          .firstWhere((f) => f.isNotEmpty && f[0] == respCodeSelfInfo)
          .timeout(const Duration(seconds: 5));
      await widget.connector.refreshDeviceInfo();
      final applied = await selfInfo.then(
        (_) => _deviceMatches(
          freqHz: freqHz,
          bwHz: bwHz,
          sf: sf,
          cr: cr,
          txPower: txPower,
          clientRepeat: knownRepeat ? _clientRepeat : null,
        ),
        onError: (_) => true,
      );
      if (!applied) {
        _logRadioSettingsState('Radio did not apply requested settings');
        if (!mounted) return;
        showDismissibleSnackBar(
          context,
          content: Text(l10n.settings_radioSettingsNotApplied),
        );
        return;
      }

      if (!mounted) return;
      _logRadioSettingsState('Radio settings saved successfully');
      showDismissibleSnackBar(
        context,
        content: Text(l10n.settings_radioSettingsUpdated),
      );
      Navigator.pop(context);
    } catch (e) {
      _appLog.warn('Radio settings save failed: $e', tag: 'RadioSettings');
      if (!mounted) return;
      // Keep the dialog open, like the rejected/not-applied paths, so the
      // user's edits survive a transient failure and can be retried.
      showDismissibleSnackBar(
        context,
        content: Text(l10n.settings_error(e.toString())),
      );
    }
  }

  bool _deviceMatches({
    required int freqHz,
    required int bwHz,
    required int sf,
    required int cr,
    required int txPower,
    required bool? clientRepeat,
  }) {
    final c = widget.connector;
    // Firmware stores freq/bw as float MHz/kHz, so allow 1 unit of rounding.
    return c.currentFreqHz != null &&
        (c.currentFreqHz! - freqHz).abs() <= 1 &&
        c.currentBwHz != null &&
        (c.currentBwHz! - bwHz).abs() <= 1 &&
        c.currentSf == sf &&
        c.currentCr != null &&
        _toUiCodingRate(c.currentCr!) == cr &&
        c.currentTxPower == txPower &&
        (clientRepeat == null || c.clientRepeat == clientRepeat);
  }

  String _presetLabel(int? index) {
    if (index == null) {
      return 'custom';
    }
    return '${RadioSettings.presets[index].$1} (#$index)';
  }

  void _logRadioSettingsState(String message) {
    if (!kDebugMode) return;
    _appLog.info(
      '$message | '
      'freq=${_frequencyController.text}MHz '
      'bw=${_bandwidth.label} '
      'sf=${_spreadingFactor.label} '
      'cr=${_codingRate.label} '
      'tx=${_txPowerController.text}dBm '
      'repeat=$_clientRepeat '
      'preset=${_presetLabel(_selectedPresetIndex)}',
      tag: 'RadioSettings',
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.settings_radioSettings),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<int>(
              key: ValueKey<int?>(_selectedPresetIndex),
              initialValue: _selectedPresetIndex ?? -1,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.settings_presets,
                border: const OutlineInputBorder(),
              ),
              items: [
                if (_selectedPresetIndex == null)
                  DropdownMenuItem(
                    value: -1,
                    child: Text(l10n.settings_presetCustom),
                  ),
                for (final i in _visiblePresetIndexes())
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      RadioSettings.presets[i].$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (index) {
                if (index != null && index >= 0) {
                  _applyPreset(index);
                }
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _frequencyController,
              onChanged: (_) => _handleManualSettingsChanged('frequency'),
              decoration: InputDecoration(
                labelText: l10n.settings_frequency,
                border: const OutlineInputBorder(),
                helperText: _clientRepeat
                    ? l10n.settings_clientRepeatFrequencyNote(
                        _frequencyController.text,
                      )
                    : l10n.settings_frequencyHelper,
                errorText: _frequencyError,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<LoRaBandwidth>(
              initialValue: _bandwidth,
              decoration: InputDecoration(
                labelText: l10n.settings_bandwidth,
                border: const OutlineInputBorder(),
              ),
              items: LoRaBandwidth.values
                  .map(
                    (bw) => DropdownMenuItem(value: bw, child: Text(bw.label)),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _bandwidth = value;
                    _syncPresetSelection();
                  });
                  _logRadioSettingsState('Manual settings edit: bandwidth');
                }
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<LoRaSpreadingFactor>(
              initialValue: _spreadingFactor,
              decoration: InputDecoration(
                labelText: l10n.settings_spreadingFactor,
                border: const OutlineInputBorder(),
              ),
              items: LoRaSpreadingFactor.values
                  .map(
                    (sf) => DropdownMenuItem(value: sf, child: Text(sf.label)),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _spreadingFactor = value;
                    _syncPresetSelection();
                  });
                  _logRadioSettingsState(
                    'Manual settings edit: spreading factor',
                  );
                }
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<LoRaCodingRate>(
              initialValue: _codingRate,
              decoration: InputDecoration(
                labelText: l10n.settings_codingRate,
                border: const OutlineInputBorder(),
              ),
              items: LoRaCodingRate.values
                  .map(
                    (cr) => DropdownMenuItem(value: cr, child: Text(cr.label)),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _codingRate = value;
                    _syncPresetSelection();
                  });
                  _logRadioSettingsState('Manual settings edit: coding rate');
                }
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _txPowerController,
              onChanged: (_) => _handleManualSettingsChanged('tx power'),
              decoration: InputDecoration(
                labelText: l10n.settings_txPower,
                border: const OutlineInputBorder(),
                helperText: l10n.settings_txPowerRangeHelper(
                  _minTxPowerDbm,
                  widget.connector.maxTxPower ?? 22,
                ),
                errorText: _txPowerError,
              ),
              keyboardType: TextInputType.number,
            ),
            if (widget.connector.clientRepeat != null) ...[
              const SizedBox(height: 16),
              SwitchListTile(
                title: Text(l10n.settings_clientRepeat),
                subtitle: Text(l10n.settings_clientRepeatSubtitle),
                value: _clientRepeat,
                onChanged: _handleClientRepeatChanged,
                contentPadding: EdgeInsets.zero,
              ),
            ],
            const SizedBox(height: 16),
            Text(
              l10n.settings_radioMatchWarning,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: (_frequencyError != null || _txPowerError != null)
              ? null
              : _saveSettings,
          child: Text(l10n.common_save),
        ),
      ],
    );
  }
}

class _RadioSettingsSnapshot {
  final double frequencyMHz;
  final LoRaBandwidth bandwidth;
  final LoRaSpreadingFactor spreadingFactor;
  final LoRaCodingRate codingRate;
  final int txPowerDbm;

  const _RadioSettingsSnapshot({
    required this.frequencyMHz,
    required this.bandwidth,
    required this.spreadingFactor,
    required this.codingRate,
    required this.txPowerDbm,
  });

  /// Frequency in integer kHz — avoids floating-point comparison issues.
  int get frequencyHz => (frequencyMHz * 1000).round();
}
