import * as React from "react";
import { HoverCard as HoverCardPrimitive } from "radix-ui";
import { cn } from "../../lib/utils";

export const HoverCard = HoverCardPrimitive.Root;
export const HoverCardTrigger = HoverCardPrimitive.Trigger;
export function HoverCardContent({ className, align = "start", sideOffset = 6, ...props }: React.ComponentProps<typeof HoverCardPrimitive.Content>) {
  return <HoverCardPrimitive.Portal><HoverCardPrimitive.Content data-slot="hover-card-content" align={align} sideOffset={sideOffset}
    className={cn("z-50 w-80 origin-[var(--radix-hover-card-content-transform-origin)] animate-in fade-in-0 zoom-in-95 rounded-lg border bg-popover p-3 text-popover-foreground shadow-md data-[state=closed]:animate-out data-[state=closed]:fade-out-0 motion-reduce:animate-none", className)} {...props} /></HoverCardPrimitive.Portal>;
}
