import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_socks_proxy/socks_proxy.dart';
import 'package:j_downloader/src/exception/j_download_exception.dart';
import 'package:j_downloader/src/model/main_isolate_message.dart';
import 'package:j_downloader/src/model/proxy_config.dart';
import 'package:j_downloader/src/model/sub_isolate_message.dart';
import 'package:logger/web.dart';

class SubIsolateManager {
  final ReceivePort _subReceivePort;
  final SendPort _mainSendPort;

  late final ProxyConfig? _proxyConfig;

  CancelToken? _cancelToken;

  SubIsolateManager({
    required SendPort mainSendPort,
  })  : _mainSendPort = mainSendPort,
        _subReceivePort = ReceivePort() {
    _mainSendPort.send(SubIsolateMessage(SubIsolateMessageType.created, _subReceivePort.sendPort));

    _subReceivePort.listen((message) {
      _mainSendPort.send(SubIsolateMessage(SubIsolateMessageType.log, LogEvent(Level.debug, 'received main message: $message')));

      switch (message.type) {
        case MainIsolateMessageType.init:
          message = message as MainIsolateMessage<ProxyConfig?>;
          _proxyConfig = message.data;
          SocksProxy.initProxy(findProxy: ProxyConfig.toFindProxy(_proxyConfig));
          _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.inited, null));
          break;
        case MainIsolateMessageType.download:
          message = message as MainIsolateMessage<
              ({
                String url,
                String downloadPath,
                ({int start, int end})? downloadRange,
                int fileWriteOffset,
                int preservedMetadataHeaderSize,
              })>;
          download(
            message.data.url,
            message.data.downloadPath,
            message.data.downloadRange,
            message.data.fileWriteOffset,
            message.data.preservedMetadataHeaderSize,
          );
          break;
        case MainIsolateMessageType.close:
          if (_cancelToken == null || _cancelToken!.isCancelled) {
            _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
          } else {
            _cancelToken!.cancel();
          }
          break;
        default:
          break;
      }
    });
  }

  Future<void> download(
    String url,
    String downloadPath,
    ({int start, int end})? downloadRange,
    int fileWriteOffset,
    int preservedMetadataHeaderSize,
  ) async {
    _cancelToken ??= CancelToken();
    Response<ResponseBody> response;

    _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.begin, null));
    try {
      final Map<String, dynamic>? headers = downloadRange == null
          ? null
          : {'Range': 'bytes=${downloadRange.start}-${downloadRange.end - 1}'};
      response = await Dio().get(
        url,
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          preserveHeaderCase: true,
          headers: headers,
          responseType: ResponseType.stream,
        ),
        cancelToken: _cancelToken,
      );
    } on DioException catch (e) {
      _cancelToken = null;

      if (e.type == DioExceptionType.cancel) {
        _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
      } else {
        e.response?.data = null;
        e.requestOptions.cancelToken = null;
        _mainSendPort.send(
          SubIsolateMessage<JDownloadException>(
            SubIsolateMessageType.error,
            JDownloadException(
              JDownloadExceptionType.downloadFailed,
              error: e,
            ),
          ),
        );
      }

      return;
    }

    final int statusCode = response.statusCode ?? HttpStatus.ok;
    final int? headerContentLength = int.tryParse(response.headers.value(HttpHeaders.contentLengthHeader) ?? '');

    int actualWriteOffset = fileWriteOffset;
    bool resetFromStart = false;
    int? expectedBytes = downloadRange == null ? headerContentLength : downloadRange.end - downloadRange.start;

    if (downloadRange != null) {
      if (statusCode == HttpStatus.partialContent) {
        // Range honored.
      } else if (statusCode == HttpStatus.ok) {
        // Server ignored Range and returned the full stream from byte 0;
        // consume this response seamlessly from the beginning instead of aborting.
        resetFromStart = true;
        actualWriteOffset = preservedMetadataHeaderSize;
        expectedBytes = headerContentLength;
      } else {
        _cancelToken!.cancel();
        _cancelToken = null;

        return _mainSendPort.send(
          SubIsolateMessage<JDownloadException>(
            SubIsolateMessageType.error,
            JDownloadException(JDownloadExceptionType.serverNotSupport),
          ),
        );
      }
    } else if (statusCode != HttpStatus.ok && statusCode != HttpStatus.partialContent) {
      _cancelToken!.cancel();
      _cancelToken = null;

      return _mainSendPort.send(
        SubIsolateMessage<JDownloadException>(
          SubIsolateMessageType.error,
          JDownloadException(JDownloadExceptionType.downloadFailed),
        ),
      );
    }

    _mainSendPort.send(SubIsolateMessage(SubIsolateMessageType.log, LogEvent(Level.debug, 'open download file')));

    File downloadFile = File(downloadPath);
    RandomAccessFile raf = await downloadFile.open(mode: FileMode.writeOnlyAppend);
    await raf.setPosition(actualWriteOffset);

    if (_cancelToken?.isCancelled ?? false) {
      await raf.close().catchError((_) => raf);
      _cancelToken = null;
      _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
      return;
    }

    _mainSendPort.send(
      SubIsolateMessage<({int statusCode, int? contentLength, bool resetFromStart})>(
        SubIsolateMessageType.responseStarted,
        (statusCode: statusCode, contentLength: headerContentLength, resetFromStart: resetFromStart),
      ),
    );

    int writtenBytes = 0;
    Future<void>? asyncWrite;
    bool closed = false;
    Future<void> close() async {
      if (!closed) {
        closed = true;
        await asyncWrite;
        await raf.close().catchError((_) => raf);
        _mainSendPort.send(SubIsolateMessage(SubIsolateMessageType.log, LogEvent(Level.debug, 'close download file')));
      }
    }

    Stream<Uint8List> stream = response.data!.stream;
    late StreamSubscription subscription;
    subscription = stream.listen(
      (data) {
        Uint8List chunk = data;
        if (downloadRange != null && !resetFromStart && expectedBytes != null) {
          final int remaining = expectedBytes - writtenBytes;
          if (remaining <= 0) {
            return;
          }
          if (chunk.length > remaining) {
            chunk = Uint8List.sublistView(chunk, 0, remaining);
          }
        }
        if (chunk.isEmpty) {
          return;
        }

        subscription.pause();
        asyncWrite = raf.writeFrom(chunk).then((result) {
          writtenBytes += chunk.length;
          _mainSendPort.send(SubIsolateMessage<int>(SubIsolateMessageType.progress, chunk.length));
          raf = result;
          if (_cancelToken != null && !_cancelToken!.isCancelled) {
            subscription.resume();
          }
        }).catchError((e) async {
          await subscription.cancel().catchError((_) {});
          closed = true;
          await raf.close().catchError((_) => raf);
          _mainSendPort.send(SubIsolateMessage(SubIsolateMessageType.log, LogEvent(Level.debug, 'close download file')));
          _mainSendPort.send(
            SubIsolateMessage<JDownloadException>(
              SubIsolateMessageType.error,
              JDownloadException(JDownloadExceptionType.writeDownloadFileFailed, error: e),
            ),
          );
        });
      },
      onDone: () async {
        await asyncWrite;
        if (_cancelToken?.isCancelled ?? false) {
          await close();
          return;
        }
        closed = true;
        await raf.close().catchError((_) => raf);
        _mainSendPort.send(SubIsolateMessage(SubIsolateMessageType.log, LogEvent(Level.debug, 'close download file')));
        _cancelToken = null;
        if (expectedBytes != null && writtenBytes < expectedBytes) {
          _mainSendPort.send(
            SubIsolateMessage<JDownloadException>(
              SubIsolateMessageType.error,
              JDownloadException(
                JDownloadExceptionType.receiveDataFailed,
                error: StateError('Unexpected EOF: expected $expectedBytes bytes, got $writtenBytes bytes'),
              ),
            ),
          );
          return;
        }
        _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.done, null));
      },
      onError: (e) async {
        await close();
        _cancelToken = null;
        _mainSendPort.send(SubIsolateMessage(SubIsolateMessageType.error, JDownloadException(JDownloadExceptionType.receiveDataFailed, error: e)));
      },
      cancelOnError: true,
    );

    _cancelToken?.whenCancel.then((_) async {
      await subscription.cancel();
      await close();
      _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
    });
  }
}

void subIsolateEntryPoint(SendPort mainSendPort) {
  SubIsolateManager(mainSendPort: mainSendPort);
}
