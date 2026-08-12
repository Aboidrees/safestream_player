import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  final m = await yt.videos.streamsClient.getManifest('dQw4w9WgXcQ');
  print('Video only: ${m.videoOnly.length}');
  print('Audio only: ${m.audioOnly.length}');
  print('Muxed: ${m.muxed.length}');
  
  if (m.audioOnly.isNotEmpty) {
     print('First audio URL: ${m.audioOnly.first.url}');
  }
  yt.close();
}
