import { type ReactElement } from "react";
import { cn } from "./lib/utils";
import { Tooltip as Root, TooltipContent, TooltipProvider, TooltipTrigger } from "./components/ui/tooltip";

export function Tooltip({ label, shortcut, children, className = "" }: {
  label: string;
  shortcut?: string;
  children: ReactElement;
  className?: string;
}) {
  return <TooltipProvider delayDuration={300} skipDelayDuration={100}>
    <Root>
      <TooltipTrigger asChild className={cn("inline-flex min-w-0", className)}>{children}</TooltipTrigger>
      <TooltipContent side="bottom">{label}{shortcut && <kbd className="ml-2 text-background/70">{shortcut}</kbd>}</TooltipContent>
    </Root>
  </TooltipProvider>;
}
