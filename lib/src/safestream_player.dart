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
///
/// Both backends hand back a shared [SafeStreamPlayerController], so callers
/// (screen-time monitoring, child lock, progress tracking) don't need to
/// know which one is active.
class SafeStreamPlayer extends StatelessWidget {
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

  const SafeStreamPlayer({
    Key? key,
    required this.videoId,
    this.requiresMultiLanguageAudio = false,
    this.autoPlay = true,
    this.startAt,
    this.onControllerCreated,
    this.controls,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (requiresMultiLanguageAudio) {
      return SafeStreamYoutubePlayer(
        videoId: videoId,
        autoPlay: autoPlay,
        startAt: startAt,
        onControllerCreated: onControllerCreated,
        controls: controls,
      );
    }
    return SafeStreamIframePlayer(
      videoId: videoId,
      autoPlay: autoPlay,
      startAt: startAt,
      onControllerCreated: onControllerCreated,
      controls: controls,
    );
  }
}
