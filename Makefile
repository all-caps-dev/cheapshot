# cheapshot: universal (arm64 + x86_64) release binary, macOS 13 floor.
PREFIX ?= /usr/local
PRODUCT = .build/apple/Products/Release/cheapshot

.PHONY: all build check test install clean

all: build check

build:
	swift build -c release --arch arm64 --arch x86_64
	cp $(PRODUCT) ./cheapshot

check:
	@lipo -info ./cheapshot | grep -q "x86_64 arm64" || lipo -info ./cheapshot | grep -q "arm64 x86_64" || (echo "not universal" && exit 1)
	@test "$$(otool -l ./cheapshot | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $$2; f=0}' | sort -u)" = "13.0" || (echo "minos is not 13.0 on every slice" && exit 1)
	@echo "ok: universal, minos 13.0"

test:
	swift test

install: build
	install -d $(PREFIX)/bin
	install -m 755 ./cheapshot $(PREFIX)/bin/cheapshot

clean:
	rm -rf .build ./cheapshot
