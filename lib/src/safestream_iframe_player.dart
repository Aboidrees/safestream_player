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
      value = value.copyWith(isPlaying: playerValue.playerState == PlayerState.playing);
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
  final void Function(SafeStreamPlayerController)? onControllerCreated;

  const SafeStreamIframePlayer({
    Key? key,
    required this.videoId,
    this.autoPlay = true,
    this.startAt,
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
      params: const YoutubePlayerParams(
        showControls: true,
        showFullscreenButton: true,
        strictRelatedVideos: true,
        privacyEnhancedMode: true,
        enableJavaScript: true,
        enableCaption: true,
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
      child: YoutubePlayer(controller: _controller, aspectRatio: 16 / 9),
    );
  }
}
