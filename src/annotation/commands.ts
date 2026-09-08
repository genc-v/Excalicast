// The single place that knows the native bridge command names. Everything else calls these
// typed wrappers. Fire-and-forget/lookup commands swallow errors with safe defaults; commands
// whose failure the caller must handle (capture, save, clipboard) propagate.

import { invoke } from "../bridge";
import type { AppSettings, Capture } from "./types";

export const captureScreen = () => invoke<Capture>("capture_screen");

export const showOverlay = (dims?: { widthPx: number; heightPx: number }) =>
  invoke("show_overlay", dims ?? {}).catch(() => {});

export const hideOverlay = () => invoke("hide_overlay").catch(() => {});

/// Signals the native side that the web app has mounted and event listeners are registered.
export const webReady = () => invoke("web_ready").catch(() => {});

/// Asks the native side to hide + destroy the WebView, freeing all web memory while idle.
export const releaseOverlay = () => invoke("release_overlay").catch(() => {});

export const getSettings = () =>
  invoke<AppSettings>("get_settings").catch(() => ({}) as AppSettings);

export const checkScreenPermission = () =>
  invoke<boolean>("check_screen_permission").catch(() => true);

export const requestScreenPermission = () =>
  invoke("request_screen_permission").catch(() => {});

export const openScreenRecordingSettings = () =>
  invoke("open_screen_recording_settings").catch(() => {});

export const copyPngToClipboard = (pngB64: string) =>
  invoke("copy_png_to_clipboard", { pngB64 });

export const saveAnnotation = (pngB64: string, excalidraw: string) =>
  invoke<string>("save_annotation", { pngB64, excalidraw });

export const saveToFile = (path: string, pngB64: string, excalidraw: string) =>
  invoke("save_to_file", { path, pngB64, excalidraw });

export const getPendingFile = () =>
  invoke<{ path: string; content: string } | null>("get_pending_file").catch(() => null);
