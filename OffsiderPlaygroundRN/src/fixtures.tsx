import { type ReactNode, useEffect, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  type AccessibilityRole,
  type AccessibilityState,
  Animated,
  BackHandler,
  Easing,
  type GestureResponderEvent,
  Platform,
  Pressable,
  type StyleProp,
  StyleSheet,
  Text,
  type TextStyle,
  useWindowDimensions,
  View,
  type ViewStyle,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { markerId, routeInfo, type RouteId, useNavigation } from './navigation';

export type Point = { x: number; y: number };

export function pagePoint(event: GestureResponderEvent): Point {
  return { x: Math.round(event.nativeEvent.pageX), y: Math.round(event.nativeEvent.pageY) };
}

export function formatPoint(point: Point): string {
  return `(${point.x}, ${point.y})`;
}

export function fixtureLog(id: string, detail: string) {
  console.log(`OffsiderFixture ${id}: ${detail}`);
}

/** Keeps a fixture web view on its inline page, so it never fetches anything. */
export function isLocalPage(request: { url: string }): boolean {
  return request.url.startsWith('about:');
}

export function hiddenFromAccessibility(hide: boolean) {
  return { accessibilityElementsHidden: hide, importantForAccessibility: hide ? 'no-hide-descendants' : 'auto' } as const;
}

let screenReader = false;
void AccessibilityInfo.isScreenReaderEnabled().then((enabled) => {
  screenReader = enabled;
});
AccessibilityInfo.addEventListener('screenReaderChanged', (enabled) => {
  screenReader = enabled;
});

/** What the system last reported, read without a render, as an app that checks it only inside handlers does. */
export function screenReaderOn(): boolean {
  return screenReader;
}

export function useScreenReader(): boolean {
  const [enabled, setEnabled] = useState(screenReader);
  useEffect(() => {
    void AccessibilityInfo.isScreenReaderEnabled().then(setEnabled);
    const subscription = AccessibilityInfo.addEventListener('screenReaderChanged', setEnabled);
    return () => subscription.remove();
  }, []);
  return enabled;
}

export function iosValue(text: string | undefined): { text: string } | undefined {
  return Platform.OS === 'ios' && text !== undefined ? { text } : undefined;
}

type ReadoutProps = {
  id: string;
  label: string;
  value?: string;
  role?: AccessibilityRole;
  style?: StyleProp<ViewStyle>;
  textStyle?: StyleProp<TextStyle>;
};

export function Readout({ id, label, value, role = 'text', style, textStyle }: ReadoutProps) {
  return (
    <View
      testID={id}
      accessible
      accessibilityRole={role}
      accessibilityLabel={label}
      accessibilityValue={iosValue(value)}
      style={style}
    >
      <Text importantForAccessibility="no" style={[styles.readoutText, textStyle]}>
        {label}
      </Text>
    </View>
  );
}

type TargetProps = {
  id: string;
  label: string;
  onPress?: () => void;
  onLongPress?: () => void;
  role?: AccessibilityRole;
  state?: AccessibilityState;
  hint?: string;
  disabled?: boolean;
  style?: StyleProp<ViewStyle>;
  textStyle?: StyleProp<TextStyle>;
  children?: ReactNode;
};

export function Target({
  id,
  label,
  onPress,
  onLongPress,
  role = 'button',
  state,
  hint,
  disabled,
  style,
  textStyle,
  children,
}: TargetProps) {
  return (
    <Pressable
      testID={id}
      accessibilityRole={role}
      accessibilityLabel={label}
      accessibilityState={disabled === undefined ? state : { ...state, disabled }}
      accessibilityHint={hint}
      disabled={disabled}
      onPress={onPress}
      onLongPress={onLongPress}
      style={({ pressed }) => [styles.target, pressed && styles.pressed, style]}
    >
      {children ?? (
        <Text importantForAccessibility="no" style={[styles.targetText, textStyle]}>
          {label}
        </Text>
      )}
    </Pressable>
  );
}

export function Note({ children, style }: { children: ReactNode; style?: StyleProp<TextStyle> }) {
  return (
    <Text accessible={false} aria-hidden style={[styles.note, style]}>
      {children}
    </Text>
  );
}

type HeaderMarkerProps = {
  id: string;
  title: string;
  style?: StyleProp<ViewStyle>;
  textStyle?: StyleProp<TextStyle>;
};

export function HeaderMarker({ id, title, style, textStyle }: HeaderMarkerProps) {
  return (
    <View testID={id} accessible accessibilityRole="header" accessibilityLabel={title} style={style}>
      <Text importantForAccessibility="no" style={[styles.headerTitle, textStyle]} numberOfLines={1}>
        {title}
      </Text>
    </View>
  );
}

export function BackButton({ onPress, label = 'Offsider Playground' }: { onPress?: () => void; label?: string }) {
  const { pop } = useNavigation();
  return (
    <Pressable
      testID="BackButton"
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress ?? pop}
      style={({ pressed }) => [styles.backButton, pressed && styles.pressed]}
    >
      <Text importantForAccessibility="no" style={styles.backChevron}>
        ‹
      </Text>
    </Pressable>
  );
}

type ScreenProps = {
  route: RouteId;
  headerRight?: ReactNode;
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
};

export function Screen({ route, headerRight, children, style }: ScreenProps) {
  const insets = useSafeAreaInsets();
  return (
    <View style={styles.screen}>
      <View style={[styles.header, { paddingTop: insets.top }]}>
        <BackButton />
        <HeaderMarker id={markerId(route)} title={routeInfo[route].title} style={styles.headerMarker} />
        <View style={styles.headerRight}>{headerRight}</View>
      </View>
      <View style={[styles.content, style]}>{children}</View>
    </View>
  );
}

type FullPageProps = {
  id: string;
  backId: string;
  titleId: string;
  title: string;
  onBack: () => void;
  children?: ReactNode;
};

export function FullPage({ id, backId, titleId, title, onBack, children }: FullPageProps) {
  const insets = useSafeAreaInsets();
  return (
    <View testID={id} style={styles.fullPage}>
      <View style={[styles.header, { paddingTop: insets.top }]}>
        <Target
          id={backId}
          label="Back"
          onPress={onBack}
          style={styles.fullPageBack}
          textStyle={styles.fullPageBackText}
        />
        <HeaderMarker id={titleId} title={title} style={styles.headerMarker} />
        <View style={styles.fullPageSpacer} />
      </View>
      {children}
    </View>
  );
}

export type SlideKind = 'left' | 'up';

type SlidePageProps = {
  kind: SlideKind;
  open: boolean;
  top: boolean;
  onClosed: () => void;
  children: ReactNode;
};

/** A page of a JS stack: it slides in on the native driver over pages that stay mounted, and hides those only for a screen reader. */
export function SlidePage({ kind, open, top, onClosed, children }: SlidePageProps) {
  const { width, height } = useWindowDimensions();
  const reader = useScreenReader();
  const shown = useRef(new Animated.Value(0)).current;
  const closed = useRef(onClosed);
  closed.current = onClosed;

  useEffect(() => {
    const toValue = open ? 1 : 0;
    const animation =
      kind === 'up'
        ? Animated.spring(shown, { toValue, bounciness: 4, speed: 40, useNativeDriver: true })
        : Animated.timing(shown, { toValue, duration: 200, easing: Easing.inOut(Easing.sin), useNativeDriver: true });
    animation.start(({ finished }) => {
      if (finished && !open) {
        closed.current();
      }
    });
  }, [kind, open, shown]);

  const transform =
    kind === 'up'
      ? [{ translateY: shown.interpolate({ inputRange: [0, 1], outputRange: [height + 10, 0] }) }]
      : [{ translateX: shown.interpolate({ inputRange: [0, 1], outputRange: [width + 30, 0] }) }];

  return (
    <Animated.View {...hiddenFromAccessibility(reader && !top)} style={[StyleSheet.absoluteFill, { transform }]}>
      {children}
    </Animated.View>
  );
}

export function useHardwareBack(active: boolean, onBack: () => void) {
  useEffect(() => {
    if (!active) {
      return undefined;
    }
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
      onBack();
      return true;
    });
    return () => subscription.remove();
  }, [active, onBack]);
}

export const colours = {
  background: '#FFFFFF',
  panel: '#F2F2F7',
  accent: '#007AFF',
  text: '#1C1C1E',
  secondary: '#6C6C70',
  separator: '#D1D1D6',
};

const styles = StyleSheet.create({
  readoutText: { fontSize: 17, color: colours.text },
  target: {
    minHeight: 44,
    paddingHorizontal: 16,
    borderRadius: 10,
    backgroundColor: colours.accent,
    alignItems: 'center',
    justifyContent: 'center',
  },
  pressed: { opacity: 0.6 },
  targetText: { fontSize: 17, fontWeight: '600', color: '#FFFFFF' },
  note: { fontSize: 15, color: colours.secondary },
  headerTitle: { fontSize: 17, fontWeight: '600', color: colours.text, textAlign: 'center' },
  backButton: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
  backChevron: { fontSize: 34, lineHeight: 38, color: colours.accent },
  screen: { flex: 1, backgroundColor: colours.background },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 8,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colours.separator,
  },
  headerMarker: { flex: 1, marginHorizontal: 8 },
  headerRight: { minWidth: 44, alignItems: 'flex-end' },
  content: { flex: 1 },
  fullPage: { ...StyleSheet.absoluteFill, backgroundColor: colours.background },
  fullPageBack: { width: 72, height: 44, paddingHorizontal: 8, backgroundColor: 'transparent' },
  fullPageBackText: { color: colours.accent },
  fullPageSpacer: { width: 72 },
});
