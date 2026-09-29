import { memo } from "react";
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
