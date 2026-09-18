import { useEffect, useId, useRef, useState } from "react";
import { Check, Pencil, Trash2, X } from "lucide-react";
import { AppearancePicker, AppearanceIcon, type Appearance } from "./AppearancePicker";
import { Button } from "./components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "./components/ui/dialog";
import { Input } from "./components/ui/input";
import { Label } from "./components/ui/label";
import { Popover, PopoverContent, PopoverTrigger } from "./components/ui/popover";
import { Textarea } from "./components/ui/textarea";
import { Select } from "./Select";
import { uiText } from "./api";

export interface DialogField {
  name: string;
  label: string;
  hideLabel?: boolean;
  value?: string;
  multiline?: boolean;
  appearance?: "editable" | "inherited";
  required?: boolean;
  pattern?: string;
  type?: "email" | "number";
  min?: number;
  max?: number;
  options?: Array<{ value: string; label: string }>;
}

export interface ActionDialogOptions {
  title: string;
  description?: string;
  confirmLabel: string;
  destructive?: boolean;
  fields?: DialogField[];
  onSubmit: (values: Record<string, string>) => Promise<void>;
}

export function ActionDialog({ title, description, confirmLabel, destructive, fields = [], onSubmit, onClose, previousFocus }: ActionDialogOptions & { onClose: () => void; previousFocus?: HTMLElement | null }) {
  const submitting = useRef(false);
  const previousFocusRef = useRef<HTMLElement | null>(previousFocus ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null));
  const content = useRef<HTMLDivElement>(null);
  const [pending, setPending] = useState(false);
  const [discarding, setDiscarding] = useState(false);
  const [error, setError] = useState<string>();
  const [values, setValues] = useState(() => Object.fromEntries(fields.map((field) => [field.name, field.value ?? ""])));
  const id = useId();
  const dirty = fields.some((field) => values[field.name] !== (field.value ?? ""));
  const focusFirst = () => content.current?.querySelector<HTMLElement>(discarding || destructive ? "[data-cancel]" : "input, textarea, [role=combobox], [data-confirm]")?.focus();

  useEffect(() => () => {
    const previous = previousFocusRef.current;
    if (previous?.isConnected) previous.focus({ preventScroll: true });
  }, []);

  useEffect(focusFirst, [discarding, destructive]);

  const requestClose = () => {
    if (submitting.current) return;
    if (discarding) { setDiscarding(false); return; }
    if (dirty) { setDiscarding(true); return; }
    onClose();
  };
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (submitting.current || discarding) return;
    submitting.current = true;
    setPending(true);
    setError(undefined);
    try { await onSubmit(values); onClose(); }
    catch (caught) { setError(caught instanceof Error ? caught.message : uiText("Could not save. Please try again.", "保存できませんでした。再試行してください。")); }
    finally { submitting.current = false; setPending(false); }
  }

  const appearanceField = fields.find((field) => field.appearance);
  const displayedTitle = discarding ? uiText("Discard unsaved changes?", "未保存の変更を破棄しますか？") : title;
  const displayedDescription = discarding ? uiText("Your changes have not been saved. You can keep editing or discard this draft.", "変更はまだ保存されていません。編集を続けるか、変更を破棄してください。") : description;
  const Symbol = destructive || discarding ? Trash2 : fields.length ? Pencil : Check;
  return <Dialog open onOpenChange={(open) => { if (!open) requestClose(); }}>
    <DialogContent ref={content} showCloseButton={false} className={`action-dialog${fields.some((field) => field.multiline) && !discarding ? " sm:max-w-2xl" : ""}`}
      aria-describedby={displayedDescription ? `${id}-description` : undefined}
      onEscapeKeyDown={(event) => { event.preventDefault(); requestClose(); }}
      onPointerDownOutside={(event) => { event.preventDefault(); requestClose(); }}
      onOpenAutoFocus={(event) => { event.preventDefault(); focusFirst(); }}>
      <form className="grid gap-4" onSubmit={(event) => void submit(event)} aria-busy={pending}>
        <DialogHeader className="pr-8">
          <div className="flex items-center gap-2.5"><span className={destructive || discarding ? "rounded-md bg-destructive/10 p-1.5 text-destructive" : "rounded-md bg-accent p-1.5 text-primary"}><Symbol className="size-4" /></span><DialogTitle>{displayedTitle}</DialogTitle></div>
          {displayedDescription && <DialogDescription id={`${id}-description`}>{displayedDescription}</DialogDescription>}
          <Button type="button" variant="ghost" size="icon" className="absolute right-3 top-3" aria-label={uiText("Close", "閉じる")} disabled={pending} onClick={requestClose}><X /></Button>
        </DialogHeader>
        {!discarding && <div className="grid gap-4">
          {fields.map((field) => {
            if (field.appearance) return null;
            if (field.name === "name" && appearanceField) {
              const appearance = JSON.parse(values[appearanceField.name]!) as Appearance;
              return <div className="grid gap-2" key={field.name}>
                <Label htmlFor={`${id}-${field.name}`}>{field.label}</Label>
                <div className="flex items-center gap-2">
                  {appearanceField.appearance === "inherited" ? <span className="grid size-9 place-items-center rounded-md border" title={uiText("Inherited from parent Project", "親プロジェクトから継承")}><AppearanceIcon appearance={appearance} size={20} /></span>
                    : <Popover><PopoverTrigger asChild><Button type="button" variant="outline" size="icon" disabled={pending} aria-label={uiText("Change icon and color", "アイコンと色を変更")}><AppearanceIcon appearance={appearance} size={20} /></Button></PopoverTrigger>
                      <PopoverContent align="start" className="w-auto"><AppearancePicker value={appearance} disabled={pending} onChange={(next) => setValues((current) => ({ ...current, [appearanceField.name]: JSON.stringify(next) }))} /></PopoverContent></Popover>}
                  <Input id={`${id}-${field.name}`} name={field.name} value={values[field.name]} required={field.required} disabled={pending}
                    onChange={(event) => setValues((current) => ({ ...current, [field.name]: event.target.value }))} />
                </div>
              </div>;
            }
            if (field.options) return <div className="grid gap-2" key={field.name}><Label>{field.label}</Label><Select aria-label={field.label} value={values[field.name] ?? ""} disabled={pending}
              onValueChange={(value) => setValues((current) => ({ ...current, [field.name]: value }))}>{field.options.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</Select></div>;
            return <div className="grid gap-2" key={field.name}>
              {!field.hideLabel && <Label htmlFor={`${id}-${field.name}`}>{field.label}{!field.required && <span className="text-xs font-normal text-muted-foreground">{uiText("Optional", "任意")}</span>}</Label>}
              {field.multiline ? <Textarea id={`${id}-${field.name}`} aria-label={field.hideLabel ? field.label : undefined} name={field.name} value={values[field.name]} required={field.required} rows={5} disabled={pending} onChange={(event) => setValues((current) => ({ ...current, [field.name]: event.target.value }))} />
                : <Input id={`${id}-${field.name}`} aria-label={field.hideLabel ? field.label : undefined} name={field.name} value={values[field.name]} required={field.required} pattern={field.pattern} type={field.type} min={field.min} max={field.max} step={field.type === "number" ? 1 : undefined} disabled={pending} onChange={(event) => setValues((current) => ({ ...current, [field.name]: event.target.value }))} />}
            </div>;
          })}
          {error && <p className="text-sm text-destructive" role="alert">{error}</p>}
        </div>}
        <DialogFooter>
          <span className="mr-auto self-center text-xs text-muted-foreground" role="status">{pending ? uiText("Saving changes…", "変更を保存中…") : ""}</span>
          <Button type="button" variant="outline" data-cancel disabled={pending} onClick={requestClose}>{discarding ? uiText("Keep editing", "編集を続ける") : uiText("Cancel", "キャンセル")}</Button>
          {discarding ? <Button type="button" variant="destructive" data-confirm onClick={onClose}>{uiText("Discard changes", "変更を破棄")}</Button>
            : <Button variant={destructive ? "destructive" : "default"} data-confirm disabled={pending || fields.some((field) => field.required && !values[field.name]?.trim())}>{pending ? uiText("Please wait…", "処理中…") : confirmLabel}</Button>}
        </DialogFooter>
      </form>
    </DialogContent>
  </Dialog>;
}

export function useActionDialog() {
  const [options, setOptions] = useState<ActionDialogOptions>();
  const previousFocus = useRef<HTMLElement | null>(null);
  return {
    openDialog: (next: ActionDialogOptions, restoreFocus?: HTMLElement | null) => {
      previousFocus.current = restoreFocus ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null);
      const menu = document.activeElement?.closest<HTMLElement>("[data-radix-menu-content], [popover]");
      if (menu?.matches("[popover]") && "hidePopover" in menu) menu.hidePopover();
      setOptions(next);
    },
    dialog: options ? <ActionDialog {...options} previousFocus={previousFocus.current} onClose={() => setOptions(undefined)} /> : null,
  };
}
