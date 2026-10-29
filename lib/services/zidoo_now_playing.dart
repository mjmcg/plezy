import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../exceptions/media_server_exceptions.dart';
import '../media/media_item.dart';
import '../media/media_server_client.dart';
import '../media/media_source_info.dart';
import '../utils/app_logger.dart';

/// What the native Zidoo player says it is playing, from the box's local
/// control API (`GET /ZidooVideoPlay/getPlayStatus`, documented at
/// apidoc.zidoo.tv). Positions are on the open file's clock, in milliseconds.
class ZidooPlayStatus {
  const ZidooPlayStatus({
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    this.path,
    this.audioIndex,
    this.subtitleIndex,
    this.output,
  });

  final int positionMs;
  final int durationMs;

  /// `video.status` is 1 while playing; the API pauses with 0.
  final bool playing;

  /// The open file's path: for a stream, the URL's path.
  final String? path;

  /// `audio.index` counts the file's audio streams from 0, the same as the
  /// player's `audio_idx` launch extra.
  final int? audioIndex;

  /// `subtitle.index` is 0 for off and counts the subtitle streams from 1,
  /// the same as the player's `subtitle_idx` launch extra.
  final int? subtitleIndex;

  /// The HDMI output, e.g. "3840X2160P @ 23.976Hz YUV422 12Bits HDR10".
  final String? output;

  /// Null unless the player has a video open: the API answers status 806
  /// ("The resource does not exist") when it has none.
  static ZidooPlayStatus? fromJson(Object? json) {
    if (json is! Map || _asInt(json['status']) != 200) return null;
    final video = json['video'];
    if (video is! Map) return null;
    final position = _asInt(video['currentPosition']);
    if (position == null) return null;
    final path = video['path'];
    final output = video['output'];
    return ZidooPlayStatus(
      positionMs: position,
      durationMs: _asInt(video['duration']) ?? 0,
      playing: _asInt(video['status']) == 1,
      path: path is String && path.isNotEmpty ? path : null,
      audioIndex: _index(json['audio']),
      subtitleIndex: _index(json['subtitle']),
      output: output is String && output.trim().isNotEmpty ? output.trim() : null,
    );
  }

  static int? _index(Object? stream) => stream is Map ? _asInt(stream['index']) : null;

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// The native Zidoo player's local control API, served by the box itself on
/// port 9529.
class ZidooPlayerApi {
  ZidooPlayerApi({http.Client? httpClient, this.baseUrl = 'http://127.0.0.1:9529'})
    : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String baseUrl;

  static const _timeout = Duration(seconds: 3);

  Future<ZidooPlayStatus?> playStatus() async {
    final response = await _http.get(Uri.parse('$baseUrl/ZidooVideoPlay/getPlayStatus')).timeout(_timeout);
    if (response.statusCode != 200) return null;
    return ZidooPlayStatus.fromJson(jsonDecode(response.body));
  }

  /// The names in [folder] on the box (folders and the videos the player can
  /// open), or null when the folder does not exist.
  Future<List<String>?> listFolder(String folder) async {
    final uri = Uri.parse(
      '$baseUrl/ZidooFileControl/getFileList',
    ).replace(queryParameters: {'path': folder, 'type': '0'});
    final response = await _http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) return null;
    final json = jsonDecode(response.body);
    if (json is! Map || ZidooPlayStatus._asInt(json['status']) != 200 || json['isExists'] != true) return null;
    final entries = json['filelist'];
    if (entries is! List) return const [];
    return [
      for (final entry in entries)
        if (entry is Map && entry['name'] is String) entry['name'] as String,
    ];
  }

  /// Stops playback, as the remote's stop key does.
  Future<void> stopPlayback() async {
    await _http.get(Uri.parse('$baseUrl/ZidooControlCenter/RemoteControl/sendkey?key=Key.MediaStop')).timeout(_timeout);
  }

  void close() => _http.close();
}

/// The file's own audio streams in the order the native Zidoo player counts
/// them: stream order, without external rows.
List<MediaAudioTrack> zidooAudioOrder(List<MediaAudioTrack> tracks) => _inStreamOrder([
  for (final track in tracks)
    if (!track.isExternal) track,
], (t) => t.index);

/// The file's own subtitle streams in the order the native Zidoo player counts
/// them. A sidecar is a separate file, so it is left out: Plex gives it a key,
/// Jellyfin flags it. A Jellyfin row delivered externally but stored in the
/// file still counts.
List<MediaSubtitleTrack> zidooSubtitleOrder(List<MediaSubtitleTrack> tracks) {
  bool isSidecar(MediaSubtitleTrack t) => t.isExternalFile || (!t.usesExternalDelivery && (t.key?.isNotEmpty ?? false));
  return _inStreamOrder([
    for (final track in tracks)
      if (!isSidecar(track)) track,
  ], (t) => t.index);
}

List<T> _inStreamOrder<T>(List<T> rows, int? Function(T) index) {
  if (rows.any((row) => index(row) == null)) return rows;
  return [...rows]..sort((a, b) => index(a)!.compareTo(index(b)!));
}

/// Saves a track the viewer picked in the native player as the item's
/// selection on the server, as Plex keeps it per file. Each call names one
/// track type; a [subtitleStreamId] of 0 is subtitles off.
typedef ZidooTrackPersister = Future<void> Function({int? audioStreamId, int? subtitleStreamId});

/// Reports playback in the native Zidoo player to the server while it runs,
/// so the server's dashboard (and Tautulli) shows it as playing, with its
/// position and paused state, instead of hearing nothing until the player
/// closes.
///
/// It reads the player's state from the box every [pollInterval]. A pause,
/// resume or track switch is reported straight away; otherwise the position
/// goes out every [reportInterval], the heartbeat Plex's own clients keep.
/// The first report is a started report, the rest progress reports, all under
/// [playSessionId]. The
/// stopped report that closes the session is sent by the caller from the
/// player's result, under the same id; [closeSession] covers a result that
/// never reports a position.
class ZidooNowPlayingReporter {
  ZidooNowPlayingReporter({
    required this.client,
    required this.metadata,
    required this.playSessionId,
    this.mediaSourceId,
    this.partStart = Duration.zero,
    this.itemDuration,
    List<MediaAudioTrack> audioTracks = const [],
    List<MediaSubtitleTrack> subtitleTracks = const [],
    this.persistTrack,
    ZidooPlayerApi? api,
    this.pollInterval = const Duration(seconds: 2),
    this.reportInterval = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _audioRows = zidooAudioOrder(audioTracks),
       _subtitleRows = zidooSubtitleOrder(subtitleTracks),
       _api = api ?? ZidooPlayerApi();

  final MediaServerClient client;
  final MediaItem metadata;
  final String playSessionId;
  final String? mediaSourceId;

  /// Where the handed-over file starts on a stacked item.
  final Duration partStart;

  /// The item's runtime; for a stacked item, all of its files together.
  final Duration? itemDuration;

  final ZidooTrackPersister? persistTrack;
  final Duration pollInterval;
  final Duration reportInterval;
  final DateTime Function() _clock;

  final List<MediaAudioTrack> _audioRows;
  final List<MediaSubtitleTrack> _subtitleRows;
  final ZidooPlayerApi _api;

  Timer? _timer;
  bool _busy = false;
  bool _stopped = false;
  bool _sessionOpen = false;
  bool _statusFailing = false;
  DateTime? _lastReportAt;
  ZidooPlayStatus? _last;

  /// The player's last position on the file's clock, for a result that
  /// carries none.
  int? get lastFilePositionMs => _last?.positionMs;

  /// Whether the server has a session open from this reporter.
  bool get sessionOpen => _sessionOpen;

  void start() {
    _timer ??= Timer.periodic(pollInterval, (_) => unawaited(tick()));
  }

  /// Ends polling and waits for a poll in flight.
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    _api.close();
  }

  /// Closes the server session at the last position read, for when the
  /// player's result will not.
  Future<void> closeSession() async {
    final last = _last;
    if (!_sessionOpen || last == null) return;
    _sessionOpen = false;
    try {
      await client.reportPlaybackStopped(
        itemId: metadata.id,
        position: _itemPosition(last),
        duration: _duration(last),
        playSessionId: playSessionId,
        mediaSourceId: mediaSourceId,
      );
    } catch (e) {
      appLogger.d('Zidoo player: closing the playback session failed', error: e);
    }
  }

  @visibleForTesting
  Future<void> tick() async {
    if (_stopped || _busy) return;
    _busy = true;
    try {
      final ZidooPlayStatus? status;
      try {
        status = await _api.playStatus();
      } catch (e) {
        if (!_statusFailing) appLogger.d('Zidoo player: status unavailable', error: e);
        _statusFailing = true;
        return;
      }
      _statusFailing = false;
      if (_stopped || status == null) return;
      final previous = _last;
      _last = status;
      if (previous == null) {
        appLogger.i('Zidoo player: playing ${metadata.id}, output ${status.output ?? 'unknown'}');
      }
      await _persistTrackChanges(previous, status);
      final now = _clock();
      final changed =
          previous == null ||
          previous.playing != status.playing ||
          previous.audioIndex != status.audioIndex ||
          previous.subtitleIndex != status.subtitleIndex;
      final lastReportAt = _lastReportAt;
      if (changed || lastReportAt == null || now.difference(lastReportAt) >= reportInterval) {
        _lastReportAt = now;
        await _report(status);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _report(ZidooPlayStatus status) async {
    final position = _itemPosition(status);
    final duration = _duration(status);
    final audio = _audioAt(status.audioIndex);
    final subtitle = status.subtitleIndex == 0 ? null : _subtitleAt(status.subtitleIndex);
    final subtitleStreamIndex = status.subtitleIndex == 0 ? -1 : subtitle?.id;
    try {
      if (!_sessionOpen) {
        await client.reportPlaybackStarted(
          itemId: metadata.id,
          position: position,
          duration: duration,
          playSessionId: playSessionId,
          playMethod: 'DirectPlay',
          mediaSourceId: mediaSourceId,
          audioStreamIndex: audio?.id,
          subtitleStreamIndex: subtitleStreamIndex,
        );
        _sessionOpen = true;
      } else if (duration != null) {
        await client.reportPlaybackProgress(
          itemId: metadata.id,
          position: position,
          duration: duration,
          isPaused: !status.playing,
          playSessionId: playSessionId,
          playMethod: 'DirectPlay',
          mediaSourceId: mediaSourceId,
          audioStreamIndex: audio?.id,
          subtitleStreamIndex: subtitleStreamIndex,
        );
      }
    } on PlaybackSessionTerminatedException catch (e) {
      // The server's owner stopped the stream from the dashboard: stop the
      // player too, as Plex's own clients do.
      appLogger.i('Zidoo player: the server ended playback of ${metadata.id} (${e.code}); stopping the player');
      _stopped = true;
      _sessionOpen = false;
      _timer?.cancel();
      try {
        await _api.stopPlayback();
      } catch (error) {
        appLogger.w('Zidoo player: could not stop playback', error: error);
      }
    } catch (e) {
      appLogger.d('Zidoo player: live playback report failed', error: e);
    }
  }

  /// A track the viewer switched to in the player becomes the server's
  /// selection. The first reading only sets the baseline: it is the track the
  /// player was launched on.
  Future<void> _persistTrackChanges(ZidooPlayStatus? previous, ZidooPlayStatus status) async {
    final persist = persistTrack;
    if (persist == null || previous == null) return;
    if (status.audioIndex != previous.audioIndex) {
      final audio = _audioAt(status.audioIndex);
      if (audio != null) await _persist(() => persist(audioStreamId: audio.id), 'audio');
    }
    if (status.subtitleIndex != previous.subtitleIndex) {
      // Plex's "no subtitle" stream id is 0.
      final subtitleId = status.subtitleIndex == 0 ? 0 : _subtitleAt(status.subtitleIndex)?.id;
      if (subtitleId != null) await _persist(() => persist(subtitleStreamId: subtitleId), 'subtitle');
    }
  }

  Future<void> _persist(Future<void> Function() save, String kind) async {
    try {
      await save();
    } catch (e) {
      appLogger.w('Zidoo player: could not save the $kind track the viewer picked', error: e);
    }
  }

  MediaAudioTrack? _audioAt(int? index) =>
      index != null && index >= 0 && index < _audioRows.length ? _audioRows[index] : null;

  /// Null for off and for a subtitle the server has no row for, such as one
  /// the player found itself.
  MediaSubtitleTrack? _subtitleAt(int? index) =>
      index != null && index >= 1 && index <= _subtitleRows.length ? _subtitleRows[index - 1] : null;

  Duration _itemPosition(ZidooPlayStatus status) {
    final position = partStart + Duration(milliseconds: status.positionMs);
    final duration = _duration(status);
    return duration != null && position > duration ? duration : position;
  }

  Duration? _duration(ZidooPlayStatus status) =>
      itemDuration ?? (status.durationMs > 0 ? Duration(milliseconds: status.durationMs) : null);
}
