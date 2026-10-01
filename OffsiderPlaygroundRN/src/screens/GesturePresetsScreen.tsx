import { useRef, useState } from 'react';
import { PanResponder, type PanResponderGestureState, StyleSheet, View } from 'react-native';

import { colours, Note, Readout, Screen } from '../fixtures';

const minimumDistance = 30;

function classify({ dx, dy }: PanResponderGestureState): string {
  if (Math.abs(dx) > Math.abs(dy)) {
    return dx > 0 ? 'scroll-right' : 'scroll-left';
  }
  return dy > 0 ? 'scroll-down' : 'scroll-up';
}

export function GesturePresetsScreen() {
  const [history, setHistory] = useState<string[]>([]);
  const [active, setActive] = useState(false);

  const responder = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onPanResponderTerminationRequest: () => false,
      onPanResponderGrant: () => setActive(true),
      onPanResponderRelease: (_event, gesture) => {
        setActive(false);
        if (Math.hypot(gesture.dx, gesture.dy) > minimumDistance) {
          const name = classify(gesture);
          setHistory((current) => [...current, name]);
        }
      },
      onPanResponderTerminate: () => setActive(false),
    }),
  ).current;

  const latest = history[history.length - 1] ?? 'None';

  return (
    <Screen route="gesture-presets">
      <View testID="gesture-detection-area" style={StyleSheet.absoluteFill} {...responder.panHandlers} />
      <View pointerEvents="none" style={styles.panel}>
        <Readout id="gesture-presets-title" label="Gesture Presets Playground" textStyle={styles.title} />
        <Note>Drags over 30 points are classified by direction</Note>
        <Readout id="gesture-count" label={`Detected: ${history.length}`} value={`${history.length}`} />
        <Readout id="latest-gesture" label={`Latest Gesture: ${latest}`} value={latest} />
        <Note>{active ? 'Drag active' : 'Ready for gestures'}</Note>
        {history.length > 0 && <Note>Recent: {history.slice(-5).join(', ')}</Note>}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  panel: {
    margin: 16,
    padding: 16,
    gap: 6,
    borderRadius: 12,
    alignItems: 'center',
    backgroundColor: colours.panel,
  },
  title: { fontSize: 20, fontWeight: '700' },
});
