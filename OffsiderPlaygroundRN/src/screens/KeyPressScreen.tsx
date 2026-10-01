import { useRef, useState } from 'react';
import { Platform, StyleSheet, TextInput, View } from 'react-native';

import { colours, Note, Readout, Screen } from '../fixtures';

type Key = { name: string; code: number };
type KeyEvent = Key & { n: number };

const letters = 'abcdefghijklmnopqrstuvwxyz';
const digits = '1234567890';
const shiftedDigits = '!@#$%^&*()';
const symbolCodes: Record<string, number> = {
  '-': 45, _: 45, '=': 46, '+': 46, '[': 47, '{': 47, ']': 48, '}': 48, '\\': 49, '|': 49,
  ';': 51, ':': 51, "'": 52, '"': 52, '`': 53, '~': 53, ',': 54, '<': 54, '.': 55, '>': 55,
  '/': 56, '?': 56,
};

export function keyForCharacter(character: string): Key {
  if (character === ' ') {
    return { name: 'Space', code: 44 };
  }
  const letter = letters.indexOf(character.toLowerCase());
  if (letter >= 0) {
    return { name: character, code: 4 + letter };
  }
  const digit = Math.max(digits.indexOf(character), shiftedDigits.indexOf(character));
  if (digit >= 0) {
    return { name: character, code: 30 + digit };
  }
  return { name: character, code: symbolCodes[character] ?? 0 };
}

const returnKey: Key = { name: 'Return', code: 40 };
const backspaceKey: Key = { name: 'Backspace', code: 42 };

export function KeyPressScreen() {
  const [events, setEvents] = useState<KeyEvent[]>([]);
  const previous = useRef('');
  const counter = useRef(0);

  const press = (keys: Key[]) => {
    const pressed = keys.map((key) => {
      counter.current += 1;
      return { ...key, n: counter.current };
    });
    setEvents((current) => [...current, ...pressed].slice(-10));
  };

  const onChangeText = (next: string) => {
    const before = previous.current;
    previous.current = next;
    if (next.length < before.length) {
      press([backspaceKey]);
    } else if (next.startsWith(before)) {
      press(Array.from(next.slice(before.length)).map(keyForCharacter));
    } else {
      const last = Array.from(next).pop();
      if (last) {
        press([keyForCharacter(last)]);
      }
    }
  };

  const last = events[events.length - 1];
  const describe = (key: Key) => `${key.name} (${key.code})`;

  return (
    <Screen route="key-press" style={styles.content}>
      <Readout id="key-press-title" label="Key Press Detection" textStyle={styles.title} />
      <Note>Detects key events typed into the focused field</Note>
      {last ? (
        <Readout id="last-key-press" label={`Last Key: ${describe(last)}`} value={describe(last)} />
      ) : (
        <Readout id="no-keys-pressed" label="No keys pressed yet" />
      )}
      <Readout id="key-press-count" label={`Key Count: ${counter.current}`} value={`${counter.current}`} />
      <TextInput
        testID="key-press-field"
        autoFocus
        onChangeText={onChangeText}
        onSubmitEditing={() => press([returnKey])}
        submitBehavior="submit"
        keyboardType={Platform.OS === 'ios' ? 'ascii-capable' : 'visible-password'}
        autoCorrect={false}
        autoCapitalize="none"
        spellCheck={false}
        autoComplete="off"
        smartInsertDelete={false}
        style={styles.field}
      />
      <View style={styles.history}>
        {events
          .slice(-5)
          .reverse()
          .map((event) => (
            <Readout key={event.n} id={`key-event-${event.n}`} label={describe(event)} textStyle={styles.event} />
          ))}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 12, alignItems: 'stretch' },
  title: { fontSize: 20, fontWeight: '700', textAlign: 'center' },
  field: {
    height: 44,
    paddingHorizontal: 12,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: colours.accent,
    fontSize: 17,
    color: colours.text,
  },
  history: { gap: 4 },
  event: { fontSize: 15, fontFamily: Platform.select({ ios: 'Menlo', default: 'monospace' }) },
});
