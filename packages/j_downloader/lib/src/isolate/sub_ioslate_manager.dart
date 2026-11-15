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
  Dio? _dio;

  CancelToken? _cancelToken;
  bool _inDownload = false;
  bool _closing = false;

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
          _dio = Dio();
          _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.inited, null));
          break;
        case MainIsolateMessageType.download:
          message = message as MainIsolateMessage<
              ({
                String url,
                String downloadPath,
                ({int start, int end})? downloadRange,
                int fileWriteOffset,
                int dataOffset,
                Duration connectionTimeout,
                Duration receiveTimeout,
              })>;
          download(
            message.data.url,
            message.data.downloadPath,
            message.data.downloadRange,
            message.data.fileWriteOffset,
            message.data.dataOffset,
            message.data.connectionTimeout,
            message.data.receiveTimeout,
          );
          break;
        case MainIsolateMessageType.close:
          _closing = true;
          if (!_inDownload || _cancelToken == null || _cancelToken!.isCancelled) {
            _dio?.close(force: true);
            _dio = null;
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

  DioException _sanitizeDioException(DioException e) {
    return DioException(
      requestOptions: RequestOptions(
        path: e.requestOptions.path,
        baseUrl: e.requestOptions.baseUrl,
        method: e.requestOptions.method,
      ),
      response: e.response == null
          ? null
          : Response<dynamic>(
              requestOptions: RequestOptions(path: e.requestOptions.path),
              statusCode: e.response?.statusCode,
              statusMessage: e.response?.statusMessage,
            ),
      type: e.type,
      error: e.error?.toString(),
      message: e.message,
    );
  }

  Future<void> download(
    String url,
    String downloadPath,
    ({int start, int end})? downloadRange,
    int fileWriteOffset,
    int dataOffset,
    Duration connectionTimeout,
    Duration receiveTimeout,
  ) async {
    if (_closing) {
      _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
      return;
    }

    _inDownload = true;
    final CancelToken cancelToken = CancelToken();
    _cancelToken = cancelToken;

    final Dio dio = _dio ??= Dio();
    dio.options.connectTimeout = connectionTimeout;
    dio.options.receiveTimeout = receiveTimeout;

    Response<ResponseBody> response;
    _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.begin, null));

    try {
      final Map<String, dynamic>? headers =
          downloadRange == null ? null : {'Range': 'bytes=${downloadRange.start}-${downloadRange.end - 1}'};
      response = await dio.get<ResponseBody>(
        url,
        options: Options(
          sendTimeout: connectionTimeout > Duration.zero ? connectionTimeout : const Duration(seconds: 15),
          receiveTimeout: receiveTimeout,
          preserveHeaderCase: true,
          headers: headers,
          responseType: ResponseType.stream,
        ),
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      _inDownload = false;
      if (identical(_cancelToken, cancelToken)) {
        _cancelToken = null;
      }

      if (e.type == DioExceptionType.cancel || _closing) {
        if (_closing) {
          _dio?.close(force: true);
          _dio = null;
        }
        _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
      } else {
        _mainSendPort.send(
          SubIsolateMessage<JDownloadException>(
            SubIsolateMessageType.error,
            JDownloadException(
              JDownloadExceptionType.downloadFailed,
              error: _sanitizeDioException(e),
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
        // Server ignored Range and returned full stream from byte 0.
        resetFromStart = true;
        actualWriteOffset = dataOffset;
        expectedBytes = headerContentLength;
      } else {
        _inDownload = false;
        _cancelToken = null;
        _drainResponseQuietly(response);
        _mainSendPort.send(
          SubIsolateMessage<JDownloadException>(
            SubIsolateMessageType.error,
            JDownloadException(
              JDownloadExceptionType.serverNotSupport,
              error: _statusException(url, statusCode, response.statusMessage),
            ),
          ),
        );
        return;
      }
    } else if (statusCode != HttpStatus.ok && statusCode != HttpStatus.partialContent) {
      _inDownload = false;
      _cancelToken = null;
      _drainResponseQuietly(response);
      _mainSendPort.send(
        SubIsolateMessage<JDownloadException>(
          SubIsolateMessageType.error,
          JDownloadException(
            JDownloadExceptionType.downloadFailed,
            error: _statusException(url, statusCode, response.statusMessage),
          ),
        ),
      );
      return;
    }

    if (_closing || cancelToken.isCancelled) {
      _inDownload = false;
      _cancelToken = null;
      _drainResponseQuietly(response);
      if (_closing) {
        _dio?.close(force: true);
        _dio = null;
      }
      _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
      return;
    }

    _mainSendPort.send(SubIsolateMessage(SubIsolateMessageType.log, LogEvent(Level.debug, 'open download file')));

    final File downloadFile = File(downloadPath);
    RandomAccessFile? raf;
    try {
      raf = await downloadFile.open(mode: FileMode.writeOnlyAppend);
      await raf.setPosition(actualWriteOffset);
    } catch (e) {
      await raf?.close().catchError((_) => raf!);
      _inDownload = false;
      _cancelToken = null;
      _drainResponseQuietly(response);
      _mainSendPort.send(
        SubIsolateMessage<JDownloadException>(
          SubIsolateMessageType.error,
          JDownloadException(JDownloadExceptionType.writeDownloadFileFailed, error: e.toString()),
        ),
      );
      return;
    }

    if (_closing || cancelToken.isCancelled) {
      await raf.close().catchError((_) => raf!);
      _inDownload = false;
      _cancelToken = null;
      _drainResponseQuietly(response);
      if (_closing) {
        _dio?.close(force: true);
        _dio = null;
      }
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
    bool rafClosed = false;
    bool finished = false;
    Timer? idleTimer;
    StreamSubscription<Uint8List>? subscription;
    final Duration idleTimeout = receiveTimeout > Duration.zero ? receiveTimeout : const Duration(seconds: 30);

    Future<void> closeRaf() async {
      if (rafClosed) {
        return;
      }
      rafClosed = true;
      await asyncWrite;
      if (raf != null) {
        await raf!.close().catchError((_) => raf!);
        raf = null;
      }
      _mainSendPort.send(SubIsolateMessage(SubIsolateMessageType.log, LogEvent(Level.debug, 'close download file')));
    }

    Future<void> terminate(SubIsolateMessage Function() messageBuilder, {bool forceCloseHttp = false}) async {
      if (finished) {
        return;
      }
      finished = true;
      idleTimer?.cancel();
      idleTimer = null;
      await subscription?.cancel().catchError((_) {});
      await closeRaf();
      if (forceCloseHttp || _closing) {
        // Close socket when aborting a stalled stream or shutting down the isolate.
        _dio?.close(force: true);
        _dio = null;
      }
      _inDownload = false;
      if (identical(_cancelToken, cancelToken)) {
        _cancelToken = null;
      }
      _mainSendPort.send(messageBuilder());
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      if (finished || _closing || cancelToken.isCancelled) {
        return;
      }
      idleTimer = Timer(idleTimeout, () {
        if (finished || _closing || cancelToken.isCancelled) {
          return;
        }
        terminate(
          () => SubIsolateMessage<JDownloadException>(
            SubIsolateMessageType.error,
            JDownloadException(
              JDownloadExceptionType.receiveDataFailed,
              error: DioException.receiveTimeout(
                timeout: idleTimeout,
                requestOptions: RequestOptions(path: url),
              ),
            ),
          ),
          forceCloseHttp: true,
        );
      });
    }

    resetIdleTimer();

    final Stream<Uint8List> stream = response.data!.stream;
    subscription = stream.listen(
      (Uint8List data) {
        if (finished || _closing || cancelToken.isCancelled) {
          return;
        }
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

        idleTimer?.cancel();
        subscription?.pause();
        asyncWrite = raf!.writeFrom(chunk).then((RandomAccessFile result) {
          writtenBytes += chunk.length;
          raf = result;
          if (!finished && !_closing && !cancelToken.isCancelled) {
            _mainSendPort.send(SubIsolateMessage<int>(SubIsolateMessageType.progress, chunk.length));
            resetIdleTimer();
            subscription?.resume();
          }
        }).catchError((Object e) {
          terminate(
            () => SubIsolateMessage<JDownloadException>(
              SubIsolateMessageType.error,
              JDownloadException(JDownloadExceptionType.writeDownloadFileFailed, error: e.toString()),
            ),
            forceCloseHttp: true,
          );
        });
      },
      onDone: () async {
        await asyncWrite;
        if (finished) {
          return;
        }
        if (_closing || cancelToken.isCancelled) {
          await terminate(() => SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
          return;
        }
        if (expectedBytes != null && writtenBytes < expectedBytes) {
          await terminate(
            () => SubIsolateMessage<JDownloadException>(
              SubIsolateMessageType.error,
              JDownloadException(
                JDownloadExceptionType.receiveDataFailed,
                error: 'Unexpected EOF: expected $expectedBytes bytes, got $writtenBytes bytes',
              ),
            ),
          );
          return;
        }
        await terminate(() => SubIsolateMessage<Null>(SubIsolateMessageType.done, null));
      },
      onError: (Object e) {
        terminate(
          () => SubIsolateMessage<JDownloadException>(
            SubIsolateMessageType.error,
            JDownloadException(JDownloadExceptionType.receiveDataFailed, error: e.toString()),
          ),
        );
      },
      cancelOnError: true,
    );

    cancelToken.whenCancel.then((_) {
      terminate(() => SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
    });
  }

  DioException _statusException(String url, int statusCode, String? statusMessage) {
    final RequestOptions req = RequestOptions(path: url);
    return DioException.badResponse(
      statusCode: statusCode,
      requestOptions: req,
      response: Response<dynamic>(
        requestOptions: req,
        statusCode: statusCode,
        statusMessage: statusMessage,
      ),
    );
  }

  void _drainResponseQuietly(Response<ResponseBody> response) {
    try {
      response.data?.stream.listen((_) {}, onError: (_) {}).cancel();
    } catch (_) {}
  }
}

void subIsolateEntryPoint(SendPort mainSendPort) {
  SubIsolateManager(mainSendPort: mainSendPort);
}
