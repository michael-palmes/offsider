import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { colours, Readout, Screen, Target } from '../fixtures';

const filters = ['All', 'Unread', 'Read'] as const;
type Filter = (typeof filters)[number];

export function ToolbarPickerTestScreen() {
  const [filter, setFilter] = useState<Filter>('All');

  const picker = (
    <View testID="toolbar-picker-test-filter" accessibilityRole="radiogroup" style={styles.segments}>
      {filters.map((option) => (
        <Target
          key={option}
          id={`toolbar-picker-test-filter-${option.toLowerCase()}`}
          label={option}
          role="radio"
          state={{ checked: filter === option }}
          onPress={() => setFilter(option)}
          style={[styles.segment, filter === option && styles.segmentSelected]}
          textStyle={styles.segmentText}
        />
      ))}
    </View>
  );

  return (
    <Screen route="toolbar-picker-test" headerRight={picker} style={styles.content}>
      <Readout id="toolbar-picker-test-state" label={`Toolbar Picker State: ${filter}`} value={filter} style={styles.row} />
      <Readout id="toolbar-picker-test-body" label="Toolbar Picker Detail Body" style={styles.row} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { paddingHorizontal: 16 },
  segments: { flexDirection: 'row', padding: 2, borderRadius: 9, backgroundColor: colours.panel },
  segment: { minHeight: 32, height: 32, paddingHorizontal: 10, borderRadius: 7, backgroundColor: 'transparent' },
  segmentSelected: { backgroundColor: colours.background },
  segmentText: { fontSize: 13, color: colours.text },
  row: {
    paddingVertical: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
});
