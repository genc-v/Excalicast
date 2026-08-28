// WKWebView <-> native (Swift) bridge. Drop-in replacement for the bits of @tauri-apps/api the
// app used: `invoke(cmd, args)` and `listen(event, cb)`.
//
// - invoke: calls a WKScriptMessageHandlerWithReply named "invoke"; postMessage returns a Promise
//   that resolves with the native reply.
// - events: the native side calls `window.__excaliEmit(event, payload)` via evaluateJavaScript.

type Handler = (payload?: unknown) => void;

const listeners: Record<string, Set<Handler>> = {};

(window as unknown as { __excaliEmit: (e: string, p?: unknown) => void }).__excaliEmit = (
  event,
  payload,
) => {
  listeners[event]?.forEach((fn) => {
    try {
      fn(payload);
    } catch (e) {
      console.error(`excali listener for "${event}" threw`, e);
    }
  });
};

// Trackpad pinch arrives natively as a magnify gesture (not a wheel event), so the Swift shell
// forwards it here and we synthesize the ctrl+wheel event Excalidraw zooms on, at the cursor.
(
  window as unknown as {
    __excaliPinch: (x: number, y: number, deltaY: number) => void;
  }
).__excaliPinch = (x, y, deltaY) => {
  const el = document.elementFromPoint(x, y) ?? document.body;
  el?.dispatchEvent(
    new WheelEvent("wheel", {
      deltaY,
      clientX: x,
      clientY: y,
      ctrlKey: true,
      bubbles: true,
      cancelable: true,
    }),
  );
};

interface ReplyHandler {
  postMessage: (msg: unknown) => Promise<unknown>;
}

function bridge(): ReplyHandler | null {
  const w = window as unknown as {
    webkit?: { messageHandlers?: { invoke?: ReplyHandler } };
  };
  return w.webkit?.messageHandlers?.invoke ?? null;
}

export function invoke<T = unknown>(
  cmd: string,
  args?: Record<string, unknown>,
): Promise<T> {
  const handler = bridge();
  if (!handler) {
    return Promise.reject(new Error("excali native bridge unavailable"));
  }
  return handler.postMessage({ cmd, args: args ?? {} }) as Promise<T>;
}

export type UnlistenFn = () => void;

export function listen(event: string, cb: Handler): Promise<UnlistenFn> {
  (listeners[event] ??= new Set()).add(cb);
  return Promise.resolve(() => {
    listeners[event]?.delete(cb);
  });
}
