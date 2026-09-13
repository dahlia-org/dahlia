import { Children, isValidElement, useEffect, useId, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { createPortal } from "react-dom";

type Option = { value?: string | number; children?: ReactNode; disabled?: boolean };
type Props = { value: string | number; onValueChange: (value: string) => void; children: ReactNode;
  disabled?: boolean; placeholder?: string; menuLabel?: string; "aria-label"?: string };

/** Single-value picker using the same menu surface as Workspace navigation. */
export function Select({ value, onValueChange, children, disabled, placeholder, menuLabel, "aria-label": label }: Props) {
  const id = useId();
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const [portalRoot, setPortalRoot] = useState<Element | null>(null);
  useEffect(() => { setPortalRoot(trigger.current?.closest("dialog") ?? document.body); }, []);
  const [open, setOpen] = useState(false);
  const [position, setPosition] = useState<CSSProperties>({});
  useEffect(() => {
    if (!open) return;
    const hide = (event: Event) => {
      if (!menu.current?.contains(event.target as Node)) menu.current?.hidePopover();
    };
    window.addEventListener("resize", hide);
    document.addEventListener("scroll", hide, true);
    return () => { window.removeEventListener("resize", hide); document.removeEventListener("scroll", hide, true); };
  }, [open]);
  const options = Children.toArray(children).filter(isValidElement<Option>).map(({ props }) => ({
    value: String(props.value ?? (typeof props.children === "string" || typeof props.children === "number" ? props.children : "")), label: props.children, disabled: props.disabled,
  }));
  const selectedValue = String(value);
  const selected = options.find((option) => option.value === selectedValue) ?? (placeholder ? undefined : options[0]);
  const focusOption = (index: number) => {
    const buttons = menu.current?.querySelectorAll<HTMLButtonElement>("button:not(:disabled)");
    const button = buttons?.[Math.max(0, Math.min(index, buttons.length - 1))];
    button?.focus(); button?.scrollIntoView({ block: "nearest" });
  };
  const show = () => {
    const button = trigger.current;
    if (!button || button.matches(":disabled")) return;
    const rect = button.getBoundingClientRect();
    const below = window.innerHeight - rect.bottom - 12;
    const above = rect.top - 12;
    const upwards = below < 200 && above > below;
    const left = Math.max(12, Math.min(rect.left, window.innerWidth - Math.max(rect.width, 160) - 12));
    setPosition({ left, maxWidth: window.innerWidth - left - 12,
      minWidth: rect.width, ...(upwards ? { bottom: window.innerHeight - rect.top + 6 } : { top: rect.bottom + 6 }),
      maxHeight: Math.min(400, upwards ? above : below) });
    menu.current?.showPopover();
    requestAnimationFrame(() => {
      const enabled = options.filter((option) => !option.disabled);
      focusOption(enabled.findIndex((option) => option.value === selected?.value));
    });
  };
  const close = () => { menu.current?.hidePopover(); trigger.current?.focus(); };
  return <>
    <button ref={trigger} type="button" className="dropdown-trigger select-trigger" disabled={disabled}
      value={selectedValue} role="combobox" aria-label={label} aria-controls={id} aria-haspopup="listbox" aria-expanded={open}
      onClick={() => open ? close() : show()} onKeyDown={(event) => {
        if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) { event.preventDefault(); show(); }
      }}><span>{selected?.label ?? placeholder}</span><svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path d="m4 6 4 4 4-4" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" /></svg></button>
    {portalRoot && createPortal(<div id={id} ref={menu} popover="auto" role="listbox" aria-label={label}
      className="dropdown-menu select-menu" style={position} onToggle={(event) => setOpen(event.newState === "open")}
      onKeyDown={(event) => {
        const buttons = [...event.currentTarget.querySelectorAll<HTMLButtonElement>("button:not(:disabled)")];
        const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
        event.stopPropagation();
        if (event.key === "Tab") { close(); return; }
        if (event.key === "Escape") { event.preventDefault(); close(); return; }
        let next: number | undefined;
        if (event.key === "ArrowDown") next = (index + 1) % buttons.length;
        if (event.key === "ArrowUp") next = (index - 1 + buttons.length) % buttons.length;
        if (event.key === "Home") next = 0;
        if (event.key === "End") next = buttons.length - 1;
        if (event.key.length === 1 && event.key !== " " && !event.metaKey && !event.ctrlKey) {
          next = buttons.findIndex((_, offset) => {
            const candidate = buttons[(index + 1 + offset) % buttons.length];
            return candidate?.textContent?.toLocaleLowerCase().startsWith(event.key.toLocaleLowerCase());
          });
          if (next >= 0) next = (index + 1 + next) % buttons.length;
          else next = undefined;
        }
        if (next !== undefined) { event.preventDefault(); focusOption(next); }
      }}>
      {menuLabel && <strong>{menuLabel}</strong>}
      {options.map((option) => <button type="button" key={option.value} value={option.value} role="option" tabIndex={-1}
        className="dropdown-option" aria-selected={option.value === selectedValue} disabled={option.disabled}
        onClick={() => { close(); if (option.value !== selectedValue) onValueChange(option.value); }}>
        <span>{option.label}</span>{option.value === selectedValue && <span aria-hidden="true">✓</span>}
      </button>)}
    </div>, portalRoot)}
  </>;
}
