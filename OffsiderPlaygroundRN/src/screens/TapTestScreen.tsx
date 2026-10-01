import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { colours, formatPoint, Note, pagePoint, type Point, Readout, Screen } from '../fixtures';

export function TapTestScreen() {
  const [count, setCount] = useState(0);
  const [last, setLast] = useState<Point | null>(null);

  return (
    <Screen route="tap-test">
      <View
        testID="tap-test-area"
        style={StyleSheet.absoluteFill}
        onStartShouldSetResponder={() => true}
        onResponderRelease={(event) => {
          setLast(pagePoint(event));
          setCount((current) => current + 1);
        }}
      />
      <View pointerEvents="none" style={styles.panel}>
        <Note>Detects taps sent by CLI commands</Note>
        <Readout id="tap-count" label={`Tap Count: ${count}`} value={`${count}`} textStyle={styles.count} />
        {last && (
          <Readout
            id="last-tap-coordinates"
            label={`Tap Location: ${formatPoint(last)}`}
            value={`x:${last.x},y:${last.y}`}
            textStyle={styles.location}
          />
        )}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  panel: {
    margin: 16,
    padding: 16,
    gap: 8,
    borderRadius: 12,
    alignItems: 'center',
    backgroundColor: colours.panel,
  },
  count: { fontWeight: '600', color: colours.accent },
  location: { fontWeight: '600', color: '#248A3D' },
});
