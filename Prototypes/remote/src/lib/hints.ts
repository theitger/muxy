// What the screen is asking for right now — read from its last lines, so
// the phone can offer the answer instead of the keys to type it.

export type Choice = { label: string; selected: boolean }

export type Hint =
  | { kind: 'menu'; question: string | null; choices: Choice[] }
  | { kind: 'yesno'; question: string }
  | null

const BORDER = /[│┃╭╮╰╯─]/g
const CURSOR = /^(❯|›|>|▶︎?|→)\s+/

/**
 * A pick list at the bottom of the screen — Claude Code's permission and
 * question dialogs, its trust prompt, most CLI pickers: one line marked
 * with a cursor (❯), its siblings indented to the same column, numbered
 * or not. Or a `[y/N]` prompt.
 */
export function readHint(text: string | undefined): Hint {
  if (!text) return null
  const lines = text.split('\n').slice(-30).map((l) => l.replace(BORDER, ' ').replace(/\s+$/, ''))

  for (let i = lines.length - 1; i >= 0; i--) {
    const marked = lines[i].match(/^(\s*)(❯|›|▶︎?)\s+(\S.*)$/)
    if (!marked) continue
    // Siblings' text starts in the column where the marked line's text does.
    const column = lines[i].indexOf(marked[3])
    const item = (line: string) => {
      const m = line.match(/^(\s*)(\S.*)$/)
      if (!m) return null
      return Math.abs(m[1].length - column) <= 1 && !CURSOR.test(m[2]) ? m[2] : null
    }
    const above: string[] = []
    for (let j = i - 1; j >= 0 && item(lines[j]); j--) above.unshift(item(lines[j])!)
    const below: string[] = []
    for (let j = i + 1; j < lines.length && item(lines[j]); j++) below.push(item(lines[j])!)
    const choices: Choice[] = [
      ...above.map((l) => ({ label: tidy(l), selected: false })),
      { label: tidy(marked[3]), selected: true },
      ...below.map((l) => ({ label: tidy(l), selected: false })),
    ]
    if (choices.length < 2 || choices.length > 9) return null
    const start = i - above.length
    return { kind: 'menu', question: questionAbove(lines, start - 1), choices }
  }

  const last = lines.filter((l) => l.trim()).at(-1) ?? ''
  if (/\[(y\/n|yes\/no)\]\s*:?\s*$/i.test(last)) {
    return { kind: 'yesno', question: last.replace(/\s*\[(y\/n|yes\/no)\].*$/i, '').trim() }
  }
  return null
}

/** "2. Yes, and don't ask again" → "Yes, and don't ask again". */
function tidy(label: string) {
  return label.replace(/^\d[.)]\s+/, '').replace(/\s{2,}/g, ' ').trim()
}

function questionAbove(lines: string[], from: number) {
  for (let i = from; i >= Math.max(0, from - 4); i--) {
    const t = lines[i].trim()
    if (!t) continue
    return /[?:]$/.test(t) ? t : null
  }
  return null
}

/** Keys that move the cursor from the marked choice to `target`, then pick it. */
export function keysFor(choices: Choice[], target: number): ('up' | 'down' | 'enter')[] {
  const at = choices.findIndex((c) => c.selected)
  const delta = target - at
  return [...Array(Math.abs(delta)).fill(delta > 0 ? 'down' : 'up'), 'enter']
}
