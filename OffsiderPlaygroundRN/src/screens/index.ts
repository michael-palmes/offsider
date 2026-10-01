import type { ComponentType } from 'react';

import type { RouteId } from '../navigation';
import { AlertTestScreen } from './AlertTestScreen';
import { BatchLoginFlowScreen } from './BatchLoginFlowScreen';
import { BatchTestScreen } from './BatchTestScreen';
import { ButtonTestScreen } from './ButtonTestScreen';
import { ContextMenuTestScreen } from './ContextMenuTestScreen';
import { GesturePresetsScreen } from './GesturePresetsScreen';
import { KeyPressScreen } from './KeyPressScreen';
import { KeySequenceScreen } from './KeySequenceScreen';
import { LongScrollTestScreen } from './LongScrollTestScreen';
import { ModalNavigationTestScreen } from './ModalNavigationTestScreen';
import { SearchableTestScreen } from './SearchableTestScreen';
import { SheetTestScreen } from './SheetTestScreen';
import { SliderValueTestScreen } from './SliderValueTestScreen';
import { SwipeTestScreen } from './SwipeTestScreen';
import { SwitchTestScreen } from './SwitchTestScreen';
import { TabViewTestScreen } from './TabViewTestScreen';
import { TapTestScreen } from './TapTestScreen';
import { TextInputScreen } from './TextInputScreen';
import { ToolbarPickerTestScreen } from './ToolbarPickerTestScreen';
import { TouchControlScreen } from './TouchControlScreen';

export const screens: Record<RouteId, ComponentType> = {
  'tap-test': TapTestScreen,
  'touch-control': TouchControlScreen,
  'swipe-test': SwipeTestScreen,
  'gesture-presets': GesturePresetsScreen,
  'switch-test': SwitchTestScreen,
  'tab-view-test': TabViewTestScreen,
  'text-input': TextInputScreen,
  'key-press': KeyPressScreen,
  'key-sequence': KeySequenceScreen,
  'button-test': ButtonTestScreen,
  'batch-test': BatchTestScreen,
  'batch-login-flow': BatchLoginFlowScreen,
  'slider-value-test': SliderValueTestScreen,
  'searchable-test': SearchableTestScreen,
  'toolbar-picker-test': ToolbarPickerTestScreen,
  'alert-test': AlertTestScreen,
  'sheet-test': SheetTestScreen,
  'context-menu-test': ContextMenuTestScreen,
  'modal-navigation-test': ModalNavigationTestScreen,
  'long-scroll-test': LongScrollTestScreen,
};
