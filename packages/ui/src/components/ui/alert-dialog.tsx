import * as React from "react";
import { AlertDialog as AlertDialogPrimitive } from "radix-ui";
import { cn } from "../../lib/utils";
import { buttonVariants } from "./button";

export const AlertDialog = AlertDialogPrimitive.Root;
export const AlertDialogTrigger = AlertDialogPrimitive.Trigger;
export const AlertDialogPortal = AlertDialogPrimitive.Portal;
export function AlertDialogOverlay({ className, ...props }: React.ComponentProps<typeof AlertDialogPrimitive.Overlay>) { return <AlertDialogPrimitive.Overlay className={cn("fixed inset-0 z-50 bg-black/45 backdrop-blur-[2px] data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 motion-reduce:animate-none", className)} {...props} />; }
export function AlertDialogContent({ className, ...props }: React.ComponentProps<typeof AlertDialogPrimitive.Content>) { return <AlertDialogPortal><AlertDialogOverlay /><AlertDialogPrimitive.Content className={cn("fixed left-1/2 top-1/2 z-50 grid w-[calc(100%-2rem)] max-w-lg -translate-x-1/2 -translate-y-1/2 gap-4 rounded-xl border bg-background p-5 shadow-xl data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 motion-reduce:animate-none", className)} {...props} /></AlertDialogPortal>; }
export function AlertDialogHeader({ className, ...props }: React.ComponentProps<"div">) { return <div className={cn("grid gap-2", className)} {...props} />; }
export function AlertDialogFooter({ className, ...props }: React.ComponentProps<"div">) { return <div className={cn("flex flex-col-reverse gap-2 sm:flex-row sm:justify-end", className)} {...props} />; }
export function AlertDialogTitle({ className, ...props }: React.ComponentProps<typeof AlertDialogPrimitive.Title>) { return <AlertDialogPrimitive.Title className={cn("text-base font-semibold", className)} {...props} />; }
export function AlertDialogDescription({ className, ...props }: React.ComponentProps<typeof AlertDialogPrimitive.Description>) { return <AlertDialogPrimitive.Description className={cn("text-sm text-muted-foreground", className)} {...props} />; }
export function AlertDialogAction({ className, ...props }: React.ComponentProps<typeof AlertDialogPrimitive.Action>) { return <AlertDialogPrimitive.Action className={cn(buttonVariants(), className)} {...props} />; }
export function AlertDialogCancel({ className, ...props }: React.ComponentProps<typeof AlertDialogPrimitive.Cancel>) { return <AlertDialogPrimitive.Cancel className={cn(buttonVariants({ variant: "outline" }), className)} {...props} />; }
