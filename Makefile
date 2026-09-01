PROJECT ?=
SLUG ?=
AGENTS ?= claude,codex
SCENARIO ?= list-apps

.PHONY: init build app test conformance agent-smoke check-docs check-repo ci release-package npm-build npm-publish new-history new-plan windows-native windows-native-publish windows-native-lifecycle

init:
	@if [ -z "$(PROJECT)" ]; then echo "用法: make init PROJECT=项目名"; exit 1; fi
	./scripts/init-project.sh "$(PROJECT)"

build:
	swift build

app:
	./scripts/build-open-computer-use-app.sh debug

test:
	swift test

conformance:
	swift test --filter HostProtocolTests

agent-smoke:
	node ./scripts/run-agent-smoke-tests.mjs --agents=$(AGENTS) --scenario=$(SCENARIO)

check-docs:
	./scripts/check-docs.sh

check-repo:
	./scripts/check-docs.sh
	./scripts/check-repo-hygiene.sh

ci:
	./scripts/ci.sh

release-package:
	./scripts/release-package.sh

npm-build:
	node ./scripts/npm/build-packages.mjs

npm-publish:
	node ./scripts/npm/publish-packages.mjs

new-history:
	@if [ -z "$(SLUG)" ]; then echo "用法: make new-history SLUG=变更名"; exit 1; fi
	./scripts/new-history.sh "$(SLUG)"

new-plan:
	@if [ -z "$(SLUG)" ]; then echo "用法: make new-plan SLUG=计划名"; exit 1; fi
	./scripts/new-exec-plan.sh "$(SLUG)"

windows-native:
	dotnet build apps/OpenComputerUseWindows/native/MakaCuWindows.csproj -c Release

windows-native-publish:
	powershell -ExecutionPolicy Bypass -File scripts/windows/publish-native.ps1

windows-native-lifecycle:
	powershell -ExecutionPolicy Bypass -File scripts/windows/publish-native.ps1 -IncludeFixture
	node scripts/windows/lifecycle-driver.mjs \
		dist/windows-native/win-x64/helper/maka-cu-windows.exe \
		dist/windows-native/win-x64/fixture/maka-cu-windows-fixture.exe
