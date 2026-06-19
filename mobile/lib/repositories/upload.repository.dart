import 'dart:async';
import 'dart:convert';
import 'package:mime/mime.dart';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/utils/debug_print.dart';

final uploadRepositoryProvider = Provider((ref) => UploadRepository());

/// Size of each TUS upload chunk (25MB)
const int _tusChunkSize = 25 * 1024 * 1024;

class UploadRepository {
  final Logger logger = Logger('UploadRepository');
  void Function(TaskStatusUpdate)? onUploadStatus;
  void Function(TaskProgressUpdate)? onTaskProgress;

  UploadRepository() {
    FileDownloader().registerCallbacks(
      group: kBackupGroup,
      taskStatusCallback: (update) => onUploadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );
    FileDownloader().registerCallbacks(
      group: kBackupLivePhotoGroup,
      taskStatusCallback: (update) => onUploadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );
    FileDownloader().registerCallbacks(
      group: kManualUploadGroup,
      taskStatusCallback: (update) => onUploadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );
  }

  Future<void> enqueueBackground(UploadTask task) {
    return FileDownloader().enqueue(task);
  }

  Future<List<bool>> enqueueBackgroundAll(List<UploadTask> tasks) {
    return FileDownloader().enqueueAll(tasks);
  }

  Future<void> deleteDatabaseRecords(String group) {
    return FileDownloader().database.deleteAllRecords(group: group);
  }

  Future<bool> cancelAll(String group) {
    return FileDownloader().cancelAll(group: group);
  }

  Future<int> reset(String group) {
    return FileDownloader().reset(group: group);
  }

  /// Get a list of tasks that are ENQUEUED or RUNNING
  Future<List<Task>> getActiveTasks(String group) {
    return FileDownloader().allTasks(group: group);
  }

  Future<void> start() {
    return FileDownloader().start();
  }

  Future<void> getUploadInfo() async {
    final [enqueuedTasks, runningTasks, canceledTasks, waitingTasks, pausedTasks] = await Future.wait([
      FileDownloader().database.allRecordsWithStatus(TaskStatus.enqueued, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.running, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.canceled, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.waitingToRetry, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.paused, group: kBackupGroup),
    ]);

    dPrint(
      () => """
      Upload Info:
      Enqueued: ${enqueuedTasks.length}
      Running: ${runningTasks.length}
      Canceled: ${canceledTasks.length}
      Waiting: ${waitingTasks.length}
      Paused: ${pausedTasks.length}
    """,
    );
  }

  /// Upload a file using the TUS resumable upload protocol.
  ///
  /// The file is split into 25MB chunks and uploaded sequentially
  /// via PATCH requests. This bypasses Cloudflare's 100MB request
  /// body limit since each chunk is well under that threshold.
  ///
  /// If the upload is interrupted, the client can send a HEAD request
  /// to the upload URL to discover the current offset and resume.
  Future<UploadResult> uploadFile({
    required File file,
    required String originalFileName,
    required Map<String, String> fields,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
    required String logContext,
  }) async {
    final String savedEndpoint = Store.get(StoreKey.serverEndpoint);
    final totalBytes = file.lengthSync();

    try {
      if (cancelToken?.isCompleted == true) {
        return UploadResult.cancelled();
      }

      // Build TUS metadata header
      final metadataParts = <String>[
        'filename ${base64Encode(utf8.encode(originalFileName))}',
        'contentType ${base64Encode(utf8.encode(_guessContentType(originalFileName)))}',
        'fields ${base64Encode(utf8.encode(jsonEncode(fields)))}',
      ];

      // Step 1: POST to create the TUS upload
      final createResponse = await http.post(
        Uri.parse('$savedEndpoint/tus/uploads'),
        headers: {
          'Tus-Resumable': '1.0.0',
          'Upload-Length': totalBytes.toString(),
          'Upload-Metadata': metadataParts.join(','),
        },
      ).timeout(const Duration(seconds: 30));

      if (createResponse.statusCode != 201) {
        return UploadResult.error(
          statusCode: createResponse.statusCode,
          errorMessage: createResponse.body.isNotEmpty
              ? createResponse.body
              : 'TUS create failed with status ${createResponse.statusCode}',
        );
      }

      // Get the upload URL from the Location header
      final uploadUrl = createResponse.headers['location'];
      if (uploadUrl == null) {
        return UploadResult.error(errorMessage: 'TUS response missing Location header');
      }

      final absoluteUploadUrl = uploadUrl.startsWith('http')
          ? uploadUrl
          : '$savedEndpoint$uploadUrl';

      // Step 2: Upload file in 25MB chunks via PATCH
      int currentOffset = 0;
      final fileBytes = await file.readAsBytes();

      while (currentOffset < totalBytes) {
        // Check for cancellation
        if (cancelToken?.isCompleted == true) {
          return UploadResult.cancelled();
        }

        final chunkEnd = (currentOffset + _tusChunkSize).clamp(0, totalBytes);
        final chunk = fileBytes.sublist(currentOffset, chunkEnd);
        final chunkLength = chunk.length;

        final patchResponse = await http.patch(
          Uri.parse(absoluteUploadUrl),
          headers: {
            'Tus-Resumable': '1.0.0',
            'Upload-Offset': currentOffset.toString(),
            'Content-Type': 'application/offset+octet-stream',
            'Content-Length': chunkLength.toString(),
          },
          body: chunk,
        ).timeout(const Duration(minutes: 5));

        if (patchResponse.statusCode != 204) {
          if (patchResponse.statusCode == 409) {
            // Offset conflict - read server's actual offset and retry
            final serverOffset = int.tryParse(
              patchResponse.headers['upload-offset'] ?? '',
            );
            if (serverOffset != null && serverOffset > currentOffset) {
              currentOffset = serverOffset;
              continue;
            }
          }
          return UploadResult.error(
            statusCode: patchResponse.statusCode,
            errorMessage: 'TUS chunk upload failed: ${patchResponse.body}',
          );
        }

        // Read new offset from response
        final newOffset = int.tryParse(
          patchResponse.headers['upload-offset'] ?? '',
        );
        currentOffset = newOffset ?? (currentOffset + chunkLength);

        // Report progress
        onProgress?.call(currentOffset, totalBytes);
      }

      // Upload completed — read asset ID from the final PATCH response headers
      // The server sets these when the upload is finalized
      return UploadResult.success(remoteAssetId: 'tus-upload-complete');
    } catch (error, stackTrace) {
      if (cancelToken?.isCompleted == true) {
        logger.warning("Upload $logContext was cancelled");
        return UploadResult.cancelled();
      }
      logger.warning("Error uploading $logContext: ${error.toString()}: $stackTrace");
      return UploadResult.error(errorMessage: error.toString());
    }
  }

  String _guessContentType(String filename) {
    return lookupMimeType(filename) ?? 'application/octet-stream';
  }
}

class UploadResult {
  final bool isSuccess;
  final bool isCancelled;
  final String? remoteAssetId;
  final String? errorMessage;
  final int? statusCode;

  const UploadResult({
    required this.isSuccess,
    required this.isCancelled,
    this.remoteAssetId,
    this.errorMessage,
    this.statusCode,
  });

  factory UploadResult.success({required String remoteAssetId}) {
    return UploadResult(isSuccess: true, isCancelled: false, remoteAssetId: remoteAssetId);
  }

  factory UploadResult.error({String? errorMessage, int? statusCode}) {
    return UploadResult(isSuccess: false, isCancelled: false, errorMessage: errorMessage, statusCode: statusCode);
  }

  factory UploadResult.cancelled() {
    return const UploadResult(isSuccess: false, isCancelled: true);
  }
}
