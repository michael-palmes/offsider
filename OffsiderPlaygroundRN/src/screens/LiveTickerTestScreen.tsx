import { useEffect, useRef, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { colours, fixtureLog, FullPage, iosValue, Readout, Screen, Target, useHardwareBack } from '../fixtures';

const tickMs = 1000;
const openDetailMs = 1200;
const basePriceCents = 12_995;
const priceStepsCents = [0, 127, 41, 268, 155, -82, 19, 203, -37, 96];
const baseOrders = 18_402;
const ordersStep = 3;
const sizes = ['S', 'M'] as const;
type Size = (typeof sizes)[number];

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
  const [selected, setSelected] = useState<Size>('S');
  const [detail, setDetail] = useState(false);
  const detailTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const orders = grouped(baseOrders + tick * ordersStep);

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
        <Readout id="live-ticker-price" label={price(tick)} textStyle={styles.price} />
        <View style={styles.row}>
          <View
            testID="live-ticker-orders"
            accessible
            accessibilityRole="text"
            accessibilityLabel="Orders (24h)"
            accessibilityValue={iosValue(orders)}
          >
            <Text importantForAccessibility="no" style={styles.label}>
              Orders (24h)
            </Text>
          </View>
          <Readout id="live-ticker-orders-count" label={orders} />
        </View>
        <Readout id="live-ticker-inert" label="Chart Area" style={styles.inert} textStyle={styles.inertText} />
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
