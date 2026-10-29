/// One library location as the media server and the Zidoo box each see it:
/// the server's folder ([serverPath], e.g. `/data/media`) and the same folder
/// where the box mounts the share ([zidooPath], e.g.
/// `/mnt/smb/192.168.1.10#media`).
class ZidooPathMapping {
  const ZidooPathMapping({required this.serverPath, required this.zidooPath});

  final String serverPath;
  final String zidooPath;

  static ZidooPathMapping? fromJson(Object? json) {
    if (json is! Map) return null;
    final serverPath = json['serverPath'];
    final zidooPath = json['zidooPath'];
    if (serverPath is! String || zidooPath is! String) return null;
    return ZidooPathMapping(serverPath: serverPath, zidooPath: zidooPath);
  }

  Map<String, String> toJson() => {'serverPath': serverPath, 'zidooPath': zidooPath};

  @override
  bool operator ==(Object other) =>
      other is ZidooPathMapping && other.serverPath == serverPath && other.zidooPath == zidooPath;

  @override
  int get hashCode => Object.hash(serverPath, zidooPath);
}

/// Where the Zidoo box reads [serverFile], the file's path on the media
/// server, through its own mount of the share: the longest [mappings] folder
/// that holds the file, swapped for the box's. Windows server paths
/// (`D:\Movies\…`) match case-insensitively and come out with `/`. Null when
/// no mapping holds the file.
String? zidooDirectPath(String serverFile, List<ZidooPathMapping> mappings) {
  final file = _normalise(serverFile);
  String? best;
  var bestLength = -1;
  for (final mapping in mappings) {
    final folder = _trimTrailingSlash(_normalise(mapping.serverPath.trim()));
    final zidooFolder = _trimTrailingSlash(mapping.zidooPath.trim());
    if (folder.isEmpty || zidooFolder.isEmpty || folder.length <= bestLength) continue;
    final rest = _below(file, folder);
    if (rest == null) continue;
    best = '$zidooFolder$rest';
    bestLength = folder.length;
  }
  return best;
}

String _normalise(String path) => path.replaceAll(r'\', '/');

String _trimTrailingSlash(String path) {
  var end = path.length;
  while (end > 1 && path[end - 1] == '/') {
    end--;
  }
  return path.substring(0, end);
}

/// [file] below [folder] (`/rest/of/path`), on a whole folder name: `/data`
/// does not hold `/database/x.mkv`. A drive-letter folder matches any case.
String? _below(String file, String folder) {
  final windows = RegExp(r'^[A-Za-z]:(/|$)').hasMatch(folder);
  final head = file.length < folder.length ? null : file.substring(0, folder.length);
  if (head == null) return null;
  if (windows ? head.toLowerCase() != folder.toLowerCase() : head != folder) return null;
  final rest = file.substring(folder.length);
  if (folder == '/') return '/$rest';
  return rest.isEmpty || rest.startsWith('/') ? rest : null;
}

/// Lists a folder on the Zidoo box: its names, or null when it is missing.
typedef ZidooFolderLister = Future<List<String>?> Function(String folder);

/// Where the box mounts network shares: one folder per share, named
/// `<server>#<share>`.
const zidooMountRoots = ['/mnt/smb', '/mnt/nfs'];

/// Finds where the box's own share mounts hold [serverFile], the file's path
/// on the media server, and returns the folder pair that maps one onto the
/// other. Each mounted share is tried with the server path's leading folders
/// dropped one at a time, longest remainder first, until the box lists the
/// file itself in the folder it should be in. Null when no mount holds it.
Future<ZidooPathMapping?> discoverZidooPathMapping(
  String serverFile,
  ZidooFolderLister list, {
  List<String> mountRoots = zidooMountRoots,
}) async {
  final path = _normalise(serverFile);
  final segments = [
    for (final segment in path.split('/'))
      if (segment.isNotEmpty) segment,
  ];
  if (segments.isEmpty) return null;
  final fileName = segments.last;
  final posix = path.startsWith('/');
  for (final root in mountRoots) {
    for (final share in await list(root) ?? const <String>[]) {
      final mount = '$root/$share';
      // Only remainders whose first name is at the top of the share can be
      // there, which spares a listing per folder level.
      final top = (await list(mount))?.toSet() ?? const <String>{};
      // A drive letter is never a folder on the share.
      for (var drop = posix ? 0 : 1; drop < segments.length; drop++) {
        if (!top.contains(segments[drop])) continue;
        final folder = [mount, ...segments.sublist(drop, segments.length - 1)].join('/');
        final names = drop == segments.length - 1 ? top : await list(folder);
        if (names == null || !names.contains(fileName)) continue;
        final serverFolder = segments.sublist(0, drop).join('/');
        return ZidooPathMapping(serverPath: posix ? '/$serverFolder' : serverFolder, zidooPath: mount);
      }
    }
  }
  return null;
}
