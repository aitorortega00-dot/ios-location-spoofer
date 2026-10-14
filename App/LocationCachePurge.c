//
//  LocationCachePurge.c
//  location-spoofer
//
//  Jailbreak / TrollStore only.
//
//  iOS keeps the positions of Wi-Fi access points it has already resolved in
//  locationd's cache databases. While those entries exist, locationd never asks
//  gs-loc.apple.com (= our proxy) about them, so real positions cached while the
//  spoof was off (e.g. the home APs) pull the fix back home. "Reset Location &
//  Privacy" in Settings clears them, but also wipes every app's permissions.
//
//  This file removes only the Wi-Fi location rows and then kills locationd so it
//  also forgets its in-memory copy (launchd relaunches it on demand).
//
//  How it runs:
//    1. The app calls lcp_purge_as_root(), which re-launches the app's own
//       executable as root (persona override, needs com.apple.private.persona-mgmt
//       and an unsandboxed app) with the argument --purge-location-cache.
//    2. In that child, the constructor below runs before Swift/UIKit start,
//       does the purge, prints a report on stdout and exits.
//

#include <dirent.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

#define LCP_ARG "--purge-location-cache"
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1

extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *attr, uid_t persona_id, uint32_t flags);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *attr, uid_t uid);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *attr, gid_t gid);
extern char ***_NSGetArgv(void);
extern int *_NSGetArgc(void);
extern char **environ;

// ---------------------------------------------------------------------------
// Child side (runs as root)
// ---------------------------------------------------------------------------

static const char *kCacheDirs[] = {
    "/private/var/root/Library/Caches/locationd",
    "/private/var/mobile/Library/Caches/locationd",
    NULL,
};

static int has_suffix(const char *s, const char *suffix) {
    size_t ls = strlen(s), lx = strlen(suffix);
    return ls >= lx && strcmp(s + ls - lx, suffix) == 0;
}

/// Deletes every row of the Wi-Fi location tables in one database.
/// Returns the number of rows removed, or -1 if the file could not be opened.
static long purge_db(const char *path) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        printf("  %s: cannot open (%s)\n", path, db ? sqlite3_errmsg(db) : "?");
        if (db) sqlite3_close(db);
        return -1;
    }
    sqlite3_busy_timeout(db, 3000);

    // Collect table names first (can't modify while iterating sqlite_master).
    char tables[32][128];
    int ntables = 0;
    sqlite3_stmt *st = NULL;
    const char *q = "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%Wifi%Location%'";
    if (sqlite3_prepare_v2(db, q, -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW && ntables < 32) {
            const unsigned char *n = sqlite3_column_text(st, 0);
            if (n) {
                strncpy(tables[ntables], (const char *)n, sizeof(tables[0]) - 1);
                tables[ntables][sizeof(tables[0]) - 1] = 0;
                ntables++;
            }
        }
    }
    sqlite3_finalize(st);

    long total = 0;
    if (ntables == 0) {
        printf("  %s: no Wi-Fi location tables\n", path);
    }
    for (int i = 0; i < ntables; i++) {
        char sql[256];
        snprintf(sql, sizeof(sql), "DELETE FROM \"%s\"", tables[i]);
        char *err = NULL;
        if (sqlite3_exec(db, sql, NULL, NULL, &err) == SQLITE_OK) {
            int n = sqlite3_changes(db);
            total += n;
            printf("  %s: %s -> %d rows deleted\n", path, tables[i], n);
        } else {
            printf("  %s: %s -> delete failed (%s)\n", path, tables[i], err ? err : "?");
        }
        if (err) sqlite3_free(err);
    }
    sqlite3_close(db);
    return total;
}

/// SIGKILLs every process named locationd (no flush of its in-memory cache).
static int kill_locationd(void) {
    int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) return 0;
    size += size / 4;
    struct kinfo_proc *procs = malloc(size);
    if (!procs) return 0;
    int killed = 0;
    if (sysctl(mib, 3, procs, &size, NULL, 0) == 0) {
        size_t count = size / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < count; i++) {
            if (strcmp(procs[i].kp_proc.p_comm, "locationd") == 0) {
                pid_t pid = procs[i].kp_proc.p_pid;
                if (kill(pid, SIGKILL) == 0) {
                    printf("  locationd pid %d killed\n", pid);
                    killed++;
                } else {
                    printf("  locationd pid %d: kill failed (%s)\n", pid, strerror(errno));
                }
            }
        }
    }
    free(procs);
    return killed;
}

static int run_purge(void) {
    printf("uid=%d euid=%d\n", getuid(), geteuid());
    long total = 0;
    int dbs = 0;
    for (int d = 0; kCacheDirs[d]; d++) {
        DIR *dir = opendir(kCacheDirs[d]);
        if (!dir) {
            printf("dir %s: %s\n", kCacheDirs[d], strerror(errno));
            continue;
        }
        printf("dir %s\n", kCacheDirs[d]);
        struct dirent *e;
        while ((e = readdir(dir)) != NULL) {
            if (!has_suffix(e->d_name, ".db")) continue;
            char path[1024];
            snprintf(path, sizeof(path), "%s/%s", kCacheDirs[d], e->d_name);
            long n = purge_db(path);
            if (n >= 0) { total += n; dbs++; }
        }
        closedir(dir);
    }
    int killed = kill_locationd();
    printf("RESULT dbs=%d rows=%ld killed=%d\n", dbs, total, killed);
    fflush(stdout);
    return dbs > 0 ? 0 : 2;
}

__attribute__((constructor))
static void lcp_child_entry(void) {
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    if (argc >= 2 && argv[1] && strcmp(argv[1], LCP_ARG) == 0) {
        _exit(run_purge());
    }
}

// ---------------------------------------------------------------------------
// Parent side (called from Swift)
// ---------------------------------------------------------------------------

/// Re-launches this executable as root to purge the cache.
/// Writes the child's report (or the spawn error) into `out`.
/// Returns the child's exit code (0 = OK), or a negative value if it could not run.
int lcp_purge_as_root(char *out, int outlen) {
    if (outlen > 0) out[0] = 0;

    char exe[1024];
    uint32_t sz = sizeof(exe);
    if (_NSGetExecutablePath(exe, &sz) != 0) {
        snprintf(out, outlen, "cannot get executable path");
        return -1;
    }

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        snprintf(out, outlen, "pipe failed: %s", strerror(errno));
        return -2;
    }

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, pipefd[0]);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    char *args[] = {exe, LCP_ARG, NULL};
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe, &fa, &attr, args, environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    close(pipefd[1]);

    if (rc != 0) {
        close(pipefd[0]);
        snprintf(out, outlen, "spawn as root failed: %s (%d)", strerror(rc), rc);
        return -3;
    }

    int used = 0;
    char buf[512];
    ssize_t n;
    while ((n = read(pipefd[0], buf, sizeof(buf))) > 0) {
        int room = outlen - used - 1;
        if (room > 0) {
            int c = (int)(n < room ? n : room);
            memcpy(out + used, buf, c);
            used += c;
            out[used] = 0;
        }
    }
    close(pipefd[0]);

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return -4;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -5;
}
