"""Keep observed Windows focus separate from capture validity and attribution."""


class ForegroundEvidence:
    def __init__(self, report):
        self.report = report
        report['foregroundPolicy'] = {
            'affectsCaptureValidity': False,
            'activationAttribution': 'unknown',
            'note': 'Foreground/focus observations do not identify who activated the window. '
                    'Automation must still avoid activation and global input.',
        }
        self.observations = report.setdefault('foregroundObservations', [])
        self.context_checks = report.setdefault('foregroundChecks', [])

    def state(self, label, current):
        native = current.get('native', {})
        self.observations.append({
            'label': label,
            'kind': 'state',
            **{key: native.get(key) for key in (
                'isForeground', 'hasNativeFocus', 'activationCount',
                'isBelowForeground', 'topmost')},
            **{key: current.get(key) for key in (
                'rawLifecycle', 'rawViewFocus', 'effectiveLifecycle', 'effectiveViewFocus')},
        })

    def recording(self, label, notes):
        self.observations.append({
            'label': label, 'kind': 'recording',
            'foregroundSamples': notes.get('foregroundSamples'),
        })

    def background_activity(self, name, before, after, check):
        # A user may inspect the window and return it to the background between
        # samples. The activation counter detects that interval too.
        natives = [state.get('native', {}) for state in (before, after)]
        background = all(
            not state.get('pretendForeground', True)
            and state.get('rawLifecycle') in ('inactive', 'hidden', 'paused', 'detached')
            and state.get('effectiveLifecycle') == state.get('rawLifecycle')
            and native.get('isForeground') is False
            and native.get('hasNativeFocus') is False
            for state, native in zip((before, after), natives)
        )
        same_activation_count = (
            isinstance(natives[0].get('activationCount'), int)
            and natives[0]['activationCount'] == natives[1].get('activationCount')
        )
        if not background or not same_activation_count:
            self.context_checks.append({
                'name': name, 'status': 'not_assessed', 'passed': None,
                'reason': 'An uninterrupted real-background interval was not established; '
                          'foreground/focus changes do not invalidate captures.',
            })
            return
        passed = after['foregroundTicks'] == before['foregroundTicks']
        self.context_checks.append({
            'name': name, 'status': 'passed' if passed else 'failed', 'passed': passed,
        })
        check(name, passed)

    def restoration(self, current, check):
        check('switch restores actual framework lifecycle',
              not current['pretendForeground']
              and current['effectiveLifecycle'] == current['rawLifecycle'])
        if 'rawViewFocus' not in current:
            self.context_checks.append({
                'name': 'switch restores latest real view focus',
                'status': 'not_assessed', 'passed': None,
                'reason': 'This fixture does not expose rawViewFocus; rebuild the test entrypoint '
                          'to verify focus restoration.',
            })
            return
        # Matches the binding's fallback only when no real focus event exists.
        expected = current['rawViewFocus'] or 'unfocused'
        check('switch restores latest real view focus',
              current['effectiveViewFocus'] == expected,
              {'expected': expected, 'actual': current['effectiveViewFocus']})


def finish_report(report, error):
    """Aggregate executable assertions, independently of observational focus data."""
    checks = report['checks']
    report['functionalPassed'] = error is None and all(
        c['passed'] for c in checks if c['group'] == 'functional')
    report['nativeCapturePassed'] = error is None and any(
        c['group'] == 'native' for c in checks) and all(
        c['passed'] for c in checks if c['group'] == 'native')
    report['passed'] = report['functionalPassed'] and report['nativeCapturePassed']
