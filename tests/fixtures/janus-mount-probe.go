// Synthetic Linux container probe; it never receives a real credential.
package main

import (
	"bytes"
	"os"
	"syscall"
	"time"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "wait" {
		for {
			time.Sleep(time.Hour)
		}
	}
	if len(os.Args) != 2 || (os.Args[1] != "A" && os.Args[1] != "B") {
		os.Exit(2)
	}
	parent, err := os.Lstat("/run/janus/flow-host")
	if err != nil || !parent.IsDir() || parent.Mode().Perm() != 0700 {
		os.Exit(3)
	}
	ps := parent.Sys().(*syscall.Stat_t)
	if ps.Uid != 100 || ps.Gid != 101 {
		os.Exit(4)
	}
	key, err := os.Lstat("/run/janus/flow-host/api-key")
	if err != nil || !key.Mode().IsRegular() || key.Mode().Perm() != 0400 {
		os.Exit(5)
	}
	ks := key.Sys().(*syscall.Stat_t)
	if ks.Uid != 100 || ks.Gid != 101 || ks.Nlink != 1 {
		os.Exit(6)
	}
	data, err := os.ReadFile("/run/janus/flow-host/api-key")
	if err != nil || !bytes.Equal(data, bytes.Repeat([]byte(os.Args[1]), 64)) {
		os.Exit(7)
	}
	if err := os.WriteFile("/run/janus/flow-host/unexpected", nil, 0600); err == nil {
		os.Exit(8)
	}
}
