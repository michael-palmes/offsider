import { createContext, useContext } from 'react';

type RouteInfo = { section: string; title: string; menuTitle: string; subtitle: string };

export const routeInfo = {
  'tap-test': {
    section: 'Touch & Gestures',
    title: 'Tap Test',
    menuTitle: 'Tap Test',
    subtitle: 'Displays coordinates of CLI taps',
  },
  'touch-control': {
    section: 'Touch & Gestures',
    title: 'Touch Control',
    menuTitle: 'Touch Control',
    subtitle: 'Touch down/up events',
  },
  'swipe-test': {
    section: 'Touch & Gestures',
    title: 'Swipe Test',
    menuTitle: 'Swipe Test',
    subtitle: 'Shows CLI swipe paths',
  },
  'gesture-presets': {
    section: 'Touch & Gestures',
    title: 'Gesture Presets',
    menuTitle: 'Gesture Presets',
    subtitle: 'Drag gesture classification',
  },
  'switch-test': {
    section: 'Touch & Gestures',
    title: 'Switch Test',
    menuTitle: 'Switch Test',
    subtitle: 'Native and custom switch controls',
  },
  'tab-view-test': {
    section: 'Touch & Gestures',
    title: 'TabView Test',
    menuTitle: 'TabView Test',
    subtitle: 'Tab switching',
  },
  'text-input': {
    section: 'Input & Text',
    title: 'Text Input',
    menuTitle: 'Text Input',
    subtitle: 'Text typed by CLI commands',
  },
  'key-press': {
    section: 'Input & Text',
    title: 'Key Press',
    menuTitle: 'Key Press',
    subtitle: 'Detects CLI key events',
  },
  'key-sequence': {
    section: 'Input & Text',
    title: 'Key Sequence',
    menuTitle: 'Key Sequence',
    subtitle: 'Detects CLI key sequences',
  },
  'button-test': {
    section: 'Hardware',
    title: 'Button Test',
    menuTitle: 'Button Test',
    subtitle: 'Hardware button press detection',
  },
  'batch-test': {
    section: 'Batch',
    title: 'Batch Test',
    menuTitle: 'Batch Test',
    subtitle: 'State changes + delayed element appearance',
  },
  'batch-login-flow': {
    section: 'Batch',
    title: 'Batch Login',
    menuTitle: 'Batch Login Flow',
    subtitle: 'Multi-step login + loading + post-login action',
  },
  'slider-value-test': {
    section: 'Accessibility',
    title: 'Slider Value',
    menuTitle: 'Slider Value Test',
    subtitle: 'Numeric value with selector tap',
  },
  'searchable-test': {
    section: 'Accessibility',
    title: 'Searchable Test',
    menuTitle: 'Searchable Test',
    subtitle: 'Search field targeting',
  },
  'toolbar-picker-test': {
    section: 'Accessibility',
    title: 'Toolbar Picker',
    menuTitle: 'Toolbar Picker Test',
    subtitle: 'Header segmented picker targeting',
  },
  'alert-test': {
    section: 'Presentation',
    title: 'Alert Test',
    menuTitle: 'Alert Test',
    subtitle: 'Alert presentation and button targeting',
  },
  'sheet-test': {
    section: 'Presentation',
    title: 'Sheet Test',
    menuTitle: 'Sheet Test',
    subtitle: 'Sheet presentation and actions',
  },
  'context-menu-test': {
    section: 'Presentation',
    title: 'Context Menu',
    menuTitle: 'Context Menu Test',
    subtitle: 'Long press menu targeting',
  },
  'modal-navigation-test': {
    section: 'Presentation',
    title: 'Modal Navigation',
    menuTitle: 'Modal Navigation Test',
    subtitle: 'Modal route and nested navigation',
  },
  'long-scroll-test': {
    section: 'Presentation',
    title: 'Long Scroll',
    menuTitle: 'Long Scroll Test',
    subtitle: 'Dedicated long scroll coverage',
  },
} satisfies Record<string, RouteInfo>;

export type RouteId = keyof typeof routeInfo;

export const routeIds = Object.keys(routeInfo) as RouteId[];

export function isRouteId(value: unknown): value is RouteId {
  return typeof value === 'string' && Object.prototype.hasOwnProperty.call(routeInfo, value);
}

export function markerId(route: RouteId): string {
  return route === 'batch-login-flow' ? 'batch-login-screen' : `${route}-screen`;
}

export function routeFromUrl(url: string | null): RouteId | null {
  const match = url?.match(/^offsiderplaygroundrn:\/\/screen\/([a-z-]+)\/?$/);
  return match && isRouteId(match[1]) ? match[1] : null;
}

export type Navigation = { push: (route: RouteId) => void; pop: () => void };

export const NavigationContext = createContext<Navigation>({ push: () => {}, pop: () => {} });

export function useNavigation(): Navigation {
  return useContext(NavigationContext);
}
