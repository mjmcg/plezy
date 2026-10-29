import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/services/external_player_service.dart';
import 'package:plezy/services/zidoo_now_playing.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/playback_report_fakes.dart';

class _RecordingClient with PlaybackReportRecorder implements MediaServerClient {
  final calls = <PlaybackReportCall>[];
  Object? failWith;

  @override
  ServerId get serverId => ServerId('srv');

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  Future<void> onPlaybackReport(PlaybackReportCall call) async {
    calls.add(call);
    final failure = failWith;
    if (failure != null) throw failure;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The box's control API, answering status reads from [statuses] in turn and
/// recording the other requests.
class _FakeBox {
  _FakeBox(this.statuses);

  final List<Map<String, Object?>> statuses;
  final requests = <String>[];

  ZidooPlayerApi api() => ZidooPlayerApi(
    httpClient: MockClient((request) async {
      requests.add('${request.url.path}?${request.url.query}');
      if (request.url.path == '/ZidooVideoPlay/getPlayStatus') {
        final body = statuses.length > 1 ? statuses.removeAt(0) : statuses.first;
        return http.Response(jsonEncode(body), 200);
      }
      return http.Response(jsonEncode({'status': 200}), 200);
    }),
  );
}

Map<String, Object?> _playing({
  int position = 60000,
  int duration = 5400000,
  int status = 1,
  int audio = 0,
  int subtitle = 0,
}) => {
  'status': 200,
  'video': {
    'status': status,
    'title': 'Austin Powers',
    'path': '/library/parts/7/1690000/file.mkv',
    'currentPosition': position,
    'duration': duration,
    'output': '1920X1080P @ 23.976Hz YUV444 10Bits SDR',
  },
  'subtitle': {'index': subtitle, 'information': 'Off (0/2)'},
  'audio': {'index': audio, 'information': 'English AAC 5.1 (1/2)'},
};

const _nothingOpen = {'status': 806, 'msg': 'The resource does not exist'};

void main() {
  group('play status', () {
    test('reads the documented response', () {
      final status = ZidooPlayStatus.fromJson(_playing(position: 3494, duration: 9024932, audio: 1, subtitle: 2))!;

      expect(status.positionMs, 3494);
      expect(status.durationMs, 9024932);
      expect(status.playing, isTrue);
      expect(status.path, '/library/parts/7/1690000/file.mkv');
      expect(status.audioIndex, 1);
      expect(status.subtitleIndex, 2);
      expect(status.output, '1920X1080P @ 23.976Hz YUV444 10Bits SDR');
    });

    test('is paused for any status other than 1', () {
      expect(ZidooPlayStatus.fromJson(_playing(status: 0))!.playing, isFalse);
    });

    test('is null when the player has no video open', () {
      expect(ZidooPlayStatus.fromJson(_nothingOpen), isNull);
      expect(ZidooPlayStatus.fromJson('not json'), isNull);
    });
  });

  group('folder listing', () {
    test('reads the names in a folder, and null for a missing one', () async {
      final requested = <Uri>[];
      final api = ZidooPlayerApi(
        httpClient: MockClient((request) async {
          requested.add(request.url);
          final exists = request.url.queryParameters['path']!.endsWith('(2019)');
          return http.Response(
            jsonEncode({
              'status': 200,
              'isExists': exists,
              'filelist': [
                if (exists) {'name': '1917 (2019) Remux-2160p.mkv', 'type': 2},
              ],
            }),
            200,
          );
        }),
      );

      expect(await api.listFolder('/mnt/smb/192.168.1.12#HomeTheater/Movies/1917 (2019)'), [
        '1917 (2019) Remux-2160p.mkv',
      ]);
      expect(await api.listFolder('/mnt/smb/192.168.1.12#HomeTheater/Nope'), isNull);
      expect(requested.first.path, '/ZidooFileControl/getFileList');
      expect(requested.first.queryParameters['path'], '/mnt/smb/192.168.1.12#HomeTheater/Movies/1917 (2019)');
    });
  });

  group('live reporting', () {
    final audioTracks = [
      MediaAudioTrack(id: 11, index: 1, selected: true),
      MediaAudioTrack(id: 12, index: 2, selected: false),
    ];
    final subtitleTracks = [
      MediaSubtitleTrack(id: 21, index: 3, selected: false, forced: false),
      MediaSubtitleTrack(id: 29, selected: false, forced: false, key: '/library/streams/29'),
      MediaSubtitleTrack(id: 22, index: 4, selected: false, forced: false),
    ];

    late _RecordingClient client;
    late List<({int? audioStreamId, int? subtitleStreamId})> persisted;

    setUp(() {
      client = _RecordingClient();
      persisted = [];
    });

    ZidooNowPlayingReporter reporter(
      _FakeBox box, {
      Duration partStart = Duration.zero,
      Duration? itemDuration,
      DateTime Function()? clock,
    }) => ZidooNowPlayingReporter(
      client: client,
      metadata: testMediaItem(id: 'item-1', serverId: 'srv'),
      playSessionId: 'session-1',
      partStart: partStart,
      itemDuration: itemDuration,
      audioTracks: audioTracks,
      subtitleTracks: subtitleTracks,
      persistTrack: ({int? audioStreamId, int? subtitleStreamId}) async =>
          persisted.add((audioStreamId: audioStreamId, subtitleStreamId: subtitleStreamId)),
      api: box.api(),
      clock: clock,
    );

    test('opens the session with a started report, then sends progress', () async {
      final box = _FakeBox([_playing(position: 60000), _playing(position: 70000, status: 0)]);
      final live = reporter(box);

      await live.tick();
      await live.tick();

      expect(client.calls.map((c) => c.kind), [PlaybackReportKind.started, PlaybackReportKind.progress]);
      expect(client.calls.map((c) => c.position), [const Duration(seconds: 60), const Duration(seconds: 70)]);
      expect(client.calls.map((c) => c.playSessionId), everyElement('session-1'));
      expect(client.calls.last.isPaused, isTrue);
      expect(client.calls.last.duration, const Duration(milliseconds: 5400000));
      expect(client.calls.first.audioStreamIndex, 11);
      expect(client.calls.first.subtitleStreamIndex, -1);
      expect(live.sessionOpen, isTrue);
      expect(live.lastFilePositionMs, 70000);
    });

    test('reports a pause at once, and an unchanged position every 10 seconds', () async {
      var now = DateTime(2026, 10, 28, 20);
      final box = _FakeBox([
        _playing(position: 60000),
        _playing(position: 62000),
        _playing(position: 64000, status: 0),
        _playing(position: 64000, status: 0),
        _playing(position: 64000, status: 0),
      ]);
      final live = reporter(box, clock: () => now);

      for (final seconds in [0, 2, 4, 6, 14]) {
        now = DateTime(2026, 10, 28, 20, 0, seconds);
        await live.tick();
      }

      expect(client.calls.map((c) => c.kind), [
        PlaybackReportKind.started,
        PlaybackReportKind.progress,
        PlaybackReportKind.progress,
      ]);
      // The pause at 4s goes out at once; nothing changes again until the
      // heartbeat 10 seconds after it.
      expect(client.calls.map((c) => c.isPaused), [false, true, true]);
    });

    test('sends nothing until the player has the video open', () async {
      final live = reporter(_FakeBox([_nothingOpen]));

      await live.tick();

      expect(client.calls, isEmpty);
      expect(live.sessionOpen, isFalse);
    });

    test('places a stacked file on the item clock', () async {
      final live = reporter(
        _FakeBox([_playing(position: 60000, duration: 2400000)]),
        partStart: const Duration(minutes: 50),
        itemDuration: const Duration(minutes: 90),
      );

      await live.tick();

      expect(client.calls.single.position, const Duration(minutes: 51));
      expect(client.calls.single.duration, const Duration(minutes: 90));
    });

    test('saves a track the viewer switches to, but not the one it started on', () async {
      final box = _FakeBox([
        _playing(audio: 0, subtitle: 0),
        _playing(audio: 1, subtitle: 0),
        _playing(audio: 1, subtitle: 2),
        _playing(audio: 1, subtitle: 0),
      ]);
      final live = reporter(box);

      for (var i = 0; i < 4; i++) {
        await live.tick();
      }

      expect(persisted, [
        (audioStreamId: 12, subtitleStreamId: null),
        // The sidecar is not in the file, so the player's second subtitle is 22.
        (audioStreamId: null, subtitleStreamId: 22),
        (audioStreamId: null, subtitleStreamId: 0),
      ]);
      expect(client.calls[2].subtitleStreamIndex, 22);
    });

    test('stops the player when the server ends the session', () async {
      final box = _FakeBox([_playing()]);
      final live = reporter(box);
      client.failWith = PlaybackSessionTerminatedException(code: 2006, reason: 'Admin stopped it');

      await live.tick();
      client.failWith = null;
      await live.tick();

      expect(box.requests.where((r) => r.contains('Key.MediaStop')), hasLength(1));
      expect(client.calls, hasLength(1));
      expect(live.sessionOpen, isFalse);
    });

    test('closeSession sends a stopped report at the last position, once', () async {
      final live = reporter(_FakeBox([_playing(position: 90000)]));

      await live.tick();
      await live.closeSession();
      await live.closeSession();

      expect(client.calls.map((c) => c.kind), [PlaybackReportKind.started, PlaybackReportKind.stopped]);
      expect(client.calls.last.position, const Duration(seconds: 90));
      expect(client.calls.last.playSessionId, 'session-1');
    });
  });

  group('Plex stream identity', () {
    test('adds the app identity and session to the stream URL, keeping the token', () {
      final url = ExternalPlayerService.plexStreamUrlWithIdentity(
        'http://192.168.1.10:32400/library/parts/7/1690000/file.mkv?X-Plex-Token=abc',
        const {
          'X-Plex-Client-Identifier': 'client-1',
          'X-Plex-Product': 'Plezy',
          'X-Plex-Token': 'other',
          'Accept': 'application/json',
        },
        'session-1',
      );
      final query = Uri.parse(url).queryParameters;

      expect(Uri.parse(url).path, '/library/parts/7/1690000/file.mkv');
      expect(query['X-Plex-Token'], 'abc');
      expect(query['X-Plex-Client-Identifier'], 'client-1');
      expect(query['X-Plex-Product'], 'Plezy');
      expect(query['X-Plex-Session-Identifier'], 'session-1');
      expect(query.containsKey('Accept'), isFalse);
    });

    test('swaps in a transient token', () {
      final url = ExternalPlayerService.plexStreamUrlWithIdentity(
        'http://192.168.1.10:32400/library/parts/7/1690000/file.mkv?X-Plex-Token=abc',
        const {'X-Plex-Client-Identifier': 'client-1'},
        'session-1',
        token: 'transient-1',
      );

      expect(Uri.parse(url).queryParameters['X-Plex-Token'], 'transient-1');
      expect(url, isNot(contains('abc')));
    });

    test('swaps the token in a subtitle URL, and leaves one without a token alone', () {
      expect(
        ExternalPlayerService.plexUrlWithToken('http://srv/library/streams/9?encoding=utf-8&X-Plex-Token=abc', 't-1'),
        'http://srv/library/streams/9?encoding=utf-8&X-Plex-Token=t-1',
      );
      expect(ExternalPlayerService.plexUrlWithToken('/storage/movie.srt', 't-1'), '/storage/movie.srt');
    });

    test('leaves a local file alone', () {
      expect(
        ExternalPlayerService.plexStreamUrlWithIdentity('/storage/movie.mkv', const {}, 's'),
        '/storage/movie.mkv',
      );
    });
  });
}
