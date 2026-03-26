import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

Future<Map<String, String?>> _hashChunkInIsolate(List<String> filePaths) async {
  final hashes = <String, String?>{};
  for (final path in filePaths) {
    try {
      final digest = await md5.bind(File(path).openRead()).first;
      hashes[path] = digest.toString();
    } catch (_) {
      hashes[path] = null;
    }
  }
  return hashes;
}

enum ScanPhase {
  idle,
  discovering,
  indexing,
  hashing,
  finalizing,
  completed,
  failed,
}

enum MediaCategory {
  images,
  videos,
  documents,
  audio,
  voiceNotes,
  statuses,
  stickers,
  gifs,
  others,
}

extension MediaCategoryX on MediaCategory {
  String get label {
    switch (this) {
      case MediaCategory.images:
        return 'Images';
      case MediaCategory.videos:
        return 'Videos';
      case MediaCategory.documents:
        return 'Documents';
      case MediaCategory.audio:
        return 'Audio';
      case MediaCategory.voiceNotes:
        return 'Voice Notes';
      case MediaCategory.statuses:
        return 'Status';
      case MediaCategory.stickers:
        return 'Stickers';
      case MediaCategory.gifs:
        return 'GIFs';
      case MediaCategory.others:
        return 'Other Files';
    }
  }
}

class ScanProgress {
  const ScanProgress({
    required this.phase,
    required this.processed,
    required this.total,
    required this.message,
    required this.overallProgress,
    this.currentPath,
  });

  final ScanPhase phase;
  final int processed;
  final int total;
  final String message;
  final double overallProgress;
  final String? currentPath;

  double get fraction {
    if (overallProgress < 0) {
      return 0;
    }
    if (overallProgress > 1) {
      return 1;
    }
    return overallProgress;
  }

  String get percentLabel => '${(fraction * 100).toStringAsFixed(0)}%';
}

class MediaFileRecord {
  const MediaFileRecord({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.appVariant,
    required this.relativeFolder,
    required this.category,
    required this.isSent,
  });

  final String path;
  final String name;
  final int sizeBytes;
  final DateTime modifiedAt;
  final String appVariant;
  final String relativeFolder;
  final MediaCategory category;
  final bool isSent;

  bool get isImage {
    final lower = name.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif');
  }

  bool get isVideo {
    final lower = name.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.3gp') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.webm');
  }

  bool get isPreviewable => isImage || isVideo;
}

class FolderSummary {
  FolderSummary({
    required this.appVariant,
    required this.folderName,
  });

  final String appVariant;
  final String folderName;
  int fileCount = 0;
  int totalBytes = 0;
}

class DuplicateGroup {
  DuplicateGroup({
    required this.fingerprint,
    required List<MediaFileRecord> files,
  })  : files = List<MediaFileRecord>.unmodifiable(files),
        keepBest = _pickBest(files);

  final String fingerprint;
  final List<MediaFileRecord> files;
  final MediaFileRecord keepBest;

  int get totalBytes => files.fold<int>(0, (sum, file) => sum + file.sizeBytes);

  int get reclaimableBytes => totalBytes - keepBest.sizeBytes;

  static MediaFileRecord _pickBest(List<MediaFileRecord> files) {
    final sorted = files.toList()
      ..sort((a, b) {
        final bySize = b.sizeBytes.compareTo(a.sizeBytes);
        if (bySize != 0) {
          return bySize;
        }
        return b.modifiedAt.compareTo(a.modifiedAt);
      });
    return sorted.first;
  }
}

class ScanResult {
  ScanResult({
    required this.startedAt,
    required this.completedAt,
    required this.scannedRoots,
    required this.files,
    required this.duplicateGroups,
    required this.bytesByCategory,
    required this.countByCategory,
    required this.folderSummaries,
    required this.sentBytes,
    required this.receivedBytes,
  });

  final DateTime startedAt;
  final DateTime completedAt;
  final List<String> scannedRoots;
  final List<MediaFileRecord> files;
  final List<DuplicateGroup> duplicateGroups;
  final Map<MediaCategory, int> bytesByCategory;
  final Map<MediaCategory, int> countByCategory;
  final Map<String, FolderSummary> folderSummaries;
  final int sentBytes;
  final int receivedBytes;

  Duration get duration => completedAt.difference(startedAt);

  int get totalBytes => files.fold<int>(0, (sum, file) => sum + file.sizeBytes);

  int get reclaimableBytes {
    return duplicateGroups.fold<int>(
      0,
      (sum, group) => sum + group.reclaimableBytes,
    );
  }

  List<FolderSummary> get sortedFolderSummaries {
    final list = folderSummaries.values.toList()
      ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    return list;
  }
}

class DeleteProgress {
  const DeleteProgress({
    required this.processed,
    required this.total,
    this.currentPath,
  });

  final int processed;
  final int total;
  final String? currentPath;

  double get fraction {
    if (total <= 0) {
      return 0;
    }
    return processed / total;
  }
}

class DeleteFailure {
  const DeleteFailure({
    required this.path,
    required this.error,
  });

  final String path;
  final String error;
}

class DeleteResult {
  const DeleteResult({
    required this.requestedCount,
    required this.deletedCount,
    required this.deletedBytes,
    required this.deletedPaths,
    required this.failures,
  });

  final int requestedCount;
  final int deletedCount;
  final int deletedBytes;
  final List<String> deletedPaths;
  final List<DeleteFailure> failures;
}

class ScanSession {
  const ScanSession({
    required this.progress,
    required this.result,
  });

  final Stream<ScanProgress> progress;
  final Future<ScanResult> result;
}

class ScanService {
  static const List<String> _wellKnownRoots = <String>[
    '/storage/emulated/0/WhatsApp/Media',
    '/storage/emulated/0/WhatsApp Business/Media',
    '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media',
    '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp Business/Media',
    '/storage/emulated/0/Android/media/com.whatsapp.w4b/WhatsApp Business/Media',
    '/storage/emulated/0/Android/media/com.whatsapp.w4b/WhatsApp/Media',
    '/sdcard/WhatsApp/Media',
    '/sdcard/WhatsApp Business/Media',
    '/storage/self/primary/WhatsApp/Media',
    '/storage/self/primary/WhatsApp Business/Media',
  ];

  ScanSession startScan() {
    final controller = StreamController<ScanProgress>.broadcast();
    final resultFuture = scanWhatsAppMedia(
      onProgress: (progress) {
        if (!controller.isClosed) {
          controller.add(progress);
        }
      },
    ).whenComplete(() async {
      await controller.close();
    });

    return ScanSession(
      progress: controller.stream,
      result: resultFuture,
    );
  }

  Future<ScanResult> scanWhatsAppMedia({
    void Function(ScanProgress progress)? onProgress,
  }) async {
    final startedAt = DateTime.now();
    final roots = await _discoverMediaRoots();

    if (roots.isEmpty) {
      onProgress?.call(const ScanProgress(
        phase: ScanPhase.completed,
        processed: 0,
        total: 0,
        message: 'No WhatsApp media folders were found on this device.',
        overallProgress: 1,
      ));

      return ScanResult(
        startedAt: startedAt,
        completedAt: DateTime.now(),
        scannedRoots: const <String>[],
        files: const <MediaFileRecord>[],
        duplicateGroups: const <DuplicateGroup>[],
        bytesByCategory: {
          for (final category in MediaCategory.values) category: 0,
        },
        countByCategory: {
          for (final category in MediaCategory.values) category: 0,
        },
        folderSummaries: <String, FolderSummary>{},
        sentBytes: 0,
        receivedBytes: 0,
      );
    }

    final discoveredPaths = <String>[];
    var discoveredCount = 0;

    onProgress?.call(ScanProgress(
      phase: ScanPhase.discovering,
      processed: 0,
      total: roots.length,
      message: 'Discovering folders (10%)...',
      overallProgress: _overallFor(ScanPhase.discovering, 0),
    ));

    for (var rootIndex = 0; rootIndex < roots.length; rootIndex++) {
      final root = roots[rootIndex];
      final rootDir = Directory(root);
      var filesInRoot = 0;

      try {
        await for (final entity in rootDir.list(recursive: true, followLinks: false)) {
          if (entity is! File) {
            continue;
          }
          if (_shouldSkip(entity.path)) {
            continue;
          }

          discoveredPaths.add(entity.path);
          discoveredCount++;
          filesInRoot++;

          if (discoveredCount % 200 == 0) {
            final rootFraction =
                ((rootIndex + _withinRootDiscovery(filesInRoot)) / roots.length).clamp(0.0, 1.0);
            onProgress?.call(ScanProgress(
              phase: ScanPhase.discovering,
              processed: discoveredCount,
              total: 0,
              message: 'Discovering folders (10%)... ${_formatCount(discoveredCount)} files found',
              overallProgress: _overallFor(ScanPhase.discovering, rootFraction),
              currentPath: entity.path,
            ));
            await Future<void>.delayed(Duration.zero);
          }
        }
      } catch (_) {
        // Continue with remaining roots if one directory cannot be traversed.
      }

      final completedRoots = rootIndex + 1;
      onProgress?.call(ScanProgress(
        phase: ScanPhase.discovering,
        processed: completedRoots,
        total: roots.length,
        message: 'Discovering folders (10%)... ${_formatCount(discoveredCount)} files found',
        overallProgress: _overallFor(ScanPhase.discovering, completedRoots / roots.length),
        currentPath: root,
      ));
      await Future<void>.delayed(Duration.zero);
    }

    final files = <MediaFileRecord>[];
    final bytesByCategory = <MediaCategory, int>{
      for (final category in MediaCategory.values) category: 0,
    };
    final countByCategory = <MediaCategory, int>{
      for (final category in MediaCategory.values) category: 0,
    };
    final folderSummaries = <String, FolderSummary>{};
    var sentBytes = 0;
    var receivedBytes = 0;

    for (var index = 0; index < discoveredPaths.length; index++) {
      final path = discoveredPaths[index];
      try {
        final file = File(path);
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) {
          continue;
        }

        final root = _matchRoot(path, roots);
        final appVariant = _isBusinessRoot(root) ? 'WhatsApp Business' : 'WhatsApp';
        final relativeFolder = _relativeFolder(path, root);
        final category = _categoryFor(relativeFolder);
        final isSent = _isSent(relativeFolder);

        final record = MediaFileRecord(
          path: path,
          name: _basename(path),
          sizeBytes: stat.size,
          modifiedAt: stat.modified,
          appVariant: appVariant,
          relativeFolder: relativeFolder,
          category: category,
          isSent: isSent,
        );

        files.add(record);
        bytesByCategory[category] = (bytesByCategory[category] ?? 0) + stat.size;
        countByCategory[category] = (countByCategory[category] ?? 0) + 1;

        if (isSent) {
          sentBytes += stat.size;
        } else {
          receivedBytes += stat.size;
        }

        final topFolder = _topFolder(relativeFolder);
        final folderKey = '$appVariant|$topFolder';
        final summary = folderSummaries.putIfAbsent(
          folderKey,
          () => FolderSummary(appVariant: appVariant, folderName: topFolder),
        );
        summary.fileCount++;
        summary.totalBytes += stat.size;
      } catch (_) {
        // Keep indexing even when one file fails.
      }

      final processed = index + 1;
      if (processed % 150 == 0 || processed == discoveredPaths.length) {
        final fraction =
            discoveredPaths.isEmpty ? 1.0 : (processed / discoveredPaths.length).clamp(0.0, 1.0);
        onProgress?.call(ScanProgress(
          phase: ScanPhase.indexing,
          processed: processed,
          total: discoveredPaths.length,
          message: 'Indexing files (40%)...',
          overallProgress: _overallFor(ScanPhase.indexing, fraction),
          currentPath: path,
        ));
      }

      if (processed % 250 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    final candidates = _duplicateCandidates(files);
    final groups = <DuplicateGroup>[];

    if (candidates.isNotEmpty) {
      final byHash = <String, List<MediaFileRecord>>{};
      final byFallback = <String, List<MediaFileRecord>>{};

      const chunkSize = 24;
      for (var offset = 0; offset < candidates.length; offset += chunkSize) {
        final chunk = candidates.skip(offset).take(chunkSize).toList(growable: false);
        final paths = chunk.map((file) => file.path).toList(growable: false);

        Map<String, String?> hashes;
        try {
          hashes = await compute(_hashChunkInIsolate, paths);
        } catch (_) {
          hashes = await _hashChunkInIsolate(paths);
        }

        for (final file in chunk) {
          final hash = hashes[file.path];
          if (hash != null && hash.isNotEmpty) {
            byHash.putIfAbsent(hash, () => <MediaFileRecord>[]).add(file);
          } else {
            final fallback = 'fallback:${file.sizeBytes}:${_normalizedName(file.name)}';
            byFallback.putIfAbsent(fallback, () => <MediaFileRecord>[]).add(file);
          }
        }

        final hashed = min(offset + chunk.length, candidates.length);
        final fraction = candidates.isEmpty ? 1.0 : (hashed / candidates.length).clamp(0.0, 1.0);
        onProgress?.call(ScanProgress(
          phase: ScanPhase.hashing,
          processed: hashed,
          total: candidates.length,
          message: 'Hashing duplicates (70%)...'
              ' ${_formatCount(hashed)} / ${_formatCount(candidates.length)}',
          overallProgress: _overallFor(ScanPhase.hashing, fraction),
          currentPath: chunk.isEmpty ? null : chunk.last.path,
        ));
        await Future<void>.delayed(Duration.zero);
      }

      onProgress?.call(ScanProgress(
        phase: ScanPhase.finalizing,
        processed: 0,
        total: 1,
        message: 'Finalizing duplicate groups...',
        overallProgress: _overallFor(ScanPhase.finalizing, 0.2),
      ));

      for (final entry in byHash.entries) {
        if (entry.value.length < 2) {
          continue;
        }
        groups.add(DuplicateGroup(
          fingerprint: entry.key,
          files: _rankDuplicateFiles(entry.value),
        ));
      }

      for (final entry in byFallback.entries) {
        if (entry.value.length < 2) {
          continue;
        }
        groups.add(DuplicateGroup(
          fingerprint: entry.key,
          files: _rankDuplicateFiles(entry.value),
        ));
      }
    }

    groups.sort((a, b) => b.reclaimableBytes.compareTo(a.reclaimableBytes));

    onProgress?.call(ScanProgress(
      phase: ScanPhase.completed,
      processed: files.length,
      total: files.length,
      message: 'Scan complete (100%). ${_formatCount(files.length)} files indexed.',
      overallProgress: 1,
    ));

    return ScanResult(
      startedAt: startedAt,
      completedAt: DateTime.now(),
      scannedRoots: List<String>.unmodifiable(roots),
      files: List<MediaFileRecord>.unmodifiable(files),
      duplicateGroups: List<DuplicateGroup>.unmodifiable(groups),
      bytesByCategory: Map<MediaCategory, int>.unmodifiable(bytesByCategory),
      countByCategory: Map<MediaCategory, int>.unmodifiable(countByCategory),
      folderSummaries: Map<String, FolderSummary>.unmodifiable(folderSummaries),
      sentBytes: sentBytes,
      receivedBytes: receivedBytes,
    );
  }

  Future<DeleteResult> deleteFiles(
    List<MediaFileRecord> files, {
    void Function(DeleteProgress progress)? onProgress,
  }) async {
    final uniqueFiles = <MediaFileRecord>[];
    final seenPaths = <String>{};

    for (final file in files) {
      if (seenPaths.add(file.path)) {
        uniqueFiles.add(file);
      }
    }

    final deletedPaths = <String>[];
    final failures = <DeleteFailure>[];
    var deletedBytes = 0;

    for (var index = 0; index < uniqueFiles.length; index++) {
      final target = uniqueFiles[index];
      try {
        final ioFile = File(target.path);
        if (await ioFile.exists()) {
          await ioFile.delete();
          deletedBytes += target.sizeBytes;
        }
        deletedPaths.add(target.path);
      } catch (error) {
        failures.add(DeleteFailure(
          path: target.path,
          error: error.toString(),
        ));
      }

      final processed = index + 1;
      onProgress?.call(DeleteProgress(
        processed: processed,
        total: uniqueFiles.length,
        currentPath: target.path,
      ));

      if (processed % 50 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    return DeleteResult(
      requestedCount: uniqueFiles.length,
      deletedCount: deletedPaths.length,
      deletedBytes: deletedBytes,
      deletedPaths: List<String>.unmodifiable(deletedPaths),
      failures: List<DeleteFailure>.unmodifiable(failures),
    );
  }

  Future<List<String>> _discoverMediaRoots() async {
    final roots = <String>{};

    for (final root in _wellKnownRoots) {
      if (await _directoryExists(root)) {
        roots.add(_normalizePath(root));
      }
    }

    roots.addAll(await _discoverFromLegacyBase('/storage/emulated/0'));
    roots.addAll(await _discoverFromLegacyBase('/storage/self/primary'));
    roots.addAll(await _discoverFromLegacyBase('/sdcard'));
    roots.addAll(await _discoverFromAndroidMediaBase('/storage/emulated/0/Android/media'));
    roots.addAll(await _discoverFromAndroidMediaBase('/storage/self/primary/Android/media'));

    final ordered = roots.toList()..sort();
    return ordered;
  }

  Future<List<String>> _discoverFromLegacyBase(String basePath) async {
    final roots = <String>[];
    final candidates = <String>[
      '$basePath/WhatsApp/Media',
      '$basePath/WhatsApp Business/Media',
      '$basePath/WhatsAppBusiness/Media',
    ];

    for (final path in candidates) {
      if (await _directoryExists(path)) {
        roots.add(_normalizePath(path));
      }
    }

    return roots;
  }

  Future<List<String>> _discoverFromAndroidMediaBase(String basePath) async {
    final roots = <String>[];
    final baseDir = Directory(basePath);

    if (!await _directoryExists(basePath)) {
      return roots;
    }

    try {
      await for (final entity in baseDir.list(followLinks: false)) {
        if (entity is! Directory) {
          continue;
        }

        final packageName = _basename(entity.path).toLowerCase();
        if (!packageName.contains('whatsapp')) {
          continue;
        }

        final mediaCandidates = <String>[
          '${entity.path}/WhatsApp/Media',
          '${entity.path}/WhatsApp Business/Media',
        ];

        for (final mediaPath in mediaCandidates) {
          if (await _directoryExists(mediaPath)) {
            roots.add(_normalizePath(mediaPath));
          }
        }
      }
    } catch (_) {
      // Ignore listing failures for this optional discovery source.
    }

    return roots;
  }

  bool _directoryPathMatchesRoot(String filePath, String rootPath) {
    final normalizedFile = _normalizePath(filePath);
    final normalizedRoot = _normalizePath(rootPath);
    return normalizedFile.startsWith(normalizedRoot);
  }

  String _matchRoot(String filePath, List<String> roots) {
    final orderedRoots = roots.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    for (final root in orderedRoots) {
      if (_directoryPathMatchesRoot(filePath, root)) {
        return root;
      }
    }
    return orderedRoots.first;
  }

  String _relativeFolder(String filePath, String rootPath) {
    final normalizedFile = _normalizePath(filePath);
    final normalizedRoot = _normalizePath(rootPath);
    if (!normalizedFile.startsWith(normalizedRoot)) {
      return '';
    }

    final relative = normalizedFile.substring(normalizedRoot.length).replaceFirst(RegExp(r'^/+'), '');
    if (relative.isEmpty) {
      return '';
    }

    final parts = relative.split('/');
    if (parts.length <= 1) {
      return '';
    }

    return parts.sublist(0, parts.length - 1).join('/');
  }

  List<MediaFileRecord> _duplicateCandidates(List<MediaFileRecord> files) {
    final bySize = <int, List<MediaFileRecord>>{};
    for (final file in files) {
      bySize.putIfAbsent(file.sizeBytes, () => <MediaFileRecord>[]).add(file);
    }

    return bySize.values
        .where((bucket) => bucket.length > 1)
        .expand((bucket) => bucket)
        .toList(growable: false);
  }

  List<MediaFileRecord> _rankDuplicateFiles(List<MediaFileRecord> files) {
    final ranked = files.toList()
      ..sort((a, b) {
        final bySize = b.sizeBytes.compareTo(a.sizeBytes);
        if (bySize != 0) {
          return bySize;
        }
        return b.modifiedAt.compareTo(a.modifiedAt);
      });
    return ranked;
  }

  MediaCategory _categoryFor(String relativeFolder) {
    final lower = relativeFolder.toLowerCase();

    if (lower.contains('voice notes')) {
      return MediaCategory.voiceNotes;
    }
    if (lower.contains('documents')) {
      return MediaCategory.documents;
    }
    if (lower.contains('status')) {
      return MediaCategory.statuses;
    }
    if (lower.contains('sticker')) {
      return MediaCategory.stickers;
    }
    if (lower.contains('gif')) {
      return MediaCategory.gifs;
    }
    if (lower.contains('video')) {
      return MediaCategory.videos;
    }
    if (lower.contains('image')) {
      return MediaCategory.images;
    }
    if (lower.contains('audio')) {
      return MediaCategory.audio;
    }

    return MediaCategory.others;
  }

  bool _isBusinessRoot(String root) {
    final lower = root.toLowerCase();
    return lower.contains('business') || lower.contains('w4b');
  }

  bool _isSent(String relativeFolder) {
    final normalized = '/${relativeFolder.toLowerCase().replaceAll('\\', '/')}/';
    return normalized.contains('/sent/');
  }

  String _topFolder(String relativeFolder) {
    if (relativeFolder.isEmpty) {
      return 'Root';
    }
    return relativeFolder.split('/').first;
  }

  bool _shouldSkip(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.nomedia') || lower.endsWith('.tmp');
  }

  String _basename(String path) {
    final normalized = _normalizePath(path);
    final lastSlash = normalized.lastIndexOf('/');
    if (lastSlash == -1) {
      return normalized;
    }
    return normalized.substring(lastSlash + 1);
  }

  String _normalizePath(String path) {
    return path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  }

  Future<bool> _directoryExists(String path) async {
    try {
      return await Directory(path).exists();
    } catch (_) {
      return false;
    }
  }

  String _normalizedName(String fileName) {
    final lower = fileName.toLowerCase();
    final noExtension = lower.replaceFirst(RegExp(r'\.[a-z0-9]+$'), '');
    return noExtension.replaceAll(RegExp(r'[^a-z]+'), '');
  }

  String _formatCount(int value) => value.toString();

  double _withinRootDiscovery(int filesInRoot) {
    final projected = 1 - exp(-(filesInRoot / 1400));
    return projected.clamp(0.05, 0.98).toDouble();
  }

  double _overallFor(ScanPhase phase, double stageFraction) {
    final safe = stageFraction.clamp(0.0, 1.0).toDouble();

    switch (phase) {
      case ScanPhase.idle:
        return 0;
      case ScanPhase.discovering:
        return 0 + (0.10 * safe);
      case ScanPhase.indexing:
        return 0.10 + (0.30 * safe);
      case ScanPhase.hashing:
        return 0.40 + (0.30 * safe);
      case ScanPhase.finalizing:
        return 0.70 + (0.25 * safe);
      case ScanPhase.completed:
        return 1;
      case ScanPhase.failed:
        return 0;
    }
  }
}
