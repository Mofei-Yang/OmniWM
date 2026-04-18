.PHONY: format lint lint-fix kernels-build kernels-test build test verify release-check check

SWIFT_WITH_GHOSTTY = LIBRARY_PATH="$$(./Scripts/build-preflight.sh print-ghostty-library-dir)$${LIBRARY_PATH:+:$$LIBRARY_PATH}"

format:
	swiftformat .

lint:
	@status=0; \
	swiftlint lint || status=$$?; \
	./Scripts/check-private-api-boundary.sh || status=$$?; \
	exit $$status

lint-fix:
	swiftlint lint --fix

kernels-build:
	./Scripts/build-zig-kernels.sh $(if $(CONFIG),$(CONFIG),debug)

kernels-test:
	cd Zig/omniwm_kernels && zig build test

build:
	./Scripts/build-preflight.sh build debug
	$(SWIFT_WITH_GHOSTTY) swift build

test:
	./Scripts/build-preflight.sh build debug
	$(SWIFT_WITH_GHOSTTY) swift test

verify:
	$(MAKE) lint
	$(MAKE) build
	$(MAKE) test

release-check:
	./Scripts/build-preflight.sh release-check
	$(MAKE) verify
	./Scripts/build-universal-products.sh release
	test -x .build/apple/Products/Release/OmniWM
	test -x .build/apple/Products/Release/omniwmctl
	lipo -info .build/apple/Products/Release/OmniWM
	lipo -info .build/apple/Products/Release/omniwmctl

check:
	$(MAKE) verify
