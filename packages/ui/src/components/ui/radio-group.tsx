import * as React from "react";
import { Circle } from "lucide-react";
import { RadioGroup as RadioGroupPrimitive } from "radix-ui";
import { cn } from "../../lib/utils";

export function RadioGroup({ className, ...props }: React.ComponentProps<typeof RadioGroupPrimitive.Root>) { return <RadioGroupPrimitive.Root data-slot="radio-group" className={cn("grid gap-2", className)} {...props} />; }
export function RadioGroupItem({ className, ...props }: React.ComponentProps<typeof RadioGroupPrimitive.Item>) { return <RadioGroupPrimitive.Item data-slot="radio-group-item" className={cn("aspect-square size-4 rounded-full border border-input text-primary shadow-xs outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50", className)} {...props}><RadioGroupPrimitive.Indicator className="flex items-center justify-center"><Circle className="size-2 fill-current" /></RadioGroupPrimitive.Indicator></RadioGroupPrimitive.Item>; }
