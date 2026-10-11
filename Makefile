LUAROCKS_BIN ?= $(HOME)/.luarocks/bin
BUSTED   ?= $(shell command -v busted 2>/dev/null || echo $(LUAROCKS_BIN)/busted)
LUACHECK ?= $(shell command -v luacheck 2>/dev/null || echo $(LUAROCKS_BIN)/luacheck)

.PHONY: test test-lua test-python test-swift test-install test-integration lint install uninstall

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

lint:
	$(LUACHECK) src spec
	shellcheck install.sh uninstall.sh tests/test_install.sh recorder/build.sh recorder/test.sh tests/integration/mic_coexistence.sh

install:
	./install.sh

uninstall:
	./uninstall.sh
