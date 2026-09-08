import { Excalidraw } from "@excalidraw/excalidraw";
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import { useOverlaySession } from "./useOverlaySession";

export default function AnnotationOverlay() {
  const session = useOverlaySession();
  const { mode, toast } = session;

  const actions = (
    <div className="excali-actions">
      {mode === "whiteboard" && (
        <button onClick={() => void session.newBlank()} title="New whiteboard">
          New ＋
        </button>
      )}
      <button onClick={() => session.recenter()} title="Refit the canvas">
        Recenter ⤢
      </button>
      <button className="primary" onClick={() => void session.copyToClipboard()}>
        Copy ⧉
      </button>
      <button onClick={() => void session.saveNow()}>Save</button>
      <button onClick={() => void session.dismiss()}>Close ✕</button>
    </div>
  );

  return (
    <div className="excali-root">
      <Excalidraw
        excalidrawAPI={(api: ExcalidrawImperativeAPI) => session.setApi(api)}
        onChange={() => session.handleChange()}
        initialData={{
          appState: { viewBackgroundColor: "#ffffff", theme: "light", gridModeEnabled: false },
        }}
        renderTopRightUI={() => actions}
      />
      {toast && <div className="excali-toast">{toast}</div>}
    </div>
  );
}
