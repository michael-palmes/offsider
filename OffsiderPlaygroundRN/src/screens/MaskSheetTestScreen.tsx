import { useState } from 'react';
import { Modal, Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, fixtureLog, HeaderMarker, Screen, Target } from '../fixtures';

type Sheet = 'None' | 'Modal' | 'Inline' | 'Hiding';

export function MaskSheetTestScreen() {
  const insets = useSafeAreaInsets();
  const [sheet, setSheet] = useState<Sheet>('None');

  const show = (next: Sheet) => {
    fixtureLog('mask-sheet-test', `sheet ${next}`);
    setSheet(next);
  };

  const body = (
    <View style={styles.sheetBody}>
      <HeaderMarker id="mask-sheet-test-sheet-title" title="About this receipt" style={styles.sheetHeader} />
      <Text style={styles.sheetText}>Network fees are paid to miners.</Text>
      <Target id="mask-sheet-test-close" label="Close Sheet" onPress={() => show('None')} />
    </View>
  );

  return (
    <Screen route="mask-sheet-test">
      <View
        style={styles.receipt}
        importantForAccessibility={sheet === 'Hiding' ? 'no-hide-descendants' : 'auto'}
        accessibilityElementsHidden={sheet === 'Hiding'}
      >
        <Text testID="mask-sheet-test-address" style={styles.row}>Address bc1q...7k3m</Text>
        <Text testID="mask-sheet-test-txid" style={styles.row}>Transaction 4a9f...e21b</Text>
        <Text testID="mask-sheet-test-sheet-state" style={styles.row}>{`Sheet: ${sheet}`}</Text>
        <Target id="mask-sheet-test-open-modal" label="Open Modal Sheet" onPress={() => show('Modal')} />
        <Target id="mask-sheet-test-open-inline" label="Open Inline Sheet" onPress={() => show('Inline')} />
        <Target id="mask-sheet-test-open-hiding" label="Open Hiding Sheet" onPress={() => show('Hiding')} />
      </View>
      {sheet === 'Inline' || sheet === 'Hiding' ? (
        <View style={StyleSheet.absoluteFill}>
          <Pressable accessibilityLabel="Dismiss" style={styles.backdrop} onPress={() => show('None')} />
          <View style={[styles.sheet, { paddingBottom: insets.bottom + 16 }]}>{body}</View>
        </View>
      ) : null}
      <Modal visible={sheet === 'Modal'} transparent animationType="slide" onRequestClose={() => show('None')}>
        <View style={styles.modalRoot}>
          <Pressable accessibilityLabel="Dismiss" style={styles.backdrop} onPress={() => show('None')} />
          <View style={[styles.sheet, { paddingBottom: insets.bottom + 16 }]}>{body}</View>
        </View>
      </Modal>
    </Screen>
  );
}

const styles = StyleSheet.create({
  receipt: { padding: 16, gap: 16, alignItems: 'center' },
  row: { fontSize: 17, color: colours.text },
  modalRoot: { flex: 1 },
  backdrop: { flex: 1, backgroundColor: 'rgba(0, 0, 0, 0.4)' },
  sheet: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    height: '35%',
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    backgroundColor: colours.panel,
  },
  sheetBody: { alignItems: 'center', gap: 16, padding: 16 },
  sheetHeader: { alignSelf: 'stretch', paddingVertical: 12 },
  sheetText: { fontSize: 15, color: colours.secondary },
});
