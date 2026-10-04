import { useState } from "react";
import type { AiInteraction } from "../model/ai-interaction";
import { ChatMarkdown } from "./ChatMarkdown";
import { uiText } from "../api/api";

export function ChatInteraction({ interaction, disabled, onAnswer, onPlan }: {
  interaction: AiInteraction;
  disabled: boolean;
  onAnswer: (answer: string | string[]) => void;
  onPlan: (action: "approved" | "rejected") => void;
}) {
  const [selected, setSelected] = useState<string[]>([]);
  if (interaction.tool === "submit_plan") return <section className="ai-interaction" aria-live="polite" aria-label={uiText("Plan review", "計画の確認")}>
    <h3>{interaction.title}</h3>
    <ChatMarkdown content={interaction.content} />
    <button className="secondary" disabled={disabled} onClick={() => onPlan("approved")}>{uiText("Approve plan", "計画を承認")}</button>
    <button className="secondary" disabled={disabled} onClick={() => onPlan("rejected")}>{uiText("Request changes", "変更を依頼")}</button>
  </section>;
  const multi = interaction.selectionMode === "multi_select";
  return <section className="ai-interaction" aria-live="polite" aria-label={uiText("Question", "確認事項")}>
    <p>{interaction.question}</p>
    {interaction.options?.map((option) => multi
      ? <label key={option.label}><input type="checkbox" disabled={disabled} checked={selected.includes(option.label)}
        onChange={(event) => setSelected((previous) => event.target.checked ? [...previous, option.label] : previous.filter((value) => value !== option.label))} />
        {option.label}{option.description && <span> — {option.description}</span>}</label>
      : <button className="secondary" key={option.label} disabled={disabled} onClick={() => onAnswer(option.label)}>{option.label}{option.description && <span> — {option.description}</span>}</button>)}
    {multi && <button className="secondary" disabled={disabled || !selected.length} onClick={() => onAnswer(selected)}>{uiText("Submit selections", "選択内容を送信")}</button>}
    <p>{uiText("You can also answer in the message field.", "メッセージ欄からも回答できます。")}</p>
  </section>;
}
