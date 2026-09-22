import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Downloads match clips to local files so playback seeks - rewind, scrubbing -
/// are instant.
///
/// WHY: `video_player` uses ExoPlayer on Android, which keeps a zero-length
/// back-buffer and discards data the moment it has played. So a STREAMED clip
/// re-fetches and re-decodes from scratch on every backward seek, which is the
/// "rewind feels slow" symptom. Seeking a LOCAL FILE is immediate.
///
/// Built on `dart:io` (HttpClient) + `path_provider` only - both already in the
/// project - so it adds no new dependency and none of the Android toolchain
/// risk this project keeps hitting.
///
/// The feed downloads the clip you are about to reach ahead of time (see the
/// prefetch calls in WatchFeedScreen), so by the time you land on a clip it is
/// already local and every seek is instant. A cache miss falls back to
/// streaming, so playback never depends on the cache.
class ClipCacheService {
  ClipCacheService._();
  static final ClipCacheService instance = ClipCacheService._();

  /// How many clip files to keep at once (~20MB each). Bounds disk use; the
  /// oldest are deleted past this. Comfortably more than the current + next
  /// couple of clips that are ever in use, so the playing file is never evicted.
  static const int _maxFiles = 6;

  Future<Directory>? _dirFuture;

  /// In-flight or just-completed downloads, keyed by URL. Dedups concurrent
  /// requests - the feed both prefetches a clip and loads it a moment later.
  final Map<String, Future<File>> _inFlight = {};

  Future<Directory> _dir() => _dirFuture ??= _createDir();

  Future<Directory> _createDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/clip_cache');
    // Start each session clean so cached clips don't accumulate across runs -
    // the feed is different every session anyway.
    if (await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
    await dir.create(recursive: true);
    return dir;
  }

  // A filename-safe key for a URL (which has query params and slashes).
  String _nameFor(String url) => 'clip_${url.hashCode & 0x7fffffff}.mp4';

  /// Returns a local file for [url], downloading it if necessary. Throws on
  /// failure so the caller can fall back to streaming.
  Future<File> getFile(String url) {
    final existing = _inFlight[url];
    if (existing != null) return existing;
    final future = _download(url);
    _inFlight[url] = future;
    future.whenComplete(() => _inFlight.remove(url));
    return future;
  }

  /// Warms the cache for a clip the viewer is about to reach. Best-effort -
  /// never throws.
  void prefetch(String url) {
    if (url.isEmpty) return;
    getFile(url).catchError((_) => File(''));
  }

  Future<File> _download(String url) async {
    final dir = await _dir();
    final file = File('${dir.path}/${_nameFor(url)}');
    if (await _hasData(file)) return file;
    // Download to a .part file and rename on completion, so a half-written
    // file is never handed to the player.
    final part = File('${file.path}.part');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('clip download HTTP ${resp.statusCode}',
            uri: Uri.parse(url));
      }
      final sink = part.openWrite();
      try {
        await resp.pipe(sink);
      } catch (e) {
        try {
          await sink.close();
        } catch (_) {}
        rethrow;
      }
      await part.rename(file.path);
      unawaited(_enforceCap(dir));
      return file;
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<bool> _hasData(File f) async {
    try {
      return await f.exists() && await f.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// Keeps only the [_maxFiles] most-recent clip files, deleting the oldest.
  /// The just-downloaded/currently-playing file is the newest, so it is never
  /// the one removed.
  Future<void> _enforceCap(Directory dir) async {
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.mp4'))
          .toList();
      if (files.length <= _maxFiles) return;
      files.sort(
          (a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      for (final f in files.take(files.length - _maxFiles)) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
