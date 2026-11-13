import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:j_downloader/j_downloader.dart';

void main() {
  final Uint8List payload = Uint8List.fromList(
    List<int>.generate(256 * 1024 + 137, (i) => (i * 31 + 7) & 0xFF),
  );

  late HttpOverrides? previousHttpOverrides;

  setUpAll(() {
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });

  tearDownAll(() {
    HttpOverrides.global = previousHttpOverrides;
  });

  Future<JDownloadTask> runDownloadTask({
    required Uri url,
    required String savePath,
    required int isolateCount,
  }) async {
    final Completer<void> completer = Completer<void>();
    late JDownloadTask task;
    task = JDownloadTask.newTask(
      url: url.toString(),
      savePath: savePath,
      isolateCount: isolateCount,
      headConnectionTimeout: const Duration(seconds: 5),
      headReceiveTimeout: const Duration(seconds: 5),
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      },
    );
    await task.start();
    await completer.future.timeout(const Duration(seconds: 15));
    return task;
  }

  test('isolateCount == 1 performs single GET without HEAD or Range', () async {
    final List<({String method, String? range})> requests = [];
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      requests.add((method: request.method, range: range));
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set(HttpHeaders.contentLengthHeader, payload.length);
      request.response.add(payload);
      await request.response.close();
    });

    final Directory tempDir = await Directory.systemTemp.createTemp('j_dl_single_');
    addTearDown(() => tempDir.delete(recursive: true));
    final String savePath = '${tempDir.path}${Platform.pathSeparator}archive.zip';

    final JDownloadTask task = await runDownloadTask(
      url: Uri.parse('http://127.0.0.1:${server.port}/archive.zip'),
      savePath: savePath,
      isolateCount: 1,
    );
    await task.dispose();

    expect(requests.length, 1);
    expect(requests.single.method, 'GET');
    expect(requests.single.range, isNull);
    expect(File(savePath).readAsBytesSync(), equals(payload));
  });

  test('isolateCount > 1 seamlessly falls back on 200 OK ignoring Range', () async {
    final List<({String method, String? range})> requests = [];
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      requests.add((method: request.method, range: range));
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set(HttpHeaders.contentLengthHeader, payload.length);
      if (request.method != 'HEAD') {
        request.response.add(payload);
      }
      await request.response.close();
    });

    final Directory tempDir = await Directory.systemTemp.createTemp('j_dl_fallback_200_');
    addTearDown(() => tempDir.delete(recursive: true));
    final String savePath = '${tempDir.path}${Platform.pathSeparator}archive.zip';

    final JDownloadTask task = await runDownloadTask(
      url: Uri.parse('http://127.0.0.1:${server.port}/archive.zip'),
      savePath: savePath,
      isolateCount: 4,
    );
    await task.dispose();

    final List<({String method, String? range})> gets = requests.where((r) => r.method == 'GET').toList();
    expect(gets.length, 1);
    expect(gets.single.range, startsWith('bytes=0-'));
    expect(File(savePath).readAsBytesSync(), equals(payload));
  });

  test('isolateCount > 1 downloads chunks in parallel when 206 Partial Content is supported', () async {
    final List<({String method, String? range})> requests = [];
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      requests.add((method: request.method, range: range));
      if (request.method == 'HEAD') {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.headers.set(HttpHeaders.contentLengthHeader, payload.length);
        await request.response.close();
        return;
      }

      if (range == null || !range.startsWith('bytes=')) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      final List<String> parts = range.substring('bytes='.length).split('-');
      final int start = int.parse(parts[0]);
      final int end = int.parse(parts[1]);
      final Uint8List slice = payload.sublist(start, end + 1);

      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(HttpHeaders.contentLengthHeader, slice.length);
      request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${payload.length}');
      request.response.add(slice);
      await request.response.close();
    });

    final Directory tempDir = await Directory.systemTemp.createTemp('j_dl_range_206_');
    addTearDown(() => tempDir.delete(recursive: true));
    final String savePath = '${tempDir.path}${Platform.pathSeparator}archive.zip';

    final JDownloadTask task = await runDownloadTask(
      url: Uri.parse('http://127.0.0.1:${server.port}/archive.zip'),
      savePath: savePath,
      isolateCount: 4,
    );
    await task.dispose();

    final List<({String method, String? range})> gets = requests.where((r) => r.method == 'GET').toList();
    expect(gets.length, 4);
    for (final get in gets) {
      expect(get.range, startsWith('bytes='));
    }
    expect(File(savePath).readAsBytesSync(), equals(payload));
  });

  test('isolateCount > 1 falls back cleanly when HEAD returns 405 and GET is chunked without Content-Length', () async {
    final List<({String method, String? range})> requests = [];
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      requests.add((method: request.method, range: range));
      if (request.method == 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = -1;
      final int mid = payload.length ~/ 2;
      request.response.add(payload.sublist(0, mid));
      await request.response.flush();
      request.response.add(payload.sublist(mid));
      await request.response.close();
    });

    final Directory tempDir = await Directory.systemTemp.createTemp('j_dl_chunked_');
    addTearDown(() => tempDir.delete(recursive: true));
    final String savePath = '${tempDir.path}${Platform.pathSeparator}archive.zip';

    final JDownloadTask task = await runDownloadTask(
      url: Uri.parse('http://127.0.0.1:${server.port}/archive.zip'),
      savePath: savePath,
      isolateCount: 4,
    );
    await task.dispose();

    final List<({String method, String? range})> gets = requests.where((r) => r.method == 'GET').toList();
    expect(gets.length, 1);
    expect(gets.single.range, isNull);
    expect(File(savePath).readAsBytesSync(), equals(payload));
  });

  test('truncated response triggers error and does not leave a corrupt final file', () async {
    final ServerSocket rawServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => rawServer.close());

    rawServer.listen((Socket socket) {
      socket.listen((_) {});
      final int partialLen = payload.length ~/ 2;
      final String header = 'HTTP/1.1 200 OK\r\n'
          'Content-Length: ${payload.length}\r\n'
          'Connection: close\r\n\r\n';
      socket.write(header);
      socket.add(payload.sublist(0, partialLen));
      socket.flush().then((_) => socket.close());
    });

    final Directory tempDir = await Directory.systemTemp.createTemp('j_dl_eof_');
    addTearDown(() => tempDir.delete(recursive: true));
    final String savePath = '${tempDir.path}${Platform.pathSeparator}archive.zip';

    JDownloadException? capturedError;
    final Completer<void> completer = Completer<void>();
    final JDownloadTask task = JDownloadTask.newTask(
      url: 'http://127.0.0.1:${rawServer.port}/archive.zip',
      savePath: savePath,
      isolateCount: 1,
      headConnectionTimeout: const Duration(seconds: 5),
      headReceiveTimeout: const Duration(seconds: 5),
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (e) {
        capturedError = e;
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
    );

    await task.start();
    await completer.future.timeout(const Duration(seconds: 15));
    await task.dispose();

    expect(capturedError, isNotNull);
    expect(
      capturedError!.type,
      anyOf(JDownloadExceptionType.receiveDataFailed, JDownloadExceptionType.downloadFailed),
    );
    expect(File(savePath).existsSync(), isFalse);
  });
}
