import 'dart:io';

import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/scan_service.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.initialResult,
    required this.scanService,
  });

  final ScanResult initialResult;
  final ScanService scanService;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  final DateFormat _dateFormat = DateFormat('MMM d, yyyy h:mm a');
  final NumberFormat _countFormat = NumberFormat.decimalPattern();

  late List<DuplicateGroup> _groups;
  final Map<String, Set<String>> _selectedByGroup = <String, Set<String>>{};

  bool _isDeleting = false;
  bool _didDelete = false;
  int _deletedBytes = 0;
  DeleteProgress? _deleteProgress;

  @override
  void initState() {
    super.initState();
    _groups = widget.initialResult.duplicateGroups.toList(growable: true);

    // Default to "safe cleanup": select duplicates except the best candidate.
    for (final group in _groups) {
      _selectedByGroup[group.fingerprint] = _defaultSelection(group);
    }
  }

  Set<String> _defaultSelection(DuplicateGroup group) {
    final selected = <String>{};
    for (final file in group.files) {
      if (file.path != group.keepBest.path) {
        selected.add(file.path);
      }
    }
    return selected;
  }

  List<MediaFileRecord> _selectedFilesForGroup(DuplicateGroup group) {
    final selectedPaths = _selectedByGroup[group.fingerprint] ?? <String>{};
    return group.files.where((file) => selectedPaths.contains(file.path)).toList();
  }

  List<MediaFileRecord> get _allSelectedFiles {
    final selected = <MediaFileRecord>[];
    final seenPaths = <String>{};
    for (final group in _groups) {
      final groupSelected = _selectedFilesForGroup(group);
      for (final file in groupSelected) {
        if (seenPaths.add(file.path)) {
          selected.add(file);
        }
      }
    }
    return selected;
  }

  int get _selectedBytes {
    return _allSelectedFiles.fold<int>(0, (sum, file) => sum + file.sizeBytes);
  }

  int get _currentTotalBytes {
    final value = widget.initialResult.totalBytes - _deletedBytes;
    return value < 0 ? 0 : value;
  }

  Future<void> _keepBestForGroup(DuplicateGroup group) async {
    setState(() {
      _selectedByGroup[group.fingerprint] = _defaultSelection(group);
    });
  }

  Future<void> _toggleSelection({
    required DuplicateGroup group,
    required MediaFileRecord file,
    required bool selected,
  }) async {
    final current = Set<String>.from(_selectedByGroup[group.fingerprint] ?? <String>{});
    if (selected) {
      current.add(file.path);
    } else {
      current.remove(file.path);
    }

    setState(() {
      _selectedByGroup[group.fingerprint] = current;
    });
  }

  Future<bool> _confirmDelete({
    required int fileCount,
    required int totalBytes,
  }) async {
    return (await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text('Delete ${_countFormat.format(fileCount)} files?'),
              content: Text(
                'You are about to delete ${_countFormat.format(fileCount)} files '
                '(${_formatBytes(totalBytes)}).\n\n'
                'This cannot be undone easily.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        )) ??
        false;
  }

  Future<void> _deleteForGroup(DuplicateGroup group) async {
    if (_isDeleting) {
      return;
    }

    final selected = _selectedFilesForGroup(group);
    if (selected.isEmpty) {
      return;
    }

    final totalBytes = selected.fold<int>(0, (sum, file) => sum + file.sizeBytes);
    final confirmed = await _confirmDelete(
      fileCount: selected.length,
      totalBytes: totalBytes,
    );
    if (!confirmed) {
      return;
    }

    await _runDelete(selected);
  }

  Future<void> _deleteAllSelected() async {
    if (_isDeleting) {
      return;
    }

    final selected = _allSelectedFiles;
    if (selected.isEmpty) {
      return;
    }

    final totalBytes = selected.fold<int>(0, (sum, file) => sum + file.sizeBytes);
    final confirmed = await _confirmDelete(
      fileCount: selected.length,
      totalBytes: totalBytes,
    );
    if (!confirmed) {
      return;
    }

    await _runDelete(selected);
  }

  Future<void> _runDelete(List<MediaFileRecord> selectedFiles) async {
    setState(() {
      _isDeleting = true;
      _deleteProgress = const DeleteProgress(processed: 0, total: 0);
    });

    final result = await widget.scanService.deleteFiles(
      selectedFiles,
      onProgress: (progress) {
        if (!mounted) {
          return;
        }
        setState(() {
          _deleteProgress = progress;
        });
      },
    );

    if (!mounted) {
      return;
    }

    final removedPaths = result.deletedPaths.toSet();
    _applyDeletedPaths(removedPaths);

    setState(() {
      _isDeleting = false;
      _didDelete = _didDelete || result.deletedCount > 0;
      _deletedBytes += result.deletedBytes;
      _deleteProgress = null;
    });

    final failed = result.failures.length;
    final summary = failed == 0
        ? 'Deleted ${_countFormat.format(result.deletedCount)} files '
            '(${_formatBytes(result.deletedBytes)}).'
        : 'Deleted ${_countFormat.format(result.deletedCount)} files with '
            '${_countFormat.format(failed)} failures.';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(summary)),
    );
  }

  void _applyDeletedPaths(Set<String> removedPaths) {
    final updatedGroups = <DuplicateGroup>[];
    final updatedSelection = <String, Set<String>>{};

    for (final group in _groups) {
      final remaining = group.files.where((file) => !removedPaths.contains(file.path)).toList();
      if (remaining.length < 2) {
        continue;
      }

      final rebuiltGroup = DuplicateGroup(
        fingerprint: group.fingerprint,
        files: remaining,
      );
      updatedGroups.add(rebuiltGroup);

      final previous = _selectedByGroup[group.fingerprint] ?? <String>{};
      final next = previous.where((path) => !removedPaths.contains(path)).toSet();
      if (next.isEmpty) {
        next.addAll(_defaultSelection(rebuiltGroup));
      }
      updatedSelection[rebuiltGroup.fingerprint] = next;
    }

    setState(() {
      _groups = updatedGroups;
      _selectedByGroup
        ..clear()
        ..addAll(updatedSelection);
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedFiles = _allSelectedFiles;
    final selectedCount = selectedFiles.length;
    final selectedBytes = _selectedBytes;
    final estimatedAfter = (_currentTotalBytes - selectedBytes).clamp(0, _currentTotalBytes);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Duplicates'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(_didDelete),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isDeleting && _deleteProgress != null) ...[
                LinearProgressIndicator(value: _deleteProgress!.fraction),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_countFormat.format(selectedCount)} selected  -  ${_formatBytes(selectedBytes)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _isDeleting || selectedCount == 0 ? null : _deleteAllSelected,
                    icon: const Icon(Icons.delete_forever_rounded),
                    label: const Text('Delete Selected'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildTopSummary(
            selectedBytes: selectedBytes,
            estimatedAfter: estimatedAfter,
          ),
          const SizedBox(height: 12),
          if (_groups.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No duplicate groups remaining.'),
              ),
            )
          else
            ...List<Widget>.generate(
              _groups.length,
              (index) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildGroupCard(index, _groups[index]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTopSummary({
    required int selectedBytes,
    required int estimatedAfter,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Potential Storage Saved: ${_formatBytes(selectedBytes)}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _metricTile(
                    label: 'Before',
                    value: _formatBytes(_currentTotalBytes),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _metricTile(
                    label: 'After',
                    value: _formatBytes(estimatedAfter),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _metricTile(
                    label: 'Duplicate Groups',
                    value: _countFormat.format(_groups.length),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricTile({
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ],
      ),
    );
  }

  Widget _buildGroupCard(int index, DuplicateGroup group) {
    final selectedForGroup = _selectedFilesForGroup(group);
    final selectedBytes = selectedForGroup.fold<int>(0, (sum, file) => sum + file.sizeBytes);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Group ${index + 1}  -  ${group.files.length} files',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  _formatBytes(group.totalBytes),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Selected: ${_countFormat.format(selectedForGroup.length)} files '
              '(${_formatBytes(selectedBytes)})',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _isDeleting ? null : () => _keepBestForGroup(group),
                  icon: const Icon(Icons.auto_fix_high_rounded),
                  label: const Text('Keep Best'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _isDeleting || selectedForGroup.isEmpty
                      ? null
                      : () => _deleteForGroup(group),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Delete Selected'),
                ),
              ],
            ),
            const Divider(height: 20),
            ...group.files.map((file) => _buildFileTile(group, file)),
          ],
        ),
      ),
    );
  }

  Widget _buildFileTile(DuplicateGroup group, MediaFileRecord file) {
    final selectedPaths = _selectedByGroup[group.fingerprint] ?? <String>{};
    final isSelected = selectedPaths.contains(file.path);
    final isBest = file.path == group.keepBest.path;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPreview(file),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  '${_formatBytes(file.sizeBytes)}  -  ${_dateFormat.format(file.modifiedAt)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  '${file.appVariant}  -  ${file.relativeFolder.isEmpty ? 'Root' : file.relativeFolder}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (isBest)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Chip(
                      label: const Text('Best Candidate'),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                    ),
                  ),
              ],
            ),
          ),
          Checkbox(
            value: isSelected,
            onChanged: _isDeleting
                ? null
                : (value) => _toggleSelection(
                      group: group,
                      file: file,
                      selected: value ?? false,
                    ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(MediaFileRecord file) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;

    if (file.isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(file.path),
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return _fallbackPreview(icon: Icons.image_not_supported_outlined, color: color);
          },
        ),
      );
    }

    if (file.isVideo) {
      return _fallbackPreview(icon: Icons.videocam_outlined, color: color);
    }

    switch (file.category) {
      case MediaCategory.documents:
        return _fallbackPreview(icon: Icons.description_outlined, color: color);
      case MediaCategory.audio:
      case MediaCategory.voiceNotes:
        return _fallbackPreview(icon: Icons.graphic_eq_rounded, color: color);
      case MediaCategory.statuses:
        return _fallbackPreview(icon: Icons.history_toggle_off_rounded, color: color);
      case MediaCategory.stickers:
        return _fallbackPreview(icon: Icons.emoji_emotions_outlined, color: color);
      case MediaCategory.gifs:
        return _fallbackPreview(icon: Icons.gif_box_outlined, color: color);
      case MediaCategory.images:
      case MediaCategory.videos:
      case MediaCategory.others:
        return _fallbackPreview(icon: Icons.insert_drive_file_outlined, color: color);
    }
  }

  Widget _fallbackPreview({
    required IconData icon,
    required Color color,
  }) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) {
      return '0 B';
    }
    return filesize(bytes);
  }
}

