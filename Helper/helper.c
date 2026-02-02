// awdl-helper: setuid helper for ifconfig awdl0
// Usage: awdl-helper up|down

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Usage: awdl-helper up|down\n");
        return 1;
    }

    // Escalate to root if setuid
    if (setuid(0) != 0) {
        perror("setuid failed");
        return 1;
    }

    const char *action = argv[1];

    if (strcmp(action, "up") != 0 && strcmp(action, "down") != 0) {
        fprintf(stderr, "Invalid action: %s\n", action);
        return 1;
    }

    // Execute ifconfig
    execl("/sbin/ifconfig", "ifconfig", "awdl0", action, NULL);

    perror("execl failed");
    return 1;
}
