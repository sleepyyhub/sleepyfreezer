# Text → Python Compressor

A tiny, single-page website. Paste any text, give it a name, and download it as a
compact self-contained Python file.

## How it works

- The whole app is one static file: [`index.html`](./index.html). No frameworks,
  no build step, no external dependencies.
- When you paste text, it is gzip-compressed in the browser (using the native
  `CompressionStream` API) and base64-encoded. Live stats show how much smaller it got.
- Input stays responsive on large pastes because compression is debounced and the
  text box has a fixed height with scrolling (it never grows to lag the page).
- Clicking **Download** produces `<your_name>.py` — a small script that stores the
  compressed payload and reconstructs the text when run.

## Using the downloaded file

```bash
python your_file.py      # prints the original text
```

Or import it:

```python
from your_file import TEXT
print(len(TEXT))
```

## Deploying to Render

This repo includes a [`render.yaml`](./render.yaml) blueprint that publishes the
folder as a **static site** — no server, no build command. In Render, create a new
Blueprint pointing at this repo/branch, or a new **Static Site** with an empty build
command and publish directory `.`.
