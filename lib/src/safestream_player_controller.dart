import 'package:flutter/foundation.dart';

/// Playback state shared by every SafeStream player backend, so callers
/// (screen-time monitoring, child lock, progress tracking, autoplay) can
/// depend on one shape regardless of which backend is rendering the video.
@immutable
class SafeStreamPlayerValue {
  final Duration duration;
  final Duration position;
  final bool isPlaying;
  final bool isEnded;

  const SafeStreamPlayerValue({
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.isPlaying = false,
    this.isEnded = false,
  });

  SafeStreamPlayerValue copyWith({
    Duration? duration,
    Duration? position,
    bool? isPlaying,
    bool? isEnded,
  }) {
    return SafeStreamPlayerValue(
      duration: duration ?? this.duration,
      position: position ?? this.position,
      isPlaying: isPlaying ?? this.isPlaying,
      isEnded: isEnded ?? this.isEnded,
    );
  }
}

/// Backend-agnostic playback handle. `SafeStreamYoutubePlayer` (custom,
/// multi-audio-track) and `SafeStreamIframePlayer` (official embed) each
/// hand one of these back via `onControllerCreated` instead of a
/// backend-specific controller type.
abstract class SafeStreamPlayerController extends ValueNotifier<SafeStreamPlayerValue> {
  SafeStreamPlayerController() : super(const SafeStreamPlayerValue());

  void play();
  void pause();

  /// Jumps playback to [position]. Used by the custom control overlay
  /// (rewind/forward buttons, scrubber) and by resume-playback.
  void seekTo(Duration position);

  /// Releases the underlying player resources. Named distinctly from
  /// [dispose] (owned by [ChangeNotifier]) so backends can clean up their
  /// native player before the notifier itself is torn down.
  Future<void> disposePlayer();
}
