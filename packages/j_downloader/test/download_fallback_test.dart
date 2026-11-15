import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
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
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final Completer<void> completer = Completer<void>();
    late JDownloadTask task;
    task = JDownloadTask.newTask(
      url: url.toString(),
      savePath: savePath,
      isolateCount: isolateCount,
      headConnectionTimeout: timeout,
      headReceiveTimeout: timeout,
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
    expect(File('$savePath.jdtemp').existsSync(), isFalse);
    expect(File('$savePath.jdmeta').existsSync(), isFalse);
    expect(File('$savePath.jdcopy').existsSync(), isFalse);
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

  test('truncated non-resumable response triggers error and does not leave a corrupt final file', () async {
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

  test('isolateCount == 1 preserves breakpoint across pause/restart via .jdmeta and resumes with 206 Range', () async {
    final int splitPoint = payload.length ~/ 2;
    final List<String?> receivedRanges = [];
    final Completer<void> firstHalfWritten = Completer<void>();
    final Completer<void> allowPauseHold = Completer<void>();

    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      receivedRanges.add(range);
      if (range == null) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set(HttpHeaders.contentLengthHeader, payload.length);
        request.response.add(payload.sublist(0, splitPoint));
        await request.response.flush();
        if (!firstHalfWritten.isCompleted) {
          firstHalfWritten.complete();
        }
        await allowPauseHold.future;
        try {
          await request.response.close();
        } catch (_) {}
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

    final Directory tempDir = await Directory.systemTemp.createTemp('j_dl_resume_single_');
    addTearDown(() => tempDir.delete(recursive: true));
    final String savePath = '${tempDir.path}${Platform.pathSeparator}archive.zip';
    final Uri url = Uri.parse('http://127.0.0.1:${server.port}/archive.zip');

    final Completer<void> progressReached = Completer<void>();
    final JDownloadTask task1 = JDownloadTask.newTask(
      url: url.toString(),
      savePath: savePath,
      isolateCount: 1,
      headConnectionTimeout: const Duration(seconds: 5),
      headReceiveTimeout: const Duration(seconds: 5),
      onProgress: (current, total) {
        if (current >= splitPoint && !progressReached.isCompleted) {
          progressReached.complete();
        }
      },
    );

    await task1.start();
    await firstHalfWritten.future.timeout(const Duration(seconds: 5));
    await progressReached.future.timeout(const Duration(seconds: 5));
    await task1.pause();
    allowPauseHold.complete();

    expect(task1.currentBytes, greaterThanOrEqualTo(splitPoint));
    expect(File('$savePath.jdmeta').existsSync(), isTrue);
    expect(File('$savePath.jdtemp').existsSync(), isTrue);

    final JDownloadTask resumedTask = await runDownloadTask(
      url: url,
      savePath: savePath,
      isolateCount: 1,
    );
    await resumedTask.dispose();

    expect(receivedRanges.length, 2);
    expect(receivedRanges[0], isNull);
    expect(receivedRanges[1], startsWith('bytes=$splitPoint-${payload.length - 1}'));
    expect(File(savePath).readAsBytesSync(), equals(payload));
    expect(File('$savePath.jdmeta').existsSync(), isFalse);
    expect(File('$savePath.jdtemp').existsSync(), isFalse);
  });

  test('chunk-level retry automatically resumes range chunk after mid-stream EOF', () async {
    final ServerSocket rawServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => rawServer.close());

    int getAttempt = 0;
    rawServer.listen((Socket socket) {
      final List<int> reqBytes = [];
      bool handled = false;
      socket.listen((List<int> data) async {
        if (handled) {
          return;
        }
        reqBytes.addAll(data);
        final String reqText = utf8.decode(reqBytes, allowMalformed: true);
        if (!reqText.contains('\r\n\r\n')) {
          return;
        }
        handled = true;

        final String firstLine = reqText.split('\r\n').first;
        if (firstLine.startsWith('HEAD ')) {
          socket.write(
            'HTTP/1.1 200 OK\r\n'
            'Accept-Ranges: bytes\r\n'
            'Content-Length: ${payload.length}\r\n'
            'Connection: close\r\n\r\n',
          );
          await socket.flush();
          await socket.close();
          return;
        }

        final RegExpMatch? rangeMatch = RegExp(r'Range:\s*bytes=(\d+)-(\d+)', caseSensitive: false).firstMatch(reqText);
        final int start = int.parse(rangeMatch!.group(1)!);
        final int end = int.parse(rangeMatch.group(2)!);
        getAttempt++;
        if (getAttempt == 1) {
          final int dropAt = start + (end - start + 1) ~/ 2;
          socket.write(
            'HTTP/1.1 206 Partial Content\r\n'
            'Content-Length: ${end - start + 1}\r\n'
            'Content-Range: bytes $start-$end/${payload.length}\r\n'
            'Connection: close\r\n\r\n',
          );
          socket.add(payload.sublist(start, dropAt));
          await socket.flush();
          await socket.close();
          return;
        }

        final Uint8List slice = payload.sublist(start, end + 1);
        socket.write(
          'HTTP/1.1 206 Partial Content\r\n'
          'Content-Length: ${slice.length}\r\n'
          'Content-Range: bytes $start-$end/${payload.length}\r\n'
          'Connection: close\r\n\r\n',
        );
        socket.add(slice);
        await socket.flush();
        await socket.close();
      });
    });

    final Directory tempDir = await Directory.systemTemp.createTemp('j_dl_retry_206_');
    addTearDown(() => tempDir.delete(recursive: true));
    final String savePath = '${tempDir.path}${Platform.pathSeparator}archive.zip';

    final JDownloadTask task = await runDownloadTask(
      url: Uri.parse('http://127.0.0.1:${rawServer.port}/archive.zip'),
      savePath: savePath,
      isolateCount: 2,
    );
    await task.dispose();

    expect(getAttempt, greaterThanOrEqualTo(3));
    expect(File(savePath).readAsBytesSync(), equals(payload));
  });

  test('corrupt short metadata does not throw RangeError and recovers cleanly', () async {
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((HttpRequest request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set(HttpHeaders.contentLengthHeader, payload.length);
      request.response.add(payload);
      await request.response.close();
    });

    final Directory tempDir = await Directory.systemTemp.createTemp('j_dl_corrupt_');
    addTearDown(() => tempDir.delete(recursive: true));
    final String savePath = '${tempDir.path}${Platform.pathSeparator}archive.zip';

    // Simulate 1-byte truncated legacy file + invalid JSON sidecar.
    File('$savePath.jdtemp').writeAsBytesSync(<int>[1]);
    File('$savePath.jdmeta').writeAsStringSync('{corrupt');

    final JDownloadTask task = await runDownloadTask(
      url: Uri.parse('http://127.0.0.1:${server.port}/archive.zip'),
      savePath: savePath,
      isolateCount: 1,
    );
    await task.dispose();

    expect(File(savePath).readAsBytesSync(), equals(payload));
    expect(File('$savePath.jdmeta').existsSync(), isFalse);
  });

  test('legacy 16KB embedded-header .jdtemp resumes and strips header on completion', () async {
    final int resumeAt = payload.length ~/ 2;
    final List<String?> ranges = [];
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      final List<String> parts = range!.substring('bytes='.length).split('-');
      final int start = int.parse(parts[0]);
      final int end = int.parse(parts[1]);
      final Uint8List slice = payload.sublist(start, end + 1);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(HttpHeaders.contentLengthHeader, slice.length);
      request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${payload.length}');
      request.response.add(slice);
      await request.response.close();
    });

    final Directory tempDir = await Directory.systemTemp.createTemp('j_dl_legacy_');
    addTearDown(() => tempDir.delete(recursive: true));
    final String savePath = '${tempDir.path}${Platform.pathSeparator}archive.zip';
    final Uri url = Uri.parse('http://127.0.0.1:${server.port}/archive.zip');

    // Construct a legacy 16 KB header + first half of payload at offset 16 KB.
    const int headerSize = 1024 * 16;
    final String metaJson = jsonEncode({
      'url': url.toString(),
      'savePath': savePath,
      'totalBytes': payload.length,
      'chunks': jsonEncode([
        {'size': payload.length, 'downloadedBytes': resumeAt},
      ]),
    });
    final Uint8List metaBytes = Uint8List.fromList(utf8.encode(metaJson));
    final Uint8List legacyFileBytes = Uint8List(headerSize + payload.length);
    legacyFileBytes[0] = metaBytes.length & 0xFF;
    legacyFileBytes[1] = metaBytes.length >> 8;
    legacyFileBytes.setRange(2, 2 + metaBytes.length, metaBytes);
    legacyFileBytes.setRange(headerSize, headerSize + resumeAt, payload.sublist(0, resumeAt));
    File('$savePath.jdtemp').writeAsBytesSync(legacyFileBytes);

    final JDownloadTask task = await runDownloadTask(
      url: url,
      savePath: savePath,
      isolateCount: 1,
    );
    await task.dispose();

    expect(ranges.single, 'bytes=$resumeAt-${payload.length - 1}');
    expect(File(savePath).readAsBytesSync(), equals(payload));
    expect(File('$savePath.jdtemp').existsSync(), isFalse);
  });

  test('stalled body stream enforces receiveTimeout and status 410 preserves DioException across isolate boundary', () async {
    final ServerSocket stallServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => stallServer.close());

    final List<Socket> heldSockets = [];
    stallServer.listen((Socket socket) {
      heldSockets.add(socket);
      socket.listen((_) {});
      socket.write(
        'HTTP/1.1 200 OK\r\n'
        'Content-Length: ${payload.length}\r\n'
        'Connection: close\r\n\r\n',
      );
      socket.add(payload.sublist(0, 64));
      socket.flush();
    });
    addTearDown(() {
      for (final Socket s in heldSockets) {
        s.destroy();
      }
    });

    final Directory tempDir = await Directory.systemTemp.createTemp('j_dl_stall_');
    addTearDown(() => tempDir.delete(recursive: true));
    final String stallSavePath = '${tempDir.path}${Platform.pathSeparator}stall.zip';

    JDownloadException? stallError;
    final Completer<void> stallCompleter = Completer<void>();
    final JDownloadTask stallTask = JDownloadTask.newTask(
      url: 'http://127.0.0.1:${stallServer.port}/stall.zip',
      savePath: stallSavePath,
      isolateCount: 1,
      headConnectionTimeout: const Duration(milliseconds: 250),
      headReceiveTimeout: const Duration(milliseconds: 250),
      onError: (JDownloadException e) {
        stallError = e;
        if (!stallCompleter.isCompleted) {
          stallCompleter.complete();
        }
      },
    );

    await stallTask.start();
    await stallCompleter.future.timeout(const Duration(seconds: 5));
    await stallTask.dispose();

    expect(stallError, isNotNull);
    expect(stallError!.type, JDownloadExceptionType.receiveDataFailed);

    // Now verify 410 response crosses SendPort cleanly as DioException with statusCode == 410.
    final HttpServer goneServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => goneServer.close(force: true));
    goneServer.listen((HttpRequest request) async {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
    });

    JDownloadException? goneError;
    final Completer<void> goneCompleter = Completer<void>();
    final String goneSavePath = '${tempDir.path}${Platform.pathSeparator}gone.zip';
    final JDownloadTask goneTask = JDownloadTask.newTask(
      url: 'http://127.0.0.1:${goneServer.port}/gone.zip',
      savePath: goneSavePath,
      isolateCount: 1,
      onError: (JDownloadException e) {
        goneError = e;
        if (!goneCompleter.isCompleted) {
          goneCompleter.complete();
        }
      },
    );
    await goneTask.start();
    await goneCompleter.future.timeout(const Duration(seconds: 5));
    await goneTask.dispose();

    expect(goneError, isNotNull);
    expect(goneError!.type, JDownloadExceptionType.downloadFailed);
    expect(goneError!.error, isA<DioException>());
    expect((goneError!.error as DioException).response?.statusCode, HttpStatus.gone);
  });
}
