import * as React from "react";
import { Tooltip as TooltipPrimitive } from "radix-ui";
import { cn } from "../../lib/utils";

export const TooltipProvider = TooltipPrimitive.Provider;
export const Tooltip = TooltipPrimitive.Root;
export const TooltipTrigger = TooltipPrimitive.Trigger;
export function TooltipContent({ className, sideOffset = 6, ...props }: React.ComponentProps<typeof TooltipPrimitive.Content>) {
  return <TooltipPrimitive.Portal><TooltipPrimitive.Content data-slot="tooltip-content" sideOffset={sideOffset}
    className={cn("z-50 max-w-60 animate-in fade-in-0 zoom-in-95 rounded-md bg-foreground px-2.5 py-1.5 text-xs text-background shadow-md data-[state=closed]:animate-out data-[state=closed]:fade-out-0 motion-reduce:animate-none", className)} {...props} /></TooltipPrimitive.Portal>;
}
