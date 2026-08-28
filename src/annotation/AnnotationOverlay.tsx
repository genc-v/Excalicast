import { useEffect, useRef, useState } from "react";
import {
  Excalidraw,
  convertToExcalidrawElements,
  exportToBlob,
  serializeAsJSON,
  CaptureUpdateAction,
} from "@excalidraw/excalidraw";
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import { invoke, listen, type UnlistenFn } from "../bridge";

/** Mirror of the Rust `Capture` struct (serde camelCase). */
interface Capture {
  dataUrl: string;
  widthPx: number;
  heightPx: number;
  scaleFactor: number;
  logicalW: number;
  logicalH: number;
  looksBlack: boolean;
}

type Mode = "idle" | "frozen" | "whiteboard" | "file";

interface AppSettings {
  gridEnabled?: boolean;
  dark?: boolean; // system dark mode (reported by the native side)
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function blobToDataURL(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error);
    reader.onload = () => resolve(reader.result as string);
    reader.readAsDataURL(blob);
  });
}

// Canvas colors follow the system: dark = black canvas + white pen; light = white + dark pen.
// (The screenshot itself always renders faithfully.)
function canvasColors(s: AppSettings): { bg: string; stroke: string } {
  if (s.dark) return { bg: "#121212", stroke: "#ffffff" };
  return { bg: "#ffffff", stroke: "#1e1e1e" };
}

// Persist Excalidraw's tool defaults (color, stroke width, font, ...) across sessions/modes.
const PREFS_KEY = "excali-prefs";
const PREF_KEYS = [
  "currentItemStrokeColor",
  "currentItemBackgroundColor",
  "currentItemFillStyle",
  "currentItemStrokeWidth",
  "currentItemStrokeStyle",
  "currentItemRoughness",
  "currentItemOpacity",
  "currentItemFontFamily",
  "currentItemFontSize",
  "currentItemTextAlign",
  "currentItemStartArrowhead",
  "currentItemEndArrowhead",
  "currentItemRoundness",
  "currentItemArrowType",
] as const;

function savePrefs(appState: any) {
  try {
    const prefs: Record<string, unknown> = {};
    for (const k of PREF_KEYS) if (appState[k] !== undefined) prefs[k] = appState[k];
    localStorage.setItem(PREFS_KEY, JSON.stringify(prefs));
  } catch {
    /* ignore */
  }
}

function loadPrefs(): Record<string, unknown> | null {
  try {
    const raw = localStorage.getItem(PREFS_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

export default function AnnotationOverlay() {
  const apiRef = useRef<ExcalidrawImperativeAPI | null>(null);
  const bgRef = useRef<any>(null);
  const scaleFactorRef = useRef(1);
  const saveTimer = useRef<number | undefined>(undefined);
  const currentPathRef = useRef<string | null>(null); // autosave target for the open document
  const [mode, setMode] = useState<Mode>("idle");
  const [toast, setToast] = useState<string | null>(null);

  const modeRef = useRef(mode);
  modeRef.current = mode;

  const flashToast = (msg: string, ms = 2600) => {
    setToast(msg);
    window.setTimeout(() => setToast((t) => (t === msg ? null : t)), ms);
  };

  // Common appState: theme default stroke, overridden by persisted tool prefs, then canvas bg/grid.
  const sceneAppState = (bg: string, grid: boolean, stroke: string) => ({
    currentItemStrokeColor: stroke,
    ...(loadPrefs() ?? {}),
    viewBackgroundColor: bg,
    gridModeEnabled: grid,
    theme: "light" as any,
    scrollX: 0,
    scrollY: 0,
    zoom: { value: 1 as any },
  });

  // ---- Scene builders --------------------------------------------------------
  const buildFrozenScene = (cap: Capture, bg: string, grid: boolean, stroke: string) => {
    const api = apiRef.current;
    if (!api) return;
    const fileId = `snapshot-${Date.now()}`;
    api.addFiles([
      {
        id: fileId as any,
        mimeType: "image/png",
        dataURL: cap.dataUrl as any,
        created: Date.now(),
      } as any,
    ]);
    const elements = convertToExcalidrawElements([
      { type: "image", x: 0, y: 0, width: cap.logicalW, height: cap.logicalH, fileId: fileId as any } as any,
    ]).map((el) => ({ ...el, locked: true }));

    bgRef.current = elements[0];
    scaleFactorRef.current = cap.scaleFactor;
    api.updateScene({
      elements,
      appState: sceneAppState(bg, grid, stroke),
      captureUpdate: CaptureUpdateAction.NEVER,
    });
  };

  // ---- Autosave --------------------------------------------------------------
  const hasUserContent = (): boolean => {
    const api = apiRef.current;
    if (!api) return false;
    const els = api.getSceneElements();
    if (modeRef.current === "frozen") {
      const bgId = bgRef.current?.id;
      return els.some((e) => e.id !== bgId);
    }
    return els.length > 0;
  };

  const autosaveNow = async () => {
    const api = apiRef.current;
    if (!api || modeRef.current === "idle" || !hasUserContent()) return;
    const dataUrl = await flattenToDataURL();
    if (!dataUrl) return;
    const excalidraw = serializeAsJSON(
      api.getSceneElements(),
      api.getAppState(),
      api.getFiles(),
      "local",
    );
    try {
      if (currentPathRef.current) {
        await invoke("save_to_file", {
          path: currentPathRef.current,
          pngB64: dataUrl,
          excalidraw,
        });
      } else {
        currentPathRef.current = await invoke<string>("save_annotation", {
          pngB64: dataUrl,
          excalidraw,
        });
      }
    } catch {
      /* ignore autosave errors */
    }
  };

  // ---- Actions ---------------------------------------------------------------
  const startWhiteboard = async () => {
    if (modeRef.current === "whiteboard") {
      await dismiss();
      return;
    }
    const api = apiRef.current;
    if (!api) return;
    await autosaveNow();
    const settings = await invoke<AppSettings>("get_settings").catch(() => ({}) as AppSettings);
    const { bg, stroke } = canvasColors(settings);
    bgRef.current = null;
    scaleFactorRef.current = 1;
    currentPathRef.current = null;
    window.clearTimeout(saveTimer.current);
    modeRef.current = "whiteboard";
    api.updateScene({
      elements: [],
      appState: sceneAppState(bg, settings.gridEnabled ?? false, stroke),
      captureUpdate: CaptureUpdateAction.NEVER,
    });
    setMode("whiteboard");
    await invoke("show_overlay").catch(() => {});
  };

  const startFrozen = async () => {
    if (modeRef.current === "frozen") {
      await dismiss();
      return;
    }
    await autosaveNow();

    const granted = await invoke<boolean>("check_screen_permission").catch(() => true);
    if (!granted) {
      await invoke("request_screen_permission").catch(() => {});
      await invoke("open_screen_recording_settings").catch(() => {});
      flashToast("Enable Screen Recording for “Excalicast”, then quit and relaunch.", 7000);
      return;
    }

    await invoke("hide_overlay").catch(() => {});
    await sleep(120);

    let cap: Capture;
    try {
      cap = await invoke<Capture>("capture_screen");
    } catch (e) {
      flashToast(`Capture failed: ${e}`);
      return;
    }

    const settings = await invoke<AppSettings>("get_settings").catch(() => ({}) as AppSettings);
    const { bg, stroke } = canvasColors(settings);
    currentPathRef.current = null;
    window.clearTimeout(saveTimer.current);
    modeRef.current = "frozen";
    buildFrozenScene(cap, bg, settings.gridEnabled ?? false, stroke);
    setMode("frozen");
    await invoke("show_overlay", { widthPx: cap.widthPx, heightPx: cap.heightPx }).catch(() => {});

    if (cap.looksBlack) {
      flashToast("Couldn't capture this screen — it may be DRM-protected content.", 5000);
    }
  };

  // Open a saved .excalidraw file (from the native gallery) to continue editing.
  const openFile = async () => {
    const api = apiRef.current;
    if (!api) return;
    await autosaveNow();
    const res = await invoke<{ path: string; content: string } | null>("get_pending_file").catch(
      () => null,
    );
    if (!res) return;
    let data: any;
    try {
      data = JSON.parse(res.content);
    } catch {
      flashToast("Couldn't read that file");
      return;
    }
    const settings = await invoke<AppSettings>("get_settings").catch(() => ({}) as AppSettings);
    const { bg, stroke } = canvasColors(settings);
    const files = data.files ? Object.values(data.files) : [];
    if (files.length) api.addFiles(files as any);
    bgRef.current = null;
    scaleFactorRef.current = 1;
    currentPathRef.current = res.path;
    window.clearTimeout(saveTimer.current);
    modeRef.current = "file";
    api.updateScene({
      elements: data.elements ?? [],
      appState: sceneAppState(bg, settings.gridEnabled ?? false, stroke),
      captureUpdate: CaptureUpdateAction.NEVER,
    });
    setMode("file");
    await invoke("show_overlay").catch(() => {});
    // If this file has a screenshot background (a locked image), treat it like a frozen capture
    // so Recenter frames just the screenshot. Otherwise fit all content (a whiteboard).
    const els = api.getSceneElements();
    const bgEl = els.find((e: any) => e.type === "image" && e.locked);
    bgRef.current = bgEl ?? null;
    if (bgEl) {
      api.scrollToContent(bgEl, { fitToViewport: true, viewportZoomFactor: 1 });
    } else if (els.length) {
      api.scrollToContent(els, { fitToContent: true });
    }
  };

  // Start a fresh (new) whiteboard document — the previous one is already autosaved.
  const newBlank = async () => {
    const api = apiRef.current;
    if (!api) return;
    await autosaveNow();
    const settings = await invoke<AppSettings>("get_settings").catch(() => ({}) as AppSettings);
    const { bg, stroke } = canvasColors(settings);
    bgRef.current = null;
    currentPathRef.current = null;
    window.clearTimeout(saveTimer.current);
    modeRef.current = "whiteboard";
    api.updateScene({
      elements: [],
      appState: sceneAppState(bg, settings.gridEnabled ?? false, stroke),
      captureUpdate: CaptureUpdateAction.NEVER,
    });
    setMode("whiteboard");
  };

  const recenter = () => {
    const api = apiRef.current;
    if (!api) return;
    if (bgRef.current) {
      // Always reframe the screenshot to fill the viewport, ignoring annotations.
      api.scrollToContent(bgRef.current, {
        fitToViewport: true,
        viewportZoomFactor: 1,
        animate: true,
      });
    } else {
      const els = api.getSceneElements();
      if (els.length) api.scrollToContent(els, { fitToContent: true, animate: true });
      else api.updateScene({ appState: { scrollX: 0, scrollY: 0, zoom: { value: 1 as any } } });
    }
  };

  // Debounced: remember tool defaults + autosave the document as the user works.
  const handleChange = () => {
    if (modeRef.current === "idle") return;
    window.clearTimeout(saveTimer.current);
    saveTimer.current = window.setTimeout(() => {
      const api = apiRef.current;
      if (!api) return;
      savePrefs(api.getAppState());
      void autosaveNow();
    }, 800);
  };

  const flattenToDataURL = async (): Promise<string | null> => {
    const api = apiRef.current;
    if (!api) return null;
    const elements = api.getSceneElements();
    if (elements.length === 0) return null;
    const sf = scaleFactorRef.current || 1;
    const blob = await exportToBlob({
      elements,
      appState: { ...api.getAppState(), exportBackground: false, exportEmbedScene: false },
      files: api.getFiles(),
      mimeType: "image/png",
      getDimensions: (w: number, h: number) => ({ width: w * sf, height: h * sf, scale: sf }),
    });
    return blobToDataURL(blob);
  };

  const copyToClipboard = async () => {
    const dataUrl = await flattenToDataURL();
    if (!dataUrl) {
      flashToast("Nothing to copy");
      return;
    }
    try {
      await invoke("copy_png_to_clipboard", { pngB64: dataUrl });
      await dismiss();
    } catch (e) {
      flashToast(`Copy failed: ${e}`);
    }
  };

  const saveNow = async () => {
    if (!hasUserContent()) {
      flashToast("Nothing to save");
      return;
    }
    await autosaveNow();
    flashToast("Saved");
  };

  const dismiss = async () => {
    // Autosave the latest state before tearing down (nothing is lost on close).
    if (apiRef.current) savePrefs(apiRef.current.getAppState());
    await autosaveNow();
    window.clearTimeout(saveTimer.current);
    modeRef.current = "idle";
    await invoke("hide_overlay").catch(() => {});
    setMode("idle");
    bgRef.current = null;
    currentPathRef.current = null;
    apiRef.current?.updateScene({ elements: [] });
  };

  // Apply appearance/canvas settings to an already-open overlay (from the native Settings window).
  const applySettingsLive = async () => {
    if (modeRef.current === "idle") return;
    const api = apiRef.current;
    if (!api) return;
    const s = await invoke<AppSettings>("get_settings").catch(() => ({}) as AppSettings);
    const { bg } = canvasColors(s);
    api.updateScene({
      appState: {
        viewBackgroundColor: bg,
        gridModeEnabled: s.gridEnabled ?? false,
        theme: "light" as any,
      },
    });
  };

  // ---- Wire global-hotkey / tray events --------------------------------------
  useEffect(() => {
    const unlisteners: UnlistenFn[] = [];
    let disposed = false;
    const add = (fn: UnlistenFn) => {
      if (disposed) fn();
      else unlisteners.push(fn);
    };
    listen("hotkey-frozen", () => void startFrozen()).then(add);
    listen("hotkey-whiteboard", () => void startWhiteboard()).then(add);
    listen("open-file", () => void openFile()).then(add);
    listen("hotkey-recenter", () => recenter()).then(add);
    listen("hotkey-dismiss", () => void dismiss()).then(add);
    listen("settings-changed", () => void applySettingsLive()).then(add);

    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || modeRef.current === "idle") return;
      const api = apiRef.current;
      if (!api) return;
      const st = api.getAppState() as any;
      // While actively editing/drawing, let Excalidraw handle Esc (commit/cancel).
      const editing =
        st.editingTextElement || st.editingElement || st.editingLinearElement || st.newElement;
      if (editing) return;

      const hasSelection = Object.keys(st.selectedElementIds ?? {}).length > 0;
      const nonSelectionTool = (st.activeTool?.type ?? "selection") !== "selection";

      // First Esc with something to cancel: deselect / reset the tool ourselves (matches the web),
      // and consume the key so it doesn't also dismiss. Next Esc (nothing to cancel) dismisses.
      if (hasSelection || nonSelectionTool) {
        e.preventDefault();
        e.stopPropagation();
        api.updateScene({ appState: { selectedElementIds: {} } });
        api.setActiveTool({ type: "selection" });
        return;
      }

      e.preventDefault();
      e.stopPropagation();
      void dismiss();
    };
    window.addEventListener("keydown", onKeyDown, true);

    return () => {
      disposed = true;
      unlisteners.forEach((u) => u());
      window.removeEventListener("keydown", onKeyDown, true);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const renderActions = () => (
    <div className="excali-actions">
      {mode === "whiteboard" && (
        <button onClick={() => void newBlank()} title="New whiteboard">
          New ＋
        </button>
      )}
      <button onClick={() => recenter()} title="Refit the canvas">
        Recenter ⤢
      </button>
      <button className="primary" onClick={() => void copyToClipboard()}>
        Copy ⧉
      </button>
      <button onClick={() => void saveNow()}>Save</button>
      <button onClick={() => void dismiss()}>Close ✕</button>
    </div>
  );

  return (
    <div className="excali-root">
      <Excalidraw
        excalidrawAPI={(api: ExcalidrawImperativeAPI) => {
          apiRef.current = api;
        }}
        onChange={() => handleChange()}
        initialData={{
          appState: { viewBackgroundColor: "#ffffff", theme: "light", gridModeEnabled: false },
        }}
        renderTopRightUI={() => renderActions()}
      />
      {toast && <div className="excali-toast">{toast}</div>}
    </div>
  );
}
