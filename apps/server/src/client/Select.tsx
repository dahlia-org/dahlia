import { Children, isValidElement, useRef, useState, type ReactNode } from "react";
import { Input } from "./components/ui/input";
import { Select as Root, SelectContent, SelectGroup, SelectItem, SelectLabel, SelectTrigger, SelectValue } from "./components/ui/select";

type Option = { value?: string | number; children?: ReactNode; disabled?: boolean };
type Props = { value: string | number; onValueChange: (value: string) => void; children: ReactNode;
  disabled?: boolean; placeholder?: string; menuLabel?: string; emptyMessage?: string; "aria-label"?: string;
  search?: { value: string; onValueChange: (value: string) => void; placeholder: string } };

const emptyValue = "__dahlia_empty__";

/** Single-value shadcn picker shared by forms and navigation. */
export function Select({ value, onValueChange, children, disabled, placeholder, menuLabel, emptyMessage, search, "aria-label": label }: Props) {
  const searchInput = useRef<HTMLInputElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const [open, setOpen] = useState(false);
  const options = Children.toArray(children).filter(isValidElement<Option>).map(({ props }) => ({
    value: String(props.value ?? (typeof props.children === "string" || typeof props.children === "number" ? props.children : "")),
    label: props.children,
    disabled: props.disabled,
  }));
  const selectedValue = String(value) || emptyValue;
  return <Root value={selectedValue} disabled={disabled} open={open} onValueChange={(next) => onValueChange(next === emptyValue ? "" : next)}
    onOpenChange={(next) => { setOpen(next); if (next && search) requestAnimationFrame(() => searchInput.current?.focus()); }}>
    <SelectTrigger ref={trigger} className="[&>span]:flex [&>span]:min-w-0 [&>span]:items-center [&>span]:gap-2" aria-label={label} data-value={selectedValue}><SelectValue placeholder={placeholder} /></SelectTrigger>
    <SelectContent>
      {search && <div className="p-1"><Input ref={searchInput} type="search" value={search.value} maxLength={200} aria-label={search.placeholder}
        placeholder={search.placeholder} onKeyDown={(event) => {
          if (event.key === "Tab") { event.preventDefault(); setOpen(false); requestAnimationFrame(() => trigger.current?.focus()); }
          else if (event.key !== "Escape") event.stopPropagation();
        }}
        onChange={(event) => search.onValueChange(event.target.value)} /></div>}
      <SelectGroup>
        {menuLabel && <SelectLabel>{menuLabel}</SelectLabel>}
        {!options.length && emptyMessage && <span className="block px-2 py-2 text-sm text-muted-foreground" role="status">{emptyMessage}</span>}
        {options.map((option) => <SelectItem key={option.value || emptyValue} value={option.value || emptyValue} data-value={option.value} disabled={option.disabled}>{option.label}</SelectItem>)}
      </SelectGroup>
    </SelectContent>
  </Root>;
}
