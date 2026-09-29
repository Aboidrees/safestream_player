import 'package:flutter_test/flutter_test.dart';
import 'package:safestream_player/safestream_player.dart';

void main() {
  setUp(UnofficialYoutubeGate.reset);

  test('open by default', () {
    expect(UnofficialYoutubeGate.isOpen, isTrue);
  });

  test('kill switch closes the gate', () {
    UnofficialYoutubeGate.enabled = false;
    expect(UnofficialYoutubeGate.isOpen, isFalse);
  });

  test('trip closes the gate for the cooldown and reports the deadline', () {
    DateTime? reported;
    UnofficialYoutubeGate.onTripped = (until) => reported = until;

    UnofficialYoutubeGate.trip('429 Too Many Requests');

    expect(UnofficialYoutubeGate.isOpen, isFalse);
    expect(reported, isNotNull);
    expect(
      reported!.difference(DateTime.now()).inMinutes,
      closeTo(UnofficialYoutubeGate.cooldown.inMinutes, 1),
    );
  });

  test('restore ignores deadlines in the past', () {
    UnofficialYoutubeGate.restore(DateTime.now().subtract(const Duration(minutes: 1)));
    expect(UnofficialYoutubeGate.isOpen, isTrue);
  });

  test('probe refuses without a request while the gate is closed', () async {
    UnofficialYoutubeGate.enabled = false;
    await expectLater(
      SafeStreamAudioProbe.alternateLanguages('no-such-video'),
      throwsA(isA<UnofficialYoutubeBlocked>()),
    );
  });
}
