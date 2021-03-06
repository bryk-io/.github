.PHONY: *
.DEFAULT_GOAL := help

# Project setup
BINARY_NAME=my-app
DOCKER_IMAGE=ghcr.io/$(OWNER)/$(BINARY_NAME)
MAINTAINERS='Ben Cessa <ben@pixative.com>'

# State values
GIT_COMMIT_DATE=$(shell TZ=UTC git log -n1 --pretty=format:'%cd' --date='format-local:%Y-%m-%dT%H:%M:%SZ')
GIT_COMMIT_HASH=$(shell git log -n1 --pretty=format:'%H')
GIT_TAG=$(shell git describe --tags --always --abbrev=0 | cut -c 1-7)

# Linker tags
# https://golang.org/cmd/link/
LD_FLAGS += -s -w
LD_FLAGS += -X main.coreVersion=$(GIT_TAG:v%=%)
LD_FLAGS += -X main.buildTimestamp=$(GIT_COMMIT_DATE)
LD_FLAGS += -X main.buildCode=$(GIT_COMMIT_HASH)

# Proto builder basic setup
proto-builder=docker run --rm -it -v $(shell pwd):/workdir ghcr.io/bryk-io/buf-builder:0.30.0

## help: Prints this help message
help:
	@echo "Commands available"
	@sed -n 's/^##//p' ${MAKEFILE_LIST} | column -t -s ':' | sed -e 's/^/ /' | sort

## build: Build for the default architecture in use
build:
	go build -v -ldflags '$(LD_FLAGS)' -o $(BINARY_NAME)

## build-for: Build the available binaries for the specified 'os' and 'arch'
# make build-for os=linux arch=amd64
build-for:
	CGO_ENABLED=0 GOOS=$(os) GOARCH=$(arch) \
	go build -v -ldflags '$(LD_FLAGS)' \
	-o $(BINARY_NAME)_$(os)_$(arch)$(suffix)

## ca-roots: Generate the list of valid CA certificates
ca-roots:
	@docker run -dit --rm --name ca-roots debian:stable-slim
	@docker exec --privileged ca-roots sh -c "apt update"
	@docker exec --privileged ca-roots sh -c "apt install -y ca-certificates"
	@docker exec --privileged ca-roots sh -c "cat /etc/ssl/certs/* > /ca-roots.crt"
	@docker cp ca-roots:/ca-roots.crt ca-roots.crt
	@docker stop ca-roots

## deps: Download and compile all dependencies and intermediary products
deps:
	@-rm -rf vendor
	go mod tidy
	go mod verify
	go mod download
	go mod vendor

## docker: Build docker image
# https://github.com/opencontainers/image-spec/blob/master/annotations.md
docker:
	make build-for os=linux arch=amd64
	mv $(BINARY_NAME)_linux_amd64 $(BINARY_NAME)
	@-docker rmi $(DOCKER_IMAGE):$(GIT_TAG:v%=%)
	@docker build \
	"--label=org.opencontainers.image.title=$(BINARY_NAME)" \
	"--label=org.opencontainers.image.authors=$(MAINTAINERS)" \
	"--label=org.opencontainers.image.created=$(GIT_COMMIT_DATE)" \
	"--label=org.opencontainers.image.revision=$(GIT_COMMIT_HASH)" \
	"--label=org.opencontainers.image.version=$(GIT_TAG:v%=%)" \
	--rm -t $(DOCKER_IMAGE):$(GIT_TAG:v%=%) .
	@rm $(BINARY_NAME)

## install: Install the binary to GOPATH and keep cached all compiled artifacts
install:
	go build -v -ldflags '$(LD_FLAGS)' -i -o ${GOPATH}/bin/$(BINARY_NAME)

## lint: Static analysis
lint:
	golangci-lint run -v ./...

## proto: Compile all PB definitions and RPC services
proto:
	# Verify style and consistency
	$(proto-builder) buf check lint --file $(shell echo proto/v1/*.proto | tr ' ' ',')
	@-$(proto-builder) buf check breaking \
	--file $(shell echo proto/v1/*.proto | tr ' ' ',') \
	--against-input proto/v1/image.bin

	# Clean old builds
	@-rm proto/v1/image.bin

	# Build package image
	$(proto-builder) buf image build -o proto/v1/image.bin --file $(shell echo proto/v1/*.proto | tr ' ' ',')

	# Build package code
	$(proto-builder) buf protoc \
	--proto_path=proto \
	--go_out=proto \
	--go-grpc_out=proto \
	--grpc-gateway_out=logtostderr=true:proto \
	--swagger_out=logtostderr=true:proto \
	proto/v1/*.proto

	# Remove package comment added by the gateway generator to avoid polluting
	# the package documentation.
	@-sed -i '' '/\/\*/,/*\//d' proto/v1/*.pb.gw.go

	# Style adjustments
	gofmt -s -w proto/v1
	goimports -w proto/v1

## release: Prepare artifacts for a new tagged release
release:
	goreleaser release --skip-validate --skip-publish --rm-dist

## scan: Look for known vulnerabilities in the project dependencies
# https://github.com/sonatype-nexus-community/nancy
scan:
	@go list -f '{{if not .Indirect}}{{.}}{{end}}' -mod=mod -m all | nancy sleuth -o text

## test: Run unit tests excluding the vendor dependencies
test:
	go test -race -v -failfast -coverprofile=coverage.report ./...
	go tool cover -html coverage.report -o coverage.html

## updates: List available updates for direct dependencies
# https://github.com/golang/go/wiki/Modules#how-to-upgrade-and-downgrade-dependencies
updates:
	@go list -u -f '{{if (and (not (or .Main .Indirect)) .Update)}}{{.Path}}: {{.Version}} -> {{.Update.Version}}{{end}}' -m all 2> /dev/null
