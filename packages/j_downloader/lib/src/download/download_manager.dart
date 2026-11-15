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
  final String metadataPath;
  final String savePath;

  ProxyConfig? proxyConfig;

  late int _isolateCount;
  Duration _connectionTimeout;
  Duration _receiveTimeout;

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

  void _resetChunksBusy() {
    _chunksBusy = List<bool>.filled(_chunks.length, false, growable: true);
  }

  int get currentBytes => _chunks.fold(0, (previousValue, element) => previousValue + element.downloadedBytes);

  bool _isolatesReady = false;
  final List<MainIsolateManager> _isolates = [];
  final Map<MainIsolateManager, int> _isolateChunkIndex = {};
  final Map<int, int> _chunkRetryCounts = {};

  int get activeIsolateCount => _isolates.where((i) => i.ready).length;

  final Lock _statusChangeLock = Lock();
  bool _pausing = false;
  bool _disposed = false;
  bool _completing = false;

  bool _metadataDirty = false;
  Timer? _metadataTimer;
  Future<void>? _metadataWriteInFlight;

  DownloadProgressCallback? _onProgress;
  VoidCallback? _onDone;
  ValueCallback<JDownloadException>? _onError;

  final JDownloadLogOutput _logOutput = JDownloadLogOutput();
  late final Logger _logger = Logger(output: _logOutput);

  static const int _legacyMetadataHeaderSize = 1024 * 16;
  static const int _maxChunkRetries = 2;

  static const String _copySuffix = '.jdcopy';
  static const String _metaTmpSuffix = '.tmp';

  /// 0 for sidecar .jdmeta downloads; 16 KB only when resuming a legacy header-embedded .jdtemp file.
  int _dataOffset = 0;

  DownloadManager({
    required this.url,
    required this.downloadPath,
    required this.metadataPath,
    required this.savePath,
    required int isolateCount,
    required Duration connectionTimeout,
    required Duration receiveTimeout,
  })  : _isolateCount = isolateCount,
        _connectionTimeout = connectionTimeout,
        _receiveTimeout = receiveTimeout {
    _dio = Dio(BaseOptions(connectTimeout: connectionTimeout, receiveTimeout: receiveTimeout));
    (_dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient =
        () => createProxyHttpClient()..findProxy = ProxyConfig.toFindProxy(proxyConfig);
  }

  void _deleteTempFilesSync() {
    File(downloadPath).deleteSyncIgnoreError();
    File(metadataPath).deleteSyncIgnoreError();
    File('$metadataPath$_metaTmpSuffix').deleteSyncIgnoreError();
    File('$savePath$_copySuffix').deleteSyncIgnoreError();
  }

  void tryRecoverFromMetadata(bool deleteWhenUrlMismatch) {
    final File downloadFile = File(downloadPath);
    final File metaFile = File(metadataPath);

    if (metaFile.existsSync()) {
      if (!downloadFile.existsSync()) {
        _deleteTempFilesSync();
        return;
      }

      DownloadProgress? progress;
      try {
        progress = DownloadProgress.tryParseMetaJson(metaFile.readAsStringSync());
      } catch (_) {
        progress = null;
      }

      if (progress == null || (progress.url != url && deleteWhenUrlMismatch)) {
        _deleteTempFilesSync();
        return;
      }

      final int fileLength = downloadFile.lengthSync();
      if (progress.chunks.length > 1 && progress.totalBytes > 0 && fileLength < progress.totalBytes) {
        _deleteTempFilesSync();
        return;
      }
      if (progress.chunks.length == 1 && fileLength < progress.chunks[0].downloadedBytes) {
        progress.chunks[0].downloadedBytes = max(0, fileLength);
      }

      _dataOffset = 0;
      totalBytes = progress.totalBytes;
      _chunks = progress.chunks;
      _resetChunksBusy();
      _chunksReady = true;
      return;
    }

    if (!downloadFile.existsSync()) {
      return;
    }

    // Legacy 16 KB embedded-header recovery path for in-progress downloads from older versions.
    RandomAccessFile? raf;
    Uint8List metadataHeader;
    try {
      final int fileLength = downloadFile.lengthSync();
      if (fileLength < _legacyMetadataHeaderSize) {
        downloadFile.deleteSyncIgnoreError();
        return;
      }
      raf = downloadFile.openSync(mode: FileMode.read);
      metadataHeader = raf.readSync(_legacyMetadataHeaderSize);
      raf.closeSync();
      raf = null;
    } catch (_) {
      try {
        raf?.closeSync();
      } catch (_) {}
      downloadFile.deleteSyncIgnoreError();
      return;
    }

    final DownloadProgress? legacyProgress = DownloadProgress.tryParseBuffer(metadataHeader);
    if (legacyProgress == null || (legacyProgress.url != url && deleteWhenUrlMismatch)) {
      downloadFile.deleteSyncIgnoreError();
      return;
    }

    _dataOffset = _legacyMetadataHeaderSize;
    totalBytes = legacyProgress.totalBytes;
    _chunks = legacyProgress.chunks;
    _resetChunksBusy();
    _chunksReady = true;
  }

  Future<void> start() {
    return _statusChangeLock.lock(() async {
      if (_disposed) {
        return;
      }
      _pausing = false;
      _completing = false;
      _chunkRetryCounts.clear();

      await _initTrunks();

      await _preCreateDownloadFile();

      await _startIsolates();

      await _tryHandleTrunks();
    });
  }

  Future<void> pause() {
    _pausing = true;
    _metadataTimer?.cancel();
    _metadataTimer = null;
    return _statusChangeLock.lock(() async {
      await _killIsolates();
      if (_chunksReady) {
        await _saveMetadataNow();
      }
      if (_metadataWriteInFlight != null) {
        try {
          await _metadataWriteInFlight;
        } catch (_) {}
      }
      // Release OS handle while paused so Windows does not lock .jdtemp across task switches.
      if (_fileReady) {
        await _fileManager.close();
        _fileReady = false;
      }
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _pausing = true;
    _metadataTimer?.cancel();
    _metadataTimer = null;
    _metadataDirty = false;

    return _statusChangeLock.lock(() async {
      await _killIsolates();

      if (_metadataWriteInFlight != null) {
        try {
          await _metadataWriteInFlight;
        } catch (_) {}
      }

      if (_fileReady) {
        await _fileManager.close();
        _fileReady = false;
      }

      _deleteTempFilesSync();

      _chunks.clear();
      _chunksBusy.clear();
      _chunksReady = false;
      _rangeSupported = true;
      _rangeVerified = false;
      _needsFileReset = false;
      _dataOffset = 0;
      _isolateChunkIndex.clear();
      _chunkRetryCounts.clear();
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

    final bool wasRunning = _isolatesReady;

    await _statusChangeLock.lock(() async {
      await _killIsolates();

      _isolateCount = count;

      /// Add chunks if uncompleted chunk count is smaller than isolate count.
      if (_rangeSupported &&
          _chunksReady &&
          _chunks.where((c) => !c.completed).length < _isolateCount &&
          !_chunks.every((chunk) => chunk.completed)) {
        final List<DownloadTrunk> newChunks = [];

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
        _resetChunksBusy();
        _chunkRetryCounts.clear();

        if (_fileReady) {
          await _saveMetadataNow();
        }
      }
    });

    if (wasRunning && !_disposed && !_pausing) {
      return start();
    }
  }

  Future<void> changeConnectionTimeout(Duration duration) async {
    _connectionTimeout = duration;
    _dio.options = _dio.options.copyWith(connectTimeout: duration);
  }

  Future<void> changeReceiveTimeout(Duration duration) async {
    _receiveTimeout = duration;
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
    _dataOffset = 0;
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

      final bool hasKnownSizes = _chunks.every((c) => c.size > 0);
      if (hasKnownSizes && currentBytes > 0) {
        // Preserve resumable chunks even when _isolateCount == 1; server ignoring Range falls back safely to 200 OK.
        _rangeSupported = true;
        _rangeVerified = false;
        return;
      }

      if (_isolateCount <= 1) {
        if (!(_chunks.length == 1 && _chunks[0].size == -1 && _chunks[0].downloadedBytes == 0 && !_rangeSupported)) {
          _resetToSingleStream();
        }
        return;
      }

      _chunksReady = false;
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
        retryIf: (e) =>
            e is DioException &&
            (e.type == DioExceptionType.connectionTimeout ||
                e.type == DioExceptionType.sendTimeout ||
                e.type == DioExceptionType.receiveTimeout ||
                e.type == DioExceptionType.connectionError),
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

    final int? contentLength = int.tryParse(response.headers.value(HttpHeaders.contentLengthHeader) ?? '');
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

    _dataOffset = 0;
    totalBytes = contentLength;
    _rangeSupported = true;
    _rangeVerified = false;

    _chunks = List.generate(
      chunkCount,
      (index) => DownloadTrunk(
        size: index != chunkCount - 1 ? contentLength ~/ chunkCount : contentLength - (chunkCount - 1) * (contentLength ~/ chunkCount),
      ),
    );
    _resetChunksBusy();

    _chunksReady = true;
  }

  Future<void> _startIsolates() async {
    if (_isolatesReady) {
      return;
    }

    _isolates.clear();

    final int neededIsolates = min(_isolateCount, _chunks.where((c) => !c.completed).length);
    if (neededIsolates <= 0) {
      _isolatesReady = true;
      return;
    }

    try {
      final List<Completer<void>> readyCompleters = List.generate(neededIsolates, (_) => Completer<void>());
      for (int i = 0; i < readyCompleters.length; i++) {
        final MainIsolateManager isolateManager = MainIsolateManager(proxyConfig: proxyConfig, logger: _logger)
          ..registerOnReady(() {
            if (!readyCompleters[i].isCompleted) {
              readyCompleters[i].complete();
            }
          })
          ..initIsolate();
        _isolates.add(isolateManager);
      }

      await Future.wait(readyCompleters.map((e) => e.future));
    } catch (e) {
      await _killIsolates();
      _isolates.clear();
      throw JDownloadException(JDownloadExceptionType.startIsolateFailed, error: e);
    }

    for (final MainIsolateManager isolate in _isolates) {
      isolate.unRegisterOnReady();
    }

    _isolatesReady = true;
  }

  Future<void> _tryHandleTrunks() async {
    if (_pausing || _disposed || _completing) {
      return;
    }

    if (_chunks.every((chunk) => chunk.completed)) {
      await _completeDownloadFile();
      return;
    }

    nextIsolate:
    for (final MainIsolateManager isolate in _isolates) {
      if (!isolate.free) {
        continue;
      }

      if (!_rangeVerified && _chunksBusy.any((busy) => busy)) {
        break;
      }

      for (int i = 0; i < _chunks.length; i++) {
        if (_chunks[i].completed || _chunksBusy[i]) {
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
              _handleChunkDownloadProgress(isolate, chunkIndex, value as int);
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
            } else if (!_pausing && !_disposed && !_completing) {
              _onError?.call(error);
            }
          });

        isolate.beginDownload(
          url,
          downloadPath,
          _rangeSupported ? _computeChunkDownloadRange(_chunks, i) : null,
          _computeFileWriteOffset(_chunks, i),
          _dataOffset,
          _connectionTimeout,
          _receiveTimeout,
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
          await _saveMetadataNow();
          await _fileManager.truncate(_dataOffset + totalBytes);
          _needsFileReset = false;
        } catch (e) {
          throw JDownloadException(JDownloadExceptionType.preCreateDownloadFileFailed, error: e);
        }
      }
      return;
    }

    try {
      final File downloadFile = File(downloadPath);
      if (!await downloadFile.exists()) {
        await downloadFile.create(recursive: true);
      }

      _fileManager = FileManager(path: downloadPath, logger: _logger);

      await _saveMetadataNow();

      await _fileManager.truncate(_dataOffset + totalBytes);

      _fileReady = true;
      _needsFileReset = false;
    } catch (e) {
      throw JDownloadException(JDownloadExceptionType.preCreateDownloadFileFailed, error: e);
    }
  }

  int _computeFileWriteOffset(List<DownloadTrunk> chunks, int i) {
    int offset = 0;
    for (int j = 0; j < i; j++) {
      offset += chunks[j].size;
    }

    return _dataOffset + offset + chunks[i].downloadedBytes;
  }

  ({int start, int end}) _computeChunkDownloadRange(List<DownloadTrunk> chunks, int i) {
    int start = 0;
    for (int j = 0; j < i; j++) {
      start += chunks[j].size;
    }

    final int end = start + chunks[i].size;
    start = start + chunks[i].downloadedBytes;

    return (start: start, end: end);
  }

  Future<void> _killIsolates() async {
    final List<Future<void>> killFutures = _isolates.map((e) => e.killIsolate()).toList();

    for (final MainIsolateManager isolate in _isolates) {
      isolate.unRegisterOnResponseStarted();
      isolate.unRegisterOnProgress();
      isolate.unRegisterOnDone();
      isolate.unRegisterOnError();
    }

    _isolateChunkIndex.clear();
    _resetChunksBusy();
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

      final int resolvedSize = (info.contentLength != null && info.contentLength! >= 0) ? info.contentLength! : -1;
      totalBytes = resolvedSize > 0 ? resolvedSize : 0;

      _chunks = [DownloadTrunk(size: resolvedSize)];
      _chunksBusy = [true];
      _chunkRetryCounts.clear();
      _isolateChunkIndex
        ..clear()
        ..[isolate] = 0;

      _markMetadataDirty(immediate: true);

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
        _markMetadataDirty(immediate: true);
      }
      return;
    }

    if (!_rangeVerified) {
      _rangeVerified = true;
      _tryHandleTrunks();
    }
  }

  void _handleChunkDownloadProgress(MainIsolateManager isolate, int chunkIndex, int newDownloadedBytes) {
    if (chunkIndex >= _chunks.length) {
      return;
    }
    _chunks[chunkIndex].downloadedBytes += newDownloadedBytes;
    if (_chunks[chunkIndex].size >= 0 && _chunks[chunkIndex].downloadedBytes > _chunks[chunkIndex].size) {
      _chunks[chunkIndex].downloadedBytes = _chunks[chunkIndex].size;
    }

    final int reportedTotal = totalBytes > 0 ? totalBytes : currentBytes;
    _onProgress?.call(currentBytes, reportedTotal);

    _markMetadataDirty();
  }

  Future<void> _handleChunkDownloadComplete(MainIsolateManager isolate, int chunkIndex) async {
    _chunkRetryCounts.remove(chunkIndex);

    if (chunkIndex < _chunks.length && _chunks[chunkIndex].size < 0) {
      final int actualBytes = _chunks[chunkIndex].downloadedBytes;
      totalBytes = actualBytes;
      _chunks[chunkIndex] = DownloadTrunk(size: actualBytes, downloadedBytes: actualBytes);
      _onProgress?.call(currentBytes, totalBytes);
      if (_fileReady) {
        await _fileManager.truncate(_dataOffset + totalBytes);
      }
    }

    if (chunkIndex >= _chunks.length) {
      return;
    }

    assert(_chunks[chunkIndex].completed);

    _logger.d('chunk $chunkIndex done, size:${_chunks[chunkIndex].size}, bytes:${_chunks[chunkIndex].downloadedBytes}');

    _chunksBusy[chunkIndex] = false;

    if (_chunks.every((chunk) => chunk.completed)) {
      await _completeDownloadFile();
      return;
    }

    _markMetadataDirty(immediate: true);
    await _tryHandleTrunks();
  }

  bool _isRetryableChunkError(int chunkIndex, JDownloadException error) {
    if (chunkIndex >= _chunks.length) {
      return false;
    }
    // Without Range support we can only retry safely before any bytes are lost on stream.
    final bool canResumeOffset = _rangeSupported || _chunks[chunkIndex].downloadedBytes == 0;
    if (!canResumeOffset) {
      return false;
    }

    if (error.type == JDownloadExceptionType.receiveDataFailed) {
      return true;
    }

    if (error.type == JDownloadExceptionType.downloadFailed) {
      final dynamic inner = error.error;
      if (inner is DioException) {
        final int? status = inner.response?.statusCode;
        if (status != null) {
          return status >= 500 || status == HttpStatus.requestTimeout;
        }
        return inner.type == DioExceptionType.connectionTimeout ||
            inner.type == DioExceptionType.sendTimeout ||
            inner.type == DioExceptionType.receiveTimeout ||
            inner.type == DioExceptionType.connectionError ||
            inner.type == DioExceptionType.unknown;
      }
    }

    return false;
  }

  Future<void> _handleChunkDownloadError(MainIsolateManager isolate, int chunkIndex, JDownloadException error) async {
    if (chunkIndex < _chunksBusy.length) {
      _chunksBusy[chunkIndex] = false;
    }

    if (_pausing || _disposed || _completing) {
      return;
    }

    final int attempt = (_chunkRetryCounts[chunkIndex] ?? 0) + 1;
    if (_isRetryableChunkError(chunkIndex, error) && attempt <= _maxChunkRetries) {
      _chunkRetryCounts[chunkIndex] = attempt;
      _logger.w('chunk $chunkIndex failed ($error), retry attempt $attempt/$_maxChunkRetries');
      await _saveMetadataNow();
      await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      if (_pausing || _disposed || _completing || !_isolatesReady) {
        return;
      }
      await _tryHandleTrunks();
      return;
    }

    await _killIsolates();
    await _saveMetadataNow();

    if (!_pausing && !_disposed && !_completing) {
      _onError?.call(error);
    }
  }

  Future<void> _completeDownloadFile() async {
    if (_completing || _disposed) {
      return;
    }
    assert(_chunks.every((chunk) => chunk.completed));
    _completing = true;
    _metadataTimer?.cancel();
    _metadataTimer = null;
    _metadataDirty = false;

    final File downloadFile = File(downloadPath);
    File? copyFile;
    IOSink? saveFileOutput;
    try {
      await _killIsolates();

      if (_metadataWriteInFlight != null) {
        try {
          await _metadataWriteInFlight;
        } catch (_) {}
      }

      if (_fileReady) {
        await _fileManager.close();
        _fileReady = false;
      }

      if (_dataOffset == 0) {
        final int actualLength = await downloadFile.length();
        if (actualLength != totalBytes) {
          final RandomAccessFile raf = await downloadFile.open(mode: FileMode.writeOnlyAppend);
          try {
            await raf.truncate(totalBytes);
          } finally {
            await raf.close();
          }
        }

        await File(savePath).parent.create(recursive: true);
        await downloadFile.rename(savePath);
        File(metadataPath).deleteSyncIgnoreError();
        File('$metadataPath$_metaTmpSuffix').deleteSyncIgnoreError();
        _logger.d('complete download file (zero-copy rename)');
      } else {
        copyFile = File('$savePath$_copySuffix');
        await copyFile.create(recursive: true);

        final Stream<List<int>> inputStream = downloadFile.openRead(_dataOffset, _dataOffset + totalBytes);
        saveFileOutput = copyFile.openWrite();

        await inputStream.forEach(saveFileOutput.add);
        await saveFileOutput.flush();
        await saveFileOutput.close();
        saveFileOutput = null;

        _logger.d('complete download file (legacy strip copy)');
        await copyFile.rename(savePath);
        downloadFile.deleteSyncIgnoreError();
        File(metadataPath).deleteSyncIgnoreError();
        File('$metadataPath$_metaTmpSuffix').deleteSyncIgnoreError();
      }
    } catch (e) {
      await saveFileOutput?.close();
      copyFile?.deleteSyncIgnoreError();
      _completing = false;
      _onError?.call(JDownloadException(JDownloadExceptionType.completeDownloadFileFailed, error: e));
      return;
    }

    _completing = false;
    _onDone?.call();
  }

  void _markMetadataDirty({bool immediate = false}) {
    if (_disposed || _completing) {
      return;
    }
    _metadataDirty = true;
    if (immediate) {
      _metadataTimer?.cancel();
      _metadataTimer = null;
      unawaited(_flushMetadata());
      return;
    }
    _metadataTimer ??= Timer(const Duration(milliseconds: 400), () {
      _metadataTimer = null;
      if (!_disposed && !_completing && _metadataDirty) {
        unawaited(_flushMetadata());
      }
    });
  }

  Future<void> _saveMetadataNow() {
    if (_disposed || _completing) {
      return Future<void>.value();
    }
    _metadataDirty = true;
    return _flushMetadata();
  }

  Future<void> _flushMetadata() {
    _metadataTimer?.cancel();
    _metadataTimer = null;
    if (_metadataWriteInFlight != null) {
      return _metadataWriteInFlight!;
    }
    if (!_metadataDirty) {
      return Future<void>.value();
    }

    late final Future<void> run;
    run = _runMetadataFlushLoop().whenComplete(() {
      if (identical(_metadataWriteInFlight, run)) {
        _metadataWriteInFlight = null;
      }
    });
    _metadataWriteInFlight = run;
    return run;
  }

  Future<void> _runMetadataFlushLoop() async {
    while (_metadataDirty && !_disposed && !_completing) {
      _metadataDirty = false;
      final List<DownloadTrunk> snapshot =
          _chunks.map((DownloadTrunk c) => DownloadTrunk(size: c.size, downloadedBytes: c.downloadedBytes)).toList();
      final DownloadProgress progress = DownloadProgress(
        url: url,
        savePath: savePath,
        totalBytes: totalBytes,
        chunks: snapshot,
      );

      try {
        if (_dataOffset == 0) {
          final File tmpFile = File('$metadataPath$_metaTmpSuffix');
          await tmpFile.parent.create(recursive: true);
          await tmpFile.writeAsString(progress.toMetaJson(), flush: true);
          if (!_disposed && !_completing) {
            await tmpFile.rename(metadataPath);
          } else {
            tmpFile.deleteSyncIgnoreError();
          }
        } else if (_fileReady) {
          await _fileManager.writeFrom(progress.toBuffer, position: 0);
        }
      } catch (_) {
        // Ignore transient write failures after completion or disposal.
      }
    }
  }
}
