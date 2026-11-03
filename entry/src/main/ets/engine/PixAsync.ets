/**
 * 主线程逐像素处理时的让步工具（行分块之间调用，保持 UI 可响应）。
 */

export function yieldUI(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, 1);
  });
}
