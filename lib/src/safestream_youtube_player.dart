import 'package:flutter/material.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:just_audio/just_audio.dart';

import 'safestream_player_controller.dart';

/// Wraps a raw [VideoPlayerController] so it satisfies the backend-agnostic
/// [SafeStreamPlayerController] contract consumed by the host app.
class _VideoPlayerControllerAdapter extends SafeStreamPlayerController {
  final VideoPlayerController _controller;
  final void Function(String)? onLanguageChange;

  _VideoPlayerControllerAdapter(this._controller, {this.onLanguageChange}) {
    _controller.addListener(_sync);
    _sync();
  }

  void _sync() {
    final dur = _controller.value.duration;
    final pos = _controller.value.position;
    final isEnded = dur.inSeconds > 0 && pos >= dur;
    value = value.copyWith(
      duration: dur,
      position: pos,
      isPlaying: _controller.value.isPlaying,
      isEnded: isEnded,
      playbackSpeed: _controller.value.playbackSpeed,
    );
  }

  @override
  void play() => _controller.play();

  @override
  void pause() => _controller.pause();

  @override
  void seekTo(Duration position) => _controller.seekTo(position);

  @override
  void setPlaybackSpeed(double speed) {
    _controller.setPlaybackSpeed(speed);
    value = value.copyWith(playbackSpeed: speed);
  }

  @override
  void setLanguage(String language) {
    if (!value.availableLanguages.contains(language)) return;
    onLanguageChange?.call(language);
    value = value.copyWith(currentLanguage: language);
  }

  @override
  Future<void> disposePlayer() async {
    _controller.removeListener(_sync);
  }
}

/// In-memory cache of resolved stream manifests, keyed by video ID.
///
/// Manifest resolution (`getManifest`) is the expensive, YouTube-rate-limited
/// call — it was previously re-issued on every quality switch and every
/// re-init of the same video within a session. Stream URLs stay valid for
/// hours, so within-session reuse is safe and removes that redundant traffic
/// entirely. This is process-local (cleared on app restart); it does not
/// reduce cross-device duplicate traffic — that requires a server-side cache.
class _ManifestCache {
  static final Map<String, _CachedManifest> _cache = {};
  static const Duration _ttl = Duration(hours: 4);

  static StreamManifest? get(String videoId) {
    final entry = _cache[videoId];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.fetchedAt) > _ttl) {
      _cache.remove(videoId);
      return null;
    }
    return entry.manifest;
  }

  static void put(String videoId, StreamManifest manifest) {
    _cache[videoId] = _CachedManifest(manifest, DateTime.now());
  }
}

/// Language code of an audio track: YouTube ids look like `ar.3` or
/// `en-US.4`; the part before the first `.`/`-` is the ISO 639-1 code.
String? _trackLanguage(AudioOnlyStreamInfo t) {
  final id = t.audioTrack?.id;
  if (id == null || id.isEmpty) return null;
  return id.split('.').first.split('-').first.toLowerCase();
}

/// Best-bitrate track in [language] that is *not* the video's original
/// audio (the muxed stream — and the official player — already play that).
AudioOnlyStreamInfo? _alternateTrackFor(Iterable<AudioOnlyStreamInfo> tracks, String language) {
  final matches = tracks
      .where((t) => _trackLanguage(t) == language && t.audioTrack?.audioIsDefault != true)
      .toList()
    ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
  return matches.isEmpty ? null : matches.first;
}

/// Answers "does this video have an alternate audio track in language X?"
/// so [SafeStreamPlayer] can keep the official player unless the preferred
/// language is really available. Shares [_ManifestCache] with the custom
/// player, so a positive answer costs no second fetch; answers are cached.
class SafeStreamAudioProbe {
  SafeStreamAudioProbe._();

  static final Map<String, bool> _answers = {};

  /// Cached answer, or null when the video hasn't been probed yet.
  static bool? cached(String videoId, String language) => _answers['$videoId|$language'];

  static Future<bool> hasAlternateAudio(String videoId, String language) async {
    final key = '$videoId|$language';
    final known = _answers[key];
    if (known != null) return known;

    var manifest = _ManifestCache.get(videoId);
    if (manifest == null) {
      final yt = YoutubeExplode();
      try {
        manifest = await yt.videos.streamsClient.getManifest(videoId);
        _ManifestCache.put(videoId, manifest);
      } finally {
        yt.close();
      }
    }
    return _answers[key] = _alternateTrackFor(manifest.audioOnly, language) != null;
  }
}

class _CachedManifest {
  final StreamManifest manifest;
  final DateTime fetchedAt;
  _CachedManifest(this.manifest, this.fetchedAt);
}

class SafeStreamYoutubePlayer extends StatefulWidget {
  final String videoId;
  final bool autoPlay;
  final Duration? startAt;
  final void Function(SafeStreamPlayerController)? onControllerCreated;

  /// Custom controls drawn on top of the video.
  final Widget? controls;

  /// ISO 639-1 code of the audio track to start with, when the video has an
  /// alternate track in that language (e.g. set by a parent).
  final String? preferredAudioLanguage;

  const SafeStreamYoutubePlayer({
    Key? key,
    required this.videoId,
    this.autoPlay = true,
    this.startAt,
    this.onControllerCreated,
    this.controls,
    this.preferredAudioLanguage,
  }) : super(key: key);

  @override
  State<SafeStreamYoutubePlayer> createState() => _SafeStreamYoutubePlayerState();
}

class _SafeStreamYoutubePlayerState extends State<SafeStreamYoutubePlayer> {
  final YoutubeExplode _yt = YoutubeExplode();
  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;
  AudioPlayer? _audioPlayer;
  _VideoPlayerControllerAdapter? _controllerAdapter;

  List<VideoStreamInfo> _qualityTracks = [];
  VideoStreamInfo? _selectedQualityTrack;

  List<AudioOnlyStreamInfo> _audioTracks = [];
  AudioOnlyStreamInfo? _selectedAudioTrack;

  bool _isLoading = true;
  bool _isSwitchingQuality = false;
  bool _isChangingAudio = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer({Duration? resumePosition}) async {
    try {
      // 1. Get stream manifest (reuse within-session cache when available —
      // avoids re-hitting YouTube on every quality switch / re-init of the
      // same video, see _ManifestCache).
      final cached = _ManifestCache.get(widget.videoId);
      final StreamManifest manifest;
      if (cached != null) {
        manifest = cached;
      } else {
        manifest = await _yt.videos.streamsClient.getManifest(widget.videoId);
        _ManifestCache.put(widget.videoId, manifest);
      }
      if (!mounted) return;

      // Extract muxed video streams for quality selection
      final muxedStreams = manifest.muxed.toList();
      muxedStreams.sort((a, b) => b.videoQuality.index.compareTo(a.videoQuality.index));
      _qualityTracks = muxedStreams;

      // Select default stream: prioritize smooth 720p/480p streams for TV hardware compatibility
      final VideoStreamInfo streamInfo = _selectedQualityTrack ??
          muxedStreams.firstWhere(
            (s) => s.qualityLabel.contains('720') || s.qualityLabel.contains('480'),
            orElse: () => muxedStreams.isNotEmpty ? muxedStreams.first : manifest.muxed.bestQuality,
          );
      _selectedQualityTrack = streamInfo;

      // Extract audio tracks
      _audioTracks = manifest.audioOnly.toList();
      final preferred = widget.preferredAudioLanguage;
      final AudioOnlyStreamInfo? initialTrack = _selectedAudioTrack == null && preferred != null
          ? _alternateTrackFor(_audioTracks, preferred)
          : null;

      // 2. Initialize VideoPlayerController with streaming headers to prevent throttling
      final newVideoController = VideoPlayerController.networkUrl(
        streamInfo.url,
        httpHeaders: const {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 11; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36',
          'Accept': '*/*',
          'Accept-Encoding': 'identity',
          'Connection': 'keep-alive',
        },
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await newVideoController.initialize();
      if (!mounted) {
        newVideoController.dispose();
        return;
      }

      // Preserve or seek to initial position
      final targetSeek = resumePosition ?? widget.startAt;
      if (targetSeek != null) {
        await newVideoController.seekTo(targetSeek);
      }

      // Dispose previous controller if re-initializing quality
      _videoPlayerController?.removeListener(_syncAudioWithVideo);
      _videoPlayerController?.dispose();
      _videoPlayerController = newVideoController;

      await _controllerAdapter?.disposePlayer();
      _controllerAdapter = _VideoPlayerControllerAdapter(
        _videoPlayerController!,
        onLanguageChange: (lang) {
          // Exact match on the track's display name (the values exposed in
          // availableLanguages). Substring matching picked the wrong track:
          // 'en' matched "French", 'ar' matched "Bulgarian". YouTube lists
          // each language at several bitrates — take the best one.
          final candidates = _audioTracks
              .where((t) => t.audioTrack?.displayName == lang)
              .toList()
            ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
          if (candidates.isNotEmpty) {
            _onAudioTrackSelected(candidates.first);
          }
        },
      );
      // One entry per language (manifests repeat a language per bitrate).
      final availableLanguages = _audioTracks
          .map((t) => t.audioTrack?.displayName ?? '')
          .where((l) => l.isNotEmpty)
          .toSet()
          .toList();
      _controllerAdapter!.value = _controllerAdapter!.value.copyWith(
        availableLanguages: availableLanguages,
        currentLanguage: _selectedAudioTrack?.audioTrack?.displayName,
      );

      if (widget.onControllerCreated != null) {
        widget.onControllerCreated!(_controllerAdapter!);
      }

      // Only attach audio sync listener if an alternate audio track is selected
      if (_selectedAudioTrack != null) {
        _audioPlayer ??= AudioPlayer();
        // Re-init (quality switch) creates a fresh, unmuted video controller:
        // keep its own audio silent or both soundtracks play together.
        await _videoPlayerController!.setVolume(0);
        _videoPlayerController!.addListener(_syncAudioWithVideo);
      }

      // 3. Setup ChewieController (native controls disabled in favor of custom overlay)
      _chewieController?.dispose();
      _chewieController = ChewieController(
        videoPlayerController: _videoPlayerController!,
        autoPlay: widget.autoPlay || resumePosition != null,
        looping: false,
        showControls: false,
        allowFullScreen: false,
        allowMuting: true,
        allowPlaybackSpeedChanging: false,
        materialProgressColors: ChewieProgressColors(
          playedColor: const Color(0xFFEF4E50),
          handleColor: const Color(0xFFEF4E50),
          backgroundColor: Colors.white24,
          bufferedColor: Colors.white60,
        ),
        additionalOptions: (context) {
          final options = <OptionItem>[];

          // ── 1. Quality Selection ──────────────────────────────────────────
          if (_qualityTracks.isNotEmpty) {
            options.add(
              OptionItem(
                onTap: (context) {
                  Navigator.pop(context);
                  _showQualityPicker(context);
                },
                iconData: Icons.settings,
                title: 'Quality',
                subtitle: _selectedQualityTrack?.qualityLabel ?? 'Auto',
              ),
            );
          }

          // ── 2. Language Selection ─────────────────────────────────────────
          if (_audioTracks.isNotEmpty) {
            options.add(
              OptionItem(
                onTap: (context) {
                  Navigator.pop(context);
                  _showLanguagePicker(context);
                },
                iconData: Icons.language,
                title: 'Language',
                subtitle: _selectedAudioTrack?.audioTrack?.displayName ?? 'Default',
              ),
            );
          }

          return options;
        },
      );

      if (mounted) {
        setState(() {
          _isLoading = false;
          _isSwitchingQuality = false;
        });
      }

      // Start in the preferred language when the video has it.
      if (initialTrack != null && mounted) {
        _onAudioTrackSelected(initialTrack);
      }
    } catch (e) {
      debugPrint('Error initializing SafeStreamYoutubePlayer: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isSwitchingQuality = false;
          _errorMessage = 'Failed to load video. Please check connection.';
        });
      }
    }
  }

  void _syncAudioWithVideo() {
    if (_isChangingAudio ||
        _isSwitchingQuality ||
        _audioPlayer == null ||
        _videoPlayerController == null ||
        _selectedAudioTrack == null) {
      return;
    }

    final videoVal = _videoPlayerController!.value;
    if (!videoVal.isInitialized || videoVal.isBuffering) return;

    final videoIsPlaying = videoVal.isPlaying;
    final audioIsPlaying = _audioPlayer!.playing;

    // Sync play state without throwing
    if (videoIsPlaying && !audioIsPlaying) {
      _audioPlayer!.play().catchError((e) => debugPrint('Audio play error: $e'));
    } else if (!videoIsPlaying && audioIsPlaying) {
      _audioPlayer!.pause().catchError((e) => debugPrint('Audio pause error: $e'));
    }

    // Sync position if it drifts by more than 1000ms
    final videoPos = videoVal.position;
    final audioPos = _audioPlayer!.position;

    if ((videoPos - audioPos).inMilliseconds.abs() > 1000) {
      _audioPlayer!.seek(videoPos).catchError((e) => debugPrint('Audio seek error: $e'));
    }
  }

  void _onQualityTrackSelected(VideoStreamInfo track) async {
    if (_videoPlayerController == null || _selectedQualityTrack == track) return;

    final currentPosition = _videoPlayerController!.value.position;
    setState(() {
      _selectedQualityTrack = track;
      _isSwitchingQuality = true;
    });

    await _initPlayer(resumePosition: currentPosition);
  }

  void _onAudioTrackSelected(AudioOnlyStreamInfo track) async {
    if (_videoPlayerController == null) return;
    // Created lazily on the first switch — previously this bailed out when
    // no alternate track had been selected yet, so switching never started.
    _audioPlayer ??= AudioPlayer();

    setState(() {
      _selectedAudioTrack = track;
      _isChangingAudio = true;
    });
    // Keep the shared controller in sync (the overlay's language menu reads
    // it), including when the track was picked automatically.
    final adapter = _controllerAdapter;
    if (adapter != null) {
      adapter.value = adapter.value.copyWith(currentLanguage: track.audioTrack?.displayName);
    }

    // Mute video track so alternate audio is heard
    await _videoPlayerController!.setVolume(0);

    try {
      await _audioPlayer!.stop();
      await _audioPlayer!.setUrl(track.url.toString());

      final currentPos = _videoPlayerController!.value.position;
      await _audioPlayer!.seek(currentPos);

      if (_videoPlayerController!.value.isPlaying) {
        await _audioPlayer!.play();
      }
      _videoPlayerController?.removeListener(_syncAudioWithVideo);
      _videoPlayerController?.addListener(_syncAudioWithVideo);
    } catch (e) {
      debugPrint('Error loading audio track safely: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isChangingAudio = false;
        });
      }
    }
  }

  void _showQualityPicker(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Video Quality',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: _qualityTracks.map((track) {
                    final isSelected = _selectedQualityTrack == track;
                    final label = track.qualityLabel;
                    return ListTile(
                      leading: isSelected
                          ? const Icon(Icons.check_circle_rounded, color: Color(0xFFEF4E50))
                          : const SizedBox(width: 24),
                      title: Text(
                        label,
                        style: TextStyle(
                          color: isDark ? Colors.white : Colors.black87,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _onQualityTrackSelected(track);
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
  }

  void _showLanguagePicker(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Audio Language / Track',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: _audioTracks.map((track) {
                    final isSelected = _selectedAudioTrack == track;
                    final name = track.audioTrack?.displayName ??
                        'Audio Track (${(track.bitrate.kiloBitsPerSecond).toStringAsFixed(0)} kbps)';
                    return ListTile(
                      leading: isSelected
                          ? const Icon(Icons.check_circle_rounded, color: Color(0xFFEF4E50))
                          : const SizedBox(width: 24),
                      title: Text(
                        name,
                        style: TextStyle(
                          color: isDark ? Colors.white : Colors.black87,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      onTap: () {
                        Navigator.of(ctx).pop();
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
  }

  @override
  void didUpdateWidget(SafeStreamYoutubePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId) {
      _disposeControllers();
      setState(() {
        _isLoading = true;
        _errorMessage = null;
        _selectedQualityTrack = null;
        _selectedAudioTrack = null;
        _qualityTracks = [];
        _audioTracks = [];
      });
      _initPlayer();
    }
  }

  void _disposeControllers() {
    _videoPlayerController?.removeListener(_syncAudioWithVideo);
    _chewieController?.dispose();
    _chewieController = null;
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _controllerAdapter?.disposePlayer();
    _controllerAdapter = null;
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
    if (_isLoading || _isSwitchingQuality) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          child: const Center(
            child: CircularProgressIndicator(color: Color(0xFFEF4E50)),
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
                style: const TextStyle(color: Color(0xFFEF4E50)),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    if (_chewieController != null) {
      return AspectRatio(
        aspectRatio: _videoPlayerController?.value.aspectRatio ?? 16 / 9,
        child: widget.controls == null
            ? Chewie(controller: _chewieController!)
            : Stack(
                fit: StackFit.expand,
                children: [
                  Chewie(controller: _chewieController!),
                  widget.controls!,
                ],
              ),
      );
    }

    return const SizedBox.shrink();
  }
}
