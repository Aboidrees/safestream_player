import 'package:youtube_explode_dart/youtube_explode_dart.dart';
void main() async {
  final yt = YoutubeExplode();
  final manifest = await yt.videos.streamsClient.getManifest('7s1W93L3VwU'); // MrBeast multi-lang video
  for (var track in manifest.audioOnly) {
    print('Audio Track: ${track.audioCodec}, bitrate: ${track.bitrate}');
  }
  yt.close();
}
