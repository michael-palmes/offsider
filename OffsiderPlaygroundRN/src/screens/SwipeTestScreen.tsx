import { useRef, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, formatPoint, Note, pagePoint, type Point, Readout, Target } from '../fixtures';
import { useNavigation } from '../navigation';

type Swipe = { start: Point; end: Point; direction: 'Right' | 'Left' | 'Down' | 'Up' };

function direction(start: Point, end: Point): Swipe['direction'] {
  const dx = end.x - start.x;
  const dy = end.y - start.y;
  if (Math.abs(dx) > Math.abs(dy)) {
    return dx > 0 ? 'Right' : 'Left';
  }
  return dy > 0 ? 'Down' : 'Up';
}

export function SwipeTestScreen() {
  const insets = useSafeAreaInsets();
  const { pop } = useNavigation();
  const [count, setCount] = useState(0);
  const [last, setLast] = useState<Swipe | null>(null);
  const start = useRef<Point | null>(null);

  return (
    <View style={styles.screen}>
      <View
        testID="swipe-test-area"
        style={StyleSheet.absoluteFill}
        onStartShouldSetResponder={() => true}
        onResponderTerminationRequest={() => false}
        onResponderGrant={(event) => {
          start.current = pagePoint(event);
        }}
        onResponderRelease={(event) => {
          const from = start.current;
          const to = pagePoint(event);
          start.current = null;
          if (!from || (Math.abs(to.x - from.x) < 1 && Math.abs(to.y - from.y) < 1)) {
            return;
          }
          setLast({ start: from, end: to, direction: direction(from, to) });
          setCount((current) => current + 1);
        }}
      />
      <View pointerEvents="none" style={[styles.panel, { marginTop: insets.top + 56 }]}>
        <Readout id="swipe-test-screen" role="header" label="Swipe Playground" textStyle={styles.title} />
        <Readout id="swipe-count" label={`Count: ${count}`} value={`${count}`} />
        {last ? (
          <>
            <Note>Last Swipe:</Note>
            <Readout id="last-swipe-start" label={`Start: ${formatPoint(last.start)}`} />
            <Readout id="last-swipe-end" label={`End: ${formatPoint(last.end)}`} />
            <Readout id="last-swipe-direction" label={`Direction: ${last.direction}`} value={last.direction} />
          </>
        ) : (
          <Note>No swipes yet, draw with your finger</Note>
        )}
      </View>
      <Target id="close-button" label="✕" onPress={pop} style={[styles.close, { top: insets.top + 8 }]} />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colours.background },
  panel: {
    marginHorizontal: 16,
    padding: 16,
    gap: 6,
    borderRadius: 12,
    alignItems: 'center',
    backgroundColor: colours.panel,
  },
  title: { fontSize: 20, fontWeight: '700' },
  close: { position: 'absolute', right: 16, width: 44, height: 44, borderRadius: 22, paddingHorizontal: 0 },
});
