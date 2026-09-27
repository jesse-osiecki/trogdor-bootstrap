/* Minimal PAM client: runs pam_authenticate on a service the way kscreenlocker's
 * non-interactive authenticator does (no prompts answered, messages printed). */
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int conv(int n, const struct pam_message **msg, struct pam_response **resp, void *data) {
    (void)data;
    *resp = calloc(n, sizeof(struct pam_response));
    for (int i = 0; i < n; i++) {
        const char *kind = msg[i]->msg_style == PAM_TEXT_INFO ? "info" :
                           msg[i]->msg_style == PAM_ERROR_MSG ? "error" : "prompt";
        printf("[conv %s] %s\n", kind, msg[i]->msg);
        if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF || msg[i]->msg_style == PAM_PROMPT_ECHO_ON)
            return PAM_CONV_ERR; /* non-interactive: never answer prompts */
    }
    return PAM_SUCCESS;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s service user\n", argv[0]); return 2; }
    pam_handle_t *h = NULL;
    struct pam_conv c = { conv, NULL };
    int rc = pam_start(argv[1], argv[2], &c, &h);
    if (rc != PAM_SUCCESS) { printf("pam_start: %d %s\n", rc, pam_strerror(h, rc)); return 1; }
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    rc = pam_authenticate(h, 0);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    printf("pam_authenticate(%s): rc=%d (%s) after %.1fs\n", argv[1], rc, pam_strerror(h, rc),
           (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9);
    pam_end(h, rc);
    return rc == PAM_SUCCESS ? 0 : 1;
}
