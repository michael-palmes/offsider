import { useEffect, useRef, useState } from 'react';
import { Platform, StyleSheet, TextInput, View } from 'react-native';

import { colours, Note, Readout, Screen } from '../fixtures';

const groupingDelayMs = 1000;

export function KeySequenceScreen() {
  const [current, setCurrent] = useState<string[]>([]);
  const [sequences, setSequences] = useState<string[][]>([]);
  const field = useRef<TextInput>(null);
  const pending = useRef<string[]>([]);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timer.current) {
        clearTimeout(timer.current);
      }
    },
    [],
  );

  const onChangeText = (text: string) => {
    const last = Array.from(text).pop();
    field.current?.clear();
    if (!last) {
      return;
    }
    pending.current = [...pending.current, last];
    setCurrent(pending.current);
    if (timer.current) {
      clearTimeout(timer.current);
    }
    timer.current = setTimeout(() => {
      timer.current = null;
      const keys = pending.current;
      pending.current = [];
      setCurrent([]);
      setSequences((existing) => [...existing, keys]);
    }, groupingDelayMs);
  };

  return (
    <Screen route="key-sequence" style={styles.content}>
      <Readout id="key-sequence-title" label="Key Sequence Detection" textStyle={styles.title} />
      <Note>Detects key sequences sent by CLI</Note>
      <TextInput
        ref={field}
        testID="key-sequence-field"
        autoFocus
        onChangeText={onChangeText}
        keyboardType={Platform.OS === 'ios' ? 'ascii-capable' : 'visible-password'}
        autoCorrect={false}
        autoCapitalize="none"
        spellCheck={false}
        autoComplete="off"
        smartInsertDelete={false}
        style={styles.field}
      />
      {current.length > 0 && <Readout id="key-sequence-current" label={`Current: ${current.join(' → ')}`} />}
      {sequences.length > 0 && (
        <View style={styles.history}>
          <Note style={styles.historyTitle}>Detected Sequences:</Note>
          {sequences.slice(-5).map((keys, index, recent) => {
            const n = sequences.length - recent.length + index + 1;
            return <Readout key={n} id={`key-sequence-${n}`} label={keys.join(' → ')} />;
          })}
        </View>
      )}
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
  historyTitle: { fontWeight: '600', color: colours.text },
});
