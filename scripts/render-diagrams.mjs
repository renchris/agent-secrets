#!/usr/bin/env node
// Render assets/diagrams/*.mmd → <name>-dark.svg / <name>-light.svg via
// beautiful-mermaid (the ELK-based engine behind Cursor's agent panel).
//
// Usage:  npm run diagrams          — (re)render all SVGs
//         npm run diagrams:check    — exit 1 if committed SVGs are stale (CI)
//
// Diagrams render transparent on GitHub's exact dark/light palettes and are
// embedded in README.md via <picture> + prefers-color-scheme. To change a
// diagram: edit its .mmd here, run `npm run diagrams`, commit both.
//
// Semantic colors: .mmd classDef lines use @tokens (e.g. fill:@green-bg)
// substituted per variant from PALETTE below, so one source renders with
// hand-tuned colors on BOTH GitHub color modes.
import { renderMermaidSVG, THEMES } from 'beautiful-mermaid'
import { readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

const DIR = fileURLToPath(new URL('../assets/diagrams/', import.meta.url))
const CHECK = process.argv.includes('--check')

const PALETTE = {
  dark: {
    text: '#e6edf3', 'text-bright': '#f0f6fc',
    'green-bg': '#1a2b1a', 'green-fg': '#3fb950',
    'gold-bg': '#2b2410', 'gold-fg': '#d4af37', 'warn-fg': '#e3b341',
    'red-bg': '#2b1618', 'red-fg': '#ff6b6b', 'red-text': '#ff9b9b',
    'gray-bg': '#161b22', 'gray-fg': '#6e7681', 'gray-text': '#8b949e',
    'blue-bg': '#161b22', 'blue-fg': '#58a6ff',
  },
  light: {
    text: '#1f2328', 'text-bright': '#1f2328',
    'green-bg': '#dafbe1', 'green-fg': '#1a7f37',
    'gold-bg': '#fff8c5', 'gold-fg': '#9a6700', 'warn-fg': '#9a6700',
    'red-bg': '#ffebe9', 'red-fg': '#cf222e', 'red-text': '#82071e',
    'gray-bg': '#f6f8fa', 'gray-fg': '#59636e', 'gray-text': '#59636e',
    'blue-bg': '#ddf4ff', 'blue-fg': '#0969da',
  },
}

const VARIANTS = [
  ['dark', THEMES['github-dark']],
  ['light', THEMES['github-light']],
]

function applyPalette(src, variant) {
  return src.replace(/@([a-z][a-z0-9-]*)/g, (match, token) => {
    const value = PALETTE[variant][token]
    if (!value) throw new Error(`unknown palette token ${match}`)
    return value
  })
}

// GitHub serves README images through a proxy that blocks external loads, so
// the default Google-Fonts @import can never resolve there. Strip it and pin
// GitHub's own font stack for a native look.
const GITHUB_FONTS =
  '-apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif'
function githubReady(svg) {
  return svg
    .replace(/^\s*@import url\([^\n]*\);\s*$\n?/m, '')
    .replaceAll("'Inter', system-ui, sans-serif", GITHUB_FONTS)
}

const sources = readdirSync(DIR).filter((f) => f.endsWith('.mmd')).sort()
if (sources.length === 0) {
  console.error(`no .mmd sources found in ${DIR}`)
  process.exit(1)
}

let stale = 0
for (const file of sources) {
  const src = readFileSync(join(DIR, file), 'utf8')
  for (const [variant, theme] of VARIANTS) {
    const out = file.replace(/\.mmd$/, `-${variant}.svg`)
    const svg = githubReady(
      renderMermaidSVG(applyPalette(src, variant), { ...theme, transparent: true }),
    )
    const path = join(DIR, out)
    if (CHECK) {
      const current = existsSync(path) ? readFileSync(path, 'utf8') : null
      if (current !== svg) {
        console.error(`STALE: ${out} does not match ${file} — run \`npm run diagrams\``)
        stale++
      }
    } else {
      writeFileSync(path, svg)
      console.log(`rendered ${out} (${(svg.length / 1024).toFixed(1)} KB)`)
    }
  }
}

if (CHECK) {
  if (stale) process.exit(1)
  console.log(`all ${sources.length * VARIANTS.length} SVGs up to date`)
}
