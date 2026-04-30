#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int valid_name(const char *s) {
    size_t n = strlen(s);
    if (n == 0 || n > 64) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!(isalnum(c) || c == '_' || c == '-')) return 0;
    }
    return 1;
}

static int valid_bundle(const char *s) {
    size_t n = strlen(s);
    if (n == 0 || n > 160) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!(isalnum(c) || c == '.' || c == '-' || c == '_')) return 0;
    }
    return 1;
}

static int starts_with(const char *s, const char *prefix) {
    size_t n = strlen(prefix);
    return strncmp(s, prefix, n) == 0;
}

static int ends_with(const char *s, const char *suffix) {
    size_t n = strlen(s);
    size_t m = strlen(suffix);
    return n >= m && strcmp(s + n - m, suffix) == 0;
}

static int valid_source_app(const char *s) {
    if (!starts_with(s, "/var/mobile/AppBuilder/Projects/")) return 0;
    if (!ends_with(s, ".app")) return 0;
    if (strstr(s, "/../") || strstr(s, "/./")) return 0;
    return strlen(s) < 240;
}

static int run(const char *path, char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) return 127;
    if (pid == 0) {
        execv(path, argv);
        _exit(127);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return 127;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 127;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s SOURCE_APP APP_NAME BUNDLE_ID\n", argv[0]);
        return 2;
    }

    const char *source = argv[1];
    const char *app_name = argv[2];
    const char *bundle_id = argv[3];
    if (!valid_source_app(source)) {
        fprintf(stderr, "refusing source path: %s\n", source);
        return 2;
    }
    if (!valid_name(app_name) || !valid_bundle(bundle_id)) {
        fprintf(stderr, "invalid app name or bundle id\n");
        return 2;
    }

    if (setgid(0) != 0 || setuid(0) != 0) {
        perror("setuid");
        return 1;
    }

    char dest[256];
    snprintf(dest, sizeof(dest), "/Applications/%s.app", app_name);

    char *rm_argv[] = { "rm", "-rf", dest, NULL };
    int code = run("/bin/rm", rm_argv);
    if (code != 0) {
        fprintf(stderr, "rm failed: %d\n", code);
        return code;
    }

    char *cp_argv[] = { "cp", "-R", (char *)source, dest, NULL };
    code = run("/bin/cp", cp_argv);
    if (code != 0) {
        fprintf(stderr, "cp failed: %d\n", code);
        return code;
    }

    char *uicache_argv[] = { "uicache", "-p", dest, NULL };
    code = run("/usr/bin/uicache", uicache_argv);
    if (code != 0) {
        char *uicache_all_argv[] = { "uicache", NULL };
        code = run("/usr/bin/uicache", uicache_all_argv);
    }
    if (code != 0) {
        fprintf(stderr, "uicache failed: %d\n", code);
        return code;
    }

    char *uiopen_argv[] = { "uiopen", (char *)bundle_id, NULL };
    run("/usr/bin/uiopen", uiopen_argv);

    printf("installed %s as %s\n", dest, bundle_id);
    return 0;
}
