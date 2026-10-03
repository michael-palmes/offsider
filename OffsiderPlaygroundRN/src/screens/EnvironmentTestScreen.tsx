import { useEffect, useRef, useState } from 'react';
import {
  Animated,
  Easing,
  PixelRatio,
  ScrollView,
  StyleSheet,
  useColorScheme,
  useWindowDimensions,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colours, fixtureLog, Readout, Screen, Target } from '../fixtures';

const flashDelayMs = 1000;
const spinMs = 1500;

type LogLevel = 'info' | 'warning' | 'error';

const loggers: Record<LogLevel, (message: string) => void> = {
  info: (message) => console.log(message),
  warning: (message) => console.warn(message),
  error: (message) => console.error(message),
};

export function EnvironmentTestScreen() {
  const insets = useSafeAreaInsets();
  const scheme = useColorScheme() ?? 'unspecified';
  const { width, height, fontScale } = useWindowDimensions();
  const orientation = width > height ? 'landscape' : 'portrait';
  const pixelRatio = PixelRatio.get();

  const [animating, setAnimating] = useState(false);
  const [flashed, setFlashed] = useState(false);
  const [logCount, setLogCount] = useState(0);
  const logs = useRef(0);
  const rotation = useRef(new Animated.Value(0)).current;
  const flashTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (!animating) {
      return;
    }
    rotation.setValue(0);
    const loop = Animated.loop(
      Animated.timing(rotation, { toValue: 1, duration: spinMs, easing: Easing.linear, useNativeDriver: true }),
    );
    loop.start();
    return () => loop.stop();
  }, [animating, rotation]);

  useEffect(
    () => () => {
      if (flashTimer.current) {
        clearTimeout(flashTimer.current);
      }
    },
    [],
  );

  const flash = () => {
    fixtureLog('environment-test', 'flash scheduled');
    if (flashTimer.current) {
      clearTimeout(flashTimer.current);
    }
    flashTimer.current = setTimeout(() => {
      flashTimer.current = null;
      fixtureLog('environment-test', 'flash');
      setFlashed((current) => !current);
    }, flashDelayMs);
  };

  const log = (level: LogLevel) => {
    logs.current += 1;
    fixtureLog('environment-test', `log ${level} ${logs.current}`);
    loggers[level](`OffsiderFixture ${level} ${logs.current}`);
    setLogCount(logs.current);
  };

  const spin = rotation.interpolate({ inputRange: [0, 1], outputRange: ['0deg', '360deg'] });

  return (
    <Screen route="environment-test">
      <ScrollView contentContainerStyle={[styles.body, { paddingBottom: insets.bottom + 16 }]}>
        <Readout id="environment-test-scheme" label={`Colour Scheme: ${scheme}`} value={scheme} />
        <Readout id="environment-test-font-scale" label={`Font Scale: ${fontScale.toFixed(2)}`} />
        <Readout id="environment-test-window" label={`Window: ${Math.round(width)}x${Math.round(height)}`} />
        <Readout id="environment-test-orientation" label={`Orientation: ${orientation}`} value={orientation} />
        <Readout id="environment-test-pixel-ratio" label={`Pixel Ratio: ${pixelRatio}`} />
        <View
          testID="environment-test-swatch"
          accessible
          accessibilityLabel="Scheme Swatch"
          style={[styles.swatch, scheme === 'dark' ? styles.swatchDark : styles.swatchLight]}
        />
        <View
          testID="environment-test-canvas"
          accessible
          accessibilityLabel="Canvas"
          style={[styles.canvas, flashed ? styles.canvasFlashed : styles.canvasPlain]}
        >
          <View
            accessibilityElementsHidden
            importantForAccessibility="no-hide-descendants"
            style={styles.canvasInner}
          >
            <Animated.View style={[styles.spinner, { transform: [{ rotate: spin }] }]} />
          </View>
        </View>
        <Readout id="environment-test-canvas-state" label={`Canvas: ${animating ? 'Animating' : 'Still'}`} />
        <View style={styles.row}>
          <Target
            id="environment-test-canvas-toggle"
            label={animating ? 'Stop Animation' : 'Start Animation'}
            onPress={() => {
              fixtureLog('environment-test', animating ? 'stop animation' : 'start animation');
              setAnimating((current) => !current);
            }}
          />
          <Target id="environment-test-canvas-flash" label="Flash in 1 s" onPress={flash} />
        </View>
        <Readout id="environment-test-log-count" label={`Log Count: ${logCount}`} value={String(logCount)} />
        <View style={styles.row}>
          <Target id="environment-test-log" label="Log Info" onPress={() => log('info')} />
          <Target id="environment-test-warn" label="Log Warning" onPress={() => log('warning')} />
          <Target id="environment-test-error" label="Log Error" onPress={() => log('error')} />
        </View>
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  body: { padding: 16, gap: 12, alignItems: 'center' },
  swatch: { width: 120, height: 60, borderRadius: 8, borderWidth: 1, borderColor: colours.separator },
  swatchLight: { backgroundColor: '#FFFFFF' },
  swatchDark: { backgroundColor: '#121212' },
  canvas: { width: 240, height: 120, borderRadius: 8, overflow: 'hidden' },
  canvasPlain: { backgroundColor: '#E5F0FF' },
  canvasFlashed: { backgroundColor: '#FFB020' },
  canvasInner: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  spinner: { width: 64, height: 64, borderRadius: 6, backgroundColor: colours.accent },
  row: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'center', gap: 8 },
});
