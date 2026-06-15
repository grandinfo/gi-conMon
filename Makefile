SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---- Variables -------------------------------------------------------
MODULE       := github.com/grandinfo/gi-conMon
BINARY       := conmon
VERSION      ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
GIT_COMMIT   ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE   ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
GO_VERSION   ?= $(shell go version | cut -d' ' -f3)

LDFLAGS := -s -w \
	-X $(MODULE)/internal/version.Version=$(VERSION) \
	-X $(MODULE)/internal/version.GitCommit=$(GIT_COMMIT) \
	-X $(MODULE)/internal/version.BuildDate=$(BUILD_DATE) \
	-X $(MODULE)/internal/version.GoVersion=$(GO_VERSION)

BUILD_DIR := ./bin

# ---- Help ------------------------------------------------------------
.PHONY: help
help: ## 显示此帮助信息
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---- Build -----------------------------------------------------------
.PHONY: build
build: ## 构建 conmon 二进制（当前平台）
	@mkdir -p $(BUILD_DIR)
	go build -ldflags="$(LDFLAGS)" -o $(BUILD_DIR)/$(BINARY) ./cmd/conmon
	@echo "✓ 构建完成: $(BUILD_DIR)/$(BINARY)"

.PHONY: build-all
build-all: ## 交叉编译所有目标平台
	@mkdir -p $(BUILD_DIR)
	@for GOOS in linux darwin windows; do \
		for GOARCH in amd64 arm64; do \
			suffix=""; \
			[ "$$GOOS" = "windows" ] && suffix=".exe"; \
			out="$(BUILD_DIR)/$(BINARY)-$$GOOS-$$GOARCH$$suffix"; \
			echo "  Building $$out..."; \
			GOOS=$$GOOS GOARCH=$$GOARCH CGO_ENABLED=0 go build \
				-ldflags="$(LDFLAGS)" \
				-o $$out ./cmd/conmon; \
		done; \
	done
	@echo "✓ 交叉编译完成"

.PHONY: install
install: build ## 安装到 /usr/local/bin
	sudo install -m 755 $(BUILD_DIR)/$(BINARY) /usr/local/bin/$(BINARY)
	sudo setcap cap_net_raw+ep /usr/local/bin/$(BINARY) || true

# ---- Test ------------------------------------------------------------
.PHONY: test
test: ## 运行单元测试
	go test ./... -v -count=1 -timeout=60s

.PHONY: test-cover
test-cover: ## 运行测试并生成覆盖率报告
	go test ./... -coverprofile=coverage.out -covermode=atomic
	go tool cover -html=coverage.out -o coverage.html
	@echo "✓ 覆盖率报告: coverage.html"

.PHONY: bench
bench: ## 运行性能基准测试
	go test ./... -bench=. -benchmem -run=^$

# ---- Lint & Format ---------------------------------------------------
.PHONY: lint
lint: ## 运行 golangci-lint
	@which golangci-lint > /dev/null 2>&1 || \
		(echo "安装 golangci-lint..." && \
		curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(shell go env GOPATH)/bin)
	golangci-lint run ./...

.PHONY: fmt
fmt: ## 格式化代码
	gofmt -s -w .
	goimports -w . || true

.PHONY: vet
vet: ## 运行 go vet
	go vet ./...

# ---- Docker ----------------------------------------------------------
.PHONY: docker-build
docker-build: ## 构建 Docker 镜像
	docker build \
		--build-arg VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(GIT_COMMIT) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		-t conmon/conmon:$(VERSION) \
		-t conmon/conmon:latest \
		.

.PHONY: docker-push
docker-push: ## 推送 Docker 镜像
	docker push conmon/conmon:$(VERSION)
	docker push conmon/conmon:latest

.PHONY: docker-run
docker-run: ## 以 Docker 运行（开发模式）
	docker run --rm -it \
		-p 11080:11080 \
		-v $(PWD)/configs/conmon.yaml:/etc/conmon/conmon.yaml:ro \
		-v conmon-data:/var/lib/conmon \
		conmon/conmon:latest

.PHONY: compose-up
compose-up: ## 使用 Docker Compose 启动完整服务栈
	cd deployments/compose && docker compose up -d

.PHONY: compose-down
compose-down: ## 停止 Docker Compose 服务栈
	cd deployments/compose && docker compose down

.PHONY: compose-logs
compose-logs: ## 查看 Docker Compose 日志
	cd deployments/compose && docker compose logs -f conmon-server

# ---- Dev -------------------------------------------------------------
.PHONY: run
run: ## 本地运行（开发模式）
	go run ./cmd/conmon server -c configs/conmon.yaml

.PHONY: run-probe
run-probe: ## 本地运行探针进程
	go run ./cmd/conmon probe -c configs/conmon.yaml

.PHONY: dev
dev: ## 热重载开发模式（需要 air）
	@which air > /dev/null 2>&1 || go install github.com/air-verse/air@latest
	air -c .air.toml

# ---- Clean -----------------------------------------------------------
.PHONY: clean
clean: ## 清理构建产物
	rm -rf $(BUILD_DIR) coverage.out coverage.html
	go clean -cache -testcache

# ---- Release ---------------------------------------------------------
.PHONY: release
release: lint test build-all ## 完整发布流程（lint → test → 交叉编译）
	@echo "✓ 发布准备完成，版本: $(VERSION)"

# ---- Database --------------------------------------------------------
.PHONY: db-migrate
db-migrate: ## 运行数据库迁移（首次部署时执行）
	$(BUILD_DIR)/$(BINARY) db migrate

.PHONY: db-status
db-status: ## 查看数据库迁移状态
	$(BUILD_DIR)/$(BINARY) db status

# ---- Misc ------------------------------------------------------------
.PHONY: version
version: ## 显示构建版本信息
	@echo "版本:     $(VERSION)"
	@echo "提交:     $(GIT_COMMIT)"
	@echo "构建时间: $(BUILD_DATE)"
	@echo "Go 版本:  $(GO_VERSION)"

.PHONY: deps
deps: ## 更新并整理依赖
	go get -u ./...
	go mod tidy
