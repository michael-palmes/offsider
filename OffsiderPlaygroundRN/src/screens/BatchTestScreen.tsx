import { useEffect, useRef, useState } from 'react';
import { StyleSheet } from 'react-native';

import { colours, Readout, Screen, Target } from '../fixtures';

const delayedTargetMs = 3000;

export function BatchTestScreen() {
  const [state, setState] = useState('Initial');
  const [showStateTarget, setShowStateTarget] = useState(false);
  const [showDelayedTarget, setShowDelayedTarget] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timer.current) {
        clearTimeout(timer.current);
      }
    },
    [],
  );

  const triggerDelayed = () => {
    setState('Waiting for delayed target');
    setShowDelayedTarget(false);
    if (timer.current) {
      clearTimeout(timer.current);
    }
    timer.current = setTimeout(() => {
      timer.current = null;
      setShowDelayedTarget(true);
      setState('Delayed target visible');
    }, delayedTargetMs);
  };

  return (
    <Screen route="batch-test" style={styles.content}>
      <Readout id="batch-test-title" label="Batch Playground" textStyle={styles.title} />
      <Readout id="batch-current-state" label={`Current State: ${state}`} value={state} textStyle={styles.state} />
      <Target
        id="batch-state-change-trigger"
        label="Trigger State Change"
        onPress={() => {
          setState('State changed');
          setShowStateTarget(true);
        }}
      />
      {showStateTarget && (
        <Target
          id="batch-state-target"
          label="State Target"
          onPress={() => setState('State target tapped')}
          style={styles.secondary}
          textStyle={styles.secondaryText}
        />
      )}
      <Target id="batch-delayed-trigger" label="Trigger Delayed Element" onPress={triggerDelayed} />
      {showDelayedTarget && (
        <Target
          id="batch-delayed-target"
          label="Delayed Target"
          onPress={() => setState('Delayed target tapped')}
          style={styles.secondary}
          textStyle={styles.secondaryText}
        />
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 16, alignItems: 'center' },
  title: { fontSize: 20, fontWeight: '700' },
  state: { fontWeight: '600' },
  secondary: { backgroundColor: colours.panel },
  secondaryText: { color: colours.accent },
});
