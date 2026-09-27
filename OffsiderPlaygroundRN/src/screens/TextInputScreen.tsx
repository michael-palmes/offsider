import { useState } from 'react';
import { Platform, StyleSheet, TextInput, View } from 'react-native';

import { colours, Note, Readout, Screen } from '../fixtures';

function countParts(text: string, separator: string): number {
  return text.split(separator).filter((part) => part.length > 0).length;
}

export function TextInputScreen() {
  const [text, setText] = useState('');
  const [focused, setFocused] = useState(false);

  return (
    <Screen route="text-input" style={styles.content}>
      <Readout id="text-input-title" label="Text Input Playground" textStyle={styles.title} />
      <Note>Type directly to test text input</Note>
      <TextInput
        testID="text-input-field"
        autoFocus
        onChangeText={setText}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        keyboardType={Platform.OS === 'ios' ? 'ascii-capable' : 'visible-password'}
        autoCorrect={false}
        autoCapitalize="none"
        spellCheck={false}
        autoComplete="off"
        smartInsertDelete={false}
        style={styles.field}
      />
      {focused && <Readout id="typing-active-indicator" label="✏️ Typing active" />}
      {text.length > 0 && (
        <View style={styles.analysis}>
          <Note style={styles.analysisTitle}>Input Analysis:</Note>
          <Readout id="character-count" label={`Characters: ${Array.from(text).length}`} />
          <Readout id="word-count" label={`Words: ${countParts(text, ' ')}`} />
          <Readout id="line-count" label={`Lines: ${countParts(text, '\n')}`} />
        </View>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 16, alignItems: 'stretch' },
  title: { fontSize: 20, fontWeight: '700', textAlign: 'center' },
  field: {
    height: 44,
    paddingHorizontal: 12,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: colours.separator,
    fontSize: 17,
    color: colours.text,
  },
  analysis: { gap: 6, padding: 12, borderRadius: 8, backgroundColor: colours.panel },
  analysisTitle: { fontWeight: '600', color: colours.text },
});
