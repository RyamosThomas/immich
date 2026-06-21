import 'package:http/http.dart' as http;
import 'package:tus_client_dart/tus_client_dart.dart';

class _HeaderCapturingClient extends http.BaseClient {
  final http.Client _inner = http.Client();

  Map<String, String>? lastHeaders;
  int? lastStatusCode;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request).then((response) {
      lastHeaders = Map<String, String>.from(
        response.headers.map((key, value) => MapEntry(key.toLowerCase(), value)),
      );
      lastStatusCode = response.statusCode;
      return response;
    });
  }

  void closeInner() {
    _inner.close();
  }
}

class ImmichTusClient extends TusClient {
  final _HeaderCapturingClient _client = _HeaderCapturingClient();

  ImmichTusClient(super.file, {super.store, super.maxChunkSize});

  @override
  http.Client getHttpClient() => _client;

  Map<String, String>? get lastResponseHeaders => _client.lastHeaders;

  int? get lastStatusCode => _client.lastStatusCode;

  void dispose() {
    _client.closeInner();
  }
}
