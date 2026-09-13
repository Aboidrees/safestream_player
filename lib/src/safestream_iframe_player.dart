import 'dart:async';

import 'package:flutter/material.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import 'safestream_player_controller.dart';

/// Wraps the official [YoutubePlayerController] (IFrame Player API — ToS
/// compliant, not rate-limited/blockable the way the unofficial
/// `youtube_explode_dart` resolution path is) to satisfy the shared
/// [SafeStreamPlayerController] contract.
///
/// `duration` on the underlying controller is a `Future`, not a stream, so
/// it's polled on an interval and cached rather than pushed on every value
/// change.
class _IframeControllerAdapter extends SafeStreamPlayerController {
  final YoutubePlayerController _controller;
  StreamSubscription<YoutubeVideoState>? _positionSub;
  StreamSubscription<YoutubePlayerValue>? _stateSub;
  Timer? _durationPoll;

  _IframeControllerAdapter(this._controller) {
    _positionSub = _controller.videoStateStream.listen((state) {
      value = value.copyWith(position: state.position);
    });
    _stateSub = _controller.stream.listen((playerValue) {
      final isPlaying = playerValue.playerState == PlayerState.playing;
      final isEnded = playerValue.playerState == PlayerState.ended;
      value = value.copyWith(
        isPlaying: isPlaying,
        isEnded: isEnded,
        playbackSpeed: playerValue.playbackRate,
      );
    });
    _durationPoll = Timer.periodic(const Duration(seconds: 3), (_) async {
      final seconds = await _controller.duration;
      if (seconds > 0) {
        value = value.copyWith(duration: Duration(milliseconds: (seconds * 1000).round()));
      }
    });
  }

  @override
  void play() => _controller.playVideo();

  @override
  void pause() => _controller.pauseVideo();

  @override
  void seekTo(Duration position) {
    _controller.seekTo(seconds: position.inMilliseconds / 1000.0, allowSeekAhead: true);
    // The iframe only streams position updates while playing — reflect the
    // seek immediately so a scrub while paused doesn't leave the overlay's
    // progress bar showing the stale position.
    value = value.copyWith(position: position);
  }

  @override
  void setPlaybackSpeed(double speed) {
    _controller.setPlaybackRate(speed);
    value = value.copyWith(playbackSpeed: speed);
  }

  @override
  void setLanguage(String languageCode) {
    value = value.copyWith(currentLanguage: languageCode);
  }

  @override
  Future<void> disposePlayer() async {
    _durationPoll?.cancel();
    await _positionSub?.cancel();
    await _stateSub?.cancel();
    await _controller.close();
  }
}

/// Official YouTube IFrame Player — default SafeStream player backend.
///
/// Compliant with YouTube's terms of service and not subject to the
/// request-volume throttling/blocking risk of the unofficial
/// `youtube_explode_dart`-based [SafeStreamYoutubePlayer]. Does not support
/// picking an alternate audio-language track (that capability requires the
/// custom player) — use [SafeStreamPlayer] to pick the right backend per
/// video rather than instantiating this widget directly.
class SafeStreamIframePlayer extends StatefulWidget {
  final String videoId;
  final bool autoPlay;
  final Duration? startAt;

  /// Whether to show YouTube's own player chrome. Off by default: the app
  /// draws its own kid-friendly overlay controls (which also keeps YouTube's
  /// fullscreen button — and the fullscreen restart loop it triggers — out
  /// of reach of small fingers).
  final bool showNativeControls;

  final void Function(SafeStreamPlayerController)? onControllerCreated;

  const SafeStreamIframePlayer({
    Key? key,
    required this.videoId,
    this.autoPlay = true,
    this.startAt,
    this.showNativeControls = false,
    this.onControllerCreated,
  }) : super(key: key);

  @override
  State<SafeStreamIframePlayer> createState() => _SafeStreamIframePlayerState();
}

class _SafeStreamIframePlayerState extends State<SafeStreamIframePlayer> {
  late final YoutubePlayerController _controller;
  late final _IframeControllerAdapter _adapter;

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController.fromVideoId(
      videoId: widget.videoId,
      autoPlay: widget.autoPlay,
      startSeconds: widget.startAt?.inSeconds.toDouble() ?? 0,
      params: YoutubePlayerParams(
        showControls: widget.showNativeControls,
        // Never expose YouTube's fullscreen button: entering the package's
        // fullscreen mode re-parents the WebView (reloading the video from
        // zero) and flips its internal PopScope to swallow the back button —
        // the exact restart-on-back loop reported on TV/tablet/mobile.
        showFullscreenButton: false,
        strictRelatedVideos: true,
        privacyEnhancedMode: true,
        enableJavaScript: true,
        enableCaption: true,
        pointerEvents: PointerEvents.none,
      ),
    );
    _adapter = _IframeControllerAdapter(_controller);
    widget.onControllerCreated?.call(_adapter);
  }

  @override
  void didUpdateWidget(SafeStreamIframePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId) {
      _controller.loadVideoById(videoId: widget.videoId);
    }
  }

  @override
  void dispose() {
    _adapter.disposePlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: IgnorePointer(
        ignoring: true,
        child: YoutubePlayer(
          controller: _controller,
          aspectRatio: 16 / 9,
          // ROOT CAUSE of the restart-on-back bug: this defaults to true, and
          // on any landscape screen (Android TV is *always* landscape) the
          // package force-enters its fullscreen mode. That (a) re-parents the
          // WebView, reloading the video from 0:00, and (b) flips the
          // package's internal PopScope to canPop:false, so back only exits
          // fullscreen — which the next frame's didChangeMetrics immediately
          // re-enters. Result: back never closes the player and every press
          // restarts the video. The player already fills our screen edge to
          // edge; the package's fullscreen mode adds nothing but the loop.
          autoFullScreen: false,
          enableFullScreenOnVerticalDrag: false,
        ),
      ),
    );
  }
}
