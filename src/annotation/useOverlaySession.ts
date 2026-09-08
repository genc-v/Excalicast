import { useEffect, useRef, useState } from "react";
import { serializeAsJSON, CaptureUpdateAction } from "@excalidraw/excalidraw";
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import { listen, type UnlistenFn } from "../bridge";
import type { Capture, Mode } from "./types";
import * as cmd from "./commands";
import { savePrefs } from "./prefs";
import { canvasColors, frozenBackground, sceneAppState } from "./scene";
import { flattenToPng } from "./exportImage";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Coordinates the annotation overlay: modes (frozen / whiteboard / opened file), autosave,
 * export, and the global-hotkey / Escape wiring. The React component is just the view.
 */
export function useOverlaySession() {
  const apiRef = useRef<ExcalidrawImperativeAPI | null>(null);
  const bgRef = useRef<any>(null); // the locked screenshot element, if any
  const scaleRef = useRef(1);
  const saveTimer = useRef<number | undefined>(undefined);
  const pathRef = useRef<string | null>(null); // autosave target for the open document
  const [mode, setMode] = useState<Mode>("idle");
  const [toast, setToast] = useState<string | null>(null);

  const modeRef = useRef(mode);
  modeRef.current = mode;

  const flashToast = (msg: string, ms = 2600) => {
    setToast(msg);
    window.setTimeout(() => setToast((t) => (t === msg ? null : t)), ms);
  };

  const setApi = (api: ExcalidrawImperativeAPI) => {
    apiRef.current = api;
  };

  // ---- Autosave ----
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
    const png = await flattenToPng(api, scaleRef.current || 1);
    if (!png) return;
    const excalidraw = serializeAsJSON(
      api.getSceneElements(),
      api.getAppState(),
      api.getFiles(),
      "local",
    );
    try {
      if (pathRef.current) {
        await cmd.saveToFile(pathRef.current, png, excalidraw);
      } else {
        pathRef.current = await cmd.saveAnnotation(png, excalidraw);
      }
    } catch {
      /* ignore autosave errors */
    }
  };

  // ---- Scene setup shared by whiteboard / newBlank ----
  const loadBlankCanvas = async (targetMode: Mode) => {
    const api = apiRef.current;
    if (!api) return;
    const settings = await cmd.getSettings();
    const { bg, stroke } = canvasColors(settings);
    bgRef.current = null;
    scaleRef.current = 1;
    pathRef.current = null;
    window.clearTimeout(saveTimer.current);
    modeRef.current = targetMode;
    api.updateScene({
      elements: [],
      appState: sceneAppState(bg, settings.gridEnabled ?? false, stroke),
      captureUpdate: CaptureUpdateAction.NEVER,
    });
    setMode(targetMode);
  };

  // ---- Actions ----
  const startWhiteboard = async () => {
    if (modeRef.current === "whiteboard") return dismiss();
    await autosaveNow();
    await loadBlankCanvas("whiteboard");
    await cmd.showOverlay();
  };

  const newBlank = async () => {
    await autosaveNow();
    await loadBlankCanvas("whiteboard");
  };

  const startFrozen = async () => {
    if (modeRef.current === "frozen") return dismiss();
    await autosaveNow();

    if (!(await cmd.checkScreenPermission())) {
      await cmd.requestScreenPermission();
      await cmd.openScreenRecordingSettings();
      flashToast(
        "Enable Screen Recording for “Excalicast”, then quit and relaunch.",
        7000,
      );
      return;
    }

    await cmd.hideOverlay();
    await sleep(120);

    let cap: Capture;
    try {
      cap = await cmd.captureScreen();
    } catch (e) {
      flashToast(`Capture failed: ${e}`);
      return;
    }

    const api = apiRef.current;
    if (!api) return;
    const settings = await cmd.getSettings();
    const { bg, stroke } = canvasColors(settings);
    pathRef.current = null;
    window.clearTimeout(saveTimer.current);
    modeRef.current = "frozen";

    const { file, element } = frozenBackground(cap);
    api.addFiles([file as any]);
    bgRef.current = element;
    scaleRef.current = cap.scaleFactor;
    api.updateScene({
      elements: [element],
      appState: sceneAppState(bg, settings.gridEnabled ?? false, stroke),
      captureUpdate: CaptureUpdateAction.NEVER,
    });
    setMode("frozen");
    await cmd.showOverlay({ widthPx: cap.widthPx, heightPx: cap.heightPx });

    if (cap.looksBlack) {
      flashToast(
        "Couldn't capture this screen — it may be DRM-protected content.",
        5000,
      );
    }
  };

  const openFile = async () => {
    const api = apiRef.current;
    if (!api) return;
    await autosaveNow();
    const res = await cmd.getPendingFile();
    if (!res) return;
    let data: any;
    try {
      data = JSON.parse(res.content);
    } catch {
      flashToast("Couldn't read that file");
      return;
    }
    const settings = await cmd.getSettings();
    const { bg, stroke } = canvasColors(settings);
    const files = data.files ? Object.values(data.files) : [];
    if (files.length) api.addFiles(files as any);
    bgRef.current = null;
    scaleRef.current = 1;
    pathRef.current = res.path;
    window.clearTimeout(saveTimer.current);
    modeRef.current = "file";
    api.updateScene({
      elements: data.elements ?? [],
      appState: sceneAppState(bg, settings.gridEnabled ?? false, stroke),
      captureUpdate: CaptureUpdateAction.NEVER,
    });
    setMode("file");
    await cmd.showOverlay();
    // A screenshot file has a locked image; frame just that (like a frozen capture).
    const els = api.getSceneElements();
    const bgEl = els.find((e: any) => e.type === "image" && e.locked);
    bgRef.current = bgEl ?? null;
    if (bgEl)
      api.scrollToContent(bgEl, { fitToViewport: true, viewportZoomFactor: 1 });
    else if (els.length) api.scrollToContent(els, { fitToContent: true });
  };

  const recenter = () => {
    const api = apiRef.current;
    if (!api) return;
    if (bgRef.current) {
      // Reframe the screenshot to fill the viewport, ignoring annotations.
      api.scrollToContent(bgRef.current, {
        fitToViewport: true,
        viewportZoomFactor: 1,
        animate: true,
      });
      return;
    }
    const els = api.getSceneElements();
    if (els.length)
      api.scrollToContent(els, { fitToContent: true, animate: true });
    else
      api.updateScene({
        appState: { scrollX: 0, scrollY: 0, zoom: { value: 1 as any } },
      });
  };

  const copyToClipboard = async () => {
    const api = apiRef.current;
    if (!api) return;
    const png = await flattenToPng(api, scaleRef.current || 1);
    if (!png) return flashToast("Nothing to copy");
    try {
      await cmd.copyPngToClipboard(png);
      await dismiss();
    } catch (e) {
      flashToast(`Copy failed: ${e}`);
    }
  };

  const saveNow = async () => {
    if (!hasUserContent()) return flashToast("Nothing to save");
    await autosaveNow();
    flashToast("Saved");
  };

  const dismiss = async () => {
    const api = apiRef.current;
    if (api) savePrefs(api.getAppState());
    await autosaveNow();
    window.clearTimeout(saveTimer.current);
    modeRef.current = "idle";
    setMode("idle");
    bgRef.current = null;
    pathRef.current = null;
    api?.updateScene({ elements: [] });
    // Hide + destroy the WebView so the idle app releases all web memory.
    await cmd.releaseOverlay();
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

  const applySettingsLive = async () => {
    const api = apiRef.current;
    if (modeRef.current === "idle" || !api) return;
    const s = await cmd.getSettings();
    api.updateScene({
      appState: {
        viewBackgroundColor: canvasColors(s).bg,
        gridModeEnabled: s.gridEnabled ?? false,
        theme: "light" as any,
      },
    });
  };

  // ---- Global-hotkey / tray events + Escape ----
  useEffect(() => {
    const unlisteners: UnlistenFn[] = [];
    let disposed = false;
    const add = (fn: UnlistenFn) => (disposed ? fn() : unlisteners.push(fn));

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
      if (
        st.editingTextElement ||
        st.editingElement ||
        st.editingLinearElement ||
        st.newElement
      ) {
        return;
      }
      const hasSelection = Object.keys(st.selectedElementIds ?? {}).length > 0;
      const nonSelectionTool =
        (st.activeTool?.type ?? "selection") !== "selection";
      e.preventDefault();
      e.stopPropagation();
      // First Esc cancels (deselect / reset tool); next Esc (nothing to cancel) dismisses.
      if (hasSelection || nonSelectionTool) {
        api.updateScene({ appState: { selectedElementIds: {} } });
        api.setActiveTool({ type: "selection" });
        return;
      }
      void dismiss();
    };
    window.addEventListener("keydown", onKeyDown, true);

    // Tell native the web is ready so any hotkey that spun up the WebView can now run.
    void cmd.webReady();

    return () => {
      disposed = true;
      unlisteners.forEach((u) => u());
      window.removeEventListener("keydown", onKeyDown, true);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return {
    mode,
    toast,
    setApi,
    handleChange,
    startWhiteboard,
    newBlank,
    recenter,
    copyToClipboard,
    saveNow,
    dismiss,
  };
}
