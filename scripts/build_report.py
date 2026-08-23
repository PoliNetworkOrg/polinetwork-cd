#!/usr/bin/env python3
"""Render the canonical migration Markdown as a standalone HTML document."""

from __future__ import annotations

import html
from pathlib import Path

import markdown


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "migration-plan.md"
OUTPUT = ROOT / "migration-plan.html"
STYLES = ROOT / "assets" / "report.css"


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    md = markdown.Markdown(
        extensions=[
            "extra",
            "sane_lists",
            "toc",
        ],
        extension_configs={
            "toc": {
                "permalink": "#",
                "permalink_class": "heading-anchor",
                "toc_depth": "2-4",
            }
        },
        output_format="html5",
    )
    body = md.convert(source)
    body = body.replace("<table>", '<div class="table-scroll">\n<table>')
    body = body.replace("</table>", "</table>\n</div>")
    toc = md.toc
    title = "PoliNetwork — piano operativo AKS → K3s"

    page = f"""<!doctype html>
<html lang="it">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark">
  <meta name="description" content="Decisioni e runbook operativo per la migrazione PoliNetwork da AKS a K3s.">
  <title>{html.escape(title)}</title>
  <style>
{STYLES.read_text(encoding="utf-8")}
  </style>
</head>
<body>
  <a class="skip-link" href="#content">Vai al contenuto</a>
  <div class="app-shell">
    <aside class="sidebar" aria-label="Navigazione del piano">
      <div class="sidebar-header">
        <p class="eyebrow">PoliNetwork infrastructure</p>
        <p class="sidebar-title">AKS → K3s</p>
        <p class="sidebar-copy">Decisioni e istruzioni operative, dalla preparazione al decommissioning.</p>
      </div>
      <nav class="toc" aria-label="Indice">
        {toc}
      </nav>
      <div class="source-card">
        <span>Sorgente canonica</span>
        <code>migration-plan.md</code>
        <span>Rigenera con</span>
        <code>make html</code>
        <span>Pubblica con</span>
        <code>make publish</code>
      </div>
    </aside>

    <main id="content" class="main-content">
      <article class="document">
        {body}
      </article>

      <footer>
        Modifica il Markdown, non questo file HTML. Nessun valore di secret deve entrare nel documento.
      </footer>
    </main>
  </div>
</body>
</html>
"""
    OUTPUT.write_text(page, encoding="utf-8")
    print(f"Generated {OUTPUT.relative_to(ROOT)} from {SOURCE.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
