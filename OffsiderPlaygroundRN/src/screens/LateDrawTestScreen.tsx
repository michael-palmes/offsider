import { useRef, useState } from 'react';
import { Animated, StyleSheet, View } from 'react-native';

import { colours, FullPage, Readout, Screen, Target, useHardwareBack } from '../fixtures';

const fadeMs = 1200;

/// A page the accessibility tree lists as soon as it mounts, while its pixels take over a second to arrive, as a slow push does on a phone.
export function LateDrawTestScreen() {
  const [open, setOpen] = useState(false);
  const opacity = useRef(new Animated.Value(0.01)).current;

  const close = () => {
    opacity.setValue(0.01);
    setOpen(false);
  };

  useHardwareBack(open, close);

  const openPage = () => {
    setOpen(true);
    Animated.timing(opacity, { toValue: 1, duration: fadeMs, useNativeDriver: true }).start();
  };

  return (
    <View style={styles.root}>
      <Screen route="late-draw" style={styles.content}>
        <Readout id="late-draw-state" label="First Page" />
        <Target id="late-draw-open" label="Open Late Page" onPress={openPage} />
      </Screen>
      {open ? (
        <Animated.View style={[StyleSheet.absoluteFill, { opacity }]}>
          <FullPage id="late-draw-page" backId="late-draw-back" titleId="late-draw-title" title="Late Page" onBack={close}>
            <View style={styles.page}>
              <Readout id="late-draw-page-state" label="Late Page Shown" />
            </View>
          </FullPage>
        </Animated.View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
  },
  content: {
    alignItems: 'center',
    gap: 16,
    padding: 16,
  },
  page: {
    alignItems: 'center',
    backgroundColor: colours.accent,
    flex: 1,
    justifyContent: 'center',
  },
});
