import { useState } from 'react';
import { Modal, StyleSheet } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { colours, HeaderMarker, Readout, Screen, Target } from '../fixtures';

export function SheetTestScreen() {
  const [state, setState] = useState('Initial');
  const [open, setOpen] = useState(false);

  return (
    <Screen route="sheet-test" style={styles.content}>
      <Readout id="sheet-test-state" label={`Sheet State: ${state}`} value={state} />
      <Target id="sheet-test-open-sheet" label="Open Sheet" onPress={() => setOpen(true)} />
      <Modal
        visible={open}
        animationType="slide"
        presentationStyle="pageSheet"
        onRequestClose={() => setOpen(false)}
      >
        <SafeAreaView style={styles.sheet}>
          <HeaderMarker id="sheet-test-sheet" title="Sheet Fixture" style={styles.sheetHeader} />
          <Target id="sheet-test-action" label="Run Sheet Action" onPress={() => setState('Sheet action tapped')} />
          <Target id="sheet-test-close" label="Close Sheet" onPress={() => setOpen(false)} />
        </SafeAreaView>
      </Modal>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 24, alignItems: 'center' },
  sheet: { flex: 1, alignItems: 'center', gap: 24, padding: 16, backgroundColor: colours.background },
  sheetHeader: { alignSelf: 'stretch', paddingVertical: 12 },
});
