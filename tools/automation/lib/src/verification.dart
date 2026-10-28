part of 'runtime.dart';

extension FixtureVerification on AutomationRuntime {
  Future<void> _publishVerification(
    File file,
    Json report,
    Cancellation cancellation,
    Future<void> Function() checkpoint,
  ) async {
    cancellation.check();
    await writeJson(file, report);
    // Both ordinary and cold verification can be cancelled during final I/O.
    if (cancellation.cancelled) {
      await checkpoint();
      cancellation.check();
    }
  }

  Future<Json> verify(
    Session session,
    Json args,
    Cancellation cancellation,
  ) async {
    if (!p.equals(p.normalize(session.project), p.normalize(tools.fixture)) ||
        session.connection.hooks != HookProtocol.fixture) {
      throw const AutomationError(
        'fixture_only',
        'Automated verification runs only on the offline fixture',
      );
    }
    final directory = _directory(session, {
      'label': args.text('label', fallback: 'verify'),
    });
    await Directory(directory).create(recursive: true);
    final items = <Json>[];
    Future<void> checkpoint() =>
        writeJson(File(p.join(directory, 'report.json')), {
          'sessionId': session.id,
          'completed': false,
          'passed': false,
          'items': items,
          'directory': directory,
        });
    await checkpoint();
    Future<void> check(String name, Future<Json> Function() action) async {
      if (args['checks'] != null && !args.items('checks').contains(name)) {
        return;
      }
      cancellation.check();
      items.add(await _item(name, action));
      await checkpoint();
    }

    void require(bool value, String message) {
      if (!value) throw AutomationError('assertion_failed', message);
    }

    Future<Json> tap(String key) => drive(session, {
      'action': 'tap',
      'selector': {'kind': 'key', 'value': key},
    }, cancellation);
    Future<Json> shot(String label) async {
      final result = await capture(session, {
        'label': label,
        if (args['channels'] != null) 'channels': args['channels'],
      }, cancellation);
      final evidence = result.child('structuredContent');
      for (final item in evidence.items('items').map(object)) {
        items.add({
          'channel': '$label/${item['channel']}',
          'passed': item['passed'],
          'result': item['result'],
          'error': item['error'],
        });
      }
      return evidence;
    }

    final original = await session.state();
    try {
      if (session.platform == TargetPlatform.windows) {
        await check('window', () async {
          final native = original.child('native'),
              bounds = native.child('windowBounds'),
              work = native.child('monitorWorkArea');
          require(
            native.flag('visible') && !native.flag('topmost'),
            'Fixture must be visible and not topmost',
          );
          require(
            bounds.number('left') >= work.number('left') &&
                bounds.number('top') >= work.number('top') &&
                bounds.number('right') <= work.number('right') &&
                bounds.number('bottom') <= work.number('bottom'),
            'Window does not fit its monitor work area',
          );
          return native;
        });
        await check('background', () async {
          await drive(session, {
            'action': 'foreground',
            'enabled': false,
          }, cancellation);
          final before = await session.state();
          await cancellation.wait(
            Future<void>.delayed(const Duration(milliseconds: 1200)),
          );
          final observed = backgroundActivity(before, await session.state());
          if (observed['status'] == 'failed') {
            throw AutomationError(
              'background_activity',
              'Foreground-only activity advanced in an established background interval',
              observed,
            );
          }
          return observed;
        });
        await drive(session, {
          'action': 'foreground',
          'enabled': true,
        }, cancellation);
        await check('foreground', () async {
          final before = await session.state();
          await cancellation.wait(
            Future<void>.delayed(const Duration(milliseconds: 600)),
          );
          final after = await session.state();
          require(
            after.integer('foregroundTicks') >
                before.integer('foregroundTicks'),
            'Simulated lifecycle did not enable activity',
          );
          await drive(session, {
            'action': 'foreground',
            'enabled': false,
          }, cancellation);
          final restoration = foregroundRestoration(await session.state());
          require(
            restoration['passed'] == true,
            'Simulation did not restore latest actual lifecycle and focus',
          );
          await drive(session, {
            'action': 'foreground',
            'enabled': true,
          }, cancellation);
          return restoration;
        });
      }
      await check('overview', () async {
        await tap('nav-overview');
        require(
          (await session.state())['page'] == 'overview',
          'Navigation did not reach overview',
        );
        return shot('overview');
      });
      await check('gallery', () async {
        await tap('nav-gallery');
        final before = await session.state();
        await tap('tile-0');
        await drive(session, {
          'action': 'scroll',
          'selector': {'kind': 'key', 'value': 'gallery-scroll'},
          'dy': -350,
        }, cancellation);
        final state = await session.state();
        require(
          state.integer('clicks') > before.integer('clicks'),
          'Tile callback missing',
        );
        require(state.number('scrollOffset') > 0, 'Scroll did not move');
        return shot('gallery');
      });
      await check('unicode', () async {
        await tap('nav-interaction');
        await drive(session, {
          'action': 'textEmulation',
          'enabled': true,
        }, cancellation);
        await tap('input-field');
        await drive(session, {
          'action': 'enterText',
          'text': '中文 Flutter 🦋',
        }, cancellation);
        final state = await session.state();
        require(state['text'] == '中文 Flutter 🦋', 'Unicode text mismatch');
        final baseline = state.integer('clicks');
        await tap('increment-button');
        require(
          (await session.state()).integer('clicks') == baseline + 1,
          'Button callback missing',
        );
        await tap('focus-key-button');
        final shortcuts = (await session.state()).integer('shortcutCount');
        await drive(session, {'action': 'key', 'key': 'F6'}, cancellation);
        require(
          (await session.state()).integer('shortcutCount') == shortcuts + 1,
          'Framework keyboard event missing',
        );
        return shot('unicode');
      });
      await drive(session, {'action': 'unfocus'}, cancellation);
      await drive(session, {
        'action': 'textEmulation',
        'enabled': false,
      }, cancellation);
      if (session.platform.isMobile) {
        await check('native-keyboard', () async {
          await tap('nav-interaction');
          await tap('input-field');
          final state = await until(
            session.state,
            (s) => s.child('view').number('keyboardInset') > 0,
            cancellation: cancellation,
          );
          await shot('native-keyboard');
          await drive(session, {
            'action': session.platform == TargetPlatform.android
                ? 'back'
                : 'unfocus',
          }, cancellation);
          await until(
            session.state,
            (s) => s.child('view').number('keyboardInset') == 0,
            cancellation: cancellation,
          );
          return state;
        });
      }
      await check('modal', () async {
        await tap('nav-scenarios');
        final baseline = await session.state();
        final center = await drive(session, {
          'action': 'center',
          'selector': {'kind': 'key', 'value': 'nav-gallery'},
        }, cancellation);
        await tap('open-dialog');
        require(
          (await session.state()).flag('dialogOpen'),
          'Modal did not open',
        );
        await shot('dialog');
        await drive(session, {
          'action': 'tapAt',
          'x': center['dx'],
          'y': center['dy'],
        }, cancellation);
        require(
          (await session.state())['page'] == 'scenarios',
          'Modal barrier did not block navigation',
        );
        await tap('dialog-confirm');
        final after = await session.state();
        require(
          after.integer('dialogConfirmed') >
              baseline.integer('dialogConfirmed'),
          'Dialog callback missing',
        );
        await tap('open-dialog');
        if (session.platform == TargetPlatform.android) {
          await drive(session, {'action': 'back'}, cancellation);
        } else {
          await tap('dialog-cancel');
        }
        final cancelled = await session.state();
        require(
          !cancelled.flag('dialogOpen') &&
              cancelled.integer('dialogConfirmed') ==
                  after.integer('dialogConfirmed'),
          'Dismissal unexpectedly invoked confirmation',
        );
        return after;
      });
      await check('animation', () async {
        await tap('nav-scenarios');
        await drive(session, {
          'action': 'tap',
          'selector': {'kind': 'key', 'value': 'animation-play'},
          'settle': false,
        }, cancellation);
        final before = await session.state();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final after = await session.state();
        require(
          after.integer('animationFrames') > before.integer('animationFrames'),
          'Animation did not advance',
        );
        if (args.flag('record', fallback: true)) {
          final recording = await record(session, {
            'label': 'animation',
            'seconds': 3,
            'fps': 2,
            if (args['channels'] != null) 'channels': args['channels'],
          }, cancellation);
          final recorded = recording.items('items').map(object).toList();
          items.addAll(recorded);
          for (final item in recorded.where((i) => i['passed'] == true)) {
            final video = item.child('result'),
                rect = after.child('animationRect');
            final ratio = after.child('view').number('pixelRatio');
            var x = rect.number('x') * ratio,
                y = rect.number('y') * ratio,
                w = rect.number('width') * ratio,
                h = rect.number('height') * ratio;
            if (item['channel'] == 'native') {
              if (session.platform != TargetPlatform.android) {
                x += video.number('clientX');
                y += video.number('clientY');
              } else {
                final bounds = after.child('native').child('viewBounds'),
                    fit = video.child('displayProjection');
                x += bounds.number('x');
                y += bounds.number('y');
                x =
                    fit.number('x') +
                    x * fit.number('width') / fit.number('sourceWidth');
                y =
                    fit.number('y') +
                    y * fit.number('height') / fit.number('sourceHeight');
                w *= fit.number('width') / fit.number('sourceWidth');
                h *= fit.number('height') / fit.number('sourceHeight');
              }
            }
            final motion = await media.inspect(
              video.text('masterPath', fallback: video.text('path')),
              rotation: CaptureRotation.fromDegrees(
                video.integer('rotationToAppDegrees', fallback: 0),
              ),
              region: {
                'x': x.round(),
                'y': y.round(),
                'width': w.floor(),
                'height': h.floor(),
              },
              cancellation: cancellation,
            );
            require(
              motion.integer('uniqueSampleFrames') > 1,
              'Animation pixels did not change',
            );
            items.add({
              'channel': '${item['channel']}/animation-pixels',
              'passed': true,
              'result': motion,
            });
            items.add({
              'channel': '${item['channel']}/timing',
              'passed':
                  video['timingPassed'] ??
                  ((video.number('elapsedMs') - video.number('expectedMs'))
                          .abs() <
                      video.number('expectedMs') * .15),
              'result': video,
            });
          }
        }
        await tap('animation-pause');
        final paused = await session.state();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final stopped = await session.state();
        require(
          !stopped.flag('animationRunning') &&
              stopped['animationFrames'] == paused['animationFrames'] &&
              stopped['animationValue'] == paused['animationValue'],
          'Paused animation still advances',
        );
        await tap('animation-reset');
        require(
          (await session.state()).number('animationValue') == 0,
          'Animation reset failed',
        );
        return shot('animation-paused');
      });
      if (session.platform.isMobile) {
        await check('orientation', () async {
          await drive(session, {
            'action': 'orientation',
            'value': 'landscape',
          }, cancellation);
          await shot('landscape');
          if (session.platform == TargetPlatform.ios &&
              args.flag('record', fallback: true) &&
              (args['channels'] == null ||
                  args.items('channels').contains('native'))) {
            final recording = await record(session, {
              'label': 'landscape-video',
              'seconds': 2,
              'nativeFps': 1,
              'channels': ['native'],
            }, cancellation);
            for (final item in recording.items('items').map(object)) {
              items.add({
                ...item,
                'channel': 'landscape/video/${item['channel']}',
              });
              if (item['passed'] == true) {
                final video = item.child('result');
                final view = (await session.state()).child('view');
                final ratio = view.number('pixelRatio');
                final decoded = await media.inspect(
                  video.text('masterPath'),
                  rotation: CaptureRotation.fromDegrees(
                    video.integer('rotationToAppDegrees', fallback: 0),
                  ),
                  region: {
                    'x': 0,
                    'y': 0,
                    'width': (view.number('width') * ratio).round(),
                    'height': (view.number('height') * ratio).round(),
                  },
                  cancellation: cancellation,
                );
                items.add({
                  'channel': 'landscape/video-analysis',
                  'passed': video['timingPassed'] == true,
                  'result': decoded,
                });
              }
            }
          }
          await drive(session, {
            'action': 'orientation',
            'value': 'portrait',
          }, cancellation);
          return shot('portrait');
        });
        await check('lifecycle', () async {
          final before = await session.state();
          await drive(session, {'action': 'background'}, cancellation);
          final hidden = await session.state();
          require(
            hidden.child('native')['isForeground'] == false &&
                [
                  'paused',
                  'hidden',
                  'inactive',
                ].contains(hidden['rawLifecycle']) &&
                hidden['rawLifecycle'] == hidden['effectiveLifecycle'],
            'Activity did not pause',
          );
          await drive(session, {'action': 'resume'}, cancellation);
          final after = await session.state();
          require(
            after['text'] == before['text'],
            'Text lost across lifecycle',
          );
          require(
            after.child('native')['pid'] == before.child('native')['pid'],
            'App process changed',
          );
          return {'hidden': hidden, 'resumed': after};
        });
      }
      await check('hot-reload', () async {
        final before = await session.state();
        await session.connection.update(restart: false);
        final after = await session.state();
        require(before['text'] == after['text'], 'Hot reload lost state');
        return after;
      });
      await check('hot-restart', () async {
        final before = await session.state();
        await session.connection.update(restart: true);
        final after = await session.state();
        require(
          before.child('native')['pid'] == after.child('native')['pid'],
          'Hot restart replaced native process',
        );
        return after;
      });
    } finally {
      if (session.platform.isMobile && session.orientationChanged) {
        await drive(session, {
          'action': 'orientation',
          'value': 'restore',
        }, Cancellation());
      }
      if (session.textEmulation) {
        await drive(session, {
          'action': 'textEmulation',
          'enabled': false,
        }, Cancellation());
      }
      if (session.platform == TargetPlatform.windows) {
        await drive(session, {
          'action': 'foreground',
          'enabled': original.flag('pretendForeground'),
        }, Cancellation());
      }
    }
    cancellation.check();
    final finalState = await session.state();
    cancellation.check();
    final report = {
      'sessionId': session.id,
      'completed': true,
      'passed': items.every((i) => i['passed'] == true),
      'items': items,
      'directory': directory,
      'finalState': finalState,
    };
    await _publishVerification(
      File(p.join(directory, 'report.json')),
      report,
      cancellation,
      checkpoint,
    );
    return report;
  }

  Future<Json> verifyCold(Json args, Cancellation cancellation) async {
    if (sessions.active.isNotEmpty) {
      throw const AutomationError(
        'session_busy',
        'Finish existing sessions before explicit cold-start verification',
      );
    }
    final platform = TargetPlatform.values.byName(args.text('platform'));
    final cycles = args.integer('cycles', fallback: 1), results = <Json>[];
    final path = p.join(
      tools.artifacts,
      'cold-${DateTime.now().microsecondsSinceEpoch}.json',
    );
    Future<void> checkpoint() => writeJson(File(path), {
      'cycles': results,
      'passed': false,
      'phase': 'incomplete',
    });
    for (var cycle = 0; cycle < cycles; cycle++) {
      cancellation.check();
      final id = 'cold-${DateTime.now().microsecondsSinceEpoch}';
      final session = await sessions.open({
        'sessionId': id,
        'platform': platform.name,
        'placement': ['auto', 'primary', 'secondary'][cycle % 3],
        if (platform.isMobile) 'deviceId': args.text('deviceId'),
      }, cancellation);
      final items = <Json>[];
      results.add({'cycle': cycle, 'sessionId': id, 'captures': items});
      await checkpoint();
      try {
        for (final page in [
          'overview',
          'gallery',
          'interaction',
          'scenarios',
        ]) {
          if (platform == TargetPlatform.windows) {
            await drive(session, {
              'action': 'foreground',
              'enabled': true,
            }, cancellation);
          }
          await drive(session, {
            'action': 'tap',
            'selector': {'kind': 'key', 'value': 'nav-$page'},
          }, cancellation);
          items.add(
            (await capture(session, {
              'label': 'cold-$page',
            }, cancellation)).child('structuredContent'),
          );
          await checkpoint();
        }
        final probe = await session.connection.hook('prepareCapture');
        final future = {
          ...probe,
          'token': (probe.integer('token') + 1) & 0xffffff,
        };
        final path = p.join(session.directory.path, 'fence.png');
        var accepted = false;
        Object? failure;
        final pending =
            nativeScreenshot(
              session,
              path,
              probe.child('native'),
              probe: future,
              cancellation: cancellation,
            ).then((value) {
              accepted = true;
              return value;
            });
        unawaited(
          pending.then<void>((_) {}, onError: (Object e) => failure = e),
        );
        await cancellation.wait(
          Future<void>.delayed(const Duration(milliseconds: 350)),
        );
        // A capture that failed early proves nothing about the fence; report
        // the real error rather than a fence violation or a pass.
        if (failure != null) throw failure!;
        if (accepted) {
          throw const AutomationError(
            'stale_presentation',
            'A future token was accepted before it was rendered',
          );
        }
        final released = await session.connection.hook('prepareCapture');
        if (released['token'] != future['token']) {
          throw const AutomationError(
            'token_changed',
            'Unexpected concurrent presentation token',
          );
        }
        items.add({'fence': await pending});
        await checkpoint();
        if (cycle == 0) {
          final missing = {
            ...released,
            'token': (released.integer('token') + 99) & 0xffffff,
          };
          final invalid = p.join(session.directory.path, 'never-presented.png');
          var rejected = false;
          try {
            await nativeScreenshot(
              session,
              invalid,
              released.child('native'),
              probe: missing,
              cancellation: cancellation,
            );
          } catch (e) {
            cancellation.check();
            if (await File(invalid).exists()) rethrow;
            rejected = true;
            items.add({'neverPresentedRejected': true, 'error': '$e'});
          }
          if (!rejected) {
            throw const AutomationError(
              'stale_presentation',
              'Never-presented token was accepted',
            );
          }
        }
        results.last['state'] = await session.state();
      } finally {
        try {
          await sessions.close(id);
        } catch (e) {
          results.last['cleanupError'] = '$e';
          rethrow;
        } finally {
          await checkpoint();
        }
      }
    }
    final report = {
      'cycles': results,
      'passed': results.every(
        (cycle) => cycle
            .items('captures')
            .whereType<Json>()
            .where((i) => i.containsKey('items'))
            .every(
              (capture) => capture
                  .items('items')
                  .map(object)
                  .every((i) => i['passed'] == true),
            ),
      ),
    };
    await _publishVerification(File(path), report, cancellation, checkpoint);
    return {...report, 'report': path};
  }
}
