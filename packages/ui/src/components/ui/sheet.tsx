import * as React from "react";
import { X } from "lucide-react";
import { Dialog as SheetPrimitive } from "radix-ui";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "../../lib/utils";

export const Sheet = SheetPrimitive.Root;
export const SheetTrigger = SheetPrimitive.Trigger;
export const SheetClose = SheetPrimitive.Close;
const sheetVariants = cva("fixed z-50 gap-4 bg-background p-5 shadow-xl transition data-[state=open]:animate-in data-[state=closed]:animate-out motion-reduce:animate-none", { variants: { side: {
  top: "inset-x-0 top-0 border-b data-[state=closed]:slide-out-to-top data-[state=open]:slide-in-from-top",
  bottom: "inset-x-0 bottom-0 border-t data-[state=closed]:slide-out-to-bottom data-[state=open]:slide-in-from-bottom",
  left: "inset-y-0 left-0 h-full w-3/4 border-r data-[state=closed]:slide-out-to-left data-[state=open]:slide-in-from-left sm:max-w-sm",
  right: "inset-y-0 right-0 h-full w-3/4 border-l data-[state=closed]:slide-out-to-right data-[state=open]:slide-in-from-right sm:max-w-sm",
} }, defaultVariants: { side: "right" } });
export function SheetContent({ side, className, children, ...props }: React.ComponentProps<typeof SheetPrimitive.Content> & VariantProps<typeof sheetVariants>) { return <SheetPrimitive.Portal><SheetPrimitive.Overlay className="fixed inset-0 z-50 bg-black/45 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0" /><SheetPrimitive.Content className={cn(sheetVariants({ side }), className)} {...props}>{children}<SheetPrimitive.Close className="absolute right-3 top-3 rounded-md p-1 text-muted-foreground hover:bg-accent"><X className="size-4" /><span className="sr-only">Close</span></SheetPrimitive.Close></SheetPrimitive.Content></SheetPrimitive.Portal>; }
export function SheetHeader({ className, ...props }: React.ComponentProps<"div">) { return <div className={cn("grid gap-2", className)} {...props} />; }
export function SheetTitle({ className, ...props }: React.ComponentProps<typeof SheetPrimitive.Title>) { return <SheetPrimitive.Title className={cn("font-semibold", className)} {...props} />; }
export function SheetDescription({ className, ...props }: React.ComponentProps<typeof SheetPrimitive.Description>) { return <SheetPrimitive.Description className={cn("text-sm text-muted-foreground", className)} {...props} />; }
