import { useRef, useState } from 'react';
import { type GestureResponderEvent, StyleSheet, View } from 'react-native';

import { colours, Note, Readout, Screen, Target } from '../fixtures';

export function MultiTouchScreen() {
  const [fingers, setFingers] = useState(0);
  const [heldMs, setHeldMs] = useState(0);
  const twoSince = useRef<number | null>(null);

  const onTouches = (event: GestureResponderEvent) => {
    const count = event.nativeEvent.touches.length;
    setFingers((current) => Math.max(current, count));
    if (count >= 2 && twoSince.current === null) {
      twoSince.current = Date.now();
    } else if (count < 2 && twoSince.current !== null) {
      const since = twoSince.current;
      twoSince.current = null;
      setHeldMs((current) => Math.max(current, Date.now() - since));
    }
  };

  const reset = () => {
    twoSince.current = null;
    setFingers(0);
    setHeldMs(0);
  };

  return (
    <Screen route="multi-touch">
      <View
        testID="multi-touch-area"
        style={styles.area}
        onTouchStart={onTouches}
        onTouchMove={onTouches}
        onTouchEnd={onTouches}
        onTouchCancel={onTouches}
      >
        <Note>Hold two fingers here</Note>
      </View>
      <View style={styles.panel}>
        <Readout id="multi-touch-fingers" label={`Fingers: ${fingers}`} value={`${fingers}`} />
        <Readout id="multi-touch-held-ms" label={`Held: ${heldMs} ms`} value={`${heldMs}`} />
        <Target id="multi-touch-reset" label="Reset" onPress={reset} />
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  area: {
    margin: 16,
    height: 320,
    borderRadius: 12,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colours.panel,
  },
  panel: { marginHorizontal: 16, gap: 8, alignItems: 'center' },
});
