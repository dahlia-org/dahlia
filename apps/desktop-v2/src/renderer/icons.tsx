// The few icons the app needs, drawn like SF Symbols at the text size.
import type { SVGProps } from "react";

const icon = (path: React.ReactNode) => (props: SVGProps<SVGSVGElement>) => (
  <svg viewBox="0 0 16 16" width="1em" height="1em" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden {...props}>{path}</svg>
);

export const PlusIcon = icon(<path d="M8 3v10M3 8h10" />);
export const RecordIcon = icon(<circle cx="8" cy="8" r="4.5" fill="currentColor" stroke="none" />);
export const StopIcon = icon(<rect x="4" y="4" width="8" height="8" rx="1.5" fill="currentColor" stroke="none" />);
export const SparklesIcon = icon(<><path d="M7 2.5l1.2 3.3L11.5 7 8.2 8.2 7 11.5 5.8 8.2 2.5 7l3.3-1.2z" /><path d="M12.5 10.5l.5 1.5 1.5.5-1.5.5-.5 1.5-.5-1.5-1.5-.5 1.5-.5z" /></>);
export const GearIcon = icon(<><circle cx="8" cy="8" r="2.2" /><path d="M8 1.8v1.6M8 12.6v1.6M1.8 8h1.6M12.6 8h1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M3.6 12.4l1.1-1.1M11.3 4.7l1.1-1.1" /></>);
export const EllipsisIcon = icon(<><circle cx="3.5" cy="8" r=".9" fill="currentColor" /><circle cx="8" cy="8" r=".9" fill="currentColor" /><circle cx="12.5" cy="8" r=".9" fill="currentColor" /></>);
export const PersonIcon = icon(<><circle cx="8" cy="5.5" r="2.5" /><path d="M3 13.5c.8-2.4 2.7-3.5 5-3.5s4.2 1.1 5 3.5" /></>);
export const XIcon = icon(<path d="M4 4l8 8M12 4l-8 8" />);
