import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { Note, Readout, Screen, Target } from '../fixtures';

const buttons = [
  { id: 'home', title: 'Home' },
  { id: 'lock', title: 'Lock' },
  { id: 'side-button', title: 'Side Button' },
  { id: 'siri', title: 'Siri' },
  { id: 'apple-pay', title: 'Apple Pay' },
];

export function ButtonTestScreen() {
  const [presses, setPresses] = useState<string[]>([]);
  const last = presses[presses.length - 1];

  return (
    <Screen route="button-test" style={styles.content}>
      <Readout id="button-test-title" label="Hardware Button Detection" textStyle={styles.title} />
      <Note>Simulated presses from the buttons below</Note>
      {last ? (
        <Readout id="last-button-press" label={`Last Button: ${last}`} value={last} />
      ) : (
        <Readout id="no-buttons-pressed" label="No buttons pressed yet" />
      )}
      <Readout id="button-press-count" label={`Button Count: ${presses.length}`} value={`${presses.length}`} />
      <Note>Simulate Button Presses:</Note>
      <View style={styles.grid}>
        {buttons.map((button) => (
          <Target
            key={button.id}
            id={`button-test-${button.id}`}
            label={button.title}
            onPress={() => setPresses((current) => [...current, button.id])}
            style={styles.button}
          />
        ))}
      </View>
      <View style={styles.history}>
        {presses.slice(-5).map((press, index, recent) => {
          const n = presses.length - recent.length + index + 1;
          return <Readout key={n} id={`button-event-${n}`} label={`${n}: ${press}`} />;
        })}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 12, alignItems: 'center' },
  title: { fontSize: 20, fontWeight: '700' },
  grid: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'center', gap: 12 },
  button: { width: 160 },
  history: { alignSelf: 'stretch', gap: 4 },
});
