import { useState } from 'react';
import { FlatList, StyleSheet } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, Readout, Screen, Target } from '../fixtures';

const rowHeight = 64;

type Row = { id: string; label: string; row: number | null };

const rows: Row[] = [
  { id: 'long-scroll-test-start', label: 'Long Scroll Start', row: null },
  ...Array.from({ length: 80 }, (_, index) => ({
    id: `long-scroll-test-row-${index + 1}`,
    label: `Long Scroll Row ${index + 1}`,
    row: index + 1,
  })),
  { id: 'long-scroll-test-end', label: 'Long Scroll End', row: null },
];

export function LongScrollTestScreen() {
  const insets = useSafeAreaInsets();
  const [selected, setSelected] = useState('None');

  return (
    <Screen route="long-scroll-test">
      <Readout
        id="long-scroll-test-state"
        label={`Long Scroll Selected: ${selected}`}
        value={selected}
        style={styles.state}
      />
      <FlatList
        testID="long-scroll-test-scroll-view"
        data={rows}
        keyExtractor={(item) => item.id}
        getItemLayout={(_data, index) => ({ length: rowHeight, offset: rowHeight * index, index })}
        contentContainerStyle={{ paddingBottom: insets.bottom }}
        renderItem={({ item }) => (
          <Target
            id={item.id}
            label={item.label}
            onPress={item.row === null ? () => {} : () => setSelected(`Row ${item.row}`)}
            style={styles.row}
            textStyle={styles.rowText}
          />
        )}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  state: {
    padding: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
  row: {
    height: rowHeight,
    alignItems: 'flex-start',
    borderRadius: 0,
    backgroundColor: colours.background,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
  rowText: { color: colours.text, fontWeight: '400' },
});
