import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_socks_proxy/socks_proxy.dart';
import 'package:j_downloader/j_downloader.dart';
import 'package:j_downloader/src/extension/file_extension.dart';
import 'package:j_downloader/src/file/file_manager.dart';
import 'package:j_downloader/src/function/function.dart';
import 'package:j_downloader/src/isolate/main_isolate_manager.dart';
import 'package:j_downloader/src/model/download_chunk.dart';
import 'package:j_downloader/src/model/download_progress.dart';
import 'package:j_downloader/src/util/lock.dart';
import 'package:j_downloader/src/util/log_output.dart';
import 'package:logger/logger.dart';
import 'package:retry/retry.dart';

typedef AsyncVoidCallback<T> = Future Function();

class DownloadManager {
  final String url;
  final String downloadPath;
  final String savePath;

  ProxyConfig? proxyConfig;

  late int _isolateCount;

  late final Dio _dio;

  int totalBytes = 0;

  bool _fileReady = false;
  bool _needsFileReset = false;
  late FileManager _fileManager;

  bool _chunksReady = false;
  bool _rangeSupported = true;
  bool _rangeVerified = false;
  List<DownloadTrunk> _chunks = [];
  List<bool> _chunksBusy = [];

  int get currentBytes => _chunks.fold(0, (previousValue, element) => previousValue + element.downloadedBytes);

  bool _isolatesReady = false;
  final List<MainIsolateManager> _isolates = [];
  final Map<MainIsolateManager, int> _isolateChunkIndex = {};

  int get activeIsolateCount => _isolates.where((i) => i.ready).length;

  final Lock _statusChangeLock = Lock();

  DownloadProgressCallback? _onProgress;
  VoidCallback? _onDone;
  ValueCallback<JDownloadException>? _onError;

  final JDownloadLogOutput _logOutput = JDownloadLogOutput();
  late final Logger _logger = Logger(output: _logOutput);

  static const int _preservedMetadataHeaderSize = 1024 * 16;

  static const String _copySuffix = '.jdcopy';

  DownloadManager({
    required this.url,
    required this.downloadPath,
    required this.savePath,
    required int isolateCount,
    required Duration connectionTimeout,
    required Duration receiveTimeout,
  }) : _isolateCount = isolateCount {
    _dio = Dio(BaseOptions(connectTimeout: connectionTimeout, receiveTimeout: receiveTimeout));
    (_dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () => createProxyHttpClient()..findProxy = ProxyConfig.toFindProxy(proxyConfig);
  }

  void tryRecoverFromMetadata(bool deleteWhenUrlMismatch) {
    File downloadFile = File(downloadPath);
    if (!downloadFile.existsSync()) {
      return;
    }

    RandomAccessFile? raf;
    Uint8List metadataHeader;
    try {
      raf = downloadFile.openSync(mode: FileMode.read);
      metadataHeader = raf.readSync(_preservedMetadataHeaderSize);
      raf.closeSync();
    } on Exception catch (e) {
      raf?.closeSync();
      downloadFile.deleteSyncIgnoreError();
      return;
    }

    DownloadProgress progress = DownloadProgress.fromBuffer(metadataHeader);
    if (progress.url != url && deleteWhenUrlMismatch) {
      downloadFile.deleteSyncIgnoreError();
      return;
    }

    totalBytes = progress.totalBytes;
    _chunks = progress.chunks;
    _chunksBusy = List.generate(_chunks.length, (_) => false);
    _chunksReady = true;
  }

  Future<void> start() {
    return _statusChangeLock.lock(() async {
      await _initTrunks();

      await _preCreateDownloadFile();

      await _startIsolates();

      await _tryHandleTrunks();
    });
  }

  Future<void> pause() {
    return _statusChangeLock.lock(_killIsolates);
  }

  Future<void> dispose() async {
    return _statusChangeLock.lock(() async {
      await _killIsolates();

      if (_fileReady) {
        await _fileManager.close();
        _fileReady = false;
      }

      File downloadFile = File(downloadPath);
      if (await downloadFile.exists()) {
        await downloadFile.delete();
      }

      _chunks.clear();
      _chunksBusy.clear();
      _chunksReady = false;
      _rangeSupported = true;
      _rangeVerified = false;
      _needsFileReset = false;
      _isolateChunkIndex.clear();
      totalBytes = 0;

      unRegisterOnProgress();
      unRegisterOnDone();
      unRegisterOnError();
      unRegisterOnLog();
    });
  }

  Future<void> changeIsolateCount(int count) async {
    if (_isolateCount == count) {
      return;
    }

    bool wasRunning = _isolatesReady;

    await _statusChangeLock.lock(() async {
      await _killIsolates();

      _isolateCount = count;

      /// add chunk if uncompleted chunk is less than isolate count
      if (_rangeSupported && _chunksReady && _chunks.where((c) => !c.completed).length < _isolateCount && !_chunks.every((chunk) => chunk.completed)) {
        List<DownloadTrunk> newChunks = [];

        for (int i = 0; i < _chunks.length; i++) {
          if (_chunks[i].downloadedBytes != 0) {
            newChunks.add(
              DownloadTrunk(size: _chunks[i].downloadedBytes, downloadedBytes: _chunks[i].downloadedBytes),
            );
          }
          if (_chunks[i].downloadedBytes != _chunks[i].size) {
            newChunks.add(
              DownloadTrunk(size: _chunks[i].size - _chunks[i].downloadedBytes),
            );
          }
        }

        while (newChunks.where((c) => !c.completed).length < _isolateCount) {
          int largestUnCompletedChunkIndex = -1;
          int largestUnCompletedChunkSize = 0;
          for (int i = 0; i < newChunks.length; i++) {
            if (newChunks[i].completed) {
              continue;
            }
            if (newChunks[i].size > largestUnCompletedChunkSize) {
              largestUnCompletedChunkIndex = i;
              largestUnCompletedChunkSize = newChunks[i].size;
            }
          }

          if (largestUnCompletedChunkIndex == -1 || largestUnCompletedChunkSize <= 1) {
            break;
          }

          newChunks[largestUnCompletedChunkIndex] = DownloadTrunk(size: largestUnCompletedChunkSize ~/ 2);
          newChunks.insert(largestUnCompletedChunkIndex + 1, DownloadTrunk(size: largestUnCompletedChunkSize - largestUnCompletedChunkSize ~/ 2));
        }

        _chunks = newChunks;
        _chunksBusy = List.generate(_chunks.length, (_) => false);

        if (_fileReady) {
          await _storeCurrentDownloadProgress();
        }
      }
    });

    if (wasRunning) {
      return start();
    }
  }

  Future<void> changeConnectionTimeout(Duration duration) async {
    _dio.options = _dio.options.copyWith(sendTimeout: duration);
  }

  Future<void> changeReceiveTimeout(Duration duration) async {
    _dio.options = _dio.options.copyWith(receiveTimeout: duration);
  }

  void registerOnProgress(DownloadProgressCallback callback) {
    _onProgress = callback;
  }

  void unRegisterOnProgress() {
    _onProgress = null;
  }

  void registerOnDone(VoidCallback callback) {
    _onDone = callback;
  }

  void unRegisterOnDone() {
    _onDone = null;
  }

  void registerOnError(ValueCallback callback) {
    _onError = callback;
  }

  void unRegisterOnError() {
    _onError = null;
  }

  void registerOnLog(JDownloadLogCallback callback) {
    _logOutput.registerCallBack(callback);
  }

  void unRegisterOnLog() {
    _logOutput.unregisterCallBack();
  }

  void _resetToSingleStream() {
    totalBytes = 0;
    _rangeSupported = false;
    _rangeVerified = true;
    _chunks = [DownloadTrunk(size: -1)];
    _chunksBusy = [false];
    _chunksReady = true;
    _needsFileReset = true;
  }

  Future<void> _initTrunks() async {
    if (_chunksReady) {
      if (_chunks.every((chunk) => chunk.completed)) {
        _rangeVerified = true;
        return;
      }
      if (_isolateCount <= 1 || _chunks.any((chunk) => chunk.size < 0)) {
        if (!(_chunks.length == 1 && _chunks[0].size == -1 && _chunks[0].downloadedBytes == 0 && !_rangeSupported)) {
          _resetToSingleStream();
        }
        return;
      }
      _rangeSupported = true;
      _rangeVerified = false;
      return;
    }

    if (_isolateCount <= 1) {
      _resetToSingleStream();
      return;
    }

    Response response;

    try {
      response = await retry(
        () => _dio.head(url),
        maxAttempts: 3,
        retryIf: (e) => e is DioException && (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.sendTimeout || e.type == DioExceptionType.receiveTimeout),
      );
    } on DioException catch (e) {
      final int? statusCode = e.response?.statusCode;
      if (statusCode == HttpStatus.methodNotAllowed || statusCode == HttpStatus.notImplemented) {
        _logger.w('HEAD not supported ($statusCode), falling back to single-stream GET without Range');
        _resetToSingleStream();
        return;
      }
      throw JDownloadException(JDownloadExceptionType.fetchContentLengthFailed, error: e);
    }

    int? contentLength = int.tryParse(response.headers.value(HttpHeaders.contentLengthHeader) ?? '');
    final String? acceptRanges = response.headers.value(HttpHeaders.acceptRangesHeader)?.toLowerCase();
    if (contentLength == null || contentLength <= 0 || acceptRanges == 'none') {
      _resetToSingleStream();
      return;
    }

    final int chunkCount = min(_isolateCount, contentLength);
    if (chunkCount <= 1) {
      _resetToSingleStream();
      return;
    }

    totalBytes = contentLength;
    _rangeSupported = true;
    _rangeVerified = false;

    _chunks = List.generate(
      chunkCount,
      (index) => DownloadTrunk(
        size: index != chunkCount - 1 ? contentLength ~/ chunkCount : contentLength - (chunkCount - 1) * (contentLength ~/ chunkCount),
      ),
    );
    _chunksBusy = List.generate(_chunks.length, (_) => false);

    _chunksReady = true;
  }

  Future<void> _startIsolates() async {
    if (_isolatesReady) {
      return;
    }

    _isolates.clear();

    try {
      List<Completer<void>> readyCompleters = List.generate(min(_isolateCount, _chunks.where((c) => !c.completed).length), (_) => Completer<void>());
      for (int i = 0; i < readyCompleters.length; i++) {
        MainIsolateManager isolateManager = MainIsolateManager(proxyConfig: proxyConfig, logger: _logger)
          ..registerOnReady(readyCompleters[i].complete)
          ..initIsolate();
        _isolates.add(isolateManager);
      }

      await Future.wait(readyCompleters.map((e) => e.future));
    } on Exception catch (e) {
      await _killIsolates();
      _isolates.clear();
      throw JDownloadException(JDownloadExceptionType.startIsolateFailed, error: e);
    }

    for (MainIsolateManager isolate in _isolates) {
      isolate.unRegisterOnReady();
    }

    _isolatesReady = true;
  }

  Future<void> _tryHandleTrunks() async {
    if (_chunks.every((chunk) => chunk.completed)) {
      _completeDownloadFile();
      return;
    }

    nextIsolate:
    for (MainIsolateManager isolate in _isolates) {
      if (!isolate.free) {
        continue;
      }

      if (!_rangeVerified && _chunksBusy.any((busy) => busy)) {
        break;
      }

      for (int i = 0; i < _chunks.length; i++) {
        if (_chunks[i].completed) {
          continue;
        }
        if (_chunksBusy[i]) {
          continue;
        }

        _isolateChunkIndex[isolate] = i;
        _chunksBusy[i] = true;

        isolate
          ..registerOnResponseStarted((info) {
            _handleChunkResponseStarted(isolate, info);
          })
          ..registerOnProgress((value) {
            final int? chunkIndex = _isolateChunkIndex[isolate];
            if (chunkIndex != null) {
              _handleChunkDownloadProgress(isolate, chunkIndex, value);
            }
          })
          ..registerOnDone(() {
            final int? chunkIndex = _isolateChunkIndex.remove(isolate);
            if (chunkIndex != null) {
              _handleChunkDownloadComplete(isolate, chunkIndex);
            }
          })
          ..registerOnError((JDownloadException error) {
            final int? chunkIndex = _isolateChunkIndex.remove(isolate);
            if (chunkIndex != null) {
              _handleChunkDownloadError(isolate, chunkIndex, error);
            }
          });

        isolate.beginDownload(
          url,
          downloadPath,
          _rangeSupported ? _computeChunkDownloadRange(_chunks, i) : null,
          _computeFileWriteOffset(_chunks, i),
          _preservedMetadataHeaderSize,
        );

        continue nextIsolate;
      }

      isolate.killIsolate();
    }
  }

  Future<void> _preCreateDownloadFile() async {
    if (_fileReady) {
      if (_needsFileReset) {
        try {
          await _storeCurrentDownloadProgress();
          await _fileManager.truncate(_preservedMetadataHeaderSize + totalBytes);
          _needsFileReset = false;
        } on Exception catch (e) {
          throw JDownloadException(JDownloadExceptionType.preCreateDownloadFileFailed, error: e);
        }
      }
      return;
    }

    try {
      File downloadFile = File(downloadPath);
      if (!await downloadFile.exists()) {
        await downloadFile.create(recursive: true);
      }

      _fileManager = FileManager(path: downloadPath, logger: _logger);

      await _storeCurrentDownloadProgress();

      await _fileManager.truncate(_preservedMetadataHeaderSize + totalBytes);

      _fileReady = true;
      _needsFileReset = false;
    } on Exception catch (e) {
      throw JDownloadException(JDownloadExceptionType.preCreateDownloadFileFailed, error: e);
    }
  }

  int _computeFileWriteOffset(List<DownloadTrunk> chunks, int i) {
    int offset = 0;
    for (int j = 0; j < i; j++) {
      offset += chunks[j].size;
    }

    return _preservedMetadataHeaderSize + offset + chunks[i].downloadedBytes;
  }

  ({int start, int end}) _computeChunkDownloadRange(List<DownloadTrunk> chunks, int i) {
    int start = 0;
    for (int j = 0; j < i; j++) {
      start += chunks[j].size;
    }

    int end = start + chunks[i].size;
    start = start + chunks[i].downloadedBytes;

    return (start: start, end: end);
  }

  Future<void> _killIsolates() async {
    List<Future> killFutures = _isolates.map((e) => e.killIsolate()).toList();

    for (MainIsolateManager isolate in _isolates) {
      isolate.unRegisterOnResponseStarted();
      isolate.unRegisterOnProgress();
      isolate.unRegisterOnDone();
      isolate.unRegisterOnError();
    }

    _isolateChunkIndex.clear();
    _chunksBusy = List.generate(_chunks.length, (_) => false);
    _isolatesReady = false;

    await Future.wait(killFutures);

    _isolates.clear();
  }

  void _handleChunkResponseStarted(
    MainIsolateManager isolate,
    ({int statusCode, int? contentLength, bool resetFromStart}) info,
  ) {
    if (info.resetFromStart) {
      _rangeSupported = false;
      _rangeVerified = true;

      final int resolvedSize = (info.contentLength != null && info.contentLength! >= 0)
          ? info.contentLength!
          : (totalBytes > 0 ? totalBytes : -1);
      totalBytes = resolvedSize > 0 ? resolvedSize : (info.contentLength == 0 ? 0 : totalBytes);

      _chunks = [DownloadTrunk(size: resolvedSize)];
      _chunksBusy = [true];
      _isolateChunkIndex
        ..clear()
        ..[isolate] = 0;

      _storeCurrentDownloadProgress();

      for (final MainIsolateManager other in _isolates) {
        if (other != isolate && other.free) {
          other.killIsolate();
        }
      }
      return;
    }

    if (!_rangeSupported) {
      if (info.contentLength != null && info.contentLength! >= 0) {
        totalBytes = info.contentLength!;
        _chunks = [DownloadTrunk(size: totalBytes)];
        _storeCurrentDownloadProgress();
      }
      return;
    }

    if (!_rangeVerified) {
      _rangeVerified = true;
      _tryHandleTrunks();
    }
  }

  void _handleChunkDownloadProgress(MainIsolateManager isolate, int chunkIndex, int newDownloadedBytes) {
    _chunks[chunkIndex].downloadedBytes += newDownloadedBytes;

    final int reportedTotal = totalBytes > 0 ? totalBytes : currentBytes;
    _onProgress?.call(currentBytes, reportedTotal);

    _storeCurrentDownloadProgress();
  }

  void _handleChunkDownloadComplete(MainIsolateManager isolate, int chunkIndex) {
    if (_chunks[chunkIndex].size < 0) {
      final int actualBytes = _chunks[chunkIndex].downloadedBytes;
      totalBytes = actualBytes;
      _chunks[chunkIndex] = DownloadTrunk(size: actualBytes, downloadedBytes: actualBytes);
      _onProgress?.call(currentBytes, totalBytes);
      _storeCurrentDownloadProgress();
    }

    assert(_chunks[chunkIndex].completed);

    _logger.d('chunk $chunkIndex done, size:${_chunks[chunkIndex].size}, bytes:${_chunks[chunkIndex].downloadedBytes}');

    _chunksBusy[chunkIndex] = false;

    _tryHandleTrunks();
  }

  Future<void> _handleChunkDownloadError(MainIsolateManager isolate, int chunkIndex, JDownloadException error) async {
    await _killIsolates();

    _onError?.call(error);
  }

  Future<void> _completeDownloadFile() async {
    assert(_chunks.every((chunk) => chunk.completed));

    File downloadFile = File(downloadPath);
    File saveFile = File(savePath + _copySuffix);
    IOSink? saveFileOutput;
    try {
      await _fileManager.close();
      _fileReady = false;

      await saveFile.create(recursive: true);

      Stream<List<int>> inputStream = downloadFile.openRead(_preservedMetadataHeaderSize, _preservedMetadataHeaderSize + totalBytes);
      saveFileOutput = saveFile.openWrite();

      await inputStream.forEach(saveFileOutput.add);
      await saveFileOutput.flush();
      await saveFileOutput.close();

      _logger.d('complete download file');
      await saveFile.rename(savePath);
      await downloadFile.delete();
    } on Exception catch (e) {
      await saveFileOutput?.close();
      _onError?.call(JDownloadException(JDownloadExceptionType.completeDownloadFileFailed, error: e));
      return;
    } finally {
      await _killIsolates();
    }

    _onDone?.call();
  }

  Future<void> _storeCurrentDownloadProgress() async {
    DownloadProgress progress = DownloadProgress(
      url: url,
      savePath: savePath,
      totalBytes: totalBytes,
      chunks: _chunks,
    );

    try {
      await _fileManager.writeFrom(progress.toBuffer, position: 0);
    } on Exception catch (e) {
      /// ignore error after download complete
    }
  }
}
