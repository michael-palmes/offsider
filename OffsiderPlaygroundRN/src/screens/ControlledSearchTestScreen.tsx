import { useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';

import { colours, Readout, Screen } from '../fixtures';

const codes = Array.from({ length: 600 }, (_, index) => `CODE${String(index).padStart(3, '0')}`);
const renderCostMs = 60;

/** A filter as costly as a busy search screen's, so each key waits on a render before the next. */
function filtered(query: string): string[] {
  const until = Date.now() + renderCostMs;
  while (Date.now() < until) {
    // Holds the JS thread, as a heavy list render does.
  }
  return codes.filter((code) => code.includes(query)).slice(0, 4);
}

export function ControlledSearchTestScreen() {
  const [query, setQuery] = useState('');
  const matches = filtered(query);

  return (
    <Screen route="controlled-search-test">
      <View style={styles.searchBar}>
        <TextInput
          testID="controlled-search-field"
          placeholder="Search codes"
          placeholderTextColor={colours.secondary}
          value={query}
          onChangeText={(text) => setQuery(text.toUpperCase())}
          autoCorrect={false}
          autoCapitalize="characters"
          spellCheck={false}
          autoComplete="off"
          smartInsertDelete={false}
          style={styles.field}
        />
      </View>
      <View style={styles.list}>
        <Readout id="controlled-search-value" label={`Query: ${query || 'empty'}`} value={query || 'empty'} style={styles.row} />
        {matches.map((code) => (
          <Readout key={code} id={`controlled-search-${code.toLowerCase()}`} label={code} style={styles.row} />
        ))}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  searchBar: { padding: 16, paddingBottom: 8 },
  field: {
    height: 40,
    paddingHorizontal: 12,
    borderRadius: 10,
    backgroundColor: colours.panel,
    fontSize: 17,
    color: colours.text,
  },
  list: { paddingHorizontal: 16 },
  row: {
    paddingVertical: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
});
