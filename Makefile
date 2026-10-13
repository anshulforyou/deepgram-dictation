LUAROCKS_BIN ?= $(HOME)/.luarocks/bin
BUSTED   ?= $(shell command -v busted 2>/dev/null || echo $(LUAROCKS_BIN)/busted)
LUACHECK ?= $(shell command -v luacheck 2>/dev/null || echo $(LUAROCKS_BIN)/luacheck)

.PHONY: test test-lua test-python test-swift test-install test-integration eval-dictation eval-screen render-screens lint install uninstall

test: test-lua test-python test-swift test-install

test-lua:
	$(BUSTED)

test-python:
	python3 -m unittest discover -s tests

test-swift:
	recorder/test.sh

test-install:
	tests/test_install.sh

# Needs a Mac with Hammerspoon running and microphone access; not run in CI.
test-integration:
	tests/integration/mic_coexistence.sh
	SYSTEM_AUDIO=0 tests/integration/mic_coexistence.sh

# Replays recent saved dictations through the current cleanup prompt (calls Anthropic's API).
eval-dictation:
	python3 scripts/replay_dictations.py --last 20

# Asks grandma questions about the test screens in tests/screens and checks the answers
# (calls Anthropic's API, about $0.15 a run).
eval-screen:
	python3 scripts/eval_screen.py

# Re-renders tests/screens/*.html to the PNGs eval-screen uses (needs Chrome or Brave).
render-screens:
	scripts/render_screens.sh

lint:
	$(LUACHECK) src spec
	shellcheck install.sh uninstall.sh tests/test_install.sh recorder/build.sh recorder/test.sh tests/integration/mic_coexistence.sh scripts/render_screens.sh

install:
	./install.sh

uninstall:
	./uninstall.sh
