import 'package:flutter/material.dart';
import 'package:chewie/chewie.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt_explode;

class SafeStreamCustomControls extends StatefulWidget {
  final List<yt_explode.AudioOnlyStreamInfo> audioTracks;
  final yt_explode.AudioOnlyStreamInfo? selectedAudioTrack;
  final Function(yt_explode.AudioOnlyStreamInfo) onAudioTrackSelected;
  final VideoPlayerController videoPlayerController;

  const SafeStreamCustomControls({
    Key? key,
    required this.audioTracks,
    required this.selectedAudioTrack,
    required this.onAudioTrackSelected,
    required this.videoPlayerController,
  }) : super(key: key);

  @override
  State<SafeStreamCustomControls> createState() => _SafeStreamCustomControlsState();
}

class _SafeStreamCustomControlsState extends State<SafeStreamCustomControls> with SingleTickerProviderStateMixin {
  late VideoPlayerController controller;
  bool _hideStuff = false;
  bool _showSettings = false;

    yt_explode.AudioOnlyStreamInfo? _localSelectedAudioTrack;

  @override
  void initState() {
    super.initState();
    controller = widget.videoPlayerController;
    _localSelectedAudioTrack = widget.selectedAudioTrack;
  }

  @override
  Widget build(BuildContext context) {
    final chewieController = ChewieController.of(context);
    
    return GestureDetector(
      onTap: () {
        setState(() {
          _hideStuff = !_hideStuff;
          if (_hideStuff) _showSettings = false;
        });
      },
      child: Stack(
        children: [
          // If controls are hidden, show tiny progress bar at the absolute bottom
          if (_hideStuff)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: false,
                padding: EdgeInsets.zero,
                colors: const VideoProgressColors(
                  playedColor: Colors.red,
                  backgroundColor: Colors.white24,
                  bufferedColor: Colors.white70,
                ),
              ),
            ),

          // Main controls overlay
          AnimatedOpacity(
            opacity: _hideStuff ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 300),
            child: Container(
              color: Colors.black45, // Dark overlay like YouTube
              child: Stack(
                children: [
                  // Play/Pause Center
                  Center(
                    child: IconButton(
                      iconSize: 48,
                      color: Colors.white,
                      icon: Icon(
                        controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                      onPressed: () {
                        setState(() {
                          controller.value.isPlaying ? controller.pause() : controller.play();
                        });
                      },
                    ),
                  ),

                  // Bottom Controls Bar
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Progress bar (thicker)
                        VideoProgressIndicator(
                          controller,
                          allowScrubbing: true,
                          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                          colors: const VideoProgressColors(
                            playedColor: Colors.red,
                            backgroundColor: Colors.white24,
                            bufferedColor: Colors.white70,
                          ),
                        ),
                        // Actions row
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // Timestamp
                              ValueListenableBuilder(
                                valueListenable: controller,
                                builder: (context, VideoPlayerValue value, child) {
                                  return Text(
                                    '${_formatDuration(value.position)} / ${_formatDuration(value.duration)}',
                                    style: const TextStyle(color: Colors.white, fontSize: 12),
                                  );
                                },
                              ),
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.settings, color: Colors.white, size: 20),
                                    onPressed: () {
                                      setState(() {
                                        _showSettings = !_showSettings;
                                      });
                                    },
                                  ),
                                  // chewieController is non-nullable here, so no null check needed.
                                    IconButton(
                                      icon: const Icon(Icons.fullscreen, color: Colors.white, size: 24),
                                      onPressed: chewieController.toggleFullScreen,
                                    ),
                                ],
                              )
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Settings Overlay
                  if (_showSettings)
                    Positioned(
                      top: 16,
                      right: 16,
                      child: Container(
                        width: 250,
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Padding(
                              padding: EdgeInsets.all(12.0),
                              child: Text('Language Options', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            ),
                            const Divider(color: Colors.white24, height: 1),
                            ...widget.audioTracks.map((track) {
                              return ListTile(
                                dense: true,
                                title: Text(
                                  track.audioTrack?.displayName ?? 'Audio Track (Bitrate: ${(track.bitrate.kiloBitsPerSecond).toStringAsFixed(0)} kbps)',
                                  style: const TextStyle(color: Colors.white, fontSize: 13),
                                ),
                                trailing: _localSelectedAudioTrack == track
                                    ? const Icon(Icons.check, color: Colors.white, size: 16)
                                    : null,
                                onTap: () {
                                  widget.onAudioTrackSelected(track);
                                  setState(() {
                                    _localSelectedAudioTrack = track;
                                    _showSettings = false;
                                  });
                                },
                              );
                            }).toList(),
                            if (widget.audioTracks.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(16.0),
                                child: Text('No alternative tracks', style: TextStyle(color: Colors.white54, fontSize: 12)),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return "${duration.inHours}:$twoDigitMinutes:$twoDigitSeconds";
    } else {
      return "$twoDigitMinutes:$twoDigitSeconds";
    }
  }
}
