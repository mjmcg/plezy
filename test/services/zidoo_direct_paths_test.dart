import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/zidoo_direct_paths.dart';

void main() {
  const media = ZidooPathMapping(serverPath: '/data/media', zidooPath: '/mnt/smb/192.168.1.10#media');

  test('swaps the server folder for the Zidoo mount', () {
    expect(
      zidooDirectPath('/data/media/Movies/Heat (1995)/Heat.mkv', [media]),
      '/mnt/smb/192.168.1.10#media/Movies/Heat (1995)/Heat.mkv',
    );
  });

  test('matches whole folder names only', () {
    expect(zidooDirectPath('/data/media2/Movies/Heat.mkv', [media]), isNull);
    expect(zidooDirectPath('/srv/Movies/Heat.mkv', [media]), isNull);
  });

  test('ignores trailing slashes and surrounding spaces', () {
    const loose = ZidooPathMapping(serverPath: ' /data/media/ ', zidooPath: '/mnt/smb/192.168.1.10#media/');

    expect(zidooDirectPath('/data/media/Heat.mkv', [loose]), '/mnt/smb/192.168.1.10#media/Heat.mkv');
  });

  test('prefers the most specific folder', () {
    const tv = ZidooPathMapping(serverPath: '/data/media/TV', zidooPath: '/mnt/nfs/192.168.1.10#tv');

    expect(zidooDirectPath('/data/media/TV/Show/S01E01.mkv', [media, tv]), '/mnt/nfs/192.168.1.10#tv/Show/S01E01.mkv');
    expect(zidooDirectPath('/data/media/Movies/Heat.mkv', [tv, media]), '/mnt/smb/192.168.1.10#media/Movies/Heat.mkv');
  });

  test('maps a Windows server path with forward slashes, in any drive-letter case', () {
    const windows = ZidooPathMapping(serverPath: r'D:\Media', zidooPath: '/mnt/smb/nas#media');

    expect(zidooDirectPath(r'd:\Media\Movies\Heat.mkv', [windows]), '/mnt/smb/nas#media/Movies/Heat.mkv');
  });

  test('skips empty mappings', () {
    expect(
      zidooDirectPath('/data/media/Heat.mkv', [const ZidooPathMapping(serverPath: '', zidooPath: '/mnt')]),
      isNull,
    );
  });

  test('round-trips through JSON and skips malformed entries', () {
    expect(ZidooPathMapping.fromJson(media.toJson()), media);
    expect(ZidooPathMapping.fromJson({'serverPath': '/data'}), isNull);
    expect(ZidooPathMapping.fromJson('nope'), isNull);
  });

  group('discovery', () {
    // The box as the user's Z9X 8K lists it: one SMB share, an empty NFS root.
    final box = <String, List<String>>{
      '/mnt/smb': ['192.168.1.12#HomeTheater'],
      '/mnt/nfs': [],
      '/mnt/smb/192.168.1.12#HomeTheater': ['Movies', 'TV', 'Staging'],
      '/mnt/smb/192.168.1.12#HomeTheater/Movies': ['1917 (2019)', 'Heat (1995)'],
      '/mnt/smb/192.168.1.12#HomeTheater/Movies/1917 (2019)': ['1917 (2019) Remux-2160p.mkv'],
      '/mnt/smb/192.168.1.12#HomeTheater/Movies/Heat (1995)': ['Heat (1995).mkv'],
    };
    late List<String> listed;

    Future<List<String>?> list(String folder) async {
      listed.add(folder);
      return box[folder];
    }

    setUp(() => listed = []);

    test('drops the server folders the share does not have', () async {
      final mapping = await discoverZidooPathMapping(
        '/data/HomeTheater/Movies/1917 (2019)/1917 (2019) Remux-2160p.mkv',
        list,
      );

      expect(
        mapping,
        const ZidooPathMapping(serverPath: '/data/HomeTheater', zidooPath: '/mnt/smb/192.168.1.12#HomeTheater'),
      );
      expect(
        zidooDirectPath('/data/HomeTheater/Movies/Heat (1995)/Heat (1995).mkv', [mapping!]),
        '/mnt/smb/192.168.1.12#HomeTheater/Movies/Heat (1995)/Heat (1995).mkv',
      );
      // Only the remainder that starts at the top of the share is looked into.
      expect(listed, [
        '/mnt/smb',
        '/mnt/smb/192.168.1.12#HomeTheater',
        '/mnt/smb/192.168.1.12#HomeTheater/Movies/1917 (2019)',
      ]);
    });

    test('needs the file itself, not just its folders', () async {
      expect(await discoverZidooPathMapping('/data/HomeTheater/Movies/Heat (1995)/Heat (1995) 4K.mkv', list), isNull);
      expect(await discoverZidooPathMapping('/data/Other/Movies/Ran (1985)/Ran.mkv', list), isNull);
    });

    test('maps a Windows server path', () async {
      final mapping = await discoverZidooPathMapping(r'E:\Media\Movies\Heat (1995)\Heat (1995).mkv', list);

      expect(mapping, const ZidooPathMapping(serverPath: 'E:/Media', zidooPath: '/mnt/smb/192.168.1.12#HomeTheater'));
    });

    test('finds nothing when the box has no shares mounted', () async {
      Future<List<String>?> empty(String folder) async => null;

      expect(await discoverZidooPathMapping('/data/HomeTheater/Movies/Heat (1995)/Heat (1995).mkv', empty), isNull);
    });
  });
}
