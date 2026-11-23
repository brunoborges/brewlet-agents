const form = document.querySelector('#summarize-form');
const input = document.querySelector('#article-url');
const button = form.querySelector('button');
const status = document.querySelector('#status');
const result = document.querySelector('#result');

const BUSY = 'Fetching the article and asking Copilot to summarize it…';

function element(tag, text) {
  const node = document.createElement(tag);
  if (text !== undefined) {
    node.textContent = text;
  }
  return node;
}

// Adds text to node, turning **bold** spans into <strong>. Text is never parsed as HTML.
function appendInline(node, text) {
  for (const part of text.split(/(\*\*[^*]+\*\*)/)) {
    if (/^\*\*[^*]+\*\*$/.test(part)) {
      node.append(element('strong', part.slice(2, -2)));
    } else if (part) {
      node.append(part);
    }
  }
  return node;
}

// The model answers in a small Markdown subset: paragraphs, "- " bullets, and a bold or # line as a heading.
function renderSummary(container, text) {
  let list = null;
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    const bullet = /^[-*]\s+(.*)$/.exec(trimmed);
    if (bullet) {
      if (!list) {
        list = element('ul');
        container.append(list);
      }
      list.append(appendInline(element('li'), bullet[1]));
      continue;
    }
    list = null;
    const heading = /^(?:#{1,6}\s+(.+)|\*\*([^*]+)\*\*)$/.exec(trimmed);
    if (heading) {
      container.append(element('h3', heading[1] ?? heading[2]));
    } else if (trimmed) {
      container.append(appendInline(element('p'), trimmed));
    }
  }
}

function showSummary({ title, url, summary, truncated }) {
  result.replaceChildren();
  const heading = element('h2');
  if (typeof url === 'string' && url.startsWith('https://')) {
    const link = element('a', title);
    link.href = url;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    heading.append(link);
  } else {
    heading.textContent = title;
  }
  result.append(heading);
  renderSummary(result, summary);
  if (truncated) {
    result.append(element('p', 'The article is long: only its beginning was summarized.')).lastChild.className = 'note';
  }
  result.hidden = false;
  status.hidden = true;
}

function showError(body, httpStatus) {
  result.hidden = true;
  status.className = 'error';
  status.hidden = false;
  if (body?.error === 'copilot_not_authenticated') {
    status.textContent = 'The Copilot CLI in the cluster has no GitHub credentials yet. Run "make auth" and try again.';
  } else if (body?.message) {
    status.textContent = body.message;
  } else {
    status.textContent = httpStatus ? `The request failed (HTTP ${httpStatus}).` : 'The front-end could not be reached.';
  }
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  button.disabled = true;
  result.hidden = true;
  status.className = '';
  status.textContent = BUSY;
  status.hidden = false;
  try {
    const response = await fetch('/api/summaries', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: input.value.trim() }),
    });
    const body = await response.json().catch(() => null);
    if (response.ok && body?.summary) {
      showSummary(body);
    } else {
      showError(body, response.status);
    }
  } catch {
    showError(null, 0);
  } finally {
    button.disabled = false;
  }
});
