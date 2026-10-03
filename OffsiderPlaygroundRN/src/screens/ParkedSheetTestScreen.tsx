import { useRef, useState } from 'react';
import { Animated, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, fixtureLog, HeaderMarker, Readout, Screen, Target } from '../fixtures';

const sheetHeight = 320;
const parkedOffset = 10000;
const fastOpenMs = 600;
const slowOpenMs = 2500;
const closeMs = 300;

type Position = 'Parked' | 'Moving' | 'Open';

export function ParkedSheetTestScreen() {
  const insets = useSafeAreaInsets();
  const [state, setState] = useState('Initial');
  const [position, setPosition] = useState<Position>('Parked');
  const translateY = useRef(new Animated.Value(parkedOffset)).current;
  const belowEdge = sheetHeight + insets.bottom + 48;

  const open = (duration: number) => {
    fixtureLog('parked-sheet-test', `open ${duration} ms`);
    translateY.stopAnimation();
    translateY.setValue(belowEdge);
    setPosition('Moving');
    Animated.timing(translateY, { toValue: 0, duration, useNativeDriver: true }).start(({ finished }) => {
      if (finished) {
        setPosition('Open');
        fixtureLog('parked-sheet-test', 'open finished');
      }
    });
  };

  const close = () => {
    fixtureLog('parked-sheet-test', 'close');
    translateY.stopAnimation();
    setPosition('Moving');
    Animated.timing(translateY, { toValue: belowEdge, duration: closeMs, useNativeDriver: true }).start(
      ({ finished }) => {
        if (finished) {
          translateY.setValue(parkedOffset);
          setPosition('Parked');
          fixtureLog('parked-sheet-test', 'parked');
        }
      },
    );
  };

  const record = (next: string) => {
    fixtureLog('parked-sheet-test', next);
    setState(next);
  };

  return (
    <Screen route="parked-sheet-test">
      <View style={styles.body}>
        <Readout id="parked-sheet-test-state" label={`Parked Sheet State: ${state}`} value={state} />
        <Readout id="parked-sheet-test-position" label={`Sheet Position: ${position}`} value={position} />
        <Target id="parked-sheet-test-open" label="Open Filters" onPress={() => open(fastOpenMs)} />
        <Target id="parked-sheet-test-open-slow" label="Open Filters Slowly" onPress={() => open(slowOpenMs)} />
        <Target id="parked-sheet-test-body-save" label="Save" onPress={() => record('Body save')} />
      </View>
      <Animated.View
        style={[
          styles.sheet,
          { height: sheetHeight + insets.bottom, paddingBottom: insets.bottom, transform: [{ translateY }] },
        ]}
      >
        <HeaderMarker id="parked-sheet-test-sheet-title" title="Filters" style={styles.sheetHeader} />
        <Target id="parked-sheet-test-apply" label="Apply Filters" onPress={() => record('Filters applied')} />
        <Target id="parked-sheet-test-sheet-save" label="Save" onPress={() => record('Sheet save')} />
        <Target id="parked-sheet-test-close" label="Close Filters" onPress={close} />
      </Animated.View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  body: { flex: 1, padding: 16, gap: 16, alignItems: 'center' },
  sheet: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    alignItems: 'center',
    gap: 16,
    paddingHorizontal: 16,
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderColor: colours.separator,
    backgroundColor: colours.panel,
  },
  sheetHeader: { alignSelf: 'stretch', paddingVertical: 12 },
});
