import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { colours, Readout, Screen, Target } from '../fixtures';

const sizes = ['Small', 'Medium', 'Large'] as const;
type Size = (typeof sizes)[number];

function onOff(value: boolean): string {
  return value ? 'On' : 'Off';
}

export function ChoiceTestScreen() {
  const [terms, setTerms] = useState(false);
  const [updates, setUpdates] = useState(true);
  const [size, setSize] = useState<Size>('Medium');
  const [sync, setSync] = useState(false);
  const [open, setOpen] = useState(false);

  const state = `Terms ${onOff(terms)}, Updates ${onOff(updates)}, Size ${size}, Sync ${onOff(sync)}, Menu ${open ? 'Open' : 'Closed'}`;

  return (
    <Screen route="choice-test" style={styles.content}>
      <Readout id="choice-test-state" label={`Choice State: ${state}`} value={state} />

      <View style={styles.group}>
        <Target
          id="choice-test-checkbox-terms"
          label="Accept Terms"
          role="checkbox"
          state={{ checked: terms }}
          onPress={() => setTerms((current) => !current)}
          style={[styles.choice, terms && styles.choiceOn]}
          textStyle={styles.choiceText}
        />
        <Target
          id="choice-test-checkbox-updates"
          label="Product Updates"
          role="checkbox"
          state={{ checked: updates }}
          onPress={() => setUpdates((current) => !current)}
          style={[styles.choice, updates && styles.choiceOn]}
          textStyle={styles.choiceText}
        />
        <Target
          id="choice-test-checkbox-mixed"
          label="Select All"
          role="checkbox"
          state={{ checked: 'mixed' }}
          style={styles.choice}
          textStyle={styles.choiceText}
        />
      </View>

      <View testID="choice-test-size" accessibilityRole="radiogroup" style={styles.segments}>
        {sizes.map((option) => (
          <Target
            key={option}
            id={`choice-test-radio-${option.toLowerCase()}`}
            label={option}
            role="radio"
            state={{ checked: size === option, selected: size === option }}
            onPress={() => setSize(option)}
            style={[styles.segment, size === option && styles.segmentSelected]}
            textStyle={styles.choiceText}
          />
        ))}
      </View>

      <View style={styles.group}>
        <Target
          id="choice-test-switch"
          label="Sync Contacts"
          role="switch"
          state={{ checked: sync }}
          onPress={() => setSync((current) => !current)}
          style={[styles.track, sync && styles.trackOn]}
        >
          <View style={styles.thumb} />
        </Target>
        <Target
          id="choice-test-combobox"
          label="Country"
          role="combobox"
          state={{ expanded: open }}
          onPress={() => setOpen((current) => !current)}
          style={styles.choice}
          textStyle={styles.choiceText}
        />
        <View
          testID="choice-test-progress"
          accessible
          accessibilityRole="progressbar"
          accessibilityLabel="Upload Progress"
          accessibilityState={{ busy: true }}
          accessibilityValue={{ min: 0, max: 100, now: 40 }}
          style={styles.progress}
        >
          <View style={styles.progressFill} />
        </View>
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 20 },
  group: { gap: 8, alignItems: 'flex-start' },
  choice: { backgroundColor: colours.panel },
  choiceOn: { backgroundColor: '#D6E8FF' },
  choiceText: { fontSize: 15, color: colours.text },
  segments: { flexDirection: 'row', padding: 2, borderRadius: 9, backgroundColor: colours.panel, alignSelf: 'flex-start' },
  segment: { minHeight: 32, height: 32, paddingHorizontal: 12, borderRadius: 7, backgroundColor: 'transparent' },
  segmentSelected: { backgroundColor: colours.background },
  track: {
    width: 52,
    minHeight: 32,
    height: 32,
    borderRadius: 16,
    paddingHorizontal: 2,
    alignItems: 'flex-start',
    backgroundColor: colours.separator,
  },
  trackOn: { alignItems: 'flex-end', backgroundColor: '#34C759' },
  thumb: { width: 28, height: 28, borderRadius: 14, backgroundColor: '#FFFFFF' },
  progress: { width: 200, height: 8, borderRadius: 4, backgroundColor: colours.panel },
  progressFill: { width: 80, height: 8, borderRadius: 4, backgroundColor: colours.accent },
});
