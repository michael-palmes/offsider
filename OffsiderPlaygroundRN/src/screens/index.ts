import type { ComponentType } from 'react';

import type { RouteId } from '../navigation';
import { AlertTestScreen } from './AlertTestScreen';
import { BatchLoginFlowScreen } from './BatchLoginFlowScreen';
import { BatchTestScreen } from './BatchTestScreen';
import { ButtonTestScreen } from './ButtonTestScreen';
import { ChoiceTestScreen } from './ChoiceTestScreen';
import { ContextMenuTestScreen } from './ContextMenuTestScreen';
import { EnvironmentTestScreen } from './EnvironmentTestScreen';
import { GesturePresetsScreen } from './GesturePresetsScreen';
import { KeyPressScreen } from './KeyPressScreen';
import { KeySequenceScreen } from './KeySequenceScreen';
import { LongScrollTestScreen } from './LongScrollTestScreen';
import { ModalNavigationTestScreen } from './ModalNavigationTestScreen';
import { OverlayTestScreen } from './OverlayTestScreen';
import { ParkedSheetTestScreen } from './ParkedSheetTestScreen';
import { PermissionStateTestScreen } from './PermissionStateTestScreen';
import { RowsTestScreen } from './RowsTestScreen';
import { SearchableTestScreen } from './SearchableTestScreen';
import { SheetTestScreen } from './SheetTestScreen';
import { SliderValueTestScreen } from './SliderValueTestScreen';
import { StackTestScreen } from './StackTestScreen';
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
  'choice-test': ChoiceTestScreen,
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
  'parked-sheet-test': ParkedSheetTestScreen,
  'stack-test': StackTestScreen,
  'overlay-test': OverlayTestScreen,
  'rows-test': RowsTestScreen,
  'environment-test': EnvironmentTestScreen,
  'permission-state': PermissionStateTestScreen,
};
