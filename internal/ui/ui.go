// Package ui embeds the conMon web frontend and exposes an http.FileSystem.
package ui

import (
	"embed"
	"io/fs"
	"net/http"
)

//go:embed all:dist
var embeddedFS embed.FS

// FS returns a sub-filesystem rooted at the embedded "dist" directory.
// API consumers should mount this at "/" so that index.html is served for "/".
func FS() http.FileSystem {
	sub, err := fs.Sub(embeddedFS, "dist")
	if err != nil {
		panic("ui: embedded dist/ not found: " + err.Error())
	}
	return http.FS(sub)
}
