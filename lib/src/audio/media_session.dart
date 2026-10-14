import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:logging/logging.dart';

import '../engine/radio_types.dart';
import '../radio/art_cache.dart';
import '../radio/band_plan.dart';
import '../radio/radio_controller.dart';
import '../radio/radio_state.dart';

final _log = Logger('media');

/// Wires the receiver into the OS media session: notification / lock screen
/// controls (Android foreground service, macOS Now Playing), audio focus and
/// "becoming noisy" (headphones unplugged).
Future<void> initMediaSession(RadioController controller, ArtCache art) async {
  try {
    await AudioService.init(
      builder: () => TerraAudioHandler(controller, art),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.bp.terra.playback',
        androidNotificationChannelName: 'Radio playback',
        androidNotificationIcon: 'drawable/ic_stat_radio',
        androidStopForegroundOnPause: true,
      ),
    );
  } on Object catch (e, st) {
    _log.warning('Media session unavailable', e, st);
  }
  if (Platform.isAndroid) await _initAudioFocus(controller);
}

Future<void> _initAudioFocus(RadioController controller) async {
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  var resumeAfterInterruption = false;
  session.interruptionEventStream.listen((event) {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          controller.duck(true);
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          resumeAfterInterruption =
              controller.audioEnabled &&
              event.type == AudioInterruptionType.pause;
          controller.setAudioEnabled(false);
      }
    } else {
      controller.duck(false);
      if (resumeAfterInterruption) controller.setAudioEnabled(true);
      resumeAfterInterruption = false;
    }
  });
  session.becomingNoisyEventStream.listen(
    (_) => controller.setAudioEnabled(false),
  );

  var wasPlaying = false;
  controller.addListener(() {
    final playing = controller.state.isStreaming && controller.audioEnabled;
    if (playing == wasPlaying) return;
    wasPlaying = playing;
    unawaited(session.setActive(playing));
  });
}

class TerraAudioHandler extends BaseAudioHandler {
  TerraAudioHandler(this._controller, this._art) {
    _controller.addListener(_sync);
    _sync();
  }

  final RadioController _controller;
  final ArtCache _art;
  String? _lastItemKey;
  String? _lastStateKey;
  Uint8List? _lastArt;
  Uri? _artUri;

  @override
  Future<void> play() async {
    if (!_controller.state.isStreaming) await _controller.connectPreferred();
    _controller.setAudioEnabled(true);
  }

  @override
  Future<void> pause() async => _controller.setAudioEnabled(false);

  @override
  Future<void> stop() async {
    await _controller.disconnect();
    await super.stop();
  }

  @override
  Future<void> skipToNext() => _controller.mediaKey(1);

  @override
  Future<void> skipToPrevious() => _controller.mediaKey(-1);

  @override
  Future<void> fastForward() => _controller.mediaKey(1);

  @override
  Future<void> rewind() => _controller.mediaKey(-1);

  void _sync() {
    final s = _controller.state;
    final playing = s.isStreaming && _controller.audioEnabled;
    final processing = switch (s.phase) {
      ConnectionPhase.connecting => AudioProcessingState.loading,
      ConnectionPhase.streaming => AudioProcessingState.ready,
      ConnectionPhase.ended => AudioProcessingState.completed,
      ConnectionPhase.error ||
      ConnectionPhase.lost => AudioProcessingState.error,
      ConnectionPhase.disconnected => AudioProcessingState.idle,
    };
    final stateKey = '$playing/$processing/${s.errorMessage}';
    if (stateKey != _lastStateKey) {
      _lastStateKey = stateKey;
      playbackState.add(
        PlaybackState(
          controls: [
            MediaControl.skipToPrevious,
            if (playing) MediaControl.pause else MediaControl.play,
            MediaControl.skipToNext,
            MediaControl.stop,
          ],
          systemActions: const {
            MediaAction.skipToNext,
            MediaAction.skipToPrevious,
            MediaAction.stop,
          },
          androidCompactActionIndices: const [0, 1, 2],
          processingState: processing,
          playing: playing,
          errorMessage: processing == AudioProcessingState.error
              ? s.errorMessage
              : null,
        ),
      );
    }

    final f = s.frequencyHz;
    final band = f == null ? 'FM' : '${formatMhz(f)} FM';
    final hdLabel = s.hd.isHdStation ? ' HD${s.program + 1}' : '';
    final station = s.stationName ?? band;
    final track = s.nowPlaying;
    final waiting = s.hdWaitCaption(audioOn: _controller.audioEnabled);
    final title = waiting ?? track?.title ?? station;
    final artist = waiting != null
        ? (track?.title ?? station)
        : (track?.title == null ? '$band$hdLabel' : (track?.artist ?? station));
    final art =
        s.hd.artFor(s.program)?.bytes ??
        s.hd.logoFor(s.program)?.bytes ??
        _controller.cachedLogo;
    if (!identical(art, _lastArt)) {
      _lastArt = art;
      if (art == null) {
        _artUri = null;
      } else {
        unawaited(
          _art.exportForNotification(art).then((uri) {
            if (identical(_lastArt, art)) {
              _artUri = uri;
              _lastItemKey = null;
              _sync();
            }
          }),
        );
      }
    }
    final itemKey =
        '$title|$artist|$station|$_artUri|${s.audible == AudioSource.hd}';
    if (itemKey == _lastItemKey) return;
    _lastItemKey = itemKey;
    mediaItem.add(
      MediaItem(
        id: 'terra:${f ?? 0}:${s.program}',
        title: title,
        artist: artist,
        album: '$station · $band$hdLabel',
        artUri: _artUri,
        isLive: true,
      ),
    );
  }
}
