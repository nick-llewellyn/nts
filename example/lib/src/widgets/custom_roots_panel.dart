// Panel shown below the ActionPanel when TrustMode.custom is active.
//
// Lets the user supply a PEM or DER root certificate either by pasting
// text directly into a TextField or by loading a file from disk via the
// system file picker. Once the bytes are applied they are written into
// [AppState.customRoots], which causes [NtsController] to re-mint its
// client so the new roots take effect on the next handshake.
//
// When any other TrustMode is active the panel renders a zero-size
// [SizedBox] so it contributes no layout space.

import 'dart:typed_data' show Uint8List;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:nts/nts.dart' show TrustMode;
import 'package:signals/signals_flutter.dart' show SignalBuilder;

import '../state/app_state.dart';

class CustomRootsPanel extends StatefulWidget {
  const CustomRootsPanel({super.key, required this.state});

  final AppState state;

  @override
  State<CustomRootsPanel> createState() => _CustomRootsPanelState();
}

/// Stateless body of [CustomRootsPanel]. Accepts all mutable inputs as
/// parameters so the outer [State] object owns the lifecycle, keeping
/// this widget itself stateless and therefore trivially testable.
class _CustomRootsPanelBody extends StatelessWidget {
  const _CustomRootsPanelBody({
    required this.controller,
    required this.validationError,
    required this.statusLabel,
    required this.onApply,
    required this.onPickFile,
    required this.onClear,
  });

  final TextEditingController controller;
  final String? validationError;
  final String? statusLabel;
  final VoidCallback onApply;
  final VoidCallback onPickFile;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('custom_roots_text_field'),
            controller: controller,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'Paste PEM certificate(s) here…',
              errorText: validationError,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.icon(
                key: const Key('custom_roots_apply_button'),
                onPressed: onApply,
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Apply'),
              ),
              OutlinedButton.icon(
                key: const Key('custom_roots_load_file_button'),
                onPressed: onPickFile,
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Load file…'),
              ),
              OutlinedButton.icon(
                key: const Key('custom_roots_clear_button'),
                onPressed: onClear,
                icon: const Icon(Icons.clear, size: 16),
                label: const Text('Clear'),
              ),
              if (statusLabel != null)
                Chip(
                  key: const Key('custom_roots_status_chip'),
                  avatar: const Icon(Icons.verified, size: 16),
                  label: Text(statusLabel!),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CustomRootsPanelState extends State<CustomRootsPanel> {
  final _controller = TextEditingController();
  String? _validationError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _applyPem() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _validationError = 'Paste a PEM certificate first.');
      return;
    }
    final bytes = Uint8List.fromList(text.codeUnits);
    widget.state.customRoots.value = bytes;
    widget.state.customRootsLabel.value = 'pasted PEM';
    setState(() => _validationError = null);
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;
    widget.state.customRoots.value = Uint8List.fromList(bytes);
    widget.state.customRootsLabel.value = file.name;
    setState(() => _validationError = null);
  }

  void _clear() {
    _controller.clear();
    widget.state.customRoots.value = null;
    widget.state.customRootsLabel.value = '';
    setState(() => _validationError = null);
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        if (widget.state.trustMode.value != TrustMode.custom) {
          return const SizedBox.shrink();
        }
        final label = widget.state.customRootsLabel.value;
        return _CustomRootsPanelBody(
          controller: _controller,
          validationError: _validationError,
          statusLabel: label.isEmpty ? null : label,
          onApply: _applyPem,
          onPickFile: _pickFile,
          onClear: _clear,
        );
      },
    );
  }
}
