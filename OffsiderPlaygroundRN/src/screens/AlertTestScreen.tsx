import { useState } from 'react';
import { Alert, Platform, StyleSheet, ToastAndroid } from 'react-native';

import { Readout, Screen, Target } from '../fixtures';

export function AlertTestScreen() {
  const [state, setState] = useState('Initial');

  const showAlert = () =>
    Alert.alert('Delete Draft?', 'This alert is used for deterministic automation coverage.', [
      { text: 'Cancel', style: 'cancel', onPress: () => setState('Cancelled') },
      { text: 'Delete', style: 'destructive', onPress: () => setState('Deleted') },
    ]);

  // The toast is the only feedback: nothing on the screen changes.
  const showToast = () => ToastAndroid.show('Draft saved', ToastAndroid.SHORT);

  return (
    <Screen route="alert-test" style={styles.content}>
      <Readout id="alert-test-state" label={`Alert State: ${state}`} value={state} />
      <Target id="alert-test-show-alert" label="Show Alert" onPress={showAlert} />
      {Platform.OS === 'android' ? <Target id="alert-test-show-toast" label="Show toast" onPress={showToast} /> : null}
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 24, alignItems: 'center' },
});
