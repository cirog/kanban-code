import { useEffect, useRef, useState } from "react";
import { getSettings, useBoardStore } from "../store/boardStore";

export default function NewTaskDialog() {
  const { createCard, setNewTaskOpen, selectCard, cards } = useBoardStore();
  const [prompt, setPrompt] = useState("");
  const [title, setTitle] = useState("");
  const [project, setProject] = useState("");
  const [launch, setLaunch] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [settingsProjects, setSettingsProjects] = useState<string[]>([]);
  const promptRef = useRef<HTMLTextAreaElement>(null);

  const cardProjects = [
    ...new Set(
      cards
        .map((c) => c.link.projectPath ?? c.session?.projectPath)
        .filter(Boolean) as string[]
    ),
  ];

  // Merge settings projects + card projects, deduplicated
  const projects = [...new Set([...settingsProjects, ...cardProjects])].slice(0, 30);

  useEffect(() => {
    promptRef.current?.focus();
    getSettings()
      .then((s) => {
        const paths = s.projects.map((p) => p.path).filter(Boolean);
        setSettingsProjects(paths);
        if (!project && paths.length > 0) {
          setProject(paths[0]);
        }
      })
      .catch(console.error);
    if (cardProjects.length > 0 && !project) {
      setProject(cardProjects[0]);
    }
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!prompt.trim()) return;
    setSubmitting(true);
    try {
      const cardId = await createCard(prompt.trim(), title.trim() || null, project || ".", launch);
      setNewTaskOpen(false);
      if (launch && cardId) {
        // Auto-select the card so the drawer opens with embedded terminal
        selectCard(cardId);
      }
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center glass-overlay animate-fade-in"
      onClick={() => setNewTaskOpen(false)}
    >
      <div
        className="w-[520px] bg-[#141417] border border-white/10 rounded-xl shadow-2xl animate-slide-up"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b border-white/[0.06]">
          <h2 className="text-[16px] font-semibold text-zinc-100">New Task</h2>
          <button
            onClick={() => setNewTaskOpen(false)}
            className="text-zinc-500 hover:text-zinc-300 transition-colors"
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <form onSubmit={handleSubmit} className="px-5 py-5 flex flex-col gap-5">
          {/* Prompt */}
          <div>
            <label className="block text-[13px] font-medium text-zinc-300 mb-2">
              Prompt
            </label>
            <textarea
              ref={promptRef}
              rows={4}
              placeholder="Describe the task for Claude..."
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              className="w-full bg-[#0a0a0c] border border-white/10 focus:border-[#4f8ef7]/50 rounded-lg px-3.5 py-3 text-[14px] text-zinc-100 placeholder-zinc-600 outline-none resize-none transition-colors leading-relaxed"
            />
          </div>

          {/* Title */}
          <div>
            <label className="block text-[13px] font-medium text-zinc-300 mb-2">
              Title <span className="text-zinc-600 font-normal">(optional)</span>
            </label>
            <input
              type="text"
              placeholder="Short title for the board card"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              className="w-full bg-[#0a0a0c] border border-white/10 focus:border-[#4f8ef7]/50 rounded-lg px-3.5 py-2.5 text-[14px] text-zinc-100 placeholder-zinc-600 outline-none transition-colors"
            />
          </div>

          {/* Project */}
          <div>
            <label className="block text-[13px] font-medium text-zinc-300 mb-2">
              Project
            </label>
            {projects.length > 0 ? (
              <select
                value={project}
                onChange={(e) => setProject(e.target.value)}
                className="w-full bg-[#0a0a0c] border border-white/10 focus:border-[#4f8ef7]/50 rounded-lg px-3.5 py-2.5 text-[14px] text-zinc-100 outline-none transition-colors"
              >
                {projects.map((p) => (
                  <option key={p} value={p}>
                    {p.split(/[/\\]/).pop() ?? p}
                  </option>
                ))}
              </select>
            ) : (
              <input
                type="text"
                placeholder="C:\path\to\project"
                value={project}
                onChange={(e) => setProject(e.target.value)}
                className="w-full bg-[#0a0a0c] border border-white/10 focus:border-[#4f8ef7]/50 rounded-lg px-3.5 py-2.5 text-[14px] text-zinc-100 placeholder-zinc-600 outline-none transition-colors"
              />
            )}
          </div>

          {/* Launch toggle */}
          <label className="flex items-center gap-3 cursor-pointer select-none">
            <input
              type="checkbox"
              checked={launch}
              onChange={(e) => setLaunch(e.target.checked)}
              className="w-4 h-4 rounded accent-[#4f8ef7] bg-[#0a0a0c] border-white/10"
            />
            <span className="text-[13px] text-zinc-300">Start immediately in terminal</span>
          </label>

          {/* Buttons */}
          <div className="flex gap-3 pt-1">
            <button
              type="button"
              onClick={() => setNewTaskOpen(false)}
              className="flex-1 py-2.5 rounded-lg border border-white/10 text-[13px] text-zinc-400 hover:text-zinc-200 hover:bg-white/5 transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={!prompt.trim() || submitting}
              className="flex-1 py-2.5 rounded-lg bg-[#4f8ef7] hover:bg-[#5b97fa] disabled:opacity-40 text-white text-[13px] font-semibold transition-colors"
            >
              {submitting ? "Creating..." : launch ? "Create & Start" : "Create Task"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
