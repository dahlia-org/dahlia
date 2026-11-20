// In-window modal cards, as in Dahlia for macOS: a dimmed backdrop whose click does what Cancel or Close does.
import { useEffect, useState, type ButtonHTMLAttributes, type ReactNode } from "react";
import type { AuthState, Settings } from "../shared/types.js";
import { api, useLive } from "./capture.js";
import { errorMessage, localeName, t } from "./i18n.js";
import { XIcon } from "./icons.js";

type Variant = "primary" | "secondary" | "danger" | "plain";
const variants: Record<Variant, string> = {
  primary: "bg-primary text-white hover:bg-primary-hover active:bg-primary-pressed",
  secondary: "bg-surface text-text hover:bg-highlight",
  danger: "bg-danger text-white hover:brightness-110",
  plain: "text-text hover:bg-hover",
};

export function Button({ variant = "secondary", className = "", ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant }) {
  return (
    <button
      type="button"
      className={`inline-flex h-7 items-center justify-center gap-1.5 rounded-button px-3 text-body font-medium transition-colors disabled:pointer-events-none disabled:opacity-40 ${variants[variant]} ${className}`}
      {...props}
    />
  );
}

export function Modal({ title, onCancel, children, width = "w-[420px]" }: { title: string; onCancel?: () => void; children: ReactNode; width?: string }) {
  useEffect(() => {
    if (!onCancel) return;
    const listener = (event: KeyboardEvent) => event.key === "Escape" && onCancel();
    window.addEventListener("keydown", listener);
    return () => window.removeEventListener("keydown", listener);
  }, [onCancel]);
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-backdrop" onMouseDown={(event) => event.target === event.currentTarget && onCancel?.()}>
      <div role="dialog" aria-modal aria-label={title} className={`${width} max-w-[90vw] rounded-card bg-content p-6 shadow-2xl ring-1 ring-separator`}>
        <div className="mb-4 flex items-start justify-between gap-4">
          <h2 className="text-title2 font-semibold">{title}</h2>
          {onCancel && (
            <button type="button" aria-label={t("close")} onClick={onCancel} className="-m-1 rounded-field p-1.5 text-secondary hover:bg-hover">
              <XIcon />
            </button>
          )}
        </div>
        {children}
      </div>
    </div>
  );
}

export function SignIn({ auth, onClose }: { auth: AuthState; onClose: () => void }) {
  const [workspace, setWorkspace] = useState(auth.status === "signingIn" ? auth.workspace : "");
  const waiting = auth.status === "signingIn";
  return (
    <Modal title={t("appName")} onCancel={onClose}>
      <form
        className="flex flex-col gap-4"
        onSubmit={(event) => {
          event.preventDefault();
          if (workspace.trim()) void api.auth.signIn(workspace);
        }}
      >
        <p className="text-small text-secondary">{t("signInDescription")}</p>
        <label className="flex flex-col gap-1.5">
          <span className="text-small font-medium text-secondary">{t("workspaceURL")}</span>
          <input
            autoFocus
            className="selectable h-8 rounded-field border border-separator bg-content px-2.5 text-body outline-none focus:border-primary"
            placeholder={t("workspacePlaceholder")}
            value={workspace}
            disabled={waiting}
            onChange={(event) => setWorkspace(event.target.value)}
          />
        </label>
        {auth.status === "signedOut" && auth.error && auth.error !== "cancelled" && <p className="text-small text-danger">{errorMessage(auth.error)}</p>}
        {waiting ? (
          <div className="flex items-center justify-between gap-3">
            <span className="text-small text-secondary">{t("waitingForBrowser")}</span>
            <Button onClick={onClose}>{t("cancelSignIn")}</Button>
          </div>
        ) : (
          <Button variant="primary" type="submit" className="h-8" disabled={!workspace.trim()}>{t("signInTitle")}</Button>
        )}
      </form>
    </Modal>
  );
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex min-h-10 items-center justify-between gap-6 border-b border-separator py-2 last:border-b-0">
      <span>{label}</span>
      <div className="min-w-0 text-right text-secondary">{children}</div>
    </div>
  );
}

function Select({ value, options, onChange }: { value: string; options: { value: string; label: string }[]; onChange: (value: string) => void }) {
  return (
    <select className="h-7 max-w-64 rounded-field border border-separator bg-content px-2 text-body text-text" value={value} onChange={(event) => onChange(event.target.value)}>
      {options.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
    </select>
  );
}

const summaryLanguageOptions = [
  ["ja", "日本語"], ["en", "English"], ["zh", "中文"], ["ko", "한국어"], ["fr", "Français"], ["de", "Deutsch"], ["es", "Español"],
].map(([value, label]) => ({ value: value!, label: label! }));

export function SettingsModal({ auth, onClose }: { auth: Extract<AuthState, { status: "signedIn" }> | undefined; onClose: () => void }) {
  const settings = useLive(() => api.settings.get(), []);
  const [models, setModels] = useState<string[]>([]);
  const [locales, setLocales] = useState<string[]>([]);
  useEffect(() => {
    void api.settings.models().then(setModels);
    void api.settings.locales().then(setLocales);
  }, []);
  const update = (patch: Partial<Settings>) => void api.settings.set(patch);
  return (
    <Modal title={t("settings")} onCancel={onClose} width="w-[560px]">
      {settings && (
        <div className="flex flex-col gap-5">
          <section className="rounded-card bg-surface px-4">
            <Row label={t("account")}><span className="selectable">{auth?.email ?? t("notSignedIn")}</span></Row>
            {auth && <Row label={t("workspace")}><span className="selectable block truncate">{new URL(auth.workspace).host}</span></Row>}
          </section>
          <section className="rounded-card bg-surface px-4">
            <Row label={t("transcriptionLanguage")}>
              <Select
                value={settings.transcriptionLocale}
                options={(locales.includes(settings.transcriptionLocale) ? locales : [settings.transcriptionLocale, ...locales])
                  .map((value) => ({ value, label: `${localeName(value)} (${value})` }))}
                onChange={(value) => update({ transcriptionLocale: value })}
              />
            </Row>
            <Row label={t("summaryModel")}>
              <Select
                value={settings.summaryModel}
                options={(models.length ? models : [settings.summaryModel]).map((value) => ({ value, label: value.replace(/^system\.ai\./, "") }))}
                onChange={(value) => update({ summaryModel: value })}
              />
            </Row>
            <Row label={t("summaryLanguage")}>
              <Select value={settings.summaryLanguage} options={summaryLanguageOptions} onChange={(value) => update({ summaryLanguage: value })} />
            </Row>
          </section>
          <p className="text-small text-secondary">{t("settingsNote")}</p>
        </div>
      )}
    </Modal>
  );
}

export function ConfirmDelete({ onConfirm, onCancel }: { onConfirm: () => void; onCancel: () => void }) {
  return (
    <Modal title={t("deleteTitle")} onCancel={onCancel}>
      <p className="mb-5 text-secondary">{t("deleteMessage")}</p>
      <div className="flex justify-end gap-2">
        <Button autoFocus onClick={onCancel}>{t("cancel")}</Button>
        <Button variant="danger" onClick={onConfirm}>{t("delete")}</Button>
      </div>
    </Modal>
  );
}
