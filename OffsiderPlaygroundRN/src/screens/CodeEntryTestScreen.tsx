import { useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { colours, hiddenFromAccessibility, Readout, Screen } from '../fixtures';

const length = 6;

/** A one-time-code entry: a button draws the cells, and the input that takes the keys is invisible and hidden from the tree, so the control never reports focus. */
export function CodeEntryTestScreen() {
  const [code, setCode] = useState('');
  const input = useRef<TextInput>(null);

  return (
    <Screen route="code-entry-test" style={styles.content}>
      <Pressable
        testID="code-entry-cells"
        accessible
        accessibilityRole="button"
        accessibilityLabel="Enter code"
        onPress={() => input.current?.focus()}
        style={styles.cells}
      >
        {Array.from({ length }, (_, index) => (
          <View key={index} style={styles.cell}>
            <Text importantForAccessibility="no" style={styles.digit}>
              {code[index] ?? ''}
            </Text>
          </View>
        ))}
        <View {...hiddenFromAccessibility(true)} pointerEvents="none" style={styles.hidden}>
          <TextInput
            ref={input}
            onChangeText={setCode}
            maxLength={length}
            keyboardType="number-pad"
            autoComplete="off"
            caretHidden
            style={styles.input}
          />
        </View>
      </Pressable>
      <Readout id="code-entry-value" label={`Entered: ${code || 'none'}`} value={code || 'none'} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 16, alignItems: 'stretch' },
  cells: { flexDirection: 'row', gap: 8, justifyContent: 'center' },
  cell: {
    width: 44,
    height: 56,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: colours.separator,
    alignItems: 'center',
    justifyContent: 'center',
  },
  digit: { fontSize: 24, color: colours.text },
  hidden: { position: 'absolute', left: 0, top: 0, width: 1, height: 1, opacity: 0 },
  input: { width: 1, height: 1 },
});
