import { useEffect, useRef, useState } from 'react';
import { type GestureResponderEvent, StyleSheet, View } from 'react-native';

import { colours, Note, type Point, Readout, Screen } from '../fixtures';

const holdMs = 500;
const slop = 10;
const tileSize = 80;
const zoneA = { x: 40, y: 40, width: 200, height: 160 };
const zoneB = { x: 40, y: 320, width: 200, height: 160 };
const home = { x: zoneA.x + (zoneA.width - tileSize) / 2, y: zoneA.y + (zoneA.height - tileSize) / 2 };

type Zone = typeof zoneA;

function inside(point: Point, zone: Zone): boolean {
  return point.x >= zone.x && point.x <= zone.x + zone.width && point.y >= zone.y && point.y <= zone.y + zone.height;
}

function frame(zone: Zone) {
  return { left: zone.x, top: zone.y, width: zone.width, height: zone.height };
}

export function HoldDragScreen() {
  const [tile, setTile] = useState<Point>(home);
  const [zone, setZone] = useState('A');
  const [armed, setArmed] = useState(false);
  const origin = useRef<Point>({ x: 0, y: 0 });
  const start = useRef<Point | null>(null);
  const grab = useRef<Point>({ x: 0, y: 0 });
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const isArmed = useRef(false);

  const cancel = () => {
    if (timer.current) {
      clearTimeout(timer.current);
      timer.current = null;
    }
  };
  useEffect(() => cancel, []);

  const local = (event: GestureResponderEvent): Point => ({
    x: event.nativeEvent.pageX - origin.current.x,
    y: event.nativeEvent.pageY - origin.current.y,
  });

  const onGrant = (event: GestureResponderEvent) => {
    origin.current = {
      x: event.nativeEvent.pageX - event.nativeEvent.locationX,
      y: event.nativeEvent.pageY - event.nativeEvent.locationY,
    };
    const point = local(event);
    start.current = point;
    isArmed.current = false;
    setArmed(false);
    cancel();
    const onTile = point.x >= tile.x && point.x <= tile.x + tileSize && point.y >= tile.y && point.y <= tile.y + tileSize;
    if (!onTile) {
      return;
    }
    grab.current = { x: point.x - tile.x, y: point.y - tile.y };
    timer.current = setTimeout(() => {
      timer.current = null;
      isArmed.current = true;
      setArmed(true);
    }, holdMs);
  };

  const onMove = (event: GestureResponderEvent) => {
    const point = local(event);
    if (!isArmed.current) {
      if (start.current && Math.hypot(point.x - start.current.x, point.y - start.current.y) >= slop) {
        cancel();
      }
      return;
    }
    setTile({ x: point.x - grab.current.x, y: point.y - grab.current.y });
  };

  const onEnd = (event: GestureResponderEvent) => {
    cancel();
    if (isArmed.current) {
      const point = local(event);
      const centre = { x: point.x - grab.current.x + tileSize / 2, y: point.y - grab.current.y + tileSize / 2 };
      if (inside(centre, zoneB)) {
        setZone('B');
        setTile({ x: zoneB.x + (zoneB.width - tileSize) / 2, y: zoneB.y + (zoneB.height - tileSize) / 2 });
      } else {
        setTile(zone === 'B' ? tile : home);
      }
    }
    isArmed.current = false;
    setArmed(false);
    start.current = null;
  };

  return (
    <Screen route="hold-drag">
      <View
        testID="hold-drag-area"
        style={styles.area}
        onStartShouldSetResponder={() => true}
        onResponderTerminationRequest={() => false}
        onResponderGrant={onGrant}
        onResponderMove={onMove}
        onResponderRelease={onEnd}
        onResponderTerminate={onEnd}
      >
        <View pointerEvents="none" testID="hold-drag-zone-a" accessible accessibilityLabel="Zone A" style={[styles.zone, frame(zoneA)]} />
        <View pointerEvents="none" testID="hold-drag-zone-b" accessible accessibilityLabel="Zone B" style={[styles.zone, frame(zoneB)]} />
        <View
          pointerEvents="none"
          testID="hold-drag-tile"
          accessible
          accessibilityLabel={armed ? 'Tile, lifted' : 'Tile'}
          style={[styles.tile, { left: tile.x, top: tile.y }, armed && styles.lifted]}
        />
      </View>
      <View style={styles.panel}>
        <Readout id="hold-drag-zone" label={`Zone: ${zone}`} value={zone} />
        <Note>Hold the tile for 0.5 s, then drag it to zone B</Note>
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  area: { height: 520 },
  zone: { position: 'absolute', borderRadius: 12, borderWidth: 2, borderColor: colours.separator, backgroundColor: colours.panel },
  tile: { position: 'absolute', width: tileSize, height: tileSize, borderRadius: 12, backgroundColor: colours.accent },
  lifted: { opacity: 0.6 },
  panel: { marginHorizontal: 16, gap: 8, alignItems: 'center' },
});
