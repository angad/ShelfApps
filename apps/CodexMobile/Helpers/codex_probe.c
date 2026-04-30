#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    printf("codex_probe ok\n");
    printf("argc=%d\n", argc);
    printf("uid=%d euid=%d gid=%d egid=%d\n", getuid(), geteuid(), getgid(), getegid());
    for (int i = 0; i < argc; i++) {
        printf("argv[%d]=%s\n", i, argv[i]);
    }
    return 0;
}
