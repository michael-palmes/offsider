import { useRef, useState } from 'react';
import { Pressable, StyleSheet, TextInput, View } from 'react-native';

import { colours, Readout, Screen, Target } from '../fixtures';

const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0', 'Delete'];

/** A price field fed only by the app's own keypad: typed keys never reach its state, and the wrapper hides the input from the tree. */
export function KeypadTestScreen() {
  const [amount, setAmount] = useState('');
  const [open, setOpen] = useState(false);
  const field = useRef<TextInput>(null);

  const press = (key: string) => {
    setAmount((current) => {
      if (key === 'Delete') {
        return current.slice(0, -1);
      }
      if (key === '.' && current.includes('.')) {
        return current;
      }
      return current + key;
    });
  };

  return (
    <Screen route="keypad-test" style={styles.content}>
      <Pressable
        testID="keypad-test-price"
        accessible
        accessibilityRole="button"
        accessibilityLabel={`Price, ${amount || '0.00'}`}
        onPress={() => {
          setOpen(true);
          field.current?.focus();
        }}
        style={styles.price}
      >
        <View importantForAccessibility="no-hide-descendants" accessibilityElementsHidden pointerEvents="none">
          <TextInput
            ref={field}
            value={amount}
            placeholder="0.00"
            placeholderTextColor={colours.secondary}
            showSoftInputOnFocus={false}
            onChangeText={() => {}}
            style={styles.field}
          />
        </View>
      </Pressable>
      <Readout id="keypad-test-value" label={`Amount: ${amount || 'empty'}`} value={amount || 'empty'} />
      {open && (
        <View testID="keypad-test-keys" style={styles.keys}>
          {keys.map((key) => (
            <Target key={key} id={`keypad-key-${key.toLowerCase()}`} label={key} onPress={() => press(key)} style={styles.key} />
          ))}
          <Target
            id="keypad-test-done"
            label="Done"
            onPress={() => {
              setOpen(false);
              field.current?.blur();
            }}
            style={styles.done}
          />
        </View>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 16 },
  price: { borderRadius: 8, borderWidth: 1, borderColor: colours.separator },
  field: { height: 48, paddingHorizontal: 12, fontSize: 22, color: colours.text },
  keys: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, justifyContent: 'center' },
  key: { width: '30%', height: 52, alignItems: 'center', justifyContent: 'center', borderRadius: 8, backgroundColor: colours.panel },
  done: { width: '94%', height: 48, alignItems: 'center', justifyContent: 'center', borderRadius: 8 },
});
