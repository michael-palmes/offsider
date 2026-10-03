import { useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';

import { colours, Readout, Screen } from '../fixtures';

const rows = ['Alpha Row', 'Beta Row'];

export function SearchableTestScreen() {
  const [query, setQuery] = useState('');
  const needle = query.toLowerCase();
  const visible = query ? rows.filter((row) => row.toLowerCase().includes(needle)) : rows;
  const queryText = query || 'empty';

  return (
    <Screen route="searchable-test">
      <View style={styles.searchBar}>
        <TextInput
          testID="searchable-test-field"
          placeholder="Search Books"
          placeholderTextColor={colours.secondary}
          onChangeText={setQuery}
          autoCorrect={false}
          autoCapitalize="none"
          spellCheck={false}
          autoComplete="off"
          smartInsertDelete={false}
          returnKeyType="search"
          style={styles.field}
        />
      </View>
      <View style={styles.list}>
        <Readout id="searchable-test-query" label={`Search Query: ${queryText}`} value={queryText} style={styles.row} />
        {visible.map((row) => (
          <Readout
            key={row}
            id={`searchable-test-${row.replace(' ', '-').toLowerCase()}`}
            label={row}
            style={styles.row}
          />
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
