import 'package:flutter/material.dart';

import 'safestream_iframe_player.dart';
import 'safestream_player_controller.dart';
import 'safestream_youtube_player.dart';
import 'unofficial_youtube_gate.dart';

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
/// - [preferredAudioLanguage]: use the custom player — starting in that
///   language — only when the video has an alternate audio track in it.
///   Availability comes from [knownAudioLanguages] (shared by the backend,
///   no YouTube request) or, failing that, one cached probe whose result is
///   handed to [onAudioLanguagesProbed] for sharing. Otherwise the official
///   player plays the original audio.
///
/// Every unofficial request goes through [UnofficialYoutubeGate]: while it is
/// closed (kill switch, or cooling down after YouTube refused a request)
/// everything plays in the official player.
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

  /// The video's alternate audio languages when already known (e.g. shared
  /// by the backend after another device probed it); null when unknown.
  final Set<String>? knownAudioLanguages;

  /// Receives the result of a probe this player had to make, so the caller
  /// can share it and spare other devices the request.
  final ValueChanged<Set<String>>? onAudioLanguagesProbed;

  const SafeStreamPlayer({
    Key? key,
    required this.videoId,
    this.requiresMultiLanguageAudio = false,
    this.autoPlay = true,
    this.startAt,
    this.onControllerCreated,
    this.controls,
    this.preferredAudioLanguage,
    this.knownAudioLanguages,
    this.onAudioLanguagesProbed,
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
    if (!UnofficialYoutubeGate.isOpen) {
      _useCustomPlayer = false;
      return;
    }
    if (widget.requiresMultiLanguageAudio) {
      _useCustomPlayer = true;
      return;
    }
    if (language == null) {
      _useCustomPlayer = false;
      return;
    }
    final known = widget.knownAudioLanguages ?? SafeStreamAudioProbe.cached(widget.videoId);
    if (known != null) {
      _useCustomPlayer = known.contains(language);
      return;
    }

    _useCustomPlayer = null;
    final videoId = widget.videoId;
    final probe = SafeStreamAudioProbe.alternateLanguages(videoId);
    // Share the answer whenever it arrives, even after a timeout below.
    probe.then((languages) => widget.onAudioLanguagesProbed?.call(languages)).ignore();
    probe
        .then((languages) => languages.contains(language))
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

  /// The custom player couldn't load (gate closed or YouTube refused):
  /// fall back to the official player for this video.
  void _fallBackToOfficialPlayer() {
    if (mounted && _useCustomPlayer != false) {
      setState(() => _useCustomPlayer = false);
    }
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
        onLoadFailed: _fallBackToOfficialPlayer,
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
