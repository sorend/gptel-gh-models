EMACS     ?= emacs
EMACS_FLAGS = -Q --batch

# ---------------------------------------------------------------------------
# Locate the latest installed gptel package.
# Override with: make GPTEL_DIR=/path/to/gptel
# ---------------------------------------------------------------------------
GPTEL_DIR ?= $(shell \
  ls -d $(HOME)/.emacs.d/elpa/gptel-[0-9]*/ 2>/dev/null \
  | sort -V | tail -n 1)

ifeq ($(strip $(GPTEL_DIR)),)
  $(warning gptel not found under ~/.emacs.d/elpa/; \
    set GPTEL_DIR=/path/to/gptel if needed)
  LOAD_PATH = -L .
else
  LOAD_PATH = -L . -L $(GPTEL_DIR)
endif

# ---------------------------------------------------------------------------
# Source files
# ---------------------------------------------------------------------------
EL_FILES  = gptel-gh-models.el
ELC_FILES = $(EL_FILES:.el=.elc)

TEST_FILES = test/gptel-gh-models-test.el
INTEGRATION_TEST_FILES = test/gptel-gh-models-integration-test.el

.PHONY: all compile test integration-test clean check

all: compile test

# ---------------------------------------------------------------------------
# Byte compilation
# ---------------------------------------------------------------------------
compile: $(ELC_FILES)

%.elc: %.el
	$(EMACS) $(EMACS_FLAGS) $(LOAD_PATH) -f batch-byte-compile $<

# ---------------------------------------------------------------------------
# Run ERT test suite headlessly
# ---------------------------------------------------------------------------
test:
	$(EMACS) $(EMACS_FLAGS) $(LOAD_PATH) \
	  -l ert \
	  -l gptel-gh-models.el \
	  -l $(TEST_FILES) \
	  -f ert-run-tests-batch-and-exit

# ---------------------------------------------------------------------------
# Live integration tests (require authenticated Copilot credentials)
# ---------------------------------------------------------------------------
integration-test:
	$(EMACS) $(EMACS_FLAGS) $(LOAD_PATH) \
	  -l ert \
	  -l gptel-gh-models.el \
	  -l $(INTEGRATION_TEST_FILES) \
	  -f ert-run-tests-batch-and-exit

# ---------------------------------------------------------------------------
# check = compile + test (convenient alias)
# ---------------------------------------------------------------------------
check: compile test

# ---------------------------------------------------------------------------
# Clean byte-compiled artefacts
# ---------------------------------------------------------------------------
clean:
	rm -f $(ELC_FILES) test/*.elc
