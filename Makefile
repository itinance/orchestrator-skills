# Release workflow for the npm package orchestrator-skills.
#
#   make release BUMP=patch|minor|major   bump, test, commit, tag, push
#   make release VERSION=1.2.3            same, with an explicit version
#   make publish OTP=123456               publish the tagged HEAD to npm
#   make published                        show what the registry has
#
# release and publish are separate steps because the 2FA code is only valid
# for about 30 seconds. If npm stages the publish instead (E409 "staged"),
# finish it with: npm stage list orchestrator-skills, then npm stage approve <id>.

PKG     := orchestrator-skills
BRANCH  := main
CURRENT  = $(shell node -p "require('./package.json').version")

.PHONY: help test check-clean release publish published

help:
	@sed -n '3,6p' Makefile | sed 's/^# //'

test:
	npm test
	bash tests/watchdog.test.sh

check-clean:
	@test -z "$$(git status --porcelain)" || { echo "Working tree not clean. Commit or stash first."; exit 1; }
	@test "$$(git rev-parse --abbrev-ref HEAD)" = "$(BRANCH)" || { echo "Not on $(BRANCH)."; exit 1; }
	@git fetch -q origin $(BRANCH)
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/$(BRANCH))" || { echo "HEAD differs from origin/$(BRANCH). Pull or push first."; exit 1; }

release: check-clean test
	@test -n "$(BUMP)$(VERSION)" || { echo "Usage: make release BUMP=patch|minor|major  or  VERSION=x.y.z"; exit 1; }
	@npm version $(or $(VERSION),$(BUMP)) --no-git-tag-version >/dev/null
	@new=$$(node -p "require('./package.json').version"); \
	node -e "const fs=require('fs');const f='README.md';fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace(/$(PKG)@\d+\.\d+\.\d+/g,'$(PKG)@'+process.argv[1]))" "$$new"; \
	git add package.json README.md && \
	git commit -q -m "Release $$new" && \
	git tag -a "v$$new" -m "v$$new" && \
	git push -q origin $(BRANCH) && \
	git push -q origin "v$$new" && \
	echo "Released v$$new on GitHub. Next: make publish OTP=<code>"

publish: check-clean
	@test "$$(git describe --exact-match --tags HEAD 2>/dev/null)" = "v$(CURRENT)" || { echo "HEAD is not tagged v$(CURRENT). Run make release first."; exit 1; }
	@if npm view $(PKG)@$(CURRENT) version >/dev/null 2>&1; then echo "$(PKG)@$(CURRENT) is already on npm."; exit 1; fi
	npm publish $(if $(OTP),--otp=$(OTP))
	@$(MAKE) -s published

published:
	@npm view $(PKG) dist-tags versions --prefer-online
