import { useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { BackButton, colours, fixtureLog, FullPage, HeaderMarker, Readout, Target, useHardwareBack } from '../fixtures';

const steps = ['Choose Amount', 'Check Details', 'Send Request'] as const;

// What may lie over the confirm button: nothing, a scrim that dismisses, a veil that swallows the touch, a sheet over a scrim, a wrapper with a control.
type Cover = 'none' | 'scrim' | 'veil' | 'sheet' | 'control';

export function OwnCoverTestScreen() {
  const insets = useSafeAreaInsets();
  const [step, setStep] = useState(0);
  const [pressed, setPressed] = useState('None');
  const [cover, setCover] = useState<Cover>('none');
  const [pushed, setPushed] = useState(false);

  const press = (what: string) => {
    fixtureLog('own-cover-test', `pressed ${what}`);
    setPressed(what);
  };

  useHardwareBack(pushed, () => setPushed(false));

  const body = (
    <View style={styles.fill}>
      <View style={[styles.header, { paddingTop: insets.top }]}>
        <BackButton />
        <Target id="own-cover-drawer" label="Open Drawer" onPress={() => press('Open Drawer')} style={styles.menu} textStyle={styles.menuText} />
        <HeaderMarker id="own-cover-test-screen" title="Own Cover" style={styles.title} />
        {/* A header slot drawn after the menu button, wider than it, that passes touches on. */}
        <View collapsable={false} importantForAccessibility="yes" pointerEvents="box-none" style={[styles.slot, { top: insets.top }]} />
      </View>
      <Readout id="own-cover-pressed" label={`Own Pressed: ${pressed}`} style={styles.row} />
      <HeaderMarker id="own-cover-step" title={steps[step]} style={styles.row} />
      <View style={styles.choices}>
        {(['scrim', 'veil', 'sheet', 'control'] as const).map((item) => (
          <Target key={item} id={`own-cover-show-${item}`} label={`Show ${item}`} onPress={() => setCover(item)} style={styles.choice} textStyle={styles.choiceText} />
        ))}
        <Target id="own-cover-push" label="Push Screen" onPress={() => setPushed(true)} style={styles.choice} textStyle={styles.choiceText} />
      </View>
      <View style={styles.fill} />
      <View style={[styles.footer, { paddingBottom: insets.bottom + 8 }]}>
        <Target
          id="own-cover-confirm"
          label={step === steps.length - 1 ? 'Send' : 'Continue'}
          onPress={() => {
            press(step === steps.length - 1 ? 'Send' : `Step ${step + 2}`);
            setStep((current) => Math.min(current + 1, steps.length - 1));
          }}
        />
      </View>
    </View>
  );

  return (
    <View style={styles.fill}>
      {pushed ? (
        <FullPage id="own-cover-under" backId="own-cover-under-back" titleId="own-cover-under-title" title="Under Page" onBack={() => setPushed(false)} />
      ) : null}
      <View style={pushed ? styles.pushedScreen : styles.fill}>
        {body}
        {/* The step's own full-screen wrappers, drawn after its content and passing touches on, as a layout host leaves them. */}
        <View collapsable={false} importantForAccessibility="yes" pointerEvents="box-none" style={StyleSheet.absoluteFill}>
          <View collapsable={false} importantForAccessibility="yes" pointerEvents="box-none" style={StyleSheet.absoluteFill} />
        </View>
      </View>
      {cover === 'scrim' && (
        <Pressable testID="own-cover-scrim" onPress={() => { press('Scrim'); setCover('none'); }} style={[StyleSheet.absoluteFill, styles.dim]} />
      )}
      {cover === 'veil' && <View collapsable={false} importantForAccessibility="yes" style={[StyleSheet.absoluteFill, styles.opaque]} />}
      {cover === 'sheet' && (
        <View collapsable={false} importantForAccessibility="yes" style={[StyleSheet.absoluteFill, styles.dim]}>
          <View style={styles.sheet}>
            <HeaderMarker id="own-cover-sheet-title" title="Sheet Title" />
            <Target id="own-cover-sheet-close" label="Close Sheet" onPress={() => setCover('none')} />
          </View>
        </View>
      )}
      {cover === 'control' && (
        <View collapsable={false} importantForAccessibility="yes" pointerEvents="box-none" style={StyleSheet.absoluteFill}>
          <Target id="own-cover-over-control" label="Dismiss" onPress={() => { press('Dismiss'); setCover('none'); }} style={[styles.overControl, { bottom: insets.bottom + 8 }]} />
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  pushedScreen: { ...StyleSheet.absoluteFill, backgroundColor: colours.background },
  header: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 8 },
  menu: { width: 96, height: 44, paddingHorizontal: 4 },
  menuText: { fontSize: 13 },
  title: { flex: 1 },
  slot: { position: 'absolute', left: 0, width: 150, height: 70 },
  row: { padding: 12 },
  choices: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, paddingHorizontal: 12 },
  choice: { paddingHorizontal: 8 },
  choiceText: { fontSize: 13 },
  footer: { paddingHorizontal: 16, paddingTop: 8 },
  dim: { backgroundColor: 'rgba(0,0,0,0.4)' },
  opaque: { backgroundColor: colours.panel },
  sheet: { position: 'absolute', left: 0, right: 0, top: 0, padding: 24, gap: 12, backgroundColor: colours.background },
  overControl: { position: 'absolute', left: 16, right: 16 },
});
