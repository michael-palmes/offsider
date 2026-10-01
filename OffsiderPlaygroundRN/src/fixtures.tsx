import type { ReactNode } from 'react';
import {
  type AccessibilityRole,
  type AccessibilityState,
  type GestureResponderEvent,
  Platform,
  Pressable,
  type StyleProp,
  StyleSheet,
  Text,
  type TextStyle,
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
  style,
  textStyle,
  children,
}: TargetProps) {
  return (
    <Pressable
      testID={id}
      accessibilityRole={role}
      accessibilityLabel={label}
      accessibilityState={state}
      accessibilityHint={hint}
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
});
