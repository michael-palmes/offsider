import { useState } from 'react';
import { Alert, StyleSheet } from 'react-native';

import { Readout, Screen, Target } from '../fixtures';

export function AlertTestScreen() {
  const [state, setState] = useState('Initial');

  const showAlert = () =>
    Alert.alert('Delete Draft?', 'This alert is used for deterministic automation coverage.', [
      { text: 'Cancel', style: 'cancel', onPress: () => setState('Cancelled') },
      { text: 'Delete', style: 'destructive', onPress: () => setState('Deleted') },
    ]);

  return (
    <Screen route="alert-test" style={styles.content}>
      <Readout id="alert-test-state" label={`Alert State: ${state}`} value={state} />
      <Target id="alert-test-show-alert" label="Show Alert" onPress={showAlert} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 24, alignItems: 'center' },
});
