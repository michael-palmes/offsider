import { useEffect, useRef, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { colours, fixtureLog, FullPage, iosValue, Readout, Screen, Target, useHardwareBack } from '../fixtures';

const tickMs = 1000;
const openDetailMs = 1200;
const basePriceCents = 6_401_234;
const priceStepsCents = [0, 127, 41, 268, 155, -82, 19, 203, -37, 96];
const baseVolume = 18_402_117;
const volumeStep = 1_373;
const intervals = ['1D', '1W'] as const;
type Interval = (typeof intervals)[number];

function grouped(value: number): string {
  return String(value).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function price(tick: number): string {
  const cents = basePriceCents + priceStepsCents[tick % priceStepsCents.length];
  return `$${grouped(Math.floor(cents / 100))}.${String(cents % 100).padStart(2, '0')}`;
}

function onOff(value: boolean): string {
  return value ? 'On' : 'Off';
}

export function LiveTickerTestScreen() {
  const [tick, setTick] = useState(0);
  const [alerts, setAlerts] = useState(false);
  const [selected, setSelected] = useState<Interval>('1D');
  const [detail, setDetail] = useState(false);
  const detailTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const volume = `$${grouped(baseVolume + tick * volumeStep)}`;

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

  const selectInterval = (value: Interval) => {
    console.log(`OffsiderFixture Range Selected ${value}`);
    fixtureLog('live-ticker', `interval ${value}`);
    setSelected(value);
  };

  return (
    <View style={styles.root}>
      <Screen route="live-ticker" style={styles.content}>
        <Readout id="live-ticker-price" label={price(tick)} textStyle={styles.price} />
        <View style={styles.row}>
          <View
            testID="live-ticker-volume"
            accessible
            accessibilityRole="text"
            accessibilityLabel="Orders (24h)"
            accessibilityValue={iosValue(volume)}
          >
            <Text importantForAccessibility="no" style={styles.label}>
              Orders (24h)
            </Text>
          </View>
          <Readout id="live-ticker-volume-amount" label={volume} />
        </View>
        <Readout id="live-ticker-inert" label="Chart Area" style={styles.inert} textStyle={styles.inertText} />
        <View style={styles.row}>
          <View style={styles.intervals}>
            {intervals.map((value) => (
              <Target
                key={value}
                id={`live-ticker-interval-${value.toLowerCase()}`}
                label={value}
                state={{ selected: selected === value }}
                onPress={() => selectInterval(value)}
                style={[styles.interval, selected === value && styles.rangeSelected]}
                textStyle={[styles.intervalText, selected === value && styles.intervalTextSelected]}
              />
            ))}
          </View>
          <View
            testID="live-ticker-interval"
            accessible
            accessibilityRole="text"
            accessibilityLabel="Interval"
            accessibilityValue={iosValue(selected)}
          >
            <Text importantForAccessibility="no" style={styles.label}>
              {`Interval: ${selected}`}
            </Text>
          </View>
        </View>
        <View style={styles.row}>
          <Target
            id="live-ticker-toggle"
            label="Price Alerts"
            role="switch"
            state={{ checked: alerts }}
            onPress={() => {
              fixtureLog('live-ticker', `price alerts ${onOff(!alerts).toLowerCase()}`);
              setAlerts((current) => !current);
            }}
            style={[styles.track, alerts && styles.trackOn]}
          >
            <View style={styles.thumb} />
          </Target>
          <Readout id="live-ticker-toggle-state" label={`Price Alerts: ${onOff(alerts)}`} value={onOff(alerts)} />
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
          title="Price Detail"
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
  price: { fontSize: 34, fontWeight: '700' },
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
  intervals: { flexDirection: 'row', gap: 8 },
  interval: { minWidth: 56, backgroundColor: colours.panel },
  rangeSelected: { backgroundColor: colours.accent },
  intervalText: { color: colours.accent },
  intervalTextSelected: { color: '#FFFFFF' },
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
