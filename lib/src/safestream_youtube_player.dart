import 'package:flutter/material.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:just_audio/just_audio.dart';

class SafeStreamYoutubePlayer extends StatefulWidget {
  final String videoId;
  final bool autoPlay;
  final Duration? startAt;
  final void Function(VideoPlayerController)? onControllerCreated;

  const SafeStreamYoutubePlayer({
    Key? key,
    required this.videoId,
    this.autoPlay = true,
    this.startAt,
    this.onControllerCreated,
  }) : super(key: key);

  @override
  State<SafeStreamYoutubePlayer> createState() => _SafeStreamYoutubePlayerState();
}

class _SafeStreamYoutubePlayerState extends State<SafeStreamYoutubePlayer> {
  final YoutubeExplode _yt = YoutubeExplode();
  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;
  AudioPlayer? _audioPlayer;
  
  List<AudioOnlyStreamInfo> _audioTracks = [];
  AudioOnlyStreamInfo? _selectedAudioTrack;
  
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      // 1. Get stream manifest
      final manifest = await _yt.videos.streamsClient.getManifest(widget.videoId);
      if (!mounted) return;
      
      // 2. We want a muxed stream (video + audio combined, usually max 720p).
      // This is the safest bet for mobile/TV without complex audio syncing.
      final streamInfo = manifest.muxed.bestQuality;
      
      // Store audio tracks for language selection
      _audioTracks = manifest.audioOnly.toList();

      // 3. Initialize VideoPlayer with the raw URL
      _videoPlayerController = VideoPlayerController.networkUrl(streamInfo.url);
      
      await _videoPlayerController!.initialize();
      if (!mounted) {
        _videoPlayerController?.dispose();
        return;
      }

      if (widget.startAt != null) {
        await _videoPlayerController!.seekTo(widget.startAt!);
        if (!mounted) return;
      }

      if (widget.onControllerCreated != null) {
        widget.onControllerCreated!(_videoPlayerController!);
      }
      
      // Initialize AudioPlayer
      _audioPlayer = AudioPlayer();

      // Keep them in sync
      _videoPlayerController!.addListener(_syncAudioWithVideo);

      // 4. Wrap with Chewie for the UI overlay
      _chewieController = ChewieController(
        videoPlayerController: _videoPlayerController!,
        autoPlay: widget.autoPlay,
        looping: false,
        allowFullScreen: true,
        allowMuting: true,
        allowPlaybackSpeedChanging: true, // Restored default
        additionalOptions: (context) {
          if (_audioTracks.isEmpty) return [];
          
          return [
            OptionItem(
              onTap: (context) {
                // Pop the Chewie options bottom sheet
                Navigator.pop(context);
                // Show our language selection bottom sheet
                showModalBottomSheet(
                  context: context,
                  builder: (context) {
                    return SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Padding(
                            padding: EdgeInsets.all(16.0),
                            child: Text('Language Options', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                          ),
                          Expanded(
                            child: ListView(
                              shrinkWrap: true,
                              children: _audioTracks.map((track) {
                                final isSelected = _selectedAudioTrack == track;
                                final name = track.audioTrack?.displayName ?? 'Audio Track (Bitrate: ${(track.bitrate.kiloBitsPerSecond).toStringAsFixed(0)} kbps)';
                                return ListTile(
                                  leading: isSelected ? const Icon(Icons.check) : const SizedBox(width: 24),
                                  title: Text(name),
                                  onTap: () {
                                    Navigator.of(context).pop();
                                    _onAudioTrackSelected(track);
                                  },
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
              iconData: Icons.language,
              title: 'Language',
              subtitle: _selectedAudioTrack?.audioTrack?.displayName ?? 'Default',
            ),
          ];
        },
      );

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error initializing SafeStreamYoutubePlayer: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load video: $e';
        });
      }
    }
  }

  void _syncAudioWithVideo() {
    if (_audioPlayer == null || _videoPlayerController == null || _selectedAudioTrack == null) return;
    
    final videoIsPlaying = _videoPlayerController!.value.isPlaying;
    final audioIsPlaying = _audioPlayer!.playing;
    
    // Sync play state
    if (videoIsPlaying && !audioIsPlaying) {
      _audioPlayer!.play().catchError((e) => debugPrint('Audio play error: $e'));
    } else if (!videoIsPlaying && audioIsPlaying) {
      _audioPlayer!.pause().catchError((e) => debugPrint('Audio pause error: $e'));
    }
    
    // Sync position if it drifts by more than 500ms
    final videoPos = _videoPlayerController!.value.position;
    final audioPos = _audioPlayer!.position;
    
    if ((videoPos - audioPos).inMilliseconds.abs() > 500) {
      _audioPlayer!.seek(videoPos).catchError((e) => debugPrint('Audio seek error: $e'));
    }
  }

  void _onAudioTrackSelected(AudioOnlyStreamInfo track) async {
    if (_audioPlayer == null || _videoPlayerController == null) return;
    
    setState(() {
      _selectedAudioTrack = track;
    });
    
    // Mute the main video to hear the alternate audio track
    await _videoPlayerController!.setVolume(0);
    
    try {
      // Load the new audio URL
      await _audioPlayer!.setUrl(track.url.toString());
      
      // Sync position
      final position = _videoPlayerController!.value.position;
      await _audioPlayer!.seek(position);
      
      // Play or pause based on video state
      if (_videoPlayerController!.value.isPlaying) {
        _audioPlayer!.play();
      }
    } catch (e) {
      // PlayerInterruptedException can occur if setUrl is interrupted by another load/seek.
      debugPrint('Error loading audio track: $e');
    }
  }

  @override
  void didUpdateWidget(SafeStreamYoutubePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId) {
      _disposeControllers();
      setState(() {
        _isLoading = true;
        _errorMessage = null;
        _selectedAudioTrack = null;
        _audioTracks = [];
      });
      _initPlayer();
    }
  }

  void _disposeControllers() {
    _chewieController?.dispose();
    _chewieController = null;
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _audioPlayer?.dispose().catchError((e) => debugPrint('Audio dispose error: $e'));
    _audioPlayer = null;
  }

  @override
  void dispose() {
    _disposeControllers();
    _yt.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          child: const Center(
            child: CircularProgressIndicator(color: Colors.red),
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    if (_chewieController != null) {
      // The aspect ratio can be enforced here, or we can use the video's actual aspect ratio
      return AspectRatio(
        aspectRatio: _videoPlayerController!.value.aspectRatio,
        child: Chewie(controller: _chewieController!),
      );
    }

    return const SizedBox.shrink();
  }
}
