import { useTheme, t } from "../theme";
import type { QueuedPrompt } from "../types";

interface Props {
  prompts: QueuedPrompt[];
  onSendNow: (promptId: string) => void;
  onEdit: (prompt: QueuedPrompt) => void;
  onRemove: (promptId: string) => void;
}

export default function QueuedPromptsBar({ prompts, onSendNow, onEdit, onRemove }: Props) {
  const { theme } = useTheme();
  const c = t(theme);

  if (prompts.length === 0) return null;

  return (
    <div
      className="shrink-0 mx-2 mt-1 rounded-xl overflow-hidden"
      style={{
        background: theme === "dark" ? "rgba(255,255,255,0.03)" : "rgba(0,0,0,0.03)",
        border: `1px solid ${c.border}`,
      }}
    >
      {prompts.map((prompt, i) => (
        <div key={prompt.id}>
          {i > 0 && <div style={{ height: 1, background: c.border }} />}
          <div className="flex items-start gap-2.5 px-3 py-2">
            {/* Auto-send indicator */}
            <span
              className="shrink-0 mt-0.5 text-[13px]"
              style={{ color: prompt.sendAutomatically ? "#d29922" : c.textDim }}
              title={prompt.sendAutomatically ? "Will send automatically when Claude finishes" : "Manual send only"}
            >
              {prompt.sendAutomatically ? "\u26A1" : "\u23F8"}
            </span>

            {/* Prompt text */}
            <span
              className="flex-1 text-[12px] leading-[1.5] font-mono"
              style={{
                color: c.textSecondary,
                display: "-webkit-box",
                WebkitLineClamp: 2,
                WebkitBoxOrient: "vertical",
                overflow: "hidden",
              }}
            >
              {prompt.body}
            </span>

            {/* Actions */}
            <div className="flex items-center gap-1 shrink-0">
              <button
                onClick={() => onSendNow(prompt.id)}
                className="px-2 py-0.5 rounded-md text-[11px] font-medium transition-all duration-150"
                style={{
                  color: "#4f8ef7",
                  border: `1px solid rgba(79,142,247,0.3)`,
                }}
                onMouseEnter={(e) => { e.currentTarget.style.background = "rgba(79,142,247,0.1)"; }}
                onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
                title="Send this prompt now"
              >
                Send
              </button>
              <button
                onClick={() => onEdit(prompt)}
                className="p-1 rounded-md transition-all duration-150"
                style={{ color: c.textDim }}
                onMouseEnter={(e) => { e.currentTarget.style.color = c.textSecondary; e.currentTarget.style.background = c.hoverBg; }}
                onMouseLeave={(e) => { e.currentTarget.style.color = c.textDim; e.currentTarget.style.background = ""; }}
                title="Edit"
              >
                <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Z" />
                </svg>
              </button>
              <button
                onClick={() => onRemove(prompt.id)}
                className="p-1 rounded-md transition-all duration-150"
                style={{ color: c.textDim }}
                onMouseEnter={(e) => { e.currentTarget.style.color = "#f85149"; e.currentTarget.style.background = "rgba(248,81,73,0.06)"; }}
                onMouseLeave={(e) => { e.currentTarget.style.color = c.textDim; e.currentTarget.style.background = ""; }}
                title="Remove"
              >
                <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
                </svg>
              </button>
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}
