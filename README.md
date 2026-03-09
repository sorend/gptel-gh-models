# gptel-gh-models

An Emacs package that replaces the hardcoded model list in
[gptel](https://github.com/karthink/gptel)'s built-in GitHub Copilot backend
with a **dynamically fetched list** from the live GitHub Copilot API.

The stock `gptel-gh` backend ships with a static list of models. As GitHub adds
or removes models, that list goes stale. This package queries
`https://api.githubcopilot.com/models` at runtime so you always see every model
your account has access to.

## Requirements

- **Emacs 28.1** or later
- **gptel 0.9.8** or later
- A **GitHub Copilot subscription** (Individual, Business, or Enterprise)

## Installation

### Manual

Clone or copy `gptel-gh-models.el` to a directory on your `load-path`:

```bash
git clone https://github.com/sorend/gptel-gh-models ~/.emacs.d/lisp/gptel-gh-models
```

Then add that directory to your `load-path` in your `init.el`:

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/gptel-gh-models")
```

### use-package with :vc (Emacs 29+)

```elisp
(use-package gptel-gh-models
  :vc (:url "https://github.com/sorend/gptel-gh-models" :rev :newest)
  :after gptel
  :config
  (gptel-gh-models-setup :set-default t))
```

## Usage

### Basic setup

Add the following to your `init.el`:

```elisp
(require 'gptel-gh-models)

(gptel-gh-models-setup)
```

On first run this triggers GitHub's OAuth device-flow: a URL and one-time code
are printed to the `*Messages*` buffer. Visit the URL in your browser, enter the
code, and the token is cached for future sessions.

### Set as the default backend

```elisp
(gptel-gh-models-setup :set-default t)
```

This sets both `gptel-backend` and `gptel-model` to the new backend and its
first available model.

### Custom backend name

```elisp
(gptel-gh-models-setup :name "My Copilot")
```

### Refresh the model list

After the initial setup, you can refresh the model list at any time without
re-authenticating:

```elisp
;; Interactively:
M-x gptel-gh-models-update

;; Or programmatically:
(gptel-gh-models-update)
```

### Customization

The following variables can be set directly or via `M-x customize-group RET gptel-gh-models`:

| Variable | Default | Description |
|---|---|---|
| `gptel-gh-models-backend-name` | `"GitHub Copilot"` | Name for the registered gptel backend |
| `gptel-gh-models-api-url` | `"https://api.githubcopilot.com/models"` | GitHub Copilot models API endpoint |

To use a proxy or an enterprise endpoint:

```elisp
(setq gptel-gh-models-api-url "https://your-proxy/models")
```

## Authentication

Authentication is handled by `gptel-gh`'s built-in OAuth device-flow and is
shared with any other `gptel-gh` backend you have configured. The token is
cached in the backend struct for the duration of the Emacs session.

If authentication fails, the package falls back to gptel's default hardcoded
model list rather than signalling an error.

## Model capabilities

The following GitHub Copilot API fields are mapped to gptel capability symbols:

| API field | gptel capability |
|---|---|
| `supports.tool_calls = true` | `tool-use` |
| `limits.vision` present | `media` + image MIME types |
| Always (OpenAI-compatible) | `json`, `url` |

## Development

### Building

```bash
# Byte-compile (auto-detects gptel under ~/.emacs.d/elpa/)
make compile

# With an explicit gptel path
make GPTEL_DIR=/path/to/gptel compile
```

### Running tests

The test suite is fully offline — no live network or credentials required.

```bash
# Compile then run tests
make

# Run tests only
make test

# With a custom Emacs binary or gptel path
make EMACS=/usr/local/bin/emacs-29 GPTEL_DIR=/path/to/gptel test
```

To run tests manually without Make:

```bash
emacs -Q --batch -L . -L /path/to/gptel \
  -l ert \
  -l gptel-gh-models.el \
  -l test/gptel-gh-models-test.el \
  -f ert-run-tests-batch-and-exit
```

### Cleaning build artefacts

```bash
make clean
```

## License

GNU General Public License v3 or later. See the file header in
`gptel-gh-models.el` for details.
