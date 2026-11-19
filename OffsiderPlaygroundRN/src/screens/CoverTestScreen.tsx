import { useEffect, useRef, useState } from 'react';
import { Animated, Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, fixtureLog, FullPage, Readout, Screen, Target, useHardwareBack } from '../fixtures';

const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'] as const;
const keypadRows = 4;
const keyHeight = 56;

export function CoverTestScreen() {
  const insets = useSafeAreaInsets();
  const [amount, setAmount] = useState('');
  const [keypad, setKeypad] = useState(false);
  const [pressed, setPressed] = useState('None');
  const [pages, setPages] = useState(0);

  const press = (what: string) => {
    fixtureLog('cover-test', `pressed ${what}`);
    setPressed(what);
  };

  useHardwareBack(pages > 0, () => setPages((current) => current - 1));

  // The keypad stays mounted and is parked below the screen while closed, with nothing hiding it from accessibility.
  const shown = useRef(new Animated.Value(0)).current;
  const keypadHeight = keypadRows * keyHeight + insets.bottom + 16;
  useEffect(() => {
    Animated.timing(shown, { toValue: keypad ? 1 : 0, duration: 300, useNativeDriver: true }).start();
  }, [keypad, shown]);

  return (
    <View style={styles.root}>
      <Screen route="cover-test">
        <Readout id="cover-test-pressed" label={`Cover Pressed: ${pressed}`} value={pressed} style={styles.readout} />
        <Pressable
          testID="cover-test-copy-row"
          accessibilityRole="button"
          accessibilityLabel="Copy Reference, Reference Info"
          onPress={() => press('Copy Row')}
          style={styles.copyRow}
        >
          <Text importantForAccessibility="no" style={styles.copyText}>
            Copy Reference
          </Text>
          <Target id="cover-test-copy-info" label="Reference Info" onPress={() => press('Reference Info')} style={styles.info} />
        </Pressable>
        <Target id="cover-test-open-details" label="Open Details" onPress={() => setPages(1)} style={styles.action} />
        <View style={styles.cards}>
          {/* A card whose own text is drawn at its centre. */}
          <View testID="cover-test-own-card" collapsable={false} importantForAccessibility="yes" style={styles.card}>
            <Text style={styles.cardText}>Own Total</Text>
          </View>
          {/* A card with a label drawn over its centre from beside it, not from inside it. */}
          <View style={styles.cardSlot}>
            <View testID="cover-test-badge-card" collapsable={false} importantForAccessibility="yes" style={[styles.card, styles.badgeCard]}>
              <Text style={styles.cardCorner}>Badge Card</Text>
            </View>
            <Text testID="cover-test-badge" style={styles.badge}>
              New
            </Text>
          </View>
        </View>
        <Pressable
          testID="cover-test-amount"
          accessibilityRole="button"
          accessibilityLabel={`Amount, ${amount || '0'}, Points`}
          onPress={() => {
            fixtureLog('cover-test', 'amount pressed');
            setKeypad(true);
          }}
          style={styles.amount}
        >
          <Text importantForAccessibility="no" style={styles.amountText}>
            {amount || '0'} pts
          </Text>
        </Pressable>
      </Screen>
      <Animated.View
        testID="cover-test-keypad"
        style={[
          styles.keypad,
          {
            paddingBottom: insets.bottom + 8,
            opacity: shown.interpolate({ inputRange: [0, 0.0001, 1], outputRange: [0, 1, 1] }),
            transform: [{ translateY: shown.interpolate({ inputRange: [0, 1], outputRange: [keypadHeight + 10, 0] }) }],
          },
        ]}
      >
        {keys.map((key) => (
          <Pressable
            key={key}
            testID={`cover-test-key-${key}`}
            accessibilityRole="keyboardkey"
            accessibilityLabel={key}
            onPress={() => {
              fixtureLog('cover-test', `key ${key}`);
              setAmount((current) => (current + key).slice(0, 9));
            }}
            style={({ pressed: down }) => [styles.key, down && styles.keyDown]}
          >
            <Text importantForAccessibility="no" style={styles.keyText}>
              {key}
            </Text>
          </Pressable>
        ))}
        <Target id="cover-test-done" label="Done" onPress={() => setKeypad(false)} style={styles.done} />
      </Animated.View>
      {pages >= 1 && (
        <FullPage
          id="cover-test-details"
          backId="cover-test-details-back"
          titleId="cover-test-details-title"
          title="Details"
          onBack={() => setPages(0)}
        >
          <View style={styles.pageBody}>
            <Target id="cover-test-open-notes" label="Open Notes" onPress={() => setPages(2)} />
          </View>
        </FullPage>
      )}
      {pages >= 2 && (
        <FullPage
          id="cover-test-notes"
          backId="cover-test-notes-back"
          titleId="cover-test-notes-title"
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
  cards: { flexDirection: 'row', gap: 16, marginHorizontal: 16, marginTop: 16 },
  cardSlot: { flex: 1, height: 72, alignItems: 'center', justifyContent: 'center' },
  card: { flex: 1, height: 72, alignItems: 'center', justifyContent: 'center', borderRadius: 10, backgroundColor: colours.panel },
  badgeCard: { ...StyleSheet.absoluteFill, flex: 0, height: undefined, alignItems: 'flex-start', justifyContent: 'flex-start', padding: 8 },
  cardText: { fontSize: 17, color: colours.text },
  cardCorner: { fontSize: 13, color: colours.text },
  badge: { fontSize: 13, fontWeight: '600', color: colours.text },
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
  key: { width: '33.33%', height: keyHeight, alignItems: 'center', justifyContent: 'center' },
  keyDown: { opacity: 0.5 },
  keyText: { fontSize: 24, color: colours.text },
  done: { width: '66.66%', height: keyHeight },
  pageBody: { padding: 16, gap: 16 },
});
