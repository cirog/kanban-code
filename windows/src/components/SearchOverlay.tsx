import Fuse from "fuse.js";
import { useEffect, useMemo, useRef, useState } from "react";
import { useBoardStore } from "../store/boardStore";
import type { CardDto } from "../types";

export default function SearchOverlay() {
  const { cards, setSearchOpen, selectCard } = useBoardStore();
  const [query, setQuery] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => { inputRef.current?.focus(); }, []);

  const fuse = useMemo(
    () => new Fuse(cards, {
      keys: [
        { name: "displayTitle", weight: 0.5 },
        { name: "link.promptBody", weight: 0.3 },
        { name: "projectName", weight: 0.1 },
        { name: "link.sessionLink.sessionId", weight: 0.1 },
      ],
      threshold: 0.4,
      includeScore: true,
    }),
    [cards]
  );

  const results: CardDto[] = useMemo(() => {
    if (!query.trim()) {
      return [...cards]
        .sort((a, b) => {
          const ta = a.link.lastActivity ?? a.link.updatedAt;
          const tb = b.link.lastActivity ?? b.link.updatedAt;
          return tb.localeCompare(ta);
        })
        .slice(0, 15);
    }
    return fuse.search(query).map((r) => r.item).slice(0, 15);
  }, [query, fuse, cards]);

  useEffect(() => { setSelectedIndex(0); }, [query]);

  const handleSelect = (card: CardDto) => {
    selectCard(card.id);
    setSearchOpen(false);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelectedIndex((i) => Math.min(i + 1, results.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelectedIndex((i) => Math.max(i - 1, 0));
    } else if (e.key === "Enter" && results[selectedIndex]) {
      handleSelect(results[selectedIndex]);
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center pt-[15vh] glass-overlay animate-fade-in"
      onClick={() => setSearchOpen(false)}
    >
      <div
        className="w-[520px] bg-[#141417] border border-white/10 rounded-xl shadow-2xl overflow-hidden animate-slide-up"
        onClick={(e) => e.stopPropagation()}
        onKeyDown={handleKeyDown}
      >
        {/* Input */}
        <div className="flex items-center gap-3 px-4 py-3 border-b border-white/[0.06]">
          <svg className="w-5 h-5 text-zinc-500 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="m21 21-4.35-4.35M17 11A6 6 0 1 1 5 11a6 6 0 0 1 12 0z" />
          </svg>
          <input
            ref={inputRef}
            type="text"
            placeholder="Search sessions, tasks, projects..."
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            className="flex-1 bg-transparent text-[14px] text-zinc-100 placeholder-zinc-600 outline-none"
          />
          <kbd className="text-[11px] text-zinc-600 bg-white/5 border border-white/10 px-1.5 py-0.5 rounded font-mono">
            ESC
          </kbd>
        </div>

        {/* Results */}
        <div className="overflow-y-auto max-h-[380px]">
          {results.length === 0 && query && (
            <div className="px-4 py-8 text-center text-[14px] text-zinc-500">
              No results for "{query}"
            </div>
          )}
          {results.map((card, i) => (
            <button
              key={card.id}
              onClick={() => handleSelect(card)}
              className={`w-full text-left flex items-start gap-3 px-4 py-3 transition-colors border-b border-white/[0.03] last:border-0 ${
                i === selectedIndex ? "bg-[#4f8ef7]/10" : "hover:bg-white/[0.03]"
              }`}
            >
              <div className="flex-1 min-w-0">
                <p className="text-[14px] text-zinc-200 truncate">{card.displayTitle}</p>
                <div className="flex items-center gap-2 mt-0.5">
                  {card.projectName && <span className="text-[12px] text-zinc-500">{card.projectName}</span>}
                  {card.link.worktreeLink?.branch && <span className="text-[12px] text-[#4f8ef7]">{card.link.worktreeLink.branch}</span>}
                  {card.link.prLinks[0] && <span className="text-[12px] text-[#3fb950]">PR #{card.link.prLinks[0].number}</span>}
                </div>
              </div>
              <span className="text-[11px] text-zinc-600 shrink-0 mt-0.5">{card.relativeTime}</span>
            </button>
          ))}
        </div>

        {/* Footer */}
        <div className="px-4 py-2 border-t border-white/[0.04] flex items-center gap-4 text-[11px] text-zinc-600">
          <span>↑↓ navigate</span>
          <span>↵ select</span>
          <span>ESC close</span>
          {results.length > 0 && <span className="ml-auto">{results.length} results</span>}
        </div>
      </div>
    </div>
  );
}
