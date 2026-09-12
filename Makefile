# cheapshot: universal (arm64 + x86_64) release binary, macOS 13 floor.
PREFIX ?= /usr/local
PRODUCT = .build/apple/Products/Release/cheapshot

.PHONY: all build check test install clean

# Serialize the whole invocation so `check` can never inspect a stale
# ./cheapshot while `build` is still running, even under `make -jN`.
.NOTPARALLEL:

all: build check

build:
	swift build -c release --arch arm64 --arch x86_64
	cp $(PRODUCT) ./cheapshot

check:
	@test -f ./cheapshot || { echo "run make build first"; exit 1; }
	@lipo -info ./cheapshot | grep -q "x86_64 arm64" || lipo -info ./cheapshot | grep -q "arm64 x86_64" || { echo "not universal"; exit 1; }
	@m="$$(otool -l ./cheapshot | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $$2; f=0}')"; \
	test "$$(printf '%s\n' "$$m" | sort -u)" = "13.0" || { echo "minos is not 13.0 on every slice"; exit 1; }; \
	test "$$(printf '%s\n' "$$m" | grep -c .)" = "2" || { echo "expected LC_BUILD_VERSION on 2 slices"; exit 1; }
	@echo "ok: universal, minos 13.0"

test:
	swift test

install: build check
	install -d $(PREFIX)/bin
	install -m 755 ./cheapshot $(PREFIX)/bin/cheapshot

clean:
	rm -rf .build ./cheapshot
