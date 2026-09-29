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
        value = value.copyWith(
            duration: Duration(milliseconds: (seconds * 1000).round()));
      }
    });
  }

  @override
  void play() => _controller.playVideo();

  @override
  void pause() => _controller.pauseVideo();

  @override
  void seekTo(Duration position) {
    _controller.seekTo(
        seconds: position.inMilliseconds / 1000.0, allowSeekAhead: true);
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

  /// The IFrame API can't switch the audio track, so this backend exposes
  /// no [SafeStreamPlayerValue.availableLanguages] and ignores the call
  /// rather than reporting a language that isn't actually playing.
  @override
  void setLanguage(String language) {}

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

  /// Custom controls drawn on top of the video. Must be passed here rather
  /// than stacked over the player by the caller: on mobile the iframe
  /// backend renders its WebView in an OverlayPortal above the whole route,
  /// so anything the caller stacks on top is painted underneath the video
  /// and never receives touches.
  final Widget? controls;

  const SafeStreamIframePlayer({
    Key? key,
    required this.videoId,
    this.autoPlay = true,
    this.startAt,
    this.showNativeControls = false,
    this.onControllerCreated,
    this.controls,
  }) : super(key: key);

  @override
  State<SafeStreamIframePlayer> createState() => _SafeStreamIframePlayerState();
}

class _SafeStreamIframePlayerState extends State<SafeStreamIframePlayer> {
  late final YoutubePlayerController _controller;
  late final _IframeControllerAdapter _adapter;
  StreamSubscription<YoutubePlayerValue>? _curtainSub;
  Timer? _curtainTimer;

  /// Opaque cover between the WebView and the controls. The embed draws its
  /// own title bar, "More videos" tray and logo whenever playback is paused,
  /// not yet started or ended — and for a moment after it resumes — and the
  /// IFrame API has no option to turn that off. Covering those states keeps
  /// YouTube's chrome (and its links out) away from the child.
  bool _curtain = true;

  /// How long YouTube keeps its chrome visible after playback resumes.
  static const _chromeFadeDelay = Duration(milliseconds: 2500);

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
        // The embed must never react to touches itself — taps belong to the
        // custom controls drawn above it.
        pointerEvents: PointerEvents.none,
      ),
    );
    _adapter = _IframeControllerAdapter(_controller);
    _curtainSub = _controller.stream.listen(_onPlayerState);
    widget.onControllerCreated?.call(_adapter);
  }

  void _onPlayerState(YoutubePlayerValue value) {
    switch (value.playerState) {
      case PlayerState.playing:
        if (_curtain && _curtainTimer == null) {
          _curtainTimer = Timer(_chromeFadeDelay, () {
            _curtainTimer = null;
            if (mounted) setState(() => _curtain = false);
          });
        }
      case PlayerState.buffering:
        // Mid-playback buffering shows no chrome — leave the curtain as is
        // so playback doesn't flicker.
        break;
      default:
        _curtainTimer?.cancel();
        _curtainTimer = null;
        if (!_curtain && mounted) setState(() => _curtain = true);
    }
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
    _curtainTimer?.cancel();
    _curtainSub?.cancel();
    _adapter.disposePlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
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
        // Rendered inside the package's OverlayPortal, above the WebView,
        // so the controls are visible and win the hit test over it.
        controlsBuilder: (context, isFullscreen) => Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: _curtain ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: ColoredBox(
                  color: Colors.black,
                  child: Image.network(
                    'https://i.ytimg.com/vi/${widget.videoId}/hqdefault.jpg',
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
            if (widget.controls != null) widget.controls!,
          ],
        ),
      ),
    );
  }
}
