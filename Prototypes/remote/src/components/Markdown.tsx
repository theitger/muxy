import { Fragment, memo, type ReactNode } from 'react'

type Block =
  | { kind: 'p'; text: string }
  | { kind: 'h'; level: number; text: string }
  | { kind: 'code'; lang: string; text: string }
  | { kind: 'list'; ordered: boolean; start: number; items: string[] }
  | { kind: 'quote'; text: string }
  | { kind: 'table'; head: string[]; rows: string[][] }
  | { kind: 'rule' }

const LIST = /^(\s*)([-*+]|\d{1,3}[.)])\s+(.*)$/

/** The markdown agents write, as blocks. Not CommonMark; what they use. */
export function parse(source: string): Block[] {
  const lines = source.replace(/\r\n/g, '\n').split('\n')
  const blocks: Block[] = []
  let i = 0
  while (i < lines.length) {
    const line = lines[i]
    const fence = line.match(/^\s*(```|~~~)\s*([\w+-]*)/)
    if (fence) {
      const body: string[] = []
      i++
      while (i < lines.length && !lines[i].trim().startsWith(fence[1])) body.push(lines[i++])
      i++
      blocks.push({ kind: 'code', lang: fence[2], text: body.join('\n') })
      continue
    }
    if (!line.trim()) {
      i++
      continue
    }
    const heading = line.match(/^(#{1,6})\s+(.*)$/)
    if (heading) {
      blocks.push({ kind: 'h', level: heading[1].length, text: heading[2] })
      i++
      continue
    }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) {
      blocks.push({ kind: 'rule' })
      i++
      continue
    }
    if (line.trim().startsWith('|') && i + 1 < lines.length && /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(lines[i + 1])) {
      const cells = (l: string) => l.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim())
      const head = cells(line)
      i += 2
      const rows: string[][] = []
      while (i < lines.length && lines[i].trim().startsWith('|')) rows.push(cells(lines[i++]))
      blocks.push({ kind: 'table', head, rows })
      continue
    }
    if (line.startsWith('>')) {
      const body: string[] = []
      while (i < lines.length && lines[i].startsWith('>')) body.push(lines[i++].replace(/^>\s?/, ''))
      blocks.push({ kind: 'quote', text: body.join('\n') })
      continue
    }
    const item = line.match(LIST)
    if (item) {
      const ordered = /\d/.test(item[2])
      const items: string[] = []
      const indent = item[1].length
      while (i < lines.length) {
        const m = lines[i].match(LIST)
        if (m && m[1].length <= indent + 1 && /\d/.test(m[2]) === ordered) {
          items.push(m[3])
          i++
        } else if (lines[i].trim() && /^\s{2,}/.test(lines[i]) && items.length) {
          // Continued, or a nested list: folded into the item.
          items[items.length - 1] += '\n' + lines[i].trim()
          i++
        } else break
      }
      blocks.push({ kind: 'list', ordered, start: ordered ? parseInt(item[2]) : 1, items })
      continue
    }
    const body: string[] = []
    while (
      i < lines.length &&
      lines[i].trim() &&
      !LIST.test(lines[i]) &&
      !/^(#{1,6})\s/.test(lines[i]) &&
      !/^\s*(```|~~~)/.test(lines[i]) &&
      !lines[i].startsWith('>')
    ) {
      body.push(lines[i++])
    }
    blocks.push({ kind: 'p', text: body.join('\n') })
  }
  return blocks
}

export const Markdown = memo(function Markdown({ text }: { text: string }) {
  return (
    <div className="md flex flex-col gap-[0.7em] text-[16px] leading-[1.5] text-t1">
      {parse(text).map((b, i) => (
        <BlockView key={i} block={b} />
      ))}
    </div>
  )
})

function BlockView({ block }: { block: Block }) {
  switch (block.kind) {
    case 'p':
      return (
        <p className="break-words whitespace-pre-line">
          <Inline text={block.text} />
        </p>
      )
    case 'h':
      return (
        <p className={block.level <= 2 ? 'mt-1 text-[17px] font-semibold' : 'font-semibold'}>
          <Inline text={block.text} />
        </p>
      )
    case 'code':
      return (
        <pre className="-mx-1 overflow-x-auto rounded-[10px] bg-code px-3 py-2.5 font-mono text-[13px] leading-[1.5] text-t2 [scrollbar-width:none]">
          {block.text}
        </pre>
      )
    case 'list': {
      const Tag = block.ordered ? 'ol' : 'ul'
      return (
        <Tag className="flex flex-col gap-[0.35em]">
          {block.items.map((item, i) => (
            <li key={i} className="flex gap-2">
              <span className={block.ordered ? 'min-w-[1.1em] shrink-0 text-right text-t3 tabular-nums' : 'shrink-0 text-t4'}>
                {block.ordered ? `${block.start + i}.` : '•'}
              </span>
              <span className="min-w-0 flex-1 break-words whitespace-pre-line">
                <Inline text={item} />
              </span>
            </li>
          ))}
        </Tag>
      )
    }
    case 'quote':
      return (
        <blockquote className="border-l-[3px] border-hair pl-3 text-t2 whitespace-pre-line">
          <Inline text={block.text} />
        </blockquote>
      )
    case 'table':
      return (
        <div className="-mx-1 overflow-x-auto rounded-[10px] border border-hair [scrollbar-width:none]">
          <table className="w-max min-w-full border-collapse text-[14px]">
            <thead>
              <tr>
                {block.head.map((c, i) => (
                  <th key={i} className="border-b border-hair bg-code px-2.5 py-1.5 text-left font-semibold">
                    <Inline text={c} />
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {block.rows.map((r, i) => (
                <tr key={i} className={i > 0 ? 'border-t border-hair' : ''}>
                  {r.map((c, j) => (
                    <td key={j} className="px-2.5 py-1.5 align-top">
                      <Inline text={c} />
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )
    case 'rule':
      return <hr className="border-hair" />
  }
}

const INLINE = /(`[^`\n]+`|\*\*[^*\n]+\*\*|__[^_\n]+__|(?<![\w*])\*[^*\n]+\*(?!\w)|\[[^\]\n]+\]\([^)\s]+\)|https?:\/\/[^\s)]+)/

export function Inline({ text }: { text: string }) {
  const parts = text.split(INLINE)
  const out: ReactNode[] = []
  parts.forEach((part, i) => {
    if (!part) return
    if (i % 2 === 0) return out.push(<Fragment key={i}>{part}</Fragment>)
    if (part.startsWith('`'))
      return out.push(
        <code key={i} className="rounded-[5px] bg-code px-[0.3em] py-[0.05em] font-mono text-[0.86em] break-all">
          {part.slice(1, -1)}
        </code>,
      )
    if (part.startsWith('**') || part.startsWith('__'))
      return out.push(
        <strong key={i} className="font-semibold">
          {part.slice(2, -2)}
        </strong>,
      )
    if (part.startsWith('*')) return out.push(<em key={i}>{part.slice(1, -1)}</em>)
    const link = part.match(/^\[([^\]]+)\]\(([^)]+)\)$/)
    const href = link ? link[2] : part
    const label = link ? link[1] : part
    if (!/^https?:\/\//.test(href)) return out.push(<Fragment key={i}>{label}</Fragment>)
    out.push(
      <a key={i} href={href} target="_blank" rel="noreferrer noopener" className="text-tone-blue underline decoration-tone-blue/30 underline-offset-2 break-all">
        {label}
      </a>,
    )
  })
  return <>{out}</>
}
