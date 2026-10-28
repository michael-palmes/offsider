import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, fixtureLog, FullPage, Readout, Screen, Target, useHardwareBack } from '../fixtures';

const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'] as const;

export function KeypadTestScreen() {
  const insets = useSafeAreaInsets();
  const [amount, setAmount] = useState('');
  const [keypad, setKeypad] = useState(false);
  const [pressed, setPressed] = useState('None');
  const [pages, setPages] = useState(0);

  const press = (what: string) => {
    fixtureLog('keypad-test', `pressed ${what}`);
    setPressed(what);
  };

  useHardwareBack(pages > 0, () => setPages((current) => current - 1));

  return (
    <View style={styles.root}>
      <Screen route="keypad-test">
        <Readout id="keypad-test-pressed" label={`Keypad Pressed: ${pressed}`} value={pressed} style={styles.readout} />
        <Pressable
          testID="keypad-test-copy-row"
          accessibilityRole="button"
          accessibilityLabel="Copy Reference, Reference Info"
          onPress={() => press('Copy Row')}
          style={styles.copyRow}
        >
          <Text importantForAccessibility="no" style={styles.copyText}>
            Copy Reference
          </Text>
          <Target id="keypad-test-copy-info" label="Reference Info" onPress={() => press('Reference Info')} style={styles.info} />
        </Pressable>
        <Target id="keypad-test-open-details" label="Open Details" onPress={() => setPages(1)} style={styles.action} />
        <Pressable
          testID="keypad-test-amount"
          accessibilityRole="button"
          accessibilityLabel={`Amount, ${amount || '0'}, Points`}
          onPress={() => {
            fixtureLog('keypad-test', 'amount pressed');
            setKeypad(true);
          }}
          style={styles.amount}
        >
          <Text importantForAccessibility="no" style={styles.amountText}>
            {amount || '0'} pts
          </Text>
        </Pressable>
      </Screen>
      {keypad && (
        <View testID="keypad-test-keypad" style={[styles.keypad, { paddingBottom: insets.bottom + 8 }]}>
          {keys.map((key) => (
            <Pressable
              key={key}
              testID={`keypad-test-key-${key}`}
              accessibilityRole="keyboardkey"
              accessibilityLabel={key}
              onPress={() => {
                fixtureLog('keypad-test', `key ${key}`);
                setAmount((current) => (current + key).slice(0, 9));
              }}
              style={({ pressed: down }) => [styles.key, down && styles.keyDown]}
            >
              <Text importantForAccessibility="no" style={styles.keyText}>
                {key}
              </Text>
            </Pressable>
          ))}
          <Target id="keypad-test-done" label="Done" onPress={() => setKeypad(false)} style={styles.done} />
        </View>
      )}
      {pages >= 1 && (
        <FullPage
          id="keypad-test-details"
          backId="keypad-test-details-back"
          titleId="keypad-test-details-title"
          title="Details"
          onBack={() => setPages(0)}
        >
          <View style={styles.pageBody}>
            <Target id="keypad-test-open-notes" label="Open Notes" onPress={() => setPages(2)} />
          </View>
        </FullPage>
      )}
      {pages >= 2 && (
        <FullPage
          id="keypad-test-notes"
          backId="keypad-test-notes-back"
          titleId="keypad-test-notes-title"
          title="Notes"
          onBack={() => setPages(1)}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  readout: { padding: 16, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colours.separator },
  copyRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginHorizontal: 16,
    marginTop: 16,
    paddingLeft: 16,
    paddingRight: 8,
    height: 64,
    borderRadius: 10,
    backgroundColor: colours.panel,
  },
  copyText: { fontSize: 17, color: colours.text },
  info: { width: 120, minHeight: 40 },
  action: { marginHorizontal: 16, marginTop: 16 },
  amount: { flex: 1, margin: 16, alignItems: 'center', paddingTop: 48, borderRadius: 10, backgroundColor: colours.panel },
  amountText: { fontSize: 40, fontWeight: '600', color: colours.text },
  keypad: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    flexDirection: 'row',
    flexWrap: 'wrap',
    paddingHorizontal: 8,
    paddingTop: 8,
    backgroundColor: colours.separator,
  },
  key: { width: '33.33%', height: 56, alignItems: 'center', justifyContent: 'center' },
  keyDown: { opacity: 0.5 },
  keyText: { fontSize: 24, color: colours.text },
  done: { width: '66.66%', height: 56 },
  pageBody: { padding: 16, gap: 16 },
});
