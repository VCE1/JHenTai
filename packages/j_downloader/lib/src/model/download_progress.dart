import 'dart:convert';
import 'dart:typed_data';

import 'package:j_downloader/src/model/download_chunk.dart';

class DownloadProgress {
  final String url;

  final String savePath;

  final int totalBytes;

  final List<DownloadTrunk> chunks;

  const DownloadProgress({
    required this.url,
    required this.savePath,
    required this.totalBytes,
    required this.chunks,
  });

  Uint8List get toBuffer {
    Uint8List buffer = utf8.encode(jsonEncode(this));
    return Uint8List.fromList([buffer.length & 0xFF, buffer.length >> 8] + buffer);
  }

  String toMetaJson() => jsonEncode(toJson());

  static DownloadProgress? tryParseBuffer(Uint8List buffer) {
    try {
      if (buffer.length < 2) {
        return null;
      }
      final int length = buffer[0] + (buffer[1] << 8);
      if (length <= 0 || 2 + length > buffer.length) {
        return null;
      }
      final dynamic decoded = jsonDecode(utf8.decode(buffer.sublist(2, 2 + length)));
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      return _fromValidatedJson(decoded);
    } catch (_) {
      return null;
    }
  }

  static DownloadProgress? tryParseMetaJson(String content) {
    try {
      if (content.trim().isEmpty) {
        return null;
      }
      final dynamic decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      return _fromValidatedJson(decoded);
    } catch (_) {
      return null;
    }
  }

  static DownloadProgress? _fromValidatedJson(Map<String, dynamic> json) {
    final DownloadProgress progress = DownloadProgress.fromJson(json);
    if (progress.url.isEmpty || progress.savePath.isEmpty || progress.totalBytes < 0 || progress.chunks.isEmpty) {
      return null;
    }
    for (final DownloadTrunk chunk in progress.chunks) {
      if (chunk.downloadedBytes < 0 || (chunk.size >= 0 && chunk.downloadedBytes > chunk.size)) {
        return null;
      }
    }
    return progress;
  }

  factory DownloadProgress.fromBuffer(Uint8List buffer) {
    final DownloadProgress? parsed = tryParseBuffer(buffer);
    if (parsed == null) {
      throw const FormatException('Invalid DownloadProgress metadata buffer');
    }
    return parsed;
  }

  factory DownloadProgress.fromJson(Map<String, dynamic> json) {
    final dynamic rawChunks = json['chunks'];
    final List<dynamic> chunkList = rawChunks is String ? jsonDecode(rawChunks) as List<dynamic> : rawChunks as List<dynamic>;
    return DownloadProgress(
      url: json['url'] as String,
      savePath: json['savePath'] as String,
      totalBytes: json['totalBytes'] as int,
      chunks: chunkList.map((dynamic e) => DownloadTrunk.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'savePath': savePath,
      'totalBytes': totalBytes,
      'chunks': chunks.map((DownloadTrunk c) => c.toJson()).toList(),
    };
  }

  @override
  String toString() {
    return 'DownloadProgress{url: $url, savePath: $savePath, totalBytes: $totalBytes, chunks: $chunks}';
  }
}
