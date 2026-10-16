LUAROCKS_BIN ?= $(HOME)/.luarocks/bin
BUSTED   ?= $(shell command -v busted 2>/dev/null || echo $(LUAROCKS_BIN)/busted)
LUACHECK ?= $(shell command -v luacheck 2>/dev/null || echo $(LUAROCKS_BIN)/luacheck)

.PHONY: test test-lua test-python test-swift test-install test-integration eval-dictation eval-screen render-screens render-badges sounds test-fill test-work lint install uninstall

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

# Fills a real form in Brave with grandma and checks what landed (calls Anthropic's API). Takes
# over the mouse and keyboard for up to 90 s, so it's never run in CI.
test-fill:
	tests/integration/fill.sh

# Has grandma rework a test landing page in Brave (look through, propose, edit, save a draft) and
# checks nothing was published (calls Anthropic's API). Takes over the mouse and keyboard for a
# few minutes, so it's never run in CI.
test-work:
	tests/integration/work.sh

# Re-renders tests/screens/*.html to the PNGs eval-screen uses (needs Chrome or Brave).
render-screens:
	scripts/render_screens.sh

# Grandma's badge animations and sounds. Both are committed; rebuild after changing one.
render-badges:
	scripts/render_badges.sh

sounds:
	python3 scripts/make_sounds.py

lint:
	$(LUACHECK) src spec scripts
	shellcheck install.sh uninstall.sh tests/test_install.sh recorder/build.sh recorder/test.sh dragger/build.sh tests/integration/mic_coexistence.sh scripts/render_screens.sh scripts/render_badges.sh tests/integration/fill.sh tests/integration/work.sh

install:
	./install.sh

uninstall:
	./uninstall.sh
