import Slider from '@react-native-community/slider';
import { useState } from 'react';
import { Platform, StyleSheet } from 'react-native';

import { iosValue, Readout, Screen, Target } from '../fixtures';

export function SliderValueTestScreen() {
  const [value, setValue] = useState(0.25);
  const [state, setState] = useState('Initial');
  const position = value.toFixed(2);
  const percent = (value * 100).toFixed(2);
  const exact = value.toFixed(4);

  return (
    <Screen route="slider-value-test" style={styles.content}>
      <Readout id="slider-value-state" label={`Slider Value State: ${state}`} value={state} />
      <Target id="slider-value-button" label="Slider Value Button" onPress={() => setState('Tapped')} />
      <Readout id="slider-position-value" label={`Slider Position: ${position}`} value={position} />
      <Readout id="slider-percent-state" label={`Slider Percent State: ${percent}`} value={percent} />
      <Readout id="slider-exact-value-state" label={`Slider Exact Value: ${exact}`} value={exact} />
      <Slider
        testID="slider-value-slider"
        accessibilityLabel="Slider Value Slider"
        accessibilityRole={Platform.OS === 'ios' ? 'adjustable' : undefined}
        accessibilityValue={iosValue(exact)}
        minimumValue={0}
        maximumValue={1}
        step={0.0001}
        value={0.25}
        onValueChange={setValue}
        style={styles.slider}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 24, alignItems: 'center' },
  slider: { alignSelf: 'stretch', height: 44 },
});
