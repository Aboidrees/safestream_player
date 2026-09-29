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
  final double playbackSpeed;
  /// Display name of the selected audio track, or null for the default.
  final String? currentLanguage;

  /// Display names of the switchable audio tracks; empty when the backend
  /// can't switch audio (callers should hide language UI).
  final List<String> availableLanguages;

  const SafeStreamPlayerValue({
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.isPlaying = false,
    this.isEnded = false,
    this.playbackSpeed = 1.0,
    this.currentLanguage,
    this.availableLanguages = const <String>[],
  });

  SafeStreamPlayerValue copyWith({
    Duration? duration,
    Duration? position,
    bool? isPlaying,
    bool? isEnded,
    double? playbackSpeed,
    String? currentLanguage,
    List<String>? availableLanguages,
  }) {
    return SafeStreamPlayerValue(
      duration: duration ?? this.duration,
      position: position ?? this.position,
      isPlaying: isPlaying ?? this.isPlaying,
      isEnded: isEnded ?? this.isEnded,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      currentLanguage: currentLanguage ?? this.currentLanguage,
      availableLanguages: availableLanguages ?? this.availableLanguages,
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

  /// Changes the playback rate/speed (e.g. 0.5, 0.75, 1.0, 1.25, 1.5, 2.0).
  void setPlaybackSpeed(double speed);

  /// Switches the audio track. [language] must be one of
  /// [SafeStreamPlayerValue.availableLanguages]; backends that can't switch
  /// audio expose an empty list and ignore the call.
  void setLanguage(String language);

  /// Releases the underlying player resources. Named distinctly from
  /// [dispose] (owned by [ChangeNotifier]) so backends can clean up their
  /// native player before the notifier itself is torn down.
  Future<void> disposePlayer();
}
