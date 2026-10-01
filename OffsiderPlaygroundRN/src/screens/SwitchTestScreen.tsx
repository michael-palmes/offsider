import { useState } from 'react';
import { StyleSheet, Switch, View } from 'react-native';

import { colours, Note, Readout, Screen, Target } from '../fixtures';

function onOff(value: boolean): string {
  return value ? 'On' : 'Off';
}

export function SwitchTestScreen() {
  const [nativeOn, setNativeOn] = useState(false);
  const [customOn, setCustomOn] = useState(false);

  return (
    <Screen route="switch-test" style={styles.content}>
      <Readout id="switch-test-title" label="Switch Playground" textStyle={styles.title} />

      <View style={styles.group}>
        <View style={styles.row}>
          <Note style={styles.rowLabel}>SwiftUI Weather Alerts</Note>
          <Switch
            testID="swiftui-weather-alerts-switch"
            accessibilityLabel="SwiftUI Weather Alerts"
            value={nativeOn}
            onValueChange={setNativeOn}
          />
        </View>
        <Readout
          id="swiftui-weather-alerts-state"
          label={`SwiftUI Weather Alerts: ${onOff(nativeOn)}`}
          value={onOff(nativeOn)}
        />
      </View>

      <View style={styles.group}>
        <View style={styles.row}>
          <Note style={styles.rowLabel}>UIKit Weather Alerts</Note>
          <Target
            id="uikit-weather-alerts-switch"
            label="UIKit Weather Alerts"
            role="switch"
            state={{ checked: customOn }}
            onPress={() => setCustomOn((current) => !current)}
            style={[styles.track, customOn && styles.trackOn]}
          >
            <View style={styles.thumb} />
          </Target>
        </View>
        <Readout
          id="uikit-weather-alerts-state"
          label={`UIKit Weather Alerts: ${onOff(customOn)}`}
          value={onOff(customOn)}
        />
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 24 },
  title: { fontSize: 20, fontWeight: '700' },
  group: { gap: 8 },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  rowLabel: { fontSize: 17, color: colours.text },
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
});
