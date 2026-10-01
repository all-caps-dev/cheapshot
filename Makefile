# cheapshot: universal (arm64 + x86_64) release binary, macOS 13 floor.
PREFIX ?= /usr/local
SWIFT_BUILD = swift build -c release --arch arm64 --arch x86_64
STAMP_FILE = Sources/CheapshotCore/BuildInfo.swift

.PHONY: all build check test install clean

# Serialize the whole invocation so `check` can never inspect a stale
# ./cheapshot while `build` is still running, even under `make -jN`.
.NOTPARALLEL:

all: build check

# Stamp the build (commit, UTC date, .dirty if tracked files differ) into $(STAMP_FILE) for the
# length of the compile, then restore it, so the tree stays clean and plain `swift build` stays
# unstamped. The product folder comes from SwiftPM itself: it moved from .build/apple/ to
# .build/out/ in newer toolchains, and --show-bin-path is right for both.
build:
	@sha=$$(git rev-parse --short HEAD 2>/dev/null || echo unknown); \
	dirty=$$(git status --porcelain --untracked-files=no 2>/dev/null | grep -q . && echo .dirty); \
	stamp="$$sha.$$(date -u +%Y%m%d)$$dirty"; \
	cp $(STAMP_FILE) $(STAMP_FILE).orig; \
	printf '%s\n' "// Stamped by make build and restored afterwards. Do not commit this copy." \
	  "public let cheapshotBuild = \"$$stamp\"" > $(STAMP_FILE); \
	$(SWIFT_BUILD); rc=$$?; \
	cp $(STAMP_FILE).orig $(STAMP_FILE) && rm -f $(STAMP_FILE).orig; \
	[ $$rc -eq 0 ] || exit $$rc; \
	bin="$$($(SWIFT_BUILD) --show-bin-path)/cheapshot"; \
	test -f "$$bin" || { echo "no product at $$bin"; exit 1; }; \
	cp "$$bin" ./cheapshot; \
	echo "built ./cheapshot $$(./cheapshot --version)"

check:
	@test -f ./cheapshot || { echo "run make build first"; exit 1; }
	@lipo -info ./cheapshot | grep -q "x86_64 arm64" || lipo -info ./cheapshot | grep -q "arm64 x86_64" || { echo "not universal"; exit 1; }
	@m="$$(otool -l ./cheapshot | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $$2; f=0}')"; \
	test "$$(printf '%s\n' "$$m" | sort -u)" = "13.0" || { echo "minos is not 13.0 on every slice"; exit 1; }; \
	test "$$(printf '%s\n' "$$m" | grep -c .)" = "2" || { echo "expected LC_BUILD_VERSION on 2 slices"; exit 1; }
	@./cheapshot --version | grep -q "+" || { echo "binary is not stamped with its build (use make build)"; exit 1; }
	@echo "ok: universal, minos 13.0, stamped $$(./cheapshot --version)"

test:
	swift test

install: build check
	install -d $(PREFIX)/bin
	install -m 755 ./cheapshot $(PREFIX)/bin/cheapshot

clean:
	rm -rf .build ./cheapshot
