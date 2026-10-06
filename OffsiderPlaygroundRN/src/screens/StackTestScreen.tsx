import { useState } from 'react';
import { StyleSheet, useWindowDimensions, View } from 'react-native';

import { colours, fixtureLog, HeaderMarker, Readout, Screen, Target } from '../fixtures';

const maxDepth = 3;

export function StackTestScreen() {
  const { width } = useWindowDimensions();
  const [depth, setDepth] = useState(1);
  const [state, setState] = useState('Initial');
  const [hideInactive, setHideInactive] = useState(false);
  const [fullOffset, setFullOffset] = useState(false);
  const previousOffset = -width * (fullOffset ? 1 : 0.3);

  const next = () => {
    fixtureLog('stack-test', depth < maxDepth ? `push page ${depth + 1}` : 'next ignored at max depth');
    setDepth((current) => Math.min(current + 1, maxDepth));
  };

  const back = () => {
    fixtureLog('stack-test', depth > 1 ? `pop page ${depth}` : 'back ignored at first page');
    setDepth((current) => Math.max(current - 1, 1));
  };

  const mark = (page: number) => {
    fixtureLog('stack-test', `page ${page} marked`);
    setState(`Page ${page} marked`);
  };

  return (
    <Screen route="stack-test">
      <View style={styles.controls}>
        <Readout id="stack-test-state" label={`Stack State: ${state}`} value={state} />
        <Readout id="stack-test-depth" label={`Stack Depth: ${depth}`} value={String(depth)} />
        <View style={styles.toggles}>
          <Target
            id="stack-test-hide-inactive"
            label={`Hide Inactive Pages: ${hideInactive ? 'On' : 'Off'}`}
            onPress={() => {
              fixtureLog('stack-test', `hide inactive ${hideInactive ? 'off' : 'on'}`);
              setHideInactive((current) => !current);
            }}
            style={styles.toggle}
            textStyle={styles.toggleText}
          />
          <Target
            id="stack-test-offset"
            label={`Previous Offset: ${fullOffset ? '100%' : '30%'}`}
            onPress={() => {
              fixtureLog('stack-test', `previous offset ${fullOffset ? '30%' : '100%'}`);
              setFullOffset((current) => !current);
            }}
            style={styles.toggle}
            textStyle={styles.toggleText}
          />
        </View>
      </View>
      <View style={styles.stack}>
        {Array.from({ length: depth }, (_, index) => {
          const page = index + 1;
          const active = page === depth;
          return (
            <View
              key={page}
              accessibilityElementsHidden={!active && hideInactive}
              importantForAccessibility={!active && hideInactive ? 'no-hide-descendants' : 'auto'}
              style={[
                styles.page,
                { pointerEvents: active ? 'auto' : 'none', transform: [{ translateX: active ? 0 : previousOffset }] },
              ]}
            >
              <HeaderMarker id="stack-test-page-title" title={`Page ${page}`} style={styles.pageTitle} />
              <Readout id={`stack-test-page-${page}`} label={`On Page ${page}`} />
              <Target id="stack-test-next" label="Next Page" onPress={next} />
              <Target id="stack-test-mark" label="Mark Page" onPress={() => mark(page)} />
              <Target id="stack-test-back" label="Previous Page" onPress={back} />
            </View>
          );
        })}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  controls: {
    padding: 16,
    gap: 8,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
  toggles: { flexDirection: 'row', gap: 8 },
  toggle: { flex: 1, backgroundColor: colours.panel },
  toggleText: { color: colours.accent, fontSize: 15 },
  stack: { flex: 1 },
  page: {
    ...StyleSheet.absoluteFill,
    padding: 16,
    gap: 16,
    alignItems: 'center',
    backgroundColor: colours.background,
    borderLeftWidth: StyleSheet.hairlineWidth,
    borderLeftColor: colours.separator,
  },
  pageTitle: { alignSelf: 'stretch', paddingVertical: 12 },
});
