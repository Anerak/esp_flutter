import 'dart:async';
import 'dart:js_interop';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

http.Client createLocalHttpClient() => _LocalWebHttpClient();

String _inferAddressSpace(Uri url) {
  final host = url.host.toLowerCase();
  if (host == 'localhost' ||
      host == '::1' ||
      host == '[::1]' ||
      host.startsWith('127.')) {
    return 'loopback';
  }
  return 'local';
}

/// Browser `fetch`-backed HTTP client that annotates `http://` LAN requests
/// from `https://` origins with `targetAddressSpace: 'local'` (or `'loopback'`)
/// for Chrome/Edge Local Network Access mixed-content exemption, and avoids
/// non-safelisted headers so requests stay CORS-simple.
class _LocalWebHttpClient extends http.BaseClient {
  bool _isClosed = false;
  final List<web.AbortController> _controllers = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_isClosed) {
      throw http.ClientException(
        'HTTP request failed. Client is already closed.',
        request.url,
      );
    }

    final abortController = web.AbortController();
    _controllers.add(abortController);

    final bodyBytes = await request.finalize().toBytes();
    try {
      final isHttpsToHttp =
          Uri.base.scheme == 'https' && request.url.scheme == 'http';

      final init = isHttpsToHttp
          ? web.RequestInit(
              method: request.method,
              mode: 'cors',
              credentials: 'omit',
              targetAddressSpace: _inferAddressSpace(request.url),
              body: bodyBytes.isNotEmpty ? bodyBytes.toJS : null,
              headers: {
                for (final entry in request.headers.entries)
                  entry.key: entry.value,
              }.jsify()! as web.HeadersInit,
              signal: abortController.signal,
              redirect: request.followRedirects ? 'follow' : 'error',
            )
          : web.RequestInit(
              method: request.method,
              mode: 'cors',
              credentials: 'omit',
              body: bodyBytes.isNotEmpty ? bodyBytes.toJS : null,
              headers: {
                for (final entry in request.headers.entries)
                  entry.key: entry.value,
              }.jsify()! as web.HeadersInit,
              signal: abortController.signal,
              redirect: request.followRedirects ? 'follow' : 'error',
            );

      final response =
          await web.window.fetch('${request.url}'.toJS, init).toDart;
      final arrayBuffer = await response.arrayBuffer().toDart;
      final responseBytes = arrayBuffer.toDart.asUint8List();

      return http.StreamedResponse(
        Stream<List<int>>.value(responseBytes),
        response.status,
        contentLength: responseBytes.length,
        request: request,
        reasonPhrase: response.statusText,
      );
    } catch (error) {
      throw http.ClientException(error.toString(), request.url);
    } finally {
      _controllers.remove(abortController);
    }
  }

  @override
  void close() {
    for (final controller in _controllers) {
      controller.abort();
    }
    _controllers.clear();
    _isClosed = true;
  }
}
