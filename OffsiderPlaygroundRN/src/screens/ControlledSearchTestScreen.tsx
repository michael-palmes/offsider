import { useEffect, useState } from 'react';
import { StyleSheet, TextInput, type TextInputProps, View } from 'react-native';

import { colours, fixtureLog, Readout, Screen, Target } from '../fixtures';

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

/** Sets the value from its own state, then spreads the caller's props over it. */
function BaseInput(props: TextInputProps) {
  const [text] = useState(props.value);
  return <TextInput value={text} {...props} />;
}

/** Keeps its own copy of the text, written on each key and again when the caller's value comes back down. */
function TwoSourceInput({ value, onChangeText, ...rest }: TextInputProps) {
  const [shown, setShown] = useState(value ?? '');

  useEffect(() => {
    setShown(value ?? '');
  }, [value]);

  return (
    <BaseInput
      {...rest}
      value={shown}
      onChangeText={(text) => {
        setShown(text);
        onChangeText?.(text);
      }}
    />
  );
}

export function ControlledSearchTestScreen() {
  const [query, setQuery] = useState('');
  const [twoSources, setTwoSources] = useState(false);
  const matches = filtered(query);
  const Field = twoSources ? TwoSourceInput : TextInput;

  return (
    <Screen route="controlled-search-test">
      <View style={styles.searchBar}>
        <Field
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
        <Target
          id="controlled-search-source"
          label={`Value Source: ${twoSources ? 'State And Props' : 'State'}`}
          onPress={() => {
            fixtureLog('controlled-search-test', `value source ${twoSources ? 'state' : 'state and props'}`);
            setQuery('');
            setTwoSources((current) => !current);
          }}
          style={styles.source}
          textStyle={styles.sourceText}
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
  searchBar: { padding: 16, paddingBottom: 8, gap: 8 },
  source: { alignSelf: 'flex-start', backgroundColor: colours.panel },
  sourceText: { color: colours.accent, fontSize: 15 },
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
