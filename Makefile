.PHONY: build test run preview
build:
	./Scripts/build.sh
test:
	./Scripts/swift.sh test
run: build
	open dist/MyTool.app
preview:
	./Scripts/smoke-ui.sh
