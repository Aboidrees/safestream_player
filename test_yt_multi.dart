import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  final m = await yt.videos.streamsClient.getManifest('7s1W93L3VwU');
  print('Audio only: ${m.audioOnly.length}');
  for (var a in m.audioOnly) {
     print('Audio codec: ${a.audioCodec}, bitrate: ${a.bitrate}');
  }
  yt.close();
}
