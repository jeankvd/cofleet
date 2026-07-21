.PHONY: bootstrap doctor generate check test test-ui build build-macos build-ios build-watch

bootstrap:
	Scripts/bootstrap.sh

doctor:
	Scripts/doctor.sh

generate:
	Scripts/generate-project.sh

check:
	Scripts/check-repository.sh
	Scripts/check-project-drift.sh

test:
	Scripts/test.sh

test-ui:
	Scripts/test.sh --ui

build:
	Scripts/build.sh all

build-macos:
	Scripts/build.sh macos

build-ios:
	Scripts/build.sh ios-simulator

build-watch:
	Scripts/build.sh watch
