import 'dart:async';
import 'dart:convert';
import '../media/ids.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../database/app_database.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_part_timeline.dart';
import '../media/media_server_client.dart';
import '../media/media_source_info.dart';
import '../media/watch_progress.dart';
import '../models/external_player_models.dart';
import '../mpv/models.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import '../utils/session_identifier.dart';
import '../utils/snackbar_helper.dart';
import '../utils/watch_state_notifier.dart';
import '../i18n/strings.g.dart';
import 'deep_links/deep_link.dart';
import 'settings_service.dart';
import 'offline_watch_sync_service.dart';
import 'playback_initialization_service.dart';
import 'plex_client.dart';
import 'trackers/tracker_coordinator.dart';
import 'zidoo_direct_paths.dart';
import 'zidoo_now_playing.dart';

const _externalPlayerChannel = MethodChannel('com.plezy/external_player');

class _ExternalPlayerLaunchResult {
  const _ExternalPlayerLaunchResult({
    required this.launched,
    this.positionMs,
    this.durationMs,
    this.playbackCompleted = false,
    this.playbackError = false,
  });

  final bool launched;
  final int? positionMs;
  final int? durationMs;
  final bool playbackCompleted;
  final bool playbackError;

  factory _ExternalPlayerLaunchResult.fromMap(Map<String, Object?>? map) {
    if (map == null) return const _ExternalPlayerLaunchResult(launched: true);
    return _ExternalPlayerLaunchResult(
      launched: map['launched'] == true,
      positionMs: _asInt(map['positionMs']),
      durationMs: _asInt(map['durationMs']),
      playbackCompleted: map['playbackCompleted'] == true,
      playbackError: map['playbackError'] == true,
    );
  }

  /// This result, with [positionMs] standing in for a position the player
  /// did not report. A finished playback keeps its own end position.
  _ExternalPlayerLaunchResult withFallbackPosition(int? positionMs) {
    if (this.positionMs != null || positionMs == null || playbackCompleted) return this;
    return _ExternalPlayerLaunchResult(
      launched: launched,
      positionMs: positionMs,
      durationMs: durationMs,
      playbackCompleted: playbackCompleted,
      playbackError: playbackError,
    );
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// The item an x-callback-url player was launched for, kept until the player
/// opens one of its return links.
class _CallbackSession {
  _CallbackSession({
    required this.id,
    required this.playerId,
    required this.metadata,
    required this.client,
    required this.offlineWatchService,
    required this.mediaSourceId,
    this.partTimeline,
  });

  final String id;
  final String playerId;
  final MediaItem metadata;
  final MediaServerClient? client;
  final OfflineWatchSyncService? offlineWatchService;
  final String? mediaSourceId;
  final MediaPartTimeline? partTimeline;
}

/// What an Android launch needs to report its result, kept by the native side
/// until the player answers. When the device reclaims Plezy while the player
/// is in front, the answer reaches a fresh process; this is all that process
/// knows about the item.
@visibleForTesting
class ExternalHandoffSession {
  const ExternalHandoffSession({
    required this.serverId,
    required this.itemId,
    this.itemDurationMs,
    this.partStartMs,
    this.partEndMs,
  });

  final String serverId;
  final String itemId;

  /// The item's runtime; for a stacked item, all of its files together.
  final int? itemDurationMs;

  /// The handed-over file's span on a stacked item; null for a single file.
  final int? partStartMs;
  final int? partEndMs;

  static ExternalHandoffSession? forItem(MediaItem item, MediaPartTimeline? partTimeline) {
    final serverId = item.serverId;
    if (serverId == null || serverId.isEmpty) return null;
    final part = partTimeline?.current;
    return ExternalHandoffSession(
      serverId: serverId,
      itemId: item.id,
      itemDurationMs: partTimeline?.duration.inMilliseconds ?? item.durationMs,
      partStartMs: part?.start.inMilliseconds,
      partEndMs: part?.end.inMilliseconds,
    );
  }

  String toJson() => jsonEncode({
    'serverId': serverId,
    'itemId': itemId,
    'itemDurationMs': ?itemDurationMs,
    'partStartMs': ?partStartMs,
    'partEndMs': ?partEndMs,
  });

  static ExternalHandoffSession? fromJson(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      final serverId = map['serverId'];
      final itemId = map['itemId'];
      if (serverId is! String || itemId is! String) return null;
      return ExternalHandoffSession(
        serverId: serverId,
        itemId: itemId,
        itemDurationMs: map['itemDurationMs'] as int?,
        partStartMs: map['partStartMs'] as int?,
        partEndMs: map['partEndMs'] as int?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// How playback in an x-callback-url player ended: the `<result>` of its
/// return link, `plezy://external-player/<result>/<session>`.
abstract final class _ReturnResult {
  static const success = 'success';
  static const cancel = 'cancel';
  static const error = 'error';
}

/// Traces the x-callback-url round trip with iOS external players.
void _callbackLog(String message) => appLogger.d('[ExternalPlayerCallback] $message');

/// Masks server tokens before a stream URL reaches the log.
String _redactTokens(String text) =>
    text.replaceAllMapped(RegExp(r'((?:X-Plex-Token|api_key|ApiKey)(?:=|%3D))[^&%]+', caseSensitive: false), (m) {
      return '${m[1]}<redacted>';
    });

class ExternalPlayerService {
  /// Only the latest launch can call back; a new launch replaces it.
  static _CallbackSession? _callbackSession;

  /// Launch an external player with either a pre-resolved [videoUrl] (the
  /// local file of a downloaded copy) or by asking [client] to resolve the
  /// stream for [metadata]. Each backend implements `resolveExternalPlayback`
  /// for the right URL shape (Plex part URL, Jellyfin
  /// `/Videos/{id}/stream.{container}?Static=true`) and its external
  /// subtitle files, which Android players receive through the intent.
  static Future<bool> launch({
    required BuildContext context,
    MediaItem? metadata,
    MediaServerClient? client,
    OfflineWatchSyncService? offlineWatchService,
    int mediaIndex = 0,
    String? mediaSourceId,
    String? videoUrl,
    bool Function()? isLaunchCurrent,
    VoidCallback? onHandoffPending,
    VoidCallback? onLaunched,
  }) async {
    if (!PlatformDetector.supportsExternalPlayers()) return false;
    bool current() => context.mounted && (isLaunchCurrent?.call() ?? true);
    if (!current()) return false;

    try {
      String resolvedUrl;
      var subtitles = const <SubtitleTrack>[];
      var audioTracks = const <MediaAudioTrack>[];
      var subtitleTracks = const <MediaSubtitleTrack>[];
      int? partId;
      String? serverFilePath;
      // An external player is handed one file. For an item stacked across
      // several files that is one part, on that part's clock.
      MediaPartTimeline? partTimeline;
      final resume = (metadata?.viewOffsetMs ?? 0) > 0 ? Duration(milliseconds: metadata!.viewOffsetMs!) : null;

      if (videoUrl != null) {
        resolvedUrl = videoUrl;
        // A downloaded copy is handed over as its first file.
        final versions = metadata?.mediaVersions;
        if (versions != null && mediaIndex >= 0 && mediaIndex < versions.length) {
          partTimeline = MediaPartTimeline.fromParts(versions[mediaIndex].parts);
        }
      } else if (client != null && metadata != null) {
        final target = await client.resolveExternalPlayback(
          metadata,
          mediaIndex: mediaIndex,
          mediaSourceId: mediaSourceId,
          position: resume,
        );
        if (target == null || target.url.isEmpty) {
          if (context.mounted) {
            showErrorSnackBar(context, t.messages.fileInfoNotAvailable);
          }
          return false;
        }
        resolvedUrl = target.url;
        subtitles = target.subtitles;
        partTimeline = target.partTimeline;
        audioTracks = target.audioTracks;
        subtitleTracks = target.subtitleTracks;
        partId = target.partId;
        serverFilePath = target.filePath;
      } else {
        appLogger.e('ExternalPlayerService.launch requires either videoUrl or client+metadata');
        return false;
      }
      final startPosition = partTimeline == null
          ? resume
          : resume != null && partTimeline.covers(resume)
          ? resume - partTimeline.current.start
          : null;

      final settings = await SettingsService.getInstance();
      if (!current()) return false;
      final player = settings.read(SettingsService.selectedExternalPlayer);
      // Nothing to hand off to: System Default on Apple TV is the case this
      // exists for, since it stays the stored default there.
      if (!player.isAvailable) {
        if (context.mounted) showErrorSnackBar(context, t.externalPlayer.launchFailed);
        return false;
      }

      // On Android, always use native intent to avoid url_launcher opening in browser
      if (Platform.isAndroid && context.mounted) {
        // A downloaded copy's subtitles are the sidecar files saved with it.
        if (videoUrl != null && metadata != null) {
          subtitles = await _downloadedSubtitles(
            context.read<AppDatabase>(),
            videoUrl,
            metadata: metadata,
            client: client,
            mediaIndex: mediaIndex,
          );
          if (!context.mounted || !current()) return false;
        }
        // The native Zidoo player can be followed while it plays, through
        // the box's control API, so the server shows it as playing.
        ZidooNowPlayingReporter? reporter;
        String? playSessionId;
        var directFile = false;
        if (KnownPlayers.isZidooPlayer(player.id) && client != null && metadata != null) {
          playSessionId = generateSessionIdentifier();
          if (player.id == KnownPlayers.zidooDirectPlayerId && videoUrl == null) {
            // The box reads the file from its own mount of the server's
            // share, so no server address or token reaches the player.
            final directPath = serverFilePath == null ? null : await _zidooDirectPath(serverFilePath, settings);
            if (!context.mounted || !current()) return false;
            if (directPath == null) {
              appLogger.w('Zidoo direct: no path mapping holds ${serverFilePath ?? 'a file the server did not name'}');
              if (context.mounted) showErrorSnackBar(context, t.externalPlayer.zidooNoPathMapping);
              return false;
            }
            appLogger.i('Zidoo direct: $serverFilePath -> $directPath');
            resolvedUrl = directPath;
            directFile = true;
            // The player finds subtitle files beside the video itself, and
            // the server's links to them would carry its token.
            subtitles = const [];
          } else if (client is PlexClient && videoUrl == null) {
            // The player shows its URL on screen and keeps it in its
            // history, so it gets a token that only works on this server
            // and soon lapses rather than the account's own.
            final transientToken = await client.createTransientToken();
            if (!context.mounted || !current()) return false;
            if (transientToken == null) {
              appLogger.w('Handing the Zidoo player this app\'s own Plex token: the server issued no transient one');
            } else {
              subtitles = [
                for (final track in subtitles)
                  track.uri == null ? track : track.copyWith(uri: plexUrlWithToken(track.uri!, transientToken)),
              ];
            }
            resolvedUrl = plexStreamUrlWithIdentity(
              resolvedUrl,
              client.streamHeaders,
              playSessionId,
              token: transientToken,
            );
          }
          reporter = ZidooNowPlayingReporter(
            client: client,
            metadata: metadata,
            playSessionId: playSessionId,
            mediaSourceId: mediaSourceId,
            partStart: partTimeline?.current.start ?? Duration.zero,
            itemDuration:
                partTimeline?.duration ??
                (metadata.durationMs == null ? null : Duration(milliseconds: metadata.durationMs!)),
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            persistTrack: _zidooTrackPersister(client, partId, settings.read(SettingsService.rememberTrackSelections)),
          );
        }
        onHandoffPending?.call();
        reporter?.start();
        _ExternalPlayerLaunchResult launchResult;
        try {
          launchResult = await _launchAndroidNative(
            resolvedUrl,
            player,
            context,
            metadata: metadata,
            startPosition: startPosition,
            subtitles: subtitles,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            session: metadata == null ? null : ExternalHandoffSession.forItem(metadata, partTimeline),
            keepAlive: reporter != null,
            directFile: directFile,
          );
        } finally {
          await reporter?.stop();
        }
        if (reporter != null) launchResult = launchResult.withFallbackPosition(reporter.lastFilePositionMs);
        if (launchResult.launched && current()) onLaunched?.call();
        var closedSession = false;
        if (launchResult.launched && metadata != null && current()) {
          closedSession = await _reportExternalProgress(
            launchResult,
            metadata: metadata,
            client: client,
            offlineWatchService: offlineWatchService,
            mediaSourceId: mediaSourceId,
            partTimeline: partTimeline,
            isLaunchCurrent: current,
            playSessionId: playSessionId,
          );
        }
        if (!closedSession) await reporter?.closeSession();
        return launchResult.launched;
      }

      if (!current()) return false;
      onHandoffPending?.call();
      final launchWithOptions = player.launchWithOptions;
      final bool launched;
      if (launchWithOptions != null && metadata != null) {
        final session = _beginCallbackSession(
          playerId: player.id,
          metadata: metadata,
          client: client,
          offlineWatchService: offlineWatchService,
          mediaSourceId: mediaSourceId,
          partTimeline: partTimeline,
        );
        final options = ExternalPlayerLaunchOptions(
          startPosition: startPosition,
          returnLinks: returnLinks(session.id),
          filename: playerFilename(metadata, resolvedUrl),
        );
        _callbackLog(
          'launching ${player.id} for ${metadata.id} (session ${session.id}, '
          'startPosition $startPosition, durationMs ${metadata.durationMs}): ${_redactTokens(resolvedUrl)}',
        );
        final playerUri = KnownPlayers.callbackPlayUri(player.id, resolvedUrl, options);
        if (playerUri != null) _callbackLog('player url: ${_redactTokens(playerUri.toString())}');
        launched = await launchWithOptions(resolvedUrl, options);
        _callbackLog('launch returned $launched');
        if (!launched && identical(_callbackSession, session)) _callbackSession = null;
      } else {
        launched = await player.launch(resolvedUrl);
      }
      if (launched && current()) onLaunched?.call();
      if (!launched && context.mounted) {
        showErrorSnackBar(context, t.externalPlayer.appNotInstalled(name: player.name));
      }
      return launched;
    } catch (e) {
      appLogger.e('Failed to launch external player', error: e);
      if (context.mounted) {
        showErrorSnackBar(context, t.externalPlayer.launchFailed);
      }
      return false;
    }
  }

  static _CallbackSession _beginCallbackSession({
    required String playerId,
    required MediaItem metadata,
    required MediaServerClient? client,
    required OfflineWatchSyncService? offlineWatchService,
    required String? mediaSourceId,
    MediaPartTimeline? partTimeline,
  }) {
    return _callbackSession = _CallbackSession(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      playerId: playerId,
      metadata: metadata,
      client: client,
      offlineWatchService: offlineWatchService,
      mediaSourceId: mediaSourceId,
      partTimeline: partTimeline,
    );
  }

  /// A name players can identify [item] by, in the Plex/Infuse naming style:
  /// `Title (Year).ext` for movies, `Show - S01E02 - Title.ext` for episodes.
  /// Null when the item lacks what that needs (e.g. an episode without season
  /// or episode numbers), so the player falls back to its own detection.
  @visibleForTesting
  static String? playerFilename(MediaItem item, String streamUrl) {
    final String? name;
    switch (item.kind) {
      case MediaKind.movie:
        final title = _fileNamePart(item.title);
        final year = item.year;
        name = title == null || year == null ? title : '$title ($year)';
      case MediaKind.episode:
        final show = _fileNamePart(item.grandparentTitle);
        final season = item.parentIndex;
        final episode = item.index;
        if (show == null || season == null || episode == null) {
          name = null;
        } else {
          final code = 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
          final title = _fileNamePart(item.title);
          name = title == null ? '$show - $code' : '$show - $code - $title';
        }
      default:
        name = null;
    }
    if (name == null) return null;
    final lastSegment = Uri.tryParse(streamUrl)?.pathSegments.lastOrNull ?? '';
    final extension = RegExp(r'\.([A-Za-z0-9]{2,4})$').firstMatch(lastSegment)?.group(1);
    return extension == null ? name : '$name.$extension';
  }

  /// [value] without characters file names cannot hold, or null when nothing
  /// is left.
  static String? _fileNamePart(String? value) {
    final cleaned = value?.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned == null || cleaned.isEmpty ? null : cleaned;
  }

  /// The return links for [session]. The session sits in the path because
  /// players append their own query parameters to these links.
  @visibleForTesting
  static ExternalPlayerReturnLinks returnLinks(String session) {
    Uri link(String result) =>
        Uri(scheme: DeepLink.scheme, host: ExternalPlayerReturnLink.host, pathSegments: [result, session]);
    return ExternalPlayerReturnLinks(
      success: link(_ReturnResult.success),
      cancel: link(_ReturnResult.cancel),
      error: link(_ReturnResult.error),
    );
  }

  @visibleForTesting
  static String beginCallbackSessionForTesting({
    required MediaItem metadata,
    MediaServerClient? client,
    String playerId = 'outplayer',
  }) {
    return _beginCallbackSession(
      playerId: playerId,
      metadata: metadata,
      client: client,
      offlineWatchService: null,
      mediaSourceId: null,
    ).id;
  }

  /// Handles `plezy://external-player/<result>/<session>?position=&duration=`,
  /// the return link an x-callback-url player opens when playback ends, and
  /// syncs the position it reports. `DeepLinkService` hands every
  /// [ExternalPlayerReturnLink] here. Returns whether the link belonged to
  /// the pending launch.
  static Future<bool> handleCallbackUrl(Uri uri) async {
    _callbackLog('received: ${_redactTokens(uri.toString())}');
    final segments = uri.pathSegments;
    if (uri.scheme != DeepLink.scheme || uri.host != ExternalPlayerReturnLink.host || segments.length < 2) {
      _callbackLog('not an external-player return link; ignoring');
      return false;
    }
    final session = _callbackSession;
    if (session == null || session.id != segments[1]) {
      _callbackLog('session ${segments[1]} does not match pending ${session?.id}; ignoring');
      return false;
    }
    _callbackSession = null;

    final params = uri.queryParameters;
    final reportedDuration = _callbackNumber(params['duration']);
    final msPerUnit = _callbackMsPerUnit(reportedDuration, session.metadata.durationMs);
    final durationMs = reportedDuration == null ? null : (reportedDuration * msPerUnit).round();
    final position = _callbackNumber(params['position']);
    final positionMs = position == null ? null : (position * msPerUnit).round();
    // A reported position always wins. Without one, success means the video
    // finished only for players that call it on completion (not VLC, which
    // calls it on every stop).
    final successMeansFinished = KnownPlayers.xCallbackPlayer(session.playerId)?.successMeansFinished ?? true;
    final result = switch (segments.first) {
      _ReturnResult.success => _ExternalPlayerLaunchResult(
        launched: true,
        positionMs: positionMs,
        durationMs: durationMs,
        playbackCompleted: positionMs == null && successMeansFinished,
      ),
      _ReturnResult.cancel => _ExternalPlayerLaunchResult(
        launched: true,
        positionMs: positionMs,
        durationMs: durationMs,
      ),
      _ => const _ExternalPlayerLaunchResult(launched: true, playbackError: true),
    };
    _callbackLog(
      'result ${segments.first} from ${session.playerId}: position=${params['position']} duration=${params['duration']} '
      '-> msPerUnit $msPerUnit, positionMs $positionMs, durationMs $durationMs '
      '(item durationMs ${session.metadata.durationMs}, client ${session.client == null ? 'none' : 'set'})',
    );
    if (positionMs == null && !result.playbackCompleted && !result.playbackError) {
      _callbackLog('stopped at an unknown position; nothing will be reported');
    }
    // The link is used up either way: a failed sync must not leave it for
    // the deep-link layer to deliver again.
    try {
      await _reportExternalProgress(
        result,
        metadata: session.metadata,
        client: session.client,
        offlineWatchService: session.offlineWatchService,
        mediaSourceId: session.mediaSourceId,
        partTimeline: session.partTimeline,
      );
      _callbackLog('progress report finished for ${session.metadata.id}');
    } catch (e, stackTrace) {
      appLogger.e(
        '[ExternalPlayerCallback] progress report failed for ${session.metadata.id}',
        error: e,
        stackTrace: stackTrace,
      );
    }
    return true;
  }

  static double? _callbackNumber(String? value) {
    final number = value == null ? null : double.tryParse(value);
    return number != null && number.isFinite && number > 0 ? number : null;
  }

  /// Milliseconds per reported time unit. Players report seconds (Outplayer
  /// documents its `position` that way), unless the reported duration lines up
  /// with the item's runtime in milliseconds.
  static int _callbackMsPerUnit(double? reportedDuration, int? itemDurationMs) {
    if (reportedDuration == null || itemDurationMs == null || itemDurationMs <= 0) return 1000;
    final asMs = (reportedDuration - itemDurationMs).abs();
    final asSeconds = (reportedDuration * 1000 - itemDurationMs).abs();
    return asMs < asSeconds ? 1 : 1000;
  }

  /// Sidecar subtitles saved with the downloaded copy at [videoUrl].
  /// Best-effort: a copy whose subtitles can't be listed still launches,
  /// just without them.
  static Future<List<SubtitleTrack>> _downloadedSubtitles(
    AppDatabase database,
    String videoUrl, {
    required MediaItem metadata,
    required MediaServerClient? client,
    required int mediaIndex,
  }) async {
    final videoPath = videoUrl.startsWith('file://') ? videoUrl.substring('file://'.length) : videoUrl;
    try {
      final sidecars = await PlaybackInitializationService(
        client: client,
        database: database,
      ).discoverDownloadedSubtitles(metadata, videoPath: videoPath, mediaIndex: mediaIndex);
      return [for (final sidecar in sidecars) sidecar.track];
    } catch (e, stackTrace) {
      appLogger.w('Could not list downloaded subtitles for the external player', error: e, stackTrace: stackTrace);
      return const [];
    }
  }

  /// Launch a video on Android using native ACTION_VIEW intent.
  /// Handles local files (file://, content://, absolute paths) and remote URLs.
  static Future<_ExternalPlayerLaunchResult> _launchAndroidNative(
    String url,
    ExternalPlayer player,
    BuildContext context, {
    MediaItem? metadata,
    Duration? startPosition,
    List<SubtitleTrack> subtitles = const [],
    List<MediaAudioTrack> audioTracks = const [],
    List<MediaSubtitleTrack> subtitleTracks = const [],
    ExternalHandoffSession? session,
    bool keepAlive = false,
    bool directFile = false,
  }) async {
    try {
      final isZidoo = KnownPlayers.isZidooPlayer(player.id);
      final packages = player.id == 'system_default' || isZidoo
          ? const <String>[]
          : KnownPlayers.androidPackageCandidates(player);
      final components = isZidoo ? await KnownPlayers.zidooPlayerComponents() : const <String>[];
      if (isZidoo && components.isEmpty) {
        throw PlatformException(code: 'APP_NOT_FOUND', message: 'The Zidoo player is not installed');
      }
      final tracks = isZidoo ? zidooTrackIndexes(audioTracks, subtitleTracks) : null;
      final result = await _externalPlayerChannel.invokeMapMethod<String, Object?>('openVideo', {
        'filePath': url,
        if (metadata?.title?.trim().isNotEmpty == true) 'title': metadata!.title!.trim(),
        if (startPosition != null && startPosition > Duration.zero) 'startPositionMs': startPosition.inMilliseconds,
        if (packages.isNotEmpty) 'packages': packages,
        if (components.isNotEmpty) 'components': components,
        if (subtitles.isNotEmpty) 'subtitles': [for (final track in subtitles) ?_subtitleArgument(track)],
        'audioIndex': ?tracks?.audio,
        'subtitleIndex': ?tracks?.subtitle,
        'session': ?session?.toJson(),
        if (keepAlive) 'keepAlive': true,
        if (directFile) 'directFile': true,
      });
      return _ExternalPlayerLaunchResult.fromMap(result);
    } on PlatformException catch (e) {
      if (e.code == 'APP_NOT_FOUND' && context.mounted) {
        showErrorSnackBar(context, t.externalPlayer.appNotInstalled(name: player.name));
      } else if (context.mounted) {
        showErrorSnackBar(context, t.externalPlayer.launchFailed);
      }
      return const _ExternalPlayerLaunchResult(launched: false);
    }
  }

  /// The native Zidoo player's `audio_idx` (from 0) and `subtitle_idx` (from
  /// 1) for the server-selected rows: positions among the file's own audio
  /// and subtitle streams, in stream order. Sidecar rows are not in the file
  /// the player opens, so they are skipped, and a selected sidecar subtitle
  /// gets no index. Null where nothing is selected, which leaves the choice
  /// to the player.
  @visibleForTesting
  static ({int? audio, int? subtitle}) zidooTrackIndexes(
    List<MediaAudioTrack> audioTracks,
    List<MediaSubtitleTrack> subtitleTracks,
  ) {
    final audioIndex = zidooAudioOrder(audioTracks).indexWhere((t) => t.selected);
    final subtitleIndex = zidooSubtitleOrder(subtitleTracks).indexWhere((t) => t.selected);
    return (audio: audioIndex < 0 ? null : audioIndex, subtitle: subtitleIndex < 0 ? null : subtitleIndex + 1);
  }

  /// [url], a Plex stream handed to an external player, carrying this app's
  /// `X-Plex-*` identity from [streamHeaders] and the playback's
  /// [sessionIdentifier] in its query, since the player sends no headers of
  /// its own. The server then ties the player's download to the session the
  /// live reports open, so its dashboard shows the stream's bandwidth under
  /// this app. A [token] replaces the URL's own.
  @visibleForTesting
  static String plexStreamUrlWithIdentity(
    String url,
    Map<String, String> streamHeaders,
    String sessionIdentifier, {
    String? token,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) return url;
    final query = Map<String, String>.from(uri.queryParameters);
    for (final MapEntry(:key, :value) in streamHeaders.entries) {
      if (key.startsWith('X-Plex-') && key != _plexTokenParam) query.putIfAbsent(key, () => value);
    }
    query['X-Plex-Session-Identifier'] = sessionIdentifier;
    if (token != null) query[_plexTokenParam] = token;
    return uri.replace(queryParameters: query).toString();
  }

  /// [url] with [token] in place of the Plex token in its query; unchanged
  /// when it carries none.
  @visibleForTesting
  static String plexUrlWithToken(String url, String token) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.queryParameters.containsKey(_plexTokenParam)) return url;
    return uri.replace(queryParameters: {...uri.queryParameters, _plexTokenParam: token}).toString();
  }

  static const _plexTokenParam = 'X-Plex-Token';

  /// Where the Zidoo box reads [serverFile] through its own share mounts:
  /// by a saved mapping, else by finding the file on the mounted shares and
  /// saving the mapping that found it, for the files that follow.
  static Future<String?> _zidooDirectPath(String serverFile, SettingsService settings) async {
    final mappings = settings.read(SettingsService.zidooPathMappings);
    final mapped = zidooDirectPath(serverFile, mappings);
    if (mapped != null) return mapped;
    final api = ZidooPlayerApi();
    try {
      final found = await discoverZidooPathMapping(serverFile, api.listFolder);
      if (found == null) return null;
      appLogger.i('Zidoo direct: found ${found.serverPath} on the box at ${found.zidooPath}');
      await settings.write(SettingsService.zidooPathMappings, [
        ...settings.read(SettingsService.zidooPathMappings),
        found,
      ]);
      return zidooDirectPath(serverFile, [found]);
    } catch (e) {
      appLogger.w('Zidoo direct: could not search the box\'s share mounts', error: e);
      return null;
    } finally {
      api.close();
    }
  }

  /// Saves a track picked in the native Zidoo player on Plex, per file, when
  /// the viewer lets track picks be remembered. MediaBrowser servers take the
  /// pick from the stream indexes on the progress reports instead.
  static ZidooTrackPersister? _zidooTrackPersister(MediaServerClient client, int? partId, bool remember) {
    if (!remember || partId == null || client is! PlexClient) return null;
    return ({int? audioStreamId, int? subtitleStreamId}) async {
      if (!await client.selectStreams(partId, audioStreamID: audioStreamId, subtitleStreamID: subtitleStreamId)) {
        throw StateError('Plex did not store the stream selection');
      }
    };
  }

  /// Reports a player result that reached this process after the one that
  /// launched the player was reclaimed (see [ExternalHandoffSession]). The
  /// position is queued for [offlineWatchService]'s next sync, which also
  /// marks the item watched past the server's threshold. Android only; safe
  /// to call when nothing is waiting.
  static Future<void> recoverOrphanedResult(OfflineWatchSyncService offlineWatchService) async {
    if (!Platform.isAndroid) return;
    final Map<String, Object?>? raw;
    try {
      raw = await _externalPlayerChannel.invokeMapMethod<String, Object?>('takeOrphanedResult');
    } catch (e) {
      appLogger.w('Could not read an orphaned external player result', error: e);
      return;
    }
    if (raw == null) return;
    final session = ExternalHandoffSession.fromJson(raw['session'] as String? ?? '');
    if (session == null) {
      appLogger.w('Dropping an orphaned external player result without a readable session');
      return;
    }
    final result = _ExternalPlayerLaunchResult.fromMap(raw);
    final progress = _handoffProgress(result: result, session: session);
    appLogger.i(
      'Recovered an external player result for ${session.serverId}:${session.itemId} '
      '(position ${result.positionMs}, completed ${result.playbackCompleted}) -> ${progress?.positionMs}',
    );
    if (progress == null) return;
    await offlineWatchService.queueProgressUpdate(
      serverId: ServerId(session.serverId),
      itemId: session.itemId,
      viewOffset: progress.positionMs,
      duration: progress.durationMs,
    );
  }

  /// Where [result] leaves the item [session] describes, on the item's
  /// clock; null when the player reported no usable position.
  @visibleForTesting
  static ({int positionMs, int? durationMs})? handoffProgress({
    required ExternalHandoffSession session,
    int? positionMs,
    int? durationMs,
    bool playbackCompleted = false,
    bool playbackError = false,
  }) => _handoffProgress(
    result: _ExternalPlayerLaunchResult(
      launched: true,
      positionMs: positionMs,
      durationMs: durationMs,
      playbackCompleted: playbackCompleted,
      playbackError: playbackError,
    ),
    session: session,
  );

  static ({int positionMs, int? durationMs})? _handoffProgress({
    required _ExternalPlayerLaunchResult result,
    required ExternalHandoffSession session,
  }) {
    if (result.playbackError) return null;
    final int? duration;
    final int? reported;
    final partStart = session.partStartMs;
    if (partStart != null) {
      duration = _positive(session.itemDurationMs);
      final filePosition = _positive(result.positionMs);
      reported = filePosition != null
          ? partStart + filePosition
          : (result.playbackCompleted ? session.partEndMs : null);
    } else {
      duration = _positive(result.durationMs) ?? _positive(session.itemDurationMs);
      reported = _positive(result.positionMs) ?? (result.playbackCompleted ? duration : null);
    }
    if (reported == null) return null;
    return (positionMs: duration == null ? reported : reported.clamp(0, duration).toInt(), durationMs: duration);
  }

  /// One `subtitles` entry for the native intent builder. Local sidecars go
  /// as plain paths, the same shape as a downloaded video, so the native side
  /// shares them through its FileProvider.
  static Map<String, Object?>? _subtitleArgument(SubtitleTrack track) {
    final uri = track.uri;
    if (uri == null || uri.isEmpty) return null;
    final name = track.title?.trim();
    return {
      'uri': uri.startsWith('file:') ? Uri.parse(uri).toFilePath() : uri,
      if (name != null && name.isNotEmpty) 'name': name,
      'enabled': track.isDefault,
    };
  }

  /// Syncs where playback in an external player stopped, as reported by the
  /// Android intent result or an x-callback-url return link (iOS).
  ///
  /// [partTimeline] places the handed-over file on its item when the item is
  /// stacked across several files: the external player's position is on that
  /// file's clock and its duration is that file's, so both are mapped onto
  /// the item, and playing out a file with another after it leaves the item
  /// at the next file instead of finished.
  ///
  /// [playSessionId] names the server session live reports opened while the
  /// player ran, if any. Returns whether a stopped report was sent for it.
  static Future<bool> _reportExternalProgress(
    _ExternalPlayerLaunchResult result, {
    required MediaItem metadata,
    required MediaServerClient? client,
    OfflineWatchSyncService? offlineWatchService,
    String? mediaSourceId,
    MediaPartTimeline? partTimeline,
    bool Function()? isLaunchCurrent,
    String? playSessionId,
  }) async {
    bool current() => isLaunchCurrent?.call() ?? true;
    if (!current()) return false;
    if (result.playbackError) {
      appLogger.d('External player returned an error result for ${metadata.id}; skipping progress sync');
      return false;
    }

    final part = partTimeline?.current;
    final progress = _handoffProgress(
      result: result,
      session: ExternalHandoffSession(
        serverId: metadata.serverId ?? '',
        itemId: metadata.id,
        itemDurationMs: partTimeline?.duration.inMilliseconds ?? metadata.durationMs,
        partStartMs: part?.start.inMilliseconds,
        partEndMs: part?.end.inMilliseconds,
      ),
    );
    if (progress == null) return false;

    final position = Duration(milliseconds: progress.positionMs);
    final durationMs = progress.durationMs;
    final duration = durationMs == null ? null : Duration(milliseconds: durationMs);
    if (client == null) {
      await _queueExternalProgress(metadata, offlineWatchService, position: position, duration: duration);
      return false;
    }

    var startedSucceeded = false;
    try {
      await client.reportPlaybackStarted(
        itemId: metadata.id,
        position: position,
        duration: duration,
        playSessionId: playSessionId,
        playMethod: 'DirectPlay',
        mediaSourceId: mediaSourceId,
      );
      startedSucceeded = true;
    } catch (e) {
      appLogger.d('External player progress: started call failed (continuing)', error: e);
    }

    if (!current()) return false;
    try {
      await client.reportPlaybackStopped(
        itemId: metadata.id,
        position: position,
        duration: duration,
        playSessionId: playSessionId,
        mediaSourceId: mediaSourceId,
      );
    } catch (e) {
      appLogger.w('Failed to sync external player progress for ${metadata.id}', error: e);
      if (!current()) return true;
      await _queueExternalProgress(metadata, offlineWatchService, position: position, duration: duration);
      return true;
    }

    if (!current()) return true;
    if (duration == null) return true;

    WatchStateNotifier().notifyProgress(
      item: metadata,
      cacheServerId: client.cacheServerId,
      viewOffset: position.inMilliseconds,
      duration: duration.inMilliseconds,
      watchedThreshold: client.watchedThreshold,
      // MediaBrowser persists stopped progress only for a session opened by
      // Started; Plex persists every timeline report independently.
      serverAcknowledged: !metadata.backend.usesMediaBrowserApi || startedSucceeded,
    );

    if (isWatchedProgress(
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      threshold: client.watchedThreshold,
    )) {
      try {
        // reportPlaybackStopped above marks the item played on backends that
        // support it (Jellyfin); markWatchedFromPlaybackStop then only emits the
        // local watch event there to avoid double-scrobbling via the Trakt
        // plugin (#1287). Plex still issues the explicit server call.
        await client.markWatchedFromPlaybackStop(metadata);
        if (!current()) return true;
        unawaited(TrackerCoordinator.instance.markWatched(metadata, client));
      } catch (e) {
        appLogger.w('Failed to mark external playback watched for ${metadata.id}', error: e);
      }
    }
    return true;
  }

  @visibleForTesting
  static Future<void> reportExternalProgressForTesting({
    required int? positionMs,
    required int? durationMs,
    bool playbackCompleted = false,
    bool playbackError = false,
    required MediaItem metadata,
    required MediaServerClient? client,
    OfflineWatchSyncService? offlineWatchService,
    String? mediaSourceId,
    MediaPartTimeline? partTimeline,
  }) {
    return _reportExternalProgress(
      _ExternalPlayerLaunchResult(
        launched: true,
        positionMs: positionMs,
        durationMs: durationMs,
        playbackCompleted: playbackCompleted,
        playbackError: playbackError,
      ),
      metadata: metadata,
      client: client,
      offlineWatchService: offlineWatchService,
      mediaSourceId: mediaSourceId,
      partTimeline: partTimeline,
    );
  }

  static Future<void> _queueExternalProgress(
    MediaItem metadata,
    OfflineWatchSyncService? offlineWatchService, {
    required Duration position,
    required Duration? duration,
  }) async {
    final serverId = metadata.serverId;
    if (offlineWatchService == null || serverId == null) return;
    await offlineWatchService.queueProgressUpdate(
      serverId: ServerId(serverId),
      itemId: metadata.id,
      viewOffset: duration == null
          ? position.inMilliseconds
          : position.inMilliseconds.clamp(0, duration.inMilliseconds).toInt(),
      duration: duration?.inMilliseconds,
    );
  }

  static int? _positive(int? value) => value != null && value > 0 ? value : null;
}
