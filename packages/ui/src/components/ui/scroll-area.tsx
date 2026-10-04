import * as React from "react";
import { ScrollArea as ScrollAreaPrimitive } from "radix-ui";
import { cn } from "../../lib/utils";

export function ScrollArea({ className, children, ...props }: React.ComponentProps<typeof ScrollAreaPrimitive.Root>) { return <ScrollAreaPrimitive.Root data-slot="scroll-area" className={cn("relative overflow-hidden", className)} {...props}><ScrollAreaPrimitive.Viewport className="size-full rounded-[inherit]">{children}</ScrollAreaPrimitive.Viewport><ScrollBar /><ScrollAreaPrimitive.Corner /></ScrollAreaPrimitive.Root>; }
export function ScrollBar({ className, orientation = "vertical", ...props }: React.ComponentProps<typeof ScrollAreaPrimitive.Scrollbar>) { return <ScrollAreaPrimitive.Scrollbar orientation={orientation} className={cn("flex touch-none select-none p-px transition-colors", orientation === "vertical" ? "h-full w-2.5 border-l border-l-transparent" : "h-2.5 flex-col border-t border-t-transparent", className)} {...props}><ScrollAreaPrimitive.Thumb className="relative flex-1 rounded-full bg-border" /></ScrollAreaPrimitive.Scrollbar>; }
