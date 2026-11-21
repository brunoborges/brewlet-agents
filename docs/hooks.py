"""MkDocs hook: render the agent READMEs and the agent contract as pages of this site.

The READMEs are read on GitHub first, so they stay the single source of truth. A docs page that
holds only a marker line

    <!-- source: agents/java-spring/README.md -->

is replaced by that file's content, with
  * links to repository files turned into links to GitHub (or to the matching docs page), and
  * GitHub alerts ("> [!NOTE]") turned into admonitions.
"""

import posixpath
import re
from pathlib import Path

REPO_URL = "https://github.com/brunoborges/brewlet-agents"
BRANCH = "main"
ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"

SOURCE = re.compile(r"^\s*<!--\s*source:\s*(\S+)\s*-->\s*$", re.MULTILINE)
LINK = re.compile(r"(?<!!)\[([^\]]*)\]\(([^)\s]+)((?:\s+\"[^\"]*\")?)\)")
FENCE = re.compile(r"^\s*(```|~~~)")
ALERT = re.compile(r"^>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$")
ALERTS = {
    "NOTE": ("note", "Note"),
    "TIP": ("tip", "Tip"),
    "IMPORTANT": ("info", "Important"),
    "WARNING": ("warning", "Warning"),
    "CAUTION": ("danger", "Caution"),
}

_pages = None


def _doc_pages():
    """Repository file -> docs page, for every stub that carries a source marker."""
    global _pages
    if _pages is None:
        _pages = {}
        for stub in sorted(DOCS.rglob("*.md")):
            found = SOURCE.search(stub.read_text(encoding="utf-8")[:400])
            if found:
                _pages[found.group(1)] = stub.relative_to(DOCS).as_posix()
    return _pages


def _retarget(target, source, page_uri):
    """Where a link found in `source` should point when it is shown on page `page_uri`."""
    if re.match(r"^([a-z][a-z0-9+.-]*:|#|/)", target):
        return target
    path, _, anchor = target.partition("#")
    suffix = f"#{anchor}" if anchor else ""
    repo_path = posixpath.normpath(posixpath.join(posixpath.dirname(source), path))
    if repo_path.startswith(".."):
        return target

    page = _doc_pages().get(repo_path)
    if page is None and repo_path.startswith("docs/") and (ROOT / repo_path).is_file():
        page = repo_path[len("docs/"):]
    if page is not None:
        return posixpath.relpath(page, posixpath.dirname(page_uri)) + suffix

    kind = "tree" if (ROOT / repo_path).is_dir() else "blob"
    return f"{REPO_URL}/{kind}/{BRANCH}/{repo_path}{suffix}"


def _render(text, source, page_uri):
    out = []
    lines = text.splitlines()
    in_fence = False
    i = 0
    while i < len(lines):
        line = lines[i]
        if FENCE.match(line):
            in_fence = not in_fence
        if in_fence or FENCE.match(line):
            out.append(line)
            i += 1
            continue

        alert = ALERT.match(line)
        if alert:
            kind, title = ALERTS[alert.group(1)]
            out.append(f'!!! {kind} "{title}"')
            i += 1
            while i < len(lines) and lines[i].startswith(">"):
                body = re.sub(r"^>\s?", "", lines[i])
                out.append(f"    {body}" if body else "")
                i += 1
            out.append("")
            continue

        out.append(
            LINK.sub(
                lambda m: f"[{m.group(1)}]({_retarget(m.group(2), source, page_uri)}{m.group(3)})",
                line,
            )
        )
        i += 1

    out += [
        "",
        "---",
        "",
        f"This page is rendered from [`{source}`]({REPO_URL}/blob/{BRANCH}/{source}).",
        "",
    ]
    return "\n".join(out)


def on_page_markdown(markdown, page, config, files, **kwargs):
    found = SOURCE.search(markdown)
    if not found:
        return markdown
    source = found.group(1)
    path = ROOT / source
    if not path.is_file():
        raise FileNotFoundError(f"{page.file.src_uri} renders {source}, which does not exist")
    return _render(path.read_text(encoding="utf-8"), source, page.file.src_uri)
