/**
 * Toast helper.
 */
import { promptAction } from '@kit.ArkUI';

export class Toast {
  static show(message: string): void {
    promptAction.showToast({ message: message, duration: 2000 });
  }
}