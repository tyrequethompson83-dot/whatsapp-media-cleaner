import 'dart:async';
import 'dart:io';

import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/scan_service.dart';
import 'review_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ScanService _scanService = ScanService();
  final DateFormat _timestampFormat = DateFormat('MMM d, yyyy h:mm a');
  final NumberFormat _countFormat = NumberFormat.decimalPattern();

  StreamSubscription<ScanProgress>? _progressSubscription;
  bool _isScanning = false;
  ScanProgress? _progress;
  ScanResult? _result;
  String? _errorMessage;
  String _storagePath = '/storage/emulated/0';
  PermissionStatus _permissionStatus = PermissionStatus.denied;

  @override
  void initState() {
    super.initState();
    _loadStoragePath();
    _refreshPermissionStatus();
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadStoragePath() async {
    try {
      final externalDir = await getExternalStorageDirectory();
      if (externalDir == null) {
        return;
      }

      final normalized = externalDir.path.replaceAll('\\', '/');
      final primaryRoot = normalized.split('/Android/').first;
      if (!mounted || primaryRoot.isEmpty) {
        return;
      }

      setState(() {
        _storagePath = primaryRoot;
      });
    } catch (_) {
      // Keep fallback path when app-specific external path cannot be resolved.
    }
  }

  Future<void> _refreshPermissionStatus() async {
    PermissionStatus status = await Permission.manageExternalStorage.status;
    if (!status.isGranted) {
      final fallback = await Permission.storage.status;
      if (fallback.isGranted) {
        status = fallback;
      }
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _permissionStatus = status;
    });
  }

  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) {
      return true;
    }

    PermissionStatus manageStatus = await Permission.manageExternalStorage.status;
    if (manageStatus.isGranted) {
      return true;
    }

    manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) {
      return true;
    }

    final storageStatus = await Permission.storage.request();
    if (storageStatus.isGranted) {
      return true;
    }

    if (manageStatus.isPermanentlyDenied || storageStatus.isPermanentlyDenied) {
      await openAppSettings();
    }
    return false;
  }

  Future<void> _scanMedia() async {
    if (_isScanning) {
      return;
    }

    setState(() {
      _isScanning = true;
      _errorMessage = null;
      _progress = const ScanProgress(
        phase: ScanPhase.idle,
        processed: 0,
        total: 0,
        message: 'Preparing scan...',
        overallProgress: 0,
      );
    });

    final granted = await _ensurePermission();
    await _refreshPermissionStatus();
    if (!granted) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isScanning = false;
        _progress = const ScanProgress(
          phase: ScanPhase.failed,
          processed: 0,
          total: 0,
          message: 'Storage permission is required to scan WhatsApp media.',
          overallProgress: 0,
        );
        _errorMessage = 'Storage permission is required to scan WhatsApp media.';
      });
      return;
    }

    try {
      await _progressSubscription?.cancel();
      final session = _scanService.startScan();
      _progressSubscription = session.progress.listen((progress) {
        if (!mounted) {
          return;
        }
        setState(() {
          _progress = progress;
        });
      });

      final result = await session.result;
      await _progressSubscription?.cancel();
      _progressSubscription = null;

      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
        _isScanning = false;
      });

      if (!mounted || result.duplicateGroups.isEmpty) {
        return;
      }

      final didDelete = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (context) => ReviewScreen(
            initialResult: result,
            scanService: _scanService,
          ),
        ),
      );

      if (!mounted || didDelete != true) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Files deleted. Run scan again to refresh exact totals.'),
        ),
      );
    } catch (error) {
      await _progressSubscription?.cancel();
      _progressSubscription = null;

      if (!mounted) {
        return;
      }
      setState(() {
        _isScanning = false;
        _errorMessage = 'Scan failed: $error';
        _progress = ScanProgress(
          phase: ScanPhase.failed,
          processed: 0,
          total: 0,
          message: 'Scan failed.',
          overallProgress: 0,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final beforeBytes = result?.totalBytes ?? 0;
    final reclaimable = result?.reclaimableBytes ?? 0;
    final afterBytes = beforeBytes - reclaimable;

    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp Media Cleaner'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildStorageCard(
              beforeBytes: beforeBytes,
              afterBytes: afterBytes,
              reclaimableBytes: reclaimable,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _isScanning ? null : _scanMedia,
              icon: _isScanning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_rounded),
              label: Text(
                _isScanning ? 'Scanning WhatsApp Media...' : 'Scan WhatsApp Media',
              ),
            ),
            if (_progress != null) ...[
              const SizedBox(height: 12),
              _buildProgressCard(_progress!),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              _buildErrorCard(_errorMessage!),
            ],
            if (result != null) ...[
              const SizedBox(height: 12),
              _buildQuickStatsCard(result),
              const SizedBox(height: 12),
              _buildTypeBreakdownCard(result),
              const SizedBox(height: 12),
              _buildFolderBreakdownCard(result),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStorageCard({
    required int beforeBytes,
    required int afterBytes,
    required int reclaimableBytes,
  }) {
    final permissionLabel = _permissionStatus.isGranted ? 'Granted' : 'Required';
    final permissionColor = _permissionStatus.isGranted ? Colors.green : Colors.orange;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Device Storage Snapshot',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              _storagePath,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Chip(
              avatar: Icon(Icons.shield_rounded, size: 18, color: permissionColor),
              label: Text('Storage permission: $permissionLabel'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _metricTile(label: 'Before', value: _formatBytes(beforeBytes))),
                const SizedBox(width: 8),
                Expanded(child: _metricTile(label: 'After', value: _formatBytes(afterBytes))),
                const SizedBox(width: 8),
                Expanded(
                  child: _metricTile(
                    label: 'Potential Saved',
                    value: _formatBytes(reclaimableBytes),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricTile({required String label, required String value}) {
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

  Widget _buildProgressCard(ScanProgress progress) {
    final progressCount = progress.total > 0
        ? '${_countFormat.format(progress.processed)} / ${_countFormat.format(progress.total)}'
        : '${_countFormat.format(progress.processed)} items';
    final progressText = '${progress.percentLabel}  -  $progressCount';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(progress.message, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress.fraction),
            const SizedBox(height: 8),
            Text(progressText, style: Theme.of(context).textTheme.bodySmall),
            if (progress.currentPath != null && progress.currentPath!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                _shortenPath(progress.currentPath!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQuickStatsCard(ScanResult result) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Quick Stats', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chipStat('Files', _countFormat.format(result.files.length)),
                _chipStat(
                  'Duplicate Groups',
                  _countFormat.format(result.duplicateGroups.length),
                ),
                _chipStat('Potential Savings', _formatBytes(result.reclaimableBytes)),
                _chipStat('Sent', _formatBytes(result.sentBytes)),
                _chipStat('Received', _formatBytes(result.receivedBytes)),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Last scan: ${_timestampFormat.format(result.completedAt)} (${result.duration.inSeconds}s)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _chipStat(String label, String value) {
    return Chip(
      label: Text('$label: $value'),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildTypeBreakdownCard(ScanResult result) {
    final entries = result.bytesByCategory.entries
        .where((entry) => entry.value > 0)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('By Media Type', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (entries.isEmpty)
              const Text('No media files found in scanned folders.')
            else
              ...entries.map((entry) {
                final count = result.countByCategory[entry.key] ?? 0;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(entry.key.label),
                  subtitle: Text('${_countFormat.format(count)} files'),
                  trailing: Text(_formatBytes(entry.value)),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderBreakdownCard(ScanResult result) {
    final folders = result.sortedFolderSummaries;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('By Folder', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (folders.isEmpty)
              const Text('No folder breakdown available.')
            else
              ...folders.map((summary) {
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('${summary.appVariant} - ${summary.folderName}'),
                  subtitle: Text('${_countFormat.format(summary.fileCount)} files'),
                  trailing: Text(_formatBytes(summary.totalBytes)),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard(String message) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          message,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) {
      return '0 B';
    }
    return filesize(bytes);
  }

  String _shortenPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    if (normalized.length <= 64) {
      return normalized;
    }
    return '...${normalized.substring(normalized.length - 61)}';
  }
}

