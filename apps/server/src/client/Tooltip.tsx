import { cloneElement, useId, useState, type ReactElement } from "react";

export function Tooltip({ label, shortcut, children, className = "" }: {
  label: string;
  shortcut?: string;
  children: ReactElement<{ "aria-describedby"?: string }>;
  className?: string;
}) {
  const id = useId();
  const [dismissed, setDismissed] = useState(false);
  return <span className={`tooltip ${className}`} data-dismissed={dismissed}
    onPointerEnter={() => setDismissed(false)} onFocus={() => setDismissed(false)}
    onKeyDown={(event) => { if (event.key === "Escape") setDismissed(true); }}
    onClick={() => setDismissed(true)}>
    {cloneElement(children, { "aria-describedby": [children.props["aria-describedby"], id].filter(Boolean).join(" ") })}
    <span id={id} role="tooltip" className="tooltip-help">{label}{shortcut && <kbd>{shortcut}</kbd>}</span>
  </span>;
}
