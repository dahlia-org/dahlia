import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { App } from "@dahlia-ai/ui";
import "./styles.css";

document.documentElement.lang = navigator.language.startsWith("ja") ? "ja" : "en";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
