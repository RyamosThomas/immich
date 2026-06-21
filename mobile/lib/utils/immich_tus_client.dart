import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:cross_file/cross_file.dart';
import 'package:http/http.dart' as http;

class _FileChunkRequest extends http.BaseRequest {
  final String _filePath;
  final int _start;
  final int _end;

  _FileChunkRequest(super.method, super.url, this._filePath, this._start, this._end);

  @override
  http.ByteStream finalize() {
    super.finalize();
    final file = File(_filePath);
    return http.ByteStream(file.openRead(_start, _end));
  }
}

class _HeaderCapturingClient extends http.BaseClient {
  final http.Client _inner;

  _HeaderCapturingClient(this._inner);

  Map<String, String>? lastHeaders;
  int? lastStatusCode;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request).then((response) {
      lastHeaders = Map<String, String>.from(
        response.headers.map(
          (key, value) => MapEntry(key.toLowerCase(), value),
        ),
      );
      lastStatusCode = response.statusCode;
      return response;
    });
  }
}

class ImmichTusClient {
  final XFile _file;
  final int _maxChunkSize;
  final _HeaderCapturingClient _client;

  ImmichTusClient(
    this._file, {
    int maxChunkSize = 512 * 1024,
    http.Client? httpClient,
  }) : _maxChunkSize = maxChunkSize,
       _client = _HeaderCapturingClient(httpClient ?? http.Client());

  Map<String, String>? get lastResponseHeaders => _client.lastHeaders;

  int? get lastStatusCode => _client.lastStatusCode;

  static String _encodeMetadata(Map<String, String> meta) {
    return meta.entries
        .map((e) => '${e.key} ${base64.encode(utf8.encode(e.value))}')
        .join(',');
  }

  Future<void> upload({
    required Uri uri,
    Map<String, String>? metadata,
    Map<String, String>? headers,
    void Function(int bytes, int totalBytes)? onProgress,
    void Function()? onComplete,
  }) async {
    final fileSize = await _file.length();
    final file = File(_file.path);

    if (!file.existsSync()) {
      throw Exception('File not found: ${_file.path}');
    }

    final createHeaders = <String, String>{
      'Tus-Resumable': '1.0.0',
      'Upload-Length': '$fileSize',
    };

    if (metadata != null && metadata.isNotEmpty) {
      createHeaders['Upload-Metadata'] = _encodeMetadata(metadata);
    }

    if (headers != null) {
      createHeaders.addAll(headers);
    }

    final createResponse = await _client.post(uri, headers: createHeaders);

    if (createResponse.statusCode < 200 || createResponse.statusCode >= 300) {
      throw Exception(
        'TUS create failed (${createResponse.statusCode}): ${createResponse.body}',
      );
    }

    final location = createResponse.headers['location'];
    if (location == null || location.isEmpty) {
      throw Exception('TUS create response missing Location header');
    }

    final uploadUrl = Uri.parse(location);

    int offset = 0;

    while (offset < fileSize) {
      final end = min(offset + _maxChunkSize, fileSize);

      final request = _FileChunkRequest('PATCH', uploadUrl, file.path, offset, end);
      request.headers.addAll({
        'Tus-Resumable': '1.0.0',
        'Upload-Offset': '$offset',
        'Content-Type': 'application/offset+octet-stream',
      });

      final chunkResponse = await _client.send(request);

      if (chunkResponse.statusCode < 200 ||
          chunkResponse.statusCode >= 300) {
        final body = await chunkResponse.stream.bytesToString();
        throw Exception(
          'TUS chunk failed (${chunkResponse.statusCode}): $body',
        );
      }

      await chunkResponse.stream.drain<void>();

      final serverOffsetStr = chunkResponse.headers['upload-offset'];
      if (serverOffsetStr == null) {
        throw Exception('TUS PATCH response missing Upload-Offset header');
      }

      final serverOffset = int.tryParse(serverOffsetStr);
      if (serverOffset == null) {
        throw Exception('TUS PATCH invalid Upload-Offset: $serverOffsetStr');
      }

      offset = serverOffset;

      onProgress?.call(offset, fileSize);
    }

    onComplete?.call();
  }
}
