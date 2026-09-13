// Open /tests/browser/select.html under pnpm dev:client. Uses no backend.
import { createRoot } from "react-dom/client";
import { useState } from "react";
import { Select } from "../../src/client/Select";
import "../../src/client/styles.css";
function Fixture() {
  const [value, setValue] = useState("a");
  return <dialog open><label>Choice<Select value={value} onValueChange={setValue}>
    <option value="a"><svg aria-hidden="true" width="16" height="16"><circle cx="8" cy="8" r="6" /></svg><span>Alpha</span></option><option value="disabled" disabled>Blocked</option><option value="b">Beta</option>
  </Select></label><fieldset disabled><label>Disabled<Select value="a" onValueChange={() => { throw Error("Disabled changed"); }}><option value="a">Alpha</option></Select></label></fieldset><button>After</button><Select aria-label="Destination" value="" placeholder="Choose a Workspace" menuLabel="Workspaces" onValueChange={() => {}}><option value="target">Target</option></Select></dialog>;
}
const assert = (value: unknown, message: string) => { if (!value) throw Error(message); };
const frame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
const key = (value: string) => document.activeElement?.dispatchEvent(new KeyboardEvent("keydown", { key: value, bubbles: true, cancelable: true }));
async function run() {
  createRoot(document.getElementById("root")!).render(<Fixture />);
  for (let n = 0; n < 10 && !document.querySelector('[role="listbox"]'); n++) await frame();
  const dialog = document.querySelector("dialog")!;
  dialog.close(); dialog.showModal();
  const trigger = document.querySelector<HTMLButtonElement>('[role="combobox"]')!;
  assert(document.querySelector('fieldset button')?.matches(":disabled"), "fieldset disabled state lost");
  trigger.click(); await frame(); await frame();
  const menuRect = document.querySelector('[role="listbox"]')!.getBoundingClientRect();
  assert(Math.abs(menuRect.left - trigger.getBoundingClientRect().left) < 1, "menu is not left-aligned with trigger");
  assert(menuRect.left >= 12 && menuRect.right <= innerWidth - 12, "menu overflowed viewport");
  assert(document.activeElement?.textContent?.startsWith("Alpha"), "selected option not focused");
  assert(dialog.contains(document.querySelector('[role="listbox"]')), "menu escaped modal dialog");
  key("ArrowDown"); assert(document.activeElement?.textContent === "Beta", "disabled option not skipped");
  (document.activeElement as HTMLButtonElement).click(); await frame();
  assert(trigger.value === "b", "selection not committed");
  trigger.click(); await frame(); await frame(); key("Home"); key("Escape"); await frame();
  assert(trigger.value === "b" && document.activeElement === trigger, "Escape changed selection or lost focus");
  trigger.click(); await frame(); await frame(); key("a");
  assert(document.activeElement?.textContent?.startsWith("Alpha"), "typeahead failed");
  key("Escape");
  const destination = document.querySelector<HTMLButtonElement>('[aria-label="Destination"]')!;
  destination.click(); await frame(); await frame();
  const popup = document.getElementById(destination.getAttribute("aria-controls")!)!;
  assert(popup.querySelector("strong")?.textContent === "Workspaces", "menu label missing");
  assert(popup.querySelectorAll('[role="option"]').length === 1, "placeholder became an option");
  assert(document.querySelector('[role="option"] svg'), "option icon missing");
  key("Escape");
  document.getElementById("result")!.textContent = "PASS: modal, disabled fieldset, selection, arrow keys, disabled option, Home, Escape, focus, typeahead";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
