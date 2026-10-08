LUAROCKS_BIN ?= $(HOME)/.luarocks/bin
BUSTED   ?= $(shell command -v busted 2>/dev/null || echo $(LUAROCKS_BIN)/busted)
LUACHECK ?= $(shell command -v luacheck 2>/dev/null || echo $(LUAROCKS_BIN)/luacheck)

.PHONY: test test-lua test-python test-install lint install uninstall

test: test-lua test-python test-install

test-lua:
	$(BUSTED)

test-python:
	python3 -m unittest discover -s tests

test-install:
	tests/test_install.sh

lint:
	$(LUACHECK) src spec
	shellcheck install.sh uninstall.sh tests/test_install.sh

install:
	./install.sh

uninstall:
	./uninstall.sh
