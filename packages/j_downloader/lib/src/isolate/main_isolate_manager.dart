import 'dart:async';
import 'dart:isolate';

import 'package:j_downloader/src/exception/j_download_exception.dart';
import 'package:j_downloader/src/isolate/sub_ioslate_manager.dart';
import 'package:j_downloader/src/model/main_isolate_message.dart';
import 'package:j_downloader/src/model/proxy_config.dart';
import 'package:j_downloader/src/model/sub_isolate_message.dart';
import 'package:j_downloader/src/function/function.dart';
import 'package:logger/logger.dart';

class MainIsolateManager {
  final ProxyConfig? _proxyConfig;
  final Logger _logger;

  bool _ready = false;

  bool get ready => _ready;
  Isolate? _isolate;
  ReceivePort? _mainReceivePort;
  SendPort? _subSendPort;

  bool _free = true;

  bool get free => _free;
  
  VoidCallback? _onReady;
  ValueCallback<({int statusCode, int? contentLength, bool resetFromStart})>? _onResponseStarted;
  ValueCallback? _onProgress;
  VoidCallback? _onDone;
  ValueCallback<JDownloadException>? _onError;

  Completer<void>? _closeCompleter;

  MainIsolateManager({ProxyConfig? proxyConfig, required Logger logger})
      : _proxyConfig = proxyConfig,
        _logger = logger;

  Future<void> initIsolate() async {
    if (_ready) {
      return;
    }

    _mainReceivePort = ReceivePort();

    try {
      _isolate = await Isolate.spawn(subIsolateEntryPoint, _mainReceivePort!.sendPort);
    } catch (e) {
      _mainReceivePort!.close();
      rethrow;
    }

    _isolate!.addOnExitListener(_mainReceivePort!.sendPort);

    _mainReceivePort!.listen((message) {
      message ??= SubIsolateMessage<Null>(SubIsolateMessageType.closed, null);

      if (message.type != SubIsolateMessageType.log) {
        _logger.log(message.type == SubIsolateMessageType.progress ? Level.trace : Level.debug, message);
      }

      switch (message.type) {
        case SubIsolateMessageType.created:
          message = message as SubIsolateMessage<SendPort>;
          _subSendPort = message.data;
          _subSendPort!.send(
            MainIsolateMessage<ProxyConfig?>(
              MainIsolateMessageType.init,
              _proxyConfig,
            ),
          );
          break;
        case SubIsolateMessageType.inited:
          _ready = true;
          _free = true;
          _onReady?.call();
          break;
        case SubIsolateMessageType.responseStarted:
          message = message as SubIsolateMessage<({int statusCode, int? contentLength, bool resetFromStart})>;
          _onResponseStarted?.call(message.data);
          break;
        case SubIsolateMessageType.progress:
          message = message as SubIsolateMessage<int>;
          _onProgress?.call(message.data);
          break;
        case SubIsolateMessageType.error:
          message = message as SubIsolateMessage;
          _free = true;
          _onError?.call(message.data);
          break;
        case SubIsolateMessageType.done:
          _free = true;
          _onDone?.call();
          break;
        case SubIsolateMessageType.closeReady:
        case SubIsolateMessageType.closed:
          final bool exitedUnexpectedly = message.type == SubIsolateMessageType.closed && !_free && _closeCompleter == null;
          _mainReceivePort?.close();
          _isolate?.kill();
          _isolate = null;
          _subSendPort = null;
          _ready = false;
          _free = true;
          if (_closeCompleter != null && !_closeCompleter!.isCompleted) {
            _closeCompleter!.complete();
          }
          _closeCompleter = null;
          if (exitedUnexpectedly) {
            _onError?.call(
              JDownloadException(
                JDownloadExceptionType.downloadFailed,
                error: 'Download isolate exited unexpectedly',
              ),
            );
          }
          break;
        case SubIsolateMessageType.log:
          message = message as SubIsolateMessage<LogEvent>;
          _logger.log(
            message.data.level,
            message.data.message,
            time: message.data.time,
            error: message.data.error,
            stackTrace: message.data.stackTrace,
          );
          break;
        default:
          break;
      }
    });
  }

  void beginDownload(
    String url,
    String downloadPath,
    ({int start, int end})? downloadRange,
    int fileWriteOffset,
    int dataOffset,
    Duration connectionTimeout,
    Duration receiveTimeout,
  ) {
    assert(_isolate != null && _mainReceivePort != null && _subSendPort != null && _ready);

    if (!_free || _closeCompleter != null) {
      return;
    }
    _free = false;

    _subSendPort!.send(
      MainIsolateMessage(
        MainIsolateMessageType.download,
        (
          url: url,
          downloadPath: downloadPath,
          downloadRange: downloadRange,
          fileWriteOffset: fileWriteOffset,
          dataOffset: dataOffset,
          connectionTimeout: connectionTimeout,
          receiveTimeout: receiveTimeout,
        ),
      ),
    );
  }

  Future<void> killIsolate() async {
    if (_isolate == null || _mainReceivePort == null) {
      return;
    }
    if (!_ready) {
      _mainReceivePort?.close();
      _isolate?.kill();
      _isolate = null;
      _subSendPort = null;
      _free = true;
      return;
    }

    _closeCompleter ??= Completer();
    _subSendPort!.send(MainIsolateMessage(MainIsolateMessageType.close, null));
    return _closeCompleter!.future;
  }

  void registerOnReady(VoidCallback onReady) {
    _onReady = onReady;
  }

  void unRegisterOnReady() {
    _onReady = null;
  }

  void registerOnResponseStarted(ValueCallback<({int statusCode, int? contentLength, bool resetFromStart})> onResponseStarted) {
    _onResponseStarted = onResponseStarted;
  }

  void unRegisterOnResponseStarted() {
    _onResponseStarted = null;
  }

  void registerOnProgress(ValueCallback onProgress) {
    _onProgress = onProgress;
  }

  void unRegisterOnProgress() {
    _onProgress = null;
  }

  void registerOnDone(VoidCallback onDone) {
    _onDone = onDone;
  }

  void unRegisterOnDone() {
    _onDone = null;
  }

  void registerOnError(ValueCallback<JDownloadException> onError) {
    _onError = onError;
  }

  void unRegisterOnError() {
    _onError = null;
  }
}
