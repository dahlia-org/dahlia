import { AppearancePicker, AppearanceIcon, type Appearance } from "./AppearancePicker";
import { useEffect, useId, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { MenuIcon } from "./Sidebar";
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
  type?: "email";
}

export interface ActionDialogOptions {
  title: string;
  description?: string;
  confirmLabel: string;
  destructive?: boolean;
  fields?: DialogField[];
  onSubmit: (values: Record<string, string>) => Promise<void>;
}

export function ActionDialog({ title, description, confirmLabel, destructive, fields = [], onSubmit, onClose }: ActionDialogOptions & { onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const submitting = useRef(false);
  const [pending, setPending] = useState(false);
  const [discarding, setDiscarding] = useState(false);
  const [error, setError] = useState<string>();
  const [values, setValues] = useState(() => Object.fromEntries(fields.map((field) => [field.name, field.value ?? ""])));
  const id = useId();

  useEffect(() => {
    const previous = document.activeElement;
    const element = dialog.current!;
    element.showModal();
    // Destructive dialogs start at Cancel; editors start at their first field.
    element.querySelector<HTMLElement>(destructive ? "[data-cancel]" : "input, textarea, [data-confirm]")?.focus();
    return () => {
      element.close();
      if (previous instanceof HTMLElement && previous.isConnected) previous.focus({ preventScroll: true });
    };
  }, [destructive]);

  useEffect(() => {
    dialog.current?.querySelector<HTMLElement>(discarding || destructive ? "[data-cancel]" : "input, textarea, [data-confirm]")?.focus();
  }, [discarding, destructive]);

  const close = () => {
    dialog.current?.close();
    onClose();
  };
  const requestClose = () => {
    if (submitting.current) return;
    if (discarding) {
      setDiscarding(false);
      return;
    }
    if (fields.some((field) => values[field.name] !== (field.value ?? ""))) {
      setDiscarding(true);
      return;
    }
    close();
  };
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (submitting.current || discarding) return;
    submitting.current = true;
    setPending(true);
    setError(undefined);
    try {
      await onSubmit(values);
      close();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : uiText("Could not save. Please try again.", "保存できませんでした。再試行してください。"));
    } finally {
      submitting.current = false;
      setPending(false);
    }
  }

  const appearanceField = fields.find((field) => field.appearance);
  const displayedTitle = discarding ? uiText("Discard unsaved changes?", "未保存の変更を破棄しますか？") : title;
  const displayedDescription = discarding ? uiText("Your changes have not been saved. You can keep editing or discard this draft.", "変更はまだ保存されていません。編集を続けるか、変更を破棄してください。") : description;
  return <dialog ref={dialog} className={`action-dialog${!discarding && fields.some((field) => field.multiline) ? " action-dialog-wide" : ""}`}
    aria-labelledby={`${id}-title`} aria-describedby={displayedDescription ? `${id}-description` : undefined}
    onCancel={(event) => { event.preventDefault(); requestClose(); }}
    onClick={(event) => {
      const rect = event.currentTarget.getBoundingClientRect();
      if (event.target === event.currentTarget && (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom)) requestClose();
    }}>
    <form onSubmit={(event) => void submit(event)} aria-busy={pending}>
      <header className="dialog-header">
        <div><span className={`dialog-symbol${destructive || discarding ? " destructive" : ""}`} aria-hidden="true"><MenuIcon name={destructive || discarding ? "trash" : fields.length ? "edit" : "check"} /></span>
          <h2 id={`${id}-title`}>{displayedTitle}</h2></div>
        <button type="button" className="icon-button" aria-label={uiText("Close", "閉じる")} disabled={pending} onClick={requestClose}>×</button>
      </header>
      <div className="dialog-body">
        {displayedDescription && <p id={`${id}-description`} className="dialog-description">{displayedDescription}</p>}
        {!discarding && fields.map((field) => {
          if (field.appearance) return null;
          if (field.name === "name" && appearanceField) {
            const appearance = JSON.parse(values[appearanceField.name]!) as Appearance;
            const pickerId = `${id}-${appearanceField.name}`;
            return <div className="dialog-field" key={field.name}>
              <label htmlFor={`${id}-${field.name}`}>{field.label}</label>
              <div className="appearance-name-field">
                {appearanceField.appearance === "inherited" ? <span className="appearance-trigger" title={uiText("Inherited from parent Project", "親プロジェクトから継承")}><AppearanceIcon appearance={appearance} size={22} /></span> : <button type="button" className="appearance-trigger" popoverTarget={pickerId} disabled={pending} aria-label={uiText("Change icon and color", "アイコンと色を変更")}
                  onClick={(event) => {
                    const rect = event.currentTarget.parentElement!.getBoundingClientRect();
                    const picker = document.getElementById(pickerId)!;
                    picker.style.setProperty("--picker-top", `${rect.bottom + 6}px`);
                    picker.style.setProperty("--picker-left", `${Math.max(16, Math.min(rect.left, window.innerWidth - 304))}px`);
                  }}>
                  <AppearanceIcon appearance={appearance} size={22} />
                </button>}
                <input id={`${id}-${field.name}`} name={field.name} value={values[field.name]} required={field.required} disabled={pending}
                  onChange={(event) => setValues((current) => ({ ...current, [field.name]: event.target.value }))} />
              </div>
              {appearanceField.appearance === "editable" && <div id={pickerId} popover="auto" className="appearance-popover">
                <AppearancePicker value={appearance} disabled={pending} onChange={(next) => setValues((current) => ({ ...current, [appearanceField.name]: JSON.stringify(next) }))} />
              </div>}
            </div>;
          }
          const Control = field.multiline ? "textarea" : "input";
          return <label className="dialog-field" key={field.name}>
            {!field.hideLabel && <span>{field.label}{!field.required && <small>{uiText("Optional", "任意")}</small>}</span>}
            <Control aria-label={field.hideLabel ? field.label : undefined} name={field.name} value={values[field.name]} required={field.required}
              pattern={field.pattern} type={field.multiline ? undefined : field.type}
              rows={field.multiline ? 5 : undefined} disabled={pending}
              onChange={(event) => setValues((current) => ({ ...current, [field.name]: event.target.value }))} />
          </label>;
        })}
        {!discarding && error && <p className="dialog-error" role="alert">{error}</p>}
      </div>
      <footer className="dialog-footer">
        <span className="dialog-status" role="status">{pending ? uiText("Saving changes…", "変更を保存中…") : ""}</span>
        <button type="button" className="secondary" data-cancel disabled={pending} onClick={requestClose}>{discarding ? uiText("Keep editing", "編集を続ける") : uiText("Cancel", "キャンセル")}</button>
        {discarding ? <button type="button" className="primary destructive" data-confirm onClick={close}>{uiText("Discard changes", "変更を破棄")}</button>
          : <button className={destructive ? "primary destructive" : "primary"} data-confirm
          disabled={pending || fields.some((field) => field.required && !values[field.name]?.trim())}>
          {pending ? uiText("Please wait…", "処理中…") : confirmLabel}
        </button>}
      </footer>
    </form>
  </dialog>;
}

export function useActionDialog() {
  const [options, setOptions] = useState<ActionDialogOptions>();
  return {
    openDialog: (next: ActionDialogOptions) => {
      // Return focus to the menu's trigger rather than a now-hidden menu item.
      const menu = document.activeElement?.closest<HTMLElement>("[popover]");
      if (menu) {
        menu.hidePopover();
        document.querySelector<HTMLElement>(`[popovertarget="${menu.id}"]`)?.focus({ preventScroll: true });
      }
      setOptions(next);
    },
    dialog: options ? createPortal(<ActionDialog {...options} onClose={() => setOptions(undefined)} />, document.body) : null,
  };
}
