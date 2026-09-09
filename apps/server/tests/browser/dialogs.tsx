// pnpm dev:client -> /tests/browser/dialogs.html. No backend is contacted.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { useActionDialog } from "../../src/client/ActionDialog";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
let submissions = 0;
let shouldFail = false;
let release: (() => void) | undefined;
let saved: Record<string, string> | undefined;

function Fixture() {
  const { dialog, openDialog } = useActionDialog();
  return <main className="workspace">
    <button id="edit" className="secondary" onClick={() => openDialog({
      title: "Edit meeting", confirmLabel: "Save changes",
      fields: [{ name: "name", label: "Meeting name", value: "Original", required: true }, { name: "description", label: "Description", multiline: true }],
      onSubmit: async (values) => {
        submissions++;
        await new Promise<void>((resolve) => { release = resolve; });
        if (shouldFail) throw new Error("Unable to save. Please try again.");
        saved = values;
      },
    })}>Edit meeting</button>
    <button id="delete" className="secondary" onClick={() => openDialog({
      title: "Delete summary?", description: "All summary versions will be deleted. The meeting will remain.",
      confirmLabel: "Delete summary", destructive: true, onSubmit: () => { submissions++; return Promise.resolve(); },
    })}>Delete summary</button>
    {dialog}
  </main>;
}

function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
async function until(predicate: () => unknown) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    if (performance.now() > deadline) throw new Error("Timed out waiting for dialog");
    await new Promise(requestAnimationFrame);
  }
}
const modal = () => document.querySelector<HTMLDialogElement>(".action-dialog")!;
const confirm = () => modal().querySelector<HTMLButtonElement>("[data-confirm]")!;
function fill(selector: string, value: string) {
  const input = modal().querySelector<HTMLInputElement | HTMLTextAreaElement>(selector)!;
  const prototype = input instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

async function run() {
  createRoot(document.getElementById("root")!).render(<StrictMode><Fixture /></StrictMode>);
  await until(() => document.getElementById("edit"));
  const edit = document.getElementById("edit")!;
  edit.focus(); edit.click();
  await until(() => modal()?.matches(":modal"));
  assert(document.activeElement === modal().querySelector("input"), "Editor did not focus the name");
  fill("input", "   ");
  await until(() => confirm().disabled);
  fill("input", "Changed title"); fill("textarea", "Line one\nLine two");
  await until(() => !confirm().disabled);
  // Clicking the card itself must not dismiss a draft.
  const rect = modal().getBoundingClientRect();
  modal().dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: rect.left + 4, clientY: rect.top + 4 }));
  assert(modal(), "Clicking dialog padding dismissed the editor");
  shouldFail = true;
  confirm().click(); confirm().click();
  await until(() => Boolean(release));
  assert(submissions === 1, "Double click submitted twice");
  assert(modal().querySelector<HTMLButtonElement>("[data-cancel]")!.disabled, "Cancel remained enabled during save");
  modal().dispatchEvent(new Event("cancel", { cancelable: true }));
  assert(modal()?.matches(":modal"), "Escape dismissed an in-flight operation");
  modal().dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: 0, clientY: 0 }));
  assert(modal(), "Backdrop dismissed an in-flight operation");
  release!();
  await until(() => modal().querySelector('[role="alert"]'));
  assert(modal().querySelector<HTMLInputElement>("input")!.value === "Changed title", "Failure discarded the name");
  assert(modal().querySelector<HTMLTextAreaElement>("textarea")!.value === "Line one\nLine two", "Failure discarded multiline text");
  shouldFail = false; release = undefined;
  confirm().click(); await until(() => Boolean(release)); release!();
  await until(() => !modal());
  assert(saved?.name === "Changed title" && saved.description === "Line one\nLine two", "Retry saved the wrong draft");
  assert(document.activeElement === edit, "Closing editor did not restore focus");
  const remove = document.getElementById("delete")!;
  remove.focus(); remove.click();
  await until(() => modal()?.matches(":modal"));
  assert(document.activeElement === modal().querySelector("[data-cancel]"), "Destructive action received initial focus");
  const before = submissions;
  modal().dispatchEvent(new Event("cancel", { cancelable: true }));
  await until(() => !modal());
  assert(submissions === before && document.activeElement === remove, "Cancel submitted or lost focus");
  remove.click(); await until(() => modal()?.matches(":modal"));
  modal().dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: 0, clientY: 0 }));
  await until(() => !modal());
  assert(submissions === before, "Backdrop submitted a destructive action");
  edit.click(); await until(() => modal()?.matches(":modal"));
  fill("input", "Unfinished draft");
  await new Promise(requestAnimationFrame);
  modal().dispatchEvent(new Event("cancel", { cancelable: true }));
  await until(() => modal().textContent?.includes("Discard unsaved changes?"));
  assert(document.activeElement === modal().querySelector("[data-cancel]"), "Discard received initial focus");
  modal().querySelector<HTMLButtonElement>("[data-cancel]")!.click();
  await until(() => modal().querySelector<HTMLInputElement>("input")?.value === "Unfinished draft");
  modal().querySelector<HTMLButtonElement>("[data-cancel]")!.click();
  await until(() => modal().textContent?.includes("Discard unsaved changes?"));
  confirm().click(); await until(() => !modal());
  assert(submissions === before, "Discard saved a draft");
  document.body.dataset.testResult = "passed";
  console.log("PASS: modal focus, validation, pending cancellation, duplicate submission, multiline drafts, retry, destructive default and backdrop");
}
void run().catch((error: unknown) => { document.body.dataset.testResult = "failed"; document.body.dataset.testError = String(error); console.error(error); });
