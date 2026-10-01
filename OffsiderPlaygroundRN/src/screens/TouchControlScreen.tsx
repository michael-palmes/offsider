import { useEffect, useRef, useState } from 'react';
import { type GestureResponderEvent, Platform, StyleSheet, View } from 'react-native';

import { colours, formatPoint, Note, pagePoint, type Point, Readout, Screen } from '../fixtures';

const longPressDelayMs = 500;
const longPressSlop = 20;
const historyLength = 20;

type TouchEvent = { n: number; type: 'down' | 'up'; point: Point };

function distance(a: Point, b: Point): number {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

export function TouchControlScreen() {
  const [events, setEvents] = useState<TouchEvent[]>([]);
  const [eventCount, setEventCount] = useState(0);
  const [longPressCount, setLongPressCount] = useState(0);
  const [lastDown, setLastDown] = useState<Point | null>(null);
  const [lastUp, setLastUp] = useState<Point | null>(null);
  const [lastLongPress, setLastLongPress] = useState<Point | null>(null);
  const counter = useRef(0);
  const start = useRef<Point | null>(null);
  const latest = useRef<Point | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const cancelLongPress = () => {
    if (timer.current) {
      clearTimeout(timer.current);
      timer.current = null;
    }
  };
  useEffect(() => cancelLongPress, []);

  const record = (type: TouchEvent['type'], point: Point) => {
    counter.current += 1;
    const n = counter.current;
    setEvents((current) => [...current, { n, type, point }].slice(-historyLength));
    setEventCount(n);
    if (type === 'down') {
      setLastDown(point);
    } else {
      setLastUp(point);
    }
  };

  const onGrant = (event: GestureResponderEvent) => {
    const point = pagePoint(event);
    start.current = point;
    latest.current = point;
    record('down', point);
    cancelLongPress();
    timer.current = setTimeout(() => {
      timer.current = null;
      setLastLongPress(latest.current);
      setLongPressCount((current) => current + 1);
    }, longPressDelayMs);
  };

  const onMove = (event: GestureResponderEvent) => {
    const point = pagePoint(event);
    if (start.current && distance(point, start.current) >= longPressSlop) {
      cancelLongPress();
    }
    if (latest.current && distance(point, latest.current) >= 1) {
      latest.current = point;
      record('down', point);
    }
  };

  const onEnd = (event: GestureResponderEvent) => {
    cancelLongPress();
    record('up', pagePoint(event));
    start.current = null;
    latest.current = null;
  };

  return (
    <Screen route="touch-control">
      <View
        testID="touch-control-area"
        style={StyleSheet.absoluteFill}
        onStartShouldSetResponder={() => true}
        onResponderTerminationRequest={() => false}
        onResponderGrant={onGrant}
        onResponderMove={onMove}
        onResponderRelease={onEnd}
        onResponderTerminate={onEnd}
      />
      <View pointerEvents="none" style={styles.panel}>
        <Readout id="touch-control-title" label="Touch Control Playground" textStyle={styles.title} />
        <Note>Drag to see touch down/up events</Note>
        <Note>Hold for at least 0.5s to trigger long press</Note>
        <Readout id="touch-event-count" label={`Events: ${eventCount}`} value={`${eventCount}`} />
        <Readout id="long-press-count" label={`Long presses: ${longPressCount}`} value={`${longPressCount}`} />
        {lastDown && (
          <Readout
            id="last-touch-down-coordinates"
            label={`Last touch down: ${formatPoint(lastDown)}`}
            value={`x:${lastDown.x},y:${lastDown.y}`}
          />
        )}
        {lastUp && (
          <Readout
            id="last-touch-up-coordinates"
            label={`Last touch up: ${formatPoint(lastUp)}`}
            value={`x:${lastUp.x},y:${lastUp.y}`}
          />
        )}
        {lastLongPress && (
          <Readout
            id="last-long-press-coordinates"
            label={`Last long press: ${formatPoint(lastLongPress)}`}
            value={`x:${lastLongPress.x},y:${lastLongPress.y}`}
          />
        )}
      </View>
      <View pointerEvents="none" style={styles.history}>
        {events.map((event) => {
          const text = `${event.type}:x:${event.point.x},y:${event.point.y}`;
          return (
            <Readout
              key={event.n}
              id={`touch-event-${event.n}`}
              label={text}
              value={text}
              style={[styles.chip, event.type === 'down' ? styles.down : styles.up]}
              textStyle={styles.chipText}
            />
          );
        })}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  panel: {
    margin: 16,
    padding: 16,
    gap: 6,
    borderRadius: 12,
    alignItems: 'center',
    backgroundColor: colours.panel,
  },
  title: { fontSize: 20, fontWeight: '700' },
  history: {
    position: 'absolute',
    left: 16,
    right: 16,
    bottom: 32,
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 4,
  },
  chip: { paddingHorizontal: 6, paddingVertical: 2, borderRadius: 8 },
  down: { backgroundColor: '#FFD6D6' },
  up: { backgroundColor: '#D4F5DC' },
  chipText: { fontSize: 11, fontFamily: Platform.select({ ios: 'Menlo', default: 'monospace' }) },
});
