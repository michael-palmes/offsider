import { useEffect, useRef, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { colours, fixtureLog, FullPage, iosValue, Readout, Screen, Target, useHardwareBack } from '../fixtures';

const tickMs = 1000;
const openDetailMs = 1200;
const baseHeartRate = 72;
const heartRateSteps = [0, 3, 1, 5, 2, -2, 0, 4, -1, 2];
const baseSteps = 18_402;
const stepsPerTick = 3;
const sizes = ['S', 'M'] as const;
type Size = (typeof sizes)[number];

function grouped(value: number): string {
  return String(value).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function heartRate(tick: number): string {
  return `${baseHeartRate + heartRateSteps[tick % heartRateSteps.length]} bpm`;
}

function onOff(value: boolean): string {
  return value ? 'On' : 'Off';
}

export function LiveTickerTestScreen() {
  const [tick, setTick] = useState(0);
  const [alerts, setAlerts] = useState(false);
  const [selected, setSelected] = useState<Size>('S');
  const [detail, setDetail] = useState(false);
  const detailTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const steps = grouped(baseSteps + tick * stepsPerTick);

  useEffect(() => {
    const timer = setInterval(() => setTick((current) => current + 1), tickMs);
    return () => clearInterval(timer);
  }, []);

  useEffect(
    () => () => {
      if (detailTimer.current) {
        clearTimeout(detailTimer.current);
      }
    },
    [],
  );

  const closeDetail = () => {
    fixtureLog('live-ticker', 'pop detail');
    setDetail(false);
  };

  useHardwareBack(detail, closeDetail);

  const openDetail = () => {
    fixtureLog('live-ticker', `push detail in ${openDetailMs} ms`);
    if (detailTimer.current) {
      clearTimeout(detailTimer.current);
    }
    detailTimer.current = setTimeout(() => {
      detailTimer.current = null;
      fixtureLog('live-ticker', 'push detail');
      setDetail(true);
    }, openDetailMs);
  };

  const selectSize = (value: Size) => {
    console.log(`OffsiderFixture Size Selected ${value}`);
    fixtureLog('live-ticker', `size ${value}`);
    setSelected(value);
  };

  return (
    <View style={styles.root}>
      <Screen route="live-ticker" style={styles.content}>
        <Readout id="live-ticker-heart-rate" label={heartRate(tick)} textStyle={styles.heartRate} />
        <View style={styles.row}>
          <View
            testID="live-ticker-steps"
            accessible
            accessibilityRole="text"
            accessibilityLabel="Steps (today)"
            accessibilityValue={iosValue(steps)}
          >
            <Text importantForAccessibility="no" style={styles.label}>
              Steps (today)
            </Text>
          </View>
          <Readout id="live-ticker-steps-count" label={steps} />
        </View>
        <Readout id="live-ticker-inert" label="Map Area" style={styles.inert} textStyle={styles.inertText} />
        <View style={styles.row}>
          <View style={styles.sizes}>
            {sizes.map((value) => (
              <Target
                key={value}
                id={`live-ticker-size-${value.toLowerCase()}`}
                label={value}
                state={{ selected: selected === value }}
                onPress={() => selectSize(value)}
                style={[styles.size, selected === value && styles.sizeSelected]}
                textStyle={[styles.sizeText, selected === value && styles.sizeTextSelected]}
              />
            ))}
          </View>
          <View
            testID="live-ticker-size"
            accessible
            accessibilityRole="text"
            accessibilityLabel="Size"
            accessibilityValue={iosValue(selected)}
          >
            <Text importantForAccessibility="no" style={styles.label}>
              {`Size: ${selected}`}
            </Text>
          </View>
        </View>
        <View style={styles.row}>
          <Target
            id="live-ticker-toggle"
            label="Goal Alerts"
            role="switch"
            state={{ checked: alerts }}
            onPress={() => {
              fixtureLog('live-ticker', `goal alerts ${onOff(!alerts).toLowerCase()}`);
              setAlerts((current) => !current);
            }}
            style={[styles.track, alerts && styles.trackOn]}
          >
            <View style={styles.thumb} />
          </Target>
          <Readout id="live-ticker-toggle-state" label={`Goal Alerts: ${onOff(alerts)}`} value={onOff(alerts)} />
        </View>
        <View style={styles.row}>
          <Target
            id="live-ticker-noop"
            label="Do Nothing"
            onPress={() => fixtureLog('live-ticker', 'do nothing pressed')}
            style={styles.flex}
          />
          <Target id="live-ticker-emit-logs" label="Emit Two Logs" onPress={emitTwoLogs} style={styles.flex} />
        </View>
        <Target id="live-ticker-open-detail" label="Open Detail" onPress={openDetail} />
      </Screen>
      {detail && (
        <FullPage
          id="live-ticker-detail-page"
          backId="live-ticker-detail-back"
          titleId="live-ticker-detail"
          title="Activity Detail"
          onBack={closeDetail}
        />
      )}
    </View>
  );
}

function emitTwoLogs() {
  fixtureLog('live-ticker', 'emit two logs');
  console.warn('OffsiderFixture warning toast');
  console.error('OffsiderFixture error toast');
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  content: { padding: 16, gap: 16 },
  heartRate: { fontSize: 34, fontWeight: '700' },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12 },
  label: { fontSize: 17, color: colours.secondary },
  inert: {
    height: 120,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 10,
    borderWidth: 1,
    borderStyle: 'dashed',
    borderColor: colours.separator,
    backgroundColor: colours.panel,
  },
  inertText: { color: colours.secondary },
  sizes: { flexDirection: 'row', gap: 8 },
  size: { minWidth: 56, backgroundColor: colours.panel },
  sizeSelected: { backgroundColor: colours.accent },
  sizeText: { color: colours.accent },
  sizeTextSelected: { color: '#FFFFFF' },
  track: {
    width: 52,
    minHeight: 32,
    height: 32,
    borderRadius: 16,
    paddingHorizontal: 2,
    alignItems: 'flex-start',
    backgroundColor: colours.separator,
  },
  trackOn: { alignItems: 'flex-end', backgroundColor: '#34C759' },
  thumb: { width: 28, height: 28, borderRadius: 14, backgroundColor: '#FFFFFF' },
  flex: { flex: 1 },
});
