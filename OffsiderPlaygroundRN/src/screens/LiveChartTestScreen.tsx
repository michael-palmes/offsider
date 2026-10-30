import { useEffect, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { colours, Readout, Screen, Target } from '../fixtures';

const tickMs = 150;
const bars = [0, 1, 2, 3, 4, 5];

function barHeight(tick: number, bar: number): number {
  return 60 + ((tick * 7 + bar * 31) % 180);
}

export function LiveChartTestScreen() {
  const [tick, setTick] = useState(0);

  useEffect(() => {
    const timer = setInterval(() => setTick((current) => current + 1), tickMs);
    return () => clearInterval(timer);
  }, []);

  return (
    <Screen route="live-chart" style={styles.content}>
      <Readout id="live-chart-title" label="Market" />
      <View testID="live-chart" style={[styles.plot, { paddingTop: tick % 40 }]}>
        {bars.map((bar) => (
          <View
            key={bar}
            accessible
            accessibilityLabel={`Bar ${bar + 1}`}
            style={[styles.bar, { height: barHeight(tick, bar) }]}
          />
        ))}
      </View>
      <Target id="live-chart-buy" label="Buy" onPress={() => {}} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: {
    alignItems: 'center',
    gap: 16,
    padding: 16,
  },
  plot: {
    alignItems: 'flex-end',
    alignSelf: 'center',
    flexDirection: 'row',
    gap: 16,
    height: 320,
  },
  bar: {
    backgroundColor: colours.accent,
    width: 24,
  },
});
