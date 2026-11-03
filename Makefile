SHELL := /bin/bash
.PHONY: lint test up smoke down

lint:
	yamllint .
	shellcheck scripts/*.sh

test:
	bats test/

up smoke down:
	@echo "make $@: not implemented yet" >&2
	@exit 1
