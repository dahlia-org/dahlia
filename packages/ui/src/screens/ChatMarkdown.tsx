import { memo, useEffect, useRef, useState } from "react";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";

const plugins = [remarkGfm];

export const ChatMarkdown = memo(function ChatMarkdown({ content }: { content: string }) {
  return <div className="chat-markdown"><Markdown remarkPlugins={plugins} skipHtml components={{
    table: ({ children }) => <div className="chat-markdown-table"><table>{children}</table></div>,
    // Display image references without automatically fetching model-supplied URLs.
    img: ({ src, alt }) => <a href={src}>{alt || src}</a>,
    input: ({ checked }) => <input data-slot="markdown-checkbox" type="checkbox" checked={checked} disabled />,
  }}>{content}</Markdown></div>;
});

// Keep the complete stream in AiChat; coalesce only the expensive Markdown projection.
export function StreamingChatMarkdown({ content }: { content: string }) {
  const [visible, setVisible] = useState(content);
  const latest = useRef(content);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  useEffect(() => {
    latest.current = content;
    if (timer.current !== undefined) return;
    timer.current = setTimeout(() => {
      timer.current = undefined;
      setVisible(latest.current);
    }, 100);
  }, [content]);
  useEffect(() => () => { clearTimeout(timer.current); timer.current = undefined; }, []);
  return <ChatMarkdown content={visible} />;
}
