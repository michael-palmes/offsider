import { useRef, useState } from 'react';
import { Animated, Easing, Keyboard, Modal, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, fixtureLog, HeaderMarker, hiddenFromAccessibility, Screen, Target } from '../fixtures';

type Sheet = 'None' | 'Modal' | 'Inline' | 'Hiding' | 'Root';
const rootSheetTravel = 400;

export function MaskSheetTestScreen() {
  const insets = useSafeAreaInsets();
  const [sheet, setSheet] = useState<Sheet>('None');

  // The root sheet hides the whole screen, header included, once it has risen; the screen stays drawn, dimmed.
  const [screenHidden, setScreenHidden] = useState(false);
  const rise = useRef(new Animated.Value(0)).current;
  const rootUp = sheet === 'Root';

  const show = (next: Sheet) => {
    Keyboard.dismiss();
    fixtureLog('mask-sheet-test', `sheet ${next}`);
    setSheet(next);
  };

  const showRoot = (up: boolean) => {
    if (up) {
      show('Root');
    }
    Animated.timing(rise, { toValue: up ? 1 : 0, duration: 200, easing: Easing.out(Easing.cubic), useNativeDriver: true }).start(
      ({ finished }) => {
        if (!finished) {
          return;
        }
        setScreenHidden(up);
        if (!up) {
          show('None');
        }
      },
    );
  };

  const body = (
    <View style={styles.sheetBody}>
      <HeaderMarker id="mask-sheet-test-sheet-title" title="About this receipt" style={styles.sheetHeader} />
      <Text style={styles.sheetText}>Network fees are paid to miners.</Text>
      <Target id="mask-sheet-test-close" label="Close Sheet" onPress={() => show('None')} />
    </View>
  );

  return (
    <View style={styles.root}>
      <View style={styles.root} {...hiddenFromAccessibility(screenHidden)}>
        <Screen route="mask-sheet-test">
          <View
            style={styles.receipt}
            importantForAccessibility={sheet === 'Hiding' ? 'no-hide-descendants' : 'auto'}
            accessibilityElementsHidden={sheet === 'Hiding'}
          >
            <TextInput
              testID="mask-sheet-test-email"
              accessibilityLabel="Receipt Email"
              placeholder="Receipt email"
              placeholderTextColor={colours.secondary}
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="email-address"
              style={styles.field}
            />
            <Text testID="mask-sheet-test-address" style={styles.row}>Address bc1q...7k3m</Text>
            <Text testID="mask-sheet-test-txid" style={styles.row}>Transaction 4a9f...e21b</Text>
            <Text testID="mask-sheet-test-sheet-state" style={styles.row}>{`Sheet: ${sheet}`}</Text>
            <Target id="mask-sheet-test-open-modal" label="Open Modal Sheet" onPress={() => show('Modal')} />
            <Target id="mask-sheet-test-open-inline" label="Open Inline Sheet" onPress={() => show('Inline')} />
            <Target id="mask-sheet-test-open-hiding" label="Open Hiding Sheet" onPress={() => show('Hiding')} />
            <Target id="mask-sheet-test-open-root" label="Open Root Sheet" onPress={() => showRoot(true)} />
          </View>
          {sheet === 'Inline' || sheet === 'Hiding' ? (
            <View style={StyleSheet.absoluteFill}>
              <Pressable accessibilityLabel="Dismiss" style={styles.backdrop} onPress={() => show('None')} />
              <View style={[styles.sheet, { paddingBottom: insets.bottom + 16 }]}>{body}</View>
            </View>
          ) : null}
          <Modal visible={sheet === 'Modal'} transparent animationType="slide" onRequestClose={() => show('None')}>
            <View style={styles.modalRoot}>
              <Pressable accessibilityLabel="Dismiss" style={styles.backdrop} onPress={() => show('None')} />
              <View style={[styles.sheet, { paddingBottom: insets.bottom + 16 }]}>{body}</View>
            </View>
          </Modal>
        </Screen>
      </View>
      <View
        accessibilityViewIsModal={rootUp}
        {...hiddenFromAccessibility(!rootUp)}
        style={[StyleSheet.absoluteFill, { transform: [{ translateY: rootUp ? 0 : 10000 }] }]}
      >
        <Animated.View style={[styles.rootBackdrop, { opacity: rise.interpolate({ inputRange: [0, 1], outputRange: [0, 0.4] }) }]}>
          <Pressable accessible={false} style={StyleSheet.absoluteFill} onPress={() => showRoot(false)} />
        </Animated.View>
        <Animated.View
          style={[
            styles.sheet,
            {
              paddingBottom: insets.bottom + 16,
              transform: [{ translateY: rise.interpolate({ inputRange: [0, 1], outputRange: [rootSheetTravel, 0] }) }],
            },
          ]}
        >
          <View style={styles.sheetBody}>
            <HeaderMarker id="mask-sheet-test-root-title" title="Receipt Details" style={styles.sheetHeader} />
            <Text style={styles.sheetText}>Receipts are kept for seven years.</Text>
            <Target id="mask-sheet-test-root-close" label="Close Root Sheet" onPress={() => showRoot(false)} />
          </View>
        </Animated.View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  receipt: { padding: 16, gap: 16, alignItems: 'center' },
  field: {
    alignSelf: 'stretch',
    height: 44,
    paddingHorizontal: 12,
    borderRadius: 8,
    backgroundColor: colours.panel,
    fontSize: 17,
    color: colours.text,
  },
  rootBackdrop: { ...StyleSheet.absoluteFill, backgroundColor: '#000000' },
  row: { fontSize: 17, color: colours.text },
  modalRoot: { flex: 1 },
  backdrop: { flex: 1, backgroundColor: 'rgba(0, 0, 0, 0.4)' },
  sheet: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    height: '35%',
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    backgroundColor: colours.panel,
  },
  sheetBody: { alignItems: 'center', gap: 16, padding: 16 },
  sheetHeader: { alignSelf: 'stretch', paddingVertical: 12 },
  sheetText: { fontSize: 15, color: colours.secondary },
});
