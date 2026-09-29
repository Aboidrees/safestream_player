import 'package:flutter/material.dart';

import 'safestream_iframe_player.dart';
import 'safestream_player_controller.dart';
import 'safestream_youtube_player.dart';

/// Picks the right playback backend per video:
///
/// - Default: the official YouTube IFrame Player ([SafeStreamIframePlayer]).
///   ToS-compliant, zero risk of the request-volume throttling/blocking that
///   hits the unofficial resolution path.
/// - [requiresMultiLanguageAudio]: the custom, `youtube_explode_dart`-backed
///   player ([SafeStreamYoutubePlayer]), the only backend that supports
///   switching the audio track on multi-language videos. Reserve this for
///   videos that actually need it — every device playing this backend
///   re-issues (session-cached) calls against YouTube's unofficial internal
///   API, which is the traffic pattern that got the app rate-limited.
/// - [preferredAudioLanguage]: probe the video once (cached) and use the
///   custom player — starting in that language — only when the video has an
///   alternate audio track in it. Otherwise, or if the probe fails, the
///   official player is used.
///
/// Both backends hand back a shared [SafeStreamPlayerController], so callers
/// (screen-time monitoring, child lock, progress tracking) don't need to
/// know which one is active.
class SafeStreamPlayer extends StatefulWidget {
  final String videoId;
  final bool requiresMultiLanguageAudio;
  final bool autoPlay;
  final Duration? startAt;
  final void Function(SafeStreamPlayerController)? onControllerCreated;

  /// Custom controls drawn on top of the video. Must be passed here rather
  /// than stacked over the player by the caller: on mobile the iframe
  /// backend renders its WebView in an OverlayPortal above the whole route,
  /// so anything the caller stacks on top is painted underneath the video
  /// and never receives touches.
  final Widget? controls;

  /// ISO 639-1 code (e.g. 'ar') of the audio language to prefer, or null to
  /// play every video in its original audio.
  final String? preferredAudioLanguage;

  const SafeStreamPlayer({
    Key? key,
    required this.videoId,
    this.requiresMultiLanguageAudio = false,
    this.autoPlay = true,
    this.startAt,
    this.onControllerCreated,
    this.controls,
    this.preferredAudioLanguage,
  }) : super(key: key);

  @override
  State<SafeStreamPlayer> createState() => _SafeStreamPlayerState();
}

class _SafeStreamPlayerState extends State<SafeStreamPlayer> {
  /// Whether the custom player is needed; null while the probe is running.
  bool? _useCustomPlayer;

  /// Upper bound on how long playback waits for the language probe. On a
  /// timeout the video plays in its original audio; the probe keeps running
  /// and its cached answer is used the next time the video opens.
  static const _probeTimeout = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    _decide();
  }

  @override
  void didUpdateWidget(SafeStreamPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId ||
        oldWidget.preferredAudioLanguage != widget.preferredAudioLanguage ||
        oldWidget.requiresMultiLanguageAudio != widget.requiresMultiLanguageAudio) {
      _decide();
    }
  }

  void _decide() {
    final language = widget.preferredAudioLanguage;
    if (widget.requiresMultiLanguageAudio) {
      _useCustomPlayer = true;
      return;
    }
    if (language == null) {
      _useCustomPlayer = false;
      return;
    }
    final known = SafeStreamAudioProbe.cached(widget.videoId, language);
    if (known != null) {
      _useCustomPlayer = known;
      return;
    }

    _useCustomPlayer = null;
    final videoId = widget.videoId;
    SafeStreamAudioProbe.hasAlternateAudio(videoId, language)
        .timeout(_probeTimeout)
        .catchError((Object e) {
          // Blocked / rate-limited / offline: play normally rather than fail.
          debugPrint('SafeStreamPlayer: audio probe failed for $videoId: $e');
          return false;
        })
        .then((hasLanguage) {
          if (!mounted || widget.videoId != videoId) return;
          setState(() => _useCustomPlayer = hasLanguage);
        });
  }

  @override
  Widget build(BuildContext context) {
    final useCustom = _useCustomPlayer;
    if (useCustom == null) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Center(child: CircularProgressIndicator(color: Colors.white70)),
        ),
      );
    }
    if (useCustom) {
      return SafeStreamYoutubePlayer(
        videoId: widget.videoId,
        autoPlay: widget.autoPlay,
        startAt: widget.startAt,
        onControllerCreated: widget.onControllerCreated,
        controls: widget.controls,
        preferredAudioLanguage: widget.preferredAudioLanguage,
      );
    }
    return SafeStreamIframePlayer(
      videoId: widget.videoId,
      autoPlay: widget.autoPlay,
      startAt: widget.startAt,
      onControllerCreated: widget.onControllerCreated,
      controls: widget.controls,
    );
  }
}
