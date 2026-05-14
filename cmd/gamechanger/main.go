package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/joshrpowell/gamechanger-cli/internal/commands"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	os.Exit(commands.Execute(ctx, os.Args[1:], os.Stdout, os.Stderr))
}
