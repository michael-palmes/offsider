import { useEffect, useRef, useState } from 'react';
import { InputAccessoryView, Keyboard, Platform, ScrollView, StyleSheet, TextInput, View } from 'react-native';

import { colours, Note, Readout, Screen, Target } from '../fixtures';

type Session = 'Signed out' | 'Signing in' | 'Signed in' | 'Refused';

const signInDelayMs = 800;
const accessoryId = 'user-switch-test-accessory';

const fieldProps = {
  autoCorrect: false,
  autoCapitalize: 'none',
  spellCheck: false,
  autoComplete: 'off',
  textContentType: 'none',
  importantForAutofill: 'no',
  smartInsertDelete: false,
} as const;

export function UserSwitchTestScreen() {
  const [session, setSession] = useState<Session>('Signed out');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [current, setCurrent] = useState('');
  const [signIns, setSignIns] = useState(0);
  // Footer mode pins submit under a scroll view that keeps the keyboard up on a tap, so only the keyboard's own Done or Back clears it.
  const [footer, setFooter] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timer.current) {
        clearTimeout(timer.current);
      }
    },
    [],
  );

  const submit = () => {
    const name = email.trim();
    if (name.length === 0 || password.length === 0) {
      return;
    }
    // A `kept` account is turned away with the form left as it is, as a server's refusal leaves it.
    if (name.toLowerCase().startsWith('kept')) {
      timer.current = setTimeout(() => {
        timer.current = null;
        setSession('Refused');
      }, signInDelayMs);
      return;
    }
    setEmail('');
    setPassword('');
    setSession('Signing in');
    timer.current = setTimeout(() => {
      timer.current = null;
      if (name.toLowerCase().startsWith('refused')) {
        setSession('Refused');
        return;
      }
      setCurrent(name);
      setSignIns((count) => count + 1);
      setSession('Signed in');
    }, signInDelayMs);
  };

  const signOut = () => {
    setCurrent('');
    setSession('Signed out');
  };

  const showForm = session === 'Signed out' || session === 'Refused';

  const fields = (
    <>
      <Note>Email</Note>
      <TextInput
        testID="user-switch-test-email"
        accessibilityLabel="Email"
        keyboardType="email-address"
        onChangeText={setEmail}
        inputAccessoryViewID={footer ? accessoryId : undefined}
        style={styles.field}
        {...fieldProps}
      />
      <Note>Password</Note>
      <TextInput
        testID="user-switch-test-password"
        accessibilityLabel="Password"
        secureTextEntry
        onChangeText={setPassword}
        onSubmitEditing={footer ? submit : undefined}
        inputAccessoryViewID={footer ? accessoryId : undefined}
        style={styles.field}
        {...fieldProps}
      />
    </>
  );
  const submitButton = <Target id="user-switch-test-submit" label="Sign in" onPress={submit} />;

  return (
    <Screen route="user-switch-test" style={styles.content}>
      <Readout id="user-switch-test-state" label={`Session: ${session}`} value={session} />
      <Readout id="user-switch-test-sign-ins" label={`Sign-ins: ${signIns}`} value={String(signIns)} />

      {session === 'Refused' && <Readout id="user-switch-test-error" label="This account cannot sign in" />}

      {showForm && (
        <Target
          id="user-switch-test-footer"
          label={footer ? 'Unpin submit' : 'Pin submit to the bottom'}
          onPress={() => setFooter((pinned) => !pinned)}
          style={styles.secondary}
          textStyle={styles.secondaryText}
        />
      )}

      {showForm && !footer && (
        <>
          {fields}
          {submitButton}
        </>
      )}

      {showForm && footer && (
        <>
          <ScrollView style={styles.scroll} contentContainerStyle={styles.scrollContent} keyboardShouldPersistTaps="always">
            {fields}
          </ScrollView>
          <View style={styles.footer}>{submitButton}</View>
          {Platform.OS === 'ios' && (
            <InputAccessoryView nativeID={accessoryId}>
              <View style={styles.accessory}>
                <Target id="user-switch-test-done" label="Done" onPress={Keyboard.dismiss} style={styles.done} textStyle={styles.secondaryText} />
              </View>
            </InputAccessoryView>
          )}
        </>
      )}

      {session === 'Signed in' && (
        <>
          <Readout id="user-switch-test-current" label={`Signed in as ${current}`} />
          <Target
            id="user-switch-test-sign-out"
            label="Sign out"
            onPress={signOut}
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
  field: {
    height: 44,
    paddingHorizontal: 12,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: colours.separator,
    fontSize: 17,
    color: colours.text,
  },
  scroll: { flex: 1 },
  scrollContent: { gap: 12 },
  footer: { paddingTop: 8 },
  accessory: { flexDirection: 'row', justifyContent: 'flex-end', backgroundColor: colours.panel, paddingHorizontal: 12, paddingVertical: 4 },
  done: { backgroundColor: colours.panel, paddingHorizontal: 12 },
  secondary: { backgroundColor: colours.panel },
  secondaryText: { color: colours.accent },
});
