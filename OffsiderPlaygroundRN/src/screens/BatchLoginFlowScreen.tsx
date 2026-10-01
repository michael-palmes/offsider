import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, StyleSheet, TextInput, View } from 'react-native';

import { colours, Note, Readout, Screen, Target } from '../fixtures';

type Stage = 'Email' | 'Password' | 'Loading' | 'Dashboard' | 'Settings';

const signInDelayMs = 2500;

const fieldProps = {
  autoFocus: true,
  autoCorrect: false,
  autoCapitalize: 'none',
  spellCheck: false,
  autoComplete: 'off',
  smartInsertDelete: false,
} as const;

export function BatchLoginFlowScreen() {
  const [stage, setStage] = useState<Stage>('Email');
  const [email, setEmail] = useState('');
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timer.current) {
        clearTimeout(timer.current);
      }
    },
    [],
  );

  const signIn = () => {
    setStage('Loading');
    timer.current = setTimeout(() => {
      timer.current = null;
      setStage('Dashboard');
    }, signInDelayMs);
  };

  return (
    <Screen route="batch-login-flow" style={styles.content}>
      <Readout id="batch-login-title" label="Fake Login Flow" textStyle={styles.title} />
      <Readout id="batch-login-current-screen" label={`Current Screen: ${stage}`} value={stage} />

      {stage === 'Email' && (
        <>
          <Note>Email</Note>
          <TextInput
            testID="batch-login-email-field"
            keyboardType="email-address"
            onChangeText={setEmail}
            style={styles.field}
            {...fieldProps}
          />
          <Target id="batch-login-continue" label="Continue" onPress={() => setStage('Password')} />
        </>
      )}

      {stage === 'Password' && (
        <>
          <Note>Password</Note>
          <TextInput
            testID="batch-login-password-field"
            secureTextEntry
            style={styles.field}
            {...fieldProps}
          />
          <Target id="batch-login-sign-in" label="Sign In" onPress={signIn} />
        </>
      )}

      {stage === 'Loading' && (
        <View style={styles.loading}>
          <ActivityIndicator testID="batch-login-loading-indicator" size="large" />
          <Note>Signing in…</Note>
          <Note>Please wait</Note>
        </View>
      )}

      {stage === 'Dashboard' && (
        <>
          <Readout id="batch-login-welcome" label={`Welcome, ${email || 'User'}`} />
          <Target id="batch-login-open-settings" label="Open Settings" onPress={() => setStage('Settings')} />
        </>
      )}

      {stage === 'Settings' && (
        <>
          <Readout id="batch-login-settings-opened" label="Settings Opened" textStyle={styles.heading} />
          <Target
            id="batch-login-toggle-preference"
            label="Toggle Preference"
            onPress={() => {}}
            style={styles.secondary}
            textStyle={styles.secondaryText}
          />
        </>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 12, alignItems: 'stretch' },
  title: { fontSize: 20, fontWeight: '700', textAlign: 'center' },
  heading: { fontWeight: '600' },
  field: {
    height: 44,
    paddingHorizontal: 12,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: colours.separator,
    fontSize: 17,
    color: colours.text,
  },
  loading: { alignItems: 'center', gap: 8, paddingVertical: 16 },
  secondary: { backgroundColor: colours.panel },
  secondaryText: { color: colours.accent },
});
