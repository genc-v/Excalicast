import AnnotationOverlay from "./annotation/AnnotationOverlay";

// The native shell hosts only the annotation overlay in its WKWebView; Settings is a native
// SwiftUI window.
export default function App() {
  return <AnnotationOverlay />;
}
