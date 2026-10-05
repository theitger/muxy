import { ArrowUp, Check, ChevronDown, Copy, CornerDownLeft, Folder, GitBranch, History, RotateCw, Sparkles } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'
import { Key } from '@/components/muxy'
import { suggestions, type Block, type Tab } from '@/data'

type ShellTab = Extract<Tab, { kind: 'shell' }>

const LIVE = ['htop', 'top', 'vim', 'less']

/**
 * The shell as it looks in the Ghostty window — same font, colors and
 * starship prompt — but every command is a block you can tap: collapse,
 * copy, rerun, jump to the first error. Output is text that reflows, so
 * the Mac keeps its width. Full-screen programs switch to the live grid.
 */
export function ShellView({
  tab,
  branch,
  onRun,
  onAnswer,
}: {
  tab: ShellTab
  branch: string
  onRun: (command: string) => void
  onAnswer: (blockId: string, choice: string) => void
}) {
  const [draft, setDraft] = useState('')
  const [live, setLive] = useState<string | null>(null)
  const [selected, setSelected] = useState<string | null>(null)
  const end = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLInputElement>(null)
  const last = tab.blocks[tab.blocks.length - 1]

  useEffect(() => {
    end.current?.scrollIntoView({ block: 'end' })
  }, [tab.blocks.length, last?.exit])

  function run(command: string) {
    const c = command.trim()
    if (!c) return
    setDraft('')
    setSelected(null)
    if (LIVE.includes(c.split(' ')[0])) {
      setLive(c)
      return
    }
    onRun(c)
  }

  if (live) {
    return (
      <LiveTerminal
        command={live}
        onExit={() => {
          onRun(`__live:${live}`)
          setLive(null)
        }}
      />
    )
  }

  const asking = last?.ask && last.exit === null ? last : null
  const busy = last && last.exit === null && !asking

  // What the line suggests depends on what's typed — all known on the Mac.
  const chips: { text: string; icon: typeof History; fill?: boolean }[] = draft.startsWith('git checkout ')
    ? suggestions.branches.map((b) => ({ text: `git checkout ${b}`, icon: GitBranch }))
    : draft.startsWith('cd')
      ? suggestions.folders.map((f) => ({ text: `cd ${f}`, icon: Folder }))
      : [
          ...suggestions.history.map((h) => ({ text: h, icon: History })),
          ...suggestions.scripts.map((s) => ({ text: s, icon: Sparkles })),
          { text: 'cd ', icon: Folder, fill: true },
          { text: 'git checkout ', icon: GitBranch, fill: true },
        ].filter((c) => !draft || c.text.startsWith(draft))

  return (
    <div className="flex min-h-0 flex-1 flex-col bg-bg">
      <div
        className="flex-1 overflow-y-auto px-4 pt-4 pb-2 font-mono text-[13px] leading-[1.38] text-term"
        onClick={(e) => {
          if (e.target === e.currentTarget) setSelected(null)
        }}
      >
        {tab.blocks.map((b, i) => (
          <TermBlock
            key={b.id}
            block={b}
            prev={tab.blocks[i - 1]}
            cwd={tab.cwd}
            branch={branch}
            gitStatus={tab.gitStatus}
            selected={selected === b.id}
            onSelect={() => setSelected(selected === b.id ? null : b.id)}
            onRerun={() => run(b.command)}
          />
        ))}
        <div ref={end} />
      </div>

      <div className="border-t border-hair bg-bg pt-2 pb-[calc(env(safe-area-inset-bottom,0px)+8px)]">
        {asking ? (
          <div className="grid grid-cols-2 gap-2 px-4 pb-2">
            {asking.ask!.choices.map((c) => (
              <button
                key={c}
                type="button"
                onClick={() => onAnswer(asking.id, c)}
                className={cn(
                  'h-11 rounded-xl font-mono text-[15px] font-bold',
                  c === 'y' ? 'bg-t1 text-bg' : 'border border-hair bg-raised text-t1',
                )}
              >
                {c}
              </button>
            ))}
          </div>
        ) : (
          <div className="mb-2 flex gap-1.5 overflow-x-auto px-4">
            {chips.slice(0, 9).map((c) => (
              <button
                key={c.text}
                type="button"
                onClick={() => {
                  if (c.fill) {
                    setDraft(c.text)
                    input.current?.focus()
                  } else run(c.text)
                }}
                className="flex shrink-0 items-center gap-1.5 rounded-lg border border-hair px-2.5 py-1.5 font-mono text-[12.5px] text-t2 active:bg-active"
              >
                <c.icon className="size-3.5 text-t4" />
                {c.text.trim()}
              </button>
            ))}
          </div>
        )}

        {/* The live prompt: starship's line, then → and what you type. */}
        <div className="px-4 font-mono text-[13px] leading-[1.38]" onClick={() => input.current?.focus()}>
          <PromptLine cwd={tab.cwd} branch={branch} gitStatus={tab.gitStatus} prev={last} />
          <form
            className="flex items-center"
            onSubmit={(e) => {
              e.preventDefault()
              run(draft)
            }}
          >
            <span className={cn('font-bold', last && last.exit !== null && last.exit !== 0 ? 'text-ss-error' : 'text-ss-char')}>
              →&nbsp;
            </span>
            <input
              ref={input}
              id={`cmd-${tab.id}`}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              disabled={!!asking || !!busy}
              autoCapitalize="off"
              autoCorrect="off"
              autoComplete="off"
              spellCheck={false}
              enterKeyHint="go"
              placeholder={busy ? 'läuft …' : ''}
              className="h-9 min-w-0 flex-1 bg-transparent text-[16px] text-term caret-term outline-none placeholder:text-t4 disabled:opacity-60"
            />
            <button
              type="submit"
              aria-label="Ausführen"
              disabled={!draft.trim()}
              className="ml-2 grid size-9 shrink-0 place-items-center rounded-lg bg-t1 text-bg disabled:opacity-20"
            >
              <CornerDownLeft className="size-4" />
            </button>
          </form>
        </div>
      </div>
    </div>
  )
}

/** starship.toml: directory, git_branch, git_status, cmd_duration — time right. */
function PromptLine({
  cwd,
  branch,
  gitStatus,
  prev,
  time,
}: {
  cwd: string
  branch: string
  gitStatus: string
  prev?: Block
  time?: string
}) {
  const duration = prev && prev.exit !== null && prev.ms >= 2000 ? `${Math.floor(prev.ms / 1000)}s` : ''
  const now = time ?? new Date().toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit' })
  return (
    <div className="flex items-baseline gap-2">
      <div className="min-w-0 flex-1 break-words">
        <span className="text-ss-dir">{cwd}</span>{' '}
        {branch && <span className="text-ss-branch">{branch} </span>}
        {gitStatus && <span className="text-ss-status">{gitStatus}</span>}
        {duration && <span className="text-ss-duration">{duration}</span>}
      </div>
      <span className="shrink-0 text-ss-status">{now}</span>
    </div>
  )
}

function lineTone(line: string) {
  if (/^(---\s)?FAIL|error|Error|✕/.test(line.trim()) || /\bFAIL\b/.test(line)) return 'text-ansi-red'
  if (/_test\.go:\d+/.test(line)) return 'text-ansi-red'
  if (/^ok\s|✓|ready in|passed/.test(line.trim())) return 'text-ansi-green'
  if (/➜/.test(line)) return 'text-ansi-cyan'
  return ''
}

function TermBlock({
  block,
  prev,
  cwd,
  branch,
  gitStatus,
  selected,
  onSelect,
  onRerun,
}: {
  block: Block
  prev?: Block
  cwd: string
  branch: string
  gitStatus: string
  selected: boolean
  onSelect: () => void
  onRerun: () => void
}) {
  const failed = block.exit !== null && block.exit !== 0
  const [collapsed, setCollapsed] = useState(false)
  const [copied, setCopied] = useState(false)
  const firstError = block.output.findIndex((l) => lineTone(l) === 'text-ansi-red')
  const errorRef = useRef<HTMLDivElement>(null)
  const prevFailed = prev && prev.exit !== null && prev.exit !== 0

  return (
    <section
      className={cn(
        'relative -mx-4 px-4 py-1 transition-colors',
        selected && 'bg-hover',
      )}
    >
      {/* Gutter mark: the only thing a plain terminal doesn't have. */}
      {(failed || block.exit === null) && (
        <span
          aria-hidden
          className={cn(
            'absolute top-1.5 bottom-1.5 left-1.5 w-[3px] rounded-full',
            failed ? 'bg-ansi-red' : block.ask ? 'bg-tone-orange' : 'bg-tone-blue pulse-soft',
          )}
        />
      )}
      <button type="button" onClick={onSelect} className="block w-full text-left" aria-expanded={selected}>
        <PromptLine cwd={cwd} branch={branch} gitStatus={gitStatus} prev={prev} time={block.time} />
        <div className="break-all">
          <span className={cn('font-bold', prevFailed ? 'text-ss-error' : 'text-ss-char')}>→ </span>
          {block.command}
        </div>
      </button>

      {collapsed ? (
        <button type="button" onClick={() => setCollapsed(false)} className="text-ansi-dim">
          … {block.output.length} Zeilen
        </button>
      ) : (
        block.output.map((l, i) => (
          <div
            key={i}
            ref={i === firstError ? errorRef : undefined}
            className={cn('break-words whitespace-pre-wrap', lineTone(l))}
          >
            {l || '\u00a0'}
          </div>
        ))
      )}
      {block.ask && block.exit === null && (
        <div>
          {block.ask.question} <span className="caret inline-block h-[1.1em] w-[0.55em] translate-y-[0.15em] bg-term" />
        </div>
      )}
      {block.exit === null && !block.ask && (
        <span className="caret inline-block h-[1.1em] w-[0.55em] translate-y-[0.15em] bg-term" />
      )}

      {selected && (
        <div className="mt-1.5 mb-1 flex flex-wrap gap-1.5 font-sans">
          {block.output.length > 2 && (
            <BlockAction onClick={() => setCollapsed(!collapsed)}>
              <ChevronDown className={cn('size-3.5', !collapsed && 'rotate-180')} />
              {collapsed ? 'Ausklappen' : 'Einklappen'}
            </BlockAction>
          )}
          {failed && firstError >= 0 && (
            <BlockAction
              danger
              onClick={() => {
                setCollapsed(false)
                setTimeout(() => errorRef.current?.scrollIntoView({ block: 'center', behavior: 'smooth' }), 30)
              }}
            >
              Zum Fehler
            </BlockAction>
          )}
          <BlockAction
            onClick={() => {
              navigator.clipboard?.writeText(block.output.join('\n')).catch(() => {})
              setCopied(true)
              setTimeout(() => setCopied(false), 1200)
            }}
          >
            {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
            Kopieren
          </BlockAction>
          {block.exit !== null && (
            <BlockAction onClick={onRerun}>
              <RotateCw className="size-3.5" />
              Nochmal
            </BlockAction>
          )}
        </div>
      )}
    </section>
  )
}

function BlockAction({ children, onClick, danger }: { children: React.ReactNode; onClick: () => void; danger?: boolean }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        'flex h-8 items-center gap-1 rounded-lg border border-hair bg-raised px-2.5 text-[12.5px] font-medium active:bg-active',
        danger ? 'text-tone-red' : 'text-t2',
      )}
    >
      {children}
    </button>
  )
}

/* ---------- Live: the real grid, for full-screen programs ---------- */

const PROCS = [
  ['31337', 'theitger', '38.2', '2.1', 'claude'],
  ['48211', 'theitger', '21.7', '4.8', 'node vite'],
  ['912', 'theitger', '12.4', '1.2', 'Muxy'],
  ['5120', 'theitger', '6.9', '9.6', 'postgres'],
  ['77', 'root', '3.1', '0.4', 'WindowServer'],
  ['48890', 'theitger', '2.2', '0.9', 'go test'],
  ['301', 'theitger', '0.8', '0.3', 'zsh'],
  ['288', 'theitger', '0.3', '0.2', 'gh'],
]

function bar(pct: number, width = 18) {
  const n = Math.round((pct / 100) * width)
  return { on: '|'.repeat(n), off: ' '.repeat(width - n) }
}

function LiveTerminal({ command, onExit }: { command: string; onExit: () => void }) {
  const [row, setRow] = useState(0)
  const [trail, setTrail] = useState<string[]>([])
  const [ctrl, setCtrl] = useState(false)
  const [tick, setTick] = useState(0)
  const pad = useRef<{ x: number; y: number } | null>(null)

  useEffect(() => {
    const t = setInterval(() => setTick((n) => n + 1), 1500)
    return () => clearInterval(t)
  }, [])

  function press(k: string) {
    setTrail((t) => [...t.slice(-5), k])
    if (k === '↓') setRow((r) => Math.min(PROCS.length - 1, r + 1))
    if (k === '↑') setRow((r) => Math.max(0, r - 1))
    if (k === 'q' || (ctrl && k === 'c') || k === '^C') onExit()
    if (ctrl) setCtrl(false)
  }

  const cpu = [62 + (tick % 3) * 7, 41 + (tick % 4) * 5, 28 + (tick % 2) * 9, 17]

  return (
    <div className="flex min-h-0 flex-1 flex-col bg-bg">
      <div className="flex items-center gap-2 border-b border-hair bg-tone-blue-soft px-3 py-1.5 text-[12px] text-tone-blue">
        <span className="size-1.5 rounded-full bg-current pulse-soft" />
        <span className="font-medium">Live · {command}</span>
        <span className="text-tone-blue/70">Mac läuft gerade auf 46 Spalten</span>
      </div>

      <div className="flex-1 overflow-auto px-2.5 py-2 font-mono text-[11.5px] leading-[1.42] whitespace-pre text-t2">
        {cpu.map((c, i) => {
          const b = bar(c)
          return (
            <div key={i}>
              <span className="text-ansi-cyan">{i}</span>[<span className="text-ansi-green">{b.on.slice(0, 10)}</span>
              <span className="text-ansi-red">{b.on.slice(10)}</span>
              {b.off}
              <span className="text-t4">{String(c).padStart(4)}%</span>]
            </div>
          )
        })}
        <div>
          <span className="text-ansi-cyan">Mem</span>[<span className="text-ansi-green">||||||||||</span>
          <span className="text-ansi-blue">||||</span>
          {'    '}
          <span className="text-t4">11.2G/32G</span>]
        </div>
        <div className="mt-1 text-t4">Tasks: 412 · Load: 2.31 1.98 1.77</div>
        <div className="mt-1 bg-ansi-green px-0.5 text-bg">{'  PID USER       CPU%  MEM% COMMAND        '}</div>
        {PROCS.map((p, i) => (
          <div key={p[0]} className={cn('px-0.5', i === row && 'bg-ansi-cyan text-bg')}>
            {p[0].padStart(5)} {p[1].padEnd(9)} {p[2].padStart(5)} {p[3].padStart(5)} {p[4]}
          </div>
        ))}
        <div className="mt-2">
          <span className="bg-ansi-cyan px-0.5 text-bg">F9</span>Kill <span className="bg-ansi-cyan px-0.5 text-bg">F10</span>Quit{' '}
          <span className="bg-ansi-cyan px-0.5 text-bg">q</span>Quit
        </div>
      </div>

      <div className="border-t border-hair bg-surface px-3 pt-2 pb-[calc(env(safe-area-inset-bottom,0px)+8px)]">
        <div
          className="mb-2 flex h-14 touch-none items-center justify-center rounded-xl border border-dashed border-hair bg-raised text-[12.5px] text-t4 select-none"
          onPointerDown={(e) => (pad.current = { x: e.clientX, y: e.clientY })}
          onPointerMove={(e) => {
            if (!pad.current) return
            const dx = e.clientX - pad.current.x
            const dy = e.clientY - pad.current.y
            if (Math.abs(dx) < 22 && Math.abs(dy) < 22) return
            press(Math.abs(dy) > Math.abs(dx) ? (dy > 0 ? '↓' : '↑') : dx > 0 ? '→' : '←')
            pad.current = { x: e.clientX, y: e.clientY }
          }}
          onPointerUp={() => (pad.current = null)}
          onPointerCancel={() => (pad.current = null)}
        >
          {trail.length ? <span className="font-mono text-[15px] text-t2">{trail.join(' ')}</span> : 'Hier wischen = Pfeiltasten'}
        </div>
        <div className="flex gap-1.5 overflow-x-auto">
          <Key wide onPress={() => press('esc')}>esc</Key>
          <Key wide onPress={() => press('tab')}>tab</Key>
          <Key wide active={ctrl} onPress={() => setCtrl(!ctrl)} label="Control">
            ctrl
          </Key>
          <Key onPress={() => press('^C')}>^C</Key>
          <Key onPress={() => press('q')}>q</Key>
          <Key onPress={() => press('/')}>/</Key>
          <Key onPress={() => press('↑')}>
            <ArrowUp className="size-4" />
          </Key>
          <Key onPress={() => press('↓')}>
            <ArrowUp className="size-4 rotate-180" />
          </Key>
        </div>
        <p className="mt-1.5 text-center text-[11.5px] text-t4">q oder ^C beendet htop → zurück zu den Blöcken</p>
      </div>
    </div>
  )
}
