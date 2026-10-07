// Command entrypoint prepares the writable directories and then becomes the
// server. It exists for one reason: a mounted volume arrives owned by root, and
// the server runs as an unprivileged user, so something has to fix ownership
// before the process drops privileges.
//
// It only ever chowns the configured upload directory, and it refuses to run as
// root beyond that: if the process is already unprivileged it simply execs.
package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
)

const defaultDir = "/data/uploads"

func main() {
	binary := "/relaydesk"
	if len(os.Args) > 1 {
		binary = os.Args[1]
	}
	dir := os.Getenv("STORAGE_LOCAL_DIR")
	if dir == "" {
		dir = defaultDir
	}

	prepare(dir)

	// Hand over to the server with the same environment and arguments. Using
	// exec rather than fork keeps the process a single PID, so the container
	// runtime's signals reach the server directly.
	argv := append([]string{binary}, os.Args[2:]...)
	if err := syscall.Exec(binary, argv, os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "relaydesk entrypoint: exec %s: %v\n", binary, err)
		os.Exit(1)
	}
}

// prepare makes dir exist and be writable by the process, then leaves the
// privileges alone. Failures are reported but not fatal: a read-only filesystem
// with an external object store is a legitimate configuration.
func prepare(dir string) {
	if err := os.MkdirAll(dir, 0o750); err != nil && !errors.Is(err, fs.ErrExist) {
		warn("create %s: %v", dir, err)
	}
	if os.Geteuid() == 0 {
		uid, gid := unprivileged()
		if err := chownTree(dir, uid, gid); err != nil {
			warn("chown %s: %v", dir, err)
		}
		if err := syscall.Setgid(gid); err != nil {
			warn("setgid %d: %v", gid, err)
		}
		if err := syscall.Setuid(uid); err != nil {
			warn("setuid %d: %v", uid, err)
		}
		return
	}
	if err := writable(dir); err != nil {
		warn("%s is not writable: %v", dir, err)
	}
}

func warn(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "relaydesk entrypoint: "+format+"\n", args...)
}

func writable(dir string) error {
	probe := filepath.Join(dir, ".write-probe")
	file, err := os.OpenFile(probe, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	name := file.Name()
	if err := file.Close(); err != nil {
		return err
	}
	return os.Remove(name)
}

func chownTree(root string, uid, gid int) error {
	return filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if chownErr := os.Lchown(path, uid, gid); chownErr != nil {
			return chownErr
		}
		// Group-writable so a later run under a different uid in the same group
		// can still write.
		if entry.IsDir() {
			return os.Chmod(path, 0o770)
		}
		return nil
	})
}

// unprivileged mirrors the distroless :nonroot user.
func unprivileged() (int, int) {
	uid := 65532
	if value := os.Getenv("RELAYDESK_UID"); value != "" {
		if parsed, err := parsePositive(value); err == nil {
			uid = parsed
		}
	}
	gid := uid
	if value := os.Getenv("RELAYDESK_GID"); value != "" {
		if parsed, err := parsePositive(value); err == nil {
			gid = parsed
		}
	}
	return uid, gid
}

func parsePositive(value string) (int, error) {
	number := 0
	for _, char := range value {
		if char < '0' || char > '9' {
			return 0, fmt.Errorf("not a number: %q", value)
		}
		number = number*10 + int(char-'0')
	}
	if number <= 0 {
		return 0, fmt.Errorf("not positive: %q", value)
	}
	return number, nil
}
