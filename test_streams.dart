import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  try {
    final videoId = 'dQw4w9WgXcQ';
    final m = await yt.videos.streamsClient.getManifest(videoId);
    print('HLS count: ${m.hls.length}');
    for (var s in m.hls) {
      print('HLS: ${s.url}');
    }
    print('Muxed count: ${m.muxed.length}');
    for (var s in m.muxed) {
      print('Muxed: ${s.qualityLabel} | container: ${s.container.name} | bitrate: ${s.bitrate.kiloBitsPerSecond} kbps | size: ${s.size.totalMegaBytes.toStringAsFixed(1)} MB | url: ${s.url.toString().substring(0, 60)}...');
    }
    print('VideoOnly count: ${m.videoOnly.length}');
    for (var s in m.videoOnly.take(6)) {
      print('VideoOnly: ${s.qualityLabel} | container: ${s.container.name} | bitrate: ${s.bitrate.kiloBitsPerSecond} kbps | url: ${s.url.toString().substring(0, 60)}...');
    }
  } catch (e) {
    print('Error: $e');
  } finally {
    yt.close();
  }
}
