import * as React from "react";
import { cn } from "../../lib/utils";

export function Card({ className, ...props }: React.ComponentProps<"div">) { return <div data-slot="card" className={cn("rounded-xl border bg-card text-card-foreground shadow-sm", className)} {...props} />; }
export function CardHeader({ className, ...props }: React.ComponentProps<"div">) { return <div data-slot="card-header" className={cn("grid gap-1.5 p-5", className)} {...props} />; }
export function CardTitle({ className, ...props }: React.ComponentProps<"div">) { return <div data-slot="card-title" className={cn("font-semibold leading-none tracking-tight", className)} {...props} />; }
export function CardDescription({ className, ...props }: React.ComponentProps<"div">) { return <div data-slot="card-description" className={cn("text-sm text-muted-foreground", className)} {...props} />; }
export function CardContent({ className, ...props }: React.ComponentProps<"div">) { return <div data-slot="card-content" className={cn("p-5 pt-0", className)} {...props} />; }
export function CardFooter({ className, ...props }: React.ComponentProps<"div">) { return <div data-slot="card-footer" className={cn("flex items-center p-5 pt-0", className)} {...props} />; }
